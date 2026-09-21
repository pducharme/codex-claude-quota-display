#!/bin/sh
# Publish only generated, public guide files. No application configuration is copied.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GUIDE_TMP=$(mktemp -d)
trap 'rm -rf "$GUIDE_TMP"' EXIT
REMOTE=$(git -C "$ROOT" remote get-url origin)
python3 "$ROOT/docs/guide/build.py" "$GUIDE_TMP/site"
if git ls-remote --exit-code --heads "$REMOTE" gh-pages >/dev/null 2>&1; then
  git clone --quiet --single-branch --branch gh-pages "$REMOTE" "$GUIDE_TMP/repo"
else
  git init --quiet --initial-branch=gh-pages "$GUIDE_TMP/repo"
  git -C "$GUIDE_TMP/repo" remote add origin "$REMOTE"
fi
git -C "$GUIDE_TMP/repo" config user.name "$(git -C "$ROOT" config user.name)"
git -C "$GUIDE_TMP/repo" config user.email "$(git -C "$ROOT" config user.email)"
rsync -a --delete --exclude=.git "$GUIDE_TMP/site/" "$GUIDE_TMP/repo/"
git -C "$GUIDE_TMP/repo" add .
if ! git -C "$GUIDE_TMP/repo" diff --cached --quiet; then
  git -C "$GUIDE_TMP/repo" commit --quiet -m "Publish Designer user guide"
  git -C "$GUIDE_TMP/repo" push origin gh-pages
fi
