#!/bin/sh
set -eu

: "${GITHUB_SHA:?The measured source revision is required}"
if [ "$(git rev-parse HEAD)" != "$GITHUB_SHA" ]; then
    echo "checkout differs from the measured source" >&2
    exit 1
fi
git fetch origin main
if [ "$(git rev-parse origin/main)" != "$GITHUB_SHA" ]; then
    echo "main advanced; keeping measurements in the run artifact"
    exit 0
fi
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add metrics/history.json metrics/code-size.svg metrics/coverage.svg metrics/summary.md
if git diff --cached --quiet; then
    exit 0
fi
git commit -m 'chore: update project metrics'
if git push origin HEAD:main; then
    exit 0
fi
# A merge may race the freshness check. Never rebase stale evidence onto it.
git fetch origin main
if [ "$(git rev-parse origin/main)" != "$GITHUB_SHA" ]; then
    echo "main advanced during publication; keeping measurements in the run artifact"
    exit 0
fi
echo "metrics publication failed while main was unchanged" >&2
exit 1
