#include "store_channel.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>

#include <cstdio>
#include <thread>
#include <utility>

namespace {

using winrt::Windows::Services::Store::StoreContext;
using winrt::Windows::Services::Store::StoreProduct;
using winrt::Windows::Services::Store::StoreProductResult;
using winrt::Windows::Services::Store::StoreRateAndReviewResult;
using winrt::Windows::Services::Store::StoreRateAndReviewStatus;
using winrt::Windows::Services::Store::StoreSku;

using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

// What the Store said, as far as the Dart side cares.
struct Answer {
  std::string acquired_at;  // empty when unknown
  std::string error;        // empty when acquired_at is set
};

// A call in flight. Owned by the worker thread until it posts the
// pointer through |kAnswerMessage|, then by |OnAnswerMessage|, which
// replies and deletes it. Nothing here refers back to the StoreChannel, so
// a call that outlives the channel — the window closed mid-call — has
// nothing to dangle on; its message is dropped and the entry leaks, once,
// on the way out of the process.
struct Lookup {
  std::unique_ptr<MethodResult> result;
  flutter::EncodableValue reply;
};

Answer Fail(std::string error) {
  Answer answer;
  answer.error = std::move(error);
  return answer;
}

// A WinRT DateTime is 100ns ticks since 1601 in UTC; zero is "never".
std::string IsoUtc(winrt::Windows::Foundation::DateTime instant) {
  if (instant.time_since_epoch().count() <= 0) return "";
  FILETIME file_time = winrt::clock::to_FILETIME(instant);
  SYSTEMTIME system_time;
  if (!::FileTimeToSystemTime(&file_time, &system_time)) return "";
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02uZ",
                system_time.wYear, system_time.wMonth, system_time.wDay,
                system_time.wHour, system_time.wMinute, system_time.wSecond);
  return buffer;
}

std::string HresultText(const char* what, HRESULT code) {
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%s 0x%08lX", what,
                static_cast<unsigned long>(code));
  return buffer;
}

// Picks the SKU the user actually owns. A product lists every SKU it has —
// the full app, a trial, per-market variants — and only the one in the
// user's collection carries an acquisition date. A trial is skipped: the
// listing never offered one, and owning one would prove no purchase.
Answer AnswerFrom(const StoreProduct& product) {
  if (!product.IsInUserCollection()) {
    // Signed out of the Store, or a package that did not come from it.
    return Fail("not-in-collection");
  }
  for (const StoreSku& sku : product.Skus()) {
    if (!sku.IsInUserCollection() || sku.IsTrial()) continue;
    auto collection = sku.CollectionData();
    if (!collection || collection.IsTrial()) continue;
    std::string acquired = IsoUtc(collection.AcquiredDate());
    if (acquired.empty()) continue;
    Answer answer;
    answer.acquired_at = std::move(acquired);
    return answer;
  }
  return Fail("no-acquired-date");
}

// Ties a Store context to |window|. A Win32 process has no CoreWindow; the
// context has to be told which window it belongs to before it will talk to
// the Store, and before it can put a sheet in front of the user.
StoreContext ContextFor(HWND window) {
  StoreContext context = StoreContext::GetDefault();
  if (context && window) {
    auto initializer = context.try_as<IInitializeWithWindow>();
    if (initializer) initializer->Initialize(window);
  }
  return context;
}

// Asks the Store, on the calling thread. Blocks for as long as the Store
// takes, so never on the platform thread.
Answer AskStore(HWND window) {
  StoreContext context = ContextFor(window);
  if (!context) return Fail("no-store-context");
  StoreProductResult product_result =
      context.GetStoreProductForCurrentAppAsync().get();
  StoreProduct product = product_result.Product();
  if (!product) {
    const HRESULT extended = product_result.ExtendedError();
    return Fail(FAILED(extended) ? HresultText("store", extended)
                                 : "no-product");
  }
  return AnswerFrom(product);
}

