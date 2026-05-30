#!/usr/bin/env bash
#
# update-submodules.sh — pull every git submodule in this meta-monorepo to the
# latest commit on its tracked branch, recursively.
#
# Safe by default:
#   - skips submodules with uncommitted changes (the in-progress work the
#     workspace AGENTS.md explicitly warns about)
#   - uses --ff-only, so it never silently rewrites local history
#   - on detached HEAD, checks out the configured tracking branch (from the
#     parent .gitmodules) or the remote's default branch before pulling
#
# Usage:
#   ./update-submodules.sh            # update every submodule (recursive)
#   ./update-submodules.sh --top-only # only the workspace-level submodules
#   ./update-submodules.sh --dry-run  # report what would happen, no changes
#
# Output is colour-coded: green = pulled, yellow = skipped, red = failed.

set -uo pipefail

mode_recursive=1
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --top-only)  mode_recursive=0 ;;
    --dry-run)   dry_run=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2 ;;
  esac
done

# Always run from the workspace root (the dir this script lives in).
cd "$(dirname "$(readlink -f "$0")")"

# Colours (only if stdout is a TTY).
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=; C_DIM=; C_GREEN=; C_YELLOW=; C_RED=; C_BLUE=
fi

# Counters live in a temp file because `git submodule foreach` runs each
# iteration in a subshell — variable assignments wouldn't propagate.
counters=$(mktemp)
printf '0 0 0\n' > "$counters"   # updated skipped failed
trap 'rm -f "$counters"' EXIT

bump() {
  # $1 = column index (1=updated, 2=skipped, 3=failed)
  local u s f
  read -r u s f < "$counters"
  case "$1" in
    1) u=$((u+1)) ;;
    2) s=$((s+1)) ;;
    3) f=$((f+1)) ;;
  esac
  printf '%s %s %s\n' "$u" "$s" "$f" > "$counters"
}
export -f bump
export counters C_RESET C_DIM C_GREEN C_YELLOW C_RED C_BLUE dry_run

# Pick up any URL changes from .gitmodules before pulling.
echo "${C_BLUE}sync${C_RESET}: git submodule sync --recursive"
[ "$dry_run" -eq 0 ] && git submodule sync --recursive --quiet

# The per-submodule routine, executed by `git submodule foreach`.
# Available env: $name, $sm_path, $displaypath, $sha1, $toplevel.
read -r -d '' PER_SUBMODULE_SCRIPT <<'BASH' || true
  set -uo pipefail

  printf "\n${C_BLUE}→${C_RESET} %s\n" "$displaypath"

  # Refuse to touch a working tree with real file edits. Ignore submodule
  # diffs — those just mean a nested gitlink moved, which the recursive pass
  # will resolve. `git pull --ff-only` below still bails on a real conflict.
  if ! git diff --quiet --ignore-submodules=all || \
     ! git diff --cached --quiet --ignore-submodules=all; then
    printf "  ${C_YELLOW}skip${C_RESET}: uncommitted file edits\n"
    bump 2
    exit 0
  fi

  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  if [ -z "$branch" ]; then
    # Detached HEAD — find the tracking branch.
    branch=$(git config -f "$toplevel/.gitmodules" --get "submodule.$name.branch" 2>/dev/null || true)
    if [ -z "$branch" ]; then
      branch=$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)
    fi
    if [ -z "$branch" ] || [ "$branch" = "(unknown)" ]; then
      printf "  ${C_YELLOW}skip${C_RESET}: detached HEAD, no tracking branch configured\n"
      bump 2
      exit 0
    fi
    printf "  ${C_DIM}detached → checkout %s${C_RESET}\n" "$branch"
    if [ "$dry_run" -eq 0 ]; then
      if ! git checkout "$branch" --quiet 2>/dev/null; then
        # Branch may not exist locally yet; try tracking the remote.
        if ! git checkout -B "$branch" --track "origin/$branch" --quiet 2>/dev/null; then
          printf "  ${C_RED}fail${C_RESET}: cannot check out %s\n" "$branch"
          bump 3
          exit 0
        fi
      fi
    fi
  fi

  printf "  pull ${C_DIM}(branch: %s)${C_RESET} … " "$branch"
  if [ "$dry_run" -eq 1 ]; then
    printf "${C_DIM}(dry-run)${C_RESET}\n"
    bump 1
    exit 0
  fi

  if out=$(git pull --ff-only --quiet 2>&1); then
    if [ -z "$out" ]; then
      printf "${C_GREEN}ok${C_RESET} ${C_DIM}(already up to date)${C_RESET}\n"
    else
      printf "${C_GREEN}ok${C_RESET}\n"
      printf "    %s\n" "$out"
    fi
    bump 1
  else
    printf "${C_RED}fail${C_RESET}\n"
    printf "    %s\n" "$out"
    bump 3
  fi
BASH

if [ "$mode_recursive" -eq 1 ]; then
  git submodule foreach --recursive --quiet "$PER_SUBMODULE_SCRIPT"
else
  git submodule foreach --quiet "$PER_SUBMODULE_SCRIPT"
fi

read -r updated skipped failed < "$counters"
echo
echo "${C_BLUE}==${C_RESET} Summary ${C_BLUE}==${C_RESET}"
printf "  ${C_GREEN}updated${C_RESET}: %d\n" "$updated"
printf "  ${C_YELLOW}skipped${C_RESET}: %d ${C_DIM}(dirty or detached without tracking branch)${C_RESET}\n" "$skipped"
printf "  ${C_RED}failed${C_RESET} : %d\n" "$failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
