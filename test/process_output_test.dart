import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/process_output.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';

/// [text] the way wsl.exe writes it to a pipe.
List<int> utf16le(String text) =>
    text.codeUnits.expand((unit) => [unit & 0xFF, unit >> 8]).toList();

void main() {
  // The two messages from bostrot/wslmanager#322, as a Simplified Chinese
  // Windows prints them.
  const updateFailure = '正在检查更新。\r\n'
      '禁止访问(403)。\r\n'
      '错误代码: Wsl/UpdatePackage/HTTP_E_STATUS_FORBIDDEN\r\n';
  const sparseFailure = '无法在该 VHD 当前正在使用时进行此操作: wsl.exe --shutdown\r\n'
      '错误代码: Wsl/Service/ERROR_SHARING_VIOLATION\r\n';

  group('decodeProcessOutput', () {
    test('reads a localized wsl.exe message as UTF-16LE', () {
      expect(decodeProcessOutput(utf16le(updateFailure)), updateFailure);
      expect(decodeProcessOutput(utf16le(sparseFailure)), sparseFailure);
    });

    test('the old decode is what the issue shows', () {
      // Guards the premise: UTF-8 with the NULs dropped turns 正在 into ck(W.
      final old = const Utf8Decoder(allowMalformed: true)
          .convert(utf16le('正在'))
          .replaceAll('\u0000', '');
      expect(old, 'ck(W');
    });

    test('still reads ASCII UTF-16LE', () {
      expect(decodeProcessOutput(utf16le('WSL version: 2.5.9.0\r\n')),
          'WSL version: 2.5.9.0\r\n');
    });

    test('keeps a code unit whose low byte is zero', () {
      // 一 is 00 4E on the wire: a NUL on an even offset.
      const text = '一共 1 个\r\n';
      expect(decodeProcessOutput(utf16le(text)), text);
    });

    test('other scripts and surrogate pairs survive', () {
      const text = 'Ошибка: путь не найден 😀\r\n';
      expect(decodeProcessOutput(utf16le(text)), text);
    });

    test('honours and drops a byte-order mark', () {
      expect(decodeProcessOutput([0xFF, 0xFE, ...utf16le('错误')]), '错误');
    });

    test('leaves UTF-8 from inside a distro alone', () {
      const text = '错误: 路径无效\nGrüße, 世界\n';
      expect(decodeProcessOutput(utf8.encode(text)), text);
    });

    test('NUL-separated UTF-8 is not mistaken for UTF-16', () {
      // /proc/<pid>/cmdline: the first separator sits on an odd offset.
      final bytes = utf8.encode('/sbin/init\u0000--splash\u0000quiet\u0000');
      expect(looksLikeUtf16Le(bytes), isFalse);
      expect(decodeProcessOutput(bytes).replaceAll('\u0000', ' '),
          '/sbin/init --splash quiet ');
    });

    test('a read that stopped mid-character loses only that character', () {
      final bytes = utf16le('错误代码: 5\r\n')..removeLast();
      expect(decodeProcessOutput(bytes), '错误代码: 5\r');
    });

    test('malformed input degrades instead of throwing', () {
      expect(decodeProcessOutput([]), '');
      expect(decodeProcessOutput([0x41]), 'A');
      expect(decodeProcessOutput([0x61, 0xFF, 0x62]), 'a�b');
      // An unpaired surrogate: not UTF-16 after all, so fall back.
      expect(() => decodeProcessOutput([0x41, 0x00, 0x00, 0xD8]),
          returnsNormally);
    });
  });

  test('the broker decodes localized wsl.exe output', () {
    expect(ExecutionBroker.decodeWslOutput(utf16le(sparseFailure)),
        sparseFailure);
    expect(ExecutionBroker.decodeWslOutput(utf8.encode('错误\n')), '错误\n');
  });

  test('a failure built from raw bytes keeps the localized text', () {
    final failure = WslFailure.fromStreams(null, utf16le(updateFailure));
    expect(failure.details, contains('禁止访问(403)。'));
    expect(failure.code, 'Wsl/UpdatePackage/HTTP_E_STATUS_FORBIDDEN');
  });
}
