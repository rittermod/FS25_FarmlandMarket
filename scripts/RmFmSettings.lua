--[[
    RmFmSettings.lua
    Settings module for FarmlandMarket.

    Manages:
    - In-game settings UI (cloned from gameSettingsLayout)
    - Network sync via RmSettingsSyncEvent
    - Savegame persistence
    - Multiplayer lifecycle hooks

    Settings:
    - Availability preset (MultiTextOption): off, easy, normal, hard, harder, realistic
    - Negotiate purchases (BinaryOption): on/off - negotiate listed field buys
    - Negotiate sales (BinaryOption): on/off - negotiate field sales
    - Unlisted offers (BinaryOption): on/off - make offers on unlisted fields
    - Base price per hectare (Button + TextInputDialog): custom absolute price, 0 = map default

    Author: Ritter
]]

RmFmSettings = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- MODULE STATE
-- ============================================================================

-- Settings state (1-indexed for MultiTextOption)
RmFmSettings.availabilityPresetState = 3   -- Default: 3 = Normal (index into PRESET_ORDER)
RmFmSettings.customPricePerHa = 0          -- 0 = use map default, otherwise absolute price/ha (1-9999999)
RmFmSettings.negotiateBuyState = 2          -- Default: 2 = On (BinaryOption: 1=Off, 2=On)
RmFmSettings.negotiateSellState = 2         -- Default: 2 = On (BinaryOption: 1=Off, 2=On)
RmFmSettings.unlistedOffersState = 2        -- Default: 2 = On (BinaryOption: 1=Off, 2=On)

-- Price per hectare bounds
RmFmSettings.MIN_PRICE_PER_HA = 1
RmFmSettings.MAX_PRICE_PER_HA = 9999999

-- UI initialization flag
RmFmSettings.uiInitialized = false

-- ============================================================================
-- PUBLIC GETTERS
-- ============================================================================

--- Get the preset name string for the current availability setting.
---@return string presetName One of "off", "easy", "normal", "hard", "harder", "realistic"
function RmFmSettings.getPresetName()
    return RmFmAvailability.PRESET_ORDER[RmFmSettings.availabilityPresetState]
end

--- Check if availability system is enabled (any preset other than "off").
---@return boolean enabled
function RmFmSettings.isAvailabilityEnabled()
    return RmFmSettings.availabilityPresetState ~= 1
end

--- Get custom price per hectare (0 = use map default)
---@return number price
function RmFmSettings.getCustomPricePerHa()
    return RmFmSettings.customPricePerHa
end

--- Check if buy negotiation is enabled (listed fields).
---@return boolean
function RmFmSettings.isNegotiateBuyEnabled()
    return RmFmSettings.negotiateBuyState == 2
end

--- Check if sell negotiation is enabled.
---@return boolean
function RmFmSettings.isNegotiateSellEnabled()
    return RmFmSettings.negotiateSellState == 2
end

--- Check if unlisted offers are enabled.
---@return boolean
function RmFmSettings.isUnlistedOffersEnabled()
    return RmFmSettings.unlistedOffersState == 2
end

--- Check if any negotiation feature is active (for shared concerns like cooldown display).
---@return boolean
function RmFmSettings.isAnyNegotiationEnabled()
    return RmFmSettings.negotiateBuyState == 2
        or RmFmSettings.negotiateSellState == 2
        or RmFmSettings.unlistedOffersState == 2
end

-- ============================================================================
-- PUBLIC SETTERS (pure state apply - called from event run(), load, and tests)
-- ============================================================================

--- Set availability preset state (no network - use event for MP changes).
---@param state number State index (1-6, index into PRESET_ORDER)
function RmFmSettings.setAvailabilityPreset(state)
    Log:trace(">>> setAvailabilityPreset(state=%d)", state)
    RmFmSettings.availabilityPresetState = state
    Log:debug("SETTINGS: Availability preset = %s (state=%d)",
        RmFmSettings.getPresetName(), state)
    Log:trace("<<< setAvailabilityPreset()")
end

