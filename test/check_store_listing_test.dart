import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/check_store_listing.dart';

/// Shaped like the storefront response: a list of envelopes where only one
/// carries the product payload.
String storefrontResponse({
  int screenshots = 8,
  int logos = 3,
  List<String> features = const <String>['Move distros between drives'],
  List<String> notes = const <String>['WSL Manager 2.0\n- AI Workspace'],
  String shortDescription = 'The WSL front end that does what free ones do not',
  String description = 'Every WSL front end can start and stop a distro.',
}) {
  final images = <Map<String, Object?>>[
    for (var index = 0; index < logos; index++)
      <String, Object?>{
        'ImageType': 'logo',
        'Width': 150,
        'Height': 150,
        'Url': 'https://store-images.example/logo$index',
      },
    for (var index = 0; index < screenshots; index++)
      <String, Object?>{
        'ImageType': 'screenshot',
        'Width': 1384,
        'Height': 851,
        'Url': '//store-images.example/shot$index',
      },
  ];

  return jsonEncode(<Object?>[
    <String, Object?>{'Path': '/pages/pdp', 'Payload': <String, Object?>{}},
    <String, Object?>{'Payload': 'not-a-map'},
    <String, Object?>{
      'Payload': <String, Object?>{
        'ProductId': '9NWS9K95NMJB',
        'Title': 'WSL Manager',
        'PublisherName': 'Bostrot',
        'LastUpdateDateUtc': '2026-09-06T19:54:41Z',
        'ShortDescription': shortDescription,
        'Description': description,
        'Features': features,
        'Images': images,
        'Notes': notes,
      },
    },
  ]);
}

void main() {
  group('parseStoreListing', () {
    test('reads the product payload out of the envelope list', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));

      expect(listing.productId, '9NWS9K95NMJB');
      expect(listing.title, 'WSL Manager');
      expect(listing.publisherName, 'Bostrot');
      expect(listing.lastUpdate, DateTime.utc(2026, 9, 6, 19, 54, 41));
      expect(listing.screenshots, hasLength(8));
      expect(listing.logos, hasLength(3));
      expect(listing.features, hasLength(1));
      expect(listing.releaseNotes.single, contains('WSL Manager 2.0'));
    });

    test('makes protocol-relative image urls absolute', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));

      expect(
          listing.screenshots.first.url, 'https://store-images.example/shot0');
      expect(listing.logos.first.url, 'https://store-images.example/logo0');
    });

    test('keeps screenshot dimensions', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));
      final screenshot = listing.screenshots.first;

      expect(screenshot.width, 1384);
      expect(screenshot.height, 851);
    });

    test('tolerates missing and mistyped fields', () {
      final listing = parseStoreListing(<Object?>[
        <String, Object?>{
          'Payload': <String, Object?>{
            'ProductId': '9NWS9K95NMJB',
            'Title': 42,
            'Features': <Object?>['Real bullet', 7, ''],
            'Images': 'not-a-list',
            'LastUpdateDateUtc': 'never',
          },
        },
      ]);

      expect(listing.title, '');
      expect(listing.features, <String>['Real bullet']);
      expect(listing.images, isEmpty);
      expect(listing.lastUpdate, isNull);
    });

    test('throws when no envelope carries a product', () {
      expect(
        () => parseStoreListing(<Object?>[
          <String, Object?>{'Payload': <String, Object?>{}}
        ]),
        throwsFormatException,
      );
    });

    test('throws when the response is not a list', () {
      expect(
        () => parseStoreListing(
            <String, Object?>{'Payload': <String, Object?>{}}),
        throwsFormatException,
      );
    });
  });

  group('evaluateListing', () {
    test('accepts a fully published listing', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));

      final problems = evaluateListing(
        listing,
        const ListingExpectations(
          minScreenshots: 8,
          minFeatures: 1,
          expectNotes: 'WSL Manager 2.0',
        ),
      );

      expect(problems, isEmpty);
    });

    test('reports a listing still serving fewer screenshots than the draft',
        () {
      final listing =
          parseStoreListing(jsonDecode(storefrontResponse(screenshots: 3)));

      final problems = evaluateListing(
        listing,
        const ListingExpectations(minScreenshots: 8),
      );

      expect(problems, hasLength(1));
      expect(problems.single, contains('Only 3 screenshot(s) live'));
    });

    test('reports stale release notes as a probable unsubmitted draft', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse(
        notes: <String>['Fixed window not closing on exit'],
      )));

      final problems = evaluateListing(
        listing,
        const ListingExpectations(expectNotes: 'WSL Manager 2.0'),
      );

      expect(problems.single, contains('does not mention "WSL Manager 2.0"'));
    });

    test('matches expected release notes case-insensitively', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));

      final problems = evaluateListing(
        listing,
        const ListingExpectations(expectNotes: 'wsl manager 2.0'),
      );

      expect(problems, isEmpty);
    });

    test('reports every empty listing field at once', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse(
        screenshots: 0,
        logos: 0,
        features: <String>[],
        notes: <String>[],
        shortDescription: '',
        description: '',
      )));

      final problems = evaluateListing(listing, const ListingExpectations());

      expect(problems, hasLength(6));
      expect(problems.join('\n'), contains('Short description is empty'));
      expect(problems.join('\n'), contains('Description is empty'));
      expect(problems.join('\n'), contains("What's new in this version"));
    });
  });

  group('parseMinScreenshots', () {
    test('defaults to 1 when the flag is absent', () {
      expect(parseMinScreenshots(null), 1);
    });

    test('reads a threshold', () {
      expect(parseMinScreenshots('8'), 8);
      expect(parseMinScreenshots('0'), 0);
    });

    test('rejects a typo instead of quietly falling back', () {
      expect(parseMinScreenshots('eight'), isNull);
      expect(parseMinScreenshots(''), isNull);
      expect(parseMinScreenshots('8.5'), isNull);
    });

    test('rejects a negative threshold', () {
      expect(parseMinScreenshots('-1'), isNull);
    });
  });

  group('buildListingUri', () {
    test('targets the public storefront product detail endpoint', () {
      final uri = buildListingUri(
        productId: defaultProductId,
        market: 'US',
        locale: 'en-US',
      );

      expect(uri.host, storefrontHost);
      expect(uri.path, '/v9.0/pages/pdp');
      expect(uri.queryParameters['productId'], '9NWS9K95NMJB');
      expect(uri.queryParameters['deviceFamily'], 'Windows.Desktop');
    });
  });

  group('describeListing', () {
    test('summarises what a customer sees', () {
      final listing = parseStoreListing(jsonDecode(storefrontResponse()));

      final report = describeListing(listing);

      expect(report, contains('WSL Manager (9NWS9K95NMJB) by Bostrot'));
      expect(report, contains('Screenshots: 8'));
      expect(report, contains('2026-09-06T19:54:41.000Z'));
      expect(report, contains('screenshot 1384x851'));
      expect(report, contains('WSL Manager 2.0'));
    });

    test('says so when there are no release notes', () {
      final listing =
          parseStoreListing(jsonDecode(storefrontResponse(notes: <String>[])));

      expect(describeListing(listing), contains("What's new: (empty)"));
    });
  });
}
