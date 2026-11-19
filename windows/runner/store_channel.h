#ifndef RUNNER_STORE_CHANNEL_H_
#define RUNNER_STORE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Answers "when did the Store hand this user the app?" for the Dart side.
//
// Once the Store listing is free, being installed from the Store no longer
// says whether the app was paid for. The Store itself still knows: every
// SKU a user owns carries the date it entered their collection
// (Windows.Services.Store, StoreSku.CollectionData.AcquiredDate), and for a
// copy bought while the listing cost money that date is the purchase. It is
// what lets a buyer who reinstalls on a fresh PC keep Pro, where nothing
// local is left to prove the purchase.
//
// The API is WinRT and only works with package identity, so this lives in
// the runner rather than in Dart. `getAcquisition`, no arguments, answers a
// map:
//
//   acquiredAt  ISO-8601 UTC instant, or null when unknown
//   error       null, or a short reason nothing could be found
//
// `requestRateAndReview`, no arguments, shows the Store's own rating sheet
// (StoreContext.RequestRateAndReviewAppAsync) and answers once the user
// closes it: `status` is "succeeded", "canceled", "networkError" or "error",
// with `error` as above.
//
// Never throws at the Dart side: an unpackaged process, a sideloaded
// package, a user who is not signed in to the Store, an old Windows — all
// come back as an answer with `error` set.
class StoreChannel {
 public:
  // Matches `StoreAcquisitionProbe.channelName` on the Dart side.
  static constexpr char kChannelName[] =
      "com.bostrot.wsl2distromanager/store";

  // Posted to |window| when a lookup finishes, so the reply is sent from the
  // platform thread. The window forwards it to |OnAnswerMessage|.
  static constexpr UINT kAnswerMessage = WM_APP + 0x75;

  // |window| is the top-level window: the Store context of a Win32 process
  // has to be tied to one, and it is where |kAnswerMessage| lands.
  StoreChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~StoreChannel();

  // Handles |kAnswerMessage|: |lparam| carries the finished call. Returns
  // true when the message was one of ours.
  bool OnAnswerMessage(LPARAM lparam);

 private:
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<MethodResult> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_STORE_CHANNEL_H_
