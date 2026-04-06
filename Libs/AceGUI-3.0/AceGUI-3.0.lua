--- AceGUI-3.0 provides access to numerous widgets which can be used to create GUIs.
-- AceGUI is used by AceConfigDialog to create the option GUIs, but can also be used standalone.
-- @class file
-- @name AceGUI-3.0
local MAJOR, MINOR = "AceGUI-3.0", 41
local AceGUI = LibStub:NewLibrary(MAJOR, MINOR)

if not AceGUI then return end

-- Lua APIs
local tconcat, tremove, tinsert = table.concat, table.remove, table.insert
local select, pairs, next, type = select, pairs, next, type
local error, assert, loadstring = error, assert, loadstring
local setmetatable, rawget, rawset = setmetatable, rawget, rawset
local math_max, math_min, math_ceil = math.max, math.min, math.ceil
local tostring, format = tostring, string.format

-- WoW APIs
local CreateFrame, UIParent = CreateFrame, UIParent

AceGUI.WidgetRegistry = AceGUI.WidgetRegistry or {}
AceGUI.LayoutRegistry = AceGUI.LayoutRegistry or {}
AceGUI.WidgetBase = AceGUI.WidgetBase or {}
AceGUI.WidgetContainerBase = AceGUI.WidgetContainerBase or {}
AceGUI.WidgetVersions = AceGUI.WidgetVersions or {}
AceGUI.tooltip = AceGUI.tooltip or CreateFrame("GameTooltip", "AceGUITooltip", UIParent, "GameTooltipTemplate")

-- xpcall safecall
local xpcall = xpcall
local function errorhandler(err)
    return geterrorhandler()(err)
end
local function safecall(func, ...)
    if func then
        return xpcall(func, errorhandler, ...)
    end
end

-- Pool for recycling widgets
AceGUI.objPools = AceGUI.objPools or {}

----- WidgetBase -----
local WidgetBase = AceGUI.WidgetBase

function WidgetBase:SetCallback(name, func)
    self.events = self.events or {}
    self.events[name] = func
end

function WidgetBase:Fire(name, ...)
    if self.events and self.events[name] then
        local success, ret = safecall(self.events[name], self, name, ...)
        if success then return ret end
    end
end

function WidgetBase:SetWidth(width)
    self.frame:SetWidth(width)
    self.frame.width = width
    if self.OnWidthSet then
        self:OnWidthSet(width)
    end
end

function WidgetBase:SetRelativeWidth(width)
    if width <= 0.0 or width > 1.0 then
        error(":SetRelativeWidth: width must be between 0 and 1", 2)
    end
    self.relWidth = width
    self.width = "relative"
end

function WidgetBase:SetHeight(height)
    self.frame:SetHeight(height)
    self.frame.height = height
    if self.OnHeightSet then
        self:OnHeightSet(height)
    end
end

function WidgetBase:SetRelativeHeight(height)
    if height <= 0.0 or height > 1.0 then
        error(":SetRelativeHeight: height must be between 0 and 1", 2)
    end
    self.relHeight = height
    self.height = "relative"
end

function WidgetBase:IsVisible()
    return self.frame:IsVisible()
end

function WidgetBase:IsShown()
    return self.frame:IsShown()
end

function WidgetBase:Release()
    AceGUI:Release(self)
end

function WidgetBase:SetPoint(...)
    return self.frame:SetPoint(...)
end

function WidgetBase:ClearAllPoints()
    return self.frame:ClearAllPoints()
end

function WidgetBase:GetNumPoints()
    return self.frame:GetNumPoints()
end

function WidgetBase:GetPoint(...)
    return self.frame:GetPoint(...)
end

function WidgetBase:GetUserDataTable()
    return self.userdata
end

function WidgetBase:SetUserData(key, value)
    self.userdata = self.userdata or {}
    self.userdata[key] = value
end

function WidgetBase:GetUserData(key)
    return self.userdata and self.userdata[key]
end

function WidgetBase:SetFullWidth(isFull)
    if isFull then
        self.width = "fill"
    else
        self.width = nil
    end
end

function WidgetBase:SetFullHeight(isFull)
    if isFull then
        self.height = "fill"
    else
        self.height = nil
    end
end

----- WidgetContainerBase -----
local WidgetContainerBase = AceGUI.WidgetContainerBase

function WidgetContainerBase:AddChild(child, beforeWidget)
    if beforeWidget then
        for i, widget in pairs(self.children) do
            if widget == beforeWidget then
                tinsert(self.children, i, child)
                child:SetParent(self)
                child.frame:Show()
                self:DoLayout()
                return
            end
        end
    end
    tinsert(self.children, child)
    child:SetParent(self)
    child.frame:Show()
    self:DoLayout()
end

function WidgetContainerBase:AddChildren(...)
    for i = 1, select("#", ...) do
        local child = select(i, ...)
        tinsert(self.children, child)
        child:SetParent(self)
        child.frame:Show()
    end
    self:DoLayout()
end

function WidgetContainerBase:ReleaseChildren()
    local children = self.children
    for i = 1, #children do
        AceGUI:Release(children[i])
        children[i] = nil
    end
end

function WidgetContainerBase:SetLayout(layout)
    self.layout = layout
end

function WidgetContainerBase:SetAutoAdjustHeight(adjust)
    if adjust then
        self.noAutoHeight = nil
    else
        self.noAutoHeight = true
    end
end

function WidgetContainerBase:DoLayout()
    local layout = self.layout or "List"
    local layoutFunc = AceGUI.LayoutRegistry[layout]
    if layoutFunc then
        safecall(layoutFunc, self.content or self.frame, self.children)
    end
end

function WidgetContainerBase:PauseLayout()
    self.LayoutPaused = true
