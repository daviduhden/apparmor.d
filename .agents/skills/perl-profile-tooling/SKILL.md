---
name: perl-profile-tooling
description: Use, review, or modify the repository's Perl helpers enforce-complain-toggle.pl and merge-dupe-rules.pl. Use when changing profile modes in bulk or merging duplicate rules, and when assessing the scripts' side effects.
---

# Perl profile tooling

## Activation conditions

Use this skill when the task involves:

- `scripts/enforce-complain-toggle.pl` (installed as
  `enforce-complain-toggle`);
- `scripts/merge-dupe-rules.pl` (installed as `merge-dupe-rules`);
- reviewing their safety, exit codes, backups, or side effects.

Both scripts modify system state and require authorization. Neither is a
validator.

## enforce-complain-toggle.pl

### What it does

Reads `/sys/kernel/security/apparmor/profiles`, saves the names of profiles
currently in **enforce** mode to a state file, then runs `aa-complain` for each.
`restore` reads the state file and runs `aa-enforce` for each line.

### Usage

```sh
enforce-complain-toggle.pl [--state-file PATH] [--dry-run] downgrade
enforce-complain-toggle.pl [--state-file PATH] [--dry-run] restore
enforce-complain-toggle.pl --help
```

- Default state file: `/var/lib/apparmor/enforce_to_complain.list`.
- Rejects `--state-file` paths containing `..` components before writing.
- `--dry-run` skips the `aa-*` calls and the state write, and prints the
  commands.
- `--help` prints usage and exits **0**.
- Extra positional arguments after the command are ignored.
- Exit codes: `0` success/no-op/help, `1` prerequisite or action failure, `2`
  usage error.

### Prerequisites and behavior

- Requires a mounted AppArmor security filesystem. It checks only the tool for
  the requested command (`aa-complain` for `downgrade`, `aa-enforce` for
  `restore`), and skips the tool check under `--dry-run`.
- Requires real UID 0 unless `--dry-run` is set.
- Parses only `(enforce)`, `(complain)`, and `(kill)`. Profiles in prompt mode
  are ignored.
- In a real run, writes the state file **before** switching any profile. A
  partial failure therefore leaves a snapshot that claims all listed profiles
  were enforcing.
- If the state file exists, copies it to
  `/var/backups/<path-without-leading-slash>.bak.YYYYmmdd-HHMMSS` first.
- Uses `open ">"` and truncates in place; no locking, atomic replace, or
  `fsync`.
- Passes profile names to `aa-complain`/`aa-enforce` without a `--` separator,
  so a state-file line beginning with `-` can be interpreted as an option.
- Resolves the `aa-*` tools by scanning `PATH`; an untrusted `PATH` as root is
  dangerous.

### Dry-run behavior

`--dry-run` still reads the AppArmor profiles file and prints the commands, but
it does not call `write_state_file`, does not create backups, and does not
change profile modes. The summary line is prefixed with `DRY-RUN: would switch`
so it cannot be mistaken for a completed change. It still requires the AppArmor
security filesystem to be mounted.

### Safe procedure

1. Back up the state file and record `aa-status` output.
2. Use an explicit `--state-file` under a controlled directory.
3. `--dry-run` still reads sysfs and, for `restore`, the state file; verify the
   path before running it.
4. Run `downgrade` only with a plan to restore, and keep the state file safe.
5. Verify with `aa-status`; do not trust the summary line alone.
6. After diagnosis, run `restore` and verify every profile is back in enforce
   mode.
7. Never leave production profiles in complain mode.

## merge-dupe-rules.pl

### What it does

Scans a policy directory for **consecutive duplicate simple file rules** with
the same indentation, qualifiers, and path, and merges them by unioning base
permissions. It is dry-run by default.

### Usage

```sh
merge-dupe-rules.pl [--policy-dir DIR] [--apply] \
  [--backup-suffix SUFFIX] [--verbose]
```

- Default policy directory: `/etc/apparmor.d`.
- `--policy-dir` must exist and must not contain `..` components.
- Without `--apply`, it only prints the plan and exits 2 if changes would be
  made.
- `--backup-suffix` defaults to `.bak.YYYYmmdd-HHMMSS`; backups go under
  `/var/backups/<path-without-leading-slash><suffix>`.
- `-h`/`--help` prints usage to stderr and exits 0.
- Exit codes: `0` no changes/success, `2` changes planned in dry-run or
  write/backup errors during `--apply`, and `2` for an invalid directory or
  usage error. Unreadable files are silently skipped rather than reported.
  `die_tool` is defined but never used.

### Parsing scope

It only parses rules that:

- end with a comma;
- are not `include`/`#include`;
- are not `dbus`, `capability`, `network`, `mount`, `signal`, `ptrace`, `unix`,
  `change_profile`, or `profile` rules;
- do not contain `->` (rename/link);
- have a path starting with `/` or `@{...}`;
- use only `audit`, `deny`, and `owner` qualifiers (in any order).

