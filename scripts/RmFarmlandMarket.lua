--[[
    RmFarmlandMarket.lua
    Main module for FarmlandMarket mod.
    Contains all mod logic, state, and game integration hooks.
]]

-- Module declaration
RmFarmlandMarket = {}
RmFarmlandMarket.modDirectory = g_currentModDirectory
RmFarmlandMarket.modName = g_currentModName

-- Module constants
RmFarmlandMarket.DEFAULT_PRICE_PER_HA = nil -- nil = use game default
RmFarmlandMarket.isColorBlindMode = false -- updated in onLoadMapFinished

-- Hotspot colors: boolean-keyed [false]=normal, [true]=colorBlind (FS25 pattern)
RmFarmlandMarket.COLOR_FOR_SALE = {}
RmFarmlandMarket.COLOR_FOR_SALE[false] = {0.10, 0.22, 0.01, 1}           -- green
RmFarmlandMarket.COLOR_FOR_SALE[true]  = {0.0423, 0.2502, 0.8069, 1}     -- blue (CB)

RmFarmlandMarket.COLOR_NOT_FOR_SALE = {}
RmFarmlandMarket.COLOR_NOT_FOR_SALE[false] = {0.4, 0.05, 0.05, 1}        -- red
RmFarmlandMarket.COLOR_NOT_FOR_SALE[true]  = {0.9473, 0.5271, 0.0, 1}    -- orange (CB)

-- Watchlist row text colors (used by RmWatchlistDialog.populateCellForItemInSection).
-- Sibling tables to the hotspot palette above; values tuned for body text on
-- the dark dialog background, not for the bright map markers.
RmFarmlandMarket.COLOR_WATCHLIST_LISTED_PRICE = {}
RmFarmlandMarket.COLOR_WATCHLIST_LISTED_PRICE[false] = {0.49, 0.93, 0.0, 1}   -- bright green
RmFarmlandMarket.COLOR_WATCHLIST_LISTED_PRICE[true]  = {0.40, 0.70, 1.00, 1}  -- light blue (CB)

RmFarmlandMarket.COLOR_WATCHLIST_NOT_FOR_SALE = {}
RmFarmlandMarket.COLOR_WATCHLIST_NOT_FOR_SALE[false] = {0.7, 0.7, 0.7, 1}     -- light grey
RmFarmlandMarket.COLOR_WATCHLIST_NOT_FOR_SALE[true]  = {0.95, 0.60, 0.20, 1}  -- light orange (CB)

-- Overlay colors: boolean-keyed [false]=normal, [true]=colorBlind
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED = {}
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED[false] = {0.10, 0.22, 0.01}      -- green
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED[true]  = {0.0423, 0.2502, 0.8069} -- blue (CB)

RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE = {}
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE[false] = {0.06, 0.13, 0.005}    -- dim green
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE[true]  = {0.03, 0.15, 0.49}     -- dim blue (CB)

RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED = {}
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED[false] = {0.4, 0.05, 0.05}     -- red
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED[true]  = {0.9473, 0.5271, 0.0}  -- orange (CB)

RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE = {}
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE[false] = {0.25, 0.04, 0.04}   -- dim red
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE[true]  = {0.58, 0.32, 0.0}    -- dim orange (CB)

-- Cached pricing details per farmland id (populated during updatePrice)
RmFarmlandMarket.priceData = {}

-- XML schema for savegame persistence (lazy-registered)
RmFarmlandMarket.xmlSchema = nil

-- Configure logging (per-mod instance with multiplayer context)
local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- CORE FUNCTIONALITY: Crop Value Calculation
-- ============================================================================

--- Get peak seasonal price for a fill type across all 12 periods.
--- Falls back to current pricePerLiter if economy data unavailable.
---@param fillType table FillTypeDesc
---@return number peakPrice Peak price per liter
local function getPeakPrice(fillType)
    Log:trace(">>> getPeakPrice(fillType=%s)", fillType.name or "?")
    local economyManager = g_currentMission.economyManager
    if economyManager == nil then
        Log:trace("<<< getPeakPrice = %.4f (no economyManager, using base)", fillType.pricePerLiter)
        return fillType.pricePerLiter
    end

    local maxFactor = 0
    local bestPeriod = 0
    for period = 1, 12 do
        local factor = EconomyManager.getFillTypeSeasonalFactor(nil, fillType, period, 0)
        if factor ~= nil and factor > maxFactor then
            maxFactor = factor
            bestPeriod = period
        end
    end

    if maxFactor > 0 then
        local peakPrice = fillType.pricePerLiter * maxFactor
        Log:debug("PEAK_PRICE: %s base=%.4f factor=%.2f (period %d) peak=%.4f",
            fillType.name or "?", fillType.pricePerLiter, maxFactor, bestPeriod, peakPrice)
        Log:trace("<<< getPeakPrice = %.4f", peakPrice)
        return peakPrice
    end

    Log:trace("<<< getPeakPrice = %.4f (no seasonal data, using base)", fillType.pricePerLiter)
    return fillType.pricePerLiter
end

--- Calculates estimated crop value for a farmland based on current field state.
--- Uses peak seasonal price to reflect what a farmer would get selling at optimal time.
---@param farmland table The farmland object
---@return table details { cropValue, fruitName, growthRatio, ... }
local function calculateCropValue(farmland)
    Log:trace(">>> calculateCropValue(farmlandId=%d)", farmland.id)
    local details = { cropValue = 0 }

    local field = farmland:getField()
    if field == nil then
        Log:trace("<<< calculateCropValue = 0 (no field for farmland)")
        return details
    end
    details.hasField = true

    local fieldState = field:getFieldState()
    if fieldState == nil or not fieldState.isValid then
        Log:trace("<<< calculateCropValue = 0 (no valid fieldState)")
        return details
    end

    if fieldState.fruitTypeIndex == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        Log:trace("<<< calculateCropValue = 0 (no fruit planted)")
        return details
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitDesc == nil then
        Log:trace("<<< calculateCropValue = 0 (unknown fruitTypeIndex=%d)", fieldState.fruitTypeIndex)
        return details
    end

    local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fieldState.fruitTypeIndex)
    if fillType == nil then
        Log:trace("<<< calculateCropValue = 0 (no fillType for fruit=%s)", fruitDesc.name)
        return details
    end

    -- Growth progress ratio (0.0 to 1.0)
    local growthRatio = fieldState.growthState / fruitDesc.maxHarvestingGrowthState
    growthRatio = math.min(growthRatio, 1.0)

    -- Estimated harvest value using peak seasonal price
    local areaHa = field:getAreaHa()
    local areaSqm = areaHa * 10000
    local harvestMultiplier = fieldState:getHarvestScaleMultiplier()
    local harvestLiters = areaSqm * fruitDesc.literPerSqm * harvestMultiplier
    local peakPrice = getPeakPrice(fillType)
    local cropValue = harvestLiters * peakPrice * growthRatio

    details.cropValue = cropValue
    details.fruitName = fruitDesc.name
    details.growthState = fieldState.growthState
    details.maxGrowthState = fruitDesc.maxHarvestingGrowthState
    details.growthRatio = growthRatio
    details.areaHa = areaHa
    details.literPerSqm = fruitDesc.literPerSqm
    details.harvestMultiplier = harvestMultiplier
    details.harvestLiters = harvestLiters
    details.basePricePerLiter = fillType.pricePerLiter
    details.peakPrice = peakPrice

    Log:debug("CROP_VALUE: farmland=%d fruit=%s growth=%.0f%% area=%.1fha liters=%.0f peakPrice=%.2f value=%.0f",
        farmland.id, fruitDesc.name, growthRatio * 100, areaHa,
        harvestLiters, peakPrice, cropValue)
    Log:trace("<<< calculateCropValue = %.0f", cropValue)

    return details