end

function WidgetContainerBase:ResumeLayout()
    self.LayoutPaused = nil
    self:DoLayout()
end

function WidgetContainerBase:SetParent(parent)
    -- Override in widget
end

----- Core AceGUI functions -----

--- Register a widget type
function AceGUI:RegisterWidgetType(Name, Constructor, Version)
    assert(type(Constructor) == "function")
    assert(type(Version) == "number")

    local oldVersion = AceGUI.WidgetVersions[Name]
    if oldVersion and oldVersion >= Version then return end

    AceGUI.WidgetVersions[Name] = Version
    AceGUI.WidgetRegistry[Name] = Constructor
end

--- Register a layout
function AceGUI:RegisterLayout(Name, LayoutFunc)
    assert(type(LayoutFunc) == "function")
    AceGUI.LayoutRegistry[Name] = LayoutFunc
end

--- Create a new widget
function AceGUI:Create(type_name)
    if not AceGUI.WidgetRegistry[type_name] then
        error(("Widget type %q is not registered."):format(tostring(type_name)), 2)
    end

    -- Check the pool
    if AceGUI.objPools[type_name] and #AceGUI.objPools[type_name] > 0 then
        local widget = tremove(AceGUI.objPools[type_name])
        if widget.OnAcquire then
            widget:OnAcquire()
        end
        return widget
    end

    -- Create new
    local widget = AceGUI.WidgetRegistry[type_name]()
    widget.type = type_name
    widget.userdata = {}
    widget.events = {}
    widget.base = WidgetBase

    -- Mix in WidgetBase
    for k, v in pairs(WidgetBase) do
        if not widget[k] then
            widget[k] = v
        end
    end

    -- If it's a container, mix in WidgetContainerBase
    if widget.children ~= nil or type_name == "Window" or type_name == "Frame" or type_name == "SimpleGroup" or type_name == "TabGroup" or type_name == "TreeGroup" or type_name == "ScrollFrame" or type_name == "InlineGroup" or type_name == "DropdownGroup" then
        widget.children = widget.children or {}
        for k, v in pairs(WidgetContainerBase) do
            if not widget[k] then
                widget[k] = v
            end
        end
    end

    if widget.OnAcquire then
        widget:OnAcquire()
    end

    return widget
end

--- Release a widget back to the pool
function AceGUI:Release(widget)
    safecall(widget.Fire, widget, "OnRelease")
    if widget.OnRelease then
        safecall(widget.OnRelease, widget)
    end
    -- Release children if container
    if widget.ReleaseChildren then
        widget:ReleaseChildren()
    end
    widget.events = {}
    widget.userdata = {}

    local type_name = widget.type
    if type_name then
        AceGUI.objPools[type_name] = AceGUI.objPools[type_name] or {}
        tinsert(AceGUI.objPools[type_name], widget)
    end

    widget.frame:ClearAllPoints()
    widget.frame:Hide()
    widget.frame:SetParent(UIParent)
    widget.frame.width = nil
    widget.frame.height = nil
end

--- Set focus on a widget (AceGUI tracks focus)
function AceGUI:SetFocus(widget)
    if AceGUI.FocusedWidget and AceGUI.FocusedWidget ~= widget then
        safecall(AceGUI.FocusedWidget.ClearFocus, AceGUI.FocusedWidget)
    end
    AceGUI.FocusedWidget = widget
end

function AceGUI:ClearFocus()
    if AceGUI.FocusedWidget then
        safecall(AceGUI.FocusedWidget.ClearFocus, AceGUI.FocusedWidget)
    end
    AceGUI.FocusedWidget = nil
end

--- Get the number of registered widget types
function AceGUI:GetWidgetCount()
    local count = 0
    for _ in pairs(AceGUI.WidgetRegistry) do count = count + 1 end
    return count
end

--- Get the number of registered layouts
function AceGUI:GetLayoutCount()
    local count = 0
    for _ in pairs(AceGUI.LayoutRegistry) do count = count + 1 end
    return count
end

----- Built-in Layouts -----

-- List layout: stack widgets vertically
AceGUI:RegisterLayout("List", function(content, children)
    if not children or #children == 0 then return end
    local height = 0
    local width = content:GetWidth() or 0

    for i = 1, #children do
        local child = children[i]
        local frame = child.frame
        frame:ClearAllPoints()

        if child.width == "fill" then
            child:SetWidth(width)
            frame:SetPoint("LEFT", content)
            frame:SetPoint("RIGHT", content)
        elseif child.width == "relative" then
            child:SetWidth(width * (child.relWidth or 1))
        end

        if i == 1 then
            frame:SetPoint("TOPLEFT", content)
        else
            frame:SetPoint("TOPLEFT", children[i-1].frame, "BOTTOMLEFT")
        end

        height = height + (frame:GetHeight() or 0)
    end

    safecall(content.SetHeight, content, height)
end)

-- Flow layout: place widgets left to right, wrapping
AceGUI:RegisterLayout("Flow", function(content, children)
    if not children or #children == 0 then return end
    local width = content:GetWidth() or 0
    local usedWidth = 0
    local height = 0
    local rowHeight = 0
    local rowStart = 1

    for i = 1, #children do
        local child = children[i]
        local frame = child.frame

        frame:ClearAllPoints()

        local frameWidth = frame:GetWidth() or 0
        local frameHeight = frame:GetHeight() or 0

        if child.width == "fill" then
            frameWidth = width
            child:SetWidth(width)
        elseif child.width == "relative" then
            frameWidth = width * (child.relWidth or 1)
            child:SetWidth(frameWidth)
        end

        if usedWidth + frameWidth > width and i > 1 then
            -- Wrap to next row
            usedWidth = 0
            height = height + rowHeight
            rowHeight = 0
        end

        if usedWidth == 0 then
            if height == 0 then
                frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            else
                frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -height)
            end
        else
            frame:SetPoint("TOPLEFT", content, "TOPLEFT", usedWidth, -height)
        end

        usedWidth = usedWidth + frameWidth
        rowHeight = math_max(rowHeight, frameHeight)
    end

    height = height + rowHeight
    safecall(content.SetHeight, content, height)
