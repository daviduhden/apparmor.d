# apparmor.d

Custom AppArmor policies: hardened profiles and abstractions for common daemons (Tor, i2pd, Monero `monerod`, Radicale, OpenDKIM) plus a small helper to sync selected upstream profiles.

## Contents
- **Profiles:** `usr.sbin.tor`, `usr.bin.i2pd`, `usr.bin.monerod`, `usr.bin.radicale`, `usr.sbin.opendkim`
- **Abstractions:** `abstractions/tor` (shared read-only allowances for Tor and transports)
- **Helper:** `sync-profiles.pl` (fetches upstream AppArmor profiles and forces enforce mode)
- **Makefile:** installs local abstractions/profiles and the sync helper

## Conventions
- **Dual-path patterns:** profiles prefer brace patterns like `/{usr/,}bin/...` and `/{,var/}run/...` to cover distro differences.
- **Named profiles:** profiles use a stable name (e.g., `profile tor /{usr/,}sbin/tor`) rather than relying on a path-only identifier.
- **Minimal writes:** abstractions avoid writable paths; writable directories appear only in specific profiles (e.g., Tor state, Radicale collections).

## Install
Use the Makefile to install abstractions and the sync helper:

```sh
make install PREFIX= DESTDIR=
```

This copies `abstractions/tor` to `/etc/apparmor.d/abstractions/` and installs `sync-profiles` to `/usr/local/bin/`. It also removes a legacy `system_tor` entry if present.

## Reload and Verify
After installing or editing profiles, reload them and check logs:

```sh
sudo apparmor_parser -r \
	/etc/apparmor.d/abstractions/tor \
	/etc/apparmor.d/usr.sbin.tor \
	/etc/apparmor.d/usr.bin.i2pd \
	/etc/apparmor.d/usr.bin.monerod \
	/etc/apparmor.d/usr.bin.radicale \
	/etc/apparmor.d/usr.sbin.opendkim

sudo journalctl -g apparmor -n 200 --no-pager
```

## Sync Upstream Profiles
`sync-profiles.pl` clones the upstream AppArmor repo and copies selected profiles (apache2, postfix, dovecot, spamc/spamd, clamav/clamd) into your `/etc/apparmor.d`, forcing `flags=(enforce,...)` and bringing required `abstractions/` and `tunables/`.

Environment overrides:
- `APPARMOR_REMOTE`: upstream repo URL (default: `https://gitlab.com/apparmor/apparmor.git`)
- `APPARMOR_TARGET`: target directory (default: `/etc/apparmor.d`)

Run:
```sh
sudo /usr/local/bin/sync-profiles
```

## Troubleshooting
- If a service fails under enforce, temporarily switch to complain to gather logs:
```sh
sudo aa-complain /etc/apparmor.d/usr.sbin.tor
sudo journalctl -g apparmor -n 200 --no-pager
```
- Add site-local adjustments in `local/<profile_name>` includes, keeping the base profiles minimal.
