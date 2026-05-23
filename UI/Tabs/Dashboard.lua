---@type GuildHall
local WGS = GuildHall
local ui = WGS._ui

-- Dashboard tab — the default view. Two columns: Raid Tools on the
-- left (Auto-Invite + Sort Groups), summary text on the right.
-- Bottom-of-tab banner appears when the server's min-addon-version
-- exceeds the running build.

local function BuildDashboardTab(parent)
    local col1X, col2X = 5, 310
    local btnW, btnH, gap = 260, 26, 4

    -- Raid Leader Tools (officer/leader perms required, button checks at runtime).
    -- Attendance + bank capture used to be three "Quick Actions" buttons here;
    -- they're now fully automatic (RAID_INSTANCE_WELCOME for attendance,
    -- GUILDBANKFRAME_OPENED for bank), so the manual buttons were removed.
    local y = 0
    local hdr2 = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr2:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    hdr2:SetText("|cffffd100Raid Tools|r")
    y = y - 18

    local btnInvite = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnInvite:SetSize(btnW, btnH)
    btnInvite:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    btnInvite:SetText("Auto-Invite Team")
    btnInvite:SetScript("OnClick", function()
        WGS:AutoInvite()
    end)
    y = y - btnH - gap

    local btnSort = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSort:SetSize(btnW, btnH)
    btnSort:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    btnSort:SetText("Sort Raid Groups")
    btnSort:SetScript("OnClick", function()
        WGS:SortRaidGroups()
    end)
    y = y - btnH - gap * 3

    local info = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", parent, "TOPLEFT", col1X, y)
    info:SetWidth(btnW)
    info:SetJustifyH("LEFT")
    info:SetText("|cff888888guildhall.run|r")

    -- Settings
    local btnSettings = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btnSettings:SetSize(80, 22)
    btnSettings:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", col1X, 0)
    btnSettings:SetText("Settings")
    btnSettings:SetScript("OnClick", function() WGS:OpenConfig() end)

    -- Summary column
    local hdrSummary = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdrSummary:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, 0)
    hdrSummary:SetText("|cffffd100Summary|r")

    parent.summaryText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    parent.summaryText:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, -22)
    parent.summaryText:SetWidth(270)
    parent.summaryText:SetJustifyH("LEFT")
    parent.summaryText:SetJustifyV("TOP")

    parent.attendanceStatus = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    parent.attendanceStatus:SetPoint("TOPLEFT", parent, "TOPLEFT", col2X, -140)
    parent.attendanceStatus:SetWidth(270)
    parent.attendanceStatus:SetJustifyH("LEFT")

    -- Bottom-of-tab banner: only shown when the server's MIN_ADDON_VERSION
    -- exceeds our running version. Spans both columns so it's hard to miss.
    parent.outdatedBanner = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    parent.outdatedBanner:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 100, 4)
    parent.outdatedBanner:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 4)
    parent.outdatedBanner:SetJustifyH("LEFT")
    parent.outdatedBanner:SetText("")
end

local function RefreshDashboard(tab)
    if not tab or not tab:IsVisible() then return end
    local db = WGS.db.global
    local lines = {}
    lines[#lines + 1] = "|cff888888Loot:|r " .. (db.loot and #db.loot or 0)
        .. "  |cff888888Attend:|r " .. (db.attendance and #db.attendance or 0)
    lines[#lines + 1] = "|cff888888Bank Tx:|r " .. (db.guildBankTransactions and #db.guildBankTransactions or 0)
    local gold = WGS.GetGuildGoldFormatted and WGS:GetGuildGoldFormatted() or nil
    if gold then lines[#lines + 1] = "|cff888888Gold:|r " .. gold end
    if db.lastExport > 0 then
        lines[#lines + 1] = "|cff555555Exported: " .. date("%m/%d %H:%M", db.lastExport) .. "|r"
    end
    if db.lastImport > 0 then
        lines[#lines + 1] = "|cff555555Imported: " .. date("%m/%d %H:%M", db.lastImport) .. "|r"
    end
    tab.summaryText:SetText(table.concat(lines, "\n"))

    if WGS:IsTrackingAttendance() then
        tab.attendanceStatus:SetText("|cff00ff00Attendance: recording|r")
    else
        tab.attendanceStatus:SetText("")
    end

    if tab.outdatedBanner then
        if WGS:IsOutdated() then
            tab.outdatedBanner:SetText(string.format(
                "|cffff8800Addon outdated:|r v%s required, you have v%s. Update at |cff8888ffaddons.wago.io/addons/guildhall-addon|r",
                db.serverMinAddonVersion or "?", WGS.version))
        else
            tab.outdatedBanner:SetText("")
        end
    end
end

ui.tabs[ui.TAB_DASHBOARD] = { build = BuildDashboardTab, refresh = RefreshDashboard }