end)

-- Fill layout: single child fills the container
AceGUI:RegisterLayout("Fill", function(content, children)
    if children and children[1] then
        local child = children[1]
        child.frame:ClearAllPoints()
        child.frame:SetAllPoints(content)
        child.frame:Show()
    end
end)

----- Built-in Widget: Frame (main window container) -----

local function Frame_Constructor()
    local num = AceGUI:GetNextWidgetNum("Frame")
    local frame = CreateFrame("Frame", "AceGUI30Frame" .. num, UIParent, "BackdropTemplate")
    frame:Hide()

    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(100)
    frame:SetSize(700, 500)

    if frame.SetResizeBounds then
        frame:SetResizeBounds(400, 200)
    elseif frame.SetMinResize then
        frame:SetMinResize(400, 200)
    end

    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })

    -- Title bar
    local titlebar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titlebar:SetPoint("TOPLEFT", 10, -10)
    titlebar:SetPoint("TOPRIGHT", -10, -10)
    titlebar:SetHeight(40)
    titlebar:EnableMouse(true)
    titlebar:SetScript("OnMouseDown", function() frame:StartMoving() end)
    titlebar:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    local titletext = titlebar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titletext:SetPoint("TOPLEFT", titlebar, "TOPLEFT", 0, 0)
    titletext:SetPoint("TOPRIGHT", titlebar, "TOPRIGHT", 0, 0)
    titletext:SetHeight(40)

    -- Close button
    local closebutton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closebutton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    -- Status bar
    local statusbg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    statusbg:SetPoint("BOTTOMLEFT", 15, 15)
    statusbg:SetPoint("BOTTOMRIGHT", -15, 15)
    statusbg:SetHeight(24)

    local statustext = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statustext:SetPoint("TOPLEFT", 2, -2)
    statustext:SetPoint("BOTTOMRIGHT", -2, 2)
    statustext:SetJustifyH("LEFT")

    -- Content frame
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 17, -55)
    content:SetPoint("BOTTOMRIGHT", -17, 40)

    -- Resize grip
    local sizer = CreateFrame("Frame", nil, frame)
    sizer:SetPoint("BOTTOMRIGHT")
    sizer:SetSize(25, 25)
    sizer:EnableMouse(true)
    sizer:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    sizer:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    local widget = {
        type = "Frame",
        frame = frame,
        content = content,
        titletext = titletext,
        statustext = statustext,
        children = {},
        localstatus = {},
    }

    function widget:OnAcquire()
        self.frame:SetParent(UIParent)
        self.frame:SetFrameStrata("FULLSCREEN_DIALOG")
        self.frame:Show()
        self:ApplyStatus()
    end

    function widget:OnRelease()
        self.status = nil
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetTitle(title)
        self.titletext:SetText(title)
    end

    function widget:SetStatusText(text)
        self.statustext:SetText(text)
    end

    function widget:Hide()
        self.frame:Hide()
    end

    function widget:Show()
        self.frame:Show()
    end

    function widget:SetStatusTable(status)
        self.status = status
        self:ApplyStatus()
    end

    function widget:ApplyStatus()
        local status = self.status or self.localstatus
        local frame = self.frame
        self:SetWidth(status.width or 700)
        self:SetHeight(status.height or 500)
        frame:ClearAllPoints()
        if status.top and status.left then
            frame:SetPoint("TOP", UIParent, "BOTTOM", 0, status.top)
            frame:SetPoint("LEFT", UIParent, "LEFT", status.left, 0)
        else
            frame:SetPoint("CENTER")
        end
    end

    function widget:OnWidthSet(width)
        local content = self.content
        local contentwidth = width - 34
        if contentwidth < 0 then contentwidth = 0 end
        content:SetWidth(contentwidth)
        content.width = contentwidth
    end

    function widget:OnHeightSet(height)
        local content = self.content
        local contentheight = height - 95
        if contentheight < 0 then contentheight = 0 end
        content:SetHeight(contentheight)
        content.height = contentheight
    end

    closebutton:SetScript("OnClick", function()
        widget:Fire("OnClose")
        AceGUI:Release(widget)
    end)

    return widget
end

AceGUI.WidgetRegistry["Frame"] = Frame_Constructor

-- Widget counter
AceGUI.counts = AceGUI.counts or {}
function AceGUI:GetNextWidgetNum(type)
    AceGUI.counts[type] = (AceGUI.counts[type] or 0) + 1
    return AceGUI.counts[type]
end

----- Built-in Widgets: basic set needed by AceConfigDialog -----

-- Label widget
local function Label_Constructor()
    local num = AceGUI:GetNextWidgetNum("Label")
    local frame = CreateFrame("Frame", "AceGUI30Label" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 18)

    local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
    label:SetAllPoints()
    label:SetJustifyH("LEFT")
    label:SetJustifyV("MIDDLE")

    local widget = {
        type = "Label",
        frame = frame,
        label = label,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetText("")
        self:SetColor()
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text)
        self.label:SetText(text)
    end

    function widget:SetColor(r, g, b)
        if r and g and b then
            self.label:SetTextColor(r, g, b)
        else
            self.label:SetTextColor(1, 1, 1)
        end
    end

    function widget:SetFont(font, height, flags)
        self.label:SetFont(font, height, flags)
    end

    function widget:SetFontObject(fontObj)
        self.label:SetFontObject(fontObj)
    end

    function widget:SetImage(path, ...)
        -- Simplified: no image support in label stub
    end

    function widget:SetImageSize(width, height)
    end

    return widget
