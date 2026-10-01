#!/usr/bin/env bash
# Copy stenographer's truth format v2 spec (spec/truth-format: the README,
# the JSON Schema and the golden fixtures) into this package, so
# SmallChatTruth is tested against the same fixtures as stenographer and
# short-hand.
#
#   Scripts/sync-truth-fixtures.sh <path to a stenographer checkout>
#
# - <checkout>/spec/truth-format/{README.md,wiki-line.v2.schema.json} and
#   fixtures/** are copied to Tests/Fixtures/truth-format/ (replacing it),
#   keeping the fixtures' layout (signers.json, valid/, invalid/, v1/).
# - Tests/Fixtures/truth-format/SOURCE records where they came from: the
#   checkout's commit, the last commit that changed the spec, whether the
#   spec had uncommitted changes, and every copied file's sha256. The
#   conformance tests refuse files that differ from SOURCE, so fixtures are
#   only ever changed by re-running this script.
#
# The fixtures are the contract: review the diff, then run
# `swift test --filter TruthFormatConformanceTests`.
set -euo pipefail

src="${1:?usage: Scripts/sync-truth-fixtures.sh <path to a stenographer checkout>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
spec="$src/spec/truth-format"
dest="$root/Tests/Fixtures/truth-format"

for required in README.md wiki-line.v2.schema.json fixtures; do
  if [ ! -e "$spec/$required" ]; then
    echo "error: $spec has no $required: is $src a stenographer checkout with the truth format v2 spec?" >&2
    exit 1
  fi
done

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

rm -rf "$dest"
mkdir -p "$dest"
cp "$spec/README.md" "$spec/wiki-line.v2.schema.json" "$dest/"
cp -R "$spec/fixtures/." "$dest/"

commit="unknown"
spec_commit="unknown"
dirty="unknown"
# --no-optional-locks: never touch the other checkout's index
if git --no-optional-locks -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
  commit="$(git --no-optional-locks -C "$src" rev-parse HEAD)"
  spec_commit="$(git --no-optional-locks -C "$src" log -1 --format=%H -- spec/truth-format)"
  if [ -n "$(git --no-optional-locks -C "$src" status --porcelain -- spec/truth-format)" ]; then dirty="yes"; else dirty="no"; fi
fi

{
  echo "# Copied by Scripts/sync-truth-fixtures.sh. Do not edit these files by hand: re-run the script."
  echo "repository: https://github.com/johnnyclem/stenographer"
  echo "path: spec/truth-format"
  echo "commit: $commit"
  echo "spec-last-changed: $spec_commit"
  echo "uncommitted-changes: $dirty"
  echo "files:"
  (cd "$dest" && find . -type f ! -name SOURCE | sed 's|^\./||' | LC_ALL=C sort) | while read -r file; do
    echo "  $(sha256 "$dest/$file")  $file"
  done
} > "$dest/SOURCE"

echo "Copied $spec to $dest"
cat "$dest/SOURCE"
