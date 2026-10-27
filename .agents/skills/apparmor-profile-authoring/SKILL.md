---
name: apparmor-profile-authoring
description: Author or edit AppArmor profiles and abstractions in this repository. Use when adding a new daemon profile, changing attachment or flags, selecting capabilities, network or filesystem rules, or writing a local override.
---

# AppArmor profile authoring

## Activation conditions

Use this skill when you need to:

- create a profile for a new binary;
- edit an existing file such as `usr.bin.*` or `usr.sbin.*`;
- add or change an abstraction, include, capability, network rule, filesystem
  rule, or exec transition;
- decide whether a change belongs in the shipped profile or in
  `local/<profile-file>`.

Do not use it to install, load, or switch profile modes. Use
`apparmor-installation-and-modes` for that.

## Procedure

1. **Establish facts before writing policy.** Identify the exact executable
   path, the service unit, the runtime user, and the configuration, data, log,
   socket, and PID paths. Use repository files and upstream/service
   documentation. If a fact cannot be established, write it down as an open
   question; do not guess a path or port.
2. **Choose the file name from the install path.** `/usr/bin/foo` becomes
   `usr.bin.foo`; `/usr/sbin/foo` becomes `usr.sbin.foo`. Keep the profile name
   equal to the binary basename. This repository already has a
   file-name/profile-name split, so do not rename one without the other.
3. **Write the attachment glob.** Match every real executed path, including
   symlinked locations when the service uses them. Examples in this tree:
   `/{usr/,}{,s}bin/tor`, `/{usr/,usr/local/}bin/{XD,xd-torrent}`. An
   attachment that misses the real path leaves the daemon unconfined.
4. **Start from the repository preamble.**
   ```apparmor
   abi <abi/4.0>,
   include <tunables/global>

   profile name /path/to/binary flags=(attach_disconnected, enforce, mediate_deleted) {
   ```
   Keep the existing header comment block and license pointer.
5. **Include shared policy first.** `abstractions/base`,
   `abstractions/nameservice`, and `abstractions/ssl_certs` are the normal
   baseline. Add `abstractions/python` for Python daemons and
   `abstractions/user-tmp` only when the daemon really uses user temp files.
   Do not add `abstractions/openssl` when `ssl_certs` already covers it.
6. **Add the narrowest rules that satisfy observed behavior.**
   - Capabilities: only those required before or during privilege drop. Do not
     copy `chown`, `dac_override`, or `dac_read_search` without justification.
   - Network: prefer socket-type rules (`stream`, `dgram`, `unix`) over
     protocol rules (`tcp`, `udp`) when the type is sufficient. Add
     `network unix stream` when the daemon uses a Unix socket path.
   - Filesystem: one rule per purpose. Use `owner` for per-UID data. Use `rwk`
     on a data directory and its tree, `w`/`a` for logs, and explicit `rw` for
     sockets and PID files. Grant write on a log directory if the daemon must
     create its own log file.
   - Do not use `/** rw`, `/** mrwkl`, `ux`, `Ux`, or a `PUx` fallback to make
     a denial disappear. A broad rule is a finding, not a fix.
7. **Choose exec transitions deliberately.**
   - `ix`: stay in the current profile. Use for trusted helpers that need the
     same policy.
   - `pix`: use a matching child profile if one exists, else inherit. This is
     the usual choice for an interpreter launcher.
   - `px`/`Px`: require a separate profile. Lowercase scrubs the environment;
     uppercase preserves it. `Px` is not a synonym for "more secure".
   - `cx`/`Cx`: child profile. Only use when a child profile is actually
     declared in the same file.
   - Do not use `ux` or an unconfined fallback in a shipped profile.
8. **Use `deny` only for an explicit, reviewable block.** AppArmor is already
   default-deny for paths, capabilities, and execution. A deny rule is useful
   for documenting an intentional prohibition, but it must match the real
   architecture and version; it is not a substitute for minimal allows.
9. **End with the local override include.**
   ```apparmor
   include if exists <local/usr.bin.foo>
   ```
   The path uses the file name, not the profile name.
10. **Validate statically.**
    - Confirm every include exists in the repository or is a standard host
      abstraction.
    - Confirm the attachment matches the intended binary path.
    - Confirm each writable path has a matching directory rule if the daemon
      creates files there.
    - Confirm there is no rule broader than the stated purpose.
    - Run `make check` only if the user authorized compilation; it stops at the
      first rejected profile, so check the reported file and fix it before
      rerunning.

For documentation-only edits, explain verified rule-group effects in comments
without changing policy tokens, includes, declarations, order, or line
continuations. Treat a comment-only diff as necessary evidence, not proof of
semantic equivalence: inspect the complete diff and preserve AppArmor
`#include` directives as executable syntax.

## Minimal-permission checklist

- [ ] No `/**` rule with write permissions.
- [ ] No `ux`, `Ux`, or `PUx` escape hatch.
- [ ] No `dac_override`/`dac_read_search` without a documented reason.
- [ ] No read of another service's private keys or data.
- [ ] No write outside the daemon's config, data, log, cache, and runtime
      directories (and the user's own home paths when applicable).
- [ ] Capabilities match the privilege-drop and port-binding behavior.
- [ ] Socket paths have the matching `network unix` rule.
- [ ] Logs use `a`/`w` and the directory is writable if creation is needed.
- [ ] `owner` is used where multiple UIDs can reach the same tree.

## Validation

- **Static**: attachment matches the real path; every include resolves; every
  writable path has the necessary directory permission; no `/** rw`, `ux`,
  `Ux`, or `PUx`; capabilities and `network unix` match the documented behavior.
- **Syntax**: `make check` or a per-profile
  `apparmor_parser -Q -K --Werror -I <root> <profile>`, only when execution is
  authorized. The target stops at the first parser failure, so run profiles
  individually to isolate one.
- **Runtime**: complain mode plus the real workload, then audit denials and
  restore enforce. This requires root and explicit authorization.
- Report which level was actually performed; a static review is not a runtime
  test.

## Common problems

- **Profile does not apply.** The attachment glob does not match the executed
  path, or the daemon is started from `/usr/local/bin` while the profile only
  covers `/usr/bin`.
- **Denial after rotation.** `owner` on logs fails when logrotate or systemd
  creates root-owned replacements. Use a group or path rule that matches the
  real ownership, not a blanket `/** rw`.
- **Cannot create the log.** The file rule grants `w` but the parent directory
  lacks `w`. Add the directory rule narrowly.
- **Unix socket denied.** A path rule alone is not enough on releases that
  mediate AF_UNIX; add `network unix stream` (and a peer rule only if needed).
- **Profile name confusion.** `aa-status`, `aa-complain`, and
  `aa-disable` use the profile name or file path, not the repository file
  name. Check both.
- **Warning under `--Werror`.** Deprecated or unusual modes (`PUx`), undefined
  tunables, and ABI mismatches can fail the check even when the profile loads
  elsewhere.

## References

- `AGENTS.md` for repository conventions and safety rules.
- `README.md` for the project overview.
- `apparmor.d(5)`, `apparmor_parser(8)`, and `aa-complain(8)` on the target
  system.
- Existing profiles in this repository as style examples, especially
  `usr.bin.radicale` and `usr.sbin.opendkim`.

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
