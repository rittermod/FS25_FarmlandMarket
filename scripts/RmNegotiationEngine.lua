--[[
    RmNegotiationEngine.lua
    Stateless negotiation engine for farmland buying/selling.
    Pure-function module: no game state, no persistence, no network.
    Depends only on RmLogging and math.* stdlib.

    Author: Ritter
]]

-- =============================================================================
-- MODULE DECLARATION & CONSTANTS
-- =============================================================================

RmNegotiationEngine = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- Outcome constants
RmNegotiationEngine.OUTCOME_DEAL = "deal"
RmNegotiationEngine.OUTCOME_REJECTED = "rejected"
RmNegotiationEngine.OUTCOME_FAILED = "failed"
RmNegotiationEngine.OUTCOME_DISMISSED = "dismissed"
RmNegotiationEngine.OUTCOME_NPC_WALKED = "npc_walked"
RmNegotiationEngine.OUTCOME_REFUSED = "refused"

-- How far a relationship moves a hidden number at full strength (factor +1 or -1)
RmNegotiationEngine.RELATIONSHIP_SWING = 0.5

-- Park-Miller MINSTD generator for the per-farmer temperament
RmNegotiationEngine.TEMPERAMENT_MODULUS = 2147483647
RmNegotiationEngine.TEMPERAMENT_MULTIPLIER = 48271

-- Mode constants
RmNegotiationEngine.MODE_LISTED_BUY = "listed_buy"
RmNegotiationEngine.MODE_UNLISTED_BUY = "unlisted_buy"
RmNegotiationEngine.MODE_SELL = "sell"

-- Valid preset names (for validation)
RmNegotiationEngine.VALID_PRESETS = { "easy", "normal", "hard", "harder", "realistic" }

-- =============================================================================
-- PRESET PARAMETER TABLES
-- =============================================================================

RmNegotiationEngine.LISTED_BUY = {
    markupRange = { 0.04, 0.16 },
    stubbornness = { base = 0.48, range = 0.16 },
    rejectThreshold = 0.65,
    maxRounds = 3,
    counterNoise = 0.035,
    convergenceThreshold = 0.025,
    lastDitchChance = 0.38,
    lastDitchProximity = 0.97,
    decay = 0.55,
    reservationByPreset = {
        easy      = { 0.81, 0.94 },
        normal    = { 0.83, 0.96 },
        hard      = { 0.84, 0.97 },
        harder    = { 0.85, 0.97 },
        realistic = { 0.85, 0.98 },
    },
    minFirstConcession = 0.01,
}

RmNegotiationEngine.UNLISTED_BUY = {
    stubbornness = { base = 0.58, range = 0.15 },
    rejectThreshold = 0.65,
    maxRounds = 3,
    counterNoise = 0.04,
    convergenceThreshold = 0.025,
    lastDitchChance = 0.35,
    lastDitchProximity = 0.97,
    decay = 0.55,
    reservation = { 0.82, 0.96 },
    dismissByPreset = {
        easy      = 0.10,
        normal    = 0.25,
        hard      = 0.40,
        harder    = 0.55,
        realistic = 0.70,
    },
    demandByPreset = {
        easy      = { 1.12, 1.55 },
        normal    = { 1.18, 1.65 },
        hard      = { 1.22, 1.75 },
        harder    = { 1.25, 1.82 },
        realistic = { 1.28, 1.90 },
    },
    minFirstConcession = 0.01,
}

RmNegotiationEngine.SELL = {
    npcOpening = { 0.68, 0.92 },
    npcResListing = { 0.78, 0.99 },
    npcMarketCap = { 0.90, 1.15 },
    npcStubbornness = { base = 0.48, range = 0.22 },
    npcWalkaway = 1.15,
    maxRounds = 3,
    counterNoise = 0.045,
    convergenceThreshold = 0.025,
    lastDitchProximity = 0.05,
    lastDitchChance = 0.38,
    decay = 0.55,
    maxListingMultiplier = 2.0,
}

-- =============================================================================
-- STRATEGY TABLES
-- =============================================================================

RmNegotiationEngine.BUY_STRATEGIES = {
    conservative = { openingPct = 0.93, increment = 0.03 },
    moderate     = { openingPct = 0.85, increment = 0.05 },
    aggressive   = { openingPct = 0.76, increment = 0.06 },
    greedy       = { openingPct = 0.67, increment = 0.07 },
}

RmNegotiationEngine.SELL_STRATEGIES = {
    conservative = { listingMarkup = 0.05, reservationPct = 0.92, stubbornness = 0.30 },
    moderate     = { listingMarkup = 0.10, reservationPct = 0.96, stubbornness = 0.48 },
    aggressive   = { listingMarkup = 0.18, reservationPct = 1.00, stubbornness = 0.65 },
    greedy       = { listingMarkup = 0.25, reservationPct = 1.05, stubbornness = 0.80 },
}

-- =============================================================================
-- UTILITY FUNCTIONS (local)
-- =============================================================================

