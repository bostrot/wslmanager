// Turning the raw bytes of a child process into text.
//
// wsl.exe speaks two encodings on the same pipes. Its own messages —
// `--version`, `--status`, `--list`, and every failure it reports itself — are
// UTF-16LE. Whatever a command *inside* a distro prints is passed through
// untouched, which in practice is UTF-8. Nothing on the pipe says which one
// a given answer is.
//
// The app used to decode everything as UTF-8 and drop the NUL bytes. That
// reads fine for as long as wsl.exe answers in ASCII, where UTF-16LE is the
// same letters with a NUL after each one. On a localized Windows it is not
// ASCII: `正在` is the bytes `63 6B 28 57`, which came out as `ck(W`, and
// every byte above 0x7F as a replacement character (bostrot/wslmanager#322).

import 'dart:convert' show Utf8Decoder;

/// Decode process output, whichever of the two encodings it is in.
///
/// UTF-16LE is recognised by a byte-order mark or by where the NUL bytes sit
/// (see [looksLikeUtf16Le]); everything else is decoded as lenient UTF-8, so a
/// stray byte costs one replacement character instead of the whole answer.
/// Control characters are left in — NULs included — for the caller to strip
/// the way it always has.
String decodeProcessOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';
  if (looksLikeUtf16Le(bytes)) {
    final decoded = _decodeUtf16Le(bytes);
    if (decoded != null) return decoded;
  }
  return const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// True when [bytes] read as UTF-16LE rather than as UTF-8.
///
/// UTF-8 text has no reason to contain a NUL, while UTF-16LE text nearly
/// always does: every ASCII character — and a message without a single space,
/// digit, punctuation mark or line break is hard to find — is a byte followed
/// by a NUL, so the NULs land on odd offsets. A NUL on an even offset is the
/// low half of a code unit such as `一` (U+4E00) and is common in Chinese, so
/// those are tolerated as long as they do not outnumber the odd ones.
///
/// NULs alone are not proof, though: `/proc/<pid>/cmdline` and `find -print0`
/// are UTF-8 with NUL separators, and one of those landing on an odd offset
/// must not turn a path into CJK. So bytes that are also *valid* UTF-8 only
/// count as UTF-16LE when at least half the code units are a byte plus a NUL,
/// which is what mostly-ASCII UTF-16 looks like and what separators never do.
/// Localized UTF-16 hardly ever passes for valid UTF-8 in the first place.
bool looksLikeUtf16Le(List<int> bytes) {
  if (bytes.length < 2) return false;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) return true;

  var odd = 0;
  var even = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != 0) continue;
    if (i.isOdd) {
      odd++;
    } else {
      even++;
    }
  }
  if (odd == 0 || odd <= even) return false;
  if (!_isValidUtf8(bytes)) return true;
  return odd * 2 >= bytes.length ~/ 2;
}

bool _isValidUtf8(List<int> bytes) {
  try {
    const Utf8Decoder().convert(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// [bytes] as UTF-16LE, or null when they are not well-formed UTF-16 — an
/// unpaired surrogate means the guess was wrong and the caller should fall
/// back rather than show the result.
///
/// A trailing odd byte is dropped: it is half a code unit, which is what a
/// read that stopped mid-character leaves behind.
String? _decodeUtf16Le(List<int> bytes) {
  var start = 0;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) start = 2;

  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] & 0xFF) | ((bytes[i + 1] & 0xFF) << 8));
  }

  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next < 0xDC00 || next > 0xDFFF) return null;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return null;
    }
  }
  return String.fromCharCodes(units);
}
