#!/usr/bin/env bash
# validate-skills.sh
#
# Structural checker for this repository's skills. A malformed skill is
# SILENTLY IGNORED by the agent runtime, which surfaces to the user as "the
# agent ignored my instructions" rather than as an error — so run this after
# any edit.
#
# Usage:
#   bash scripts/validate-skills.sh
#
# Exit status: 0 = every skill is well-formed, 1 = at least one problem.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/skills"

FM_LIMIT=1024        # hard limit on the frontmatter block, in characters
BODY_MIN=1200        # warn below this: too thin to be worth loading
BODY_MAX=24000       # warn above this: too big to read in one go

if [ ! -d "$SRC_DIR" ]; then
  echo "FATAL: no skills/ directory at $SRC_DIR" >&2
  exit 1
fi

problems_total=0
warnings_total=0
checked=0

printf '%-32s %6s %6s  %s\n' 'SKILL' 'FM_CH' 'BODY_CH' 'STATUS'
printf -- '------------------------------------------------------------------------\n'

for skill_md in "$SRC_DIR"/*/SKILL.md; do
  [ -e "$skill_md" ] || continue
  checked=$((checked + 1))

  dir="$(dirname -- "$skill_md")"
  id="$(basename -- "$dir")"

  body_chars="$(wc -c < "$skill_md" | tr -d ' ')"

  # --- frontmatter must be delimited by --- on line 1 and a later --- line ---
  first_line="$(head -n 1 "$skill_md")"
  if [ "$first_line" != "---" ]; then
    printf '%-32s %6s %6s  %s\n' "$id" "$body_chars" '-' 'FAIL: line 1 is not ---'
    problems_total=$((problems_total + 1))
    continue
  fi

  closing_line="$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$skill_md")"
  if [ -z "$closing_line" ]; then
    printf '%-32s %6s %6s  %s\n' "$id" "$body_chars" '-' 'FAIL: frontmatter is never closed with ---'
    problems_total=$((problems_total + 1))
    continue
  fi

  fm="$(awk -v last="$closing_line" 'NR>1 && NR<last {print}' "$skill_md")"
  fm_chars="$(printf '%s' "$fm" | wc -c | tr -d ' ')"
  fm_chars=$((fm_chars - 1))   # trailing newline added by command substitution

  name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)"
  desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -n 1)"

  problems=""
  warnings=""

  [ -n "$name" ] || problems="$problems no-name;"
  [ -n "$desc" ] || problems="$problems no-description;"

  if [ -n "$name" ]; then
    case "$name" in
      *[!a-z0-9-]*) problems="$problems name-must-be-lowercase-alnum-hyphen;" ;;
    esac
    case "$name" in
      *claude*|*anthropic*) problems="$problems name-uses-reserved-word;" ;;
    esac
    [ "$name" = "$id" ] || problems="$problems name-does-not-match-directory-name;"
  fi

  [ "$fm_chars" -le "$FM_LIMIT" ] || \
    problems="$problems frontmatter-${fm_chars}chars-exceeds-${FM_LIMIT};"

  # The description must read as a trigger, not as a summary of the procedure.
  case "$desc" in
    *用于*|*Use\ when*|*当*) : ;;
    *) warnings="$warnings description-does-not-look-like-a-trigger;" ;;
  esac
  case "$desc" in
    *然后*|*首先*|*步骤*) \
      warnings="$warnings description-looks-like-it-summarises-the-procedure;" ;;
  esac

  [ "$body_chars" -ge "$BODY_MIN" ] || \
    warnings="$warnings SKILL.md-is-only-${body_chars}-chars;"
  [ "$body_chars" -le "$BODY_MAX" ] || \
    warnings="$warnings SKILL.md-is-${body_chars}-chars-move-detail-to-references;"

  # A skill that ships scripts must not rely on the executable bit.
  # 在 Windows 的 Git bash（MSYS/MINGW/CYGWIN）上 NTFS 文件一律被报告为可执行，
  # 这个检查在那里只会产生假阳性，所以只在真正的 POSIX 文件系统上做。
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *)
      if [ -d "$dir/scripts" ]; then
        for s in "$dir"/scripts/*; do
          [ -f "$s" ] || continue
          if [ -x "$s" ]; then
            warnings="$warnings executable-bit-set-on-$(basename -- "$s")-docs-should-say-bash-scripts/;"
          fi
        done
      fi
      ;;
  esac

  if [ -n "$problems" ]; then
    status="FAIL:$problems"
    problems_total=$((problems_total + 1))
  elif [ -n "$warnings" ]; then
    status="warn:$warnings"
    warnings_total=$((warnings_total + 1))
  else
    status="ok"
  fi

  printf '%-32s %6s %6s  %s\n' "$id" "$fm_chars" "$body_chars" "$status"
done

printf -- '------------------------------------------------------------------------\n'
printf 'checked=%s  failing=%s  warning=%s\n' "$checked" "$problems_total" "$warnings_total"

if [ "$checked" -eq 0 ]; then
  echo "FATAL: skills/ contains no <skill-name>/SKILL.md at all" >&2
  exit 1
fi

[ "$problems_total" -eq 0 ] || exit 1
exit 0
