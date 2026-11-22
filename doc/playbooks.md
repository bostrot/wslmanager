# Playbooks: an instance as code

A playbook describes the state an instance should be in — packages, users,
files, services, commands — and is applied to an instance that already
exists, as often as needed. Where a cloud-init configuration runs once, on a
first boot, a playbook is re-run: every step looks first and changes only
what is not there yet, and answers `ok` or `changed` the way Ansible does.
The **Playbooks** page in the navigation pane keeps them, opens the editor
and the apply page (bostrot/ai-tasks#78).

The playbooks live in `SharedPreferences` under `Playbooks`, one JSON list
with unique names, edited by `PlaybookStore` (`lib/api/provisioning.dart`),
and every document is stored with LF line endings and a final newline. The
latest run of each playbook on each instance — when, applied or checked,
and the ok/changed/failed/skipped counts — sits next to them under
`PlaybookRuns` and is shown under the document on the list page; that
record is what makes a playbook a description of an instance rather than a
script that was run once.

## Two document shapes

The editor accepts a document that parses as YAML and is one of:

* **A mapping in cloud-config's vocabulary.** A saved cloud-init
  configuration works here unchanged (the `#cloud-config` header is a
  comment to YAML). The app itself is the engine — see the next section —
  and at least one key it handles has to be present.
* **A list of Ansible plays**, each with a `hosts` key. This is handed to
  `ansible-playbook` inside the instance with `-i localhost, -c local`, so
  `hosts: all` or `hosts: localhost` is what a play should say. Ansible is
  installed from the instance's package manager first when it is missing
  (`ansible` everywhere, `ansible-core` on dnf/yum); a check run cannot
  install it and says so.

## The built-in engine

`compilePlaybook` turns the mapping into steps, in cloud-init's own order:
`users`, `write_files`, `package_update`, `packages`, `package_upgrade`,
`timezone`, `services`, `runcmd`. Each step is a small POSIX `sh` script run as
root through `VmBackend.runInInstance` — the same call the AI sandbox and
the MCP tools use, so it works on local WSL and on the Apple backend alike.
The script travels base64-encoded on one command line with no quote of
either kind on it, lands in a `mktemp` file, runs with `WSLM_CHECK=0` or
`1`, and prints `__wslm__:ok`, `__wslm__:changed`, `__wslm__:failed` or
`__wslm__:skipped` on a line of its own at the end; what it printed before
that is the step's output on the apply page. A non-zero exit or a missing
marker means the instance could not run the step at all and counts as
failed. An apply stops at the first failed step; a check run (below) goes
on, since nothing was changed that a later step could build on.

Every script starts with the same prelude: package-manager shims for
apt-get, apk, dnf, yum, zypper and pacman, and the `report`/`fail` answers.
Everything in it is a command busybox has, so the script itself is the same
on Alpine as on Ubuntu. What the instance does need is **bash**, because
`runInInstance` enters every instance through `bash -c` on both backends —
a stock Alpine minirootfs fails at the first step until `apk add bash`.
The pane entry is hidden over remote WSL: the SSH wrapper caps an inline
command at a couple of KB, and every step here is several.

| Key | What the step does | `changed` when |
|-----|--------------------|----------------|
| `users` | `useradd -m` (or `adduser -D`) when missing; `shell`, `groups` (created when missing), `sudo` rules in `/etc/sudoers.d/90-wslmanager-<name>`, `ssh_authorized_keys` appended to `~/.ssh/authorized_keys` | any of those was missing |
| `write_files` | `path`, `content` (`encoding: b64` accepted), `permissions` (a new file without one gets 0644, an existing one keeps its mode), `owner` (names or numeric ids), `append` | the bytes, mode or owner differ; with `append`, when the file does not already end with the content |
| `package_update` | refreshes the index | never (`ok`; skipped in a check run) |
| `packages` | installs the ones not yet installed; `[name, version]` pairs install the name | at least one was missing |
| `package_upgrade` | upgrades everything | always, as Ansible's `apt upgrade` does (skipped in a check run) |
| `timezone` | links `/etc/localtime` | the link differs |
| `services` | `systemctl enable/disable/start/stop/restart` per `enabled` and `state` (`started`, `stopped`, `restarted`); a bare name means enabled and started | something had to be done; fails without a running systemd |
| `runcmd` | a string (via `sh -c`), a list of arguments, or `{cmd, creates, unless}` | always, unless `creates` exists or `unless` succeeds (`ok`); skipped in a check run |

Any other top-level key (`hostname`, `bootcmd`, `ssh_pwauth`, …) becomes a
step reported as skipped, so nothing in the document is silently ignored.

## Check mode

The apply page's **Check only** box runs every step with `WSLM_CHECK=1`:
the step prints what it would do and answers `changed` without touching the
instance, or `skipped` where looking is not possible (a package-index
refresh, an upgrade, a command). A step whose precondition is missing (no
systemd for `services`, an unknown time zone) still answers `failed`, but a
check run carries on to the steps after it. The run is recorded as
"checked" next to, not instead of, the last "applied" record; a run the
user stopped with **Stop after this step** is not recorded at all.

## What it does not do

* Nothing is streamed: a step's output appears when the step ends. A running
  step cannot be interrupted; **Stop after this step** takes effect between
  steps.
* A step's script, content included, travels on one command line, so a
  `write_files` entry is limited to what the host's command line takes (a
  few tens of kilobytes on Windows).
* Plain-text passwords, `lock_passwd`, `ssh_import_id` and the rest of
  cloud-config's user options are not handled; nor are `bootcmd`, `hostname`
  or the network stanzas, which belong to a first boot.
* Ansible's inventory, vaults and roles are the instance's own: the app
  hands over one file and reads `changed=` off the recap line; the run
  history counts the Ansible run as one step, not per task.
* The run history is kept by instance name and nothing clears it when an
  instance is deleted (the delete paths sit in files another change holds),
  so a new instance under an old name shows the old line until the playbook
  is applied to it.
