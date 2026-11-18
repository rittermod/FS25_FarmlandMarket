--[[
    RmContractorBridge.lua
    Read-only adapter for The Contractor (FS25_TheContractor).

    Answers two questions for FarmlandMarket: which Contractor farmer holds a
    farmland, and how a farm stands with that farmer. It reaches The Contractor
    through g_currentMission.TheContractor and calls only hasGenerated,
    getHolder, getScore and getBand - nothing that changes The Contractor's
    state. Whenever it cannot answer (The Contractor absent, a function
    missing, farmers not made yet, or a call that raised earlier this session)
    it answers nil, and FarmlandMarket keeps its own behavior.

    Never save the farmer ids it returns: resolve the farmer from the farmland
    id each time.

    Author: Ritter
]]

RmContractorBridge = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- CONSTANTS
-- ============================================================================

--- The Contractor functions this adapter reads; detection requires all of them.
RmContractorBridge.REQUIRED = {
    { owner = "Farmers", name = "hasGenerated" },
    { owner = "Farmers", name = "getHolder" },
    { owner = "Relationships", name = "getScore" },
    { owner = "Relationships", name = "getBand" },
}

RmContractorBridge.REASON_NOT_DETECTED = "not detected"
RmContractorBridge.REASON_NOT_INSTALLED = "not installed"

RmContractorBridge.available = false
RmContractorBridge.reason = RmContractorBridge.REASON_NOT_DETECTED

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Run one Contractor call. A raise turns the adapter off for the session.
---@param label string the call, as Owner:fn, for the log
---@param context string identifiers of the query, for the log
---@param fn function closure making the call
---@return boolean ok false when the call raised
---@return any result the call's result, or nil
local function callContractor(label, context, fn)
    local ok, result = pcall(fn)
    if not ok then
        RmContractorBridge.available = false
        RmContractorBridge.reason = "call failed: " .. label
        Log:warning("Contractor adapter: %s raised for %s (%s) - Contractor reads off for this session",
            label, context, tostring(result))
        return false, nil
    end
    return true, result
end

--- Resolve the farmer record holding a farmland, tracing why when there is none.
---@param queryName string the public query asking, for the log
---@param farmlandId number farmland id
---@param farmId number|nil farm id, for the log only
---@return table|nil person The Contractor's live record, never handed out
---@return table|nil contractor The Contractor's object
local function findHolder(queryName, farmlandId, farmId)
    if not RmContractorBridge.available then
        Log:trace("  %s: adapter not available (%s)", queryName, tostring(RmContractorBridge.reason))
        return nil, nil
    end

    local contractor = RmContractorBridge.getContractor()
    if contractor == nil then
        Log:trace("  %s: no Contractor object", queryName)
        return nil, nil
    end

    local context = string.format("farmlandId=%s farmId=%s", tostring(farmlandId), tostring(farmId))

    local okGenerated, generated = callContractor("Farmers:hasGenerated", context, function()
        return contractor.Farmers:hasGenerated()
    end)
    if not okGenerated then
        Log:trace("  %s: Farmers:hasGenerated raised", queryName)
        return nil, nil
    end
    if generated ~= true then
        Log:trace("  %s: farmers not made yet", queryName)
        return nil, nil
    end

    local okHolder, person = callContractor("Farmers:getHolder", context, function()
        return contractor.Farmers:getHolder(farmlandId)
    end)
    if not okHolder then
        Log:trace("  %s: Farmers:getHolder raised", queryName)
        return nil, nil
    end
    if person == nil then
        Log:trace("  %s: no farmer holds farmland %s", queryName, tostring(farmlandId))
        return nil, nil
    end

    return person, contractor
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- The Contractor's mission object, or nil when it is not installed.
---@return table|nil contractor g_currentMission.TheContractor
function RmContractorBridge.getContractor()
    if g_currentMission == nil then
        return nil
    end
    return g_currentMission.TheContractor
end

