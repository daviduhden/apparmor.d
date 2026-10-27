---
name: apparmor-policy-validation
description: Validate AppArmor policy changes in this repository, from static consistency checks to syntax compilation and denial auditing. Use when deciding whether a profile change is safe, interpreting parser output, or triaging an AppArmor denial.
---

# AppArmor policy validation

## Activation conditions

Use this skill when you need to:

- verify a profile before proposing or committing a change;
- interpret `apparmor_parser` output or a `DENIED` audit record;
- decide whether a claim such as "the profile works" is justified;
- audit denials in complain mode.

This skill is about evidence. Do not collapse "static review", "syntax check",
and "runtime test" into a single claim.

## Validation levels

| Level | What it proves | What it does not prove |
| --- | --- | --- |
| Static review | Attachments, includes, paths, and rule intent are internally consistent. | That the parser accepts the file or the daemon works. |
| Syntax compile (`make check`, `apparmor_parser -Q -K --Werror`) | The parser accepts the policy against the available include tree. | That it is loaded, enforced, or behaviorally correct. |
| Install (`make install` with `DESTDIR`) | Files can be staged in the expected layout. | That the policy is loaded or correct. |
| Load (`apparmor_parser -r`, `make load`) | The kernel accepted and loaded the profile. | That the daemon runs without denials. |
| Runtime verification (complain + workload + audit log) | The observed workload produced no unexpected denials. | Coverage of untested code paths. |

State exactly which levels were executed. A documentation-only task is level 0
(static reading); do not run the other levels without authorization.

## Static checks (always allowed)

1. **Attachment vs. real path.** Extract the profile declaration and confirm the
   glob covers the executable path used by the service. Remember brace
   expansion: `/{usr/,}{,s}bin/tor` covers four paths.
2. **File name vs. profile name.** `usr.bin.radicale` declares
   `profile radicale`. `aa-status` and `aa-complain` use the profile name or
   file path, not the repository file name.
3. **Includes exist.** Every `include <...>` must resolve in the repository or
   in the host AppArmor tree. `include if exists <local/...>` is intentionally
   optional. Confirm `abi <abi/4.0>` is supported by the target.
4. **Local override name.** It must match the file name:
   `local/usr.sbin.tor`, not `local/tor`.
5. **Write surface.** List every rule with `w`, `a`, `k`, or `m`. Confirm each
   is under the daemon's data, log, cache, runtime, or config area, or is a
   documented exception. Flag `/** rw`, `/etc/** rw`, and writes to other
   services' data.
6. **Capabilities.** Compare with the privilege-drop and port-binding needs.
   Flag `dac_override`, `dac_read_search`, `chown`, and `fowner` unless
   justified.
7. **Network.** Confirm the socket families and types the daemon uses. A path
   rule for a Unix socket does not grant AF_UNIX mediation; check for
   `network unix`.
8. **Exec modes.** Flag `ux`, `Ux`, and `PUx` (unconfined fallback), and any
   `px`/`Px`/`cx`/`Cx` without a corresponding profile.
9. **Duplicates and dead rules.** Duplicated `/dev/*`, network, and log rules
   obscure review; note them. Do not remove them without confirming they are
   truly redundant against the included abstractions.
10. **Comments vs. code.** Treat a comment that contradicts the rule as a
    defect. Known examples: `attach_disconnected` described as "dbus/ppid
    changes" and `pix` described as "without scrubbing the environment".

For comment-only policy documentation, compare every changed profile against
its prior version and verify that active declarations, includes, variables,
flags, and rules are unchanged. Do not remove every `#` line during comparison:
AppArmor `#include` directives are active policy syntax. A successful textual
comparison is not equivalent to parser or runtime validation.

Useful read-only searches:

```sh
# Every profile declaration and its attachment
grep -n '^profile ' usr.* abstractions/*

# Broad writes and escape hatches
grep -nE '(/\*\*|/etc/\*\*).*(rw|w|mrwkl)|\b(u|U|PU)x\b' usr.*

# Includes and local overrides
grep -nE '^[[:space:]]*include' usr.* abstractions/*
```

These are inspection commands, not validation of behavior.

## Syntax check

The repository's syntax target is:

```sh
make check
```

What it actually does (`Makefile`):

