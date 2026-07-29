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

FarmlandManager = {
    NO_OWNER_FARM_ID = 0,
}

RmFmSettings = {
    isAvailabilityEnabled = function()
        return true
    end,
    getPresetName = function()
        return "normal"
    end,
}

local farmlands = {
    [1] = { id = 1, farmId = 0, price = 100000 },
    [2] = { id = 2, farmId = 0, price = 120000 },
    [3] = { id = 3, farmId = 0, price = 90000 },
    [4] = { id = 4, farmId = 2, price = 110000 },
}

g_farmlandManager = {
    getFarmlands = function()
        return farmlands
    end,
    getFarmlandById = function(_, farmlandId)
        return farmlands[farmlandId]
    end,
}

g_currentMission = {
    environment = {
        currentDay = 20,
        currentPeriod = 6,
        daysPerPeriod = 1,
    },
}

g_server = {}

dofile(projectRoot .. "/scripts/RmFmAvailability.lua")

local testsRun = 0

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)), 2)
    end
end

local function assertPresent(value, message)
    if value == nil then
        error(message, 2)
    end
end

local function test(name, body)
    RmFmAvailability.reset()
    local ok, message = pcall(body)
    if not ok then
        io.stderr:write(string.format("FAIL: %s\n%s\n", name, message))
        os.exit(1)
    end
    testsRun = testsRun + 1
end

local function makeLoadXml(rows)
    return {
        hasProperty = function(_, key)
            local index = tonumber(key:match("farmland%((%d+)%)$"))
            return index ~= nil and rows[index + 1] ~= nil
        end,
        getValue = function(_, key)
            local index = tonumber(key:match("farmland%((%d+)%)"))
            local attribute = key:match("#(.+)$")
            local row = index ~= nil and rows[index + 1] or nil
            return row ~= nil and row[attribute] or nil
        end,
    }
end

local function makeSaveXml()
    local values = {}
    return {
        values = values,
        setValue = function(_, key, value)
            if value == nil then
                error("save attempted to write a nil value for " .. key)
            end
            values[key] = value
        end,
    }
end

local function savedRowsById(values)
    local rows = {}
    for key, value in pairs(values) do
        local index = tonumber(key:match("farmland%((%d+)%)"))
        local attribute = key:match("#(.+)$")
        if index ~= nil and attribute ~= nil then
            rows[index] = rows[index] or {}
            rows[index][attribute] = value
        end
    end

    local byId = {}
    for _, row in pairs(rows) do
        byId[row.id] = row
    end
    return byId
end

test("load fills missing values with safe defaults", function()
    local xmlFile = makeLoadXml({
        { id = 1, isForSale = true, listingDay = 12 },
        { id = 2, expiryDay = 25, listingDay = 10 },
    })

    RmFmAvailability.loadFromXMLFile(xmlFile)

    assertEqual(RmFmAvailability.availability[1].isForSale, true,
        "listed state was not retained")
    assertEqual(RmFmAvailability.availability[1].expiryDay, 0,
        "missing expiry day did not default to zero")
    assertEqual(RmFmAvailability.availability[2].isForSale, false,
        "missing listed state did not default to false")
    assertEqual(RmFmAvailability.availability[2].expiryDay, 0,
        "unlisted expiry day was not cleared")
    assertEqual(RmFmAvailability.availability[2].listingDay, 0,
        "unlisted listing day was not cleared")
    assertEqual(RmFmAvailability.isForSale(2), false,
        "unlisted state did not remain a boolean")

    -- The next daily evaluation must be able to compare every loaded row.
    RmFmAvailability.initialize()
    RmFmAvailability.evaluateDaily()
end)

test("reconciliation adds current fields and quarantines unmatched rows", function()
    local xmlFile = makeLoadXml({
        { id = 1, isForSale = true, expiryDay = 24, listingDay = 12 },
        { id = 4, isForSale = true, expiryDay = 30, listingDay = 15 },
        { id = 99, isForSale = true, expiryDay = 40, listingDay = 18 },
        { isForSale = true, expiryDay = 40, listingDay = 18 },
    })

    RmFmAvailability.loadFromXMLFile(xmlFile)
    RmFmAvailability.initialize()

    assertPresent(RmFmAvailability.availability[1],
        "saved current farmland was removed")
    assertPresent(RmFmAvailability.availability[2],
        "missing current farmland was not added")
    assertPresent(RmFmAvailability.availability[3],
        "second missing current farmland was not added")
    assertEqual(RmFmAvailability.availability[2].isForSale, false,
        "newly added farmland should start unlisted")
    assertEqual(RmFmAvailability.availability[4], nil,
        "player-owned farmland was not removed")
    assertEqual(RmFmAvailability.availability[99], nil,
        "unmatched farmland leaked into live state")
    assertPresent(RmFmAvailability._unmatchedAvailability[99],
        "unmatched farmland was not preserved")
end)

test("save writes complete current and unmatched rows", function()
    RmFmAvailability.availability = {
        [1] = { isForSale = true, listingDay = 12 },
        [2] = { isForSale = false, expiryDay = 25, listingDay = 10 },
    }
    RmFmAvailability._unmatchedAvailability = {
        [99] = { isForSale = true },
    }

    local xmlFile = makeSaveXml()
    RmFmAvailability.saveToXMLFile(xmlFile)
    local saved = savedRowsById(xmlFile.values)

    assertEqual(saved[1].expiryDay, 0,
        "current row did not receive a default expiry day")
    assertEqual(saved[2].expiryDay, 0,
        "unlisted current row kept an expiry day")
    assertEqual(saved[2].listingDay, 0,
        "unlisted current row kept a listing day")
    assertEqual(saved[99].isForSale, true,
        "unmatched row was not written back")
    assertEqual(saved[99].expiryDay, 0,
        "unmatched row did not receive a default expiry day")
end)

io.write(string.format("PASS: %d availability persistence tests\n", testsRun))