---@param lo number
---@param hi number
---@return number
local function randomInRange(lo, hi)
    return lo + math.random() * (hi - lo)
end

---@param mean number
---@param stddev number
---@return number
local function gaussianRandom(mean, stddev)
    local u1 = math.max(math.random(), 1e-10)
    local u2 = math.random()
    local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    return mean + z * stddev
end

---@param value number
---@param min number
---@param max number
---@return number
local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

-- =============================================================================
-- VALIDATION FUNCTIONS (public)
-- =============================================================================

---@param preset string
---@return boolean
function RmNegotiationEngine.isValidPreset(preset)
    return RmNegotiationEngine.LISTED_BUY.reservationByPreset[preset] ~= nil
end

---@param strategy string
---@param mode string "buy"|"sell"
---@return boolean
function RmNegotiationEngine.isValidStrategy(strategy, mode)
    if mode == "buy" then
        return RmNegotiationEngine.BUY_STRATEGIES[strategy] ~= nil
    elseif mode == "sell" then
        return RmNegotiationEngine.SELL_STRATEGIES[strategy] ~= nil
    end
    return false
end

---@return number maxRounds Always 3
function RmNegotiationEngine.getMaxRounds()
    return 3
end

-- =============================================================================
-- PROFILE GENERATION FUNCTIONS (public)
-- =============================================================================

---@param preset string "easy"|"normal"|"hard"|"harder"|"realistic"
---@param marketValue number Current market price (must be > 0)
---@return table|nil sellerProfile Flat seller profile table, or nil on invalid input
function RmNegotiationEngine.generateListedSeller(preset, marketValue)
    Log:trace(">>> generateListedSeller(preset=%s, marketValue=%s)", tostring(preset), tostring(marketValue))

    if not RmNegotiationEngine.isValidPreset(preset) then
        Log:warning("Invalid preset: %s", tostring(preset))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local params = RmNegotiationEngine.LISTED_BUY
    local markup = randomInRange(params.markupRange[1], params.markupRange[2])
    local listingPrice = marketValue * (1 + markup)
    local resRange = params.reservationByPreset[preset]
    local resPct = randomInRange(resRange[1], resRange[2])
    local reservation = listingPrice * resPct
    local stubbornness = clamp(params.stubbornness.base + randomInRange(-params.stubbornness.range, params.stubbornness.range), 0.1, 0.95)
    local rejectFloor = params.rejectThreshold * listingPrice

    local profile = {
        mode = RmNegotiationEngine.MODE_LISTED_BUY,
        preset = preset,
        marketValue = marketValue,
        anchorPrice = listingPrice,
        listingPrice = listingPrice,
        reservation = reservation,
        stubbornness = stubbornness,
        rejectFloor = rejectFloor,
    }

    Log:debug("NEGOTIATION: Generated listed seller: listing=%.0f reservation=%.0f stubbornness=%.2f rejectFloor=%.0f",
        listingPrice, reservation, stubbornness, rejectFloor)
    Log:trace("<<< generateListedSeller")
    return profile
end

---@param preset string "easy"|"normal"|"hard"|"harder"|"realistic"
---@param marketValue number Current market price (must be > 0)
---@param relationship table|nil { factor = number, temperament = number|nil }; nil draws today's unshaped seller
---@return table|nil sellerProfile Flat seller profile table, {dismissed=true} if seller refuses, or nil on invalid input
function RmNegotiationEngine.generateUnlistedSeller(preset, marketValue, relationship)
    Log:trace(">>> generateUnlistedSeller(preset=%s, marketValue=%s, relationship=%s)",
        tostring(preset), tostring(marketValue), tostring(relationship ~= nil))

    if not RmNegotiationEngine.isValidPreset(preset) then
        Log:warning("Invalid preset: %s", tostring(preset))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local params = RmNegotiationEngine.UNLISTED_BUY

    -- Dismissal gate: the relationship shapes the chance, never the number of draws
    local baseDismissChance = params.dismissByPreset[preset]
    local dismissChance = baseDismissChance
    if relationship ~= nil then
        dismissChance = RmNegotiationEngine.shapeDismissChance(baseDismissChance, relationship.factor)
        Log:trace("  generateUnlistedSeller: dismissal chance shaped by factor %s", tostring(relationship.factor))
    else
        Log:trace("  generateUnlistedSeller: no relationship, preset dismissal chance")
    end
    if math.random() < dismissChance then
        Log:debug("NEGOTIATION: Seller dismissed approach (preset=%s, chance %.3f -> %.3f)",
            preset, baseDismissChance, dismissChance)
        return { dismissed = true }
    end

    local demandRange = params.demandByPreset[preset]
    local demandMult = randomInRange(demandRange[1], demandRange[2])
    local demandPrice = marketValue * demandMult
    local resPct = randomInRange(params.reservation[1], params.reservation[2])
    local reservation = demandPrice * resPct
    local stubbornness = clamp(params.stubbornness.base + randomInRange(-params.stubbornness.range, params.stubbornness.range), 0.1, 0.95)
    local rejectFloor = params.rejectThreshold * demandPrice

    local profile = {
        mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
        preset = preset,
        marketValue = marketValue,
        anchorPrice = demandPrice,
        demandPrice = demandPrice,
        reservation = reservation,
        stubbornness = stubbornness,
        rejectFloor = rejectFloor,
    }

    Log:debug("NEGOTIATION: Generated unlisted seller: demand=%.0f reservation=%.0f stubbornness=%.2f",
        demandPrice, reservation, stubbornness)

    if relationship ~= nil then
        local shaped = RmNegotiationEngine.shapeSeller(profile, relationship.factor, relationship.temperament)
        Log:debug("NEGOTIATION: Shaped unlisted seller (factor %.3f): demand %.0f -> %.0f, reservation %.0f -> %.0f, "
            .. "floor %.0f -> %.0f, stubbornness %.2f -> %.2f, dismissal %.3f -> %.3f",
            relationship.factor, profile.demandPrice, shaped.demandPrice, profile.reservation, shaped.reservation,
            profile.rejectFloor, shaped.rejectFloor, profile.stubbornness, shaped.stubbornness,
            baseDismissChance, dismissChance)
        profile = shaped
    else
        Log:trace("  generateUnlistedSeller: no relationship, profile unshaped")
    end

    Log:trace("<<< generateUnlistedSeller")
    return profile
