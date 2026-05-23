---@type GuildHall
local WGS = GuildHall
local L = GuildHall_L
local ui = WGS._ui

-- Sync tab: import + export, stacked vertically with a divider.
-- The export edit-box is populated lazily by WGS:PopulateExportEditBox
-- (defined in MainFrame.lua) so the post-raid reminder can drive
-- "Export Now" from outside the tab.

local TAB_INDEX = ui.TAB_SYNC

local function BuildSyncTab(parent)
    local midY = -245

    -- Import section
    local ih = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ih:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, 0)
    ih:SetText("|cffffd100Import from Web App|r")

    local ii = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ii:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -18)
    ii:SetText(L["IMPORT_PROMPT"])

    local isf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    isf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -35)
    isf:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, -35)
    isf:SetHeight(160)

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
    btnImport:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -200)
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

    -- Divider
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY + 5)
    div:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, midY + 5)
    div:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    -- Export section
    local eh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eh:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY)
    eh:SetText("|cffffd100Export Data|r")

    local ei = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ei:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, midY - 18)
    ei:SetText("Copy the text below and paste it into your guild web app.")

    local esf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    esf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, midY - 35)
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

    -- Stash on the parent so WGS:PopulateExportEditBox can invoke it from
    -- anywhere (post-raid reminder → ShowExportFrame in particular).
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
end

-- Sync has no auto-refresh path — content updates only on user
-- actions (Import, Export buttons). Register with build only.
ui.tabs[TAB_INDEX] = { build = BuildSyncTab }
