--- LibDBIcon-1.0
--- Minimap icon management library using LibDataBroker-1.1 data objects.
--- @class file
--- @name LibDBIcon-1.0

local MAJOR, MINOR = "LibDBIcon-1.0", 46
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local ldb = LibStub("LibDataBroker-1.1")
local CallbackHandler = LibStub("CallbackHandler-1.0")

lib.objects = lib.objects or {}
lib.callbackRegistered = lib.callbackRegistered or {}
lib.callbacks = lib.callbacks or CallbackHandler:New(lib)
lib.notCreated = lib.notCreated or {}
lib.tooltip = lib.tooltip or GameTooltip

local minimapShapes = {
    ["ROUND"] = {true, true, true, true},
    ["SQUARE"] = {false, false, false, false},
    ["CORNER-TOPLEFT"] = {false, false, false, true},
    ["CORNER-TOPRIGHT"] = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"] = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"] = {true, false, false, false},
    ["SIDE-LEFT"] = {false, true, false, true},
    ["SIDE-RIGHT"] = {true, false, true, false},
    ["SIDE-TOP"] = {false, false, true, true},
    ["SIDE-BOTTOM"] = {true, true, false, false},
    ["TRICORNER-TOPLEFT"] = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"] = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"] = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function getMinimapShape()
    return GetMinimapShape and GetMinimapShape() or "ROUND"
end

-- Update the position of a minimap button based on its angle
local function updatePosition(button, db)
    local angle = math.rad(db and db.minimapPos or 225)
    local x, y

    local minimapShape = getMinimapShape()
    local round = minimapShapes[minimapShape]
    if not round then round = minimapShapes["ROUND"] end

    -- Determine the quadrant
    local cos = math.cos(angle)
    local sin = math.sin(angle)

    local q
    if cos > 0 then
        q = sin > 0 and 1 or 4
    else
        q = sin > 0 and 2 or 3
    end

    local minimapRadius = 80
    if round[q] then
        x = cos * minimapRadius
        y = sin * minimapRadius
    else
        -- Square minimap: use different radius calculation
        local diagRadius = math.sqrt(2) * minimapRadius
        x = math.max(-minimapRadius, math.min(cos * diagRadius, minimapRadius))
        y = math.max(-minimapRadius, math.min(sin * diagRadius, minimapRadius))
    end

    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Create the actual minimap button frame
