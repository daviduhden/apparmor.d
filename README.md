# apparmor.d

Collection of AppArmor profiles and abstractions for common daemons
(Tor, i2pd, Monero `monerod`, Radicale, OpenDKIM), plus utilities to manage them.

Main contents
- Profiles: `usr.sbin.tor`, `usr.bin.i2pd`, `usr.bin.monerod`, `usr.bin.radicale`, `usr.sbin.opendkim`
- Abstractions: `abstractions/tor`
- Sync script: `scripts/sync-profiles.pl`
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
- `PREFIX`: installation prefix (default: `/usr`).
- `DESTDIR`: temporary installation root for packaging.
- `BINDIR`: helper script destination (default: `$(DESTDIR)$(PREFIX)/usr/local/bin`).
- `APPARMOR_PARSER`: path to `apparmor_parser` (required for `make load` and `make check`).

What `make install` does
- Creates `$(DESTDIR)$(PREFIX)/etc/apparmor.d/abstractions/` and copies `abstractions/tor`.
- Copies the listed profiles into `$(DESTDIR)$(PREFIX)/etc/apparmor.d/`.
- Creates empty stub files in `$(DESTDIR)$(PREFIX)/etc/apparmor.d/local/` for each profile (if missing).
- Installs `sync-profiles` and `enforce-complain-toggle` into `$(BINDIR)`.

Notes
- `make load` invokes `apparmor_parser` with the configured flags; it will error if the parser is not installed.
- Use `local/<profile>` to add site-specific adjustments without modifying upstream profiles.
- To debug denials, switch a profile to `complain` (e.g. `sudo aa-complain /etc/apparmor.d/usr.sbin.tor`) and check `journalctl -g apparmor`.

Contributing
- Report issues or submit patches via pull requests.

License
- See the `LICENSE` file in this directory for licensing terms.
