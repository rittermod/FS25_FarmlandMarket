--[[
    RmFmAvailability.lua
    Availability system for FarmlandMarket.

    Manages:
    - Availability state per farmland (isForSale, expiryDay, listingDay)
    - Initial randomization on new save
    - Daily evaluation (expire + new listings)
    - Savegame persistence
    - Network sync to clients

    Server-authoritative: only the server maintains the true state.
    Clients receive sync events and mirror the state locally.

    Author: Ritter
]]

RmFmAvailability = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- PRESETS
-- ============================================================================

--- Difficulty presets. Base values at DPP=1; scaled at runtime.
--- Durations are in game-days at DPP=1 (i.e., months at DPP=1).
RmFmAvailability.PRESETS = {
    easy = {
        name              = "easy",
        initialChance     = 0.40,
        dailyChance       = 0.20,
        durationMin       = 3,
        durationMax       = 14,
        relistChance      = 0,
        relistDurationMin = 0,
        relistDurationMax = 0,
        seasonalMultiplier = 1.3,
    },
    normal = {
        name              = "normal",
        initialChance     = 0.15,
        dailyChance       = 0.10,
        durationMin       = 3,
        durationMax       = 7,
        relistChance      = 0,
        relistDurationMin = 0,
        relistDurationMax = 0,
        seasonalMultiplier = 1.5,
    },
    hard = {
        name              = "hard",
        initialChance     = 0.05,
        dailyChance       = 0.04,
        durationMin       = 2,
        durationMax       = 6,
        relistChance      = 0,
        relistDurationMin = 0,
        relistDurationMax = 0,
        seasonalMultiplier = 2.0,
    },
    harder = {
        name              = "harder",
        initialChance     = 0.03,
        dailyChance       = 0.02,
        durationMin       = 2,
        durationMax       = 6,
        relistChance      = 0,
        relistDurationMin = 0,
        relistDurationMax = 0,
        seasonalMultiplier = 2.5,
    },
    realistic = {
        name              = "realistic",
        initialChance     = 0.00,
        dailyChance       = 0.002,
        durationMin       = 3,
        durationMax       = 8,
        relistChance      = 0.70,
        relistDurationMin = 3,
        relistDurationMax = 8,
        seasonalMultiplier = 3.0,
    },
}

--- Ordered list for UI cycling and state indexing. Index 1 = "off".
RmFmAvailability.PRESET_ORDER = { "off", "easy", "normal", "hard", "harder", "realistic" }

--- Selling season months (Nov-Mar): higher listing chance during these months.
RmFmAvailability.SELLING_SEASON = { [1]=true, [2]=true, [3]=true, [11]=true, [12]=true }

-- ============================================================================
-- STATE
-- ============================================================================

--- Availability table: { [farmlandId] = {isForSale, expiryDay, listingDay} }
RmFmAvailability.availability = {}

--- Saved rows whose farmland ID is not present on the current map.
--- Kept out of live evaluation and client sync, but written back to the
--- savegame in case a later map update restores the farmland.
RmFmAvailability._unmatchedAvailability = {}

--- One-shot per-mission flag for the watchlist for-sale notification path.
--- The first RmAvailabilitySyncEvent:run a client receives delivers the
--- current full availability state, which by definition lists every
--- currently-for-sale parcel. Without this gate, every watched + currently-
--- listed farmland would generate a notification at join. Reset to false
--- on BaseMission.delete so reconnect starts fresh.
RmFmAvailability._initialSyncSeen = false

local MAX_SAVED_DAY = 2147483647

--- Normalize a persisted farmland ID.
---@param value any
---@return number|nil farmlandId
local function normalizeFarmlandId(value)
    local farmlandId = tonumber(value)
    if farmlandId == nil
        or farmlandId ~= farmlandId
        or farmlandId < 1
        or farmlandId > MAX_SAVED_DAY
        or farmlandId ~= math.floor(farmlandId) then
        return nil
    end
    return farmlandId
end

--- Normalize a persisted day value for comparisons and INT serialization.
---@param value any
---@return number day
local function normalizeSavedDay(value)
    local day = tonumber(value)
    if day == nil or day ~= day or day < 0 then
        return 0
    end
    return math.min(math.floor(day), MAX_SAVED_DAY)
end

