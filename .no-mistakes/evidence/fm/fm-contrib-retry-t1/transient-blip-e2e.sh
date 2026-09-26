#!/usr/bin/env bash
# Manual end-to-end check for the transient-forge-read retry.
#
# Drives the real `bin/fm-contributions.sh poll` in a real firstmate home whose
# `gh` returns HTTP 502 for exactly one API call (one transient GitHub blip) and
# records what the first mate actually sees on stdout - the line that costs the
# captain a message - plus the durable record and the wake queue.
#
# Three scenarios: the pre-fix script on one blip, the fixed script on one blip,
# and the fixed script against a forge that fails every attempt.
#
#   REPO=<worktree root> BASE=<pre-fix commit> bash transient-blip-e2e.sh
set -u
REPO=${REPO:?set REPO to the worktree root}
BASE=${BASE:?set BASE to the pre-fix commit}
# Fixture helpers only: drop the test file's runner loop so no test executes.
# It must live beside tests/lib.sh, which it sources relative to itself.
HARNESS="$REPO/tests/.contrib-evidence-harness.sh"
sed '/^failures=0$/,$d' "$REPO/tests/fm-contributions.test.sh" > "$HARNESS"
cleanup() { rm -f -- "$HARNESS"; git -C "$REPO" checkout -- bin/fm-contributions.sh; }
trap cleanup EXIT
# shellcheck disable=SC1090
. "$HARNESS"

use_script() { # commit-ish|HEAD
  if [ "$1" = HEAD ]; then
    git -C "$REPO" checkout -- bin/fm-contributions.sh
  else
    git -C "$REPO" show "$1:bin/fm-contributions.sh" > "$REPO/bin/fm-contributions.sh"
  fi
  chmod +x "$REPO/bin/fm-contributions.sh"
}

scenario() { # label fault home-name script-label
  local label=$1 fault=$2 name=$3 script=$4 home out rc=0
  home=$(new_home "$name")
  forge_home "$home"
  wrap_forge "$home"
  # The PR's last observation is stale, so this poll must re-read it.
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  printf '%s\n' "$fault" > "$home/forge/fault"
  printf '\n===== %s =====\n' "$label"
  case $fault in
    fail-once) printf 'forge behaviour  : HTTP 502 on the first read of repos/o/r/pulls/8/reviews, then healthy\n' ;;
    fail)      printf 'forge behaviour  : HTTP 502 on every read of repos/o/r/pulls/8/reviews\n' ;;
  esac
  printf 'observer script  : %s\n' "$script"
  printf -- '--- $ fm-contributions.sh poll   (stdout is what wakes the first mate) ---\n'
  out=$(with_home "$home" "$REPO/bin/fm-contributions.sh" poll) || rc=$?
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(no output - nothing woke the first mate)\n'; fi
  printf -- '--- poll exit status: %s ---\n' "$rc"
  printf 'reviews reads attempted : %s\n' "$(grep -cF 'api repos/o/r/pulls/8/reviews?' "$home/forge/calls")"
  printf 'durable record          : checked_at=%s error=%s\n' \
    "$(jq -r '.records[0].checked_at' "$home/data/delivery/contributions.json")" \
    "$(jq -c '.records[0].error' "$home/data/delivery/contributions.json")"
  printf 'wake queue              : %s\n' \
    "$(if [ -s "$home/state/.wake-queue" ]; then cat "$home/state/.wake-queue"; else printf '(empty)'; fi)"
}

use_script "$BASE"
scenario 'BEFORE the fix: one transient blip' fail-once before-blip "pre-fix ($BASE)"
use_script HEAD
scenario 'AFTER the fix: one transient blip' fail-once after-blip 'fixed (HEAD)'
scenario 'AFTER the fix: a genuinely unavailable forge' fail after-outage 'fixed (HEAD)'
printf '\n'

rm -f -- "$HARNESS"
git -C "$REPO" checkout -- bin/fm-contributions.sh
