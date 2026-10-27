# AGENTS.md

Short operating guide for AI agents working in this repository. Human-facing
documentation lives in `README.md`; task-specific procedures live in
`.agents/skills/`.

## What this repository is

A small collection of AppArmor profiles for network daemons and helpers, one
shared abstraction, two Perl maintenance scripts, and a Python agent-sync
validator. There is no application code, automated test suite, or CI workflow.

## Architecture

- **Profiles** live at the repository root and are named after the installed
  binary path: `usr.bin.<name>` for `/usr/bin`, `usr.sbin.<name>` for
  `/usr/sbin`. The file name is not the profile name; the profile declaration
  uses the binary basename (for example `usr.bin.radicale` contains
  `profile radicale ...`).
- **Attachment** is an AppArmor path glob inside the profile declaration. A
  profile only applies when the executed path matches that glob.
- **`abstractions/tor`** holds shared Tor rules (includes, network, devices,
  capabilities, pluggable transports). It is included by `usr.sbin.tor`.
- **`scripts/*.pl`** are installed without the `.pl` suffix. The standalone
  `scripts/check-agent-sync.py` is a manually run repository validator and is
  not installed.
- **`Makefile`** installs, loads, syntax-checks, and uninstalls policy. It also
  creates empty `local/<profile-file>` stubs. Profiles end with
  `include if exists <local/<profile-file>>`.
- **Generated state**: `local/` files, installed copies under
  `/etc/apparmor.d`, and helper scripts under `$(PREFIX)/local/bin` are not
  tracked by Git.

## Non-negotiable safety rules

1. **Default to static analysis.** Read files; do not compile, load, enforce,
   complain, disable, install, or uninstall unless the user explicitly asks for
   that action and understands the system impact.
2. **Never run a bare `make`** (the default target is `install`), and never run
   `make install`, `make load`, `make uninstall`, or `make unload-profiles` as a
   validation step. They write `/etc`, `/usr/local`, and kernel policy;
   `uninstall` can mask failures, while `install` aborts on copy/diversion
   errors.
3. **Do not use `sudo`, `aa-*`, `apparmor_parser -r`, `dpkg-divert`, or writes
   under `/etc/apparmor.d`** unless the task is explicitly about installation
   or runtime verification and the user authorized it.
4. **Do not weaken confinement to make a denial disappear.** Do not add
   `/** rw`, `ux`, `Ux`, or a `PUx` fallback that can escape to an unconfined
   profile. Grant the narrowest path, permission, capability, or socket family
   that the daemon actually needs, and say why.
5. **Do not invent paths, ports, users, service units, or commands.** If a
   deployment detail is unknown, record it as an open question instead of
   encoding a guess in policy.
6. **Never commit, push, rebase, or rewrite history** unless explicitly asked.
   Do not discard pre-existing work.

## Conventions

- Use `abi <abi/4.0>,` and `include <tunables/global>` at the top of every
  profile.
- Include `abstractions/base`, `abstractions/nameservice`, and
  `abstractions/ssl_certs` unless there is a documented reason not to.
  `abstractions/ssl_certs` already pulls in OpenSSL rules; do not add
  `abstractions/openssl` on top without checking.
- Two-space indentation inside profile blocks. Keep the existing header block:
  title, `# Purpose: ...`, blank comment line, license pointer.
- Declare `flags=(attach_disconnected, enforce, mediate_deleted)` unless the
  file already uses a deliberate variant. A profile is disabled by removing or
  disabling the whole file, not by adding a rule.
- Put site-specific changes in `local/<profile-file>`, not in the shipped
  profile. `make uninstall` removes empty local stubs but preserves non-empty
  overrides; keep external backups anyway.
- Prefer `owner` on per-user data, append-only `a` for logs where possible, and
  explicit socket paths plus the matching `network unix` rules. `owner` means
  "owned by the confined process UID"; it does not mean "installed by a user".
- Preserve the ISC license header. The project is
  `Copyright (c) 2025-2026 David Uhden Collado <david@uhden.dev>`.

## Commands that actually exist

