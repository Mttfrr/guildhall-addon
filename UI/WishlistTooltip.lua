---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Hook item tooltips to show wishlist information from imported web data
-- Modern API passes (tooltip, data); legacy OnTooltipSetItem passes (tooltip) only
local function OnTooltipSetItem(tooltip, data)
    local itemID, itemName

    if data and data.id then
        -- Modern tooltip API (10.0.2+): get item ID directly from tooltip data
        itemID = data.id
    elseif tooltip.GetItem then
        -- Legacy fallback: extract from tooltip
        local name, itemLink = tooltip:GetItem()
        itemName = name
        if itemLink then
            itemID = tonumber(itemLink:match("item:(%d+)"))
        end
    end

    if not itemID then return end
    -- The name lets a Heroic drop match a Myth-track wish: same item,
    -- different id, and the id lookup alone reports nobody wants it.
    if not itemName and C_Item and C_Item.GetItemInfo then
        itemName = C_Item.GetItemInfo(itemID)
    end

    local wishEntries = WGS:GetWishlistForItem(itemID, itemName)
    if not wishEntries or #wishEntries == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cffffd100GuildHall Wishlists:|r")

    -- Sort by priority — shared rank/colour vocabulary from UIHelpers
    table.sort(wishEntries, function(a, b)
        return (ui.PRIORITY_ORDER[a.priority] or 99) < (ui.PRIORITY_ORDER[b.priority] or 99)
    end)

    for _, entry in ipairs(wishEntries) do
        local color = "|c" .. (ui.PRIORITY_COLORS[entry.priority] or "ffffffff")
        local line = "  " .. (entry.playerName or "Unknown") .. " - " .. color .. (entry.priority or "?") .. "|r"
        -- Droptimizer gain per wisher, when their sim covers this item —
        -- shared formatter with the RCLC voting column.
        local sim = WGS.FormatWishSimPct and WGS:FormatWishSimPct(entry.simPct)
        if sim then
            local simColor = (tonumber(entry.simPct) or 0) > 0 and "|cff44cc66" or "|cff999999"
            line = line .. " " .. simColor .. sim .. "|r"
        end
        if entry.note and entry.note ~= "" then
            line = line .. " (" .. entry.note .. ")"
        end
        tooltip:AddLine(line)
    end

    tooltip:Show()
end

-- Called from Core.lua OnEnable
function WGS:SetupTooltipHooks()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        -- Modern tooltip API (10.0.2+)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipSetItem)
    else
        -- Legacy fallback
        GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
    end
end
