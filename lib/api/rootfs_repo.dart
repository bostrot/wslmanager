// The "TurnKey Linux" create source: a plain directory listing of root
// filesystem tarballs, read straight off a mirror's index page.

/// The listing the TurnKey Linux source reads when Settings names no other.
///
/// TurnKey's own mirror. The RWTH Aachen copy the app shipped with stopped
/// carrying `turnkeylinux/` in 2026 and has answered 404 since, which left
/// the source with an empty list and no explanation.
const String turnkeyRepoLink =
    'https://mirror.turnkeylinux.org/turnkeylinux/images/proxmox/';

/// Defaults earlier versions shipped and that no longer serve a listing.
///
/// Settings used to save the placeholder as if the user had typed it (audit
/// ST-26), so a stored value equal to one of these is the old default, not a
/// choice, and is read as "nothing set".
const Set<String> retiredRepoLinks = {
  'http://ftp.halifax.rwth-aachen.de/turnkeylinux/images/proxmox/',
};

/// The listing to read for the stored `RepoLink` preference [stored].
String rootfsRepoLink(String? stored) {
  final link = stored?.trim() ?? '';
  if (link.isEmpty || retiredRepoLinks.contains(link)) return turnkeyRepoLink;
  return link;
}

final RegExp _href = RegExp(r'''href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false);

/// The `.tar.gz` files linked from the directory listing [html], served at
/// [repo], as display name → absolute download URL.
///
/// Links are resolved the way a browser resolves them, so a listing that
/// links by absolute path or full URL works as well as one that links by
/// bare file name; single-quoted and unquoted attributes count as well as
/// double-quoted ones. [repo] is taken to be a directory even without its
/// trailing slash, which is how people paste it.
Map<String, String> parseRootfsListing(String html, String repo) {
  final result = <String, String>{};
  final Uri base;
  try {
    base = Uri.parse(repo.endsWith('/') ? repo : '$repo/');
  } on FormatException {
    return result;
  }
  for (final match in _href.allMatches(html)) {
    final raw = (match[1] ?? match[2] ?? match[3] ?? '')
        .replaceAll('&amp;', '&')
        .trim();
    final Uri url;
    try {
      url = base.resolve(raw);
    } on FormatException {
      continue;
    }
    if (!url.path.endsWith('.tar.gz')) continue;
    final filename = url.pathSegments.last;
    result.putIfAbsent(rootfsDisplayName(filename), () => url.toString());
  }
  return result;
}

/// The name a scraped [filename] is listed under, e.g.
/// `debian-12-turnkey-core_18.0-1_amd64.tar.gz` → `Debian 12 Turnkey Core 18.0 `.
///
/// Unchanged from the first scraper on purpose: the name is also the file
/// a download is cached under, so a new spelling would re-download every
/// image a user already has.
String rootfsDisplayName(String filename) => filename
    .replaceAll('.tar.gz', '')
    .replaceAll('1_amd64', '')
    .replaceAll(RegExp(r'-|_'), ' ')
    .replaceAllMapped(
        RegExp(r' .|^.'), (Match m) => m[0].toString().toUpperCase());
