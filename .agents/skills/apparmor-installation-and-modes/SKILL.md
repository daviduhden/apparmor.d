---
name: apparmor-installation-and-modes
description: Install, stage, load, uninstall, or switch AppArmor profiles between enforce, complain, and disabled states in this repository. Use when working with the Makefile, dpkg diversions, local overrides, or profile mode changes.
---

# AppArmor installation and modes

## Activation conditions

Use this skill when the task involves:

- `make install`, `make load`, `make uninstall`, `make unload-profiles`, or
  `make check`;
- `DESTDIR`, `PREFIX`, `APPARMOR_DIR`, `BINDIR`, or `DIVERT*` variables;
- `dpkg-divert`, `/etc/apparmor.d/distrib`, or `local/` overrides;
- switching a profile between enforce, complain, and disabled.

This skill changes the system. Do not use it during a documentation-only task
without explicit authorization.

## Makefile variables (actual defaults)

| Variable | Default | Behavior |
| --- | --- | --- |
| `PREFIX` | `/usr` | Only feeds `BINDIR`. |
| `DESTDIR` | empty | Prepended to `APPARMOR_DIR` and `BINDIR`. |
| `INSTALL` | `install` | Resolved through `PATH`; not quoted. |
| `APPARMOR_DIR` | `$(DESTDIR)/etc/apparmor.d` | Profile destination. |
| `BINDIR` | `$(DESTDIR)$(PREFIX)/local/bin` | Default `/usr/local/bin`. `PREFIX=/usr/local` yields `/usr/local/local/bin`. |
| `SYSTEMD_UNIT_DIR` | `$(DESTDIR)$(PREFIX)/lib/systemd/system` | Default `/usr/lib/systemd/system`; installation copies unit files but never activates them. |
| `APPARMOR_PARSER` | `apparmor_parser` | Bare command name, resolved through `PATH`. |
| `APPARMOR_FLAGS` | `-r -T -W` | Replace, skip cache read, write cache. |
| `APPARMOR_CHECK_FLAGS` | `-Q -K --Werror` | Do not load, do not cache, warnings are errors. |
| `DIVERT` | `yes`, or `no` when `DESTDIR` is non-empty | Enables `dpkg-divert`. |
| `DIVERT_FILES` | `usr.bin.i2pd system_tor abstractions/tor` | Only these paths are diverted. `system_tor` is a distro file, not shipped here. |
| `DIVERT_DIR` | `$(APPARMOR_DIR)/distrib` | Storage for diverted files. Cleanup only runs when its normalized path is under `APPARMOR_DIR`. |
| `DPKG_DIVERT` | `dpkg-divert` | Debian-only. |

## What each target does

### `make install` (also the default `make`)

1. Creates `$(APPARMOR_DIR)`, `$(APPARMOR_DIR)/abstractions`,
   `$(APPARMOR_DIR)/local`, and `$(BINDIR)`.
2. If `DIVERT=yes` and `dpkg-divert` exists, for each entry in
   `DIVERT_FILES`: records or performs a **local** diversion into
   `$(DIVERT_DIR)`.
   - If the source exists, `dpkg-divert --rename` moves it.
   - If it does not exist, it records a `--no-rename` diversion.
   - Diversion failures abort the install instead of continuing and
     overwriting the distro file.
3. Copies `abstractions/tor`.
4. Copies the eight profiles into `$(APPARMOR_DIR)`.
5. Creates an empty `$(APPARMOR_DIR)/local/<profile-file>` if missing. It does
   not overwrite an existing local override.
6. Installs the Perl helpers as `$(BINDIR)/enforce-complain-toggle`,
   `$(BINDIR)/merge-dupe-rules`, and `$(BINDIR)/collect-apparmor-denials`
   (`.pl` removed, mode `0755`).
7. Installs `collect-apparmor-denials.service` and
   `collect-apparmor-denials.timer` into `$(SYSTEMD_UNIT_DIR)` (default
   `/usr/lib/systemd/system`, mode `0644`). This does not run daemon-reload,
   enable the timer, or start the service.

Important: `install` does not syntax-check, load, or reload anything. It aborts
if a diversion or copy fails; a missing source file is reported as "not found,
skipping".

### `make load`

Depends on `install` and `unload-profiles`, so it **installs first**, then
loads each installed profile with `-r -T -W`. It requires root, fails if a
profile is missing, and stops at the first parser failure. It does not remove
profiles for files that no longer exist.

### `make unload-profiles`

Runs `apparmor_parser -R <installed-file>` for each profile, discards output,
and reports removal failures as warnings. This is the correct file-based form,
but it remains best effort and is not a guarantee that no policy remains
loaded.

### `make uninstall`

- Removes the installed helper scripts and the collector service/timer unit files.
- Does not disable an enabled timer or stop an active unit; handle unit state
  separately before uninstalling.
- Removes every shipped profile and every **empty** `local/<profile-file>`
  stub. Non-empty overrides are preserved.
- Removes the abstraction.
- If diversion is enabled and `dpkg-divert` exists, removes recorded
  diversions and restores the distro files.
