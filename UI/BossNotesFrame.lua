---@type GuildHall
local WGS = GuildHall

-- Route the boss-notes view to the Events tab — the notes panel now
-- lives inside the per-event detail (master-detail rework). The Raids
-- → Boss Notes sub-view is gone. If a specific boss name is requested
-- we stash it on WGS and PopulateEvents picks it up on next render.
function WGS:ShowBossNotes(encounterName)
    if encounterName then
        self._pendingBossNoteSelection = encounterName
    end
    self:SelectMainFrameTab(self._ui.TAB_EVENTS)
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
    -- MRT shared note is global (not per-boss), but it's what raiders
    -- actually look at mid-pull — surface it whenever it's present, so
    -- bosses without GuildHall notes still get the MRT context.
    local mrtNote = self:GetMRTNote()

    local sections = {}
    if notes then
        if notes.strategy then
            sections[#sections + 1] = "|cffffd100Strategy:|r\n" .. notes.strategy
        end
        if notes.assignments then
            sections[#sections + 1] = "|cffffd100Assignments:|r\n" .. notes.assignments
        end
        if notes.notes then
            sections[#sections + 1] = "|cffffd100Notes:|r\n" .. notes.notes
        end
        if notes.videoUrl then
            sections[#sections + 1] = "|cffffd100Video:|r " .. notes.videoUrl
        end
    end
    if mrtNote then
        sections[#sections + 1] = "|cff66ccffMRT Note:|r\n" .. mrtNote
    end

    if #sections == 0 then
        container.noteText:SetText("|cff888888No notes found for: " .. encounterName .. "|r")
        container.content:SetHeight(40)
        return
    end

    container.noteText:SetText(table.concat(sections, "\n\n"))
    container.content:SetHeight(container.noteText:GetStringHeight() + 20)
end
