#!/usr/bin/env bash
#
# update-submodules.sh — bring every git submodule in this meta-monorepo to the
# latest commit on its remote default branch.
#
# Safe by default:
#   - skips submodules with uncommitted file edits (the in-progress work the
#     workspace AGENTS.md warns about)
#   - ff-only, so it never silently rewrites local history
#   - robust default-branch detection: repairs a stale origin/HEAD (e.g. a
#     submodule whose upstream renamed 'master' → 'main') instead of failing
#   - iterates manually (NOT `git submodule foreach`), so a single gitlink that
#     is missing from .gitmodules no longer aborts the entire run
#
# Usage:
#   ./update-submodules.sh             # update every INITIALIZED submodule (recursive)
#   ./update-submodules.sh --init      # also CHECK OUT uninitialized submodules first
#   ./update-submodules.sh --top-only  # only the workspace-level submodules
#   ./update-submodules.sh --dry-run   # report what would happen, no changes
#   (flags combine, e.g. --top-only --init)
#
# Note: under recursion `--init` is greedy — it checks out every uninitialized
# submodule it reaches, including deeply-nested ones (potentially many GB).
# Scope it with --top-only, or run it from inside a single subproject.
#
# Output is colour-coded: green = updated/ok/init, yellow = skipped, red = failed.

set -uo pipefail

mode_recursive=1
dry_run=0
do_init=0
for arg in "$@"; do
  case "$arg" in
    --top-only) mode_recursive=0 ;;
    --dry-run)  dry_run=1 ;;
    --init)     do_init=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 2 ;;
  esac
done

# Always run from the workspace root (the dir this script lives in).
root="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$root"

# Colours (only if stdout is a TTY).
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=; C_DIM=; C_GREEN=; C_YELLOW=; C_RED=; C_BLUE=
fi

export GIT_TERMINAL_PROMPT=0   # fail fast instead of hanging on an auth prompt

# The whole traversal runs in the current shell (the iteration uses process
# substitution, not a pipe), so plain counter variables survive recursion.
updated=0; skipped=0; failed=0; inited=0
bump() { # $1 = 1:updated 2:skipped 3:failed 4:inited
  case "$1" in
    1) updated=$((updated+1)) ;;
    2) skipped=$((skipped+1)) ;;
    3) failed=$((failed+1)) ;;
    4) inited=$((inited+1)) ;;
  esac
}

