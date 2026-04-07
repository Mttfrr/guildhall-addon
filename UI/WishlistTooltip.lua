---@type GuildHall
local WGS = GuildHall

-- Hook item tooltips to show wishlist information from imported web data
-- Modern API passes (tooltip, data); legacy OnTooltipSetItem passes (tooltip) only
local function OnTooltipSetItem(tooltip, data)
    local itemID

    if data and data.id then
        -- Modern tooltip API (10.0.2+): get item ID directly from tooltip data
        itemID = data.id
    elseif tooltip.GetItem then
        -- Legacy fallback: extract from tooltip
        local _, itemLink = tooltip:GetItem()
        if itemLink then
            itemID = tonumber(itemLink:match("item:(%d+)"))
        end
    end

    if not itemID then return end

    local wishEntries = WGS:GetWishlistForItem(itemID)
    if not wishEntries or #wishEntries == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cffffd100GuildHall Wishlists:|r")

    -- Sort by priority
    local priorityOrder = { BiS = 1, High = 2, Medium = 3, Low = 4 }
    table.sort(wishEntries, function(a, b)
        return (priorityOrder[a.priority] or 99) < (priorityOrder[b.priority] or 99)
    end)

    local priorityColors = {
        BiS = "|cffff8000",    -- Orange
        High = "|cffa335ee",   -- Purple
        Medium = "|cff0070dd", -- Blue
        Low = "|cff1eff00",   -- Green
    }

    for _, entry in ipairs(wishEntries) do
        local color = priorityColors[entry.priority] or "|cffffffff"
        local line = "  " .. (entry.playerName or "Unknown") .. " - " .. color .. (entry.priority or "?") .. "|r"
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
