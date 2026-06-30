#!/usr/bin/env bash
# Show what's new on upstream (nullclaw/nullclaw) that this fork's main lacks, as
# back-port candidates. Read-only: fetches origin, prints; never merges or pushes.
#
# Context: this fork has diverged from upstream (common ancestor, separate
# futures). We do NOT merge/sync upstream — we selectively back-port individual
# fixes. This script makes "what should I look at?" a one-liner.
#
# Usage:
#   scripts/upstream-check.sh            # non-merge commits upstream has, we don't
#   scripts/upstream-check.sh --files    # also show files each commit touched
#   scripts/upstream-check.sh --stat     # just the ahead/behind summary
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

UPSTREAM_REMOTE="origin"   # nullclaw/nullclaw (read-only)
UPSTREAM_BRANCH="main"
OURS="HEAD"

echo "Fetching ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} ..."
git fetch "$UPSTREAM_REMOTE" --quiet

UP="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
base=$(git merge-base "$OURS" "$UP")
ahead=$(git rev-list --count "${UP}..${OURS}")
behind=$(git rev-list --count "${OURS}..${UP}")
behind_real=$(git rev-list --no-merges --count "${OURS}..${UP}")

echo "Last common ancestor: $(git log -1 --format='%h %ad %s' --date=short "$base")"
echo "You are ${ahead} ahead, ${behind} behind upstream (${behind_real} of the behind are non-merge)."
echo

case "${1:-}" in
  --stat)
    exit 0 ;;
  --files)
    echo "Upstream commits you don't have (newest first, with files):"
    git log --no-merges --reverse=false --format='%C(yellow)%h%Creset %ad %s' --date=short "${OURS}..${UP}" \
      | while read -r line; do
          sha=$(echo "$line" | awk '{print $1}')
          echo "$line"
          git show --stat --format= "$sha" 2>/dev/null | sed 's/^/    /'
        done ;;
  *)
    echo "Upstream non-merge commits you don't have (newest first) — back-port candidates:"
    git log --no-merges --format='%h %ad %s' --date=short "${OURS}..${UP}" ;;
esac

echo
echo "Reminder: do NOT merge upstream. Cherry-pick / adapt individual fixes only."
echo "See memory project_upstream_backport for the standing back-port policy."