--- Set custom price per hectare and recalculate all farmland prices.
--- Canonical normalization: all entry points (UI, load, network) go through here.
--- (no network - use event for MP changes)
---@param price number Custom price per hectare (0 = map default, 1-9999999 = custom)
function RmFmSettings.setCustomPricePerHa(price)
    Log:trace(">>> setCustomPricePerHa(price=%s)", tostring(price))
    price = tonumber(price) or 0
    price = math.floor(price)
    if price > 0 then
        price = math.max(RmFmSettings.MIN_PRICE_PER_HA,
            math.min(RmFmSettings.MAX_PRICE_PER_HA, price))
    else
        price = 0  -- any non-positive value resets to map default
    end
    RmFmSettings.customPricePerHa = price
    RmFarmlandMarket.updateAllFarmlandPrices()
    RmNegotiationManager.invalidateSellerProfiles()
    if price > 0 then
        Log:info("Custom base price set to %d/ha, updating all farmland prices", price)
    else
        Log:info("Base price reset to map default, updating all farmland prices")
    end
    Log:trace("<<< setCustomPricePerHa()")
end

--- Set negotiate buy state (no network - use event for MP changes).
---@param state number BinaryOption: 1=Off, 2=On
function RmFmSettings.setNegotiateBuy(state)
    Log:trace(">>> setNegotiateBuy(state=%d)", state)
    RmFmSettings.negotiateBuyState = state
    Log:debug("SETTINGS: Negotiate buy = %s (state=%d)",
        RmFmSettings.isNegotiateBuyEnabled() and "enabled" or "disabled", state)
    Log:trace("<<< setNegotiateBuy()")
end

--- Set negotiate sell state (no network - use event for MP changes).
---@param state number BinaryOption: 1=Off, 2=On
function RmFmSettings.setNegotiateSell(state)
    Log:trace(">>> setNegotiateSell(state=%d)", state)
    RmFmSettings.negotiateSellState = state
    Log:debug("SETTINGS: Negotiate sell = %s (state=%d)",
        RmFmSettings.isNegotiateSellEnabled() and "enabled" or "disabled", state)
    Log:trace("<<< setNegotiateSell()")
end

--- Set unlisted offers state (no network - use event for MP changes).
---@param state number BinaryOption: 1=Off, 2=On
function RmFmSettings.setUnlistedOffers(state)
    Log:trace(">>> setUnlistedOffers(state=%d)", state)
    RmFmSettings.unlistedOffersState = state
    Log:debug("SETTINGS: Unlisted offers = %s (state=%d)",
        RmFmSettings.isUnlistedOffersEnabled() and "enabled" or "disabled", state)
    Log:trace("<<< setUnlistedOffers()")
end

-- ============================================================================
-- UI CALLBACKS
-- ============================================================================

-- Forward declaration (defined in LIFECYCLE HOOKS section)
local updateGameSettings

--- Apply settings change: direct on server, event on remote client.
---@param availabilityPresetState number Availability preset state (1-6)
---@param customPricePerHa number Custom price per hectare (0 = map default)
---@param negotiateBuyState number Negotiate buy state (BinaryOption: 1=Off, 2=On)
---@param negotiateSellState number Negotiate sell state (BinaryOption: 1=Off, 2=On)
---@param unlistedOffersState number Unlisted offers state (BinaryOption: 1=Off, 2=On)
local function sendSettingsChangeRequest(availabilityPresetState, customPricePerHa,
        negotiateBuyState, negotiateSellState, unlistedOffersState)
    Log:trace(">>> sendSettingsChangeRequest(preset=%d, price=%d, negBuy=%d, negSell=%d, unlisted=%d)",
        availabilityPresetState, customPricePerHa, negotiateBuyState, negotiateSellState, unlistedOffersState)
    if g_server ~= nil then
        -- Host/server: apply directly and broadcast to remote clients
        RmFmSettings.setAvailabilityPreset(availabilityPresetState)
        RmFmSettings.setCustomPricePerHa(customPricePerHa)
        RmFmSettings.setNegotiateBuy(negotiateBuyState)
        RmFmSettings.setNegotiateSell(negotiateSellState)
        RmFmSettings.setUnlistedOffers(unlistedOffersState)
        g_server:broadcastEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, customPricePerHa,
                negotiateBuyState, negotiateSellState, unlistedOffersState)
        )
        Log:info("Settings changed: preset=%s (%d) price/ha=%d negBuy=%s negSell=%s unlisted=%s",
            RmFmSettings.getPresetName(), availabilityPresetState, customPricePerHa,
            RmFmSettings.isNegotiateBuyEnabled() and "on" or "off",
            RmFmSettings.isNegotiateSellEnabled() and "on" or "off",
            RmFmSettings.isUnlistedOffersEnabled() and "on" or "off")
        -- Refresh UI immediately so button text reflects the change
        local settingsPage = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
        if settingsPage ~= nil then
            updateGameSettings(settingsPage)
        end
        -- Refresh map display so context box shows updated prices
        Timer.createOneshot(0, RmFarmlandMarket.refreshMapDisplay)
    elseif g_client ~= nil then
        -- Remote client: send to server for validation
        g_client:getServerConnection():sendEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, customPricePerHa,
                negotiateBuyState, negotiateSellState, unlistedOffersState)
        )
    end
    Log:trace("<<< sendSettingsChangeRequest()")
