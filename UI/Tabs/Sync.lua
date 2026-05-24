---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L
local ui = WGS._ui

-- Sync tab: three stacked sections —
--   Officer Sync       row of status text + "Sync now" button at the top
--   Import from Web    the paste-in editbox (web → addon)
--   Export Data        the read-out editbox (addon → web)
--
-- Officer Sync wraps WGS:PeerSync_ManualCatchup (which the /gh sync
-- slash command also drives). Status comes from WGS:PeerSync_Status.
--
-- The Export edit-box is populated lazily by WGS:PopulateExportEditBox
-- (defined in MainFrame.lua) so the post-raid reminder can drive
-- "Export Now" from outside the tab.

local TAB_INDEX = ui.TAB_SYNC

local OFFICER_SYNC_H = 50    -- height of the new top section
local IMPORT_TOP_Y   = -OFFICER_SYNC_H

local function FormatAgo(ts)
    if not ts or ts == 0 then return "never" end
    local now = (time and time()) or 0
    local delta = now - ts
    if delta < 0   then return "just now" end
    if delta < 60  then return delta .. "s ago" end
    if delta < 3600 then return math.floor(delta / 60) .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end

local function BuildSyncTab(parent)
    ---------------------------------------------------------------------
    -- Officer Sync section (top)
    ---------------------------------------------------------------------

    local oh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    oh:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, 0)
    oh:SetText("|cffffd100Officer Sync|r")

    local btnSync = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSync:SetSize(110, 22)
    btnSync:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -20)
    btnSync:SetText("Sync now")

    local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("LEFT", btnSync, "RIGHT", 12, 0)
    statusText:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(false)

    -- Refresh the status line + the button's enabled state from
    -- WGS:PeerSync_Status. Called on tab show + after a click +
    -- on a short delay so the in-flight probe round completes.
    local function refreshStatus()
        if not WGS.PeerSync_Status then
            statusText:SetText("|cff888888peer-sync not loaded|r")
            btnSync:Disable()
            return
        end
        local s = WGS:PeerSync_Status()
        local parts = {}
        if not s.enabled then
            parts[#parts + 1] = "|cff888888disabled|r"
        elseif not s.isOfficer then
            parts[#parts + 1] = "|cffff5555officer rank required|r"
        elseif not s.channel then
            parts[#parts + 1] = "|cffff5555no channel (need raid / party / guild)|r"
        else
            parts[#parts + 1] = "|cff00ff00on " .. s.channel .. "|r"
        end
        if s.inFlight then
            parts[#parts + 1] = "|cffffd100probing…|r"
        else
            parts[#parts + 1] = "last sync: " .. FormatAgo(s.lastSyncAt)
            if s.lastPeerCount > 0 then
                parts[#parts + 1] = s.lastPeerCount .. " peer" ..
                    (s.lastPeerCount == 1 and "" or "s")
            end
        end
        -- Surface the import freshness so officers can see when
        -- snapshot catchup has lifted them onto a newer payload (and
        -- spot the case where the whole guild is running stale data).
        if s.lastImportAt and s.lastImportAt > 0 then
            parts[#parts + 1] = "import: " .. FormatAgo(s.lastImportAt)
        end
        statusText:SetText("|cffaaaaaa" .. table.concat(parts, "  ·  ") .. "|r")

        if s.enabled and s.isOfficer and s.channel and not s.inFlight then
            btnSync:Enable()
        else
            btnSync:Disable()
        end
    end
    parent.refreshOfficerSync = refreshStatus

    btnSync:SetScript("OnClick", function()
        if WGS.PeerSync_ManualCatchup then
            WGS:PeerSync_ManualCatchup()
        end
        -- Show the in-flight state immediately, then refresh again
        -- after the 5s offer-collection window so the final
        -- "last sync: just now · N peers" lands without waiting on a
        -- tab re-show.
        refreshStatus()
        if C_Timer and C_Timer.After then
            C_Timer.After(6, refreshStatus)
        end
    end)

    -- Divider below the Officer Sync section so it reads as a distinct
    -- strip from the Import paste-in area beneath.
    local oDiv = parent:CreateTexture(nil, "ARTWORK")
    oDiv:SetHeight(1)
    oDiv:SetPoint("TOPLEFT",  parent, "TOPLEFT",  5, IMPORT_TOP_Y + 5)
    oDiv:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, IMPORT_TOP_Y + 5)
    oDiv:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    ---------------------------------------------------------------------
    -- Import section (paste-in from web)
    --
    -- y-offsets are shifted by OFFICER_SYNC_H so the original spacing
    -- math stays legible — IMPORT_TOP_Y replaces the old "0" anchor.
    ---------------------------------------------------------------------

    local midY = IMPORT_TOP_Y - 245   -- mirrors the original midY = -245

    local ih = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ih:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, IMPORT_TOP_Y)
    ih:SetText("|cffffd100Import from Web App|r")

    local ii = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ii:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, IMPORT_TOP_Y - 18)
    ii:SetText(L["IMPORT_PROMPT"])

    local isf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    isf:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0,   IMPORT_TOP_Y - 35)
    isf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, IMPORT_TOP_Y - 35)
    isf:SetHeight(140)   -- 20 shorter than before to make room for Officer Sync

    local ieb = CreateFrame("EditBox", nil, isf)
    ieb:SetMultiLine(true)
    ieb:SetAutoFocus(false)
    ieb:SetFontObject("ChatFontNormal")
    ieb:SetWidth(660)
    ieb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    isf:SetScrollChild(ieb)
    isf:EnableMouse(true)
    isf:SetScript("OnMouseDown", function() ieb:SetFocus() end)
    parent.importEditBox = ieb

    local btnImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 25)
    btnImport:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, IMPORT_TOP_Y - 180)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local text = ieb:GetText()
        if text and text ~= "" then
            if WGS:DecodeAndImport(text) then
                ieb:SetText("")
                ieb:ClearFocus()
                WGS:RefreshMainFrame()
            end
        end
    end)

    local btnClearImport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearImport:SetSize(80, 25)
    btnClearImport:SetPoint("LEFT", btnImport, "RIGHT", 8, 0)
    btnClearImport:SetText("Clear")
    btnClearImport:SetScript("OnClick", function()
        ieb:SetText("")
        ieb:SetFocus()
    end)

    -- Divider between Import and Export
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  parent, "TOPLEFT",  5, midY + 5)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, midY + 5)
    div:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    ---------------------------------------------------------------------
    -- Export section (read-out to web)
    ---------------------------------------------------------------------

    local eh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eh:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY)
    eh:SetText("|cffffd100Export Data|r")

    local ei = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ei:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY - 18)
    ei:SetText("Copy the text below and paste it into your guild web app.")

    local esf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    esf:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, midY - 35)
    esf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 30)

    local eeb = CreateFrame("EditBox", nil, esf)
    eeb:SetMultiLine(true)
    eeb:SetAutoFocus(false)
    eeb:SetFontObject("ChatFontNormal")
    eeb:SetWidth(660)
    eeb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    esf:SetScrollChild(eeb)
    esf:EnableMouse(true)
    esf:SetScript("OnMouseDown", function() eeb:SetFocus() end)
    parent.exportEditBox = eeb

    local function runExport()
        local encoded = WGS:ExportAll()
        if encoded then
            eeb:SetText(encoded)
            eeb:SetFocus()
            eeb:HighlightText()
            WGS.db.global.lastExport = WGS:GetTimestamp()
            WGS:Print(L["EXPORT_COPIED"])
        end
    end

    -- Stash on the parent so WGS:PopulateExportEditBox can invoke it
    -- from anywhere (post-raid reminder → ShowExportFrame in particular).
    parent.runExport = runExport

    local btnExport = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnExport:SetSize(100, 25)
    btnExport:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 5, 0)
    btnExport:SetText("Export")
    btnExport:SetScript("OnClick", runExport)

    local btnSelectAll = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSelectAll:SetSize(100, 25)
    btnSelectAll:SetPoint("LEFT", btnExport, "RIGHT", 8, 0)
    btnSelectAll:SetText("Select All")
    btnSelectAll:SetScript("OnClick", function()
        eeb:SetFocus()
        eeb:HighlightText()
    end)

    local btnClearExported = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnClearExported:SetSize(160, 25)
    btnClearExported:SetPoint("LEFT", btnSelectAll, "RIGHT", 8, 0)
    btnClearExported:SetText("Clear Exported Data")
    btnClearExported:SetScript("OnClick", function()
        StaticPopup_Show("WGS_CONFIRM_CLEAR_EXPORTED")
    end)

    -- Render the Officer Sync status once on build; subsequent refreshes
    -- happen in the refresh hook below.
    refreshStatus()
end

-- Sync's auto-refresh path was previously empty (Import + Export only
-- updated on user actions). Now we re-render the Officer Sync status
-- whenever the tab becomes visible so a stale "last sync: 4h ago" gets
-- corrected on every tab switch.
local function RefreshSyncTab(tab)
    if not tab or not tab:IsVisible() then return end
    if tab.refreshOfficerSync then tab.refreshOfficerSync() end
end

ui.tabs[TAB_INDEX] = { build = BuildSyncTab, refresh = RefreshSyncTab }
