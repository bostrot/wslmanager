import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/updater.dart';
import 'package:wsl2distromanager/components/constants.dart';

// The GitHub repository is bostrot/wslmanager (renamed from
// wsl2-distro-manager). Every address the app opens or fetches from it has
// to name the new repository: the old one only keeps working through
// GitHub's redirect, and a link pasted into a support reply should not point
// at a name that no longer exists.
void main() {
  const repo = 'bostrot/wslmanager';

  final links = <String, String>{
    'updateUrl': updateUrl,
    'motdUrl': motdUrl,
    'gitRepoRawLink': gitRepoRawLink,
    'githubIssues': githubIssues,
    'wikiDocker': wikiDocker,
    'releasesPageUrl': releasesPageUrl,
  };

  for (final entry in links.entries) {
    test('${entry.key} names the renamed repository', () {
      expect(entry.value, contains('/$repo/'),
          reason: '${entry.key} should live under $repo');
      expect(entry.value, isNot(contains('wsl2-distro-manager')),
          reason: '${entry.key} still uses the pre-rename repository name');
    });
  }

  test('the update feed is the releases endpoint of the renamed repository',
      () {
    expect(updateUrl, 'https://api.github.com/repos/$repo/releases');
  });

  test('the fallback images.json is fetched from the renamed repository', () {
    expect(gitRepoRawLink,
        'https://raw.githubusercontent.com/$repo/main/images.json');
  });
}
