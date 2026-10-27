"""Check that repository changes include substantive agent/skill maintenance.

This is a structural guard, not a semantic relevance judge. Use --base with a
Git ref containing the last synchronized repository state (the PR base in CI).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC_PATTERNS = (
    "AGENTS.md",
    "**/AGENTS.md",
    ".github/agents/*.agent.md",
    ".agents/skills/**/SKILL.md",
    ".github/skills/**/SKILL.md",
    ".claude/skills/**/SKILL.md",
    "**/CLAUDE.md",
    ".github/copilot-instructions.md",
    ".cursor/rules/**",
)


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout


def tracked_paths(base: str, head: str | None) -> set[str]:
    if head:
        raw = git("diff", "--name-only", "-z", f"{base}...{head}")
    else:
        raw = git("diff", "--name-only", "-z", base)
        raw += "\0" + git("diff", "--cached", "--name-only", "-z")
    paths = {p for p in raw.split("\0") if p}
    if not head:
        status = git("ls-files", "--others", "--exclude-standard", "-z")
        paths.update(p for p in status.split("\0") if p)
    return paths


def instruction_files() -> set[Path]:
    found: set[Path] = set()
    for pattern in DOC_PATTERNS:
        found.update(p for p in ROOT.glob(pattern) if p.is_file())
    return found


def is_instruction(path: str) -> bool:
    p = Path(path)
    return (
        p.name == "AGENTS.md"
        or p.name == "SKILL.md"
        or p.name.endswith(".agent.md")
        or p.name == "CLAUDE.md"
        or path in {".github/copilot-instructions.md"}
        or path.startswith(".cursor/rules/")
    )


def substantive_changed_lines(base: str, head: str | None, path: str) -> list[str]:
    if head:
        diff = git(
            "diff", "--no-ext-diff", "--unified=0", f"{base}...{head}", "--", path
        )
    else:
        diff = git("diff", "--no-ext-diff", "--unified=0", base, "--", path)
        diff += git("diff", "--cached", "--no-ext-diff", "--unified=0", "--", path)
    changed_lines = []
    for line in diff.splitlines():
        if line[:1] not in {"+", "-"} or line.startswith(("+++", "---")):
            continue
        content = line[1:].strip()
        if not content or content.startswith("#"):
            continue
        if re.match(
            r"(?i)^(updated?|modified|generated)\s*:?\s*\d{4}[-/]\d{2}", content
        ):
            continue
        changed_lines.append(content)
    if not diff and not head:
        candidate = ROOT / path
        if candidate.is_file():
            changed_lines.extend(
                line.strip()
                for line in candidate.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            )
    return changed_lines


def validate_document(path: Path) -> list[str]:
    errors: list[str] = []
    relative = path.relative_to(ROOT).as_posix()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"{relative}: cannot read UTF-8 document ({exc})"]

    if path.name == "SKILL.md":
        if not text.startswith("---\n"):
            errors.append(f"{relative}: missing YAML frontmatter opening delimiter")
        else:
            end = text.find("\n---\n", 4)
            if end < 0:
                errors.append(f"{relative}: missing YAML frontmatter closing delimiter")
            else:
                frontmatter = text[4:end]
                for field in ("name", "description"):
                    if not re.search(rf"(?m)^{field}:\s*\S", frontmatter):
                        errors.append(
                            f"{relative}: frontmatter requires nonempty {field}"
                        )
        if not re.search(r"(?m)^## Maintenance & Continuous Learning\s*$", text):
            errors.append(
                f"{relative}: missing Maintenance & Continuous Learning section"
            )
    if path.name.endswith(".agent.md") and not re.search(
        r"(?m)^## Post-Change Knowledge Synchronization\s*$", text
    ):
        errors.append(
            f"{relative}: missing Post-Change Knowledge Synchronization section"
        )

    for target in re.findall(r"(?<!!)\[[^\]]*\]\(([^)]+)\)", text):
        target = target.strip().split()[0].split("#", 1)[0]
        if not target or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
            continue
        candidate = (path.parent / target).resolve()
        try:
            candidate.relative_to(ROOT)
        except ValueError:
            errors.append(f"{relative}: local reference escapes repository: {target}")
            continue
        if not candidate.exists():
            errors.append(f"{relative}: local reference does not exist: {target}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="Git base ref before the changes")
    parser.add_argument(
        "--head",
        help="Git head ref (CI); omit to include working tree and staged files",
    )
    args = parser.parse_args()
    try:
        changed = tracked_paths(args.base, args.head)
        if not changed:
            print("Agent sync check: no repository changes detected.")
            return 0
        project_changes = sorted(p for p in changed if not is_instruction(p))
        changed_docs = sorted(p for p in changed if is_instruction(p))
        if project_changes and not changed_docs:
            print(
                "FAIL: repository changes require a substantive AGENTS.md, agent, or SKILL.md update.",
                file=sys.stderr,
            )
            print(
                "Changed project files:\n  " + "\n  ".join(project_changes),
                file=sys.stderr,
            )
            return 1
        if changed_docs and not any(
            substantive_changed_lines(args.base, args.head, p) for p in changed_docs
        ):
            print(
                "FAIL: instruction changes contain no substantive guidance (empty, heading-only, or timestamp-only edits do not count).",
                file=sys.stderr,
            )
            return 1
        errors: list[str] = []
        for path in sorted(instruction_files()):
            errors.extend(validate_document(path))
        if errors:
            print("FAIL: agent instruction validation errors:", file=sys.stderr)
            print("\n".join(f"  - {e}" for e in errors), file=sys.stderr)
            return 1
        print(
            "PASS: changed files include a substantive instruction update and instruction structure/local references are valid."
        )
        print(
            "Changed instructions: "
            + (
                ", ".join(changed_docs)
                if changed_docs
                else "none (instruction-only change set)"
            )
        )
        print("Semantic relevance still requires review of the diff.")
        return 0
    except (RuntimeError, OSError) as exc:
        print(f"FAIL: agent sync check could not complete: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