// AskStore with every way it can fail turned into an answer.
Answer Query(HWND window) {
  bool apartment = false;
  Answer answer;
  try {
    // A fresh thread has no apartment yet. Multi-threaded, because the
    // blocking wait in AskStore is not allowed on a single-threaded one.
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    apartment = true;
    answer = AskStore(window);
  } catch (const winrt::hresult_error& error) {
    // No package identity, a sideloaded package, no Store on this SKU of
    // Windows: all land here.
    answer = Fail(HresultText("winrt", error.code()));
  } catch (...) {
    answer = Fail("unknown");
  }
  if (apartment) winrt::uninit_apartment();
  return answer;
}

// Shows the Store's own rating sheet for this app and waits for the user to
// close it. Same threading as Query. Answers a map:
//
//   status  "succeeded" (rated or reviewed), "canceled", "networkError",
//           or "error" — which is also every way the sheet could not open
//   error   null, or a short reason
flutter::EncodableValue RequestRating(HWND window) {
  std::string status = "error";
  std::string error;
  bool apartment = false;
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    apartment = true;
    StoreContext context = ContextFor(window);
    if (!context) {
      error = "no-store-context";
    } else {
      // Windows 10 1809 and later; on anything older the call throws.
      StoreRateAndReviewResult result =
          context.RequestRateAndReviewAppAsync().get();
      switch (result.Status()) {
        case StoreRateAndReviewStatus::Succeeded:
          status = "succeeded";
          break;
        case StoreRateAndReviewStatus::CanceledByUser:
          status = "canceled";
          break;
        case StoreRateAndReviewStatus::NetworkError:
          status = "networkError";
          break;
        default:
          break;
      }
      const HRESULT extended = result.ExtendedError();
      if (FAILED(extended)) error = HresultText("store", extended);
    }
  } catch (const winrt::hresult_error& failure) {
    // No package identity, no Store on this SKU of Windows, too old.
    error = HresultText("winrt", failure.code());
  } catch (...) {
    error = "unknown";
  }
  if (apartment) winrt::uninit_apartment();

  flutter::EncodableMap map;
  map[flutter::EncodableValue("status")] = flutter::EncodableValue(status);
  map[flutter::EncodableValue("error")] =
      error.empty() ? flutter::EncodableValue()
                    : flutter::EncodableValue(error);
  return flutter::EncodableValue(map);
}

flutter::EncodableValue Encode(const Answer& answer) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("acquiredAt")] =
      answer.acquired_at.empty()
          ? flutter::EncodableValue()
          : flutter::EncodableValue(answer.acquired_at);
  map[flutter::EncodableValue("error")] =
      answer.error.empty() ? flutter::EncodableValue()
                           : flutter::EncodableValue(answer.error);
  return flutter::EncodableValue(map);
}

}  // namespace

StoreChannel::StoreChannel(flutter::BinaryMessenger* messenger, HWND window)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())),
      window_(window) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

StoreChannel::~StoreChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void StoreChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  const bool rate = method == "requestRateAndReview";
  if (!rate && method != "getAcquisition") {
    result->NotImplemented();
    return;
  }

  // The Store call goes to the network and blocks for as long as it likes;
  // the platform thread must keep pumping. The answer comes back through
  // |kAnswerMessage| so the reply itself is sent from the platform thread,
  // which is the only one the messenger may be used from. The thread owns
  // the lookup outright and captures nothing of this object, which may be
  // gone by the time the Store answers.
  auto* lookup = new Lookup{std::move(result), flutter::EncodableValue()};
  const HWND window = window_;
  std::thread([lookup, window, rate] {
    lookup->reply = rate ? RequestRating(window) : Encode(Query(window));
    ::PostMessage(window, kAnswerMessage, 0,
                  reinterpret_cast<LPARAM>(lookup));
  }).detach();
}

bool StoreChannel::OnAnswerMessage(LPARAM lparam) {
  std::unique_ptr<Lookup> lookup(reinterpret_cast<Lookup*>(lparam));
  if (!lookup) return false;
  lookup->result->Success(lookup->reply);
  return true;
}