end

--- Callback: Availability preset changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (1-6, index into PRESET_ORDER)
local function onAvailabilityPresetChanged(_, state)
    Log:trace(">>> onAvailabilityPresetChanged(state=%d)", state)
    sendSettingsChangeRequest(state, RmFmSettings.customPricePerHa,
        RmFmSettings.negotiateBuyState, RmFmSettings.negotiateSellState, RmFmSettings.unlistedOffersState)
    Log:trace("<<< onAvailabilityPresetChanged()")
end

--- Restore focus and scroll position to price button after dialog closes.
--- Deferred via Timer.createOneshot because the dialog callback fires before
--- the dialog's close() resets focus - immediate setFocus gets overridden.
local function schedulePriceButtonFocusRestore()
    Timer.createOneshot(100, function()
        local settingsPage = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
        if settingsPage ~= nil and settingsPage.fmPricePerHaButton ~= nil then
            local button = settingsPage.fmPricePerHaButton
            FocusManager:setFocus(button)
            local scrollPanel = button.parent
            while scrollPanel ~= nil and scrollPanel:isa(ScrollingLayoutElement) == false do
                scrollPanel = scrollPanel.parent
            end
            if scrollPanel ~= nil then
                scrollPanel:scrollToMakeElementVisible(button)
            end
            Log:trace("FOCUS: Restored focus to price button")
        end
    end)
end

--- Callback: TextInputDialog result for price/ha
---@param text string|nil User input text
---@param clickedOk boolean Whether user clicked OK
local function onPriceInputResult(text, clickedOk)
    Log:trace(">>> onPriceInputResult(text=%s, ok=%s)", tostring(text), tostring(clickedOk))
    if not clickedOk then
        schedulePriceButtonFocusRestore()
        Log:trace("<<< onPriceInputResult() cancelled")
        return
    end
    local newPrice = 0  -- default = map default
    if text ~= nil and text ~= "" then
        local parsed = tonumber(text)
        if parsed == nil then
            Log:debug("PRICE_INPUT: Invalid input '%s', ignoring", text)
            schedulePriceButtonFocusRestore()
            Log:trace("<<< onPriceInputResult() invalid input")
            return
        end
        newPrice = math.floor(parsed)
        if newPrice <= 0 then
            newPrice = 0  -- treat 0 or negative as reset
        else
            newPrice = math.max(RmFmSettings.MIN_PRICE_PER_HA,
                math.min(RmFmSettings.MAX_PRICE_PER_HA, newPrice))
        end
    end
    Log:debug("PRICE_INPUT: newPrice=%d (0=map default)", newPrice)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, newPrice,
        RmFmSettings.negotiateBuyState, RmFmSettings.negotiateSellState, RmFmSettings.unlistedOffersState)
    schedulePriceButtonFocusRestore()
    Log:trace("<<< onPriceInputResult()")
end

--- Callback: Price/ha button clicked - opens TextInputDialog
local function onPriceButtonClicked()
    Log:trace(">>> onPriceButtonClicked()")
    local effectivePrice = RmFmSettings.customPricePerHa
    if effectivePrice == 0 and g_farmlandManager ~= nil then
        effectivePrice = g_farmlandManager.pricePerHa or 0
    end
    local defaultText = effectivePrice > 0 and tostring(effectivePrice) or ""
    local basePrice = g_farmlandManager ~= nil and g_farmlandManager.pricePerHa or 0
    local prompt = string.format(
        g_i18n:getText("rm_fm_settings_pricePerHa_dialogPrompt"),
        g_i18n:formatMoney(basePrice, 0, true))
    local confirmText = g_i18n:getText("rm_fm_settings_pricePerHa_dialogConfirm")
    TextInputDialog.show(onPriceInputResult, nil, defaultText, prompt, nil, 7, confirmText)
    Log:trace("<<< onPriceButtonClicked()")
end

