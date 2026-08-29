--[[
    RmNegotiationUI.lua
    UI controller for farmland negotiation.

    Orchestrates:
    - Buy/sell intercepts on InGameMenuMapFrame
    - Custom negotiation dialog (RmNegotiationDialog) for multi-round flow
    - Host/client async result handling
    - Purchase/sale execution via FarmlandStateEvent

    UI reads from session snapshots only - never calls engine directly.
    Works identically in single-player and multiplayer.

    Author: Ritter
]]

-- =============================================================================
-- MODULE DECLARATION
-- =============================================================================

RmNegotiationUI = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- =============================================================================
-- OUTCOME CONSTANT ASSERTIONS (catch nil references early)
-- =============================================================================

assert(RmNegotiationEngine.OUTCOME_DEAL ~= nil, "OUTCOME_DEAL is nil")
assert(RmNegotiationEngine.OUTCOME_REJECTED ~= nil, "OUTCOME_REJECTED is nil")
assert(RmNegotiationEngine.OUTCOME_DISMISSED ~= nil, "OUTCOME_DISMISSED is nil")
assert(RmNegotiationEngine.OUTCOME_NPC_WALKED ~= nil, "OUTCOME_NPC_WALKED is nil")
assert(RmNegotiationManager.OUTCOME_WALKAWAY ~= nil, "OUTCOME_WALKAWAY is nil")
assert(RmNegotiationEngine.MODE_LISTED_BUY ~= nil, "MODE_LISTED_BUY is nil")
assert(RmNegotiationEngine.MODE_UNLISTED_BUY ~= nil, "MODE_UNLISTED_BUY is nil")
assert(RmNegotiationEngine.MODE_SELL ~= nil, "MODE_SELL is nil")

-- =============================================================================
-- CLIENT-SIDE STATE
-- =============================================================================

-- Callback for pending async results (client-only)
RmNegotiationUI.pendingCallback = nil

-- Current negotiation context (set when flow starts)
RmNegotiationUI.currentFarmlandId = nil
RmNegotiationUI.currentFarmId = nil
RmNegotiationUI.currentMode = nil  -- "listed_buy"|"unlisted_buy"|"sell"

-- =============================================================================
-- FORWARD DECLARATIONS (Lua 5.1: local functions with circular refs)
-- =============================================================================

local handleResult
local openDialog
local updateDialog
local setupDialogCallbacks
local setActionStateFromSnapshot
local executeDeal

-- =============================================================================
-- INTERNAL HELPERS (local)
-- =============================================================================