end

-- ============================================================================
-- PRICE OVERRIDES
-- ============================================================================

--- Override Farmland.updatePrice to add crop value on top of base price
Farmland.updatePrice = Utils.overwrittenFunction(Farmland.updatePrice, function(self, superFunc)
    superFunc(self)
    local basePrice = self.price
    Log:trace(">>> updatePrice override (farmlandId=%d, basePrice=%.0f)", self.id, basePrice)
    local details = calculateCropValue(self)
    if details.cropValue > 0 then
        self.price = self.price + details.cropValue
        Log:trace("    price adjusted: %.0f + %.0f = %.0f", basePrice, details.cropValue, self.price)
    end
    RmFarmlandMarket.priceData[self.id] = {
        basePrice = basePrice,
        cropValue = details.cropValue,
        finalPrice = self.price,
        crop = details,
    }
    Log:trace("<<< updatePrice override (finalPrice=%.0f)", self.price)
end)

-- Override base price per hectare with custom price
FarmlandManager.getPricePerHa = Utils.overwrittenFunction(
    FarmlandManager.getPricePerHa,
    function(self, superFunc)
        local customPrice = RmFmSettings.getCustomPricePerHa()
        if customPrice > 0 then
            Log:trace(">>> getPricePerHa: custom=%d", customPrice)
            return customPrice
        end
        local basePrice = superFunc(self)
        Log:trace(">>> getPricePerHa: default=%d", basePrice)
        return basePrice
    end
)

-- ============================================================================
-- BUY FLOW VALIDATION HOOKS
-- ============================================================================

--- Override FarmlandStateEvent:run() to reject purchases of unavailable farmlands.
--- Also bypasses availability check for negotiated deals (pendingDeals).
FarmlandStateEvent.run = Utils.overwrittenFunction(FarmlandStateEvent.run, function(self, superFunc, connection)
    Log:trace(">>> FarmlandStateEvent:run(farmlandId=%d)", self.id)

    -- Bypass: negotiated deal in progress - skip availability check.
    if RmNegotiationManager.pendingDeals[self.id] then
        Log:info("NEGOTIATION: Executing negotiated deal for farmland %d (bypass availability)", self.id)
        superFunc(self, connection)
        -- Clear the flag on the authoritative server-inbound run. The base server-inbound run can
        -- early-return without transferring (a mission is running, no/denied player, insufficient
        -- funds, or the field is no longer unowned); in those cases setLandOwnership - hence
        -- onOwnershipChanged, the usual clearer - never fires, so clear here regardless of transfer.
        -- Gating on `not connection:getIsServer()` leaves the nested listen-server loopback apply
        -- pass (getIsServer()==true, which still sees the flag and clears it via onOwnershipChanged
        -- while running superFunc -> setLandOwnership for the live PDA refresh) untouched.
        if not connection:getIsServer() then
            RmNegotiationManager.pendingDeals[self.id] = nil
        end
        Log:trace("<<< FarmlandStateEvent:run() [negotiated deal]")
        return
    end

    -- Availability gate: enforce only on the server-inbound run (authoritative rejection).
    -- In run(), connection:getIsServer()==false means the server is receiving this from a
    -- client; ==true is an apply node (buyer, bystanders, server loopback) that must still
    -- reach superFunc so setLandOwnership refreshes ownership and the PDA/map overlay live.
    if not connection:getIsServer() and RmFmSettings.isAvailabilityEnabled() then
        if not RmFmAvailability.isForSale(self.id) then
            Log:warning("Purchase rejected: farmland %d not available for sale", self.id)
            Log:trace("<<< FarmlandStateEvent:run() [rejected]")
            return
        end
        Log:debug("AVAIL: Buy check for farmland %d: available=true", self.id)
    end

    superFunc(self, connection)
    Log:trace("<<< FarmlandStateEvent:run() [allowed]")
end)

--- Override InGameMenuMapFrame:setMapInputContext() to manage buy button for farmlands.
--- When availability is on and negotiation is off: suppress buy for unavailable.
--- When availability is on and negotiation is on: allow buy for eligible unavailable (unlisted negotiation).
InGameMenuMapFrame.setMapInputContext = Utils.overwrittenFunction(
    InGameMenuMapFrame.setMapInputContext,
    function(self, superFunc, canEnter, canReset, canSellVehicle, canVisit, canSetMarker, removeMarker, canBuy, canSell, canManage)
        if canBuy and RmFmSettings.isAvailabilityEnabled() then
            local hotspot = self.currentHotspot
            if hotspot ~= nil and hotspot.getFarmland ~= nil then
                local farmland = hotspot:getFarmland()
                if farmland ~= nil and not RmFmAvailability.isForSale(farmland.id) then
                    if RmFmSettings.isUnlistedOffersEnabled()
                       and RmFmAvailability.isEligibleForAvailability(farmland) then
                        -- Unlisted offers on: keep canBuy=true for unlisted negotiation
                        Log:debug("AVAIL: Allowing buy for unlisted negotiation on farmland %d", farmland.id)
                    else
                        -- Unlisted offers off: suppress buy
                        canBuy = false
                        Log:debug("AVAIL: Suppressed buy button for unavailable farmland %d", farmland.id)
                    end
                end
            end
        end

        superFunc(self, canEnter, canReset, canSellVehicle, canVisit, canSetMarker, removeMarker, canBuy, canSell, canManage)

        -- Relabel BUY/SELL buttons based on granular negotiation settings.
        -- Use .title for direct text override (takes precedence over .text l10n key)
        -- Always clear/set: previous .title persists on the action object across calls.
        local actions = InGameMenuMapFrame.ACTIONS

        -- BUY button label
        local buyAction = self.contextActions[actions.BUY]
        if canBuy and buyAction.isActive then
            local shouldNegBuy = false
            local hotspot = self.currentHotspot
            if hotspot ~= nil and hotspot.getFarmland ~= nil then
                local farmland = hotspot:getFarmland()
                -- Skip relabel for FM-ineligible farmlands (incl. $0 plots);
                -- vanilla buy handles them and the click interceptor falls through.
                if farmland ~= nil and RmFmAvailability.isEligibleForAvailability(farmland) then
                    local isListed = RmFmAvailability.isForSale(farmland.id)
                    shouldNegBuy = (isListed and RmFmSettings.isNegotiateBuyEnabled())
                        or (not isListed and RmFmSettings.isUnlistedOffersEnabled())
                end
            end
            buyAction.title = shouldNegBuy and g_i18n:getText("rm_fm_btn_makeOffer") or nil
        else
            buyAction.title = nil
        end

        -- SELL button label
        local sellAction = self.contextActions[actions.SELL]
        if canSell and sellAction.isActive and RmFmSettings.isNegotiateSellEnabled() then
            local hotspot = self.currentHotspot
            local farmland = (hotspot ~= nil and hotspot.getFarmland ~= nil)
                and hotspot:getFarmland() or nil
            -- Sell paths bypass eligibility (player-owned land); gate directly
            -- on positive market value so $0 plots fall through to vanilla.
            if RmFmAvailability.hasPositiveMarketValue(farmland) then
                sellAction.title = g_i18n:getText("rm_fm_btn_negotiateSale")
            else
                sellAction.title = nil
            end
        else
            sellAction.title = nil
        end
    end
)