--- Return a complete availability entry from persisted or runtime data.
---@param entry table|nil
---@return table normalized
local function normalizeAvailabilityEntry(entry)
    entry = type(entry) == "table" and entry or {}
    local isForSale = entry.isForSale == true
    local expiryDay = normalizeSavedDay(entry.expiryDay)
    local listingDay = normalizeSavedDay(entry.listingDay)

    if not isForSale then
        expiryDay = 0
        listingDay = 0
    end

    return {
        isForSale = isForSale,
        expiryDay = expiryDay,
        listingDay = listingDay,
    }
end

-- ============================================================================
-- CORE LOGIC
-- ============================================================================

--- Single source of truth for "FM treats this farmland as priced".
--- Used by isEligibleForAvailability AND directly by sell-side paths
--- (sell intercepts player-owned land which eligibility excludes by design).
--- Kept cheap: called from hot UI paths (button relabel on context change,
--- watchlist recompute) so it does no logging and no allocations.
---@param farmland table|nil Farmland object
---@return boolean hasPositivePrice
function RmFmAvailability.hasPositiveMarketValue(farmland)
    return type(farmland) == "table"
        and type(farmland.price) == "number"
        and farmland.price > 0
end

--- Check if a farmland is eligible for the availability system
---@param farmland table Farmland object
---@return boolean eligible
function RmFmAvailability.isEligibleForAvailability(farmland)
    return farmland.farmId == FarmlandManager.NO_OWNER_FARM_ID
        and RmFmAvailability.hasPositiveMarketValue(farmland)
end

--- Check if a farmland is available for purchase
--- This is the single source of truth for availability checks.
---@param farmlandId number Farmland ID
---@return boolean isForSale
function RmFmAvailability.isForSale(farmlandId)
    Log:trace(">>> isForSale(farmlandId=%d)", farmlandId)

    -- If availability is disabled, all fields are for sale
    if not RmFmSettings.isAvailabilityEnabled() then
        Log:trace("<<< isForSale = true (availability disabled)")
        return true
    end

    -- Get farmland object
    local farmland = g_farmlandManager:getFarmlands()[farmlandId]
    if farmland == nil then
        Log:trace("<<< isForSale = true (farmland not found, safe default)")
        return true
    end

    -- Player-owned farmlands are always "available" (not blocked)
    if not RmFmAvailability.isEligibleForAvailability(farmland) then
        Log:trace("<<< isForSale = true (player-owned, not in availability pool)")
        return true
    end

    -- Check availability table
    local entry = RmFmAvailability.availability[farmlandId]
    if entry == nil then
        -- Not in table = safe default (allow purchase)
        Log:trace("<<< isForSale = true (not in availability table, safe default)")
        return true
    end

    Log:trace("<<< isForSale = %s", tostring(entry.isForSale))
    return entry.isForSale == true
end

--- Get current day from environment
---@return number currentDay
local function getCurrentDay()
    return g_currentMission.environment.currentDay
end

--- Get the active preset table, or nil if availability is "off".
---@return table|nil preset
function RmFmAvailability.getActivePreset()
    local presetName = RmFmSettings.getPresetName()
    if presetName == "off" then
        return nil
    end
    return RmFmAvailability.PRESETS[presetName]
end

--- Check if current period is a selling season month.
---@return boolean isSellingSeason
local function isSellingSeasonMonth()
    return RmFmAvailability.SELLING_SEASON[g_currentMission.environment.currentPeriod] == true
end

--- Get current days-per-period from game environment.
---@return number dpp
local function getDaysPerPeriod()
    return g_currentMission.environment.daysPerPeriod
end