--- Call a NegotiationManager API function, handling host/client routing.
--- On host: calls apiFn immediately, invokes onResult with return values.
--- On client: stores onResult as pendingCallback, apiFn returns nil/"pending".
---@param apiFn function The manager API function to call
---@param args table Array of arguments to pass
---@param onResult function Callback: function(snapshot, errorReason)
local function callManagerAPI(apiFn, args, onResult)
    Log:trace(">>> callManagerAPI()")
    local snapshot, errorReason = apiFn(unpack(args))

    if g_server ~= nil then
        -- HOST: immediate result
        Log:trace("  callManagerAPI: host path, immediate result")
        onResult(snapshot, errorReason)
    else
        -- CLIENT: async - result arrives via RmNegotiationResultEvent
        if errorReason == "pending" then
            Log:trace("  callManagerAPI: client path, storing pendingCallback")
            RmNegotiationUI.pendingCallback = onResult
        else
            -- Unexpected: client got immediate result (shouldn't happen)
            Log:warning("callManagerAPI: client got immediate result, dispatching")
            onResult(snapshot, errorReason)
        end
    end
    Log:trace("<<< callManagerAPI()")
end

--- Format a price for display.
---@param amount number
---@return string
local function formatPrice(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

--- Close the negotiation dialog if it is currently open.
local function closeNegotiationDialog()
    local dialog = RmNegotiationDialog.getInstance()
    if dialog ~= nil and dialog.isOpen then
        dialog:close()
    end
end

--- Get the display name of the NPC owner of a farmland.
--- Returns the NPC title (e.g. "Walter") or the generic "Seller" l10n string as fallback.
---@param farmlandId number
---@return string
local function getOwnerDisplayName(farmlandId)
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland ~= nil then
        local npc = farmland:getNPC()
        if npc ~= nil and npc.title ~= nil then
            return npc.title
        end
    end
    return g_i18n:getText("rm_fm_neg_dlg_seller")
end

--- Send cancel request to server (fire-and-forget).
--- On host, cancels directly. On client, sends event for server-side lock/session cleanup.
--- `userInitiated` is true only for the explicit sell "Walk Away" affordance; it rides
--- the cancel event's `accept` slot (no wire change) and triggers the selling_cancel
--- cooldown server-side. All other callers omit it (default no-cooldown cleanup).
---@param farmId number
---@param userInitiated boolean|nil
local function sendCancelToServer(farmId, userInitiated)
    userInitiated = userInitiated == true  -- normalize once so host and client agree
    if g_server ~= nil then
        RmNegotiationManager.cancelSession(farmId, userInitiated)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("cancel", 0, 0, userInitiated, "")
        )
    end
end

-- =============================================================================
-- DIALOG CONTROLLER FUNCTIONS
-- =============================================================================

--- Open the negotiation dialog with a snapshot.
---@param snapshot table Session snapshot
openDialog = function(snapshot)
    Log:trace(">>> openDialog(farmland=%d, mode=%s)", snapshot.farmlandId, snapshot.mode)
    local dialog = RmNegotiationDialog.getInstance()
    if dialog == nil then
        Log:error("RmNegotiationDialog not registered")
        return
    end
    setupDialogCallbacks(dialog)
    -- showDialog FIRST: onOpen() clears all visual state (buttons, status text, history)
    -- Then apply snapshot data so it isn't wiped by the cleanup
    g_gui:showDialog("RmNegotiationDialog")
    dialog:updateFromSnapshot(snapshot)
    setActionStateFromSnapshot(dialog, snapshot)
end

--- Update an already-open negotiation dialog with a new snapshot.
---@param snapshot table Session snapshot
updateDialog = function(snapshot)
    Log:trace(">>> updateDialog(farmland=%d, state=%s)", snapshot.farmlandId, snapshot.state)
    local dialog = RmNegotiationDialog.getInstance()
    if dialog == nil then return end
    dialog:updateFromSnapshot(snapshot)
    setActionStateFromSnapshot(dialog, snapshot)
end

--- Map snapshot state to dialog action state.
---@param dialog RmNegotiationDialog
---@param snapshot table Session snapshot
setActionStateFromSnapshot = function(dialog, snapshot)
    local maxRounds = RmNegotiationEngine.getMaxRounds()
    local mode = snapshot.mode
    local state = snapshot.state
    local round = snapshot.round
    -- Resolve NPC owner name for buy modes
    local ownerName = (mode ~= RmNegotiationEngine.MODE_SELL)
        and getOwnerDisplayName(snapshot.farmlandId) or nil

    if state == "completed" then
        local msg = RmNegotiationUI.getCompletedMessage(snapshot, ownerName)
        dialog:setActionState(RmNegotiationDialog.STATE_COMPLETED, { statusText = msg })
        return
    end

    if state == "proposal" then
        local proposal = snapshot.pendingProposal
        if proposal == nil then
            Log:warning("setActionStateFromSnapshot: proposal state but no pendingProposal")
            return
        end
        local promptKey = proposal.type == "convergence"
            and "rm_fm_neg_convergence" or "rm_fm_neg_lastDitch"
        local msg = string.format(g_i18n:getText(promptKey),
            ownerName or "", formatPrice(proposal.price))
        dialog:setActionState(RmNegotiationDialog.STATE_PROPOSAL, { statusText = msg })
        return
    end

    -- state == "active"
    if mode == RmNegotiationEngine.MODE_LISTED_BUY then
        if round == 1 and #snapshot.offers == 0 then
            -- Opening: player views listing before making offer
            local msg = string.format(g_i18n:getText("rm_fm_neg_listedOpening"),
                formatPrice(snapshot.anchorPrice))
            dialog:setActionState(RmNegotiationDialog.STATE_OPENING, { statusText = msg })
        elseif round > maxRounds then
            -- Final round exhausted
            local msg = string.format(g_i18n:getText("rm_fm_neg_roundsExhausted"),
                ownerName, formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_WALK, { statusText = msg })
        elseif round == 1 then
            -- Round 1 after Make Offer clicked: player needs to enter offer
            local msg = string.format(g_i18n:getText("rm_fm_neg_listedOpening"),
                formatPrice(snapshot.anchorPrice))
            dialog:setActionState(RmNegotiationDialog.STATE_OFFER_INPUT, { statusText = msg })
        else
            -- Rounds 2+: seller countered, player can accept or counter
            local msg = string.format(g_i18n:getText("rm_fm_neg_sellerCounters"),
                ownerName, formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_COUNTER, { statusText = msg })
        end

    elseif mode == RmNegotiationEngine.MODE_UNLISTED_BUY then
        if round == 1 and #snapshot.offers == 0 then
            -- Unlisted opening: owner demands a price
            local msg = string.format(g_i18n:getText("rm_fm_neg_unlistedOpening"),
                ownerName, formatPrice(snapshot.anchorPrice))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_COUNTER, { statusText = msg })
        elseif round > maxRounds then
            local msg = string.format(g_i18n:getText("rm_fm_neg_roundsExhausted"),
                ownerName, formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_WALK, { statusText = msg })
        else
            local msg = string.format(g_i18n:getText("rm_fm_neg_sellerCounters"),
                ownerName, formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_COUNTER, { statusText = msg })
        end

    elseif mode == RmNegotiationEngine.MODE_SELL then
        if round == 1 and #snapshot.offers == 0 then
            -- Sell opening: NPC makes first offer
            local msg = string.format(g_i18n:getText("rm_fm_neg_npcOpening"),
                formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_COUNTER, { statusText = msg })
        elseif round > maxRounds then
            local msg = string.format(g_i18n:getText("rm_fm_neg_sellRoundsExhausted"),
                formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_WALK, { statusText = msg })
        else
            local msg = string.format(g_i18n:getText("rm_fm_neg_npcRaises"),
                formatPrice(snapshot.lastCounter))
            dialog:setActionState(RmNegotiationDialog.STATE_ACCEPT_COUNTER, { statusText = msg })
        end
    end
