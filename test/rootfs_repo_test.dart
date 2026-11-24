import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/rootfs_repo.dart';

void main() {
  const repo = 'https://mirror.example.org/images/';

  group('parseRootfsListing', () {
    test('reads the mirror.turnkeylinux.org table listing', () {
      // Two rows as the mirror serves them on 2026-11-24, hash files and all.
      const html = '''
<tr><td><a href="debian-11-turnkey-ansible_17.1-1_amd64.tar.gz">debian-11-turnkey-ansible_17.1-1_amd64.tar.gz</a></td><td>2026-09-03 02:05 UTC</td></tr>
<tr><td><a href="debian-11-turnkey-ansible_17.1-1_amd64.tar.gz.hash">debian-11-turnkey-ansible_17.1-1_amd64.tar.gz.hash</a></td></tr>
<tr><td><a href="debian-12-turnkey-core_18.0-1_amd64.tar.gz">debian-12-turnkey-core_18.0-1_amd64.tar.gz</a></td></tr>
''';
      expect(parseRootfsListing(html, repo), {
        'Debian 11 Turnkey Ansible 17.1 ':
            '${repo}debian-11-turnkey-ansible_17.1-1_amd64.tar.gz',
        'Debian 12 Turnkey Core 18.0 ':
            '${repo}debian-12-turnkey-core_18.0-1_amd64.tar.gz',
      });
    });

    test('reads single-quoted and unquoted links', () {
      const html = "<a href='alpine_amd64.tar.gz'>a</a>\n"
          '<a HREF=void_amd64.tar.gz>v</a>';
      expect(parseRootfsListing(html, repo).values, [
        '${repo}alpine_amd64.tar.gz',
        '${repo}void_amd64.tar.gz',
      ]);
    });

    test('resolves absolute paths and full URLs instead of prefixing them', () {
      const html = '<a href="/other/a_amd64.tar.gz">a</a>'
          '<a href="https://cdn.example.net/b_amd64.tar.gz">b</a>';
      expect(parseRootfsListing(html, repo).values, [
        'https://mirror.example.org/other/a_amd64.tar.gz',
        'https://cdn.example.net/b_amd64.tar.gz',
      ]);
    });

    test('reads every link on a line, not just the first', () {
      const html = '<a href="a_amd64.tar.gz">a</a> <a href="b_amd64.tar.gz">b'
          '</a>';
      expect(parseRootfsListing(html, repo), hasLength(2));
    });

    test('treats a repo without a trailing slash as a directory', () {
      expect(
          parseRootfsListing(
                  '<a href="a_amd64.tar.gz">', 'https://mirror.example.org/x')
              .values,
          ['https://mirror.example.org/x/a_amd64.tar.gz']);
    });

    test('names a percent-encoded file by its decoded name', () {
      expect(parseRootfsListing('<a href="my%20box.tar.gz">', repo),
          {'My Box': '${repo}my%20box.tar.gz'});
    });

    test('ignores other files, sort links and an unparsable repo', () {
      const html = '<a href="?C=N;O=D">Name</a><a href="../">Parent</a>'
          '<a href="notes.txt">n</a><a href="a.tar.xz">x</a>';
      expect(parseRootfsListing(html, repo), isEmpty);
      expect(parseRootfsListing('<a href="a.tar.gz">', 'http://[::1'), isEmpty);
    });
  });

  group('rootfsRepoLink', () {
    test('falls back to the TurnKey mirror when nothing is set', () {
      expect(rootfsRepoLink(null), turnkeyRepoLink);
      expect(rootfsRepoLink('  '), turnkeyRepoLink);
    });

    test('replaces the retired RWTH Aachen default', () {
      for (final dead in retiredRepoLinks) {
        expect(rootfsRepoLink(dead), turnkeyRepoLink);
      }
    });

    test('keeps a link the user chose', () {
      expect(rootfsRepoLink(' $repo '), repo);
    });
  });
}