end

---@param listingPrice number Player's listing price (must be > 0)
---@param marketValue number Current market price (must be > 0)
---@return table|nil buyerProfile Flat NPC buyer profile table, or nil on invalid input
function RmNegotiationEngine.generateNpcBuyer(listingPrice, marketValue)
    Log:trace(">>> generateNpcBuyer(listingPrice=%s, marketValue=%s)", tostring(listingPrice), tostring(marketValue))

    if type(listingPrice) ~= "number" or listingPrice <= 0 then
        Log:warning("Invalid listingPrice: %s", tostring(listingPrice))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local params = RmNegotiationEngine.SELL
    local npcMarketCap = randomInRange(params.npcMarketCap[1], params.npcMarketCap[2]) * marketValue
    local npcOpening = math.min(
        randomInRange(params.npcOpening[1], params.npcOpening[2]) * listingPrice,
        npcMarketCap
    )
    local npcResListing = randomInRange(params.npcResListing[1], params.npcResListing[2]) * listingPrice
    local npcReservation = math.min(npcResListing, npcMarketCap)
    npcReservation = math.max(npcReservation, npcOpening) -- safe: npcOpening <= npcMarketCap
    local npcStubbornness = clamp(params.npcStubbornness.base + randomInRange(-params.npcStubbornness.range, params.npcStubbornness.range), 0.1, 0.95)

    local profile = {
        mode = RmNegotiationEngine.MODE_SELL,
        marketValue = marketValue,
        anchorPrice = listingPrice,
        listingPrice = listingPrice,
        npcOpening = npcOpening,
        npcReservation = npcReservation,
        npcStubbornness = npcStubbornness,
        walkawayThreshold = params.npcWalkaway,
    }

    Log:debug("NEGOTIATION: Generated NPC buyer: opening=%.0f reservation=%.0f stubbornness=%.2f",
        npcOpening, npcReservation, npcStubbornness)
    Log:trace("<<< generateNpcBuyer")
    return profile
end

-- =============================================================================
-- RELATIONSHIP SHAPING FUNCTIONS (public)
-- =============================================================================

--- One shared factor in [-1, 1]: +1 at maxScore, 0 at 0, -1 at refusesBelow.
---@param score number the farm's relationship score with the farmer
---@param maxScore number the best score possible
---@param refusesBelow number the score below which the farmer refuses (negative)
---@return number factor
function RmNegotiationEngine.relationshipFactor(score, maxScore, refusesBelow)
    Log:trace(">>> relationshipFactor(score=%s, maxScore=%s, refusesBelow=%s)",
        tostring(score), tostring(maxScore), tostring(refusesBelow))
    local factor
    if score >= 0 then
        factor = math.min(score / maxScore, 1)
        Log:trace("  relationshipFactor: non-negative score, scaled by maxScore")
    else
        factor = math.max(score / math.abs(refusesBelow), -1)
        Log:trace("  relationshipFactor: negative score, scaled by refusesBelow")
    end
    Log:trace("<<< relationshipFactor = %s", tostring(factor))
    return factor
end

--- Whether a farmer refuses to deal at all: strictly below the refusal threshold.
---@param score number the farm's relationship score with the farmer
---@param refusesBelow number the refusal threshold
---@return boolean refused
function RmNegotiationEngine.isRefused(score, refusesBelow)
    local refused = score < refusesBelow
    Log:trace("<<< isRefused(score=%s, refusesBelow=%s) = %s", tostring(score), tostring(refusesBelow),
        tostring(refused))
    return refused
