#!/usr/bin/env bash
set -euo pipefail

AMSMB2_REV="8d8e19ebeaf71cca1f66b3689034b58ba333c44f"
VENDOR_DIR="Vendor/AMSMB2"

PATCH_PROJECT_YML=0
if [ "${1:-}" = "--patch-project-yml" ]; then
  PATCH_PROJECT_YML=1
fi

mkdir -p Vendor

if [ -d "$VENDOR_DIR/.git" ]; then
  git -C "$VENDOR_DIR" fetch --depth 1 origin "$AMSMB2_REV" || git -C "$VENDOR_DIR" fetch origin
  git -C "$VENDOR_DIR" checkout --force "$AMSMB2_REV"
  git -C "$VENDOR_DIR" reset --hard "$AMSMB2_REV"
  git -C "$VENDOR_DIR" clean -fd
else
  rm -rf "$VENDOR_DIR"
  git clone --no-checkout https://github.com/amosavian/AMSMB2.git "$VENDOR_DIR"
  git -C "$VENDOR_DIR" fetch --depth 1 origin "$AMSMB2_REV" || true
  git -C "$VENDOR_DIR" checkout --force "$AMSMB2_REV"
fi

git -C "$VENDOR_DIR" submodule sync --recursive
git -C "$VENDOR_DIR" submodule update --init --depth 1 --recursive

python3 scripts/patch_amsmb2.py "$VENDOR_DIR"

if [ "$PATCH_PROJECT_YML" -eq 1 ]; then
  python3 - << 'PYEOF'
import pathlib, re

p = pathlib.Path("project.yml")
txt = p.read_text(encoding="utf-8")
pattern = re.compile(
    r"(\n\s*AMSMB2:\s*\n)\s*url:\s*https://github\.com/amosavian/AMSMB2\.git\s*\n\s*revision:\s*[0-9a-fA-F]+\s*\n"
)
replaced, count = pattern.subn(r"\1    path: Vendor/AMSMB2\n", txt, count=1)
if count != 1:
    raise RuntimeError(f"Failed to patch AMSMB2 block in project.yml (count={count})")
p.write_text(replaced, encoding="utf-8")
print("Updated project.yml to use local Vendor/AMSMB2")
PYEOF
fi
