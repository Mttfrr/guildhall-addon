---@type GuildHall
local WGS = GuildHall

function WGS:ShowBossNotes(encounterName)
    self:SelectMainFrameTab(3, 4)
    if encounterName then
        C_Timer.After(0.05, function() self:SelectBossInTab(encounterName) end)
    end
end

--- Return list of available boss names from imported notes.
function WGS:GetBossNotesList()
    local notes = self.db.global.bossNotes
    if not notes then return {} end
    local list = {}
    for _, note in ipairs(notes) do
        list[#list + 1] = note.encounterName or note.bossName or "Unknown"
    end
    return list
end

--- Populate boss notes into any container with .noteText (FontString) and .content.
function WGS:PopulateBossNotes(container, encounterName)
    if not encounterName then
        container.noteText:SetText("|cff888888Select a boss from the dropdown above.|r")
        container.content:SetHeight(40)
        return
    end

    local notes = self:GetBossNotes(encounterName)
    if not notes then
        container.noteText:SetText("|cff888888No notes found for: " .. encounterName .. "|r")
        container.content:SetHeight(40)
        return
    end

    local text = ""
    if notes.strategy then
        text = text .. "|cffffd100Strategy:|r\n" .. notes.strategy .. "\n\n"
    end
    if notes.assignments then
        text = text .. "|cffffd100Assignments:|r\n" .. notes.assignments .. "\n\n"
    end
    if notes.notes then
        text = text .. "|cffffd100Notes:|r\n" .. notes.notes .. "\n\n"
    end
    if notes.videoUrl then
        text = text .. "|cffffd100Video:|r " .. notes.videoUrl .. "\n"
    end

    container.noteText:SetText(text)
    container.content:SetHeight(container.noteText:GetStringHeight() + 20)
end