--- Reconcile loaded availability rows with the farmlands on the current map.
--- Missing current farmlands start unlisted and join the normal daily rolls.
--- Unknown saved IDs remain preserved, but stay out of live state and sync.
function RmFmAvailability.reconcileWithCurrentFarmlands()
    Log:trace(">>> reconcileWithCurrentFarmlands()")

    if g_server == nil then
        Log:trace("<<< reconcileWithCurrentFarmlands() [not server]")
        return
    end

    local currentById = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        currentById[farmland.id] = farmland
    end

    local reconciled = {}
    local unmatched = {}
    local seen = {}
    local seeded = 0
    local dropped = 0
    local preserved = 0

    local function reconcileSavedEntry(savedId, entry)
        local farmlandId = normalizeFarmlandId(savedId)
        if farmlandId == nil or seen[farmlandId] then
            return
        end
        seen[farmlandId] = true

        local normalized = normalizeAvailabilityEntry(entry)
        local farmland = currentById[farmlandId]
        if farmland == nil then
            unmatched[farmlandId] = normalized
            preserved = preserved + 1
        elseif RmFmAvailability.isEligibleForAvailability(farmland) then
            reconciled[farmlandId] = normalized
        else
            dropped = dropped + 1
        end
    end

    for farmlandId, entry in pairs(RmFmAvailability.availability) do
        reconcileSavedEntry(farmlandId, entry)
    end
    for farmlandId, entry in pairs(RmFmAvailability._unmatchedAvailability) do
        reconcileSavedEntry(farmlandId, entry)
    end

    for farmlandId, farmland in pairs(currentById) do
        if RmFmAvailability.isEligibleForAvailability(farmland)
            and reconciled[farmlandId] == nil then
            reconciled[farmlandId] = {
                isForSale = false,
                expiryDay = 0,
                listingDay = 0,
            }
            seeded = seeded + 1
        end
    end

    RmFmAvailability.availability = reconciled
    RmFmAvailability._unmatchedAvailability = unmatched

    Log:info("Availability state reconciled: %d added, %d ineligible removed, %d unmatched preserved",
        seeded, dropped, preserved)
    Log:trace("<<< reconcileWithCurrentFarmlands()")
end

