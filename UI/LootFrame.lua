---@type WoWGuildSync
local WGS = WoWGuildSync
local L = WoWGuildSync_L

-- Export/Import frame (shared for both operations)
local exportFrame = nil
local importFrame = nil

local function CreateExportFrame()
    local f = CreateFrame("Frame", "WoWGuildSyncExportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(450, 350)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("Export Data")

    -- Instructions
    f.instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.instructions:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
    f.instructions:SetText("|cffff8800[BETA]|r Copy the text below and paste it into your guild web app. Verify data after import.")

    -- Scroll frame with edit box
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -55)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 45)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(scrollFrame:GetWidth())
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    scrollFrame:SetScrollChild(editBox)
    f.editBox = editBox

    -- Select All button
    local btnSelect = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnSelect:SetSize(100, 25)
    btnSelect:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 10)
    btnSelect:SetText("Select All")
    btnSelect:SetScript("OnClick", function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)

    -- Clear exported data button
    local btnClearExported = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClearExported:SetSize(140, 25)
    btnClearExported:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
    btnClearExported:SetText("Clear Exported Data")
    btnClearExported:SetScript("OnClick", function()
        StaticPopup_Show("WGS_CONFIRM_CLEAR_EXPORTED")
    end)

    -- Close button
    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(80, 25)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    -- Confirmation dialog
    StaticPopupDialogs["WGS_CONFIRM_CLEAR_EXPORTED"] = {
        text = "Clear all exported data (loot, attendance, encounters, bank transactions)?\n\nDo this AFTER you've pasted the export into your web app.",
        button1 = "Clear",
        button2 = "Cancel",
        OnAccept = function()
            WGS.db.global.loot = {}
            WGS.db.global.attendance = {}
            WGS.db.global.encounters = {}
            WGS.db.global.guildBankMoneyChanges = {}
            WGS.db.global.guildBankTransactions = {}
            WGS:Print("Exported data cleared. Bank gold balance preserved.")
            f:Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    f:Hide()
    return f
end

local function CreateImportFrame()
    local f = CreateFrame("Frame", "WoWGuildSyncImportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(450, 350)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("Import from Web App")

    -- Instructions
    f.instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.instructions:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
    f.instructions:SetText(L["IMPORT_PROMPT"])

    -- Scroll frame with edit box
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -55)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 45)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(true)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(scrollFrame:GetWidth())
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        f:Hide()
    end)

    scrollFrame:SetScrollChild(editBox)
    f.editBox = editBox

    -- Import button
    local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImport:SetSize(100, 25)
    btnImport:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 10)
    btnImport:SetText("Import")
    btnImport:SetScript("OnClick", function()
        local text = editBox:GetText()
        if text and text ~= "" then
            local success = WGS:DecodeAndImport(text)
            if success then
                f:Hide()
            end
        end
    end)

    -- Clear button
    local btnClear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 25)
    btnClear:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:SetFocus()
    end)

    -- Close button
    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(80, 25)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    btnClose:SetText("Cancel")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    return f
end

function WGS:ShowExportFrame()
    if not exportFrame then
        exportFrame = CreateExportFrame()
    end

    local encoded = self:ExportAll()
    if encoded then
        exportFrame.editBox:SetText(encoded)
        exportFrame:Show()
        exportFrame.editBox:SetFocus()
        exportFrame.editBox:HighlightText()
        self.db.global.lastExport = self:GetTimestamp()
        self:Print(L["EXPORT_COPIED"])
    end
end

function WGS:ShowExportFrameForModule(moduleName)
    if not exportFrame then
        exportFrame = CreateExportFrame()
    end

    local encoded = self:ExportModule(moduleName)
    if encoded then
        exportFrame.title:SetText("Export " .. moduleName:sub(1, 1):upper() .. moduleName:sub(2))
        exportFrame.editBox:SetText(encoded)
        exportFrame:Show()
        exportFrame.editBox:SetFocus()
        exportFrame.editBox:HighlightText()
    end
end

function WGS:ShowExportFrameForModules(moduleNames, label)
    if not exportFrame then
        exportFrame = CreateExportFrame()
    end

    local encoded = self:ExportModules(moduleNames)
    if encoded then
        exportFrame.title:SetText("Export " .. (label or "Selected"))
        exportFrame.editBox:SetText(encoded)
        exportFrame:Show()
        exportFrame.editBox:SetFocus()
        exportFrame.editBox:HighlightText()
        self.db.global.lastExport = self:GetTimestamp()
    end
end

-- JSON export (raw JSON, no WGS envelope — for debugging or manual use)
function WGS:ShowJsonExportFrame()
    if not exportFrame then
        exportFrame = CreateExportFrame()
    end

    local data = self:BuildExportData()
    if not data or next(data) == nil then
        self:Print("No data to export.")
        return
    end

    local json = self:ToJson(data)
    if json then
        exportFrame.title:SetText("Export (Raw JSON)")
        exportFrame.editBox:SetText(json)
        exportFrame:Show()
        exportFrame.editBox:SetFocus()
        exportFrame.editBox:HighlightText()
        self.db.global.lastExport = self:GetTimestamp()
    end
end

function WGS:ShowImportFrame()
    if not importFrame then
        importFrame = CreateImportFrame()
    end

    importFrame.editBox:SetText("")
    importFrame:Show()
    importFrame.editBox:SetFocus()
end