local function createButton(name, obj, db)
    local button = CreateFrame("Button", "LibDBIcon10_" .. name, Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetSize(31, 31)
    button:SetFrameLevel(8)
    button:RegisterForClicks("anyUp")
    button:SetHighlightTexture(136477) -- Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture(136430) -- Interface\\Minimap\\MiniMap-TrackingBorder
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture(136467) -- Interface\\Minimap\\UI-Minimap-Background
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    -- Set the icon texture
    if obj.icon then
        if type(obj.icon) == "string" or type(obj.icon) == "number" then
            icon:SetTexture(obj.icon)
        end
    end

    -- Set up icon coord cropping if specified
    if obj.iconCoords then
        icon:SetTexCoord(unpack(obj.iconCoords))
    else
        icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    end

    -- Dragging support
    button.isMouseDown = false
    button.isDragging = false

    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")

    button:SetScript("OnDragStart", function(self)
        if db and db.lock then return end
        self.isDragging = true
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.atan2(cy - my, cx - mx)
            local degrees = math.deg(angle) % 360
            if db then db.minimapPos = degrees end
            updatePosition(self, db)
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnClick", function(self, b)
        if obj.OnClick then
            obj.OnClick(self, b)
        end
    end)

    button:SetScript("OnEnter", function(self)
        if obj.OnTooltipShow then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            obj.OnTooltipShow(GameTooltip)
            GameTooltip:Show()
        elseif obj.OnEnter then
            obj.OnEnter(self)
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if obj.OnLeave then
            obj.OnLeave(self)
        end
    end)

    button:SetScript("OnMouseDown", function(self)
        self.isMouseDown = true
        icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end)

    button:SetScript("OnMouseUp", function(self)
        self.isMouseDown = false
        if obj.iconCoords then
            icon:SetTexCoord(unpack(obj.iconCoords))
        else
            icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        end
    end)

    lib.objects[name] = button
    button.dataObject = obj
    button.db = db

    -- Position the button
    updatePosition(button, db)

    -- Apply saved visibility
    if db and db.hide then
        button:Hide()
    else
        button:Show()
    end

    -- Watch for attribute changes on the data object
    if not lib.callbackRegistered[name] then
        ldb.callbacks:RegisterCallback(lib, "LibDataBroker_AttributeChanged_" .. name, function(_, _, key, value)
            if key == "icon" then
                icon:SetTexture(value)
            elseif key == "iconCoords" then
                icon:SetTexCoord(unpack(value))
            end
        end)
        lib.callbackRegistered[name] = true
    end

    lib.callbacks:Fire("LibDBIcon_IconCreated", button, name)
    return button
end

--- Register a minimap icon for a data object.
-- @param name A unique name for this icon registration
-- @param obj The LibDataBroker data object
-- @param db (optional) A saved variables table for position/visibility persistence.
--   Expected keys: minimapPos (number, degrees), lock (boolean), hide (boolean)
function lib:Register(name, obj, db)
    if not name or not obj then
        error("Usage: LibDBIcon:Register(name, dataObject, db)", 2)
    end
    if lib.objects[name] then return end -- Already registered

    -- Initialize default db values
    if db then
        if db.minimapPos == nil then db.minimapPos = 225 end
        if db.hide == nil then db.hide = false end
        if db.lock == nil then db.lock = false end
    else
        db = { minimapPos = 225, hide = false, lock = false }
    end

    createButton(name, obj, db)
end

--- Show a registered minimap icon.
-- @param name The registered icon name
function lib:Show(name)
    if lib.objects[name] then
        lib.objects[name]:Show()
        lib.objects[name]:SetAlpha(1)
        if lib.objects[name].db then
            lib.objects[name].db.hide = false
        end
    end
end

--- Hide a registered minimap icon.
-- @param name The registered icon name
function lib:Hide(name)
    if lib.objects[name] then
        lib.objects[name]:Hide()
        if lib.objects[name].db then
            lib.objects[name].db.hide = true
        end
    end
end

--- Check if a name is registered.
-- @param name The icon name to check
-- @return true if registered, false otherwise
function lib:IsRegistered(name)
    return lib.objects[name] ~= nil
end

--- Refresh the icon and position of a registered icon.
-- @param name The registered icon name
-- @param db (optional) The new db table to use
function lib:Refresh(name, db)
    local button = lib.objects[name]
    if not button then return end
    if db then button.db = db end
    local obj = button.dataObject
    if obj and obj.icon then
        button.icon:SetTexture(obj.icon)
    end
    updatePosition(button, button.db)
    if button.db and button.db.hide then
        button:Hide()
    else
        button:Show()
    end
end

--- Get the minimap button frame for a registered icon.
-- @param name The registered icon name
-- @return The button frame, or nil
function lib:GetMinimapButton(name)
    return lib.objects[name]
end

--- Lock/unlock the icon position.
-- @param name The registered icon name
-- @param lock Boolean, true to lock
function lib:Lock(name)
    if lib.objects[name] and lib.objects[name].db then
        lib.objects[name].db.lock = true
    end
end

function lib:Unlock(name)
    if lib.objects[name] and lib.objects[name].db then
        lib.objects[name].db.lock = false
    end
end

--- Get all registered icon names.
-- @return An iterator over (name, button) pairs
function lib:GetButtonList()
    local t = {}
    for name in pairs(lib.objects) do
        t[#t + 1] = name
    end
    return t
end

--- Set the icon's minimap position in degrees.
-- @param name The registered icon name
-- @param degrees The angle in degrees (0-360)
function lib:SetButtonToPosition(name, degrees)
    local button = lib.objects[name]
    if not button then return end
    if button.db then
        button.db.minimapPos = degrees
    end
    updatePosition(button, button.db)
end

-- Auto-register any data objects created after LibDBIcon loads
ldb.callbacks:RegisterCallback(lib, "LibDataBroker_DataObjectCreated", function(_, _, name, obj)
    if lib.notCreated[name] then
        local db = lib.notCreated[name]
        lib.notCreated[name] = nil
        lib:Register(name, obj, db)
    end
end)