end

--- Wire dialog callbacks to Manager API calls.
---@param dialog RmNegotiationDialog
setupDialogCallbacks = function(dialog)
    local farmId = RmNegotiationUI.currentFarmId
    local mode = RmNegotiationUI.currentMode

    dialog.onMakeOffer = function()
        -- Transition from STATE_OPENING to STATE_OFFER_INPUT (no Manager call)
        dialog.previousButtonState = RmNegotiationDialog.STATE_OPENING
        dialog.previousStatusText = dialog.statusTextElement ~= nil and dialog.statusTextElement:getText() or nil
        dialog:setActionState(RmNegotiationDialog.STATE_OFFER_INPUT, {
            statusText = g_i18n:getText("rm_fm_neg_enterOffer")
        })
    end

    dialog.onSubmitOffer = function(amount)
        local apiFn = (mode == RmNegotiationEngine.MODE_SELL)
            and RmNegotiationManager.submitAsk
            or RmNegotiationManager.submitOffer
        callManagerAPI(apiFn, { farmId, amount }, handleResult)
        if g_server == nil then
            dialog:setActionState(RmNegotiationDialog.STATE_WAITING,
                { statusText = g_i18n:getText("rm_fm_neg_dlg_waiting") })
        end
    end

    dialog.onAcceptPrice = function()
        local snap = dialog.currentSnapshot
        local amount = snap.lastCounter or snap.anchorPrice
        local apiFn = (mode == RmNegotiationEngine.MODE_SELL)
            and RmNegotiationManager.submitAsk
            or RmNegotiationManager.submitOffer
        callManagerAPI(apiFn, { farmId, amount }, handleResult)
        if g_server == nil then
            dialog:setActionState(RmNegotiationDialog.STATE_WAITING,
                { statusText = g_i18n:getText("rm_fm_neg_dlg_waiting") })
        end
    end

    dialog.onWalkAway = function()
        if mode == RmNegotiationEngine.MODE_SELL then
            -- Sell mode: deliberate walk-away -> immediate abort + light selling_cancel
            -- re-list cooldown. userInitiated=true is passed ONLY here; the
            -- shared dialog back/ESC reaches this same path via onClickBottomBar.
            sendCancelToServer(farmId, true)
            dialog:close()
            RmNegotiationUI.clearState()
        else
            -- Buy mode: action depends on session state
            if dialog.currentState == RmNegotiationDialog.STATE_PROPOSAL then
                -- Walking away from a proposal = decline it (triggers cooldown)
                callManagerAPI(RmNegotiationManager.respondToProposal, { farmId, false }, handleResult)
            else
                -- Normal walkaway (cooldown + possible last-ditch)
                callManagerAPI(RmNegotiationManager.walkaway, { farmId }, handleResult)
            end
            if g_server == nil then
                dialog:setActionState(RmNegotiationDialog.STATE_WAITING,
                    { statusText = g_i18n:getText("rm_fm_neg_dlg_waiting") })
            end
        end
    end

    dialog.onAcceptProposal = function()
        callManagerAPI(RmNegotiationManager.respondToProposal, { farmId, true }, handleResult)
        if g_server == nil then
            dialog:setActionState(RmNegotiationDialog.STATE_WAITING,
                { statusText = g_i18n:getText("rm_fm_neg_dlg_waiting") })
        end
    end

    dialog.onDeclineProposal = function()
        callManagerAPI(RmNegotiationManager.respondToProposal, { farmId, false }, handleResult)
        if g_server == nil then
            dialog:setActionState(RmNegotiationDialog.STATE_WAITING,
                { statusText = g_i18n:getText("rm_fm_neg_dlg_waiting") })
        end
    end