--- Callback: Negotiate purchases changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (BinaryOption: 1=Off, 2=On)
local function onNegotiateBuyChanged(_, state)
    Log:trace(">>> onNegotiateBuyChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, RmFmSettings.customPricePerHa,
        state, RmFmSettings.negotiateSellState, RmFmSettings.unlistedOffersState)
    Log:trace("<<< onNegotiateBuyChanged()")
end

--- Callback: Negotiate sales changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (BinaryOption: 1=Off, 2=On)
local function onNegotiateSellChanged(_, state)
    Log:trace(">>> onNegotiateSellChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, RmFmSettings.customPricePerHa,
        RmFmSettings.negotiateBuyState, state, RmFmSettings.unlistedOffersState)
    Log:trace("<<< onNegotiateSellChanged()")
end

--- Callback: Unlisted offers changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (BinaryOption: 1=Off, 2=On)
local function onUnlistedOffersChanged(_, state)
    Log:trace(">>> onUnlistedOffersChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, RmFmSettings.customPricePerHa,
        RmFmSettings.negotiateBuyState, RmFmSettings.negotiateSellState, state)
    Log:trace("<<< onUnlistedOffersChanged()")
end

-- ============================================================================
-- UI HELPERS
-- ============================================================================

-- Cloned containers for FocusManager registration
local fmClonedControls = {}

--- Recursively assign unique focusIds to a cloned element and all its children.
--- Cloned elements inherit duplicate focusIds from their templates, which breaks
--- FocusManager navigation. Pattern from ForestryHelper UIHelper / PlayerMovement.
---@param element table GUI element
local function updateFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

-- ============================================================================
-- UI INITIALIZATION
-- ============================================================================