end

--- A farmer's fixed temperament in [0, 1); integer steps below 2^47, so exact on every machine.
---@param farmerId number the farmer's id (a positive integer)
---@param salt number the savegame's temperament salt, an integer in [1, TEMPERAMENT_MODULUS - 1]
---@return number unit
function RmNegotiationEngine.farmerTemperament(farmerId, salt)
    local modulus = RmNegotiationEngine.TEMPERAMENT_MODULUS
    local multiplier = RmNegotiationEngine.TEMPERAMENT_MULTIPLIER
    local state = salt
    for _ = 1, farmerId do
        state = (state * multiplier) % modulus
    end
    local unit = (state - 1) / (modulus - 1)
    Log:trace("<<< farmerTemperament(farmerId=%s, salt=%s) = %s", tostring(farmerId), tostring(salt), tostring(unit))
    return unit
end

--- Map a temperament unit onto a seller mode's stubbornness range (base - range .. base + range).
---@param mode string MODE_LISTED_BUY or MODE_UNLISTED_BUY
---@param unit number temperament in [0, 1)
---@return number stubbornness
function RmNegotiationEngine.temperamentStubbornness(mode, unit)
    local params = RmNegotiationEngine.LISTED_BUY
    if mode == RmNegotiationEngine.MODE_UNLISTED_BUY then
        params = RmNegotiationEngine.UNLISTED_BUY
        Log:trace("  temperamentStubbornness: unlisted range")
    else
        Log:trace("  temperamentStubbornness: listed range")
    end
    local base, range = params.stubbornness.base, params.stubbornness.range
    local stubbornness = base - range + 2 * range * unit
    Log:trace("<<< temperamentStubbornness(mode=%s, unit=%s) = %s", tostring(mode), tostring(unit),
        tostring(stubbornness))
    return stubbornness
end

--- Move a chance-like number toward 0 for a good relationship, toward 1 (never reaching it) for a bad one.
---@param chance number a value in [0, 1)
---@param factor number relationship factor in [-1, 1]
---@return number shaped
function RmNegotiationEngine.shapeDismissChance(chance, factor)
    local swing = RmNegotiationEngine.RELATIONSHIP_SWING
    local shaped
    if factor >= 0 then
        shaped = chance * (1 - swing * factor)
        Log:trace("  shapeDismissChance: good relationship, toward 0")
    else
        shaped = chance + (1 - chance) * swing * (-factor)
        Log:trace("  shapeDismissChance: bad relationship, toward 1")
    end
    Log:trace("<<< shapeDismissChance(chance=%s, factor=%s) = %s", tostring(chance), tostring(factor), tostring(shaped))
    return shaped
end

--- A new seller profile shifted by the relationship; the input is untouched and a listing price never moves.
---@param profile table seller profile from generateListedSeller or generateUnlistedSeller
---@param factor number relationship factor in [-1, 1]
---@param unit number|nil the farmer's temperament; nil keeps the profile's own stubbornness
---@return table shaped
function RmNegotiationEngine.shapeSeller(profile, factor, unit)
    Log:trace(">>> shapeSeller(mode=%s, factor=%s, unit=%s)", tostring(profile.mode), tostring(factor), tostring(unit))
    local swing = RmNegotiationEngine.RELATIONSHIP_SWING
    local shaped = {}
    for key, value in pairs(profile) do
        shaped[key] = value
    end

    if profile.mode == RmNegotiationEngine.MODE_UNLISTED_BUY then
        -- Scale the markup over market value; at factor 0 this returns the anchor bit for bit
        local anchor = profile.anchorPrice
        local newAnchor = profile.marketValue + (anchor - profile.marketValue) * (1 - swing * factor)
        local scale = newAnchor / anchor
        shaped.anchorPrice = newAnchor
        shaped.demandPrice = newAnchor
        shaped.reservation = profile.reservation * scale
        shaped.rejectFloor = profile.rejectFloor * scale
        Log:trace("  shapeSeller: unlisted demand %s -> %s", tostring(anchor), tostring(newAnchor))
    else
        Log:trace("  shapeSeller: listed, anchor unchanged")
    end

    local k = 1 + swing * factor
    local anchor = shaped.anchorPrice
    shaped.reservation = anchor - (anchor - shaped.reservation) * k
    shaped.rejectFloor = anchor - (anchor - shaped.rejectFloor) * k

    local stubbornness = profile.stubbornness
    if unit ~= nil then
        stubbornness = RmNegotiationEngine.temperamentStubbornness(profile.mode, unit)
        Log:trace("  shapeSeller: stubbornness from temperament %s", tostring(stubbornness))
    else
        Log:trace("  shapeSeller: no temperament, profile stubbornness kept")
    end
    shaped.stubbornness = clamp(RmNegotiationEngine.shapeDismissChance(stubbornness, factor), 0.1, 0.95)

    Log:trace("<<< shapeSeller: reservation=%s rejectFloor=%s stubbornness=%s", tostring(shaped.reservation),
        tostring(shaped.rejectFloor), tostring(shaped.stubbornness))
    return shaped
