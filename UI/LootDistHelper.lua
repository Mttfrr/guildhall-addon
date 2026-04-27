---@type GuildHall
local WGS = GuildHall

local helperFrame = nil
local POPUP_DURATION = 30  -- auto-hide after 30 seconds if no action

local priorityColors = {
    BiS    = "|cffff8000",
    High   = "|cffa335ee",
    Medium = "|cff0070dd",
    Low    = "|cff1eff00",
}
local priorityOrder = { BiS = 1, High = 2, Medium = 3, Low = 4 }

local function CreateHelperFrame()
    local f = CreateFrame("Frame", "GuildHallLootDistHelper", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(320, 50) -- resized dynamically
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("FULLSCREEN_DIALOG")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("Loot Distribution")

    -- Item info line
    f.itemLine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.itemLine:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
    f.itemLine:SetWidth(290)
    f.itemLine:SetJustifyH("LEFT")

    -- Wishlist entries container
    f.wishHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.wishHeader:SetPoint("TOPLEFT", f.itemLine, "BOTTOMLEFT", 0, -8)
    f.wishHeader:SetText("|cffffd100Wishlisted by:|r")

    f.wishLines = {}

    -- Buttons at bottom (created dynamically on show)
    f.announceBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.announceBtn:SetSize(140, 26)
    f.announceBtn:SetText("Announce to Raid")

    f.dismissBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.dismissBtn:SetSize(80, 26)
    f.dismissBtn:SetText("Dismiss")
    f.dismissBtn:SetScript("OnClick", function() f:Hide() end)

    -- Auto-hide timer
    f.autoHideTimer = nil

    f:Hide()
    return f
end

local function HideWishLines(frame)
    for _, line in ipairs(frame.wishLines) do
        line:Hide()
    end
end

local function ShowLootHelper(itemLink, itemID, player, wishEntries)
    if not helperFrame then
        helperFrame = CreateHelperFrame()
    end

    -- Cancel previous auto-hide
    if helperFrame.autoHideTimer then
        helperFrame.autoHideTimer:Cancel()
        helperFrame.autoHideTimer = nil
    end

    HideWishLines(helperFrame)

    -- Item info
    helperFrame.itemLine:SetText(itemLink .. "  |cffaaaaaa→ " .. (player or "Unknown") .. "|r")

    -- Sort wish entries by priority
    table.sort(wishEntries, function(a, b)
        return (priorityOrder[a.priority] or 99) < (priorityOrder[b.priority] or 99)
    end)

    -- Build wish lines
    local yOffset = 0
    local anchorTo = helperFrame.wishHeader
    for i, entry in ipairs(wishEntries) do
        local line = helperFrame.wishLines[i]
        if not line then
            line = helperFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            helperFrame.wishLines[i] = line
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", (i == 1 and 4 or 0), -2)
        anchorTo = line

        local color = priorityColors[entry.priority] or "|cffffffff"
        local text = "  " .. (entry.playerName or "?") .. " — " .. color .. (entry.priority or "?") .. "|r"
        if entry.note and entry.note ~= "" then
            text = text .. " |cff888888(" .. entry.note .. ")|r"
        end
        line:SetText(text)
        line:Show()
        yOffset = yOffset + 14
    end

    -- Resize frame
    local totalHeight = 35 + 18 + 16 + yOffset + 10 + 30 + 10
    helperFrame:SetSize(320, totalHeight)

    -- Position buttons
    helperFrame.announceBtn:ClearAllPoints()
    helperFrame.announceBtn:SetPoint("BOTTOMLEFT", helperFrame, "BOTTOMLEFT", 15, 10)
    helperFrame.dismissBtn:ClearAllPoints()
    helperFrame.dismissBtn:SetPoint("BOTTOMRIGHT", helperFrame, "BOTTOMRIGHT", -15, 10)

    -- Announce button: send wishlist info to raid chat
    local announceText = itemLink .. " wishlisted by: "
    local names = {}
    for _, entry in ipairs(wishEntries) do
        table.insert(names, (entry.playerName or "?") .. " (" .. (entry.priority or "?") .. ")")
    end
    announceText = announceText .. table.concat(names, ", ")

    helperFrame.announceBtn:SetScript("OnClick", function()
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if channel then
            C_ChatInfo.SendChatMessage("[GuildHall] " .. announceText, channel)
        else
            WGS:Print(announceText)
        end
        helperFrame:Hide()
    end)

    helperFrame:Show()

    -- Auto-hide after POPUP_DURATION seconds
    helperFrame.autoHideTimer = C_Timer.NewTimer(POPUP_DURATION, function()
        if helperFrame and helperFrame:IsShown() then
            helperFrame:Hide()
        end
    end)
end

-- Hook into the loot module: called after a loot entry is recorded
-- This is triggered from within the Loot module's OnLootMessage
function WGS:CheckLootDistribution(itemLink, itemID, player)
    if not self.db.profile.showLootDistHelper then return end
    if not itemID then return end

    -- Only show in raid/group
    if not (IsInRaid() or IsInGroup()) then return end

    local wishEntries = self:GetWishlistForItem(itemID)
    if not wishEntries or #wishEntries == 0 then return end

    ShowLootHelper(itemLink, itemID, player, wishEntries)
end