| Purpose | Command | Notes |
| --- | --- | --- |
| Syntax gate (no kernel load) | `make check` | Needs `apparmor_parser` and host AppArmor includes. Compiles in a temp tree with `-Q -K --Werror`. Not hermetic; stops at the first rejected profile. |
| Help | `make help` | Prints targets and a subset of variables. |
| Placeholder | `make test` | Prints "No automated tests defined"; it is not a test suite. |
| Install | `make install` | Writes `/etc/apparmor.d`, may run `dpkg-divert`, writes helper scripts, creates `local/` stubs. Root normally required. |
| Load | `make load` | Depends on `install` and `unload-profiles`; loads installed files with `-r -T -W` and stops at the first failure. Root required. |
| Uninstall | `make uninstall` | Deletes shipped policy and empty `local/<profile-file>` stubs; preserves non-empty overrides; does not unload kernel policy; can mask failures. |
| Enforce/complain toggle | `enforce-complain-toggle.pl [--state-file PATH] [--dry-run] downgrade\|restore` | Installed as `enforce-complain-toggle`. Requires `aa-complain`/`aa-enforce` and root for real changes. |
| Duplicate-rule merger | `merge-dupe-rules.pl [--policy-dir DIR] [--apply] [--backup-suffix SUFFIX] [--verbose]` | Dry-run by default. Installed as `merge-dupe-rules`. |
| Agent/skill synchronization | `python3 scripts/check-agent-sync.py --base <base-ref> [--head <head-ref>]` | Requires substantive instruction updates for project changes; checks instruction structure and local Markdown references. |

There is no build step, no unit-test command, linter configuration, or CI
workflow. The agent-sync validator is run manually; do not describe it as a
policy syntax check.

## Validation levels

Keep these distinct in reports:

1. **Static analysis**: reading files, comparing attachments and includes,
   checking that referenced paths and scripts exist. Safe and always allowed.
2. **Syntax check**: `make check` (or a per-profile `apparmor_parser -Q -K
   --Werror -I <include-root> <profile>`), only when execution is authorized.
   This compiles policy but does not load it.
3. **Build/install**: `make install` into a staging `DESTDIR`. Changes files;
   requires authorization. Never present it as a test.
4. **Runtime verification**: loading a profile, switching to complain,
   exercising the daemon, and reading `journalctl -g apparmor` or the audit log.
   Requires root and explicit authorization; never leave a daemon in complain
   mode.

For a documentation-only task, only level 1 applies. State clearly which levels
were actually run and which were skipped.

## Preexisting changes

Before editing, inspect `git status` and `git diff` (or read the files if shell
use is not authorized). Treat unrelated modifications as the user's work: do not
revert, reformat, or "clean up" them. Add only the files needed for the task and
report any collision or suspicious change instead of overwriting it.

## Known traps in this tree

These are observed in the current sources; document them, do not silently rely
on them:

- `make check` relies on host-installed `abstractions/*`, `tunables/global`, and
  `abi/4.0`, and it creates empty `local/` stubs instead of using real
  overrides.
- `make load` runs `install` and `unload-profiles` first; `unload-profiles`
  uses the installed files but still treats removal failures as warnings.
- `make uninstall` preserves non-empty `local/<profile-file>` overrides, but
  it still masks diversion and removal failures.
- Only `usr.bin.i2pd`, the distro-only `system_tor`, and `abstractions/tor` are
  diverted. Other same-named distro files can be overwritten when diversion is
  unavailable or disabled.
- `enforce-complain-toggle.pl` writes its state file before switching profiles,
  so a partial `downgrade` leaves a snapshot that claims all were enforcing.
- `merge-dupe-rules.pl` scans every regular file under `--policy-dir`
  recursively, including `abstractions/`, `tunables/`, `local/`, and `abi/`, and
  can move comments or include lines that sit between duplicate rules.
- `usr.sbin.tor`'s instance data is not `owner`-qualified, and the Tor
  abstraction executes `obfsproxy` with `PUx`, an unconfined fallback when no
  profile matches.
- `usr.bin.radicale` reads all of `/etc/ssl/private/**`, grants `dac_override`,
  reads `/proc/**`, and its compiler denies cover only one aarch64 GCC 14
  layout.

## Skills

| Skill | Activate when |
| --- | --- |
| `apparmor-profile-authoring` | Creating or editing a profile, abstraction, or local override; choosing rules and exec modes. |
| `daemon-specific-policy-review` | Reviewing Tor, i2pd, monerod, monero-lws, Radicale, OpenDKIM, Fail2Ban, or xd-torrent policy. |
| `apparmor-policy-validation` | Checking syntax, auditing denials, or deciding what "validated" means. |
| `apparmor-installation-and-modes` | Installing, loading, uninstalling, or switching enforce/complain/disabled state. |
| `perl-profile-tooling` | Using or changing `enforce-complain-toggle.pl` or `merge-dupe-rules.pl`. |

