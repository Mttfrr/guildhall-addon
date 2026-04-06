---@type WoWGuildSync
local WGS = WoWGuildSync

local readinessFrame = nil

local function CreateReadinessFrame()
    local f = CreateFrame("Frame", "WoWGuildSyncReadinessFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(380, 400)
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
    f.title:SetText("Raid Readiness")

    -- Summary line
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.summary:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
    f.summary:SetWidth(350)
    f.summary:SetJustifyH("LEFT")

    -- Scroll frame for player issues
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -70)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 45)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    f.scrollFrame = scrollFrame
    f.content = content

    -- Announce button
    f.announceBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.announceBtn:SetSize(160, 26)
    f.announceBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 10)
    f.announceBtn:SetText("Announce to Raid")

    -- Close button
    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(80, 26)
    btnClose:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 10)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    return f
end

local function PopulateReadiness(frame)
    -- Hide previous content
    local children = { frame.content:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { frame.content:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local gearAudit = WGS.db.global.gearAudit
    if not gearAudit or #gearAudit == 0 then
        frame.summary:SetText("|cff00ff00No gear issues reported!|r Import latest data from the web app for an up-to-date check.")
        frame.content:SetHeight(10)
        frame.announceBtn:Hide()
        return
    end

    -- Cross-reference with current raid members
    local raidMembers = {}
    if IsInRaid() or IsInGroup() then
        local members = WGS:GetRaidMembers()
        for name in pairs(members) do
            -- Store both full name and short name for matching
            raidMembers[name:lower()] = true
            local short = name:match("^([^%-]+)")
            if short then raidMembers[short:lower()] = true end
        end
    end

    local inRaid = next(raidMembers) ~= nil
    local contentWidth = frame.scrollFrame:GetWidth() - 10
    local yOffset = 0
    local totalIssues = 0
    local playersWithIssues = 0
    local announceLines = {}

    for _, entry in ipairs(gearAudit) do
        local name = entry.characterName or entry.playerName or "Unknown"
        local shortName = name:match("^([^%-]+)") or name

        -- If in raid, only show issues for current raid members
        if inRaid and not raidMembers[name:lower()] and not raidMembers[shortName:lower()] then
            -- skip non-raid members
        else
            local missingEnchants = entry.missingEnchants or 0
            local missingGems = entry.missingGems or 0
            local ilvl = entry.ilvl or 0
            local targetIlvl = WGS.db.global.targetIlvl or 0

            local issues = {}
            if missingEnchants > 0 then
                table.insert(issues, "|cffff4444" .. missingEnchants .. " missing enchant(s)|r")
            end
            if missingGems > 0 then
                table.insert(issues, "|cffff8800" .. missingGems .. " missing gem(s)|r")
            end
            if targetIlvl > 0 and ilvl > 0 and ilvl < targetIlvl then
                table.insert(issues, "|cffaaaaaa" .. string.format("ilvl %d (target: %d)", ilvl, targetIlvl) .. "|r")
            end

            if #issues > 0 then
                playersWithIssues = playersWithIssues + 1
                totalIssues = totalIssues + missingEnchants + missingGems

                local row = CreateFrame("Frame", nil, frame.content)
                row:SetSize(contentWidth, 32)
                row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, yOffset)

                -- Class-colored name
                local classFile = (entry.class or ""):upper()
                local colorHex = WGS.CLASS_COLORS[classFile] or "ffffffff"
                local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 5, -2)
                nameText:SetText("|c" .. colorHex .. shortName .. "|r")

                -- Issues on second line
                local issueText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                issueText:SetPoint("TOPLEFT", row, "TOPLEFT", 15, -16)
                issueText:SetText(table.concat(issues, "  "))

                yOffset = yOffset - 34

                -- Build announce line
                local plainIssues = {}
                if missingEnchants > 0 then table.insert(plainIssues, missingEnchants .. " enchant(s)") end
                if missingGems > 0 then table.insert(plainIssues, missingGems .. " gem(s)") end
                table.insert(announceLines, shortName .. ": missing " .. table.concat(plainIssues, ", "))
            end
        end
    end

    frame.content:SetHeight(math.abs(yOffset) + 10)

    -- Summary
    if playersWithIssues == 0 then
        if inRaid then
            frame.summary:SetText("|cff00ff00All raid members are fully enchanted and gemmed!|r")
        else
            frame.summary:SetText("|cff00ff00No gear issues found!|r Join a raid to filter to current members.")
        end
        frame.announceBtn:Hide()
    else
        local scope = inRaid and "in current raid" or "in guild"
        frame.summary:SetText(string.format("|cffff8800%d player(s) %s with gear issues (%d total)|r", playersWithIssues, scope, totalIssues))
        frame.announceBtn:Show()
    end

    -- Announce button
    frame.announceBtn:SetScript("OnClick", function()
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if not channel then
            WGS:Print("Not in a group.")
            return
        end
        C_ChatInfo.SendChatMessage("[GuildHall] Raid Readiness Check — " .. playersWithIssues .. " player(s) with gear issues:", channel)
        for _, line in ipairs(announceLines) do
            C_ChatInfo.SendChatMessage("  " .. line, channel)
        end
    end)
end

function WGS:ToggleReadinessFrame()
    if not readinessFrame then
        readinessFrame = CreateReadinessFrame()
    end

    if readinessFrame:IsShown() then
        readinessFrame:Hide()
    else
        PopulateReadiness(readinessFrame)
        readinessFrame:Show()
    end
end

-- Auto-show readiness warning on raid join if enabled and issues exist
function WGS:CheckRaidReadiness()
    if not self.db.profile.showReadinessCheck then return end

    local gearAudit = self.db.global.gearAudit
    if not gearAudit or #gearAudit == 0 then return end

    -- Count issues for current raid members
    local members = self:GetRaidMembers()
    local issueCount = 0
    for _, entry in ipairs(gearAudit) do
        local name = entry.characterName or entry.playerName or ""
        local shortName = name:match("^([^%-]+)") or name
        for memberName in pairs(members) do
            local memberShort = memberName:match("^([^%-]+)") or memberName
            if shortName:lower() == memberShort:lower() then
                if (entry.missingEnchants or 0) > 0 or (entry.missingGems or 0) > 0 then
                    issueCount = issueCount + 1
                end
                break
            end
        end
    end

    if issueCount > 0 then
        self:Print(string.format("|cffff8800Readiness Warning:|r %d raid member(s) have gear issues. Type /wgs readiness to view details.", issueCount))
    end
end