end
AceGUI:RegisterWidgetType("Label", Label_Constructor, 27)

-- Heading widget
local function Heading_Constructor()
    local num = AceGUI:GetNextWidgetNum("Heading")
    local frame = CreateFrame("Frame", "AceGUI30Heading" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 18)

    local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
    label:SetPoint("TOP")
    label:SetPoint("BOTTOM")
    label:SetJustifyH("CENTER")

    local left = frame:CreateTexture(nil, "BACKGROUND")
    left:SetHeight(8)
    left:SetPoint("LEFT", 3, 0)
    left:SetPoint("RIGHT", label, "LEFT", -5, 0)
    left:SetTexture(137057) -- "Interface\\Tooltips\\UI-Tooltip-Border"

    local right = frame:CreateTexture(nil, "BACKGROUND")
    right:SetHeight(8)
    right:SetPoint("RIGHT", -3, 0)
    right:SetPoint("LEFT", label, "RIGHT", 5, 0)
    right:SetTexture(137057) -- "Interface\\Tooltips\\UI-Tooltip-Border"

    local widget = {
        type = "Heading",
        frame = frame,
        label = label,
    }

    function widget:OnAcquire()
        self:SetFullWidth()
        self:SetText("")
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text)
        self.label:SetText(text or "")
        if (text or "") == "" then
            left:SetPoint("RIGHT", frame, "RIGHT", -3, 0)
            right:Hide()
        else
            left:SetPoint("RIGHT", label, "LEFT", -5, 0)
            right:Show()
        end
    end

    return widget
end
AceGUI:RegisterWidgetType("Heading", Heading_Constructor, 12)

-- Button widget
local function Button_Constructor()
    local num = AceGUI:GetNextWidgetNum("Button")
    local frame = CreateFrame("Button", "AceGUI30Button" .. num, UIParent, "UIPanelButtonTemplate")
    frame:Hide()
    frame:SetSize(200, 24)
    frame:EnableMouse(true)

    local widget = {
        type = "Button",
        frame = frame,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetText("")
        self:SetDisabled(false)
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text)
        self.frame:SetText(text)
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
        if disabled then
            self.frame:Disable()
        else
            self.frame:Enable()
        end
    end

    frame:SetScript("OnClick", function()
        widget:Fire("OnClick")
    end)

    return widget
end
AceGUI:RegisterWidgetType("Button", Button_Constructor, 16)

-- CheckBox widget
local function CheckBox_Constructor()
    local num = AceGUI:GetNextWidgetNum("CheckBox")
    local frame = CreateFrame("CheckButton", "AceGUI30CheckBox" .. num, UIParent, "UICheckButtonTemplate")
    frame:Hide()
    frame:SetSize(24, 24)

    local text = _G[frame:GetName() .. "Text"]
    if text then
        text:SetFontObject(GameFontHighlight)
    end

    local widget = {
        type = "CheckBox",
        frame = frame,
        text = text,
        checked = false,
    }

    function widget:OnAcquire()
        self:SetValue(false)
        self:SetLabel("")
        self:SetDisabled(false)
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetValue(value)
        self.checked = value
        self.frame:SetChecked(value)
    end

    function widget:GetValue()
        return self.checked
    end

    function widget:SetLabel(label_text)
        if text then
            text:SetText(label_text)
        end
    end

    function widget:SetDescription(desc)
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
        if disabled then
            self.frame:Disable()
        else
            self.frame:Enable()
        end
    end

    function widget:SetTriState(enabled)
        self.tristate = enabled
    end

    function widget:SetType(type)
    end

    function widget:SetImage(...)
    end

    frame:SetScript("OnClick", function()
        if widget.tristate then
            if widget.checked == nil then
                widget:SetValue(true)
            elseif widget.checked then
                widget:SetValue(false)
            else
                widget:SetValue(nil)
            end
        else
            widget:SetValue(not widget.checked)
        end
        widget:Fire("OnValueChanged", widget.checked)
    end)

    return widget
end
AceGUI:RegisterWidgetType("CheckBox", CheckBox_Constructor, 26)

-- EditBox widget
local function EditBox_Constructor()
    local num = AceGUI:GetNextWidgetNum("EditBox")
    local frame = CreateFrame("Frame", "AceGUI30EditBox" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 44)

    local editbox = CreateFrame("EditBox", "AceGUI30EditBoxInput" .. num, frame, "InputBoxTemplate")
    editbox:SetAutoFocus(false)
    editbox:SetFontObject(ChatFontNormal)
    editbox:SetPoint("BOTTOMLEFT", 6, 0)
    editbox:SetPoint("BOTTOMRIGHT")
    editbox:SetHeight(19)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
    label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
    label:SetJustifyH("LEFT")
    label:SetHeight(18)

    local widget = {
        type = "EditBox",
        frame = frame,
        editbox = editbox,
        label = label,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetDisabled(false)
        self:SetLabel("")
        self:SetText("")
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text)
        self.editbox:SetText(text or "")
    end

    function widget:GetText()
        return self.editbox:GetText()
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
        if disabled then
            self.editbox:EnableMouse(false)
            self.editbox:ClearFocus()
        else
            self.editbox:EnableMouse(true)
        end
    end

    function widget:SetMaxLetters(num)
        self.editbox:SetMaxLetters(num or 0)
    end

    function widget:ClearFocus()
        self.editbox:ClearFocus()
    end

    function widget:SetFocus()
        self.editbox:SetFocus()
    end

    editbox:SetScript("OnEnterPressed", function()
        local value = editbox:GetText()
        widget:Fire("OnEnterPressed", value)
        editbox:ClearFocus()
    end)

    editbox:SetScript("OnEscapePressed", function()
        editbox:ClearFocus()
    end)

    editbox:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            widget:Fire("OnTextChanged", editbox:GetText())
        end
    end)

    return widget
