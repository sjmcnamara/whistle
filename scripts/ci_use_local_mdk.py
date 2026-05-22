"""CI helper: rewrite project.yml to use the local mdk-swift clone.

mdk-swift stores its xcframework .a files in Git LFS. Xcode's embedded git
does not reliably smudge LFS objects during SPM package resolution, causing
"Couldn't check out revision" failures. As a workaround CI clones mdk-swift
with explicit `git lfs pull` into vendor/mdk-swift and this script patches
project.yml to reference that local clone, bypassing SPM resolution entirely.

Run with --print-revision to emit the pinned commit (used by the clone
step to fetch the right SHA before patching).
"""
import re
import sys
import pathlib

MDK_PATTERN = r"  MDKBindings:\n    url: [^\n]+\n    revision: ([^\n]+)"

p = pathlib.Path("project.yml")
original = p.read_text()

match = re.search(MDK_PATTERN, original)
if not match:
    raise SystemExit(
        "ERROR: MDKBindings must use 'revision: <sha>' in project.yml. "
        "'branch:' is not honored by CI (the clone step needs a fixed SHA)."
    )
revision = match.group(1).strip()

if "--print-revision" in sys.argv:
    print(revision)
    sys.exit(0)

patched = re.sub(
    MDK_PATTERN,
    "  MDKBindings:\n    path: vendor/mdk-swift",
    original,
)
p.write_text(patched)
print(f"project.yml patched: MDKBindings -> vendor/mdk-swift (pinned at {revision})")