end

-- =============================================================================
-- PLAYER-DRIVEN PER-ROUND EVALUATION FUNCTIONS (public)
-- =============================================================================

---@param sellerProfile table Seller profile from generateListedSeller or generateUnlistedSeller
---@param offer number Player's offer amount
---@param round number Current round (1, 2, or 3)
---@return table|nil {action=string, price=number|nil, counter=number|nil}
function RmNegotiationEngine.evaluateOffer(sellerProfile, offer, round)
    if type(sellerProfile) ~= "table" or type(offer) ~= "number" or type(round) ~= "number" then
        Log:warning("evaluateOffer: invalid input types")
        return nil
    end
    Log:trace(">>> evaluateOffer(round=%d, offer=%.0f)", round, offer)

    local anchor = sellerProfile.anchorPrice

    -- Accept if offer meets reservation
    if offer >= sellerProfile.reservation then
        Log:trace("<<< evaluateOffer: accepted at %.0f", offer)
        return { action = "accepted", price = offer }
    end

    -- Reject if below floor
    if offer < sellerProfile.rejectFloor then
        Log:trace("<<< evaluateOffer: rejected (below floor %.0f)", sellerProfile.rejectFloor)
        return { action = "rejected" }
    end

    -- Seller counters (read params from mode-specific table)
    local params
    if sellerProfile.mode == RmNegotiationEngine.MODE_LISTED_BUY then
        params = RmNegotiationEngine.LISTED_BUY
    else
        params = RmNegotiationEngine.UNLISTED_BUY
    end

    local decay = params.decay ^ (round - 1)
    local base = sellerProfile.reservation + sellerProfile.stubbornness * (anchor - sellerProfile.reservation) * decay
    local noise = gaussianRandom(0, params.counterNoise * anchor)
    local counter = clamp(base + noise, sellerProfile.reservation, anchor)

    -- Minimum first concession: ensure round 1 counter is below anchor
    if round == 1 and params.minFirstConcession then
        local maxFirstCounter = anchor * (1 - params.minFirstConcession)
        Log:trace(">>> minFirstConcession check (counter=%.0f, maxFirstCounter=%.0f)", counter, maxFirstCounter)
        if counter > maxFirstCounter then
            Log:debug("FIRST_CONCESSION: counter=%.0f, maxFirstCounter=%.0f", counter, maxFirstCounter)
            counter = maxFirstCounter
            counter = math.max(counter, sellerProfile.reservation)
            Log:debug("FIRST_CONCESSION: clamped=%.0f", counter)
        end
        Log:trace("<<< minFirstConcession = %.0f", counter)
    end

    -- Convergence check
    if math.abs(offer - counter) / anchor < params.convergenceThreshold then
        local midpoint = (offer + counter) / 2
        Log:trace("<<< evaluateOffer: converged_offer at %.0f", midpoint)
        return { action = "converged_offer", price = midpoint, counter = counter }
    end

    Log:trace("<<< evaluateOffer: countered at %.0f", counter)
    return { action = "countered", counter = counter }
end

---@param sellerProfile table Seller profile
---@param lastOffer number Player's last offer before walking away
---@param round number Round when player walked (1, 2, or 3)
---@return table|nil {action=string, price=number|nil}
function RmNegotiationEngine.evaluateWalkaway(sellerProfile, lastOffer, round)
    if type(sellerProfile) ~= "table" or type(lastOffer) ~= "number" or type(round) ~= "number" then
        Log:warning("evaluateWalkaway: invalid input types")
        return nil
    end
    Log:trace(">>> evaluateWalkaway(round=%d, lastOffer=%.0f)", round, lastOffer)

    local params
    if sellerProfile.mode == RmNegotiationEngine.MODE_LISTED_BUY then
        params = RmNegotiationEngine.LISTED_BUY
    else
        params = RmNegotiationEngine.UNLISTED_BUY
    end

    if round == 3 and lastOffer >= sellerProfile.reservation * params.lastDitchProximity and math.random() < params.lastDitchChance then
        local price = (lastOffer + sellerProfile.reservation) / 2
        Log:trace("<<< evaluateWalkaway: last_ditch_offer at %.0f", price)
        return { action = "last_ditch_offer", price = price }
    end

    Log:trace("<<< evaluateWalkaway: walked")
    return { action = "walked" }
end