end

--- Map a completed snapshot outcome to a display message.
--- Module-level for testability.
---@param snapshot table Completed session snapshot
---@param ownerName string|nil NPC owner display name (buy modes only)
---@return string
function RmNegotiationUI.getCompletedMessage(snapshot, ownerName)
    local outcome = snapshot.outcome
    local name = ownerName or g_i18n:getText("rm_fm_neg_dlg_seller")
    if outcome == RmNegotiationEngine.OUTCOME_DEAL then
        local key = (snapshot.mode == RmNegotiationEngine.MODE_SELL)
            and "rm_fm_neg_dealSell" or "rm_fm_neg_dealBuy"
        return string.format(g_i18n:getText(key), formatPrice(snapshot.finalPrice))
    elseif outcome == RmNegotiationEngine.OUTCOME_REJECTED then
        return string.format(g_i18n:getText("rm_fm_neg_rejected"), name)
    elseif outcome == RmNegotiationEngine.OUTCOME_DISMISSED then
        return string.format(g_i18n:getText("rm_fm_neg_dismissed"), name)
    elseif outcome == RmNegotiationEngine.OUTCOME_NPC_WALKED then
        return g_i18n:getText("rm_fm_neg_npcWalked")
    elseif outcome == RmNegotiationManager.OUTCOME_WALKAWAY then
        return g_i18n:getText("rm_fm_neg_walkedAway")
    else
        return g_i18n:getText("rm_fm_neg_ended")
    end
end

