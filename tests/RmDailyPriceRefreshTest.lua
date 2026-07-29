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

local function noOp() end

Utils = {
    overwrittenFunction = function(original, replacement)
        return function(self, ...)
            return replacement(self, original, ...)
        end
    end,
    appendedFunction = function(original)
        return original
    end,
    getNoNil = function(value, fallback)
        if value == nil then return fallback end
        return value
    end,
}

Farmland = {
    updatePrice = function(self)
        self.price = self.basePrice
    end,
}
FarmlandManager = {
    NO_OWNER_FARM_ID = 0,
    getPricePerHa = noOp,
    setLandOwnership = noOp,
}
FarmlandStateEvent = { run = noOp }
InGameMenuMapFrame = {
    ACTIONS = { BUY = 1, SELL = 2 },
    setMapInputContext = noOp,
    populateCellForItemInSection = noOp,
}
InGameMenuMapUtil = { showContextBox = noOp }
FarmlandHotspot = { updateColors = noOp }
MapOverlayGenerator = {
    buildFarmlandsMapOverlay = noOp,
    buildSingleFarmlandsMapOverlay = noOp,
}
BaseMission = {
    loadMapFinished = noOp,
    delete = noOp,
}
FSBaseMission = {
    onStartMission = noOp,
    sendInitialClientState = noOp,
}
Mission00 = { loadItemsFinished = noOp }
FSCareerMissionInfo = { saveToXMLFile = noOp }

g_currentModDirectory = projectRoot .. "/"
g_currentModName = "FS25_FarmlandMarket"
g_modManager = {
    getModByName = function()
        return { version = "test" }
    end,
}

FruitType = { UNKNOWN = 0 }
EconomyManager = {
    getFillTypeSeasonalFactor = function()
        return 1
    end,
}

local growthState = 1
local fieldState = {
    isValid = true,
    fruitTypeIndex = 1,
    getHarvestScaleMultiplier = function()
        return 1
    end,
}
local field = {
    getFieldState = function()
        fieldState.growthState = growthState
        return fieldState
    end,
    getAreaHa = function()
        return 1
    end,
}
local farmland = {
    id = 1,
    farmId = 0,
    basePrice = 100000,
    price = 100000,
    fixedPrice = nil,
    getField = function()
        return field
    end,
}
setmetatable(farmland, { __index = Farmland })

g_fruitTypeManager = {
    getFruitTypeByIndex = function()
        return {
            name = "wheat",
            maxHarvestingGrowthState = 4,
            literPerSqm = 1,
        }
    end,
    getFillTypeByFruitTypeIndex = function()
        return {
            name = "wheat",
            pricePerLiter = 1,
        }
    end,
}

local calls = {}
local expectedPriceAtAvailability = nil
local function record(name)
    calls[#calls + 1] = name
end

g_currentMission = {
    economyManager = {},
    environment = {
        currentDay = 2,
        currentPeriod = 6,
    },
    mapHotspots = {
        {
            getFarmland = noOp,
            updateColors = function()
                record("display")
            end,
        },
    },
}

g_farmlandManager = {
    getFarmlands = function()
        return { [farmland.id] = farmland }
    end,
}

g_inGameMenu = nil
local server = {
    broadcastEvent = function()
        record("broadcast")
    end,
}
g_server = server

RmFmSettings = {
    getCustomPricePerHa = function()
        return 0
    end,
    isAvailabilityEnabled = function()
        return true
    end,
}
RmFmAvailability = {
    availability = {},
    evaluateDaily = function()
        if expectedPriceAtAvailability ~= nil
            and math.abs(farmland.price - expectedPriceAtAvailability) > 0.01 then
            error("availability evaluation ran before the farmland price refresh")
        end
        record("availability")
    end,
    isForSale = function()
        return true
    end,
    isEligibleForAvailability = function()
        return true
    end,
    hasPositiveMarketValue = function()
        return true
    end,
    reset = noOp,
}
RmNegotiationManager = {
    pendingDeals = {},
    invalidateSellerProfiles = function()
        record("profiles_refreshed")
    end,
    ensureListedProfiles = function()
        record("profiles_kept")
    end,
    getListingPrice = function()
        return nil
    end,
}
RmAvailabilitySyncEvent = {
    new = function()
        return {}
    end,
}
RmWatchlistUI = {
    watched = {},
    notifyForSaleTransitions = noOp,
    _localFarmId = function()
        return nil
    end,
    replaceFromSync = noOp,
}
RmWatchlistStore = {
    reset = noOp,
    pruneStaleSubset = function()
        return {}
    end,
    sendInitialClientState = noOp,
}
RmNegotiationDialog = {
    getInstance = function()
        return nil
    end,
}

dofile(projectRoot .. "/scripts/RmFarmlandMarket.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)), 2)
    end
end

local function assertSequence(expected)
    assertEqual(#calls, #expected, "unexpected number of calls")
    for i, name in ipairs(expected) do
        assertEqual(calls[i], name, "unexpected call at position " .. i)
    end
end

local testsRun = 0
local function test(name, body)
    calls = {}
    local ok, message = pcall(body)
    if not ok then
        io.stderr:write(string.format("FAIL: %s\n%s\n", name, message))
        os.exit(1)
    end
    testsRun = testsRun + 1
end

-- Establish the previous day's crop-adjusted price.
RmFarmlandMarket.updateAllFarmlandPrices()

test("server refreshes prices before market state and sync", function()
    growthState = 2
    expectedPriceAtAvailability = 105000
    RmFarmlandMarket.onDayChanged()
    expectedPriceAtAvailability = nil

    assertEqual(farmland.price, 105000,
        "farmland price did not include the latest crop growth")
    assertSequence({
        "availability",
        "profiles_refreshed",
        "broadcast",
        "display",
    })
end)

test("unchanged prices keep existing seller profiles", function()
    expectedPriceAtAvailability = 105000
    RmFarmlandMarket.onDayChanged()
    expectedPriceAtAvailability = nil

    assertSequence({
        "availability",
        "profiles_kept",
        "broadcast",
        "display",
    })
end)

test("server removes harvested crop value", function()
    growthState = 0
    expectedPriceAtAvailability = 100000
    RmFarmlandMarket.onDayChanged()
    expectedPriceAtAvailability = nil

    assertEqual(farmland.price, 100000,
        "farmland price kept stale crop value after harvest")
    assertSequence({
        "availability",
        "profiles_refreshed",
        "broadcast",
        "display",
    })
end)

test("clients refresh local prices and display", function()
    g_server = nil
    growthState = 3
    RmFarmlandMarket.onDayChanged()

    assertEqual(farmland.price, 107500,
        "client price did not include the latest crop growth")
    assertSequence({ "display" })
end)

io.write(string.format("PASS: %d daily price refresh tests\n", testsRun))
