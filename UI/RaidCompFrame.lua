---@type WoWGuildSync
local WGS = WoWGuildSync

local raidCompFrame = nil

-- Role display order and colors
local ROLE_ORDER = { "TANK", "HEALER", "DPS" }
local ROLE_LABELS = {
    TANK = "|cff5599ffTanks|r",
    HEALER = "|cff00ff00Healers|r",
    DPS = "|cffff4444DPS|r",
}

local function CreateRaidCompFrame()
    local f = CreateFrame("Frame", "WoWGuildSyncRaidCompFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(320, 450)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", f.TitleBg, "TOPLEFT", 5, -3)
    f.title:SetText("Raid Comp")

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -35)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 10)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    f.scrollFrame = scrollFrame
    f.content = content

    f:Hide()
    return f
end

local function PopulateRaidComp(frame)
    -- Hide previous children (WoW frames can't be GC'd, so just hide)
    local children = { frame.content:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
    end
    -- Hide lingering font strings
    local regions = { frame.content:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end

    local comps = WGS.db.global.raidComps
    if not comps or (type(comps) == "table" and #comps == 0 and next(comps) == nil) then
        local noData = frame.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        noData:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 5, -10)
        noData:SetWidth(frame.scrollFrame:GetWidth() - 10)
        noData:SetJustifyH("LEFT")
        noData:SetWordWrap(true)
        noData:SetText("No raid comp imported. Import from web app first.")
        noData:Show()
        frame.content:SetHeight(40)
        return
    end

    -- raidComps can be a list of comps or a single comp table.
    -- Normalize to a list.
    local compList = comps
    if comps and not comps[1] and comps.assignments then
        compList = { comps }
    end

    local contentWidth = frame.scrollFrame:GetWidth() - 10
    local yOffset = 0

    for compIdx, comp in ipairs(compList) do
        -- Comp header (event name if available)
        local compTitle = comp.name or comp.title or (comp.eventId and ("Event #" .. comp.eventId)) or ("Comp #" .. compIdx)
        local headerRow = CreateFrame("Frame", nil, frame.content)
        headerRow:SetSize(contentWidth, 22)
        headerRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOffset)
        local headerText = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        headerText:SetPoint("LEFT", headerRow, "LEFT", 5, 0)
        headerText:SetText("|cffffd100" .. compTitle .. "|r")
        yOffset = yOffset - 24

        -- Group assignments by role
        local assignments = comp.assignments or comp.members or {}
        local byRole = { TANK = {}, HEALER = {}, DPS = {} }

        for _, member in ipairs(assignments) do
            local role = (member.role or "DPS"):upper()
            if not byRole[role] then
                role = "DPS"
            end
            table.insert(byRole[role], member)
        end

        for _, role in ipairs(ROLE_ORDER) do
            local members = byRole[role]
            if members and #members > 0 then
                -- Role header
                local roleRow = CreateFrame("Frame", nil, frame.content)
                roleRow:SetSize(contentWidth, 18)
                roleRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOffset)
                local roleText = roleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                roleText:SetPoint("LEFT", roleRow, "LEFT", 10, 0)
                roleText:SetText((ROLE_LABELS[role] or role) .. " (" .. #members .. ")")
                yOffset = yOffset - 18

                -- Individual members
                for _, member in ipairs(members) do
                    local memberRow = CreateFrame("Frame", nil, frame.content)
                    memberRow:SetSize(contentWidth, 16)
                    memberRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOffset)

                    local nameStr = member.name or member.playerName or member.characterName or "Unknown"

                    -- Apply class color if class info is available
                    local classFile = member.class or member.classFile or ""
                    classFile = classFile:upper()
                    local colorHex = WGS.CLASS_COLORS[classFile]

                    local nameText = memberRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    nameText:SetPoint("LEFT", memberRow, "LEFT", 22, 0)

                    if colorHex then
                        nameText:SetText("|c" .. colorHex .. nameStr .. "|r")
                    else
                        nameText:SetText(nameStr)
                    end

                    -- Show spec/note if available
                    local extra = member.spec or member.note or nil
                    if extra and extra ~= "" then
                        local extraText = memberRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                        extraText:SetPoint("LEFT", nameText, "RIGHT", 6, 0)
                        extraText:SetText("|cff888888" .. extra .. "|r")
                    end

                    yOffset = yOffset - 16
                end
            end
        end

        yOffset = yOffset - 8 -- spacing between comps
    end

    frame.content:SetHeight(math.abs(yOffset) + 10)
end

function WGS:ToggleRaidCompFrame()
    if not raidCompFrame then
        raidCompFrame = CreateRaidCompFrame()
    end

    if raidCompFrame:IsShown() then
        raidCompFrame:Hide()
    else
        PopulateRaidComp(raidCompFrame)
        raidCompFrame:Show()
    end
end