end
AceGUI:RegisterWidgetType("EditBox", EditBox_Constructor, 28)

-- Dropdown widget
local function Dropdown_Constructor()
    local num = AceGUI:GetNextWidgetNum("Dropdown")
    local frame = CreateFrame("Frame", "AceGUI30DropDown" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 44)

    local dropdown = CreateFrame("Frame", "AceGUI30DropDownMenu" .. num, frame, "UIDropDownMenuTemplate")
    dropdown:ClearAllPoints()
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", -13, 0)
    dropdown:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    label:SetJustifyH("LEFT")
    label:SetHeight(18)

    local widget = {
        type = "Dropdown",
        frame = frame,
        dropdown = dropdown,
        label = label,
        list = {},
        value = nil,
        multiselect = false,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetLabel("")
        self:SetList({})
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
        self.list = {}
        self.value = nil
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetValue(value)
        self.value = value
        -- Update displayed text
        if self.list and self.list[value] then
            UIDropDownMenu_SetText(dropdown, self.list[value])
        end
    end

    function widget:GetValue()
        return self.value
    end

    function widget:SetList(list, order)
        self.list = list or {}
        self.order = order
    end

    function widget:AddItem(key, value)
        self.list[key] = value
    end

    function widget:SetMultiselect(multi)
        self.multiselect = multi
    end

    function widget:GetMultiselect()
        return self.multiselect
    end

    function widget:SetItemValue(key, value)
        -- For multiselect
        if not self.values then self.values = {} end
        self.values[key] = value
    end

    function widget:SetItemDisabled(key, disabled)
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
    end

    function widget:SetText(text)
        UIDropDownMenu_SetText(dropdown, text)
    end

    UIDropDownMenu_Initialize(dropdown, function(frame, level, menuList)
        local info = UIDropDownMenu_CreateInfo()
        local order = widget.order or {}
        if #order == 0 then
            for k in pairs(widget.list) do
                tinsert(order, k)
            end
        end
        for _, key in pairs(order) do
            info.text = widget.list[key]
            info.value = key
            info.func = function(self)
                widget:SetValue(self.value)
                widget:Fire("OnValueChanged", self.value)
            end
            if widget.multiselect then
                info.checked = widget.values and widget.values[key]
                info.isNotRadio = true
                info.keepShownOnClick = true
            else
                info.checked = (widget.value == key)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    return widget
end
AceGUI:RegisterWidgetType("Dropdown", Dropdown_Constructor, 35)

-- Slider widget
local function Slider_Constructor()
    local num = AceGUI:GetNextWidgetNum("Slider")
    local frame = CreateFrame("Frame", "AceGUI30Slider" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 44)

    local slider = CreateFrame("Slider", "AceGUI30SliderBar" .. num, frame, "OptionsSliderTemplate")
    slider:SetPoint("TOP", frame, "TOP", 0, -14)
    slider:SetPoint("LEFT", frame, "LEFT", 3, 0)
    slider:SetPoint("RIGHT", frame, "RIGHT", -3, 0)
    slider:SetMinMaxValues(0, 100)
    slider:SetValue(0)
    slider:SetValueStep(1)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT")
    label:SetPoint("TOPRIGHT")
    label:SetJustifyH("CENTER")
    label:SetHeight(15)

    local lowtext = _G[slider:GetName() .. "Low"]
    local hightext = _G[slider:GetName() .. "High"]
    local valuetext = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valuetext:SetPoint("TOP", slider, "BOTTOM")

    local widget = {
        type = "Slider",
        frame = frame,
        slider = slider,
        label = label,
        lowtext = lowtext,
        hightext = hightext,
        valuetext = valuetext,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetDisabled(false)
        self:SetIsPercent(false)
        self:SetSliderValues(0, 100, 1)
        self:SetValue(0)
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetValue(value)
        self.slider:SetValue(value)
        self:UpdateText(value)
    end

    function widget:GetValue()
        return self.slider:GetValue()
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetSliderValues(min, max, step)
        self.slider:SetMinMaxValues(min or 0, max or 100)
        self.slider:SetValueStep(step or 1)
        if self.lowtext then self.lowtext:SetText(tostring(min or 0)) end
        if self.hightext then self.hightext:SetText(tostring(max or 100)) end
    end

    function widget:SetIsPercent(isPercent)
        self.isPercent = isPercent
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
        if disabled then
            self.slider:EnableMouse(false)
        else
            self.slider:EnableMouse(true)
        end
    end

    function widget:UpdateText(value)
        if self.isPercent then
            self.valuetext:SetText(format("%d%%", (value or 0) * 100))
        else
            self.valuetext:SetText(tostring(value or 0))
        end
    end

    slider:SetScript("OnValueChanged", function(_, value)
        widget:UpdateText(value)
        widget:Fire("OnValueChanged", value)
    end)

    return widget
end
AceGUI:RegisterWidgetType("Slider", Slider_Constructor, 13)

-- MultiLineEditBox widget
local function MultiLineEditBox_Constructor()
    local num = AceGUI:GetNextWidgetNum("MultiLineEditBox")
    local frame = CreateFrame("Frame", "AceGUI30MultiLineEditBox" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 116)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT")
    label:SetPoint("TOPRIGHT")
    label:SetJustifyH("LEFT")
    label:SetHeight(18)

    local scrollBG = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    scrollBG:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 3, right = 3, top = 5, bottom = 3 }
    })
    scrollBG:SetBackdropColor(0, 0, 0, 0.5)
    scrollBG:SetBackdropBorderColor(0.4, 0.4, 0.4)
    scrollBG:SetPoint("TOPLEFT", 0, -20)
    scrollBG:SetPoint("BOTTOMRIGHT", 0, 22)

    local scrollFrame = CreateFrame("ScrollFrame", "AceGUI30MultiLineEditBoxScroll" .. num, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", scrollBG, "TOPLEFT", 5, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", scrollBG, "BOTTOMRIGHT", -4, 4)

    local editbox = CreateFrame("EditBox", "AceGUI30MultiLineEditBoxEdit" .. num, scrollFrame)
    editbox:SetAllPoints()
    editbox:SetFontObject(ChatFontNormal)
    editbox:SetMultiLine(true)
    editbox:SetAutoFocus(false)
    editbox:SetScript("OnCursorChanged", function(self, _, y, _, cursorHeight) end)
    editbox:SetScript("OnEscapePressed", function() editbox:ClearFocus() end)
    scrollFrame:SetScrollChild(editbox)

    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetPoint("BOTTOMLEFT")
    button:SetSize(80, 20)
    button:SetText(ACCEPT)

    local widget = {
        type = "MultiLineEditBox",
        frame = frame,
        editbox = editbox,
        scrollFrame = scrollFrame,
        label = label,
        button = button,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetHeight(116)
        self:SetDisabled(false)
        self:SetLabel("")
        self:SetText("")
        self:SetNumLines(4)
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text)
        self.editbox:SetText(text or "")
    end

    function widget:GetText()
        return self.editbox:GetText()
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
    end

    function widget:SetNumLines(num)
        -- Approximate height
    end

    function widget:SetMaxLetters(max)
        self.editbox:SetMaxLetters(max or 0)
    end

    function widget:ClearFocus()
        self.editbox:ClearFocus()
    end

    button:SetScript("OnClick", function()
        widget:Fire("OnEnterPressed", editbox:GetText())
    end)

    return widget