- requires `apparmor_parser` in `PATH` or `APPARMOR_PARSER`;
- creates a temporary tree under `/tmp`;
- copies only `abstractions/tor` from the repository;
- copies the eight profiles and creates empty `local/<profile>` stubs;
- runs `apparmor_parser -Q -K --Werror -I <tmp> <profile>` for each profile.

Consequences:

- It is **not hermetic**: `base`, `nameservice`, `ssl_certs`, `python`,
  `user-tmp`, `tunables/global`, and `abi/4.0` come from the host.
- It does **not** validate the abstraction standalone or the Perl scripts.
- Each parser invocation is checked, so the target stops at the first rejected
  profile. To isolate a failure, run profiles individually when execution is
  authorized:

  ```sh
  apparmor_parser -Q -K --Werror -I /path/to/include-root /path/to/profile
  ```

- Empty local stubs mean real site overrides are not exercised.

`make test` is a placeholder and prints "No automated tests defined". There is
no unit-test suite or CI workflow. Never describe the separate agent-sync
validator as AppArmor policy test coverage.

## Loading and modes

- **Enforce**: the profile is loaded and denials are blocked and logged.
- **Complain**: denials are logged but allowed. Use only for diagnosis, with
  authorization, and restore enforce mode afterward.
- **Disabled**: the profile is not loaded. Removing the file or using
  `aa-disable` affects the whole file, including every attachment in it.

Typical commands (require root and authorization):

```sh
aa-status
aa-complain /etc/apparmor.d/usr.sbin.tor
aa-enforce /etc/apparmor.d/usr.sbin.tor
aa-disable /etc/apparmor.d/usr.sbin.tor
apparmor_parser -r /etc/apparmor.d/usr.sbin.tor   # replace/load
apparmor_parser -R /etc/apparmor.d/usr.sbin.tor   # remove
```

`apparmor_parser -R` expects a policy file (or a directory), not a bare profile
name. The repository's `unload-profiles` target now passes installed files, but
still treats removal failures as warnings.

## Denial audit

1. Switch only the affected profile to complain (or reproduce under enforce and
   read the audit trail).
2. Exercise the real workload: start the service, perform the failing
   operation, wait for timers.
3. Read denials:

   ```sh
   journalctl -g apparmor
   # or, depending on the host:
   dmesg | grep -i apparmor
   ausearch -m AVC -ts recent
   ```

4. Parse the record fields: `profile`, `operation`, `name`, `requested_mask`,
   `denied_mask`, `peer`, `family`, `sock_type`.
5. Add the narrowest rule that matches the denied operation. For a file, add
   the exact path and permission, plus the directory write only if creation is
   required. For a socket, add the family/type and a peer rule only if needed.
6. Re-test the same operation. Repeat until no unexplained denial remains.
7. Restore enforce mode and re-test startup and the core workload.

Do not "fix" a denial with `/** rw`, `ux`, `PUx`, or by disabling the profile.
Do not leave a profile in complain mode after the investigation.

## Common validation failures

- **`--Werror` failure on a warning.** Deprecated exec modes, undefined
  variables, or ABI mismatch. Fix the policy or document the required host
  version; do not drop `--Werror` silently.
- **Include not found.** The host lacks an abstraction or the repository path is
  wrong. `make check` does not ship the host abstractions.
- **Profile loads but does not apply.** Attachment mismatch, wrong binary path,
  or the service is already running under another profile.
- **Denial only after rotation or restart.** Ownership or directory-create
  rules, not path spelling.
- **A target stops partway.** `make load`/`make check` exit at the first
  rejection; read the last line and check `aa-status` for what is loaded.
- **Complain mode used as a "fix".** It removes enforcement and hides the
  problem; it is a diagnostic state only.

## Reporting template

When reporting validation, include:

- files reviewed and commands run (or explicitly "not run");
- whether the parser was invoked and with which flags;
- whether the profile was loaded, in which mode, and whether it was restored;
- the denial records examined and the rules added;
- residual risks and untested paths.

## References

- `AGENTS.md` for repository safety rules and command inventory.
- `apparmor-installation-and-modes` for install/load/uninstall details.
- `apparmor.d(5)`, `apparmor_parser(8)`, `aa-status(8)`, `aa-complain(8)`,
  `aa-enforce(8)`, `aa-disable(8)`.
- `journalctl(1)` and `ausearch(8)` for audit records.

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
