#!/usr/bin/env bash
# Scan the Lua source for references to WoW APIs that were removed in
# our target TOC interface (currently 120000 / The War Within onwards).
# A reference here is a guaranteed runtime "attempt to call a nil
# value" — the exact failure mode that bit us with EasyMenu in 0.7.3.
#
# Source of truth would ideally be Ketho's vscode-wow-api JSON feed:
#   https://github.com/Ketho/vscode-wow-api
# Pulled into CI as a curl + grep, that'd track upstream automatically.
# For now we hand-maintain the list of APIs we've actually been burned
# by or know to be removed. Easy to extend — add the identifier and
# the patch it was removed in to REMOVED_APIS.
#
# Skips:
#   - Comments (lines starting with --)
#   - The .luacheckrc allowlist (which intentionally enumerates the
#     globals we DO use — having "EasyMenu" string there is fine)
#   - The script itself
#   - This file's own comment
#
# Exit non-zero on any hit with file:line so CI logs point at the
# broken call directly.

set -euo pipefail

cd "$(dirname "$0")/.."

# Each entry: identifier|kind|removed-in|note
#   kind = "func"     → matches bare function calls (api(...)), skips
#                       namespaced calls like C_Item.GetItemInfo
#        = "template" → matches the quoted form "Foo" (frame templates,
#                       passed as strings to CreateFrame)
REMOVED_APIS=(
    "EasyMenu|func|110000|replaced by MenuUtil.CreateContextMenu"
    "UIDropDownMenu_Initialize|func|110000|replaced by MenuUtil"
    "UIDropDownMenu_AddButton|func|110000|replaced by MenuUtil"
    "UIDropDownMenu_SetWidth|func|110000|replaced by MenuUtil"
    "UIDropDownMenu_SetText|func|110000|replaced by MenuUtil"
    "UIDropDownMenu_CreateInfo|func|110000|replaced by MenuUtil"
    "ToggleDropDownMenu|func|110000|replaced by MenuUtil"
    "UIDropDownMenuTemplate|template|110000|replaced by MenuUtil (no template)"
    "GetCVarBool|func|110000|use C_CVar.GetCVarBool"
    "GetItemInfo|func|100200|use C_Item.GetItemInfo (bare GetItemInfo is removed; the C_Item.GetItemInfo namespaced form is the modern replacement)"
    "GetItemQualityColor|func|100200|use C_Item.GetItemQualityColor"
)

LUA_FILES=$(find . -name "*.lua" \
    -not -path "./Libs/*" \
    -not -path "./.git/*" \
    -not -path "./node_modules/*")

failed=0

for entry in "${REMOVED_APIS[@]}"; do
    api=${entry%%|*}
    rest=${entry#*|}
    kind=${rest%%|*}
    rest=${rest#*|}
    removed_in=${rest%%|*}
    note=${rest#*|}

    case $kind in
        func)
            # Match `api(` not preceded by a word char or dot — i.e.
            # bare global call, not a method or namespaced call. PCRE
            # negative lookbehind: (?<![\w.])
            pattern="(?<![\w.])${api}\s*\("
            ;;
        template)
            # Frame templates are passed as strings to CreateFrame
            # ("UIDropDownMenuTemplate") — match the quoted form.
            pattern="\"${api}\""
            ;;
        *)
            echo "INTERNAL: unknown kind '$kind' for $api"
            failed=1
            continue
            ;;
    esac

    # Comment-only lines (start with --) are fine — referencing a
    # removed API in a comment is intentional ("we used to call …").
    hits=$(grep -rPHn "$pattern" $LUA_FILES 2>/dev/null \
        | grep -v -E "^[^:]+:[0-9]+:[[:space:]]*--" \
        || true)
    if [[ -n $hits ]]; then
        echo "FAIL: '$api' was removed in TOC $removed_in ($note)"
        echo "$hits" | sed 's/^/    /'
        echo ""
        failed=1
    fi
done

if [[ $failed -eq 1 ]]; then
    echo "Removed-API scan failed. Each hit is a guaranteed runtime nil-call"
    echo "on retail (TOC 120000). Fix by switching to the suggested replacement."
    exit 1
fi

echo "OK: no removed-API references found"