--- Initialize settings UI by cloning elements from game settings page.
--- Called at source time (g_inGameMenu is available).
function RmFmSettings.initGui()
    Log:trace(">>> initGui()")

    -- Guard: skip on dedicated server
    if g_dedicatedServer ~= nil then
        return
    end

    -- Guard: g_inGameMenu not available
    if g_inGameMenu == nil then
        Log:warning("g_inGameMenu not available, skipping GUI init")
        return
    end

    local settingsPage = g_inGameMenu.pageSettings
    if settingsPage == nil then
        Log:warning("Settings page not found, skipping GUI init")
        return
    end

    local scrollPanel = settingsPage.gameSettingsLayout
    if scrollPanel == nil then
        Log:warning("Game settings layout not found, skipping GUI init")
        return
    end

    -- Find templates by scanning elements
    local sectionHeaderTemplate = nil
    local multiTextOptionTemplate = nil
    local binaryOptionTemplate = nil
    local buttonTemplate = nil

    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeaderTemplate == nil then
            sectionHeaderTemplate = element
        end
        if element.typeName == "Bitmap" and element.elements[1] ~= nil then
            if element.elements[1].typeName == "MultiTextOption" and multiTextOptionTemplate == nil then
                multiTextOptionTemplate = element
            end
            if element.elements[1].typeName == "BinaryOption" and binaryOptionTemplate == nil then
                binaryOptionTemplate = element
            end
            if element.elements[1].typeName == "Button" and buttonTemplate == nil then
                buttonTemplate = element
            end
        end
        if sectionHeaderTemplate ~= nil and multiTextOptionTemplate ~= nil
                and binaryOptionTemplate ~= nil and buttonTemplate ~= nil then
            break
        end
    end

    if sectionHeaderTemplate == nil or multiTextOptionTemplate == nil then
        Log:warning("Could not find UI templates in gameSettingsLayout")
        return
    end

    -- Clone section header
    local header = sectionHeaderTemplate:clone(scrollPanel)
    updateFocusIds(header)
    header:setText(g_i18n:getText("rm_fm_settings_section"))

    -- Clone availability preset (MultiTextOption)
    local availabilityContainer = multiTextOptionTemplate:clone(scrollPanel)
    updateFocusIds(availabilityContainer)
    availabilityContainer.id = nil  -- clear cloned ID to avoid conflicts

    local availabilityControl = availabilityContainer.elements[1]
    local availabilityLabel = availabilityContainer.elements[2]

    availabilityLabel:setText(g_i18n:getText("rm_fm_settings_availability"))
    availabilityLabel.id = nil
    availabilityControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_availability_tooltip"))
    availabilityControl.id = "fmAvailabilityPreset"
    availabilityControl:setTexts({
        g_i18n:getText("ui_off"),
        g_i18n:getText("rm_fm_preset_easy"),
        g_i18n:getText("rm_fm_preset_normal"),
        g_i18n:getText("rm_fm_preset_hard"),
        g_i18n:getText("rm_fm_preset_harder"),
        g_i18n:getText("rm_fm_preset_realistic"),
    })
    availabilityControl:setState(RmFmSettings.availabilityPresetState)
    availabilityControl.onClickCallback = onAvailabilityPresetChanged

    availabilityContainer:setVisible(true)
    availabilityContainer:setDisabled(false)

    -- Store reference for state updates in updateGameSettings
    settingsPage.fmAvailabilityControl = availabilityControl

    -- Clone negotiate purchases toggle (BinaryOption: 1=Off, 2=On)
    local negBuyTemplate = binaryOptionTemplate or multiTextOptionTemplate
    local negBuyContainer = negBuyTemplate:clone(scrollPanel)
    updateFocusIds(negBuyContainer)
    negBuyContainer.id = nil

    local negBuyControl = negBuyContainer.elements[1]
    local negBuyLabel = negBuyContainer.elements[2]

    negBuyLabel:setText(g_i18n:getText("rm_fm_settings_negotiateBuy"))
    negBuyLabel.id = nil
    negBuyControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_negotiateBuy_tooltip"))
    negBuyControl.id = "fmNegotiateBuy"
    if binaryOptionTemplate == nil then
        negBuyControl:setTexts({ g_i18n:getText("ui_off"), g_i18n:getText("ui_on") })
    end
    -- NOTE: Do NOT call setState here for BinaryOption. The slider positions itself
    -- based on element dimensions which are zero at source time. updateGameSettings
    -- will set the correct state when the frame opens with real dimensions.
    negBuyControl.onClickCallback = onNegotiateBuyChanged

    negBuyContainer:setVisible(true)
    negBuyContainer:setDisabled(false)

    settingsPage.fmNegotiateBuyControl = negBuyControl

    -- Clone negotiate sales toggle (BinaryOption: 1=Off, 2=On)
    local negSellContainer = negBuyTemplate:clone(scrollPanel)
    updateFocusIds(negSellContainer)
    negSellContainer.id = nil

    local negSellControl = negSellContainer.elements[1]
    local negSellLabel = negSellContainer.elements[2]

    negSellLabel:setText(g_i18n:getText("rm_fm_settings_negotiateSell"))
    negSellLabel.id = nil
    negSellControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_negotiateSell_tooltip"))
    negSellControl.id = "fmNegotiateSell"
    if binaryOptionTemplate == nil then
        negSellControl:setTexts({ g_i18n:getText("ui_off"), g_i18n:getText("ui_on") })
    end
    negSellControl.onClickCallback = onNegotiateSellChanged

    negSellContainer:setVisible(true)
    negSellContainer:setDisabled(false)

    settingsPage.fmNegotiateSellControl = negSellControl

    -- Clone unlisted offers toggle (BinaryOption: 1=Off, 2=On)
    local unlistedContainer = negBuyTemplate:clone(scrollPanel)
    updateFocusIds(unlistedContainer)
    unlistedContainer.id = nil

    local unlistedControl = unlistedContainer.elements[1]
    local unlistedLabel = unlistedContainer.elements[2]

    unlistedLabel:setText(g_i18n:getText("rm_fm_settings_unlistedOffers"))
    unlistedLabel.id = nil
    unlistedControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_unlistedOffers_tooltip"))
    unlistedControl.id = "fmUnlistedOffers"
    if binaryOptionTemplate == nil then
        unlistedControl:setTexts({ g_i18n:getText("ui_off"), g_i18n:getText("ui_on") })
    end
    unlistedControl.onClickCallback = onUnlistedOffersChanged

    unlistedContainer:setVisible(true)
    unlistedContainer:setDisabled(false)

    settingsPage.fmUnlistedOffersControl = unlistedControl

    -- Track cloned containers for FocusManager registration (visual order)
    fmClonedControls = { header, availabilityContainer, negBuyContainer, negSellContainer, unlistedContainer }

    -- Clone price per ha button (skip if no button template found)
    if buttonTemplate == nil then
        Log:warning("SETTINGS: No button template found in settings layout, price/ha button not created")
    else
        local priceContainer = buttonTemplate:clone(scrollPanel)
        updateFocusIds(priceContainer)
        priceContainer.id = nil

        local priceButton = priceContainer.elements[1]
        local priceLabel = priceContainer.elements[2]

        priceLabel:setText(g_i18n:getText("rm_fm_settings_pricePerHa"))
        priceLabel.id = nil
        priceButton:applyProfile("rmFmSettingsButton")
        -- Tooltip is set dynamically in updateGameSettings() (Button children differ from MultiTextOption)
        priceButton.id = "fmPricePerHa"
        priceButton.isAlwaysFocusedOnOpen = false
        priceButton.focused = false
        priceButton.onClickCallback = onPriceButtonClicked

        priceContainer:setVisible(true)
        priceContainer:setDisabled(false)

        settingsPage.fmPricePerHaButton = priceButton

        fmClonedControls[#fmClonedControls + 1] = priceContainer
    end

    scrollPanel:invalidateLayout()

    RmFmSettings.uiInitialized = true
    Log:info("Settings GUI initialized (%d elements cloned, focusIds updated)", #fmClonedControls)
    Log:trace("<<< initGui()")
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

--- Hook: Sync settings UI state when settings frame opens
---@param settingsPage table InGameMenuSettingsFrame instance
updateGameSettings = function(settingsPage)
    Log:trace(">>> updateGameSettings()")

    if settingsPage.fmAvailabilityControl ~= nil then
        settingsPage.fmAvailabilityControl:setState(RmFmSettings.availabilityPresetState)
    end

    if settingsPage.fmPricePerHaButton ~= nil then
        Log:trace("SETTINGS_UI: Updating price/ha button text")
        local effectivePrice = RmFmSettings.customPricePerHa
        local isDefault = (effectivePrice == 0)
        if isDefault and g_farmlandManager ~= nil then
            effectivePrice = g_farmlandManager.pricePerHa or 0
        end
        local formattedPrice = g_i18n:formatMoney(effectivePrice, 0, true)
        if isDefault then
            settingsPage.fmPricePerHaButton:setText(
                string.format(g_i18n:getText("rm_fm_settings_pricePerHa_buttonDefault"), formattedPrice))
        else
            settingsPage.fmPricePerHaButton:setText(
                string.format(g_i18n:getText("rm_fm_settings_pricePerHa_buttonCustom"), formattedPrice))
        end
        -- Update tooltip with map default (guard: Button children may not have setText)
        if g_farmlandManager ~= nil and g_farmlandManager.pricePerHa ~= nil then
            local tooltipElement = settingsPage.fmPricePerHaButton.elements[1]
            if tooltipElement ~= nil and tooltipElement.setText ~= nil then
                local basePrice = g_farmlandManager.pricePerHa
                local tooltip = string.format("%s\n%s: %s/ha",
                    g_i18n:getText("rm_fm_settings_pricePerHa_tooltip"),
                    g_i18n:getText("rm_fm_settings_pricePerHa_mapDefault"),
                    g_i18n:formatMoney(basePrice, 0, true))
                tooltipElement:setText(tooltip)
            end
        end
    end

    if settingsPage.fmNegotiateBuyControl ~= nil then
        settingsPage.fmNegotiateBuyControl:setState(RmFmSettings.negotiateBuyState)
    end
    if settingsPage.fmNegotiateSellControl ~= nil then
        settingsPage.fmNegotiateSellControl:setState(RmFmSettings.negotiateSellState)
    end
    if settingsPage.fmUnlistedOffersControl ~= nil then
        settingsPage.fmUnlistedOffersControl:setState(RmFmSettings.unlistedOffersState)
    end

    Log:trace("<<< updateGameSettings()")
end

--- Hook: Load settings from savegame XML (server only)
---@param xmlFile table Already-opened XMLFile handle
function RmFmSettings.loadFromXMLFile(xmlFile)
    Log:trace(">>> loadFromXMLFile()")

    if g_server == nil then
        Log:trace("<<< loadFromXMLFile() [not server]")
        return
    end

    local key = "rmFarmlandMarket.settings"
    RmFmSettings.availabilityPresetState = xmlFile:getValue(key .. "#availabilityPreset", 3)
    local rawPrice = xmlFile:getValue(key .. "#customPricePerHa", 0)
    RmFmSettings.setCustomPricePerHa(rawPrice)
    -- Migration: old single toggle -> three granular toggles
    local oldNeg = xmlFile:getValue(key .. "#negotiationEnabled")
    if oldNeg ~= nil then
        -- Old save: map single value to all three toggles
        RmFmSettings.negotiateBuyState = oldNeg
        RmFmSettings.negotiateSellState = oldNeg
        RmFmSettings.unlistedOffersState = oldNeg
        Log:info("MIGRATION: Mapped old negotiationEnabled=%d to all three toggles", oldNeg)
    else
        -- New save: load individual attributes (default 2=On, fixing pre-existing bug)
        RmFmSettings.negotiateBuyState = xmlFile:getValue(key .. "#negotiateBuy", 2)
        RmFmSettings.negotiateSellState = xmlFile:getValue(key .. "#negotiateSell", 2)
        RmFmSettings.unlistedOffersState = xmlFile:getValue(key .. "#unlistedOffers", 2)
    end

    Log:debug("Settings loaded: preset=%s price/ha=%d negBuy=%s negSell=%s unlisted=%s",
        RmFmSettings.getPresetName(), RmFmSettings.customPricePerHa,
        RmFmSettings.isNegotiateBuyEnabled() and "on" or "off",
        RmFmSettings.isNegotiateSellEnabled() and "on" or "off",
        RmFmSettings.isUnlistedOffersEnabled() and "on" or "off")

    Log:trace("<<< loadFromXMLFile()")
end

--- Hook: Save settings to savegame XML
---@param xmlFile table Already-opened XMLFile handle
function RmFmSettings.saveToXMLFile(xmlFile)
    Log:trace(">>> saveToXMLFile()")

    -- Server only
    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local key = "rmFarmlandMarket.settings"
    xmlFile:setValue(key .. "#availabilityPreset", RmFmSettings.availabilityPresetState)
    xmlFile:setValue(key .. "#customPricePerHa", RmFmSettings.customPricePerHa)
    xmlFile:setValue(key .. "#negotiateBuy", RmFmSettings.negotiateBuyState)
    xmlFile:setValue(key .. "#negotiateSell", RmFmSettings.negotiateSellState)
    xmlFile:setValue(key .. "#unlistedOffers", RmFmSettings.unlistedOffersState)

    Log:debug("Settings saved to savegame")

    Log:trace("<<< saveToXMLFile()")
end

--- Hook: Send initial client state on join
---@param _ any Unused
---@param connection table Client connection
function RmFmSettings.sendInitialClientState(_, connection)
    Log:trace(">>> sendInitialClientState(connection=%s)", connection ~= nil and "yes" or "no")

    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    connection:sendEvent(
        RmSettingsSyncEvent.new(RmFmSettings.availabilityPresetState, RmFmSettings.customPricePerHa,
            RmFmSettings.negotiateBuyState, RmFmSettings.negotiateSellState, RmFmSettings.unlistedOffersState)
    )

    Log:trace("<<< sendInitialClientState()")
end

--- Register lifecycle hooks
function RmFmSettings.setupHooks()
    Log:trace(">>> setupHooks()")

    -- Hook: Settings UI sync when frame opens
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings,
        updateGameSettings
    )

    -- Hook: Register cloned elements with FocusManager when GUI is set up.
    -- Without this, cloned elements are not in the FocusManager's element mapping
    -- and keyboard navigation skips them. Pattern from ForestryHelper / PlayerMovement.
    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        if gui == nil or #fmClonedControls == 0 then return end

        local registered = 0
        for _, control in ipairs(fmClonedControls) do
            if not control.focusId
                or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    registered = registered + 1
                else
                    Log:warning("FOCUS: Failed to register %s with FocusManager",
                        control.id or control.typeName or "?")
                end
            end
        end

        if registered > 0 then
            Log:trace("FOCUS: Registered %d controls with FocusManager", registered)
            local settingsPage = g_inGameMenu.pageSettings
            if settingsPage ~= nil and settingsPage.gameSettingsLayout ~= nil then
                settingsPage.gameSettingsLayout:invalidateLayout()
            end
        end
    end)

    -- Hook: Send initial state to joining clients
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        RmFmSettings.sendInitialClientState
    )

    Log:trace("<<< setupHooks()")
end

-- ============================================================================
-- MODULE INITIALIZATION (runs at source time)
-- ============================================================================

-- Load GUI profiles before initGui (needed for button profile)
g_gui:loadProfiles(g_currentModDirectory .. "gui/guiProfiles.xml")

RmFmSettings.initGui()
RmFmSettings.setupHooks()