---@param buyerProfile table NPC buyer profile from generateNpcBuyer
---@param playerAsk number Player's asking price this round
---@param round number Current round (1, 2, or 3)
---@return table|nil {action=string, price=number|nil, npcOffer=number|nil}
function RmNegotiationEngine.evaluatePlayerAsk(buyerProfile, playerAsk, round)
    if type(buyerProfile) ~= "table" or type(playerAsk) ~= "number" or type(round) ~= "number" then
        Log:warning("evaluatePlayerAsk: invalid input types")
        return nil
    end
    Log:trace(">>> evaluatePlayerAsk(round=%d, playerAsk=%.0f)", round, playerAsk)

    -- NPC walks away if player asks too much
    if playerAsk > buyerProfile.npcReservation * buyerProfile.walkawayThreshold then
        Log:trace("<<< evaluatePlayerAsk: npc_walked")
        return { action = "npc_walked" }
    end

    -- Accept if player asks at or below NPC reservation
    if playerAsk <= buyerProfile.npcReservation then
        Log:trace("<<< evaluatePlayerAsk: accepted at %.0f", playerAsk)
        return { action = "accepted", price = playerAsk }
    end

    -- NPC counters
    local anchor = buyerProfile.anchorPrice
    local sellParams = RmNegotiationEngine.SELL
    local decay = sellParams.decay ^ (round - 1)
    local base = buyerProfile.npcReservation - buyerProfile.npcStubbornness * (buyerProfile.npcReservation - buyerProfile.npcOpening) * decay
    local noise = gaussianRandom(0, sellParams.counterNoise * anchor)
    local npcOffer = clamp(base + noise, buyerProfile.npcOpening, buyerProfile.npcReservation)

    -- Convergence check
    if math.abs(playerAsk - npcOffer) / anchor < sellParams.convergenceThreshold then
        local midpoint = (playerAsk + npcOffer) / 2
        Log:trace("<<< evaluatePlayerAsk: converged_offer at %.0f", midpoint)
        return { action = "converged_offer", price = midpoint, npcOffer = npcOffer }
    end

    Log:trace("<<< evaluatePlayerAsk: countered at %.0f", npcOffer)
    return { action = "countered", npcOffer = npcOffer }
end

---@param buyerProfile table NPC buyer profile
---@param lastNpcOffer number NPC's last counter-offer
---@param lastPlayerAsk number Player's last asking price
---@param round number Round when player walked (1, 2, or 3)
---@return table|nil {action=string, price=number|nil}
function RmNegotiationEngine.evaluateSellWalkaway(buyerProfile, lastNpcOffer, lastPlayerAsk, round)
    if type(buyerProfile) ~= "table" or type(lastNpcOffer) ~= "number"
       or type(lastPlayerAsk) ~= "number" or type(round) ~= "number" then
        Log:warning("evaluateSellWalkaway: invalid input types")
        return nil
    end
    Log:trace(">>> evaluateSellWalkaway(round=%d)", round)

    local params = RmNegotiationEngine.SELL
    if round == 3 and math.abs(lastPlayerAsk - lastNpcOffer) / buyerProfile.anchorPrice < params.lastDitchProximity and math.random() < params.lastDitchChance then
        local price = (lastPlayerAsk + lastNpcOffer) / 2
        Log:trace("<<< evaluateSellWalkaway: last_ditch_offer at %.0f", price)
        return { action = "last_ditch_offer", price = price }
    end

    Log:trace("<<< evaluateSellWalkaway: walked")
    return { action = "walked" }
end

-- =============================================================================
-- STRATEGY-DRIVEN AUTO-PLAY FUNCTIONS (public)
-- =============================================================================

