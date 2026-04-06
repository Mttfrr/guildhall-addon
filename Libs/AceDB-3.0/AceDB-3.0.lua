--- AceDB-3.0 manages the SavedVariables for addons.
-- @class file
-- @name AceDB-3.0
local MAJOR, MINOR = "AceDB-3.0", 27
local AceDB = LibStub:NewLibrary(MAJOR, MINOR)

if not AceDB then return end

-- Lua APIs
local type, pairs, next, error = type, pairs, next, error
local setmetatable, rawset, rawget = setmetatable, rawset, rawget
local tinsert = table.insert

local CallbackHandler = LibStub("CallbackHandler-1.0")

AceDB.db_registry = AceDB.db_registry or {}
AceDB.frame = AceDB.frame or CreateFrame("Frame")

-- Database default keys
local DB_KEYS = {
    "global", "profile", "profiles", "char", "realm", "class", "race", "faction", "factionrealm",
}

-- Copies default values into the destination table
local function copyDefaults(dest, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if not rawget(dest, k) then rawset(dest, k, {}) end
            if type(dest[k]) == "table" then
                copyDefaults(dest[k], v)
            end
        else
            if rawget(dest, k) == nil then
                rawset(dest, k, v)
            end
        end
    end
end

-- Removes defaults from a table (for clean saving)
local function removeDefaults(db, defaults)
    if not defaults then return end
    for k, v in pairs(defaults) do
        if type(v) == "table" and type(db[k]) == "table" then
            removeDefaults(db[k], v)
            if next(db[k]) == nil then
                db[k] = nil
            end
        elseif db[k] == v then
            db[k] = nil
        end
    end
end

-- Create metatable for profile access
local function initSection(db, section, sv, svKey, defaults)
    local tableCreated
    if not sv[svKey] then
        sv[svKey] = {}
        tableCreated = true
    end

    local tbl = sv[svKey]

    if defaults then
        copyDefaults(tbl, defaults)
    end

    rawset(db, section, tbl)
    return tbl, tableCreated
end

-- Get profile key
local function getProfileKey(db)
    return db.keys.profile
end

local DBObjectLib = {}

--- Reset the current profile to defaults
function DBObjectLib:ResetProfile(noChildren, noCallbacks)
    local profile = self.profile
    for k, v in pairs(profile) do
        profile[k] = nil
    end

    local defaults = self.defaults and self.defaults.profile
    if defaults then
        copyDefaults(profile, defaults)
    end

    if not noCallbacks then
        self.callbacks:Fire("OnProfileReset", self)
    end
end

--- Reset the entire database
function DBObjectLib:ResetDB(defaultProfile)
    local sv = self.sv
    for k, v in pairs(sv) do
        sv[k] = nil
    end

    local defaults = self.defaults
    if defaults then
        for section in pairs(defaults) do
            -- Reinitialize
        end
    end

    self.callbacks:Fire("OnDatabaseReset", self)
end

--- Set the current profile
function DBObjectLib:SetProfile(name)
    local oldProfile = self.keys.profile
    self.keys.profile = name

    if not self.sv.profiles then
        self.sv.profiles = {}
    end
    if not self.sv.profiles[name] then
        self.sv.profiles[name] = {}
    end

    local defaults = self.defaults and self.defaults.profile
    if defaults then
        copyDefaults(self.sv.profiles[name], defaults)
    end

    self.profile = self.sv.profiles[name]
    self.callbacks:Fire("OnProfileChanged", self, name)
end

--- Get the current profile name
function DBObjectLib:GetCurrentProfile()
    return self.keys.profile
end

--- Get a list of profiles
function DBObjectLib:GetProfiles(tbl)
    tbl = tbl or {}
    local curProfile = self.keys.profile
    local i = 0
    for profileKey in pairs(self.sv.profiles or {}) do
        i = i + 1
        tbl[i] = profileKey
    end
    return tbl, i
end

--- Delete a profile
function DBObjectLib:DeleteProfile(name, silent)
    if not self.sv.profiles then return end
    if type(name) ~= "string" then
        error("Usage: AceDBObject:DeleteProfile(name): 'name' - string expected.", 2)
    end

    if self.keys.profile == name then
        error("Cannot delete the active profile.", 2)
    end

    self.sv.profiles[name] = nil
    self.callbacks:Fire("OnProfileDeleted", self, name)
end

--- Copy a profile into the current profile
function DBObjectLib:CopyProfile(name, silent)
    if type(name) ~= "string" then
        error("Usage: AceDBObject:CopyProfile(name): 'name' - string expected.", 2)
    end

    if not self.sv.profiles[name] then
        if not silent then
            error(("Cannot copy profile %q, it does not exist."):format(name), 2)
        end
        return
    end

    local profile = self.profile
    for k, v in pairs(profile) do
        profile[k] = nil
    end

    -- Deep copy
    local function deepCopy(src, dest)
        for k, v in pairs(src) do
            if type(v) == "table" then
                dest[k] = {}
                deepCopy(v, dest[k])
            else
                dest[k] = v
            end
        end
    end

    deepCopy(self.sv.profiles[name], profile)

    self.callbacks:Fire("OnProfileCopied", self, name)
end

--- Register defaults to the database
function DBObjectLib:RegisterDefaults(defaults)
    if defaults and type(defaults) ~= "table" then
        error("Usage: AceDBObject:RegisterDefaults(defaults): 'defaults' - table or nil expected.", 2)
    end

    self.defaults = defaults

    -- Apply defaults to existing sections
    if defaults then
        for section, sectionDefaults in pairs(defaults) do
            if type(sectionDefaults) == "table" then
                if section == "profile" then
                    if self.profile then
                        copyDefaults(self.profile, sectionDefaults)
                    end
                elseif rawget(self, section) then
                    copyDefaults(rawget(self, section), sectionDefaults)
                end
            end
        end
    end
end

--- Register a callback for DB events
function DBObjectLib:RegisterCallback(...)
    self.callbacks.RegisterCallback(...)
end

function DBObjectLib:UnregisterCallback(...)
    self.callbacks.UnregisterCallback(...)
end

function DBObjectLib:UnregisterAllCallbacks(...)
    self.callbacks.UnregisterAllCallbacks(...)
end

-- Create a new database object
function AceDB:New(tbl, defaults, defaultProfile)
    if type(tbl) == "string" then
        local name = tbl
        -- tbl is the name of a saved variable; create it if needed
        if not _G[name] then
            _G[name] = {}
        end
        tbl = _G[name]
    end

    if defaults and type(defaults) ~= "table" then
        error("Usage: AceDB:New(tbl, defaults, defaultProfile): 'defaults' - table expected.", 2)
    end

    -- Determine character key
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    local realmKey = GetRealmName()
    local classKey = select(2, UnitClass("player"))
    local raceKey = select(2, UnitRace("player"))
    local factionKey = UnitFactionGroup("player")
    local factionRealmKey = factionKey .. " - " .. realmKey
    local profileKey = defaultProfile or (charKey)

    -- Initialize the saved variable structure
    if not tbl.profiles then tbl.profiles = {} end
    if not tbl.profiles[profileKey] then tbl.profiles[profileKey] = {} end
    if not tbl.char then tbl.char = {} end
    if not tbl.char[charKey] then tbl.char[charKey] = {} end
    if not tbl.realm then tbl.realm = {} end
    if not tbl.realm[realmKey] then tbl.realm[realmKey] = {} end
    if not tbl.class then tbl.class = {} end
    if not tbl.class[classKey] then tbl.class[classKey] = {} end
    if not tbl.race then tbl.race = {} end
    if not tbl.race[raceKey] then tbl.race[raceKey] = {} end
    if not tbl.faction then tbl.faction = {} end
    if not tbl.faction[factionKey] then tbl.faction[factionKey] = {} end
    if not tbl.factionrealm then tbl.factionrealm = {} end
    if not tbl.factionrealm[factionRealmKey] then tbl.factionrealm[factionRealmKey] = {} end
    if not tbl.global then tbl.global = {} end

    -- Build the db object
    local db = {
        sv = tbl,
        keys = {
            char = charKey,
            realm = realmKey,
            class = classKey,
            race = raceKey,
            faction = factionKey,
            factionrealm = factionRealmKey,
            profile = profileKey,
        },
        profile = tbl.profiles[profileKey],
        global = tbl.global,
        char = tbl.char[charKey],
        realm = tbl.realm[realmKey],
        class = tbl.class[classKey],
        race = tbl.race[raceKey],
        faction = tbl.faction[factionKey],
        factionrealm = tbl.factionrealm[factionRealmKey],
        defaults = defaults,
        children = {},
    }

    -- Add callback support
    db.callbacks = CallbackHandler:New(db)

    -- Mix in the DBObject methods
    for k, v in pairs(DBObjectLib) do
        db[k] = v
    end

    -- Apply defaults
    if defaults then
        db:RegisterDefaults(defaults)
    end

    tinsert(AceDB.db_registry, db)
    return db
end

-- Namespace storage support
function AceDB:GetNamespace(db_or_self, name, silent)
    local db = (db_or_self ~= AceDB) and db_or_self or self
    if not db.children then db.children = {} end
    if not db.children[name] and not silent then
        error(("Usage: AceDBObject:GetNamespace(name): 'name' - namespace %q does not exist."):format(tostring(name)), 2)
    end
    return db.children[name]
end

function AceDB:RegisterNamespace(db_or_self, name, defaults)
    local db = (db_or_self ~= AceDB) and db_or_self or self
    if type(name) ~= "string" then
        error("Usage: AceDBObject:RegisterNamespace(name, defaults): 'name' - string expected.", 2)
    end
    if not db.children then db.children = {} end

    if not db.sv.namespaces then db.sv.namespaces = {} end
    if not db.sv.namespaces[name] then db.sv.namespaces[name] = {} end

    local sv = db.sv.namespaces[name]
    if not sv.profiles then sv.profiles = {} end

    local profileKey = db.keys.profile
    if not sv.profiles[profileKey] then sv.profiles[profileKey] = {} end

    local child = {
        sv = sv,
        keys = db.keys,
        profile = sv.profiles[profileKey],
        defaults = defaults,
        callbacks = CallbackHandler:New({}),
    }

    for k, v in pairs(DBObjectLib) do
        child[k] = v
    end

    if defaults then
        child:RegisterDefaults(defaults)
    end

    db.children[name] = child
    return child
end