--- Check that The Contractor is present with every function this adapter reads.
---@return boolean available true when the queries can answer
function RmContractorBridge.detect()
    Log:trace(">>> RmContractorBridge.detect()")
    RmContractorBridge.available = false

    local contractor = RmContractorBridge.getContractor()
    if contractor == nil then
        RmContractorBridge.reason = RmContractorBridge.REASON_NOT_INSTALLED
        Log:info("Contractor adapter: The Contractor is not present - FarmlandMarket runs without it")
        Log:trace("<<< RmContractorBridge.detect = false (not installed)")
        return false
    end

    local missing = {}
    for _, required in ipairs(RmContractorBridge.REQUIRED) do
        local owner = contractor[required.owner]
        if type(owner) ~= "table" or type(owner[required.name]) ~= "function" then
            table.insert(missing, required.owner .. "." .. required.name)
        end
    end

    if #missing > 0 then
        RmContractorBridge.reason = "missing " .. table.concat(missing, ", ")
        Log:info("Contractor adapter: The Contractor is present but %s - FarmlandMarket runs without it",
            RmContractorBridge.reason)
        Log:trace("<<< RmContractorBridge.detect = false (%s)", RmContractorBridge.reason)
        return false
    end

    RmContractorBridge.available = true
    RmContractorBridge.reason = nil
    Log:info("Contractor adapter: The Contractor detected - farmer and relationship reads on")
    Log:trace("<<< RmContractorBridge.detect = true")
    return true
end

--- Return to the not-detected state, at mission teardown.
function RmContractorBridge.reset()
    RmContractorBridge.available = false
    RmContractorBridge.reason = RmContractorBridge.REASON_NOT_DETECTED
    Log:debug("Contractor adapter: reset")
end

--- Whether the queries can answer this session.
---@return boolean available
function RmContractorBridge.isAvailable()
    return RmContractorBridge.available == true
end

--- Why the adapter is not available.
---@return string|nil reason nil while available
function RmContractorBridge.getReason()
    return RmContractorBridge.reason
end

--- The Contractor farmer holding a farmland.
---@param farmlandId number farmland id
---@return table|nil holder { id = number, name = string }, a copy; nil when none or unavailable
function RmContractorBridge.getHolder(farmlandId)
    Log:trace(">>> RmContractorBridge.getHolder(%s)", tostring(farmlandId))
    local person = findHolder("getHolder", farmlandId, nil)
    if person == nil then
        Log:trace("<<< RmContractorBridge.getHolder = nil")
        return nil
    end

    local holder = { id = person.id, name = person.name }
    Log:debug("CONTRACTOR: farmland %s held by farmer #%s %s",
        tostring(farmlandId), tostring(holder.id), tostring(holder.name))
    Log:trace("<<< RmContractorBridge.getHolder = #%s", tostring(holder.id))
    return holder
end

--- A farm's relationship with the farmer holding a farmland.
---@param farmId number the player's farm id
---@param farmlandId number farmland id
---@return table|nil relationship { score = number, band = string }; nil when no farmer or unavailable
function RmContractorBridge.getRelationship(farmId, farmlandId)
    Log:trace(">>> RmContractorBridge.getRelationship(%s, %s)", tostring(farmId), tostring(farmlandId))
    local person, contractor = findHolder("getRelationship", farmlandId, farmId)
    if person == nil then
        Log:trace("<<< RmContractorBridge.getRelationship = nil")
        return nil
    end

    local context = string.format("farmlandId=%s farmId=%s", tostring(farmlandId), tostring(farmId))

    local okScore, score = callContractor("Relationships:getScore", context, function()
        return contractor.Relationships:getScore(farmId, person.id)
    end)
    if not okScore then
        Log:trace("<<< RmContractorBridge.getRelationship = nil (Relationships:getScore raised)")
        return nil
    end

    -- The band table's shape is not part of The Contractor's public API, so read it inside the guard.
    local okBand, band = callContractor("Relationships.getBand", context, function()
        return contractor.Relationships.getBand(score).key
    end)
    if not okBand then
        Log:trace("<<< RmContractorBridge.getRelationship = nil (Relationships.getBand raised)")
        return nil
    end

    local relationship = { score = score, band = band }
    Log:debug("CONTRACTOR: farm %s and farmer #%s on farmland %s: score %s, band %s",
        tostring(farmId), tostring(person.id), tostring(farmlandId), tostring(score), tostring(band))
    Log:trace("<<< RmContractorBridge.getRelationship = %s / %s", tostring(score), tostring(band))
    return relationship
end

-- ============================================================================
-- GAME HOOKS
-- ============================================================================

-- Every mod has run its loadMap by mission start, so The Contractor's object exists by then if installed.
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function()
    RmContractorBridge.detect()
end)

BaseMission.delete = Utils.appendedFunction(BaseMission.delete, function()
    RmContractorBridge.reset()
end)