## Continuous Agent & Skills Maintenance

Agent instructions and skills are living repository artifacts.

Every repository modification MUST include an agent/skills synchronization step.

Before completing any task, inspect the applicable AGENTS.md and SKILL.md files, update the affected instructions, and validate their consistency with the implementation.

A code change without the corresponding agent knowledge maintenance is considered incomplete.

Never claim completion when the synchronization step has been skipped or has failed.

This requirement applies to every tracked repository change: policy, scripts,
configuration, dependencies, tests, workflows, documentation, and repository
structure. Perform one complete synchronization review at the end of each task;
repeat only if that review or its validation finds an error.

### Required procedure

1. Inspect `AGENTS.md` files from the repository root through the changed
   paths, plus all applicable `.agents/skills/**/SKILL.md` files. Also inspect
   `.github/agents/*.agent.md`, `.github/skills/**/SKILL.md`,
   `.claude/skills/**/SKILL.md`, and tool-specific instructions (for example
   `.github/copilot-instructions.md`, `.cursor/rules/**`, and `CLAUDE.md`) when
   present. Do not assume this list is exhaustive; discover instruction files
   for tools used by this repository.
2. Map changed components to skills using each skill's activation conditions
   and the Skills table above. Review specialized agent instructions for the
   same responsibility. If no skill applies, decide whether a reusable
   procedure warrants a new skill or belongs in an existing one.
3. Update at least one relevant agent instruction or skill for every repository
   change. Make a specific, reusable correction or addition reflecting changed
   behavior, a verified procedure, a changed path/command, or a discovered
   repository convention. Never add timestamps, empty edits, or execution-only
   notes to satisfy the rule. Update every other affected instruction too.
4. When changing agent or skill policy itself, review the whole instruction
   system, including this section, all skill links and names, and the validator
   and validator. Avoid recursive edits: one complete review after the task is
   sufficient unless it finds an error.
5. Validate the changed instruction files' structure and local references, and
   run `python3 scripts/check-agent-sync.py --base <base-ref>`. No CI workflow
   invokes this check. It cannot judge whether the knowledge change is
   semantically relevant; the author must review that in the diff.
6. Report which agents and skills were reviewed, which instruction files
   changed, what reusable knowledge was added or corrected, commands actually
   run, and synchronization status.

### Agent and skill authoring requirements

- Every specialized agent must include a **Post-Change Knowledge
  Synchronization** section requiring review of its related skills and own
  instructions after any repository modification, updates for reusable
  findings or changed behavior, applicable validation, and a synchronization
  result in its final report.
- Every `SKILL.md` must preserve its Agent Skills YAML frontmatter and include a
  **Maintenance & Continuous Learning** section. When used for a repository
  modification, review and update it for changed procedures, tools,
  configuration, assumptions, reusable findings, corrections, examples, and
  validation. Exclude execution-specific notes that will not help future use.
- Create a skill only for a distinct, reusable workflow without an appropriate
  existing skill. Otherwise extend the closest skill and its activation
  conditions. Keep agent and skill responsibilities and cross-references
  aligned.

### Mandatory Definition of Done

- [ ] Repository changes implemented.
- [ ] Relevant agent instructions reviewed.
- [ ] Relevant skills reviewed.
- [ ] Affected AGENTS.md / SKILL.md files updated.
- [ ] Obsolete knowledge removed.
- [ ] New reusable knowledge incorporated.
- [ ] Agent and skill references validated.
- [ ] Automated maintenance checks passed.
- [ ] Final synchronization status reported.

If a check fails, correct it or explicitly declare the task incomplete and
identify the limitation. The final report must contain **Agent & Skills
Synchronization** with agents reviewed, skills reviewed, instruction files
updated, knowledge incorporated/corrected, validations actually run, and
**PASS** or **FAIL**. The automated validator checks structural conditions and
detectable local references only; human review must establish semantic
relevance. Never report a check as passed unless it ran successfully.

## License

ISC. See `LICENSE`; preserve the copyright and permission notice in copies.