---@param preset string "easy"|"normal"|"hard"|"harder"|"realistic"
---@param strategy string "conservative"|"moderate"|"aggressive"|"greedy"
---@param marketValue number Current market price (must be > 0)
---@return table|nil result Full negotiation result, or nil on invalid input
function RmNegotiationEngine.negotiateListedBuy(preset, strategy, marketValue)
    Log:trace(">>> negotiateListedBuy(preset=%s, strategy=%s, marketValue=%s)",
        tostring(preset), tostring(strategy), tostring(marketValue))

    if not RmNegotiationEngine.isValidPreset(preset) then
        Log:warning("Invalid preset: %s", tostring(preset))
        return nil
    end
    if not RmNegotiationEngine.isValidStrategy(strategy, "buy") then
        Log:warning("Invalid buy strategy: %s", tostring(strategy))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local sellerProfile = RmNegotiationEngine.generateListedSeller(preset, marketValue)
    if sellerProfile == nil then
        return nil
    end

    local strategyTable = RmNegotiationEngine.BUY_STRATEGIES[strategy]
    local offers = {}
    local offer = strategyTable.openingPct * sellerProfile.listingPrice
    local lastOffer = offer

    for round = 1, 3 do
        if round > 1 then
            offer = offer + strategyTable.increment * sellerProfile.listingPrice
        end
        lastOffer = offer

        local result = RmNegotiationEngine.evaluateOffer(sellerProfile, offer, round)

        if result.action == "accepted" or result.action == "converged_offer" then
            table.insert(offers, { round = round, offer = offer, counter = nil })
            return {
                outcome = RmNegotiationEngine.OUTCOME_DEAL,
                mode = RmNegotiationEngine.MODE_LISTED_BUY,
                price = result.price,
                rounds = round,
                marketValue = marketValue,
                anchor = sellerProfile.listingPrice,
                reservation = sellerProfile.reservation,
                offers = offers,
            }
        elseif result.action == "rejected" then
            table.insert(offers, { round = round, offer = offer, counter = nil })
            return {
                outcome = RmNegotiationEngine.OUTCOME_REJECTED,
                mode = RmNegotiationEngine.MODE_LISTED_BUY,
                price = nil,
                rounds = round,
                marketValue = marketValue,
                anchor = sellerProfile.listingPrice,
                reservation = sellerProfile.reservation,
                offers = offers,
            }
        else -- countered
            table.insert(offers, { round = round, offer = offer, counter = result.counter })
        end
    end

    -- Walkaway after round 3
    local walkResult = RmNegotiationEngine.evaluateWalkaway(sellerProfile, lastOffer, 3)
    if walkResult.action == "last_ditch_offer" then
        return {
            outcome = RmNegotiationEngine.OUTCOME_DEAL,
            mode = RmNegotiationEngine.MODE_LISTED_BUY,
            price = walkResult.price,
            rounds = 3,
            marketValue = marketValue,
            anchor = sellerProfile.listingPrice,
            reservation = sellerProfile.reservation,
            offers = offers,
        }
    end

    Log:trace("<<< negotiateListedBuy: failed")
    return {
        outcome = RmNegotiationEngine.OUTCOME_FAILED,
        mode = RmNegotiationEngine.MODE_LISTED_BUY,
        price = nil,
        rounds = 3,
        marketValue = marketValue,
        anchor = sellerProfile.listingPrice,
        reservation = sellerProfile.reservation,
        offers = offers,
    }
end

---@param preset string "easy"|"normal"|"hard"|"harder"|"realistic"
---@param strategy string "conservative"|"moderate"|"aggressive"|"greedy"
---@param marketValue number Current market price (must be > 0)
---@return table|nil result Full negotiation result, or nil on invalid input
function RmNegotiationEngine.negotiateUnlistedBuy(preset, strategy, marketValue)
    Log:trace(">>> negotiateUnlistedBuy(preset=%s, strategy=%s, marketValue=%s)",
        tostring(preset), tostring(strategy), tostring(marketValue))

    if not RmNegotiationEngine.isValidPreset(preset) then
        Log:warning("Invalid preset: %s", tostring(preset))
        return nil
    end
    if not RmNegotiationEngine.isValidStrategy(strategy, "buy") then
        Log:warning("Invalid buy strategy: %s", tostring(strategy))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local sellerProfile = RmNegotiationEngine.generateUnlistedSeller(preset, marketValue)
    if sellerProfile == nil then
        return nil
    end

    -- Dismissed
    if sellerProfile.dismissed then
        return {
            outcome = RmNegotiationEngine.OUTCOME_DISMISSED,
            mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
            price = nil,
            rounds = 0,
            marketValue = marketValue,
            anchor = nil,
            reservation = nil,
            offers = {},
        }
    end

    local strategyTable = RmNegotiationEngine.BUY_STRATEGIES[strategy]
    local offers = {}
    local offer = strategyTable.openingPct * sellerProfile.demandPrice
    local lastOffer = offer

    for round = 1, 3 do
        if round > 1 then
            offer = offer + strategyTable.increment * sellerProfile.demandPrice
        end
        lastOffer = offer

        local result = RmNegotiationEngine.evaluateOffer(sellerProfile, offer, round)

        if result.action == "accepted" or result.action == "converged_offer" then
            table.insert(offers, { round = round, offer = offer, counter = nil })
            return {
                outcome = RmNegotiationEngine.OUTCOME_DEAL,
                mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
                price = result.price,
                rounds = round,
                marketValue = marketValue,
                anchor = sellerProfile.demandPrice,
                reservation = sellerProfile.reservation,
                offers = offers,
            }
        elseif result.action == "rejected" then
            table.insert(offers, { round = round, offer = offer, counter = nil })
            return {
                outcome = RmNegotiationEngine.OUTCOME_REJECTED,
                mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
                price = nil,
                rounds = round,
                marketValue = marketValue,
                anchor = sellerProfile.demandPrice,
                reservation = sellerProfile.reservation,
                offers = offers,
            }
        else -- countered
            table.insert(offers, { round = round, offer = offer, counter = result.counter })
        end
    end

    -- Walkaway after round 3
    local walkResult = RmNegotiationEngine.evaluateWalkaway(sellerProfile, lastOffer, 3)
    if walkResult.action == "last_ditch_offer" then
        return {
            outcome = RmNegotiationEngine.OUTCOME_DEAL,
            mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
            price = walkResult.price,
            rounds = 3,
            marketValue = marketValue,
            anchor = sellerProfile.demandPrice,
            reservation = sellerProfile.reservation,
            offers = offers,
        }
    end

    Log:trace("<<< negotiateUnlistedBuy: failed")
    return {
        outcome = RmNegotiationEngine.OUTCOME_FAILED,
        mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
        price = nil,
        rounds = 3,
        marketValue = marketValue,
        anchor = sellerProfile.demandPrice,
        reservation = sellerProfile.reservation,
        offers = offers,
    }