end
AceGUI:RegisterWidgetType("MultiLineEditBox", MultiLineEditBox_Constructor, 28)

-- ColorPicker widget
local function ColorPicker_Constructor()
    local num = AceGUI:GetNextWidgetNum("ColorPicker")
    local frame = CreateFrame("Button", "AceGUI30ColorPicker" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 24)
    frame:EnableMouse(true)

    local colorSwatch = frame:CreateTexture(nil, "OVERLAY")
    colorSwatch:SetSize(19, 19)
    colorSwatch:SetPoint("LEFT")
    colorSwatch:SetTexture(130939)

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", colorSwatch, "RIGHT", 5, 0)
    text:SetJustifyH("LEFT")

    local widget = {
        type = "ColorPicker",
        frame = frame,
        colorSwatch = colorSwatch,
        text = text,
        r = 1, g = 1, b = 1, a = 1,
    }

    function widget:OnAcquire()
        self.frame:Show()
        self:SetColor(1, 1, 1, 1)
        self:SetLabel("")
        self:SetHasAlpha(false)
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetColor(r, g, b, a)
        self.r, self.g, self.b, self.a = r, g, b, a
        self.colorSwatch:SetVertexColor(r, g, b, a or 1)
    end

    function widget:SetLabel(text)
        self.text:SetText(text or "")
    end

    function widget:SetHasAlpha(hasAlpha)
        self.hasAlpha = hasAlpha
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
    end

    frame:SetScript("OnClick", function()
        if widget.disabled then return end
        -- Open the color picker
        local info = {}
        info.r = widget.r
        info.g = widget.g
        info.b = widget.b
        info.opacity = widget.a
        info.hasOpacity = widget.hasAlpha
        info.swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            local a = widget.hasAlpha and (1 - OpacitySliderFrame:GetValue()) or 1
            widget:SetColor(r, g, b, a)
            widget:Fire("OnValueChanged", r, g, b, a)
        end
        info.cancelFunc = function(prev)
            widget:SetColor(prev.r, prev.g, prev.b, prev.opacity)
            widget:Fire("OnValueChanged", prev.r, prev.g, prev.b, prev.opacity)
        end
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    return widget
end
AceGUI:RegisterWidgetType("ColorPicker", ColorPicker_Constructor, 25)

-- Keybinding widget
local function Keybinding_Constructor()
    local num = AceGUI:GetNextWidgetNum("Keybinding")
    local frame = CreateFrame("Button", "AceGUI30Keybinding" .. num, UIParent, "UIPanelButtonTemplate")
    frame:Hide()
    frame:SetSize(200, 24)
    frame:EnableMouse(true)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
    label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -2)
    label:SetJustifyH("CENTER")
    label:SetHeight(18)

    local widget = {
        type = "Keybinding",
        frame = frame,
        label = label,
        waitingForKey = false,
    }

    function widget:OnAcquire()
        self.frame:Show()
        self:SetLabel("")
        self:SetKey("")
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetKey(key)
        self.key = key
        self.frame:SetText(key or "")
    end

    function widget:GetKey()
        return self.key
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
    end

    return widget
end
AceGUI:RegisterWidgetType("Keybinding", Keybinding_Constructor, 15)

-- SimpleGroup widget
local function SimpleGroup_Constructor()
    local num = AceGUI:GetNextWidgetNum("SimpleGroup")
    local frame = CreateFrame("Frame", "AceGUI30SimpleGroup" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 100)

    local content = CreateFrame("Frame", nil, frame)
    content:SetAllPoints()

    local widget = {
        type = "SimpleGroup",
        frame = frame,
        content = content,
        children = {},
    }

    function widget:OnAcquire()
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:OnWidthSet(width)
        self.content:SetWidth(width)
        self.content.width = width
    end

    function widget:OnHeightSet(height)
        self.content:SetHeight(height)
        self.content.height = height
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    return widget
end
AceGUI:RegisterWidgetType("SimpleGroup", SimpleGroup_Constructor, 20)

