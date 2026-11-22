import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads the live Microsoft Store listing for WSL Manager and reports what is
/// actually published: screenshots, logos, features, description and the
/// "What's new in this version" notes.
///
/// Partner Center shows the draft; this shows what a customer sees, so a
/// submission that never left the draft state — or a listing asset that was
/// edited but not submitted — is visible without signing in anywhere.
///
///   dart run scripts/check_store_listing.dart
///   dart run scripts/check_store_listing.dart --min-screenshots 8 \
///       --expect-notes "WSL Manager 2.0"
const String defaultProductId = '9NWS9K95NMJB';
const String storefrontHost = 'storeedgefd.dsx.mp.microsoft.com';

/// One image slot of a listing (screenshot, logo, BoxArt, Poster, ...).
class StoreImage {
  StoreImage({
    required this.imageType,
    required this.width,
    required this.height,
    required this.url,
  });

  final String imageType;
  final int width;
  final int height;
  final String url;
}

/// The published state of a Store listing.
class StoreListing {
  StoreListing({
    required this.productId,
    required this.title,
    required this.publisherName,
    required this.lastUpdate,
    required this.shortDescription,
    required this.description,
    required this.features,
    required this.images,
    required this.releaseNotes,
  });

  final String productId;
  final String title;
  final String publisherName;
  final DateTime? lastUpdate;
  final String shortDescription;
  final String description;
  final List<String> features;
  final List<StoreImage> images;
  final List<String> releaseNotes;

  List<StoreImage> imagesOfType(String imageType) => images
      .where(
          (image) => image.imageType.toLowerCase() == imageType.toLowerCase())
      .toList();

  List<StoreImage> get screenshots => imagesOfType('screenshot');

  List<StoreImage> get logos => imagesOfType('logo');
}

/// What a healthy listing has to look like.
class ListingExpectations {
  const ListingExpectations({
    this.minScreenshots = 1,
    this.minLogos = 1,
    this.minFeatures = 1,
    this.expectNotes,
  });

  final int minScreenshots;
  final int minLogos;
  final int minFeatures;

  /// Substring the release notes must contain, e.g. the version being shipped.
  /// Stale "What's new" text is the usual sign of a submission that never went
  /// out, so this is the cheapest way to catch it.
  final String? expectNotes;
}

/// Turns the decoded storefront response into a [StoreListing].
///
/// The response is a list of envelopes; only one of them carries the product.
StoreListing parseStoreListing(Object? decoded) {
  if (decoded is! List) {
    throw const FormatException('Storefront response is not a list');
  }

  for (final entry in decoded) {
    if (entry is! Map) {
      continue;
    }
    final payload = entry['Payload'];
    if (payload is! Map || payload['ProductId'] is! String) {
      continue;
    }

    return StoreListing(
      productId: payload['ProductId'] as String,
      title: _asString(payload['Title']),
      publisherName: _asString(payload['PublisherName']),
      lastUpdate: DateTime.tryParse(_asString(payload['LastUpdateDateUtc'])),
      shortDescription: _asString(payload['ShortDescription']),
      description: _asString(payload['Description']),
      features: _asStringList(payload['Features']),
      images: _parseImages(payload['Images']),
      releaseNotes: _asStringList(payload['Notes']),
    );
  }

  throw const FormatException(
      'Storefront response contains no product payload');
}

/// Lists everything wrong with [listing], newest-submission problems first.
/// An empty list means the listing looks published and complete.
List<String> evaluateListing(
  StoreListing listing,
  ListingExpectations expectations,
) {
  final problems = <String>[];

  final screenshots = listing.screenshots.length;
  if (screenshots < expectations.minScreenshots) {
    problems.add('Only $screenshots screenshot(s) live, '
        'expected at least ${expectations.minScreenshots}');
  }

  final logos = listing.logos.length;
  if (logos < expectations.minLogos) {
    problems.add('Only $logos logo(s) live, '
        'expected at least ${expectations.minLogos}');
  }

  final features = listing.features.length;
  if (features < expectations.minFeatures) {
    problems.add('Only $features feature bullet(s) live, '
        'expected at least ${expectations.minFeatures}');
  }

  if (listing.shortDescription.isEmpty) {
    problems.add('Short description is empty');
  }

  if (listing.description.isEmpty) {
    problems.add('Description is empty');
  }

  if (listing.releaseNotes.isEmpty) {
    problems.add('"What\'s new in this version" is empty');
  }

  final expectNotes = expectations.expectNotes;
  if (expectNotes != null && expectNotes.isNotEmpty) {
    final matched = listing.releaseNotes.any(
      (note) => note.toLowerCase().contains(expectNotes.toLowerCase()),
    );
    if (!matched) {
      problems.add('"What\'s new in this version" does not mention '
          '"$expectNotes" — the live listing is probably an older submission');
    }
  }

  return problems;
}

/// Reads the `--min-screenshots` threshold, defaulting to 1 when it is absent.
///
/// Returns null for anything that is not a non-negative whole number, so a
/// typo fails the run instead of quietly turning the check into a no-op.
int? parseMinScreenshots(String? raw) {
  if (raw == null) {
    return 1;
  }

  final value = int.tryParse(raw);
  if (value == null || value < 0) {
    return null;
  }
  return value;
}