end

---@param strategy string "conservative"|"moderate"|"aggressive"|"greedy"
---@param marketValue number Current market price (must be > 0)
---@return table|nil result Full negotiation result, or nil on invalid input
function RmNegotiationEngine.negotiateSell(strategy, marketValue)
    Log:trace(">>> negotiateSell(strategy=%s, marketValue=%s)", tostring(strategy), tostring(marketValue))

    if not RmNegotiationEngine.isValidStrategy(strategy, "sell") then
        Log:warning("Invalid sell strategy: %s", tostring(strategy))
        return nil
    end
    if type(marketValue) ~= "number" or marketValue <= 0 then
        Log:warning("Invalid marketValue: %s", tostring(marketValue))
        return nil
    end

    local sellStrategy = RmNegotiationEngine.SELL_STRATEGIES[strategy]
    local listingPrice = marketValue * (1 + sellStrategy.listingMarkup)
    local playerReservation = marketValue * sellStrategy.reservationPct
    local playerStubbornness = sellStrategy.stubbornness

    local buyerProfile = RmNegotiationEngine.generateNpcBuyer(listingPrice, marketValue)
    if buyerProfile == nil then
        return nil
    end

    local offers = {}
    local lastNpcOffer = buyerProfile.npcOpening
    local lastPlayerAsk = listingPrice

    for round = 1, 3 do
        local npcOffer
        if round == 1 then
            npcOffer = buyerProfile.npcOpening
        else
            npcOffer = lastNpcOffer
        end

        -- Round 1: check if NPC opening meets player reservation
        if round == 1 and npcOffer >= playerReservation then
            table.insert(offers, { round = round, npcOffer = npcOffer, playerAsk = nil })
            return {
                outcome = RmNegotiationEngine.OUTCOME_DEAL,
                mode = RmNegotiationEngine.MODE_SELL,
                price = npcOffer,
                rounds = round,
                marketValue = marketValue,
                anchor = listingPrice,
                reservation = playerReservation,
                offers = offers,
            }
        end

        -- Player counters using strategy formula
        local decay = RmNegotiationEngine.SELL.decay ^ (round - 1)
        local base = playerReservation + playerStubbornness * (listingPrice - playerReservation) * decay
        local noise = gaussianRandom(0, RmNegotiationEngine.SELL.counterNoise * listingPrice)
        local playerAsk = math.max(playerReservation, base + noise)
        lastPlayerAsk = playerAsk

        local result = RmNegotiationEngine.evaluatePlayerAsk(buyerProfile, playerAsk, round)

        if result.action == "accepted" or result.action == "converged_offer" then
            table.insert(offers, { round = round, npcOffer = npcOffer, playerAsk = playerAsk })
            return {
                outcome = RmNegotiationEngine.OUTCOME_DEAL,
                mode = RmNegotiationEngine.MODE_SELL,
                price = result.price,
                rounds = round,
                marketValue = marketValue,
                anchor = listingPrice,
                reservation = playerReservation,
                offers = offers,
            }
        elseif result.action == "npc_walked" then
            table.insert(offers, { round = round, npcOffer = npcOffer, playerAsk = playerAsk })
            return {
                outcome = RmNegotiationEngine.OUTCOME_NPC_WALKED,
                mode = RmNegotiationEngine.MODE_SELL,
                price = nil,
                rounds = round,
                marketValue = marketValue,
                anchor = listingPrice,
                reservation = playerReservation,
                offers = offers,
            }
        else -- countered
            table.insert(offers, { round = round, npcOffer = npcOffer, playerAsk = playerAsk })
            lastNpcOffer = result.npcOffer
        end
    end

    -- Walkaway after round 3
    local walkResult = RmNegotiationEngine.evaluateSellWalkaway(buyerProfile, lastNpcOffer, lastPlayerAsk, 3)
    if walkResult.action == "last_ditch_offer" then
        return {
            outcome = RmNegotiationEngine.OUTCOME_DEAL,
            mode = RmNegotiationEngine.MODE_SELL,
            price = walkResult.price,
            rounds = 3,
            marketValue = marketValue,
            anchor = listingPrice,
            reservation = playerReservation,
            offers = offers,
        }
    end

    Log:trace("<<< negotiateSell: failed")
    return {
        outcome = RmNegotiationEngine.OUTCOME_FAILED,
        mode = RmNegotiationEngine.MODE_SELL,
        price = nil,
        rounds = 3,
        marketValue = marketValue,
        anchor = listingPrice,
        reservation = playerReservation,
        offers = offers,
    }
end

Log:debug("NegotiationEngine module loaded")
