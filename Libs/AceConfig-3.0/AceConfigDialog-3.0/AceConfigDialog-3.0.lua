--- AceConfigDialog-3.0 generates AceGUI-3.0 based options dialogs from AceConfigRegistry-3.0 options tables.
-- @class file
-- @name AceConfigDialog-3.0
local MAJOR, MINOR = "AceConfigDialog-3.0", 82
local AceConfigDialog = LibStub:NewLibrary(MAJOR, MINOR)

if not AceConfigDialog then return end

local AceGUI = LibStub("AceGUI-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

-- Lua APIs
local pairs, next, type, unpack, select = pairs, next, type, unpack, select
local error, assert = error, assert
local tinsert, tsort, tremove = table.insert, table.sort, table.remove
local format, strmatch, strsub = string.format, string.match, string.sub
local tostring, tonumber = tostring, tonumber
local math_min, math_max, math_floor = math.min, math.max, math.floor

AceConfigDialog.OpenFrames = AceConfigDialog.OpenFrames or {}
AceConfigDialog.Status = AceConfigDialog.Status or {}
AceConfigDialog.frame = AceConfigDialog.frame or CreateFrame("Frame")

-- Internal: get sorted keys for an options table
local function GetSortedKeys(options)
    local keys = {}
    for k in pairs(options) do
        tinsert(keys, k)
    end
    tsort(keys, function(a, b)
        local orderA = options[a] and options[a].order or 100
        local orderB = options[b] and options[b].order or 100
        if type(orderA) == "function" then orderA = orderA() or 100 end
        if type(orderB) == "function" then orderB = orderB() or 100 end
        if orderA == orderB then
            return tostring(a) < tostring(b)
        end
        return orderA < orderB
    end)
    return keys
end

-- Internal: Check if an option is hidden
local function IsHidden(opt, ...)
    if opt.hidden == nil then return false end
    if type(opt.hidden) == "function" then return opt.hidden(...) end
    if type(opt.hidden) == "boolean" then return opt.hidden end
    return false
end

-- Internal: Check if an option is disabled
local function IsDisabled(opt, ...)
    if opt.disabled == nil then return false end
    if type(opt.disabled) == "function" then return opt.disabled(...) end
    if type(opt.disabled) == "boolean" then return opt.disabled end
    return false
end

-- Internal: Get option value with info table
local function GetOptionValue(opt, info)
    if opt.get then
        if type(opt.get) == "function" then
            return opt.get(info)
        elseif type(opt.get) == "string" then
            -- Method name on handler
            local handler = opt.handler
            if handler and handler[opt.get] then
                return handler[opt.get](handler, info)
            end
        end
    end
    return nil
end

-- Internal: Set option value with info table
local function SetOptionValue(opt, info, ...)
    if opt.set then
        if type(opt.set) == "function" then
            opt.set(info, ...)
        elseif type(opt.set) == "string" then
            local handler = opt.handler
            if handler and handler[opt.set] then
                handler[opt.set](handler, info, ...)
            end
        end
    end
end

-- Feed options into a container widget
local function FeedOptions(appName, options, container, rootframe, path, group)
    if not group or not group.args then return end

    container:PauseLayout()
    local sortedKeys = GetSortedKeys(group.args)

    for _, key in ipairs(sortedKeys) do
        local opt = group.args[key]
        if type(opt) == "table" and not IsHidden(opt) then
            local optType = opt.type

            -- Build the info table
            local info = {
                [0] = appName,
                option = opt,
                options = options,
                type = optType,
                handler = opt.handler or group.handler or (options and options.handler),
                arg = opt.arg,
            }
            for i, v in ipairs(path) do info[i] = v end
            tinsert(info, key)

            local disabled = IsDisabled(opt, info)

            if optType == "group" then
                -- Groups are handled by the container type (tab, tree, etc.)
                -- For inline groups, create an InlineGroup widget
                if opt.inline then
                    local groupWidget = AceGUI:Create("InlineGroup")
                    groupWidget:SetTitle(opt.name or key)
                    groupWidget:SetFullWidth(true)
                    groupWidget:SetLayout(opt.dialogInline and "Flow" or "List")
                    container:AddChild(groupWidget)

                    local subPath = {}
                    for i, v in ipairs(path) do subPath[i] = v end
                    tinsert(subPath, key)
                    FeedOptions(appName, options, groupWidget, rootframe, subPath, opt)
                end
            elseif optType == "execute" then
                local widget = AceGUI:Create("Button")
                widget:SetText(opt.name or key)
                if opt.desc then
                    widget:SetCallback("OnEnter", function(w)
                        GameTooltip:SetOwner(w.frame, "ANCHOR_TOPRIGHT")
                        GameTooltip:SetText(opt.name or key, 1, 0.82, 0, true)
                        GameTooltip:AddLine(opt.desc, 1, 1, 1, true)
                        GameTooltip:Show()
                    end)
                    widget:SetCallback("OnLeave", function() GameTooltip:Hide() end)
                end
                widget:SetCallback("OnClick", function()
                    if opt.func then
                        opt.func(info)
                    end
                end)
                widget:SetDisabled(disabled)
                container:AddChild(widget)

            elseif optType == "toggle" then
                local widget = AceGUI:Create("CheckBox")
                widget:SetLabel(opt.name or key)
                widget:SetValue(GetOptionValue(opt, info) and true or false)
                widget:SetCallback("OnValueChanged", function(_, _, value)
                    SetOptionValue(opt, info, value)
                end)
                widget:SetDisabled(disabled)
                if opt.width == "full" then widget:SetFullWidth(true) end
                container:AddChild(widget)

            elseif optType == "input" then
                local widget
                if opt.multiline then
                    widget = AceGUI:Create("MultiLineEditBox")
                else
                    widget = AceGUI:Create("EditBox")
                end
                widget:SetLabel(opt.name or key)
                widget:SetText(GetOptionValue(opt, info) or "")
                widget:SetCallback("OnEnterPressed", function(_, _, value)
                    SetOptionValue(opt, info, value)
                end)
                widget:SetDisabled(disabled)
                if opt.width == "full" then widget:SetFullWidth(true) end
                container:AddChild(widget)

            elseif optType == "range" then
                local widget = AceGUI:Create("Slider")
                widget:SetLabel(opt.name or key)
                local min = opt.min or 0
                local max = opt.max or 100
                local step = opt.step or 1
                local bigStep = opt.bigStep or step
                widget:SetSliderValues(min, max, bigStep)
                widget:SetIsPercent(opt.isPercent)
                local value = GetOptionValue(opt, info) or min
                widget:SetValue(value)
                widget:SetCallback("OnValueChanged", function(_, _, value)
                    SetOptionValue(opt, info, value)
                end)
                widget:SetDisabled(disabled)
                if opt.width == "full" then widget:SetFullWidth(true) end
                container:AddChild(widget)

            elseif optType == "select" then
                local widget = AceGUI:Create("Dropdown")
                widget:SetLabel(opt.name or key)
                local values = opt.values
                if type(values) == "function" then values = values(info) end
                widget:SetList(values or {}, opt.sorting)
                widget:SetValue(GetOptionValue(opt, info))
                widget:SetCallback("OnValueChanged", function(_, _, value)
                    SetOptionValue(opt, info, value)
                end)
                widget:SetDisabled(disabled)
                if opt.width == "full" then widget:SetFullWidth(true) end
                container:AddChild(widget)

            elseif optType == "multiselect" then
                local values = opt.values
                if type(values) == "function" then values = values(info) end
                if values then
                    local widget = AceGUI:Create("Dropdown")
                    widget:SetLabel(opt.name or key)
                    widget:SetMultiselect(true)
                    widget:SetList(values, opt.sorting)
                    widget:SetDisabled(disabled)
                    container:AddChild(widget)
                end

            elseif optType == "color" then
                local widget = AceGUI:Create("ColorPicker")
                widget:SetLabel(opt.name or key)
                widget:SetHasAlpha(opt.hasAlpha)
                local r, g, b, a = GetOptionValue(opt, info)
                widget:SetColor(r or 1, g or 1, b or 1, a or 1)
                widget:SetCallback("OnValueChanged", function(_, _, r, g, b, a)
                    SetOptionValue(opt, info, r, g, b, a)
                end)
                widget:SetDisabled(disabled)
                container:AddChild(widget)

            elseif optType == "keybinding" then
                local widget = AceGUI:Create("Keybinding")
                widget:SetLabel(opt.name or key)
                widget:SetKey(GetOptionValue(opt, info))
                widget:SetCallback("OnKeyChanged", function(_, _, key)
                    SetOptionValue(opt, info, key)
                end)
                widget:SetDisabled(disabled)
                container:AddChild(widget)

            elseif optType == "header" then
                local widget = AceGUI:Create("Heading")
                widget:SetText(opt.name or "")
                widget:SetFullWidth(true)
                container:AddChild(widget)

            elseif optType == "description" then
                local widget = AceGUI:Create("Label")
                widget:SetText(opt.name or "")
                if opt.fontSize == "medium" then
                    widget:SetFontObject(GameFontHighlight)
                elseif opt.fontSize == "large" then
                    widget:SetFontObject(GameFontHighlightLarge)
                end
                if opt.width == "full" then widget:SetFullWidth(true) end
                container:AddChild(widget)
            end
        end
    end

    container:ResumeLayout()
    container:DoLayout()
end

--- Open an options dialog for appName.
-- @param appName The application name as given to AceConfigRegistry
-- @param container (optional) An existing container to use instead of opening a new frame
function AceConfigDialog:Open(appName, container, ...)
    local options = AceConfigRegistry:GetOptionsTable(appName, "dialog")
    if not options then
        error(format("Options table %q not found.", appName), 2)
    end

    local f

    if container then
        f = container
        f:ReleaseChildren()
    else
        -- Check for existing open frame
        if self.OpenFrames[appName] then
            -- Already open, just refresh
            local frame = self.OpenFrames[appName]
            frame:ReleaseChildren()
            FeedOptions(appName, options, frame, frame, {}, options)
            return
        end

        f = AceGUI:Create("Frame")
        f:SetTitle(options.name or appName)
        f:SetStatusText("")
        f:SetLayout("Fill")
        f:SetCallback("OnClose", function(widget)
            AceGUI:Release(widget)
            self.OpenFrames[appName] = nil
        end)
        self.OpenFrames[appName] = f
    end

    -- Determine container type based on childGroups
    local path = {}
    if select("#", ...) > 0 then
        for i = 1, select("#", ...) do
            tinsert(path, select(i, ...))
        end
    end

    -- Check if we need a tree/tab wrapper
    local hasSubGroups = false
    if options.args then
        for _, v in pairs(options.args) do
            if type(v) == "table" and v.type == "group" and not v.inline then
                hasSubGroups = true
                break
            end
        end
    end

    if hasSubGroups then
        local childGroups = options.childGroups or "tree"
        if childGroups == "tree" then
            local treeGroup = AceGUI:Create("TreeGroup")
            treeGroup:SetFullWidth(true)
            treeGroup:SetFullHeight(true)
            treeGroup:SetLayout("Fill")

            -- Build tree data
            local tree = {}
            local sortedKeys = GetSortedKeys(options.args)
            for _, key in ipairs(sortedKeys) do
                local opt = options.args[key]
                if type(opt) == "table" and not IsHidden(opt) then
                    tinsert(tree, {
                        value = key,
                        text = opt.name or key,
                        icon = opt.icon,
                    })
                end
            end
            treeGroup:SetTree(tree)

            treeGroup:SetCallback("OnGroupSelected", function(_, _, group)
                treeGroup:ReleaseChildren()
                local opt = options.args[group]
                if opt then
                    local scrollFrame = AceGUI:Create("ScrollFrame")
                    scrollFrame:SetLayout("List")
                    treeGroup:AddChild(scrollFrame)
                    FeedOptions(appName, options, scrollFrame, f, {group}, opt)
                end
            end)

            f:AddChild(treeGroup)

            -- Select first group
            if tree[1] then
                treeGroup:SelectByValue(tree[1].value)
                treeGroup:Fire("OnGroupSelected", tree[1].value)
            end
        elseif childGroups == "tab" then
            local tabGroup = AceGUI:Create("TabGroup")
            tabGroup:SetFullWidth(true)
            tabGroup:SetFullHeight(true)
            tabGroup:SetLayout("Fill")

            local tabs = {}
            local sortedKeys = GetSortedKeys(options.args)
            for _, key in ipairs(sortedKeys) do
                local opt = options.args[key]
                if type(opt) == "table" and not IsHidden(opt) then
                    tinsert(tabs, { value = key, text = opt.name or key })
                end
            end
            tabGroup:SetTabs(tabs)

            tabGroup:SetCallback("OnGroupSelected", function(_, _, group)
                tabGroup:ReleaseChildren()
                local opt = options.args[group]
                if opt then
                    local scrollFrame = AceGUI:Create("ScrollFrame")
                    scrollFrame:SetLayout("List")
                    tabGroup:AddChild(scrollFrame)
                    FeedOptions(appName, options, scrollFrame, f, {group}, opt)
                end
            end)

            f:AddChild(tabGroup)

            if tabs[1] then
                tabGroup:SelectTab(tabs[1].value)
                tabGroup:Fire("OnGroupSelected", tabs[1].value)
            end
        end
    else
        -- Simple list of options
        local scrollFrame = AceGUI:Create("ScrollFrame")
        scrollFrame:SetLayout("List")
        f:AddChild(scrollFrame)
        FeedOptions(appName, options, scrollFrame, f, {}, options)
    end

    return f
end

--- Close an open options dialog
function AceConfigDialog:Close(appName)
    if self.OpenFrames[appName] then
        AceGUI:Release(self.OpenFrames[appName])
        self.OpenFrames[appName] = nil
    end
end

--- Close all open options dialogs
function AceConfigDialog:CloseAll()
    for appName, frame in pairs(self.OpenFrames) do
        AceGUI:Release(frame)
        self.OpenFrames[appName] = nil
    end
end

--- Add options to Blizzard Interface Options panel
function AceConfigDialog:AddToBlizOptions(appName, name, parent, ...)
    local options = AceConfigRegistry:GetOptionsTable(appName, "dialog")
    if not options then
        error(format("Options table %q not found.", appName), 2)
    end

    name = name or options.name or appName

    -- Create a frame for the Blizzard options panel
    local panel = CreateFrame("Frame")
    panel.name = name
    panel.parent = parent

    local path = {...}

    panel.OnCommit = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() end

    local isInitialized = false
    local function Initialize()
        if isInitialized then return end
        isInitialized = true

        -- Create an AceGUI container within the panel
        local container = AceGUI:Create("SimpleGroup")
        container:SetLayout("Fill")
        container.frame:SetParent(panel)
        container.frame:SetAllPoints()
        container.frame:Show()

        local scrollFrame = AceGUI:Create("ScrollFrame")
        scrollFrame:SetLayout("List")
        container:AddChild(scrollFrame)

        local group = options
        if #path > 0 then
            for _, key in ipairs(path) do
                if group.args and group.args[key] then
                    group = group.args[key]
                end
            end
        end

        FeedOptions(appName, options, scrollFrame, panel, path, group)
    end

    panel:SetScript("OnShow", Initialize)

    -- Register with the new Settings API if available, otherwise use InterfaceOptions_AddCategory
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category
        if parent then
            local parentCategory = AceConfigDialog.BlizCategories and AceConfigDialog.BlizCategories[parent]
            if parentCategory then
                category = Settings.RegisterCanvasLayoutSubcategory(parentCategory, panel, name, name)
            else
                category = Settings.RegisterCanvasLayoutCategory(panel, name, name)
            end
        else
            category = Settings.RegisterCanvasLayoutCategory(panel, name, name)
        end
        if category then
            category.ID = name
            AceConfigDialog.BlizCategories = AceConfigDialog.BlizCategories or {}
            AceConfigDialog.BlizCategories[appName] = category
        end
    else
        InterfaceOptions_AddCategory(panel)
    end

    return panel
end

-- Listen for config changes to refresh open dialogs
AceConfigRegistry.callbacks:RegisterCallback(AceConfigDialog, "ConfigTableChange", function(_, _, appName)
    if AceConfigDialog.OpenFrames[appName] then
        AceConfigDialog:Open(appName)
    end
end)

--- Select a group in the open dialog
function AceConfigDialog:SelectGroup(appName, ...)
    -- This is a simplified version
    local frame = self.OpenFrames[appName]
    if not frame then return end
end

--- Set the default size for a dialog
function AceConfigDialog:SetDefaultSize(appName, width, height)
    if not self.Status[appName] then
        self.Status[appName] = {}
    end
    self.Status[appName].width = width
    self.Status[appName].height = height
end