Base permissions are limited to `r`, `w`, `a`, `l`, `m`, `k` plus one exec
qualifier. Bare `x` is intentionally not merged. Conflicting exec qualifiers or
unknown characters leave the rule untouched.

### Merge behavior and traps

- Duplicate detection is by `indent | qualifiers | path`; only **consecutive**
  duplicates are merged.
- Base permissions are unioned and reordered to `rwalmk`; `a` is dropped when
  `w` is present because `w` implies append.
- Every parseable rule is canonicalized, even when it is not a duplicate.
- Quoted paths keep their internal whitespace; only qualifiers and permission
  strings are normalized. A path containing two spaces is preserved.
- Inline comments: the first duplicate's comment is kept; a later duplicate's
  comment is dropped when the first already has one.
- Blank/comment-only lines between duplicates are collected and emitted
  **after** the merged rule.
- `#include` lines are treated as comments by `split_comment`, so they can be
  moved after a merged rule.
- The whole `--policy-dir` is scanned recursively, including `abstractions/`,
  `tunables/`, `local/`, `abi/`, and any non-policy text file. Symlinks,
  directories, cache paths, common backup/editor suffixes, and this script's
  `.bak.YYYYmmdd-HHMMSS` backups are skipped.
- `--backup-suffix` is rejected if it contains `/` or `..`; keep it a plain
  suffix.
- Writes use a same-directory temp file with `O_EXCL`, chmod/chown to the
  original metadata, then `rename`. There is no `flock`, no `fsync`, and no
  check for concurrent edits between planning and applying.
- Backups use second-resolution timestamps and `File::Copy::copy` overwrites an
  existing file, so two runs in the same second can destroy the earlier backup.
- It does not reload or parse AppArmor policy.

### Safe procedure

1. Copy the target directory to a scratch location; never point `--apply` at
   `/` or a live `/etc/apparmor.d` during review.
2. Run without `--apply` and inspect the complete plan, not only the first 30
   files it prints.
3. Diff the scratch copy (`diff -u`), looking for changed quoted paths, moved
   comments/includes, and canonicalized permissions.
4. Run `make check` on the result only with authorization.
5. Apply with an explicit, narrow `--policy-dir`, an explicit backup suffix,
   and a pre-existing backup. Verify the backup content.
6. Re-run the script on the result to confirm idempotency; investigate any
   second-pass change.

## Static review of the scripts

When execution is not authorized, verify by reading:

- shebang and core modules (`Getopt::Long`, `File::Path`, `File::Copy`,
  `File::Basename`, `Fcntl`, `POSIX`);
- option parsing and defaults;
- exit codes and `usage` behavior;
- every file path written, and whether it is created or truncated;
- whether dry-run actually skips writes;
- whether paths and profile names are quoted or separated with `--`;
- backup naming, permissions, and collision behavior.

For documentation-only changes, add comments next to the algorithm or
side-effect boundary they explain. Describe regexes as the script's limited
text recognizers, not as full AppArmor parsers; preserve executable Perl,
regexes, quoting, and heredocs byte-for-byte. The repository also has
`scripts/validate-agent-knowledge.py`, a read-only structural checker for instruction
updates; run it from the repository per `AGENTS.md`, but do not treat it as a
policy parser or as evidence that documentation is semantically complete.

`perl -c` is a syntax check, but it executes the Perl interpreter. Use it only
when execution is authorized; it is not part of a documentation-only review.

## Validation

- Run both scripts against a **copy** of the policy tree, never the live one.
- For the toggle, verify the state file, the backup, and `aa-status` after
  `downgrade` and after `restore`.
- For the merger, diff the scratch copy and re-run to confirm idempotency.
- Run `make check` on changed profiles only with authorization.
- The toggle's `--dry-run` no longer writes state; still verify the state file
  path used by `restore`.
- Report the commands actually run and the resulting exit codes.

## Common problems

- **State file overwritten during a real run.** The previous file is backed up
  under `/var/backups`; verify the backup timestamp.
- **Restore does nothing.** Missing/empty state file returns success with a
  warning; check the path and contents.
- **Complain toggle affects unrelated profiles.** It operates on every profile
  in enforce mode, not just this repository's eight.
- **Merge script changed a path it should not have.** Quoted whitespace
  normalization; restore from backup and fix the input.
- **Merge script moved a comment or `#include`.** Known ordering behavior;
  review the diff, do not assume a pure duplicate merge.
- **Backup missing or overwritten.** Same-second timestamp collision or an
  unsanitized suffix; keep an external backup.

## References

- `AGENTS.md` for safety rules.
- `apparmor-installation-and-modes` for mode semantics.
- `apparmor-policy-validation` for validating the resulting policy.
- `aa-complain(8)`, `aa-enforce(8)`, `apparmor_parser(8)`, `perl(1)`,
  `File::Copy`, `File::Find`, `Getopt::Long`.

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
