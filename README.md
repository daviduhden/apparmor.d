# apparmor.d

Collection of AppArmor profiles and abstractions for common daemons
(Tor, i2pd, Monero `monerod`, Monero Light Wallet Server `monero-lws-daemon`,
Radicale, OpenDKIM, Fail2Ban, xd-torrent), plus utilities to manage them.

Main contents
- Profiles: `usr.sbin.tor`, `usr.bin.i2pd`, `usr.bin.monerod`, `usr.bin.monero-lws-daemon`, `usr.bin.radicale`, `usr.sbin.opendkim`, `usr.bin.xd-torrent`, `usr.bin.fail2ban-server`
- Abstractions: `abstractions/tor`
- Helper scripts: `scripts/enforce-complain-toggle.pl`, `scripts/merge-dupe-rules.pl`
- `Makefile`: installs profiles, abstractions and helper scripts
- `AGENTS.md` and `.agents/skills/`: agent instructions and task procedures
- `scripts/check-agent-sync.pl`: dependency-free Perl structural guard for agent and
  skill maintenance; run it manually before completing repository changes

Quick `Makefile` usage
- Install profiles and helpers (writes `/etc/apparmor.d` and the helper
  directory; may run `dpkg-divert`; root normally required):

```sh
make install PREFIX=/usr DESTDIR=
```

- Load installed profiles. This target installs first and runs
  `unload-profiles`; it requires root and `apparmor_parser`:

```sh
make load
```

- Syntax-check profiles (treats parser warnings as errors; see the caveats
  below):

```sh
make check
```

- Remove files installed by this repository. This removes empty
  `local/<profile-file>` stubs but preserves non-empty overrides, and does not
  unload kernel policy:

```sh
make uninstall
```

- Show Makefile help:

```sh
make help
```

Other targets exist but are not part of the normal workflow:
`install-scripts` (helpers only), `unload-profiles` (best effort, using the
installed files), `clean` (no-op), and `test` (prints a placeholder; there are
no automated tests).

Important variables
- `PREFIX`: prefix for helper scripts (default: `/usr`). The scripts go to
  `$(DESTDIR)$(PREFIX)/local/bin`, so `PREFIX=/usr/local` produces
  `/usr/local/local/bin`; set `BINDIR` explicitly if that is not intended.
  `PREFIX` does not affect profiles.
- `DESTDIR`: temporary installation root for packaging.
- `APPARMOR_DIR`: profile destination (default: `$(DESTDIR)/etc/apparmor.d`).
  Profiles are not hard-wired to `/etc` when this variable changes.
- `BINDIR`: helper script destination (default: `$(DESTDIR)$(PREFIX)/local/bin`).
- `DIVERT`: use `dpkg-divert` to displace distro copies of the files listed in
  `DIVERT_FILES` (default: `yes`, or `no` when `DESTDIR` is set). With
  `DIVERT=no`, same-named distro files are overwritten without a backup.
- `DIVERT_DIR`: where diverted distro files are kept (default:
  `$(APPARMOR_DIR)/distrib`, a subdirectory the loader ignores). Cleanup is
  restricted to a normalized path under `APPARMOR_DIR`; still do not pass an
  untrusted path.
- `APPARMOR_PARSER`: command used for `make load` and `make check` (default:
  the bare `apparmor_parser`, resolved through `PATH`).

What `make install` does
- Creates `$(APPARMOR_DIR)`, `$(APPARMOR_DIR)/abstractions/`, `$(APPARMOR_DIR)/local/`,
  and `$(BINDIR)`, then copies `abstractions/tor`.
- If diversion is enabled, diverts the entries in `DIVERT_FILES`
  (`usr.bin.i2pd`, the distro-only `system_tor`, and `abstractions/tor`) with
  `dpkg-divert` into `$(DIVERT_DIR)` (default `/etc/apparmor.d/distrib`). This
  keeps `apt` upgrades from overwriting those files and preserves the
  originals. `system_tor` is not shipped by this repository; it is diverted
  because Debian's Tor packaging uses that file. The other profiles are copied
  without diversion, so a distro package that ships the same name can be
  overwritten.
- Copies the listed profiles into `$(APPARMOR_DIR)`.
- Creates empty stub files in `$(APPARMOR_DIR)/local/` for each profile (if
  missing).
- Installs `enforce-complain-toggle` and `merge-dupe-rules` into `$(BINDIR)`
  (the `.pl` suffix is removed).
- Does not syntax-check, load, or reload anything. It aborts if a diversion or
  a copy fails; a missing source file is reported as `not found, skipping`.

`make uninstall` removes the repository files and the diversions (restoring
distro files when diversion is active). It removes `local/<profile-file>` only
when the file is empty, so non-empty site overrides are preserved; it still
does not unload kernel policy and masks most failures. Diversions are skipped
when `DESTDIR` is set (packaging) unless `DIVERT=yes` is forced; set
`DIVERT=no` to disable them explicitly.

Debian's Tor packaging refers to a `system_tor` profile, which is why that
distro-only file is in `DIVERT_FILES`. Diverting the file does not unload an
already-loaded profile and does not create a profile named `system_tor`; the
shipped profile is named `tor` and attaches to `/usr/bin/tor` and
`/usr/sbin/tor`. After installation, check `aa-status` and the unit's
`AppArmorProfile=` setting; the exact result depends on the packaging and unit
version.

`make check` runs unprivileged: it compiles the profiles in a temporary
directory and treats parser warnings as errors (`--Werror`). It is not
self-contained: it uses the host's `abi/4.0`, `tunables/global`, and standard
abstractions, copies only `abstractions/tor`, and creates empty `local/` stubs
instead of using real overrides. Each parser invocation is checked, so the
target stops at the first rejected profile.

Notes
- `make load` installs first, unloads the installed files, then invokes
  `apparmor_parser` with the configured flags. It requires root, errors if the
  parser is not installed, and stops at the first missing or rejected profile.
- `make test` is a placeholder that prints `No automated tests defined`. There
  are no unit tests or CI workflows. `make check` is the policy syntax gate.
- To run the repository knowledge check locally, use
  `perl scripts/check-agent-sync.pl --base <base-ref>`. The base ref must
  point to the last synchronized revision. It checks change coverage, basic
  instruction structure, and detectable local Markdown references; review the
  diff for semantic relevance because the script cannot establish it.
- All profiles use `abi <abi/4.0>`; older parsers may fail to load them or may
  warn under `--Werror`. `@{system_share_dirs}` also depends on the host
  tunables.
- Use `local/<profile-file>` (for example `local/usr.sbin.tor`) to add
  site-specific adjustments. `make uninstall` preserves non-empty overrides but
  removes empty stubs; keep an external backup anyway.
- Profile names differ from file names: `usr.sbin.tor` declares `tor`, and
  `aa-status`/`aa-complain` use the profile name or file path accordingly. A
  disabled profile is not loaded; `aa-disable` disables the whole file.
- To debug denials, switch a profile to `complain` (for example
  `sudo aa-complain /etc/apparmor.d/usr.sbin.tor`), exercise the service, and
  check `journalctl -g apparmor` (or `ausearch`). Restore enforce mode
  afterward.

Contributing
- Report issues or submit patches via pull requests.
- Agent instructions are in `AGENTS.md`; task procedures are in
  `.agents/skills/`.

License
- ISC. See the `LICENSE` file in this directory; preserve the copyright and
  permission notice.