--- Map an error reason to a display message.
--- Module-level for testability.
---@param errorReason string
---@return string
function RmNegotiationUI.getErrorMessage(errorReason)
    if errorReason == "cooldown" then
        local isSell = RmNegotiationUI.currentMode == RmNegotiationEngine.MODE_SELL
        local info = RmNegotiationManager.getCooldownInfo(
            RmNegotiationUI.currentFarmlandId, RmNegotiationUI.currentFarmId)
        if info then
            -- Shared display seam: whole days (< 1 period) or whole months,
            -- nil when expired (fall through to the generic message).
            local msg = RmNegotiationManager.formatCooldownRemaining(info.remaining, isSell, nil)
            if msg ~= nil then return msg end
        end
        local key = isSell and "rm_fm_neg_cooldownSell" or "rm_fm_neg_cooldown"
        return g_i18n:getText(key)
    elseif errorReason == "locked" then
        return g_i18n:getText("rm_fm_neg_locked")
    elseif errorReason == "insufficient_funds" then
        return g_i18n:getText("rm_fm_neg_insufficientFunds")
    elseif errorReason == "invalid_farmland" then
        return g_i18n:getText("rm_fm_neg_invalidFarmland")
    elseif errorReason == "listing_too_high" then
        return g_i18n:getText("rm_fm_neg_listingTooHigh2")
    elseif errorReason == "offer_not_higher" then
        return g_i18n:getText("rm_fm_neg_offerNotHigher")
    elseif errorReason == "ask_not_lower" then
        return g_i18n:getText("rm_fm_neg_askNotLower")
    elseif errorReason == "listed_buy_disabled" then
        return g_i18n:getText("rm_fm_neg_listedBuyDisabled")
    elseif errorReason == "unlisted_offers_disabled" then
        return g_i18n:getText("rm_fm_neg_unlistedOffersDisabled")
    elseif errorReason == "sell_negotiation_disabled" then
        return g_i18n:getText("rm_fm_neg_sellNegotiationDisabled")
    elseif errorReason == "farmland_not_listed" then
        return g_i18n:getText("rm_fm_neg_farmlandNotListed")
    elseif errorReason == "farmland_is_listed" then
        return g_i18n:getText("rm_fm_neg_farmlandIsListed")
    end
    return string.format(g_i18n:getText("rm_fm_neg_error"), tostring(errorReason))
end

-- =============================================================================
-- CORE STATE MACHINE DISPATCHER
-- =============================================================================

--- Process a snapshot after a manager action and show/update the negotiation dialog.
---@param snapshot table|nil Session snapshot
---@param errorReason string|nil Error reason if failed
handleResult = function(snapshot, errorReason)
    Log:trace(">>> handleResult(snapshot=%s, error=%s)",
        snapshot and "yes" or "nil", tostring(errorReason))

    -- Error path
    if errorReason ~= nil then
        -- Non-fatal errors: keep negotiation dialog open
        if errorReason == "offer_not_higher" or errorReason == "ask_not_lower" then
            local msg = RmNegotiationUI.getErrorMessage(errorReason)
            InfoDialog.show(msg)
            return
        end
        closeNegotiationDialog()
        local msg = RmNegotiationUI.getErrorMessage(errorReason)
        InfoDialog.show(msg)
        RmNegotiationUI.clearState()
        return
    end

    if snapshot == nil then
        Log:warning("handleResult: nil snapshot without error")
        return
    end

    local dlg = RmNegotiationDialog.getInstance()
    local dialogOpen = (dlg ~= nil and dlg.isOpen)

    -- Completed deal: execute immediately, then show result in dialog
    if snapshot.state == "completed" and snapshot.outcome == RmNegotiationEngine.OUTCOME_DEAL then
        if dialogOpen then
            updateDialog(snapshot)
        else
            openDialog(snapshot)
        end
        executeDeal(snapshot)
        return
    end

    -- Other completed (rejected, walked away, etc.): show result in dialog
    if snapshot.state == "completed" then
        if dialogOpen then
            updateDialog(snapshot)
        else
            openDialog(snapshot)
        end
        RmNegotiationUI.clearState()
        return
    end

    -- Active or proposal: open or update dialog
    if dialogOpen then
        updateDialog(snapshot)
    else
        openDialog(snapshot)
    end