/// The storefront endpoint that serves the public product detail page.
Uri buildListingUri({
  required String productId,
  required String market,
  required String locale,
}) {
  return Uri.https(storefrontHost, '/v9.0/pages/pdp', <String, String>{
    'productId': productId,
    'market': market,
    'locale': locale,
    'deviceFamily': 'Windows.Desktop',
  });
}

Future<void> main(List<String> arguments) async {
  final Map<String, String> options;
  try {
    options = _parseArguments(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Usage: dart run scripts/check_store_listing.dart '
        '[--product-id ID] [--market US] [--locale en-US] '
        '[--min-screenshots N] [--expect-notes TEXT]');
    exitCode = 2;
    return;
  }

  final uri = buildListingUri(
    productId: options['product-id'] ?? defaultProductId,
    market: options['market'] ?? 'US',
    locale: options['locale'] ?? 'en-US',
  );

  final rawMinScreenshots = options['min-screenshots'];
  final minScreenshots = parseMinScreenshots(rawMinScreenshots);
  if (minScreenshots == null) {
    stderr.writeln('--min-screenshots must be a non-negative whole number, '
        'got "$rawMinScreenshots"');
    exitCode = 2;
    return;
  }

  final expectations = ListingExpectations(
    minScreenshots: minScreenshots,
    expectNotes: options['expect-notes'],
  );

  final String body;
  try {
    body = await _fetch(uri).timeout(requestTimeout);
  } on Exception catch (error) {
    stderr.writeln('Could not reach the Store: $error');
    exitCode = 1;
    return;
  }

  final StoreListing listing;
  try {
    listing = parseStoreListing(jsonDecode(body));
  } on FormatException catch (error) {
    stderr.writeln('Could not read the Store response: ${error.message}');
    exitCode = 1;
    return;
  }

  stdout.writeln(describeListing(listing));

  final problems = evaluateListing(listing, expectations);
  if (problems.isEmpty) {
    return;
  }

  stderr.writeln('');
  stderr.writeln('The live listing is not what it should be:');
  for (final problem in problems) {
    stderr.writeln('  - $problem');
  }
  exitCode = 1;
}

/// Human-readable summary of what is live right now.
String describeListing(StoreListing listing) {
  final buffer = StringBuffer()
    ..writeln('${listing.title} (${listing.productId}) '
        'by ${listing.publisherName}')
    ..writeln('Listing last updated: '
        '${listing.lastUpdate?.toUtc().toIso8601String() ?? 'unknown'}')
    ..writeln('Screenshots: ${listing.screenshots.length}')
    ..writeln('Logos: ${listing.logos.length}')
    ..writeln('Feature bullets: ${listing.features.length}')
    ..writeln('Short description: ${listing.shortDescription.length} chars')
    ..writeln('Description: ${listing.description.length} chars');

  for (final screenshot in listing.screenshots) {
    buffer.writeln('  screenshot ${screenshot.width}x${screenshot.height} '
        '${screenshot.url}');
  }

  if (listing.releaseNotes.isEmpty) {
    buffer.writeln("What's new: (empty)");
  } else {
    buffer.writeln("What's new:");
    for (final note in listing.releaseNotes) {
      for (final line in const LineSplitter().convert(note)) {
        buffer.writeln('  $line');
      }
    }
  }

  return buffer.toString().trimRight();
}

List<StoreImage> _parseImages(Object? value) {
  if (value is! List) {
    return const <StoreImage>[];
  }

  final images = <StoreImage>[];
  for (final entry in value) {
    if (entry is! Map) {
      continue;
    }
    images.add(StoreImage(
      imageType: _asString(entry['ImageType']),
      width: _asInt(entry['Width']),
      height: _asInt(entry['Height']),
      url: _normaliseUrl(_asString(entry['Url'])),
    ));
  }
  return images;
}

/// Some slots come back protocol-relative (`//store-images...`).
String _normaliseUrl(String url) => url.startsWith('//') ? 'https:$url' : url;

String _asString(Object? value) => value is String ? value : '';

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}

List<String> _asStringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.whereType<String>().where((item) => item.isNotEmpty).toList();
}

Map<String, String> _parseArguments(List<String> arguments) {
  const knownFlags = <String>{
    'product-id',
    'market',
    'locale',
    'min-screenshots',
    'expect-notes',
  };

  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) {
      throw FormatException('Unexpected argument: $argument');
    }

    final name = argument.substring(2);
    if (!knownFlags.contains(name)) {
      throw FormatException('Unknown option: $argument');
    }
    if (index + 1 >= arguments.length) {
      throw FormatException('Missing value for $argument');
    }

    options[name] = arguments[++index];
  }
  return options;
}

/// How long the whole request may take before the check gives up. A storefront
/// that accepts the connection and then goes quiet must not hang a release
/// check forever.
const Duration requestTimeout = Duration(seconds: 30);

Future<String> _fetch(Uri uri) async {
  final client = HttpClient()..connectionTimeout = requestTimeout;
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return body;
  } on TimeoutException {
    throw HttpException('timed out after ${requestTimeout.inSeconds}s',
        uri: uri);
  } finally {
    client.close(force: true);
  }
}
