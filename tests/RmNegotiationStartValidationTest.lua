local scriptPath = arg and arg[0] or ""
local projectRoot = scriptPath:match("^(.*)/tests/[^/]+$") or "."

local logger = {}
setmetatable(logger, {
    __index = function()
        return function() end
    end,
})

RmLogging = {
    getLogger = function()
        return logger
    end,
}

Utils = {
    appendedFunction = function(original)
        return original
    end,
}

FarmlandManager = {
    setLandOwnership = function() end,
}

BaseMission = {
    loadMapFinished = function() end,
    delete = function() end,
}

local listed = true
local negotiateBuyEnabled = true
local unlistedOffersEnabled = true
local negotiateSellEnabled = true
local farmland = {
    id = 1,
    farmId = 0,
    price = 100000,
}

RmFmSettings = {
    getPresetName = function()
        return "normal"
    end,
    isNegotiateBuyEnabled = function()
        return negotiateBuyEnabled
    end,
    isUnlistedOffersEnabled = function()
        return unlistedOffersEnabled
    end,
    isNegotiateSellEnabled = function()
        return negotiateSellEnabled
    end,
}

RmFmAvailability = {
    isForSale = function()
        return listed
    end,
}

RmNegotiationEngine = {
    OUTCOME_DEAL = "deal",
    OUTCOME_REJECTED = "rejected",
    OUTCOME_FAILED = "failed",
    OUTCOME_DISMISSED = "dismissed",
    OUTCOME_NPC_WALKED = "npc_walked",
    MODE_LISTED_BUY = "listed_buy",
    MODE_UNLISTED_BUY = "unlisted_buy",
    MODE_SELL = "sell",
    SELL = {
        maxListingMultiplier = 2,
    },
    generateListedSeller = function(_, marketValue)
        return {
            anchorPrice = marketValue * 1.1,
            rejectFloor = marketValue * 0.8,
        }
    end,
    generateUnlistedSeller = function(_, marketValue)
        return {
            anchorPrice = marketValue * 1.3,
            rejectFloor = marketValue,
        }
    end,
    generateNpcBuyer = function(listingPrice)
        return {
            anchorPrice = listingPrice,
            rejectFloor = listingPrice * 0.8,
            npcOpening = listingPrice * 0.75,
        }
    end,
}

g_farmlandManager = {
    getFarmlandById = function(_, farmlandId)
        if farmlandId == farmland.id then
            return farmland
        end
        return nil
    end,
}

g_server = {}
g_client = nil

dofile(projectRoot .. "/scripts/RmNegotiationManager.lua")

local farmId = 7
local testsRun = 0

local function resetState()
    listed = true
    negotiateBuyEnabled = true
    unlistedOffersEnabled = true
    negotiateSellEnabled = true
    farmland.farmId = 0
    RmNegotiationManager.sessions = {}
    RmNegotiationManager.cooldowns = {}
    RmNegotiationManager.locks = {}
    RmNegotiationManager.sellerProfiles = {}
    RmNegotiationManager.pendingDeals = {}
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)), 2)
    end
end

local function test(name, body)
    resetState()
    local ok, message = pcall(body)
    if not ok then
        io.stderr:write(string.format("FAIL: %s\n%s\n", name, message))
        os.exit(1)
    end
    testsRun = testsRun + 1
end

local function assertRejected(startFunction, expectedReason)
    local snapshot, reason = startFunction()
    assertEqual(snapshot, nil, "rejected request returned a session")
    assertEqual(reason, expectedReason, "unexpected rejection reason")
    assertEqual(RmNegotiationManager.sessions[farmId], nil,
        "rejected request created a session")
    assertEqual(RmNegotiationManager.locks[farmland.id], nil,
        "rejected request locked the farmland")
end

test("listed negotiations respect the setting", function()
    negotiateBuyEnabled = false
    assertRejected(function()
        return RmNegotiationManager.startListedBuy(farmland.id, farmId)
    end, "listed_buy_disabled")
end)

test("listed negotiations require a listed field", function()
    listed = false
    assertRejected(function()
        return RmNegotiationManager.startListedBuy(farmland.id, farmId)
    end, "farmland_not_listed")
end)

test("unlisted offers respect the setting", function()
    listed = false
    unlistedOffersEnabled = false
    assertRejected(function()
        return RmNegotiationManager.startUnlistedBuy(farmland.id, farmId)
    end, "unlisted_offers_disabled")
end)

test("unlisted offers require an unlisted field", function()
    listed = true
    assertRejected(function()
        return RmNegotiationManager.startUnlistedBuy(farmland.id, farmId)
    end, "farmland_is_listed")
end)

test("sale negotiations respect the setting", function()
    farmland.farmId = farmId
    negotiateSellEnabled = false
    assertRejected(function()
        return RmNegotiationManager.startSell(farmland.id, farmId, farmland.price)
    end, "sell_negotiation_disabled")
end)

test("listed negotiations still start when allowed", function()
    local snapshot, reason = RmNegotiationManager.startListedBuy(farmland.id, farmId)
    assertEqual(reason, nil, "allowed listed negotiation was rejected")
    assertEqual(snapshot.mode, RmNegotiationEngine.MODE_LISTED_BUY,
        "listed negotiation used the wrong mode")
end)

test("unlisted negotiations still start when allowed", function()
    listed = false
    local snapshot, reason = RmNegotiationManager.startUnlistedBuy(farmland.id, farmId)
    assertEqual(reason, nil, "allowed unlisted negotiation was rejected")
    assertEqual(snapshot.mode, RmNegotiationEngine.MODE_UNLISTED_BUY,
        "unlisted negotiation used the wrong mode")
end)

test("sale negotiations still start when allowed", function()
    farmland.farmId = farmId
    local snapshot, reason =
        RmNegotiationManager.startSell(farmland.id, farmId, farmland.price)
    assertEqual(reason, nil, "allowed sale negotiation was rejected")
    assertEqual(snapshot.mode, RmNegotiationEngine.MODE_SELL,
        "sale negotiation used the wrong mode")
end)

io.write(string.format("PASS: %d negotiation start validation tests\n", testsRun))