# Resolve a submodule's remote default branch. Prefer the local origin/HEAD but
# VERIFY it still exists as a remote-tracking ref; if it is stale (points at a
# deleted branch) or unset, repair it from the remote, falling back to a live
# query as a last resort.
default_branch() { # $1 = submodule dir → echoes branch name (or nothing)
  local d="$1" br
  # Always ask the live remote first. A merely-existing-but-stale local
  # origin/HEAD (e.g. left pointing at a non-default branch like 'gh-pages'
  # from some earlier state) would otherwise be trusted as long as that
  # branch still exists — which it usually does, silently checking out the
  # wrong branch. Real-world case: easy6502's origin/HEAD was stuck on
  # 'gh-pages' (a real, existing branch) while GitHub's actual default was
  # 'main', and the old existence-only check never caught it.
  git -C "$d" remote set-head origin -a >/dev/null 2>&1
  br=$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); br=${br#origin/}
  if [ -n "$br" ] && git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$br"; then
    printf '%s' "$br"; return 0
  fi
  br=$(git -C "$d" remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')
  [ "$br" = "(unknown)" ] && br=
  printf '%s' "$br"
}

update_one() { # $1 = submodule dir ; $2 = display name
  local d="$1" disp="$2" br before after out
  # Refuse to touch a working tree with real file edits. Ignore submodule diffs
  # — those just mean a nested gitlink moved, which the recursion resolves.
  if ! git -C "$d" diff --quiet --ignore-submodules=all || \
     ! git -C "$d" diff --cached --quiet --ignore-submodules=all; then
    printf "  ${C_YELLOW}skip${C_RESET}: uncommitted file edits\n"; bump 2; return 1
  fi
  if [ "$dry_run" -eq 1 ]; then
    printf "  ${C_DIM}(dry-run) would fetch + ff-only to default branch${C_RESET}\n"; bump 1; return 0
  fi
  if ! out=$(git -C "$d" fetch -q --prune origin 2>&1); then
    printf "  ${C_RED}fail${C_RESET}: fetch\n    %s\n" "$out"; bump 3; return 1
  fi
  br=$(default_branch "$d")
  if [ -z "$br" ]; then
    printf "  ${C_YELLOW}skip${C_RESET}: no default branch\n"; bump 2; return 1
  fi
  if ! git -C "$d" checkout -q "$br" 2>/dev/null && \
     ! git -C "$d" checkout -q -B "$br" --track "origin/$br" 2>/dev/null; then
    printf "  ${C_RED}fail${C_RESET}: cannot check out %s\n" "$br"; bump 3; return 1
  fi
  before=$(git -C "$d" rev-parse --short HEAD)
  if ! out=$(git -C "$d" merge --ff-only -q "origin/$br" 2>&1); then
    printf "  ${C_RED}fail${C_RESET}: ff-merge %s\n    %s\n" "$br" "$out"; bump 3; return 1
  fi
  after=$(git -C "$d" rev-parse --short HEAD)
  if [ "$before" = "$after" ]; then
    printf "  ${C_GREEN}ok${C_RESET} ${C_DIM}(%s @ %s, up to date)${C_RESET}\n" "$br" "$after"
  else
    printf "  ${C_GREEN}updated${C_RESET} ${C_DIM}(%s) %s → %s${C_RESET}\n" "$br" "$before" "$after"
  fi
  bump 1; return 0
}

process_repo() { # $1 = repo dir ; $2 = display prefix
  local repo="$1" prefix="$2" line path abspath disp out url
  # Enumerate submodules from the raw index gitlinks (`git ls-files --stage`,
  # mode 160000). Unlike `git submodule status` / `git submodule foreach`, this
  # NEVER aborts when a gitlink is missing its .gitmodules entry — it just lists
  # every submodule, registered or not, so one inconsistency cannot take down
  # the whole run.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    path="${line#*$'\t'}"          # strip "160000 <sha> <stage>\t" prefix
    [ -z "$path" ] && continue
    abspath="$repo/$path"
    disp="${prefix}${path}"
    printf "\n${C_BLUE}→${C_RESET} %s\n" "$disp"

    if [ -e "$abspath/.git" ]; then
      # Initialized → update in place (uses its own origin remote, so it works
      # even if the gitlink is missing from .gitmodules).
      update_one "$abspath" "$disp" || true
    else
      # Uninitialized.
      if [ "$do_init" -eq 0 ]; then
        printf "  ${C_YELLOW}skip${C_RESET}: uninitialized ${C_DIM}(use --init to check out)${C_RESET}\n"
        bump 2; continue
      fi
      url=$(git -C "$repo" config -f "$repo/.gitmodules" --get "submodule.$path.url" 2>/dev/null || true)
      if [ -z "$url" ]; then
        printf "  ${C_RED}fail${C_RESET}: uninitialized and missing from .gitmodules ${C_DIM}(no URL to clone)${C_RESET}\n"
        bump 3; continue
      fi
      if [ "$dry_run" -eq 1 ]; then
        printf "  ${C_DIM}(dry-run) would init + update${C_RESET}\n"; bump 4; continue
      elif out=$(git -C "$repo" submodule update --init "$path" 2>&1); then
        printf "  ${C_GREEN}init${C_RESET} ${C_DIM}(%s)${C_RESET}\n" "$(git -C "$abspath" rev-parse --short HEAD 2>/dev/null)"
        bump 4
        update_one "$abspath" "$disp" || true
      else
        printf "  ${C_RED}fail${C_RESET}: init\n    %s\n" "$out"; bump 3; continue
      fi
    fi

    # Recurse into this submodule's own submodules.
    if [ "$mode_recursive" -eq 1 ] && [ -e "$abspath/.git" ] && [ -f "$abspath/.gitmodules" ]; then
      process_repo "$abspath" "${disp}/"
    fi
  done < <(git -C "$repo" ls-files --stage 2>/dev/null | awk '$1=="160000"')
}

# Pick up any URL changes from .gitmodules before traversing.
sync_args=""
[ "$mode_recursive" -eq 1 ] && sync_args="--recursive"
echo "${C_BLUE}sync${C_RESET}: git submodule sync ${sync_args}"
[ "$dry_run" -eq 0 ] && git submodule sync ${sync_args} --quiet 2>/dev/null

process_repo "$root" ""

echo
echo "${C_BLUE}==${C_RESET} Summary ${C_BLUE}==${C_RESET}"
printf "  ${C_GREEN}updated/ok${C_RESET}: %d\n" "$updated"
printf "  ${C_GREEN}inited${C_RESET}    : %d\n" "$inited"
printf "  ${C_YELLOW}skipped${C_RESET}   : %d ${C_DIM}(dirty, uninitialized, or no default branch)${C_RESET}\n" "$skipped"
printf "  ${C_RED}failed${C_RESET}    : %d\n" "$failed"

[ "$failed" -gt 0 ] && exit 1
exit 0