-- InlineGroup widget (group with border and title)
local function InlineGroup_Constructor()
    local num = AceGUI:GetNextWidgetNum("InlineGroup")
    local frame = CreateFrame("Frame", "AceGUI30InlineGroup" .. num, UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetSize(300, 100)

    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 3, right = 3, top = 5, bottom = 3 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local titletext = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titletext:SetPoint("TOPLEFT", 14, 0)
    titletext:SetPoint("TOPRIGHT", -14, 0)
    titletext:SetJustifyH("LEFT")
    titletext:SetHeight(18)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 10, -10)
    content:SetPoint("BOTTOMRIGHT", -10, 10)

    local widget = {
        type = "InlineGroup",
        frame = frame,
        content = content,
        titletext = titletext,
        children = {},
    }

    function widget:OnAcquire()
        self:SetTitle("")
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetTitle(title)
        self.titletext:SetText(title or "")
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:OnWidthSet(width)
        self.content:SetWidth(width - 20)
        self.content.width = width - 20
    end

    function widget:OnHeightSet(height)
        self.content:SetHeight(height - 20)
        self.content.height = height - 20
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    return widget
end
AceGUI:RegisterWidgetType("InlineGroup", InlineGroup_Constructor, 22)

-- ScrollFrame widget (scrollable container)
local function ScrollFrame_Constructor()
    local num = AceGUI:GetNextWidgetNum("ScrollFrame")
    local frame = CreateFrame("Frame", "AceGUI30ScrollFrame" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 100)

    local scrollFrame = CreateFrame("ScrollFrame", "AceGUI30Scroll" .. num, frame)
    scrollFrame:SetPoint("TOPLEFT")
    scrollFrame:SetPoint("BOTTOMRIGHT", -16, 0)
    scrollFrame:EnableMouseWheel(true)

    local scrollBar = CreateFrame("Slider", "AceGUI30ScrollBar" .. num, frame)
    scrollBar:SetPoint("TOPRIGHT")
    scrollBar:SetPoint("BOTTOMRIGHT")
    scrollBar:SetWidth(16)
    scrollBar:SetMinMaxValues(0, 100)
    scrollBar:SetValue(0)
    scrollBar:SetValueStep(1)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetPoint("TOPLEFT")
    content:SetSize(scrollFrame:GetWidth(), 400)
    scrollFrame:SetScrollChild(content)

    local widget = {
        type = "ScrollFrame",
        frame = frame,
        scrollFrame = scrollFrame,
        scrollBar = scrollBar,
        content = content,
        children = {},
    }

    function widget:OnAcquire()
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:SetScroll(value)
        scrollBar:SetValue(value)
    end

    function widget:OnWidthSet(width)
        content:SetWidth(width - 16)
        content.width = width - 16
    end

    function widget:OnHeightSet(height)
        content:SetHeight(height)
        content.height = height
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = scrollBar:GetValue()
        scrollBar:SetValue(current - delta * 20)
    end)

    scrollBar:SetScript("OnValueChanged", function(self, value)
        scrollFrame:SetVerticalScroll(value)
    end)

    return widget
end
AceGUI:RegisterWidgetType("ScrollFrame", ScrollFrame_Constructor, 24)

-- TabGroup widget
local function TabGroup_Constructor()
    local num = AceGUI:GetNextWidgetNum("TabGroup")
    local frame = CreateFrame("Frame", "AceGUI30TabGroup" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 100)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 0, -30)
    content:SetPoint("BOTTOMRIGHT")

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT")
    tabHolder:SetPoint("TOPRIGHT")
    tabHolder:SetHeight(30)

    local widget = {
        type = "TabGroup",
        frame = frame,
        content = content,
        tabHolder = tabHolder,
        tabs = {},
        tabButtons = {},
        children = {},
        selectedTab = nil,
    }

    function widget:OnAcquire()
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetTabs(tabs)
        self.tabs = tabs or {}
        -- Create tab buttons
        for _, btn in pairs(self.tabButtons) do
            btn:Hide()
        end
        self.tabButtons = {}

        local xOffset = 0
        for i, tab in pairs(self.tabs) do
            local btn = CreateFrame("Button", nil, self.tabHolder, "UIPanelButtonTemplate")
            btn:SetSize(100, 25)
            btn:SetPoint("BOTTOMLEFT", xOffset, 0)
            btn:SetText(tab.text)
            btn.value = tab.value
            btn:SetScript("OnClick", function()
                widget:SelectTab(tab.value)
                widget:Fire("OnGroupSelected", tab.value)
            end)
            self.tabButtons[i] = btn
            xOffset = xOffset + 102
        end
    end

    function widget:SelectTab(value)
        self.selectedTab = value
        for _, btn in pairs(self.tabButtons) do
            if btn.value == value then
                btn:LockHighlight()
            else
                btn:UnlockHighlight()
            end
        end
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:OnWidthSet(width)
        self.content:SetWidth(width)
        self.content.width = width
    end

    function widget:OnHeightSet(height)
        self.content:SetHeight(height - 30)
        self.content.height = height - 30
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    return widget
end
AceGUI:RegisterWidgetType("TabGroup", TabGroup_Constructor, 36)

