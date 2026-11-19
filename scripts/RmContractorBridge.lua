--[[
    RmContractorBridge.lua
    Read-only adapter for The Contractor (FS25_TheContractor).

    Answers three questions for FarmlandMarket: which Contractor farmer holds a
    farmland, how a farm stands with that farmer, and whose farmyard a farmland
    is. It reaches The Contractor through g_currentMission.TheContractor and
    changes none of its state.
    Contractor public API (stable): Farmers:getHolder, Relationships:getScore.
    Contractor internal (may change): Farmers:getFarmers, a farmer's yardFarmlandId,
    Farmers:hasGenerated, Relationships.getBand, Relationships:getChip,
    Relationships.REFUSES_BELOW, Relationships.MAX_SCORE.
    Whenever it cannot answer (The Contractor absent, a function missing,
    farmers not made yet, or a call that raised earlier this session) it
    answers nil, and FarmlandMarket keeps its own behavior; a missing constant
    falls back to The Contractor's 0.0.0.2 value.

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

-- The Contractor's relationship constants as of 0.0.0.2, used when a read finds none
RmContractorBridge.FALLBACK_REFUSES_BELOW = -40
RmContractorBridge.FALLBACK_MAX_SCORE = 100

--- The Contractor's relationship chip fills by tone, as RGBA; [true] is the color-blind palette.
RmContractorBridge.CHIP_COLORS = {
    good = {
        [false] = { 0.12, 0.36, 0.08, 1 },
        [true] = { 0.0423, 0.2502, 0.8069, 1 },
    },
    neutral = {
        [false] = { 0.17, 0.17, 0.18, 1 },
        [true] = { 0.17, 0.17, 0.18, 1 },
    },
    warn = {
        [false] = { 0.45, 0.30, 0.03, 1 },
        [true] = { 0.45, 0.30, 0.03, 1 },
    },
    bad = {
        [false] = { 0.45, 0.09, 0.06, 1 },
        [true] = { 0.521, 0.2899, 0.0, 1 },
    },
}

RmContractorBridge.available = false
-- Yard reads need Farmers:getFarmers, which detection does not require
RmContractorBridge.yardReadsAvailable = false
-- The relationship chip needs Relationships:getChip, which detection does not require
RmContractorBridge.chipReadsAvailable = false
RmContractorBridge.reason = RmContractorBridge.REASON_NOT_DETECTED
RmContractorBridge.refusesBelow = RmContractorBridge.FALLBACK_REFUSES_BELOW
RmContractorBridge.maxScore = RmContractorBridge.FALLBACK_MAX_SCORE

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

--- The Contractor's object once its farmers exist, tracing why when it is not ready.
---@param queryName string the public query asking, for the log
---@param context string identifiers of the query, for the log
---@return table|nil contractor The Contractor's object; nil when unavailable or not ready
local function readyContractor(queryName, context)
    if not RmContractorBridge.available then
        Log:trace("  %s: adapter not available (%s)", queryName, tostring(RmContractorBridge.reason))
        return nil
    end

    local contractor = RmContractorBridge.getContractor()
    if contractor == nil then
        Log:trace("  %s: no Contractor object", queryName)
        return nil
    end

    -- Contractor internal (may change): hasGenerated; if it disappears, detect turns the adapter off.
    local okGenerated, generated = callContractor("Farmers:hasGenerated", context, function()
        return contractor.Farmers:hasGenerated()
    end)
    if not okGenerated then
        Log:trace("  %s: Farmers:hasGenerated raised", queryName)
        return nil
    end
    if generated ~= true then
        Log:trace("  %s: farmers not made yet", queryName)
        return nil
    end
    return contractor
end

--- Resolve the farmer record holding a farmland, tracing why when there is none.
---@param queryName string the public query asking, for the log
---@param farmlandId number farmland id
---@param farmId number|nil farm id, for the log only
---@return table|nil person The Contractor's live record, never handed out
---@return table|nil contractor The Contractor's object
local function findHolder(queryName, farmlandId, farmId)
    local context = string.format("farmlandId=%s farmId=%s", tostring(farmlandId), tostring(farmId))
    local contractor = readyContractor(queryName, context)
    if contractor == nil then
        return nil, nil
    end

    -- Contractor public API (stable): getHolder; if it disappears, detect turns the adapter off.
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

--- Read one relationship constant, or keep its fallback with a WARNING naming it.
---@param relationships table The Contractor's Relationships object
---@param name string the constant's name
---@param fallback number the value kept when the read is missing or of the wrong sign
---@param isValid function predicate on the read value
---@return number value
local function readConstant(relationships, name, fallback, isValid)
    local value = relationships[name]
    if isValid(value) then
        Log:debug("CONTRACTOR: Relationships.%s = %s", name, tostring(value))
        return value
    end
    Log:warning("Contractor adapter: Relationships.%s is %s, not a number of the expected sign - using %s",
        name, tostring(value), tostring(fallback))
    return fallback
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
    RmContractorBridge.yardReadsAvailable = false
    RmContractorBridge.chipReadsAvailable = false
    RmContractorBridge.refusesBelow = RmContractorBridge.FALLBACK_REFUSES_BELOW
    RmContractorBridge.maxScore = RmContractorBridge.FALLBACK_MAX_SCORE

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

    -- Contractor internal (may change): REFUSES_BELOW; if it disappears, FM uses its fallback.
    RmContractorBridge.refusesBelow = readConstant(contractor.Relationships, "REFUSES_BELOW",
        RmContractorBridge.FALLBACK_REFUSES_BELOW, function(value)
            return type(value) == "number" and value < 0
        end)
    -- Contractor internal (may change): MAX_SCORE; if it disappears, FM uses its fallback.
    RmContractorBridge.maxScore = readConstant(contractor.Relationships, "MAX_SCORE",
        RmContractorBridge.FALLBACK_MAX_SCORE, function(value)
            return type(value) == "number" and value > 0
        end)

    -- Contractor internal (may change): getFarmers; if it disappears, FM answers "no yard" and keeps its other reads.
    RmContractorBridge.yardReadsAvailable = type(contractor.Farmers.getFarmers) == "function"
    if RmContractorBridge.yardReadsAvailable then
        Log:trace("  detect: Farmers.getFarmers present - farmyard reads on")
    else
        Log:info("Contractor adapter: The Contractor has no Farmers.getFarmers - farmyards are treated as ordinary land")
    end

    -- Contractor internal (may change): getChip; if it disappears, FM shows no chip and keeps its other reads.
    RmContractorBridge.chipReadsAvailable = type(contractor.Relationships.getChip) == "function"
    if RmContractorBridge.chipReadsAvailable then
        Log:trace("  detect: Relationships.getChip present - relationship chip on")
    else
        Log:info("Contractor adapter: The Contractor has no Relationships.getChip - no relationship chip is shown")
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
    RmContractorBridge.yardReadsAvailable = false
    RmContractorBridge.chipReadsAvailable = false
    RmContractorBridge.reason = RmContractorBridge.REASON_NOT_DETECTED
    RmContractorBridge.refusesBelow = RmContractorBridge.FALLBACK_REFUSES_BELOW
    RmContractorBridge.maxScore = RmContractorBridge.FALLBACK_MAX_SCORE
    Log:debug("Contractor adapter: reset")
end

--- The score below which a farmer refuses to deal: The Contractor's, or the fallback.
---@return number refusesBelow
function RmContractorBridge.getRefusesBelow()
    return RmContractorBridge.refusesBelow
end

--- The best relationship score: The Contractor's, or the fallback.
---@return number maxScore
function RmContractorBridge.getMaxScore()
    return RmContractorBridge.maxScore
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
---@return table|nil relationship { score = number, band = string, farmerId = number }; nil when none or unavailable
function RmContractorBridge.getRelationship(farmId, farmlandId)
    Log:trace(">>> RmContractorBridge.getRelationship(%s, %s)", tostring(farmId), tostring(farmlandId))
    local person, contractor = findHolder("getRelationship", farmlandId, farmId)
    if person == nil then
        Log:trace("<<< RmContractorBridge.getRelationship = nil")
        return nil
    end

    local context = string.format("farmlandId=%s farmId=%s", tostring(farmlandId), tostring(farmId))

    -- Contractor public API (stable): getScore; if it disappears, detect turns the adapter off.
    local okScore, score = callContractor("Relationships:getScore", context, function()
        return contractor.Relationships:getScore(farmId, person.id)
    end)
    if not okScore then
        Log:trace("<<< RmContractorBridge.getRelationship = nil (Relationships:getScore raised)")
        return nil
    end

    -- Contractor internal (may change): getBand; if it disappears, detect turns the adapter off.
    local okBand, band = callContractor("Relationships.getBand", context, function()
        return contractor.Relationships.getBand(score).key
    end)
    if not okBand then
        Log:trace("<<< RmContractorBridge.getRelationship = nil (Relationships.getBand raised)")
        return nil
    end

    local relationship = { score = score, band = band, farmerId = person.id }
    Log:debug("CONTRACTOR: farm %s and farmer #%s on farmland %s: score %s, band %s",
        tostring(farmId), tostring(person.id), tostring(farmlandId), tostring(score), tostring(band))
    Log:trace("<<< RmContractorBridge.getRelationship = %s / %s", tostring(score), tostring(band))
    return relationship
end

--- A farm's relationship chip with the farmer holding a farmland: The Contractor's text and its tone's fill.
---@param farmId number the player's farm id
---@param farmlandId number farmland id
---@return table|nil chip { text = string, color = { [false] = rgba, [true] = rgba } }; nil when none or unavailable
function RmContractorBridge.getRelationshipChip(farmId, farmlandId)
    Log:trace(">>> RmContractorBridge.getRelationshipChip(%s, %s)", tostring(farmId), tostring(farmlandId))
    if RmContractorBridge.available and not RmContractorBridge.chipReadsAvailable then
        Log:trace("<<< RmContractorBridge.getRelationshipChip = nil (no Relationships.getChip)")
        return nil
    end

    local person, contractor = findHolder("getRelationshipChip", farmlandId, farmId)
    if person == nil then
        Log:trace("<<< RmContractorBridge.getRelationshipChip = nil (no holder)")
        return nil
    end

    local context = string.format("farmlandId=%s farmId=%s", tostring(farmlandId), tostring(farmId))

    -- Contractor internal (may change): getChip returns text and tone; if it disappears, FM shows no chip.
    local okChip, answer = callContractor("Relationships:getChip", context, function()
        local text, tone = contractor.Relationships:getChip(farmId, person.id)
        return { text = text, tone = tone }
    end)
    if not okChip then
        Log:trace("<<< RmContractorBridge.getRelationshipChip = nil (Relationships:getChip raised)")
        return nil
    end

    if type(answer.text) ~= "string" or answer.text == "" then
        Log:trace("<<< RmContractorBridge.getRelationshipChip = nil (unusable chip text %s)", tostring(answer.text))
        return nil
    end

    local color = RmContractorBridge.CHIP_COLORS[answer.tone] or RmContractorBridge.CHIP_COLORS.neutral
    Log:debug("CONTRACTOR: farm %s and farmer #%s on farmland %s: chip '%s', tone %s",
        tostring(farmId), tostring(person.id), tostring(farmlandId), answer.text, tostring(answer.tone))
    Log:trace("<<< RmContractorBridge.getRelationshipChip = '%s'", answer.text)
    return { text = answer.text, color = color }
end

--- The Contractor farmer whose farmyard a farmland is.
---@param farmlandId number farmland id
---@return table|nil farmer { id = number, name = string }, a copy; nil when none or unavailable
function RmContractorBridge.getYardFarmer(farmlandId)
    Log:trace(">>> RmContractorBridge.getYardFarmer(%s)", tostring(farmlandId))
    if RmContractorBridge.available and not RmContractorBridge.yardReadsAvailable then
        Log:trace("<<< RmContractorBridge.getYardFarmer = nil (no Farmers.getFarmers)")
        return nil
    end

    local context = string.format("farmlandId=%s", tostring(farmlandId))
    local contractor = readyContractor("getYardFarmer", context)
    if contractor == nil then
        Log:trace("<<< RmContractorBridge.getYardFarmer = nil (not ready)")
        return nil
    end

    -- Contractor internal (may change): getFarmers and a farmer's yardFarmlandId; if either disappears, FM
    -- answers "no yard". The walk sits inside the guard, so an unexpected shape turns the adapter off.
    local okFarmers, yardFarmer = callContractor("Farmers:getFarmers", context, function()
        for _, person in ipairs(contractor.Farmers:getFarmers()) do
            if person.yardFarmlandId == farmlandId then
                return { id = person.id, name = person.name }
            end
        end
        return nil
    end)
    if not okFarmers then
        Log:trace("<<< RmContractorBridge.getYardFarmer = nil (Farmers:getFarmers raised)")
        return nil
    end
    if yardFarmer == nil then
        Log:trace("<<< RmContractorBridge.getYardFarmer = nil (no farmer's yard)")
        return nil
    end

    Log:debug("CONTRACTOR: farmland %s is the farmyard of farmer #%s %s",
        tostring(farmlandId), tostring(yardFarmer.id), tostring(yardFarmer.name))
    Log:trace("<<< RmContractorBridge.getYardFarmer = #%s", tostring(yardFarmer.id))
    return yardFarmer
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