end

-- =============================================================================
-- EXECUTE DEAL (PURCHASE/SALE)
-- =============================================================================

--- Execute a completed deal by sending FarmlandStateEvent.
---@param snapshot table Completed session snapshot with finalPrice
executeDeal = function(snapshot)
    Log:trace(">>> executeDeal(farmland=%d, price=%.0f, mode=%s)",
        snapshot.farmlandId, snapshot.finalPrice, snapshot.mode)

    -- Guard: g_client required to send events (nil on dedicated server without player)
    if g_client == nil then
        Log:error("executeDeal: g_client is nil, cannot send FarmlandStateEvent")
        closeNegotiationDialog()
        RmNegotiationUI.clearState()
        return
    end

    local farmlandId = snapshot.farmlandId
    local farmId = RmNegotiationUI.currentFarmId
    local price = snapshot.finalPrice

    if snapshot.mode == RmNegotiationEngine.MODE_SELL then
        -- SELL: transfer to NPC (farmId=0)
        g_client:getServerConnection():sendEvent(
            FarmlandStateEvent.new(farmlandId, FarmlandManager.NO_OWNER_FARM_ID, price)
        )
        Log:info("NEGOTIATION_UI: Executing sale of farmland %d for %s",
            farmlandId, formatPrice(price))
    else
        -- BUY: validate balance first (advisory - server also validates)
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil then
            closeNegotiationDialog()
            InfoDialog.show(g_i18n:getText("rm_fm_neg_error"))
            RmNegotiationUI.clearState()
            return
        end
        if farm:getBalance() < price then
            closeNegotiationDialog()
            InfoDialog.show(g_i18n:getText("rm_fm_neg_insufficientFunds"))
            RmNegotiationUI.clearState()
            return
        end

        -- Set pendingDeals bypass for availability check (host only - server already set in completeSession)
        if g_server ~= nil then
            RmNegotiationManager.pendingDeals[farmlandId] = true
        end

        -- Send purchase event
        g_client:getServerConnection():sendEvent(
            FarmlandStateEvent.new(farmlandId, farmId, price)
        )
        Log:info("NEGOTIATION_UI: Executing purchase of farmland %d for %s",
            farmlandId, formatPrice(price))
    end

    RmNegotiationUI.clearState()
    Log:trace("<<< executeDeal()")
end

-- =============================================================================
-- PUBLIC API - ENTRY POINTS
-- =============================================================================

--- Start a buy negotiation (listed or unlisted).
---@param farmlandId number
---@param farmId number
---@param isListed boolean Whether the field is listed for sale
function RmNegotiationUI.startBuyNegotiation(farmlandId, farmId, isListed)
    Log:trace(">>> startBuyNegotiation(farmland=%d, farm=%d, listed=%s)",
        farmlandId, farmId, tostring(isListed))

    RmNegotiationUI.currentFarmlandId = farmlandId
    RmNegotiationUI.currentFarmId = farmId
    RmNegotiationUI.currentMode = isListed and
        RmNegotiationEngine.MODE_LISTED_BUY or RmNegotiationEngine.MODE_UNLISTED_BUY

    local apiFn = isListed and
        RmNegotiationManager.startListedBuy or RmNegotiationManager.startUnlistedBuy

    callManagerAPI(apiFn, { farmlandId, farmId }, handleResult)
    Log:trace("<<< startBuyNegotiation()")
end

