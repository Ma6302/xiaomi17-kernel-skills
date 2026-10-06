#!/usr/bin/env bash
# install-to-operit.sh
#
# Installs this repository's skills into an agent's skills directory.
#
# The default target is Operit AI's skills directory on Android:
#   /sdcard/Download/Operit/skills
# which is where Operit looks for a skill's SKILL.md. Copying is the default
# because Operit's file picker and SAF layer do not reliably follow symlinks;
# use --link only if your setup does.
#
# Usage:
#   bash scripts/install-to-operit.sh                # copy into Operit's skills dir
#   bash scripts/install-to-operit.sh --link         # symlink instead of copy
#   bash scripts/install-to-operit.sh --target DIR   # any other skills directory
#   bash scripts/install-to-operit.sh --only NAME    # a single skill
#   bash scripts/install-to-operit.sh --check        # validate and report, change nothing
#
# After installing, bind the skills to a character in Operit (or enable them
# for the agent you use), then start a NEW conversation so the skill list is
# rebuilt.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/skills"

MODE=copy
TARGET=""
ONLY=""
CHECK=0

usage() {
  cat <<'EOF'
Usage: bash scripts/install-to-operit.sh [options]

  --link            symlink the skills instead of copying them
  --target DIR      install into DIR instead of Operit's download dir
  --only NAME       install only skills/NAME
  --check           validate and report; do not change anything
  -h, --help        show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --link)   MODE=link; shift ;;
    --copy)   MODE=copy; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --only)   ONLY="${2:-}"; shift 2 ;;
    --check)  CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- never install a malformed skill -------------------------------------
if [ -f "$SCRIPT_DIR/validate-skills.sh" ]; then
  echo "== validating =="
  if ! bash "$SCRIPT_DIR/validate-skills.sh"; then
    echo
    echo "Refusing to install: fix the FAIL rows above first." >&2
    echo "(A malformed skill is silently ignored at runtime, so installing it" >&2
    echo " would look like the agent ignoring your instructions.)" >&2
    exit 1
  fi
  echo
fi

# ---- resolve the target --------------------------------------------------
if [ -z "$TARGET" ]; then
  if [ -d /sdcard/Download ] || [ -d /sdcard ]; then
    TARGET=/sdcard/Download/Operit/skills
  elif [ -d /storage/emulated/0/Download ]; then
    TARGET=/storage/emulated/0/Download/Operit/skills
  else
    echo "ERR: could not find an Android Download directory." >&2
    echo "     Pass the skills directory explicitly, e.g. --target ~/.dsh/skills" >&2
    exit 2
  fi
fi

echo "target : $TARGET"
echo "mode   : $MODE"
echo

if [ "$CHECK" -eq 1 ]; then
  echo "--check was given; nothing was changed."
  exit 0
fi

mkdir -p "$TARGET" || { echo "ERR: cannot create $TARGET" >&2; exit 2; }

installed=0
for skill_dir in "$SRC_DIR"/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename -- "$skill_dir")"

  if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
    continue
  fi
  [ -f "$skill_dir/SKILL.md" ] || continue

  dest="$TARGET/$name"

  # Guard: only ever replace a directory that is a direct child of TARGET and
  # carries the same name we are installing.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    case "$dest" in
      "$TARGET"/*) : ;;
      *) echo "REFUSING: $dest is not inside $TARGET" >&2; continue ;;
    esac
    [ "$(basename -- "$dest")" = "$name" ] || {
      echo "REFUSING: refusing to replace $dest" >&2; continue; }
    rm -rf -- "$dest"
  fi

  if [ "$MODE" = link ]; then
    ln -s -- "$skill_dir" "$dest"
    echo "linked  $name"
  else
    cp -R -- "$skill_dir" "$dest"
    echo "copied  $name"
  fi
  installed=$((installed + 1))
done

echo
if [ "$installed" -eq 0 ]; then
  if [ -n "$ONLY" ]; then
    echo "ERR: no skill named '$ONLY' found in $SRC_DIR" >&2
    exit 2
  fi
  echo "ERR: nothing installed" >&2
  exit 2
fi

cat <<EOF
installed $installed skill(s) into $TARGET

Next step, inside Operit: bind these skills to the character you use, then
start a NEW conversation so the skill list is rebuilt from disk.
EOF