--- Initialize availability system (called on mission start if no saved state)
function RmFmAvailability.initialize()
    Log:trace(">>> initialize()")

    -- Only run on server
    if g_server == nil then
        Log:trace("<<< initialize() [not server]")
        return
    end

    -- Reconcile partial saved state after all farmland prices are available.
    if next(RmFmAvailability.availability) ~= nil
        or next(RmFmAvailability._unmatchedAvailability) ~= nil then
        RmFmAvailability.reconcileWithCurrentFarmlands()
        Log:debug("AVAIL: Availability restored from savegame")
        Log:trace("<<< initialize() [restored]")
        return
    end

    local preset = RmFmAvailability.getActivePreset()
    if preset == nil then
        Log:debug("AVAIL: Availability is off, skipping initialization")
        Log:trace("<<< initialize() [off]")
        return
    end

    local currentDay = getCurrentDay()
    local dpp = getDaysPerPeriod()
    local eligibleFarmlands = {}
    local availableCount = 0

    -- DPP-scaled max duration for initial variety
    local durMax = preset.durationMax * dpp

    Log:debug("AVAIL: Initializing with preset=%s, initialChance=%.3f, durMax=%d (DPP=%d)",
        preset.name, preset.initialChance, durMax, dpp)

    -- Collect eligible farmlands
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            table.insert(eligibleFarmlands, farmland)
        end
    end

    if #eligibleFarmlands == 0 then
        Log:warning("No eligible farmlands found on this map")
        Log:trace("<<< initialize() [no eligible farmlands]")
        return
    end

    -- Randomize initial availability using preset's initialChance
    for _, farmland in ipairs(eligibleFarmlands) do
        local isForSale = math.random() < preset.initialChance

        if isForSale then
            -- Use range 1..durMax for early variety (stagger expiry times)
            local expiryDays = math.random(1, durMax)
            RmFmAvailability.availability[farmland.id] = {
                isForSale = true,
                expiryDay = currentDay + expiryDays,
                listingDay = currentDay,
            }
            availableCount = availableCount + 1
            Log:debug("AVAIL: Farmland %d listed for %d days (expires day %d)",
                farmland.id, expiryDays, currentDay + expiryDays)
        else
            RmFmAvailability.availability[farmland.id] = {
                isForSale = false,
                expiryDay = 0,
                listingDay = 0,
            }
            Log:trace("  AVAIL: Farmland %d not for sale initially", farmland.id)
        end
    end

    Log:info("Initialized availability (%s preset): %d eligible farmlands, %d for sale (DPP=%d)",
        preset.name, #eligibleFarmlands, availableCount, dpp)
    Log:trace("<<< initialize()")
end

--- Daily evaluation: expire/relist, add new listings, sync clients.
--- Also auto-initializes if availability table is empty (handles off->preset switch mid-game).
function RmFmAvailability.evaluateDaily()
    Log:trace(">>> evaluateDaily()")

    -- Server only
    if g_server == nil then
        Log:trace("<<< evaluateDaily() [not server]")
        return
    end

    local preset = RmFmAvailability.getActivePreset()
    if preset == nil then
        Log:trace("<<< evaluateDaily() [off]")
        return
    end

    -- Auto-initialize if table is empty (e.g., preset changed from "off" to active mid-game)
    if next(RmFmAvailability.availability) == nil then
        Log:info("Availability table empty with active preset - running initialization")
        RmFmAvailability.initialize()
    end

    local currentDay = getCurrentDay()
    local dpp = getDaysPerPeriod()
    local expiredCount = 0
    local relistedCount = 0
    local newlyListedCount = 0
    local forSaleCount = 0

    -- DPP-scaled parameters
    local chance = preset.dailyChance / dpp
    if isSellingSeasonMonth() then
        chance = chance * preset.seasonalMultiplier
    end
    local durMin = preset.durationMin * dpp
    local durMax = preset.durationMax * dpp

    Log:debug("AVAIL: DPP=%d, chance=%.6f%s, durRange=%d-%d",
        dpp, chance, isSellingSeasonMonth() and " (selling season)" or "", durMin, durMax)

    -- Collect eligible farmlands
    local eligibleFarmlands = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            table.insert(eligibleFarmlands, farmland)
        end
    end

    -- Step 1: Expire listings (with relist for presets that support it)
    for farmlandId, entry in pairs(RmFmAvailability.availability) do
        if entry.isForSale and entry.expiryDay <= currentDay then
            if preset.relistChance > 0 and math.random() < preset.relistChance then
                -- Relist: extend with new DPP-scaled duration
                local rDurMin = preset.relistDurationMin * dpp
                local rDurMax = preset.relistDurationMax * dpp
                entry.expiryDay = currentDay + math.random(rDurMin, rDurMax)
                relistedCount = relistedCount + 1
                Log:debug("AVAIL: Farmland %d relisted (new expiry day %d)",
                    farmlandId, entry.expiryDay)
            else
                -- Remove listing
                entry.isForSale = false
                entry.expiryDay = 0
                entry.listingDay = 0
                expiredCount = expiredCount + 1
                Log:debug("AVAIL: Farmland %d expired", farmlandId)
            end
        end
    end

    -- Step 2: Roll new listings for unavailable fields
    for _, farmland in ipairs(eligibleFarmlands) do
        local entry = RmFmAvailability.availability[farmland.id]
        if entry ~= nil and not entry.isForSale then
            if math.random() < chance then
                local expiryDays = math.random(durMin, durMax)
                entry.isForSale = true
                entry.listingDay = currentDay
                entry.expiryDay = currentDay + expiryDays
                newlyListedCount = newlyListedCount + 1
                Log:debug("AVAIL: Farmland %d listed for %d days (expires day %d)",
                    farmland.id, expiryDays, entry.expiryDay)
            end
        end
    end

    -- Step 3: Count current available
    for _, entry in pairs(RmFmAvailability.availability) do
        if entry.isForSale then
            forSaleCount = forSaleCount + 1
        end
    end

    if relistedCount > 0 then
        Log:info("Daily (%s): %d expired, %d relisted, %d new, %d total for sale",
            preset.name, expiredCount, relistedCount, newlyListedCount, forSaleCount)
    else
        Log:info("Daily (%s): %d expired, %d new, %d total for sale",
            preset.name, expiredCount, newlyListedCount, forSaleCount)
    end

    -- Caller is responsible for: (1) populating entry.listingPrice via
    -- ensureListedProfiles before (2) broadcasting the sync event and
    -- (3) refreshing hotspot colors. Doing the broadcast here would ship a
    -- payload missing prices for the parcels just listed in step 2.

    Log:trace("<<< evaluateDaily()")
end

-- ============================================================================
-- PERSISTENCE
-- ============================================================================

--- Load availability state from savegame XML (server only)
---@param xmlFile table Already-opened XMLFile handle
function RmFmAvailability.loadFromXMLFile(xmlFile)
    Log:trace(">>> loadFromXMLFile()")

    if g_server == nil then
        Log:trace("<<< loadFromXMLFile() [not server]")
        return
    end

    RmFmAvailability.availability = {}
    RmFmAvailability._unmatchedAvailability = {}

    local key = "rmFarmlandMarket.availability"
    local i = 0
    local invalid = 0
    local unmatched = 0
    while true do
        local entryKey = string.format("%s.farmland(%d)", key, i)
        if not xmlFile:hasProperty(entryKey) then
            break
        end

        local farmlandId = normalizeFarmlandId(xmlFile:getValue(entryKey .. "#id"))
        local entry = normalizeAvailabilityEntry({
            isForSale = xmlFile:getValue(entryKey .. "#isForSale"),
            expiryDay = xmlFile:getValue(entryKey .. "#expiryDay"),
            listingDay = xmlFile:getValue(entryKey .. "#listingDay"),
        })

        if farmlandId == nil then
            invalid = invalid + 1
            Log:warning("AVAIL: Ignoring saved availability row %d with an invalid farmland ID", i)
        elseif g_farmlandManager:getFarmlandById(farmlandId) == nil then
            RmFmAvailability._unmatchedAvailability[farmlandId] = entry
            unmatched = unmatched + 1
            Log:debug("AVAIL: Preserving saved row for unmatched farmland %d", farmlandId)
        else
            -- Eligibility is checked later by initialize(), after crop value
            -- has been added to farmland prices.
            RmFmAvailability.availability[farmlandId] = entry
            Log:trace("  AVAIL: Loaded farmland %d: isForSale=%s expiryDay=%d listingDay=%d",
                farmlandId, tostring(entry.isForSale), entry.expiryDay, entry.listingDay)
        end

        i = i + 1
    end

    local activeCount = 0
    local forSaleCount = 0
    for _, entry in pairs(RmFmAvailability.availability) do
        activeCount = activeCount + 1
        if entry.isForSale then
            forSaleCount = forSaleCount + 1
        end
    end

    Log:info("Availability state loaded: %d current farmlands (%d for sale), %d unmatched preserved, %d invalid skipped",
        activeCount, forSaleCount, unmatched, invalid)
    Log:trace("<<< loadFromXMLFile()")
end

--- Save availability state to savegame XML
---@param xmlFile table Already-opened XMLFile handle
function RmFmAvailability.saveToXMLFile(xmlFile)
    Log:trace(">>> saveToXMLFile()")

    -- Server only
    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local key = "rmFarmlandMarket.availability"
    local i = 0
    local skipped = 0
    local seen = {}

    local function saveEntries(entries)
        for savedId, entry in pairs(entries) do
            local farmlandId = normalizeFarmlandId(savedId)
            if farmlandId == nil or seen[farmlandId] then
                skipped = skipped + 1
                Log:warning("AVAIL: Skipping invalid or duplicate availability row during save")
            else
                seen[farmlandId] = true
                local normalized = normalizeAvailabilityEntry(entry)
                local entryKey = string.format("%s.farmland(%d)", key, i)
                xmlFile:setValue(entryKey .. "#id", farmlandId)
                xmlFile:setValue(entryKey .. "#isForSale", normalized.isForSale)
                xmlFile:setValue(entryKey .. "#expiryDay", normalized.expiryDay)
                xmlFile:setValue(entryKey .. "#listingDay", normalized.listingDay)
                Log:trace("  AVAIL: Saved farmland %d: isForSale=%s expiryDay=%d listingDay=%d",
                    farmlandId, tostring(normalized.isForSale),
                    normalized.expiryDay, normalized.listingDay)
                i = i + 1
            end
        end
    end

    saveEntries(RmFmAvailability.availability)
    saveEntries(RmFmAvailability._unmatchedAvailability)

    Log:debug("AVAIL: Saved %d availability entries (%d skipped)", i, skipped)
    Log:debug("Availability state saved")
    Log:trace("<<< saveToXMLFile()")
end

-- ============================================================================
-- MULTIPLAYER SYNC
-- ============================================================================

--- Send initial availability state to joining client
---@param connection table Client connection
function RmFmAvailability.sendInitialClientState(connection)
    Log:trace(">>> sendInitialClientState()")

    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local count = 0
    for _ in pairs(RmFmAvailability.availability) do
        count = count + 1
    end

    Log:debug("SYNC: Sending initial availability to joining client (%d entries)", count)
    connection:sendEvent(RmAvailabilitySyncEvent.new())

    Log:trace("<<< sendInitialClientState()")
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

--- Reset availability state (called on map delete)
function RmFmAvailability.reset()
    Log:trace(">>> reset()")
    RmFmAvailability.availability = {}
    RmFmAvailability._unmatchedAvailability = {}
    Log:debug("AVAIL: Availability state cleared")
    Log:trace("<<< reset()")
end

Log:debug("RmFmAvailability module loaded")