- Deletes empty directories under `DIVERT_DIR` with
  `find ... -type d -empty -delete`.
- Prints "Uninstall complete" even when earlier commands failed.
- Does **not** unload profiles from the kernel.

`DIVERT_DIR` is normalized and is only cleaned when it is under
`APPARMOR_DIR`; still never pass an untrusted value or a symlinked path.

### `make check`

See `apparmor-policy-validation`. It is a compile check only, not hermetic, and
it stops at the first parser failure.

### `make clean`, `make help`, `make test`

- `clean` prints "Nothing to clean".
- `help` prints the target and variable summary.
- `test` prints "No automated tests defined".

## Safe staging procedure

Use this when installation is authorized:

1. Back up current policy and local overrides:
   `cp -a /etc/apparmor.d /var/backups/apparmor.d.$(date +%Y%m%d-%H%M%S)`.
2. Stage into an empty directory first:
   `make install DESTDIR=/tmp/apparmor-stage`.
3. Inspect the staged tree. Confirm profiles, abstraction, `local/` stubs, and
   scripts are present and have the expected modes.
4. Confirm `dpkg-divert` behavior. With `DESTDIR` set, diversion is disabled by
   default; do not force `DIVERT=yes` against a staging root.
5. Only then install to the live root, with a backup and a rollback plan.
6. Run `make check` before loading, if the parser is available.
7. Load with `apparmor_parser -r <file>` per profile or `make load`, and read
   every line of output.
8. Verify with `aa-status` and a real workload.

## Validation

- `aa-status` lists the loaded profile name (not the file name) and its mode.
- Re-run the parser per profile or read every line of `make load`; do not trust
  the target's aggregate exit status.
- Exercise the service and check `journalctl -g apparmor` (or `ausearch`).
- Confirm that `local/` overrides survived and that diverted distro files are
  present under `DIVERT_DIR`.
- If a profile fails, remove or fix that file; do not leave a partially loaded
  set and call the installation successful.

## Profile modes

| Mode | Effect | How it is selected |
| --- | --- | --- |
| Enforce | Denials are blocked and logged. | `flags=(..., enforce, ...)` or `aa-enforce <profile-or-path>`. |
| Complain | Denials are logged but allowed. | `aa-complain <profile-or-path>` or a deliberate `flags=(complain)`. |
| Disabled | The file is not loaded. | `aa-disable <path>` (symlink under `/etc/apparmor.d/disable/`), or `apparmor_parser -R <file>`. |

Notes:

- All shipped profiles currently declare `enforce`.
- Changing `flags=(enforce)` to `flags=(complain)` in the file is a persistent
  local change; `aa-complain` changes the loaded mode and is easier to revert.
- `aa-disable` affects the whole file and all attachments in it.
- A profile name is not a file name: `usr.sbin.tor` declares `tor`.
- Do not leave a profile in complain mode after an investigation.

## Common problems

- **`make load` fails because `apparmor_parser` is missing.** Install the
  AppArmor user-space tools or set `APPARMOR_PARSER`; do not substitute a shell
  alias.
- **`make load` stops partway.** A profile is missing or the parser rejected it;
  check the last line and `aa-status`. Earlier profiles remain loaded.
- **Distro file overwritten.** Diversion was disabled, unavailable, or failed.
  Restore from `/etc/apparmor.d/distrib` or the package; do not reinstall over
  it blindly.
- **Local overrides lost.** The target removes empty stubs; a non-empty file
  should survive. Restore from backup and check permissions and emptiness.
- **Profile still enforced after uninstall.** Files were removed, but the kernel
  policy was not unloaded. Use `apparmor_parser -R <file>` or `aa-disable`.
- **`PREFIX=/usr/local` puts scripts in `/usr/local/local/bin`.** Set `BINDIR`
  explicitly if that is not intended.
- **`DESTDIR` install loads host policy.** `make load DESTDIR=...` still loads
  into the running kernel; do not use it for staging.

## References

- `README.md` for the user-facing summary.
- `AGENTS.md` for safety rules.
- `apparmor-policy-validation` for compile checks and denial audits.
- `dpkg-divert(1)`, `apparmor_parser(8)`, `aa-status(8)`, `aa-complain(8)`,
  `aa-enforce(8)`, `aa-disable(8)`.

## Maintenance & Continuous Learning

After using this skill to modify any repository content, review this skill and
its related `AGENTS.md` and skills once the implementation is complete. Update
this skill when the task establishes reusable knowledge or changes a procedure,
tool, configuration, path, assumption, example, or validation step. Correct any
instruction that proved inaccurate, remove obsolete or contradictory guidance,
and keep cross-references working. Do not record one-off execution details.

Every repository change must include a substantive, relevant agent/skills
update. Run `python3 scripts/validate-agent-knowledge.py --scope range --base <base-ref> --head HEAD` and review the diff for semantic relevance; the validator checks
structure and detectable references but cannot establish relevance. Report the
skills and agent instructions reviewed, updates made, checks actually run, and
PASS/FAIL synchronization status. A failed or skipped synchronization means
the task is incomplete.
