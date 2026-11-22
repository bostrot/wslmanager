import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';
import 'package:wsl2distromanager/api/layer_processor.dart';

void main() {
  late Directory tempDir;
  late LayerProcessor processor;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('layer_processor_test');
    processor = LayerProcessor();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> createTar(String path, Map<String, String> entries) async {
    final file = File(path);
    final sink = file.openWrite();

    final stream = Stream.fromIterable(entries.entries.map((e) {
      return TarEntry.data(
        TarHeader(
          name: e.key,
          mode: int.parse('644', radix: 8),
        ),
        e.value.codeUnits,
      );
    }));

    await stream
        .cast<TarEntry>()
        .transform(tarWriter)
        .transform(gzip.encoder)
        .pipe(sink);
  }

  /// The same layer, written without gzip — the shape `docker save` produces.
  Future<void> createPlainTar(String path, Map<String, String> entries) async {
    final stream = Stream.fromIterable(entries.entries.map((e) {
      return TarEntry.data(
        TarHeader(name: e.key, mode: int.parse('644', radix: 8)),
        e.value.codeUnits,
      );
    }));

    await stream
        .cast<TarEntry>()
        .transform(tarWriter)
        .pipe(File(path).openWrite());
  }

  Future<Map<String, String>> readTar(String path) async {
    final file = File(path);
    final reader = TarReader(file.openRead().transform(gzip.decoder));
    final result = <String, String>{};

    while (await reader.moveNext()) {
      final entry = reader.current;
      final content =
          await entry.contents.transform(SystemEncoding().decoder).join();
      result[entry.name] = content;
    }
    await reader.cancel();
    return result;
  }

  test('merges uncompressed layers, as docker save writes them', () async {
    // Every layer used to be piped through gzip.decoder, so a plain
    // `layer.tar` failed the merge with "FormatException: Filter error, bad
    // data" — which made importing from a local Docker image impossible.
    final layer1Path = p.join(tempDir.path, 'layer_0.tar');
    final layer2Path = p.join(tempDir.path, 'layer_1.tar');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createPlainTar(layer1Path, {'etc/hostname': 'base', 'etc/keep': 'k'});
    await createPlainTar(layer2Path, {'etc/hostname': 'top'});

    await processor.mergeLayers([layer1Path, layer2Path], outputPath, (_) {});

    final result = await readTar(outputPath);
    expect(result['etc/hostname'], 'top');
    expect(result['etc/keep'], 'k');
  });

  test('merges a mix of compressed and uncompressed layers', () async {
    final gzipped = p.join(tempDir.path, 'layer_0.tar.gz');
    final plain = p.join(tempDir.path, 'layer_1.tar');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(gzipped, {'a.txt': 'from gzip'});
    await createPlainTar(plain, {'b.txt': 'from plain'});

    await processor.mergeLayers([gzipped, plain], outputPath, (_) {});

    final result = await readTar(outputPath);
    expect(result['a.txt'], 'from gzip');
    expect(result['b.txt'], 'from plain');
  });

  test('applies a whiteout carried by an uncompressed layer', () async {
    final layer1Path = p.join(tempDir.path, 'layer_0.tar');
    final layer2Path = p.join(tempDir.path, 'layer_1.tar');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createPlainTar(layer1Path, {'etc/gone': 'x', 'etc/stays': 'y'});
    await createPlainTar(layer2Path, {'etc/.wh.gone': ''});

    await processor.mergeLayers([layer1Path, layer2Path], outputPath, (_) {});

    final result = await readTar(outputPath);
    expect(result.containsKey('etc/gone'), isFalse);
    expect(result['etc/stays'], 'y');
  });

  test('merges simple layers', () async {
    final layer1Path = p.join(tempDir.path, 'layer1.tar.gz');
    final layer2Path = p.join(tempDir.path, 'layer2.tar.gz');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(layer1Path, {'file1.txt': 'content1'});
    await createTar(layer2Path, {'file2.txt': 'content2'});

    await processor.mergeLayers(
      [layer1Path, layer2Path],
      outputPath,
      (_) {},
    );

    final result = await readTar(outputPath);
    expect(result, hasLength(2));
    expect(result['file1.txt'], 'content1');
    expect(result['file2.txt'], 'content2');
  });

  test('upper layer overwrites lower layer', () async {
    final layer1Path = p.join(tempDir.path, 'layer1.tar.gz');
    final layer2Path = p.join(tempDir.path, 'layer2.tar.gz');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(layer1Path, {'file1.txt': 'v1'});
    await createTar(layer2Path, {'file1.txt': 'v2'});

    await processor.mergeLayers(
      [layer1Path, layer2Path],
      outputPath,
      (_) {},
    );

    final result = await readTar(outputPath);
    expect(result, hasLength(1));
    expect(result['file1.txt'], 'v2');
  });

  test('handles whiteout files', () async {
    final layer1Path = p.join(tempDir.path, 'layer1.tar.gz');
    final layer2Path = p.join(tempDir.path, 'layer2.tar.gz');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(layer1Path, {
      'keep.txt': 'keep',
      'delete.txt': 'delete',
    });
    await createTar(layer2Path, {
      '.wh.delete.txt': '',
    });

    await processor.mergeLayers(
      [layer1Path, layer2Path],
      outputPath,
      (_) {},
    );

    final result = await readTar(outputPath);
    expect(result, hasLength(1));
    expect(result['keep.txt'], 'keep');
    expect(result.containsKey('delete.txt'), isFalse);
    expect(result.containsKey('.wh.delete.txt'), isFalse);
  });

  test('handles opaque directories', () async {
    final layer1Path = p.join(tempDir.path, 'layer1.tar.gz');
    final layer2Path = p.join(tempDir.path, 'layer2.tar.gz');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(layer1Path, {
      'dir/file1.txt': 'v1',
      'dir/file2.txt': 'v1',
      'other/file3.txt': 'v1',
    });
    await createTar(layer2Path, {
      'dir/.wh..wh..opq': '',
      'dir/file1.txt': 'v2',
    });

    await processor.mergeLayers(
      [layer1Path, layer2Path],
      outputPath,
      (_) {},
    );

    final result = await readTar(outputPath);
    expect(result.containsKey('other/file3.txt'), isTrue);
    expect(result['dir/file1.txt'], 'v2');
    expect(result.containsKey('dir/file2.txt'), isFalse);
    expect(result.containsKey('dir/.wh..wh..opq'), isFalse);
  });

  test('reports progress', () async {
    final layer1Path = p.join(tempDir.path, 'layer1.tar.gz');
    final layer2Path = p.join(tempDir.path, 'layer2.tar.gz');
    final outputPath = p.join(tempDir.path, 'output.tar.gz');

    await createTar(layer1Path, {'file1.txt': 'content1'});
    await createTar(layer2Path, {'file2.txt': 'content2'});

    final messages = <String>[];
    await processor.mergeLayers(
      [layer1Path, layer2Path],
      outputPath,
      (msg) => messages.add(msg),
    );

    expect(messages, contains('Scanning layers...'));
    expect(messages, contains('Scanning layer 1/2...'));
    expect(messages, contains('Scanning layer 2/2...'));
    expect(messages, contains('Writing rootfs...'));
    expect(messages, contains('Merging layer 1/2...'));
    expect(messages, contains('Merging layer 2/2...'));
  });
}
