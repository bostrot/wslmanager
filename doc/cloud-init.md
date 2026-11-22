# Cloud-init configurations

A saved cloud-init configuration is a user-data document — `#cloud-config`
YAML or a `#!` script — that a new instance runs on its first boot: packages,
users, files, commands. The **Cloud-init** page in the navigation pane keeps
them; the **Add instance** page has a picker for them (bostrot/ai-tasks#76).

The configurations live in `SharedPreferences` under `CloudInitConfigs`, one
JSON list with unique names, edited by `CloudInitStore`
(`lib/api/cloud_init.dart`); every document is stored with LF line endings
and a final newline, so both guests get the same bytes. The editor refuses a
document cloud-init would not recognise (no known header) and a
`#cloud-config` that is not a YAML mapping, because cloud-init reports both
only in a log inside the guest. A MIME multipart document is refused too:
the macOS seed nests the document inside a multipart of its own, where
cloud-init would not recognise a second one. The picker under each create
page links straight to the editor for a new configuration — pushed, so the
half-filled form is still there on the way back.

## macOS: the seed ISO

`vmctl create` already builds a NoCloud seed (`seed.iso`, volume `cidata`)
whose user-data provisions the account, the app's SSH key and a console
password — the pieces `vmctl exec` and `shell` depend on. A saved
configuration is handed over as `vmctl create --user-data PATH`; the app
writes it to a temp file for the call and deletes it afterwards, vmctl keeps
a copy in the VM's directory as `user-data` — the record of what the guest
was provisioned with. vmctl checks only that the file is readable, UTF-8 and
not blank; the header and YAML are the app's checks, made before a document
is ever saved.

The seed's `user-data` then becomes a `multipart/mixed` message, the form
cloud-init defines for more than one document:

1. the user's part, typed `text/plain`, so cloud-init reads its kind off the
   first line exactly as it would a bare file (`#cloud-config`, `#!`,
   `#include`, …);
2. vmctl's part, typed `text/cloud-config`, with the header
   `Merge-Type: list(append)+dict(no_replace,recurse_array)+str()`;
3. a two-line pins part, `ssh_pwauth: false` and `disable_root: false`
   with `Merge-Type: list()+dict(replace)+str()`, so those two win whatever
   the user wrote: the console password vmctl generates must not become an
   SSH credential, and root keeps the store's key that `exec` and the
   rootfs export rely on.

cloud-init merges cloud-config parts in order and takes the rules from the
part being merged *in*. `no_replace` keeps every scalar the user set
(`hostname`, `package_update`, `ssh_pwauth`); `recurse_array` with
`list(append)` adds vmctl's `users`, `ssh_authorized_keys`, `chpasswd.users`
and `bootcmd` entries to the user's instead of replacing them. So the
account and key the app needs always land, and nothing the user wrote is
overruled. A `#!` script is a separate part and simply runs at the
`scripts-user` stage.

Only a Linux guest booted from a cloud image runs the seed, so the picker is
offered for that choice alone. A `reseed` — the repair the app runs on its
own when a VM stops answering, and what `credentials` does for a VM made
before guest passwords existed — rewrites vmctl's own document under a
fresh instance id and deliberately leaves the user's out: replaying their
`runcmd`, `write_files` and package list would re-provision a guest somebody
has been working in.

## Windows: cloud-init's WSL datasource

Ubuntu's WSL images since 24.04 ship cloud-init with a WSL datasource that,
on the distro's first start, reads (first match wins, no merging):

```
%USERPROFILE%\.cloud-init\<InstanceName>.user-data
%USERPROFILE%\.cloud-init\<ID>-<VERSION_ID>.user-data
%USERPROFILE%\.cloud-init\<ID>-all.user-data
%USERPROFILE%\.cloud-init\default.user-data
```

The app only ever writes the first form. `createInstance`
(`lib/dialogs/create_dialog.dart`) writes `<name>.user-data` right before
`wsl --import`, then on success runs `cloud-init status --wait` as root in
the distro — which is what boots it for the first time — so the default user
the create flow adds afterwards lands on a finished system, and "created" is
said of a distro that is done setting itself up. The wait goes through the
execution broker with a 20-minute bound and can be cut short from the
create page's Cancel; it is skipped outright, with a warning, on a distro
that has no cloud-init or no running systemd to start it (`status --wait`
would otherwise spin on "not run" for ever). The file is removed again once
that first boot has confirmed it ran (or could never run), and on every
other exit of the create — a failed import, a cancel, an exception — in one
`finally`: the fallbacks above belong to the user, and a file left behind
would apply itself to every later distro of the same name. The one case
that keeps it is a first boot that could not be confirmed at all (the
broker's timeout, a distro that failed to start): then it stays for the boot
that will read it, the user is told, and `WSLApi.remove` takes it away with
the distro. A file that already exists under that name is never
overwritten; the create stops and says so.

The picker is gated on `VmFeatures.cloudInit`, which the WSL backend sets
only for a local `wsl.exe`: over remote WSL the user profile — and the file
— live on the other machine.

## What it does not do

* Distros without cloud-init (Debian, Alpine, Fedora rootfs imports, Docker
  images, VHDX imports) ignore the file. The hint under the picker says so;
  nothing in the app interprets cloud-config on their behalf.
* A saved configuration is one document. Anyone who needs the fallback
  forms, meta-data, or a Landscape/Ubuntu Pro `agent.yaml` writes those files
  by hand.
* The `Merge-Type`s above are fixed. A `#cloud-config` that itself carries
  `merge_how` still merges into an empty buffer on its own terms; vmctl's
  parts come after it and apply their own rules regardless.
* `WSLApi.create` itself knows nothing of cloud-init: the file is the create
  page's to write, so the MCP tools, templates and the sandbox — which call
  `import` directly — create distros without one.