--- Start a sell negotiation: prompt player for listing price, then start session.
---@param farmlandId number
---@param farmId number
function RmNegotiationUI.startSellNegotiation(farmlandId, farmId)
    Log:trace(">>> startSellNegotiation(farmland=%d, farm=%d)", farmlandId, farmId)

    RmNegotiationUI.currentFarmlandId = farmlandId
    RmNegotiationUI.currentFarmId = farmId
    RmNegotiationUI.currentMode = RmNegotiationEngine.MODE_SELL

    -- Get market value for reference display
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then
        InfoDialog.show(g_i18n:getText("rm_fm_neg_invalidFarmland"))
        RmNegotiationUI.clearState()
        return
    end
    local marketValue = farmland.price
    local marketStr = formatPrice(marketValue)

    -- Prompt player to enter their listing price (TextInputDialog - no session yet)
    local prompt = string.format(g_i18n:getText("rm_fm_neg_enterListingPrice"), marketStr)
    local defaultText = tostring(math.floor(marketValue))

    TextInputDialog.show(function(text, confirmed)
        if not confirmed or text == nil or text == "" then
            -- Player cancelled - abort sell
            RmNegotiationUI.clearState()
            return
        end
        local amount = tonumber(text)
        if amount == nil or amount <= 0 then
            InfoDialog.show(g_i18n:getText("rm_fm_neg_invalidAmount"))
            RmNegotiationUI.clearState()
            return
        end
        local maxListing = marketValue * RmNegotiationEngine.SELL.maxListingMultiplier
        if amount > maxListing then
            InfoDialog.show(string.format(g_i18n:getText("rm_fm_neg_listingTooHigh"), formatPrice(maxListing)))
            RmNegotiationUI.clearState()
            return
        end
        callManagerAPI(
            RmNegotiationManager.startSell,
            { farmlandId, farmId, math.floor(amount) },
            handleResult
        )
    end, nil, defaultText, prompt, nil, 12, g_i18n:getText("rm_fm_neg_submit"))

    Log:trace("<<< startSellNegotiation()")
end

-- =============================================================================
-- PUBLIC API - ASYNC RESULT RECEIVER
-- =============================================================================

--- Called by RmNegotiationResultEvent:run() on client when result arrives.
---@param success boolean
---@param errorReason string
---@param snapshot table|nil
function RmNegotiationUI.onResultReceived(success, errorReason, snapshot)
    Log:trace(">>> onResultReceived(success=%s)", tostring(success))

    local callback = RmNegotiationUI.pendingCallback
    RmNegotiationUI.pendingCallback = nil

    if callback == nil then
        Log:debug("NEGOTIATION_UI: Result received but no pending callback (console command?)")
        return
    end

    if success then
        callback(snapshot, nil)
    else
        callback(nil, errorReason)
    end

    Log:trace("<<< onResultReceived()")
end

-- =============================================================================
-- PUBLIC API - STATE MANAGEMENT
-- =============================================================================

--- Clear UI state (called after negotiation ends or is cancelled).
function RmNegotiationUI.clearState()
    RmNegotiationUI.pendingCallback = nil
    RmNegotiationUI.currentFarmlandId = nil
    RmNegotiationUI.currentFarmId = nil
    RmNegotiationUI.currentMode = nil
end

--- Cancel any active negotiation for the current farm.
function RmNegotiationUI.cancelActiveNegotiation()
    if RmNegotiationUI.currentFarmId ~= nil then
        Log:debug("NEGOTIATION_UI: Cancelling active negotiation")
        sendCancelToServer(RmNegotiationUI.currentFarmId)
        RmNegotiationUI.clearState()
    end
end

-- =============================================================================
-- HOOKS (set up at source time)
-- =============================================================================

--- Store original callbacks for fallback (vanilla behavior).
--- These are captured BEFORE any override, so they're the true originals.
local originalOnClickBuy = InGameMenuMapFrame.onClickBuy
local originalOnClickSell = InGameMenuMapFrame.onClickSell

