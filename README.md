# apparmor.d

Collection of AppArmor profiles and abstractions for common daemons
(Tor, i2pd, Monero `monerod`, Monero Light Wallet Server `monero-lws-daemon`,
Radicale, OpenDKIM, Fail2Ban), plus utilities to manage them.

Main contents
- Profiles: `usr.sbin.tor`, `usr.bin.i2pd`, `usr.bin.monerod`, `usr.bin.monero-lws-daemon`, `usr.bin.radicale`, `usr.sbin.opendkim`, `usr.bin.xd-torrent`, `usr.bin.fail2ban-server`
- Abstractions: `abstractions/tor`
- Helper scripts: `scripts/enforce-complain-toggle.pl`, `scripts/merge-dupe-rules.pl`
- `Makefile`: installs profiles, abstractions and helper scripts

Quick `Makefile` usage
- Install profiles and helpers:

```sh
make install PREFIX=/usr DESTDIR=
```

- Load installed profiles (requires `apparmor_parser`):

```sh
make load
```

- Syntax-check profiles (treats warnings as errors):

```sh
make check
```

- Remove files installed by this repository:

```sh
make uninstall
```

- Show Makefile help:

```sh
make help
```

Important variables
- `PREFIX`: prefix for helper scripts (default: `/usr`, giving `/usr/local/bin`).
  It does not affect profiles, which are always installed under `/etc/apparmor.d`.
- `DESTDIR`: temporary installation root for packaging.
- `BINDIR`: helper script destination (default: `$(DESTDIR)$(PREFIX)/local/bin`).
- `DIVERT`: use `dpkg-divert` to displace distro copies of replaced files
  (default: `yes`, but automatically `no` when `DESTDIR` is set).
- `DIVERT_DIR`: where diverted distro files are kept (default:
  `$(APPARMOR_DIR)/distrib`, a subdirectory the loader ignores).
- `APPARMOR_PARSER`: path to `apparmor_parser` (required for `make load` and `make check`).

What `make install` does
- Creates `$(DESTDIR)/etc/apparmor.d/abstractions/` and copies `abstractions/tor`.
- Diverts the distro copies of the files this repo also ships
  (`usr.bin.i2pd`, `system_tor`, `abstractions/tor`) with `dpkg-divert` into
  `$(DIVERT_DIR)` (default `/etc/apparmor.d/distrib`), then installs the
  repository versions in the canonical paths. This keeps `apt` upgrades from
  overwriting the profiles and preserves the originals.
- Copies the listed profiles into `$(DESTDIR)/etc/apparmor.d/`.
- Creates empty stub files in `$(DESTDIR)/etc/apparmor.d/local/` for each profile (if missing).
- Installs `enforce-complain-toggle` and `merge-dupe-rules` into `$(BINDIR)`.

`make uninstall` removes the repository files and removes the diversions,
restoring the distro files. Diversions are skipped when `DESTDIR` is set
(packaging); set `DIVERT=no` to disable them explicitly.

Because Debian's `tor@default.service` asks for the `system_tor` profile and
that file is diverted away, the shipped `tor` profile (attached to
`/usr/bin/tor` and `/usr/sbin/tor`) is the one applied.

`make check` runs unprivileged: it compiles the profiles in a temporary
directory and treats parser warnings as errors (`--Werror`).

Notes
- `make load` invokes `apparmor_parser` with the configured flags; it will error if the parser is not installed.
- Use `local/<profile>` to add site-specific adjustments without modifying upstream profiles.
- To debug denials, switch a profile to `complain` (e.g. `sudo aa-complain /etc/apparmor.d/usr.sbin.tor`) and check `journalctl -g apparmor`.

Contributing
- Report issues or submit patches via pull requests.

License
- See the `LICENSE` file in this directory for licensing terms.