-- TreeGroup widget (tree view container)
local function TreeGroup_Constructor()
    local num = AceGUI:GetNextWidgetNum("TreeGroup")
    local frame = CreateFrame("Frame", "AceGUI30TreeGroup" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 100)

    local treeFrame = CreateFrame("Frame", nil, frame)
    treeFrame:SetPoint("TOPLEFT")
    treeFrame:SetPoint("BOTTOMLEFT")
    treeFrame:SetWidth(175)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", treeFrame, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT")

    local widget = {
        type = "TreeGroup",
        frame = frame,
        treeFrame = treeFrame,
        content = content,
        children = {},
        tree = {},
        selectedValue = nil,
    }

    function widget:OnAcquire()
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetTree(tree)
        self.tree = tree or {}
        -- Would normally render tree buttons here
    end

    function widget:SelectByValue(value)
        self.selectedValue = value
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:OnWidthSet(width)
        self.content:SetWidth(width - 176)
        self.content.width = width - 176
    end

    function widget:OnHeightSet(height)
        self.content:SetHeight(height)
        self.content.height = height
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    function widget:SetTreeWidth(width, resizable)
        self.treeFrame:SetWidth(width)
    end

    return widget
end
AceGUI:RegisterWidgetType("TreeGroup", TreeGroup_Constructor, 40)

-- DropdownGroup widget
local function DropdownGroup_Constructor()
    local num = AceGUI:GetNextWidgetNum("DropdownGroup")
    local frame = CreateFrame("Frame", "AceGUI30DropdownGroup" .. num, UIParent)
    frame:Hide()
    frame:SetSize(300, 100)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", 0, -40)
    content:SetPoint("BOTTOMRIGHT")

    local dropdown = AceGUI:Create("Dropdown")
    dropdown.frame:SetParent(frame)
    dropdown.frame:SetPoint("TOPLEFT", 0, 0)
    dropdown:SetWidth(200)
    dropdown.frame:Show()

    local widget = {
        type = "DropdownGroup",
        frame = frame,
        content = content,
        dropdown = dropdown,
        children = {},
    }

    function widget:OnAcquire()
        self.frame:Show()
    end

    function widget:OnRelease()
        self:ReleaseChildren()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetGroupList(list, order)
        self.dropdown:SetList(list, order)
    end

    function widget:SetGroup(group)
        self.dropdown:SetValue(group)
    end

    function widget:SetLayout(layout)
        self.layout = layout
    end

    function widget:OnWidthSet(width)
        self.content:SetWidth(width)
        self.content.width = width
    end

    function widget:OnHeightSet(height)
        self.content:SetHeight(height - 40)
        self.content.height = height - 40
    end

    function widget:SetParent(parent)
        self.frame:SetParent(parent.content or parent.frame)
    end

    dropdown:SetCallback("OnValueChanged", function(_, _, value)
        widget:Fire("OnGroupSelected", value)
    end)

    return widget
end
AceGUI:RegisterWidgetType("DropdownGroup", DropdownGroup_Constructor, 22)

-- Icon widget
local function Icon_Constructor()
    local num = AceGUI:GetNextWidgetNum("Icon")
    local frame = CreateFrame("Button", "AceGUI30Icon" .. num, UIParent)
    frame:Hide()
    frame:SetSize(64, 64)

    local image = frame:CreateTexture(nil, "BACKGROUND")
    image:SetSize(64, 64)
    image:SetPoint("TOP")

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("BOTTOM")
    label:SetJustifyH("CENTER")

    local widget = {
        type = "Icon",
        frame = frame,
        image = image,
        label = label,
    }

    function widget:OnAcquire()
        self.frame:Show()
        self:SetImage(nil)
        self:SetLabel("")
        self:SetImageSize(64, 64)
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetImage(path, ...)
        if path then
            self.image:SetTexture(path)
            self.image:Show()
        else
            self.image:Hide()
        end
    end

    function widget:SetImageSize(width, height)
        self.image:SetSize(width, height)
    end

    function widget:SetLabel(text)
        self.label:SetText(text or "")
    end

    function widget:SetDisabled(disabled)
        self.disabled = disabled
    end

    frame:SetScript("OnClick", function()
        if not widget.disabled then
            widget:Fire("OnClick")
        end
    end)

    return widget
end
AceGUI:RegisterWidgetType("Icon", Icon_Constructor, 21)

-- InteractiveLabel widget
local function InteractiveLabel_Constructor()
    local num = AceGUI:GetNextWidgetNum("InteractiveLabel")
    local frame = CreateFrame("Frame", "AceGUI30InteractiveLabel" .. num, UIParent)
    frame:Hide()
    frame:SetSize(200, 18)
    frame:EnableMouse(true)

    local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
    label:SetAllPoints()
    label:SetJustifyH("LEFT")

    local widget = {
        type = "InteractiveLabel",
        frame = frame,
        label = label,
    }

    function widget:OnAcquire()
        self:SetWidth(200)
        self:SetText("")
        self.frame:Show()
    end

    function widget:OnRelease()
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end

    function widget:SetText(text) self.label:SetText(text) end
    function widget:SetColor(r, g, b) self.label:SetTextColor(r or 1, g or 1, b or 1) end
    function widget:SetFont(font, height, flags) self.label:SetFont(font, height, flags) end
    function widget:SetFontObject(fontObj) self.label:SetFontObject(fontObj) end
    function widget:SetHighlight(...) end
    function widget:SetHighlightTexCoord(...) end
    function widget:SetImage(path, ...) end
    function widget:SetImageSize(w, h) end
    function widget:SetDisabled(disabled) self.disabled = disabled end

    frame:SetScript("OnMouseUp", function()
        if not widget.disabled then
            widget:Fire("OnClick")
        end
    end)

    return widget
end
AceGUI:RegisterWidgetType("InteractiveLabel", InteractiveLabel_Constructor, 22)
