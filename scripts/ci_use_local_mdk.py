"""CI helper: rewrite project.yml to use the local mdk-swift clone.

mdk-swift stores its xcframework .a files in Git LFS. Xcode's embedded git
does not reliably smudge LFS objects during SPM package resolution, causing
"Couldn't check out revision" failures. As a workaround CI clones mdk-swift
with explicit `git lfs pull` into vendor/mdk-swift and this script patches
project.yml to reference that local clone, bypassing SPM resolution entirely.
"""
import re
import pathlib

p = pathlib.Path("project.yml")
original = p.read_text()
patched = re.sub(
    r"  MDKBindings:\n    url: [^\n]+\n    (?:branch|revision): [^\n]+",
    "  MDKBindings:\n    path: vendor/mdk-swift",
    original,
)
if patched == original:
    raise SystemExit("ERROR: MDKBindings remote reference not found in project.yml — pattern mismatch")
p.write_text(patched)
print("project.yml patched: MDKBindings -> vendor/mdk-swift")
