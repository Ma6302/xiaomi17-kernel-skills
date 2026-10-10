#!/usr/bin/env bash
# check-abi-prereqs.sh — build-side prerequisite check for GKI ABI compatibility.
#
# Read-only. It answers "is this build even capable of passing the four ABI
# checks?" before you spend time on Module.symvers / __versions / BTF diffing.
#
# It checks:
#   1. ftrace family configs must be NOT SET in the built .config
#      (CONFIG_FTRACE, CONFIG_FUNCTION_TRACER, CONFIG_STACK_TRACER,
#       CONFIG_FUNCTION_GRAPH_TRACER, CONFIG_FTRACE_MCOUNT_RECORD)
#   2. the artefacts the four checks need actually exist
#      (Module.symvers, vmlinux, gki/aarch64/abi.stg, pahole)
#   3. whether KBUILD_GENDWARFKSYMS_STABLE=1 is visible in THIS shell
#      (informational only — see the note printed at the end)
#
# Usage:
#   bash scripts/check-abi-prereqs.sh --out out --src "$HOME/kernel/src"
#   bash scripts/check-abi-prereqs.sh --out out --src src --config out/.config
#
# Exit status:
#   0 = no failing check
#   1 = at least one check failed
#   2 = bad usage / nothing to inspect
#
# DO NOT add `set -u` to this file. GKI's _setup_env.sh aborts under `set -u`
# (`_SETUP_ENV_SH_INCLUDED: unbound variable`), and this script is meant to be
# safe to source or copy next to a build script that calls it. It also
# deliberately never sources _setup_env.sh itself.

set -o pipefail

OUT=""
SRC=""
CONFIG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)    OUT="${2:-}";    shift 2 || shift ;;
    --src)    SRC="${2:-}";    shift 2 || shift ;;
    --config) CONFIG="${2:-}"; shift 2 || shift ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[ -n "$CONFIG" ] || CONFIG="${OUT:+$OUT/.config}"
[ -n "$CONFIG" ] || CONFIG="out/.config"

fails=0
warns=0

printf '======================================================================\n'
printf '  ABI prerequisites\n'
printf '======================================================================\n'

# ---------------------------------------------------------------- 1. ftrace --
printf '\n[1] ftrace family must be NOT SET in %s\n' "$CONFIG"

if [ ! -f "$CONFIG" ]; then
  printf '    FAIL: no .config at %s (build first, or pass --config)\n' "$CONFIG"
  fails=$((fails + 1))
else
  for opt in \
    CONFIG_FTRACE \
    CONFIG_FUNCTION_TRACER \
    CONFIG_STACK_TRACER \
    CONFIG_FUNCTION_GRAPH_TRACER \
    CONFIG_FTRACE_MCOUNT_RECORD
  do
    if grep -q "^${opt}=y" "$CONFIG" 2>/dev/null; then
      printf '    FAIL  %-30s = y\n' "$opt"
      fails=$((fails + 1))
    elif grep -q "^# ${opt} is not set" "$CONFIG" 2>/dev/null; then
      printf '    ok    %-30s not set\n' "$opt"
    else
      printf '    ????  %-30s absent from .config\n' "$opt"
      warns=$((warns + 1))
    fi
  done

  if grep -q '^CONFIG_STACK_TRACER=y' "$CONFIG" 2>/dev/null; then
    printf '\n    NOTE: CONFIG_STACK_TRACER selects CONFIG_FUNCTION_TRACER\n'
    printf '          (kernel/trace/Kconfig:316-319). Turning FUNCTION_TRACER\n'
    printf '          off alone does nothing — turn STACK_TRACER off first,\n'
    printf '          then run olddefconfig TWICE so the select chain settles.\n'
  fi
fi

# ------------------------------------------------------------ 2. artefacts --
printf '\n[2] artefacts required by the four checks\n'

need_file() { # label path
  if [ -f "$2" ]; then
    printf '    ok    %-30s %s\n' "$1" "$2"
  else
    printf '    FAIL  %-30s missing: %s\n' "$1" "$2"
    fails=$((fails + 1))
  fi
}

if [ -n "$OUT" ]; then
  need_file 'Module.symvers (check 1,4)' "$OUT/Module.symvers"
  need_file 'vmlinux        (check 3)'   "$OUT/vmlinux"
else
  printf '    SKIP  --out not given (checks 1,3,4 cannot be verified)\n'
  warns=$((warns + 1))
fi

if [ -n "$SRC" ]; then
  need_file 'gki/aarch64/abi.stg (1,2)' "$SRC/gki/aarch64/abi.stg"
else
  printf '    SKIP  --src not given (abi.stg baseline not verifiable)\n'
  warns=$((warns + 1))
fi

if command -v pahole >/dev/null 2>&1; then
  printf '    ok    %-30s %s\n' 'pahole' "$(command -v pahole)"
  printf '          (a distro pahole may fail on 6.12 BTF: prefer the AOSP\n'
  printf '           build-tools prebuilt pahole and put it first in PATH)\n'
else
  printf '    FAIL  %-30s not on PATH (check 3 would only SKIP)\n' 'pahole'
  fails=$((fails + 1))
fi

# ------------------------------------------------------ 3. KBUILD_* env var --
printf '\n[3] KBUILD_GENDWARFKSYMS_STABLE\n'

if [ "${KBUILD_GENDWARFKSYMS_STABLE:-}" = "1" ]; then
  printf '    ok    =1 in this shell\n'
else
  printf '    INFO  not visible in this shell\n'
  printf '          This is expected: the variable is exported by\n'
  printf '          `source ./_setup_env.sh` inside the BUILD shell only\n'
  printf '          (scripts/Makefile.build:114 turns it into\n'
  printf '          `gendwarfksyms --stable`). Do not treat this as a failure —\n'
  printf '          instead confirm the build really went through the official\n'
  printf '          entry point. A bare `make` produces CRC mismatches\n'
  printf '          (measured: msm_drm.ko DIFF 471).\n'
  warns=$((warns + 1))
fi

# ----------------------------------------------------------------- verdict --
printf '\n======================================================================\n'
if [ "$fails" -eq 0 ]; then
  printf '  prereqs OK — now run the four-way ABI verification\n'
  printf '  (missing --ko / --pahole makes checks 2 and 3 SKIP, not FAIL,\n'
  printf '   so a green run without device modules is a FALSE green)\n'
else
  printf '  %d prerequisite check(s) failed\n' "$fails"
  printf '  fix these before trusting any ABI verification result\n'
fi
printf '======================================================================\n'

[ "$fails" -eq 0 ] || exit 1
exit 0