-- ============================================================================
-- CONTEXT BOX DISPLAY
-- ============================================================================

--- Re-apply FM value overrides to the farmlandValue element.
--- Called from showContextBox append AND from the PF compat hook (which runs
--- after PF's AdditionalFieldBuyInfo:updateContextBox() overwrites the value).
---@param contextBox table The context box GUI element
---@param farmlandId number The farmland ID
---@param farmland table The Farmland object
local function applyFarmlandValueOverrides(contextBox, farmlandId, farmland)
    if contextBox == nil or farmland == nil then return end

    local valueEl = contextBox:getDescendantByName("farmlandValue")
    if valueEl == nil then return end

    -- Listing price override (unowned + listed + negotiate buy on)
    -- Unlisted fields never show a listing price - the buyer makes a blind offer
    local isOwned = farmland.farmId == g_currentMission:getFarmId()
    if not isOwned and RmFmSettings.isNegotiateBuyEnabled()
       and RmFmAvailability.isForSale(farmlandId) then
        local listingPrice = RmNegotiationManager.getListingPrice(farmlandId)
        if listingPrice ~= nil then
            valueEl:setText(g_i18n:formatMoney(listingPrice, 0, true, true))
        end
    end

    -- "Not for sale" override (takes precedence over listing price)
    if RmFmSettings.isAvailabilityEnabled()
       and RmFmAvailability.isEligibleForAvailability(farmland)
       and not RmFmAvailability.isForSale(farmlandId) then
        valueEl:setText(g_i18n:getText("rm_fm_notForSale"))
    end

    -- Cooldown display (server only - clients get error on attempt).
    -- formatCooldownRemaining owns the single EPSILON liveness gate and the
    -- day/month unit choice, and returns nil when the cooldown is expired.
    if g_server ~= nil and RmFmSettings.isAnyNegotiationEnabled() then
        local playerFarmId = g_currentMission:getFarmId()
        local cooldownInfo = RmNegotiationManager.getCooldownInfo(farmlandId, playerFarmId)
        if cooldownInfo ~= nil then
            -- A cooldown on land the player OWNS is a sell/relist cooldown; on
            -- unowned land it is a buy cooldown (ownership change clears a
            -- farmland's cooldowns, so no buy cooldown lingers onto owned land).
            -- So isOwned selects the correct buy-vs-sell display variant.
            local cooldownText = RmNegotiationManager.formatCooldownRemaining(
                cooldownInfo.remaining, isOwned, nil)
            if cooldownText ~= nil then
                valueEl:setText(valueEl:getText() .. "\n" .. cooldownText)
            end
        end
    end
end

--- Replace farmland value with "Not for sale" for unavailable farmlands.
--- Runs after base showContextBox (and PF override if active).
InGameMenuMapUtil.showContextBox = Utils.appendedFunction(
    InGameMenuMapUtil.showContextBox,
    function(contextBox, hotspot, description, imageFilename, uvs, farmId, playerName, isPlaceable, isVehicle, isFarmland)
        if not isFarmland or contextBox == nil then
            return
        end

        -- Cache label + value elements on first find
        if contextBox.rmFmValueLabel == nil then
            local farmlandValueEl = contextBox:getDescendantByName("farmlandValue")
            if farmlandValueEl ~= nil and farmlandValueEl.parent ~= nil then
                contextBox.rmFmValueElement = farmlandValueEl
                local valueLabelText = g_i18n:getText("ui_sellValue") .. ":"
                for _, child in ipairs(farmlandValueEl.parent.elements) do
                    if child ~= farmlandValueEl and child.getText ~= nil
                       and child:getText() == valueLabelText then
                        contextBox.rmFmValueLabel = child
                        break
                    end
                end
            end
        end

        -- Determine label + value override based on field state
        local farmlandId = nil
        local farmland = nil
        if hotspot ~= nil and hotspot.getFarmland ~= nil then
            farmland = hotspot:getFarmland()
            if farmland ~= nil then
                farmlandId = farmland.id
            end
        end

        -- Label overrides (PF doesn't touch labels, so this only runs here).
        -- Gates mirror setMapInputContext: buy-relabel on eligibility (excludes
        -- $0 plots), sell-relabel on positive market value (eligibility
        -- excludes player-owned by design).
        if contextBox.rmFmValueLabel ~= nil and farmland ~= nil then
            local isOwned = farmland.farmId == g_currentMission:getFarmId()
            if isOwned and RmFmSettings.isNegotiateSellEnabled()
               and RmFmAvailability.hasPositiveMarketValue(farmland) then
                contextBox.rmFmValueLabel:setText(g_i18n:getText("rm_fm_marketValue") .. ":")
            elseif not isOwned and RmFmSettings.isNegotiateBuyEnabled()
                   and RmFmAvailability.isEligibleForAvailability(farmland)
                   and RmFmAvailability.isForSale(farmland.id) then
                contextBox.rmFmValueLabel:setText(g_i18n:getText("rm_fm_listPrice") .. ":")
            else
                contextBox.rmFmValueLabel:setText(g_i18n:getText("ui_sellValue") .. ":")
            end
        end

        -- Value overrides (listing price, not-for-sale, cooldown)
        -- Uses shared helper so PF compat hook can re-apply after PF overwrites
        applyFarmlandValueOverrides(contextBox, farmlandId, farmland)
    end
)

-- ============================================================================
-- FARMLAND LEGEND
-- ============================================================================

--- Customize farmland legend at cell render time for guaranteed consistency.
--- Entry 1 "Unowned" -> "For sale", Entry 2 "Currently Selected" -> "Not for sale" (red).
InGameMenuMapFrame.populateCellForItemInSection = Utils.appendedFunction(
    InGameMenuMapFrame.populateCellForItemInSection,
    function(self, list, section, index, cell)
        if list ~= self.filterList then
            return
        end
        if self.mapOverviewSelector:getState() ~= InGameMenuMapFrame.MAP_FARMLANDS then
            return
        end
        if not RmFmSettings.isAvailabilityEnabled() then
            return
        end

        if index == 1 then
            -- "Unowned" -> "For sale" (green)
            cell:getAttribute("name"):setText(g_i18n:getText("rm_fm_forSale"))
            self:assignItemColors(cell:getAttribute("iconBg"),
                { RmFarmlandMarket.COLOR_FOR_SALE[RmFarmlandMarket.isColorBlindMode] })
        elseif index == 2 then
            -- "Currently Selected" -> "Not for sale" (red)
            cell:getAttribute("name"):setText(g_i18n:getText("rm_fm_notForSale"))
            self:assignItemColors(cell:getAttribute("iconBg"),
                { RmFarmlandMarket.COLOR_NOT_FOR_SALE[RmFarmlandMarket.isColorBlindMode] })
        end
    end
)

-- ============================================================================
-- HOTSPOT COLOR MANAGEMENT
-- ============================================================================

--- Override FarmlandHotspot:updateColors() to apply red tint to unavailable fields
FarmlandHotspot.updateColors = Utils.appendedFunction(FarmlandHotspot.updateColors, function(self)
    -- Guard: check log level before trace (performance optimization)
    if Log.level <= RmLogging.LOG_LEVEL.TRACE then
        Log:trace(">>> FarmlandHotspot:updateColors()")
    end

    -- Guard: skip if no farmland
    local farmland = self:getFarmland()
    if farmland == nil then
        return
    end

    -- Guard: skip if availability disabled
    if not RmFmSettings.isAvailabilityEnabled() then
        return
    end

    -- Guard: skip if player-owned (not in availability pool)
    if not RmFmAvailability.isEligibleForAvailability(farmland) then
        return
    end

    -- Apply red tint if not for sale
    if not RmFmAvailability.isForSale(farmland.id) then
        local color = RmFarmlandMarket.COLOR_NOT_FOR_SALE[RmFarmlandMarket.isColorBlindMode]
        self:setColor(color[1], color[2], color[3])
        self.colorDisabled[1] = color[1]
        self.colorDisabled[2] = color[2]
        self.colorDisabled[3] = color[3]
        self.colorDisabled[4] = color[4]
    end

    if Log.level <= RmLogging.LOG_LEVEL.TRACE then
        Log:trace("<<< FarmlandHotspot:updateColors()")
    end
end)

-- ============================================================================
-- MAP OVERLAY COLOR MANAGEMENT (menu map farmland area overlay)
-- ============================================================================

--- Apply availability tint to farmland area overlays after standard colors are set.
--- Red for unavailable, green for available (for sale).
--- Called as appendedFunction on both build methods.
--- NOTE: key param is the farmlands table key (from pairs()), not farmland.id
---@param self table MapOverlayGenerator instance
---@param selectedFarmland table|nil Currently selected Farmland object
local function applyAvailabilityOverlayColors(self, selectedFarmland)
    if not RmFmSettings.isAvailabilityEnabled() then
        return
    end

    local overlay = self.farmlandStateOverlay
    if overlay == nil then
        return
    end

    local map = self.farmlandManager:getLocalMap()
    if map == nil then
        return
    end

    local numChannels = getBitVectorMapNumChannels(map)
    local selectedId = selectedFarmland ~= nil and selectedFarmland.id or nil

    local isBlind = RmFarmlandMarket.isColorBlindMode
    for k, farmland in pairs(self.farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            local isSelected = farmland.id == selectedId
            local color
            if RmFmAvailability.isForSale(farmland.id) then
                color = isSelected
                    and RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED[isBlind]
                    or RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE[isBlind]
            else
                color = isSelected
                    and RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED[isBlind]
                    or RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE[isBlind]
            end
            setDensityMapVisualizationOverlayStateColor(
                overlay, map, 0, 0, 0, numChannels, k,
                color[1], color[2], color[3])
        end
    end
end

--- Override MapOverlayGenerator:buildFarmlandsMapOverlay() to tint farmlands by availability
MapOverlayGenerator.buildFarmlandsMapOverlay = Utils.appendedFunction(
    MapOverlayGenerator.buildFarmlandsMapOverlay,
    applyAvailabilityOverlayColors
)

--- Override MapOverlayGenerator:buildSingleFarmlandsMapOverlay() to tint selected farmland by availability
MapOverlayGenerator.buildSingleFarmlandsMapOverlay = Utils.appendedFunction(
    MapOverlayGenerator.buildSingleFarmlandsMapOverlay,
    applyAvailabilityOverlayColors
)

--- Handle color blind mode setting change (subscribed via MessageCenter).
--- MessageCenter passes target as first arg, so read setting directly instead.
function RmFarmlandMarket.onColorBlindModeChanged()
    RmFarmlandMarket.isColorBlindMode =
        g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) == true
    Log:debug("Color blind mode changed: %s", tostring(RmFarmlandMarket.isColorBlindMode))
    RmFarmlandMarket.updateAllHotspotColors()
end

--- Update all farmland hotspot colors (called after availability changes)
function RmFarmlandMarket.updateAllHotspotColors()
    Log:trace(">>> updateAllHotspotColors()")
    local count = 0
    for _, hotspot in pairs(g_currentMission.mapHotspots) do
        if hotspot.getFarmland ~= nil then
            hotspot:updateColors()
            count = count + 1
        end
    end
    Log:debug("Updated %d farmland hotspot colors", count)

    -- Also refresh the farmland area overlay if the map frame is open
    if g_inGameMenu ~= nil and g_inGameMenu.pageMapOverview ~= nil then
        g_inGameMenu.pageMapOverview.needsOverlayUpdate = true
        Log:debug("OVERLAY: Flagged map frame for overlay refresh")
    end

    Log:trace("<<< updateAllHotspotColors()")
end

--- Refresh map display after ownership or availability changes.
--- Deferred via Timer.createOneshot(0) to run on the next frame,
--- after all event processing in the current frame has completed.
--- Updates hotspot colors, overlay, and re-selects current hotspot to refresh context box.
function RmFarmlandMarket.refreshMapDisplay()
    Log:trace(">>> refreshMapDisplay()")

    -- Refresh hotspot colors + flag overlay for rebuild
    RmFarmlandMarket.updateAllHotspotColors()

    -- Refresh context box for currently selected hotspot
    local mapFrame = g_inGameMenu ~= nil and g_inGameMenu.pageMapOverview or nil
    if mapFrame ~= nil and mapFrame.currentHotspot ~= nil then
        mapFrame:setMapSelectionItem(mapFrame.currentHotspot)
        Log:debug("DISPLAY: Re-selected current hotspot to refresh context box")
    end

    Log:trace("<<< refreshMapDisplay()")
end

-- ============================================================================
-- DAY CHANGE HANDLER
-- ============================================================================

--- Day change callback (subscribed via MessageCenter)
function RmFarmlandMarket.onDayChanged()
    Log:trace(">>> onDayChanged()")

    -- Crop state can change as a new day begins. Refresh on every node so
    -- displayed market values match the server's authoritative price.
    local changedPriceCount = RmFarmlandMarket.updateAllFarmlandPrices()

    -- Availability and negotiation state remain server-authoritative.
    if g_server == nil then
        if changedPriceCount > 0 then
            RmFarmlandMarket.refreshMapDisplay()
        end
        Log:trace("<<< onDayChanged() [not server]")
        return
    end

    -- Snapshot watched ids' isForSale state BEFORE evaluateDaily mutates the
    -- table. Only need the slice that local watched cares about; for ids the
    -- player isn't watching, the diff result is irrelevant.
    local oldByFarmlandId = {}
    for id in pairs(RmWatchlistUI.watched) do
        local entry = RmFmAvailability.availability[id]
        oldByFarmlandId[id] = type(entry) == "table" and entry.isForSale == true
    end

    -- Detect the "auto-init" path: evaluateDaily self-heals when the table
    -- is empty (preset toggled from off -> active mid-session). On that
    -- tick every entry initialize() lists is a fresh listing, NOT an
    -- organic transition - notifying would flood the player with every
    -- watched + initially-listed parcel. Spec rule: initialize is never a
    -- notification source, including this auto-init branch.
    local availWasEmpty = next(RmFmAvailability.availability) == nil

    RmFmAvailability.evaluateDaily()
    -- A changed market value invalidates cached list prices. When prices did
    -- not change, keep existing seller profiles and only create any needed
    -- for fields that were listed by evaluateDaily().
    if changedPriceCount > 0 then
        RmNegotiationManager.invalidateSellerProfiles()
    else
        RmNegotiationManager.ensureListedProfiles()
    end

    Log:debug("SYNC: Broadcasting availability sync to all clients")
    g_server:broadcastEvent(RmAvailabilitySyncEvent.new())
    RmFarmlandMarket.refreshMapDisplay()

    if availWasEmpty then
        Log:debug("Watchlist for-sale notify: skipped (mid-session auto-init tick)")
        Log:trace("<<< onDayChanged()")
        return
    end

    -- Compute false->true transitions on the watched slice. listingPrice is
    -- now authoritative because seller profiles were handled above.
    local transitions = {}
    for id, wasForSale in pairs(oldByFarmlandId) do
        local entry = RmFmAvailability.availability[id]
        local nowForSale = type(entry) == "table" and entry.isForSale == true
        if nowForSale and not wasForSale then
            table.insert(transitions, { id = id, listingPrice = entry.listingPrice })
        end
    end
    if #transitions > 0 then
        RmWatchlistUI.notifyForSaleTransitions(transitions)
    end

    Log:trace("<<< onDayChanged()")
end

-- ============================================================================
-- CONSOLE COMMANDS
-- ============================================================================

--- Get owner name for a farmland (player farm or NPC)
---@param farmland table
---@return string ownerName
local function getOwnerName(farmland)
    -- Player-owned farmland
    if farmland.farmId ~= nil and farmland.farmId ~= FarmlandManager.NO_OWNER_FARM_ID then
        local farm = g_farmManager:getFarmById(farmland.farmId)
        if farm ~= nil then
            return farm.name
        end
        return string.format("Farm %d", farmland.farmId)
    end
    -- NPC-owned farmland
    if farmland.npcIndex ~= nil and farmland.npcIndex > 0 then
        local npc = g_npcManager:getNPCByIndex(farmland.npcIndex)
        if npc ~= nil then
            return npc.title
        end
        return string.format("NPC %d", farmland.npcIndex)
    end
    return "(unowned)"
end

--- Get crop status string for a farmland
---@param data table|nil Cached price data
---@return string status
local function getCropStatus(data)
    if data == nil then
        return ""
    end
    local crop = data.crop
    if crop.cropValue > 0 then
        return string.format("%s (%.0f%%)", crop.fruitName, crop.growthRatio * 100)
    elseif crop.hasField then
        return "(empty)"
    else
        return "(no field)"
    end
end

--- Console command: List all farmlands with prices
function RmFarmlandMarket:consoleFmList()
    local farmlands = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        table.insert(farmlands, farmland)
    end
    table.sort(farmlands, function(a, b) return a.id < b.id end)

    print("Farmland Market - Price Overview")
    print(string.format("  %3s  %-14s  %7s  %8s  %7s  %8s  %5s  %s",
        "ID", "Owner", "Area", "Base", "Crop", "Final", "Avail", "Field"))
    print("  ---  --------------  -------  --------  -------  --------  -----  ---------------")

    for _, farmland in ipairs(farmlands) do
        local owner = getOwnerName(farmland)
        local data = RmFarmlandMarket.priceData[farmland.id]
        local basePrice = data and data.basePrice or farmland.price
        local cropValue = data and data.cropValue or 0
        local finalPrice = data and data.finalPrice or farmland.price
        local status = getCropStatus(data)

        -- Availability indicator
        local availStr = "-"
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            availStr = RmFmAvailability.isForSale(farmland.id) and "Y" or "N"
        end

        print(string.format("  %3d  %-14s  %5.1fha  %8.0f  %7.0f  %8.0f  %5s  %s",
            farmland.id, owner, farmland.areaInHa, basePrice, cropValue, finalPrice, availStr, status))
    end

    return string.format("Listed %d farmlands", #farmlands)
end

--- Console command: Show availability status for all farmlands
function RmFarmlandMarket:consoleFmAvail()
    Log:trace(">>> consoleFmAvail()")

    if not RmFmSettings.isAvailabilityEnabled() then
        print("Availability system is DISABLED")
        return "Availability disabled"
    end

    local farmlands = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            table.insert(farmlands, farmland)
        end
    end
    table.sort(farmlands, function(a, b) return a.id < b.id end)

    print("Farmland Market - Availability Status")
    print(string.format("  %3s  %8s  %10s  %10s  %s",
        "ID", "For Sale", "Listed Day", "Expiry Day", "Status"))
    print("  ---  --------  ----------  ----------  -----------")

    local forSaleCount = 0
    for _, farmland in ipairs(farmlands) do
        local entry = RmFmAvailability.availability[farmland.id]
        if entry ~= nil then
            local forSaleStr = entry.isForSale and "Y" or "N"
            local listingDayStr = entry.listingDay > 0 and tostring(entry.listingDay) or "-"
            local expiryDayStr = entry.expiryDay > 0 and tostring(entry.expiryDay) or "-"
            local statusStr = ""
            if entry.isForSale then
                forSaleCount = forSaleCount + 1
                local daysLeft = entry.expiryDay - g_currentMission.environment.currentDay
                statusStr = string.format("%d days left", daysLeft)
            else
                statusStr = "Not listed"
            end

            print(string.format("  %3d  %8s  %10s  %10s  %s",
                farmland.id, forSaleStr, listingDayStr, expiryDayStr, statusStr))

            Log:debug("AVAIL: farmland %d: forSale=%s listingDay=%d expiryDay=%d",
                farmland.id, forSaleStr, entry.listingDay, entry.expiryDay)
        else
            print(string.format("  %3d  (no entry in availability table)", farmland.id))
        end
    end

    print("")
    print(string.format("Total: %d eligible farmlands, %d for sale", #farmlands, forSaleCount))

    Log:trace("<<< consoleFmAvail()")
    return string.format("%d eligible, %d for sale", #farmlands, forSaleCount)
end

--- Console command: Inspect a farmland's price breakdown
function RmFarmlandMarket:consoleFmInspect(farmlandIdStr)
    if farmlandIdStr == nil then
        return "Usage: fmInspect <farmlandId>"
    end

    local farmlandId = tonumber(farmlandIdStr)
    if farmlandId == nil then
        return "Invalid farmland ID: " .. farmlandIdStr
    end

    local farmland = g_farmlandManager:getFarmlands()[farmlandId]
    if farmland == nil then
        return string.format("Farmland %d not found", farmlandId)
    end

    local owner = getOwnerName(farmland)
    print(string.format("Farmland Market - Farmland %d", farmlandId))
    print(string.format("  Owner:         %s", owner))
    print(string.format("  Area:          %.2f ha", farmland.areaInHa))

    local data = RmFarmlandMarket.priceData[farmlandId]
    if data == nil then
        if farmland.fixedPrice ~= nil then
            print(string.format("  Fixed Price:   %.0f", farmland.price))
        else
            print(string.format("  Price:         %.0f (no cached data)", farmland.price))
        end
        return string.format("Farmland %d: price = %.0f", farmlandId, farmland.price)
    end

    -- Base price breakdown
    local pricePerHa = g_farmlandManager:getPricePerHa()
    local priceFactor = farmland.priceFactor or 0
    print(string.format("  Price Factor:  %.2f", priceFactor))
    print("")
    print(string.format("  Base Price:    %.0f", data.basePrice))
    print(string.format("    = %.0f $/ha x %.2f ha x %.2f factor",
        pricePerHa, farmland.areaInHa, priceFactor))

    -- Crop value breakdown
    print("")
    local crop = data.crop
    if crop.cropValue > 0 then
        print(string.format("  Crop Value:    %.0f", crop.cropValue))
        print(string.format("    Fruit:       %s", crop.fruitName))
        print(string.format("    Growth:      %.0f%% (%d/%d)",
            crop.growthRatio * 100, crop.growthState, crop.maxGrowthState))
        print(string.format("    Harvest:     %.0f L (%.2f ha x %.2f L/sqm x %.2fx)",
            crop.harvestLiters, crop.areaHa, crop.literPerSqm, crop.harvestMultiplier))
        print(string.format("    Peak Price:  %.4f $/L (base: %.4f)",
            crop.peakPrice, crop.basePricePerLiter))
        print(string.format("    = %.0f L x %.4f $/L x %.0f%%",
            crop.harvestLiters, crop.peakPrice, crop.growthRatio * 100))
    elseif crop.hasField then
        print("  Crop Value:    0 (no crop planted)")
    else
        print("  Crop Value:    0 (no field)")
    end

    -- Final price
    print("")
    print(string.format("  Final Price:   %.0f", data.finalPrice))
    if crop.cropValue > 0 then
        print(string.format("    = %.0f base + %.0f crop", data.basePrice, crop.cropValue))
    end

    return string.format("Farmland %d: %.0f (base) + %.0f (crop) = %.0f",
        farmlandId, data.basePrice, data.cropValue, data.finalPrice)
end

--- Console command: Test negotiation dialog with mock data
--- Usage: fmTestDialog [buy|sell|unlisted] [stateNum]
---   mode: buy (default), sell, unlisted
---   stateNum: 1=opening, 2=input, 3=acceptCounter, 4=acceptWalk, 5=proposal, 6=completed, 7=waiting
function RmFarmlandMarket:consoleFmTestDialog(mode, stateNum)
    local dialog = RmNegotiationDialog.getInstance()
    if dialog == nil then
        return "Dialog not registered"
    end

    mode = mode or "buy"
    stateNum = tonumber(stateNum)

    -- If only changing state on an already-open dialog
    if stateNum ~= nil and dialog.currentSnapshot ~= nil then
        dialog:setActionState(stateNum, { statusText = "Test state " .. stateNum })
        return string.format("Switched to state %d", stateNum)
    end

    -- Find first farmland for realistic data
    local farmlandId = 1
    for _, fl in pairs(g_farmlandManager:getFarmlands()) do
        farmlandId = fl.id
        break
    end

    -- Build mock snapshot
    local engineMode
    if mode == "sell" then
        engineMode = RmNegotiationEngine.MODE_SELL
    elseif mode == "unlisted" then
        engineMode = RmNegotiationEngine.MODE_UNLISTED_BUY
    else
        engineMode = RmNegotiationEngine.MODE_LISTED_BUY
    end

    local snapshot = {
        farmlandId = farmlandId,
        mode = engineMode,
        round = 3,
        state = "active",
        anchorPrice = 85000,
        rejectFloor = 60000,
        lastCounter = 78000,
        offers = {},
        pendingProposal = nil,
        outcome = nil,
        finalPrice = nil,
    }

    -- Build mock offer history based on mode
    if engineMode == RmNegotiationEngine.MODE_SELL then
        snapshot.offers = {
            { round = 1, npcOffer = 72000, playerAsk = 95000, npcResponse = 78000 },
            { round = 2, npcOffer = 78000, playerAsk = 88000, npcResponse = 82000 },
        }
    else
        snapshot.offers = {
            { round = 1, offer = 65000, counter = 82000 },
            { round = 2, offer = 75000, counter = 78000 },
        }
    end

    -- Open and populate
    g_gui:showDialog("RmNegotiationDialog")
    dialog:updateFromSnapshot(snapshot)

    -- Set action state
    local targetState = stateNum or RmNegotiationDialog.STATE_ACCEPT_COUNTER
    local statusText = nil
    if targetState == RmNegotiationDialog.STATE_COMPLETED then
        statusText = "Deal completed at $80,000!"
    elseif targetState == RmNegotiationDialog.STATE_OFFER_INPUT then
        statusText = engineMode == RmNegotiationEngine.MODE_SELL
            and "Enter your counter-ask:" or "Enter your offer:"
    end
    dialog:setActionState(targetState, { statusText = statusText })

    -- Wire dummy callbacks so buttons don't crash
    dialog.onMakeOffer = function() print("  [TEST] onMakeOffer") end
    dialog.onSubmitOffer = function(amount) print(string.format("  [TEST] onSubmitOffer(%d)", amount)) end
    dialog.onAcceptPrice = function() print("  [TEST] onAcceptPrice") end
    dialog.onWalkAway = function() print("  [TEST] onWalkAway") end
    dialog.onAcceptProposal = function() print("  [TEST] onAcceptProposal") end
    dialog.onDeclineProposal = function() print("  [TEST] onDeclineProposal") end

    return string.format("Opened dialog: mode=%s state=%d farmland=%d", mode, targetState, farmlandId)
end

-- ============================================================================
-- SAVEGAME PERSISTENCE
-- ============================================================================

--- Register XML schema for savegame files (idempotent)
function RmFarmlandMarket.registerXmlSchema()
    if RmFarmlandMarket.xmlSchema ~= nil then
        return
    end

    local schema = XMLSchema.new("rmFarmlandMarket")

    -- Settings
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#availabilityPreset", "Availability preset state")
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#customPricePerHa", "Custom base price per hectare (0 = map default)")
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#negotiateBuy", "Negotiate buy state")
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#negotiateSell", "Negotiate sell state")
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#unlistedOffers", "Unlisted offers state")
    -- Legacy: migration from pre-0.6 saves (read-only, never written by new saves)
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#negotiationEnabled", "Legacy negotiation toggle (migration)")

    -- Availability entries
    local entryPath = "rmFarmlandMarket.availability.farmland(?)"
    schema:register(XMLValueType.INT, entryPath .. "#id", "Farmland ID")
    schema:register(XMLValueType.BOOL, entryPath .. "#isForSale", "For sale flag")
    schema:register(XMLValueType.INT, entryPath .. "#expiryDay", "Expiry day")
    schema:register(XMLValueType.INT, entryPath .. "#listingDay", "Listing day")

    -- Negotiations: seller profiles + cooldowns
    local negPath = "rmFarmlandMarket.negotiations.farmland(?)"
    schema:register(XMLValueType.INT, negPath .. "#id", "Farmland ID")
    schema:register(XMLValueType.STRING, negPath .. ".sellerProfile#mode", "Profile mode")
    schema:register(XMLValueType.STRING, negPath .. ".sellerProfile#preset", "Profile preset")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#marketValue", "Market value")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#anchorPrice", "Anchor price")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#listingPrice", "Listing price")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#reservation", "Reservation price")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#stubbornness", "Stubbornness factor")
    schema:register(XMLValueType.FLOAT, negPath .. ".sellerProfile#rejectFloor", "Reject floor price")
    local cdPath = negPath .. ".cooldown(?)"
    schema:register(XMLValueType.INT, cdPath .. "#farmId", "Farm ID")
    schema:register(XMLValueType.FLOAT, cdPath .. "#remaining", "Remaining cooldown periods (fractional; ticks 1/daysPerPeriod per day)")
    schema:register(XMLValueType.STRING, cdPath .. "#lastOutcome", "Last negotiation outcome")

    -- Watchlist: per-farm sets of farmlandIds the player is watching.
    local wlFarmPath = "rmFarmlandMarket.watchlist.farm(?)"
    schema:register(XMLValueType.INT, wlFarmPath .. "#farmId", "Watching farm ID")
    schema:register(XMLValueType.INT, wlFarmPath .. ".entry(?)#farmlandId", "Watched farmland ID")

    RmFarmlandMarket.xmlSchema = schema
    Log:debug("XML schema registered")
end

--- Load mod data from savegame XML (server only)
local function loadFromSavegame()
    Log:trace(">>> loadFromSavegame()")

    if g_server == nil then
        Log:trace("<<< loadFromSavegame() [not server]")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        Log:warning("Savegame directory not available, skipping load")
        return
    end

    local filePath = savegameDir .. "/rm_FarmlandMarket.xml"
    RmFarmlandMarket.registerXmlSchema()
    local xmlFile = XMLFile.loadIfExists("fmSavegame", filePath, RmFarmlandMarket.xmlSchema)

    if xmlFile == nil then
        Log:debug("No savegame file found (new save), using defaults")
        return
    end

    Log:debug("Loading savegame from rm_FarmlandMarket.xml")

    -- Delegate to modules
    RmFmSettings.loadFromXMLFile(xmlFile)
    RmFmAvailability.loadFromXMLFile(xmlFile)
    RmNegotiationManager.loadFromXMLFile(xmlFile)
    RmWatchlistStore.loadFromXMLFile(xmlFile)

    -- Write listing prices from restored profiles onto availability entries
    RmNegotiationManager.ensureListedProfiles()

    xmlFile:delete()
    Log:debug("Savegame loaded from rm_FarmlandMarket.xml")
    Log:trace("<<< loadFromSavegame()")
end

--- Save mod data to savegame XML
local function saveToSavegame()
    Log:trace(">>> saveToSavegame()")

    -- Server only
    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        Log:warning("Savegame directory not available, skipping save")
        return
    end

    local filePath = savegameDir .. "/rm_FarmlandMarket.xml"
    RmFarmlandMarket.registerXmlSchema()
    local xmlFile = XMLFile.create("fmSavegame", filePath, "rmFarmlandMarket", RmFarmlandMarket.xmlSchema)

    if xmlFile == nil then
        Log:error("Failed to create savegame XML file: %s", filePath)
        return
    end

    Log:debug("Saving to rm_FarmlandMarket.xml")

    -- Delegate to modules
    RmFmSettings.saveToXMLFile(xmlFile)
    RmFmAvailability.saveToXMLFile(xmlFile)
    RmNegotiationManager.saveToXMLFile(xmlFile)
    RmWatchlistStore.saveToXMLFile(xmlFile)

    xmlFile:save()
    xmlFile:delete()

    Log:debug("Savegame saved to rm_FarmlandMarket.xml")
    Log:trace("<<< saveToSavegame()")
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

local function onLoadMapFinished()
    Log:info("Map loaded, initializing FarmlandMarket")

    -- Register negotiation dialog GUI (before console commands)
    RmNegotiationDialog.register()
    RmWatchlistDialog.register()

    -- Register console commands (development builds only - they expose price
    -- internals the GUI deliberately withholds)
    local ver = RmVersion.forMod(RmFarmlandMarket.modName, Log)
    if ver:isDevelopmentVersion() then
        addConsoleCommand("fmList", "List all farmlands with prices", "consoleFmList", RmFarmlandMarket)
        addConsoleCommand("fmInspect", "Inspect farmland price details", "consoleFmInspect", RmFarmlandMarket, "farmlandId")
        addConsoleCommand("fmAvail", "Show availability status", "consoleFmAvail", RmFarmlandMarket)
        addConsoleCommand("fmTestDialog", "Test negotiation dialog (buy|sell|unlisted|state N)", "consoleFmTestDialog", RmFarmlandMarket, "mode stateNum")
        Log:debug("FarmlandMarket: development console commands registered (%s)", ver:describe())
    end

    -- Subscribe to day change events
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, RmFarmlandMarket.onDayChanged, RmFarmlandMarket)
    Log:debug("Subscribed to DAY_CHANGED message")

    -- Read color blind mode setting and subscribe to live changes
    RmFarmlandMarket.isColorBlindMode =
        Utils.getNoNil(g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE), false) == true
    g_messageCenter:subscribe(
        MessageType.SETTING_CHANGED[GameSettings.SETTING.USE_COLORBLIND_MODE],
        RmFarmlandMarket.onColorBlindModeChanged,
        RmFarmlandMarket
    )
    Log:debug("Color blind mode: %s", tostring(RmFarmlandMarket.isColorBlindMode))

    -- Precision Farming compatibility: PF's AdditionalFieldBuyInfo:updateContextBox()
    -- asynchronously overwrites farmlandValue after our showContextBox append runs.
    -- Re-apply ALL value overrides (listing price, not-for-sale, cooldown) via shared helper.
    -- PF globals live in its sandboxed mod environment (FS25 mod isolation), not in _G.
    local pfEnv = _G.FS25_precisionFarming
    if pfEnv ~= nil and pfEnv.g_precisionFarming ~= nil then
        local pfBuyInfo = pfEnv.g_precisionFarming.additionalFieldBuyInfo
        if pfBuyInfo ~= nil then
            Log:info("Precision Farming detected, hooking additionalFieldBuyInfo instance")
            local origUpdateContextBox = pfBuyInfo.updateContextBox
            function pfBuyInfo:updateContextBox()
                origUpdateContextBox(self)
                if self.lastContextBox == nil then return end
                local farmlandId = self.selectedFarmlandId
                if farmlandId == nil then return end
                local farmland = g_farmlandManager:getFarmlands()[farmlandId]
                if farmland == nil then return end
                applyFarmlandValueOverrides(self.lastContextBox, farmlandId, farmland)
                Log:debug("PF_COMPAT: Re-applied FM value overrides after PF update for farmland %d", farmlandId)
            end
        end
    end

    Log:debug("FarmlandMarket hooks registered")
end

--- Apply crop-value pricing to all farmlands.
--- Called from onStartMission when farmlands and fields are fully loaded.
--- Also called when custom price/ha setting changes.
---@return number changedPriceCount Number of farmland prices that changed
function RmFarmlandMarket.updateAllFarmlandPrices()
    Log:trace(">>> updateAllFarmlandPrices()")
    local totalFarmlands = 0
    local farmlandsWithCrops = 0
    local changedPriceCount = 0
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        totalFarmlands = totalFarmlands + 1
        if farmland.fixedPrice ~= nil then
            Log:trace("  Skipping farmland %d (fixedPrice=%.0f)", farmland.id, farmland.fixedPrice)
        else
            local priceBefore = farmland.price
            farmland:updatePrice()
            local priceDetails = RmFarmlandMarket.priceData[farmland.id]
            if priceDetails ~= nil and priceDetails.cropValue > 0 then
                farmlandsWithCrops = farmlandsWithCrops + 1
            end
            if math.abs(farmland.price - priceBefore) > 0.01 then
                changedPriceCount = changedPriceCount + 1
            end
        end
    end

    Log:info("Updated prices for %d farmlands (%d with crop value, %d changed)",
        totalFarmlands, farmlandsWithCrops, changedPriceCount)
    Log:trace("<<< updateAllFarmlandPrices()")
    return changedPriceCount
end

local function onStartMission()
    -- Reset the watchlist for-sale notification gate at mission start as
    -- defense in depth: BaseMission.delete normally resets it on session
    -- teardown, but if delete fails to fire (crash recovery, abnormal
    -- shutdown) the flag could carry stale "true" into the next session
    -- and skip the legitimate first-sync suppression.
    RmFmAvailability._initialSyncSeen = false

    RmFarmlandMarket.updateAllFarmlandPrices()
    RmFmAvailability.initialize()
    RmNegotiationManager.ensureListedProfiles()

    -- Host post-load rehydrate of the local watchlist cache. The savegame
    -- load already populated RmWatchlistStore.byFarm; push the local farm's
    -- subset into RmWatchlistUI.watched so the dialog sees persisted state
    -- on first open without a network round-trip.
    if g_server ~= nil then
        local farmId = RmWatchlistUI._localFarmId()
        if farmId ~= nil then
            local ids = RmWatchlistStore.pruneStaleSubset(farmId)
            RmWatchlistUI.replaceFromSync(ids)
            Log:debug("Watchlist host rehydrate: %d entries for farmId=%d", #ids, farmId)
        else
            -- Diagnostic: if a player reports their watchlist appears empty
            -- after load, this line in the log is the smoking gun (e.g.
            -- spectator host, dedicated server, or getFarmId not yet bound).
            Log:warning("Watchlist host rehydrate skipped: _localFarmId returned nil; UI cache stays empty until a sync arrives")
        end
    end

    Log:info("FarmlandMarket initialization complete")
end

local function onDeleteMap()
    Log:debug("Cleaning up FarmlandMarket")

    -- Unsubscribe from day change events
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, RmFarmlandMarket)
    g_messageCenter:unsubscribe(
        MessageType.SETTING_CHANGED[GameSettings.SETTING.USE_COLORBLIND_MODE],
        RmFarmlandMarket
    )

    -- Reset color blind mode state
    RmFarmlandMarket.isColorBlindMode = false

    -- Clean up availability state
    RmFmAvailability.reset()

    -- Reset the watchlist for-sale notification gate so a reconnect starts
    -- with a clean first-sync-is-silent posture.
    RmFmAvailability._initialSyncSeen = false

    -- Clean up watchlist server master so the next save load starts fresh.
    -- The local cache (RmWatchlistUI.watched) is wiped by RmWatchlistUI's
    -- own BaseMission.delete hook.
    RmWatchlistStore.reset()

    -- Clean up negotiation dialog
    local dialog = RmNegotiationDialog.getInstance()
    if dialog ~= nil then
        dialog:reset()
    end

    -- Remove console commands
    removeConsoleCommand("fmList")
    removeConsoleCommand("fmInspect")
    removeConsoleCommand("fmAvail")
    removeConsoleCommand("fmTestDialog")

    -- Clear cached data
    RmFarmlandMarket.priceData = {}
end

-- Hook into map loading completion (early init: console commands, settings)
BaseMission.loadMapFinished = Utils.appendedFunction(
    BaseMission.loadMapFinished,
    onLoadMapFinished
)

-- Hook into mission start (farmlands and fields fully loaded)
FSBaseMission.onStartMission = Utils.appendedFunction(
    FSBaseMission.onStartMission,
    onStartMission
)

-- Hook into map cleanup
BaseMission.delete = Utils.appendedFunction(
    BaseMission.delete,
    onDeleteMap
)

-- Hook into savegame load
Mission00.loadItemsFinished = Utils.appendedFunction(
    Mission00.loadItemsFinished,
    loadFromSavegame
)

-- Hook into savegame save
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
    FSCareerMissionInfo.saveToXMLFile,
    saveToSavegame
)

-- Hook into ownership changes to refresh map display (deferred to next frame)
FarmlandManager.setLandOwnership = Utils.appendedFunction(
    FarmlandManager.setLandOwnership,
    function(_, _, _, isFromSavegame)
        if not isFromSavegame then
            Timer.createOneshot(0, RmFarmlandMarket.refreshMapDisplay)
        end
    end
)

-- Hook into initial client state sync (send availability + watchlist subset
-- to joining clients). RmFmSettings.setupHooks installs a separate hook for
-- settings sync; this hook covers availability and watchlist together.
FSBaseMission.sendInitialClientState = Utils.appendedFunction(
    FSBaseMission.sendInitialClientState,
    function(_, connection)
        if g_server ~= nil then
            RmFmAvailability.sendInitialClientState(connection)
            RmWatchlistStore.sendInitialClientState(connection)
        end
    end
)

Log:info("FarmlandMarket mod loaded (v%s)",
    g_modManager:getModByName(RmFarmlandMarket.modName).version)
