#!/usr/bin/env bash
# Sanity-check the addon's metadata files for consistency. Run from CI
# and locally before releases.
#
# Checks:
#   1. GuildHall.toc's `## Version:` matches Core.lua's `WGS.version = "…"`.
#      Hidden drift between the two has burned us across multiple
#      releases (TOC bumped, runtime missed → "What's new" badge
#      gates wrong + minimap tooltip lies about the running version).
#   2. GuildHall.toc has `## Interface:` set and parses as a number
#      (catches typos like 12000 vs 120000).
#
# Exit non-zero on any failure with file:line-style output so CI logs
# point at the broken field directly.

set -euo pipefail

cd "$(dirname "$0")/.."

TOC=GuildHall.toc
CORE=Core.lua

if [[ ! -f $TOC ]]; then echo "FAIL: $TOC missing"; exit 1; fi
if [[ ! -f $CORE ]]; then echo "FAIL: $CORE missing"; exit 1; fi

TOC_VERSION=$(grep -E "^## Version:" "$TOC" | head -1 | sed -E 's/^## Version:[[:space:]]+//' | tr -d ' \t\r\n')
if [[ -z $TOC_VERSION ]]; then
    echo "FAIL: $TOC missing or malformed '## Version:' field"
    exit 1
fi

LUA_VERSION=$(grep -E '^WGS\.version' "$CORE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z $LUA_VERSION ]]; then
    echo "FAIL: $CORE missing 'WGS.version = \"…\"' assignment"
    exit 1
fi

if [[ "$TOC_VERSION" != "$LUA_VERSION" ]]; then
    echo "FAIL: version drift between $TOC and $CORE"
    echo "  $TOC:        ## Version: $TOC_VERSION"
    echo "  $CORE:       WGS.version = \"$LUA_VERSION\""
    echo ""
    echo "Bump both when releasing. Easy to miss — see commit 500e6dc"
    echo "for the bug this guard exists to prevent."
    exit 1
fi

TOC_INTERFACE=$(grep -E "^## Interface:" "$TOC" | head -1 | sed -E 's/^## Interface:[[:space:]]+//' | tr -d ' \t\r\n')
if ! [[ $TOC_INTERFACE =~ ^[0-9]+$ ]]; then
    echo "FAIL: $TOC ## Interface field missing or non-numeric: '$TOC_INTERFACE'"
    exit 1
fi

echo "OK: $TOC version $TOC_VERSION matches $CORE WGS.version"
echo "OK: $TOC interface $TOC_INTERFACE parses as numeric"
