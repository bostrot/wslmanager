import 'dart:convert';

/// The system summary a VM's terminal opens with on macOS.
///
/// The app does not print the banner itself. It installs a small profile
/// snippet inside the guest, so every way into that machine shows the same
/// thing: the SSH session behind the terminal button, the serial console, and
/// the login prompt in the display window a start opens. A banner printed by
/// the host would only ever appear on one of those three.
///
/// [fastfetchCommand] is what the snippet prefers; a guest without it falls
/// back to `neofetch` and then to a two-line summary built from `uname`, so a
/// terminal always says which machine it landed on even when nothing is
/// installed. The installer also tries, once and in the background, to fetch
/// fastfetch through whatever package manager the guest has.
class GuestGreeting {
  GuestGreeting._();

  /// Bumped whenever [snippet] changes: a guest carrying an older version is
  /// reinstalled instead of being left with a stale banner.
  static const int version = 1;

  /// Where the snippet lives in the guest. The `99-` prefix keeps it last, so
  /// the summary is the final thing a login prints.
  static const String path = '/etc/profile.d/99-wslmanager-greeting.sh';

  /// The tool the greeting is built around.
  static const String fastfetchCommand = 'fastfetch';

  /// Preference key holding the [version] installed in a given instance.
  static String prefKey(String instance) => 'GuestGreeting_$instance';

  /// Preference key for the feature as a whole. Unset means on.
  static const String enabledPrefKey = 'VmGreeting';

  /// The profile snippet itself.
  ///
  /// Guarded three ways, because `/etc/profile` is read by more than the
  /// terminal a person is looking at: only interactive shells print anything,
  /// only the first one in a session does, and neither `return` nor `exit`
  /// appears anywhere — a sourced file that exits would take a non-interactive
  /// login shell (`sh -lc …`, which some tooling uses) down with it.
  static const String snippet = '''
# WSL Manager guest greeting v$version — installed by WSL Manager.
# Delete this file, or turn the setting off in the app, to stop it.
if [ -z "\${WSLMANAGER_GREETING_SHOWN:-}" ]; then
  case \$- in
    *i*)
      WSLMANAGER_GREETING_SHOWN=1
      export WSLMANAGER_GREETING_SHOWN
      if command -v $fastfetchCommand >/dev/null 2>&1; then
        $fastfetchCommand
      elif command -v neofetch >/dev/null 2>&1; then
        neofetch
      else
        printf '%s (%s)\\n' "\$(uname -n)" "\$(uname -srm)"
        uptime 2>/dev/null
      fi
      ;;
  esac
fi
''';

  /// Best-effort fastfetch install, run detached as root by [installCommand].
  ///
  /// Every branch is the guest's own package manager and its own repositories;
  /// nothing is downloaded from anywhere the guest was not already configured
  /// to trust. A guest whose manager is not listed, or whose repositories do
  /// not carry fastfetch, simply keeps the fallback summary.
  static const String fastfetchInstallScript = '''
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache $fastfetchCommand
elif command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && \\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $fastfetchCommand
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y $fastfetchCommand
elif command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm $fastfetchCommand
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive install $fastfetchCommand
fi
''';

  /// One shell command that puts [snippet] in the guest and leaves it there.
  ///
  /// Runs as whichever account the terminal is about to use, escalating with
  /// `sudo -n`/`doas -n` only to write under `/etc` — the seeded account has
  /// passwordless sudo, and an account that has neither is left alone rather
  /// than prompted for a password nobody is there to type.
  ///
  /// Both payloads travel base64-encoded, so nothing in them is re-parsed by
  /// the host shell, ssh, or the guest shell on the way in.
  static String installCommand() {
    final snippetPayload = base64.encode(utf8.encode(snippet));
    final installPayload = base64.encode(utf8.encode(fastfetchInstallScript));
    return '''
if [ "\$(id -u)" = 0 ]; then
  sudo=""
elif command -v sudo >/dev/null 2>&1; then
  sudo="sudo -n"
elif command -v doas >/dev/null 2>&1; then
  sudo="doas -n"
else
  echo "wslmanager: no way to write $path" >&2
  exit 1
fi
printf %s '$snippetPayload' | base64 -d | \$sudo tee $path >/dev/null || exit 1
\$sudo chmod 0644 $path || exit 1
# Debian and Alpine both source /etc/profile.d from /etc/profile; a guest that
# does not is given the loop, once.
if [ -f /etc/profile ] && ! grep -q 'profile\\.d' /etc/profile; then
  printf '%s\\n' 'for _f in /etc/profile.d/*.sh; do [ -r "\$_f" ] && . "\$_f"; done; unset _f' \\
    | \$sudo tee -a /etc/profile >/dev/null
fi
if ! command -v $fastfetchCommand >/dev/null 2>&1; then
  # Detached: fetching a package must not hold up the terminal that asked for
  # the banner, and the fallback summary covers this session either way.
  ( printf %s '$installPayload' | base64 -d | \$sudo nohup sh -s ) \\
    >/dev/null 2>&1 &
fi
# The last word: backgrounding the fetch above succeeds whatever came of it,
# and a caller that believed in an install it never got would stop retrying.
test -s $path
''';
  }
}