--- Buy interceptor: replaces the contextActions callback on the live instance.
--- Called as callback(self) where self is the InGameMenuMapFrame instance.
local function onClickBuyInterceptor(self)
    Log:trace(">>> onClickBuy interceptor")

    -- Get current hotspot farmland
    local hotspot = self.currentHotspot
    if hotspot == nil or hotspot.getFarmland == nil then
        return originalOnClickBuy(self)
    end
    local farmland = hotspot:getFarmland()
    if farmland == nil then
        return originalOnClickBuy(self)
    end

    local farmlandId = farmland.id
    local farmId = g_currentMission:getFarmId()

    -- Check if field is already owned by player
    if farmland.farmId == farmId then
        return originalOnClickBuy(self)
    end

    -- Determine listed vs unlisted
    local isListed = RmFmAvailability.isForSale(farmlandId)
    local isEligible = RmFmAvailability.isEligibleForAvailability(farmland)

    -- For non-eligible farmlands (NPC-owned, never-rotating, or $0 plots),
    -- use vanilla. Eligibility requires positive market value, so $0 plots
    -- get the free vanilla buy instead of the negotiation engine's
    -- "invalid_market_value" error.
    if not isEligible then
        return originalOnClickBuy(self)
    end

    -- Granular negotiation checks
    if isListed and not RmFmSettings.isNegotiateBuyEnabled() then
        Log:trace("  Listed field, negotiate buy disabled, falling through to vanilla")
        return originalOnClickBuy(self)
    end
    if not isListed and not RmFmSettings.isUnlistedOffersEnabled() then
        Log:trace("  Unlisted field, unlisted offers disabled, falling through to vanilla")
        return originalOnClickBuy(self)
    end

    -- Start negotiation
    RmNegotiationUI.startBuyNegotiation(farmlandId, farmId, isListed)
    Log:trace("<<< onClickBuy interceptor [negotiation started]")
    return true
end

--- Sell interceptor: replaces the contextActions callback on the live instance.
local function onClickSellInterceptor(self)
    Log:trace(">>> onClickSell interceptor")

    -- Skip if sell negotiation disabled
    if not RmFmSettings.isNegotiateSellEnabled() then
        return originalOnClickSell(self)
    end

    -- Get current hotspot farmland
    local hotspot = self.currentHotspot
    if hotspot == nil or hotspot.getFarmland == nil then
        return originalOnClickSell(self)
    end
    local farmland = hotspot:getFarmland()
    if farmland == nil then
        return originalOnClickSell(self)
    end

    local farmlandId = farmland.id
    local farmId = g_currentMission:getFarmId()

    -- Only intercept if player owns this field
    if farmland.farmId ~= farmId then
        return originalOnClickSell(self)
    end

    -- $0 plots: vanilla sell (negotiation engine rejects marketValue <= 0).
    if not RmFmAvailability.hasPositiveMarketValue(farmland) then
        return originalOnClickSell(self)
    end

    -- Start sell negotiation
    RmNegotiationUI.startSellNegotiation(farmlandId, farmId)
    Log:trace("<<< onClickSell interceptor [negotiation started]")
    return true
end

--- Patch contextActions callbacks on the live InGameMenuMapFrame instance.
--- Utils.overwrittenFunction on onClickBuy/onClickSell has no effect because the
--- button callbacks are captured as direct function references at GUI init time.
--- We patch the stored references on each frame open instead.
InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameOpen,
    function(self)
        local actions = InGameMenuMapFrame.ACTIONS
        if self.contextActions == nil or actions == nil then
            return
        end

        local buyAction = self.contextActions[actions.BUY]
        if buyAction ~= nil then
            buyAction.callback = onClickBuyInterceptor
            Log:trace("HOOK: Patched BUY contextAction callback on instance")
        end

        local sellAction = self.contextActions[actions.SELL]
        if sellAction ~= nil then
            sellAction.callback = onClickSellInterceptor
            Log:trace("HOOK: Patched SELL contextAction callback on instance")
        end
    end
)

--- Cancel active negotiation when map frame closes.
InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameClose,
    function(self)
        RmNegotiationUI.cancelActiveNegotiation()
    end
)

Log:debug("RmNegotiationUI module loaded")
