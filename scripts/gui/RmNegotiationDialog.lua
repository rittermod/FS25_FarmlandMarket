-- RmNegotiationDialog - Custom negotiation dialog for farmland buying/selling.
-- Author: Ritter
--
-- MessageDialog subclass showing farmland info, scrollable offer history,
-- context-appropriate action buttons, and a status text area.
-- Stays open throughout the negotiation; wired into the buy/sell flow.

local Log = RmLogging.getLogger("FarmlandMarket")

---@class RmNegotiationDialog : MessageDialog
RmNegotiationDialog = {}
local RmNegotiationDialog_mt = Class(RmNegotiationDialog, MessageDialog)

-- Action states
RmNegotiationDialog.STATE_OPENING = 1
RmNegotiationDialog.STATE_OFFER_INPUT = 2
RmNegotiationDialog.STATE_ACCEPT_COUNTER = 3
RmNegotiationDialog.STATE_ACCEPT_WALK = 4
RmNegotiationDialog.STATE_PROPOSAL = 5
RmNegotiationDialog.STATE_COMPLETED = 6
RmNegotiationDialog.STATE_WAITING = 7

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Creates a new RmNegotiationDialog instance
---@param target table|nil
---@param customMt table|nil
---@return RmNegotiationDialog
function RmNegotiationDialog.new(target, customMt)
    Log:trace(">>> RmNegotiationDialog.new()")
    ---@type RmNegotiationDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, customMt or RmNegotiationDialog_mt)

    -- Data state
    self.historyRows = {}
    self.currentSnapshot = nil
    self.currentMode = nil
    self.currentState = nil
    self.previousButtonState = nil
    self.previousStatusText = nil

    -- Callback slots (set by controller)
    self.onSubmitOffer = nil
    self.onAcceptPrice = nil
    self.onMakeOffer = nil
    self.onWalkAway = nil
    self.onAcceptProposal = nil
    self.onDeclineProposal = nil

    -- GUI element refs (populated in onGuiSetupFinished)
    self.dialogTitleElement = nil
    self.headerInfoElement = nil
    self.statusTextElement = nil
    self.historyList = nil
    self.textInputElement = nil

    -- Footer
    self.footerButtonBox = nil
    self.bottomBarButton = nil
    self.primaryActionButton = nil
    self.secondaryActionButton = nil

    return self
end

-- ============================================================================
-- GUI SETUP
-- ============================================================================

function RmNegotiationDialog:onGuiSetupFinished()
    Log:trace(">>> RmNegotiationDialog:onGuiSetupFinished()")
    RmNegotiationDialog:superClass().onGuiSetupFinished(self)

    -- Store element references by ID
    self.dialogTitleElement = self:getDescendantById("dialogTitleElement")
    self.headerInfoElement = self:getDescendantById("headerInfoElement")
    self.statusTextElement = self:getDescendantById("statusTextElement")
    self.historyList = self:getDescendantById("historyList")
    self.textInputElement = self:getDescendantById("textInputElement")

    -- Footer
    self.footerButtonBox = self:getDescendantById("footerButtonBox")
    self.bottomBarButton = self:getDescendantById("bottomBarButton")
    self.primaryActionButton = self:getDescendantById("primaryActionButton")
    self.secondaryActionButton = self:getDescendantById("secondaryActionButton")

    -- Set self as DataSource for history list
    if self.historyList ~= nil then
        self.historyList:setDataSource(self)
    end

    -- Button callbacks are wired via XML onClick attributes (survives deep-clone)

    Log:trace("<<< RmNegotiationDialog:onGuiSetupFinished()")
end

-- ============================================================================
-- OPEN / CLOSE / RESET
-- ============================================================================

function RmNegotiationDialog:onOpen()
    Log:trace(">>> RmNegotiationDialog:onOpen()")
    RmNegotiationDialog:superClass().onOpen(self)

    -- Clear state
    self.historyRows = {}
    self.currentSnapshot = nil
    self.currentMode = nil          -- Clear stale mode
    self.currentState = nil
    self.previousButtonState = nil
    self.previousStatusText = nil

    -- Clear text input
    if self.textInputElement ~= nil then
        self.textInputElement:setText("")
    end

    -- Clear status text
    if self.statusTextElement ~= nil then
        self.statusTextElement:setText("")
    end

    -- Hide dynamic elements
    if self.textInputElement ~= nil then
        self.textInputElement:setVisible(false)
    end
    if self.primaryActionButton ~= nil then
        self.primaryActionButton:setVisible(false)
    end
    if self.secondaryActionButton ~= nil then
        self.secondaryActionButton:setVisible(false)
    end
end

function RmNegotiationDialog:onClose()
    Log:trace(">>> RmNegotiationDialog:onClose()")
    RmNegotiationDialog:superClass().onClose(self)
    Log:trace("<<< RmNegotiationDialog:onClose()")
end

--- Clear all state. Called by BaseMission.delete handler for map unload cleanup.
function RmNegotiationDialog:reset()
    Log:trace(">>> RmNegotiationDialog:reset()")
    self.historyRows = {}
    self.currentSnapshot = nil
    self.currentMode = nil
    self.currentState = nil
    self.previousButtonState = nil
    self.previousStatusText = nil

    -- Clear callback slots
    self.onSubmitOffer = nil
    self.onAcceptPrice = nil
    self.onMakeOffer = nil
    self.onWalkAway = nil
    self.onAcceptProposal = nil
    self.onDeclineProposal = nil
    Log:trace("<<< RmNegotiationDialog:reset()")
end

-- ============================================================================
-- MAIN API: UPDATE FROM SNAPSHOT
-- ============================================================================

--- Main API called by controller to update dialog from negotiation snapshot.
---@param snapshot table Negotiation snapshot from RmNegotiationManager.createSnapshot()
function RmNegotiationDialog:updateFromSnapshot(snapshot)
    Log:trace(">>> RmNegotiationDialog:updateFromSnapshot(farmlandId=%s)", tostring(snapshot.farmlandId))
    self.currentSnapshot = snapshot
    self.currentMode = snapshot.mode

    -- Look up farmland data
    local farmland = g_farmlandManager:getFarmlandById(snapshot.farmlandId)
    local farmlandName = farmland ~= nil and farmland.name or tostring(snapshot.farmlandId)

    -- Set title based on mode
    if snapshot.mode == RmNegotiationEngine.MODE_SELL then
        self.dialogTitleElement:setText(
            string.format(g_i18n:getText("rm_fm_neg_dlg_titleSell"), farmlandName))
    else
        self.dialogTitleElement:setText(
            string.format(g_i18n:getText("rm_fm_neg_dlg_titleBuy"), farmlandName))
    end

    -- Set header based on mode
    if farmland ~= nil then
        if snapshot.mode == RmNegotiationEngine.MODE_SELL then
            -- Sell: area + market value
            self.headerInfoElement:setText(
                string.format(g_i18n:getText("rm_fm_neg_dlg_headerAreaValue"),
                    farmland.areaInHa,
                    g_i18n:formatMoney(farmland.price, 0, true, true)))
        else
            -- Buy: area only
            self.headerInfoElement:setText(
                string.format(g_i18n:getText("rm_fm_neg_dlg_headerArea"), farmland.areaInHa))
        end
    else
        -- Clear header when farmland data unavailable
        self.headerInfoElement:setText("")
    end

    -- Rebuild and refresh history
    self:rebuildHistory()
    self.historyList:reloadData()
    self.historyList:scrollToEnd()

    Log:trace("<<< RmNegotiationDialog:updateFromSnapshot()")
end

-- ============================================================================
-- HISTORY BUILDING
-- ============================================================================

--- Rebuilds the history rows from the current snapshot.
function RmNegotiationDialog:rebuildHistory()
    Log:trace(">>> RmNegotiationDialog:rebuildHistory()")
    self.historyRows = {}

    local snapshot = self.currentSnapshot
    if snapshot == nil then
        Log:trace("<<< rebuildHistory() [no snapshot]")
        return
    end

    local youLabel = g_i18n:getText("rm_fm_neg_dlg_you")
    local buyerLabel = g_i18n:getText("rm_fm_neg_dlg_buyer")

    -- Resolve NPC owner name for buy modes
    local sellerLabel = g_i18n:getText("rm_fm_neg_dlg_seller")
    if snapshot.mode ~= RmNegotiationEngine.MODE_SELL then
        local farmland = g_farmlandManager:getFarmlandById(snapshot.farmlandId)
        if farmland ~= nil then
            local npc = farmland:getNPC()
            if npc ~= nil and npc.title ~= nil then
                sellerLabel = npc.title
            end
        end
    end

    -- Anchor row (always first)
    local anchorParty
    if snapshot.mode == RmNegotiationEngine.MODE_LISTED_BUY then
        anchorParty = g_i18n:getText("rm_fm_neg_dlg_listedAt")
    elseif snapshot.mode == RmNegotiationEngine.MODE_UNLISTED_BUY then
        anchorParty = string.format(g_i18n:getText("rm_fm_neg_dlg_ownerDemands"), sellerLabel)
    else -- MODE_SELL
        anchorParty = g_i18n:getText("rm_fm_neg_dlg_youListedAt")
    end

    if snapshot.anchorPrice ~= nil then
        table.insert(self.historyRows, {
            round = "",
            party = anchorParty,
            amount = self:formatPrice(snapshot.anchorPrice),
        })
    end

    -- Build offer history
    if snapshot.mode == RmNegotiationEngine.MODE_SELL then
        self:buildSellHistory(snapshot, youLabel, buyerLabel)
    else
        self:buildBuyHistory(snapshot, youLabel, sellerLabel)
    end

    Log:debug("HISTORY: Built %d rows for farmland %d", #self.historyRows, snapshot.farmlandId)
    Log:trace("<<< RmNegotiationDialog:rebuildHistory()")
end

--- Builds history rows for buy mode.
---@param snapshot table
---@param youLabel string
---@param sellerLabel string
function RmNegotiationDialog:buildBuyHistory(snapshot, youLabel, sellerLabel)
    local lastSellerPrice = nil
    for _, entry in ipairs(snapshot.offers) do
        local rLabel = "R" .. entry.round
        -- Skip offer if it matches last seller counter (accept, not a new counter-offer)
        if entry.offer and entry.offer ~= lastSellerPrice then
            table.insert(self.historyRows, {
                round = rLabel,
                party = youLabel,
                amount = self:formatPrice(entry.offer),
            })
        end
        if entry.counter and entry.counter > 0 then
            table.insert(self.historyRows, {
                round = rLabel,
                party = sellerLabel,
                amount = self:formatPrice(entry.counter),
            })
            lastSellerPrice = entry.counter
        end
    end
end

--- Builds history rows for sell mode with round 1 deduplication.
---@param snapshot table
---@param youLabel string
---@param buyerLabel string
function RmNegotiationDialog:buildSellHistory(snapshot, youLabel, buyerLabel)
    -- Show NPC opening offer before any player asks (visible from session start)
    if #snapshot.offers == 0 and snapshot.lastCounter ~= nil then
        table.insert(self.historyRows, {
            round = "R1",
            party = buyerLabel,
            amount = self:formatPrice(snapshot.lastCounter),
        })
    end

    local lastBuyerPrice = nil
    for i, entry in ipairs(snapshot.offers) do
        local rLabel = "R" .. entry.round
        -- Show npcOffer only for round 1 (round 2+ it duplicates prior npcResponse)
        if i == 1 and entry.npcOffer then
            table.insert(self.historyRows, {
                round = rLabel,
                party = buyerLabel,
                amount = self:formatPrice(entry.npcOffer),
            })
            lastBuyerPrice = entry.npcOffer
        end
        -- Skip playerAsk if it matches the last buyer price (accept, not a counter-ask)
        if entry.playerAsk and entry.playerAsk ~= lastBuyerPrice then
            table.insert(self.historyRows, {
                round = rLabel,
                party = youLabel,
                amount = self:formatPrice(entry.playerAsk),
            })
        end
        -- Skip npcResponse if it matches playerAsk (deal confirmation, not a raise)
        if entry.npcResponse and entry.npcResponse ~= entry.playerAsk then
            table.insert(self.historyRows, {
                round = rLabel,
                party = buyerLabel,
                amount = self:formatPrice(entry.npcResponse),
            })
        end
        lastBuyerPrice = entry.npcResponse or lastBuyerPrice
    end
end

--- Formats a price for display.
---@param amount number
---@return string
function RmNegotiationDialog:formatPrice(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

-- ============================================================================
-- SMOOTHLIST DATASOURCE
-- ============================================================================

function RmNegotiationDialog:getNumberOfItemsInSection(list, section)
    return #self.historyRows
end

function RmNegotiationDialog:populateCellForItemInSection(list, section, index, cell)
    local row = self.historyRows[index]
    if row == nil then
        return
    end

    local roundEl = cell:getDescendantByName("roundText")
    local partyEl = cell:getDescendantByName("partyText")
    local amountEl = cell:getDescendantByName("amountText")

    if roundEl ~= nil then roundEl:setText(row.round) end
    if partyEl ~= nil then partyEl:setText(row.party) end
    if amountEl ~= nil then amountEl:setText(row.amount) end
end

-- ============================================================================
-- ACTION STATE MANAGEMENT
-- ============================================================================

--- Sets the current action state, updating footer buttons and text input visibility.
---@param state number One of the STATE_* constants
---@param params table|nil Optional params: { statusText = string }
function RmNegotiationDialog:setActionState(state, params)
    Log:trace(">>> RmNegotiationDialog:setActionState(%d)", state)
    params = params or {}

    -- Release text input force-press when leaving STATE_OFFER_INPUT
    if self.currentState == RmNegotiationDialog.STATE_OFFER_INPUT
       and self.textInputElement ~= nil then
        self.textInputElement:setForcePressed(false)
    end

    self.currentState = state

    -- Clear status text before state transition (prevents stale text)
    if self.statusTextElement ~= nil then
        self.statusTextElement:setText("")
    end

    -- Configure footer buttons and text input for the new state
    self:configureFooterButtons(state)

    -- Clear text input when entering offer input state
    if state == RmNegotiationDialog.STATE_OFFER_INPUT and self.textInputElement ~= nil then
        self.textInputElement:setText("")
    end

    -- Auto-set waiting text
    if state == RmNegotiationDialog.STATE_WAITING and self.statusTextElement ~= nil then
        self.statusTextElement:setText(g_i18n:getText("rm_fm_neg_dlg_waiting"))
    end

    -- Update status text from params
    if params.statusText ~= nil and self.statusTextElement ~= nil then
        self.statusTextElement:setText(params.statusText)
    end

    -- Relink focus chain
    self:relinkFocus(state)

    Log:trace("<<< RmNegotiationDialog:setActionState()")
end

--- Configures footer buttons visibility, text, and separator for the given state.
--- Follows the MultiOptionDialog pattern: separators are children of buttons,
--- hidden on the first visible button (bottomBarButton).
---@param state number
function RmNegotiationDialog:configureFooterButtons(state)
    -- Bottom bar button separator is always hidden (it's the leftmost button)
    if self.bottomBarButton ~= nil then
        local sep = self.bottomBarButton:getDescendantByName("separator")
        if sep ~= nil then
            sep:setVisible(false)
        end
    end

    -- Default: hide optional elements
    if self.primaryActionButton ~= nil then
        self.primaryActionButton:setVisible(false)
    end
    if self.secondaryActionButton ~= nil then
        self.secondaryActionButton:setVisible(false)
    end
    if self.textInputElement ~= nil then
        self.textInputElement:setVisible(false)
    end

    if state == RmNegotiationDialog.STATE_OPENING then
        -- Walk Away + Make Offer
        self:showPrimaryAction(g_i18n:getText("rm_fm_btn_makeOffer"))
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), false)

    elseif state == RmNegotiationDialog.STATE_OFFER_INPUT then
        -- Walk Away + Submit (+ text input in content area)
        self:showPrimaryAction(g_i18n:getText("rm_fm_neg_submit"))
        if self.textInputElement ~= nil then
            self.textInputElement:setVisible(true)
        end
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), false)

    elseif state == RmNegotiationDialog.STATE_ACCEPT_COUNTER then
        -- Walk Away + Counter-offer (primary/Enter) + Accept (secondary)
        -- Counter is primary so Enter consistently means "take action" across states
        local counterLabel = self.currentMode == RmNegotiationEngine.MODE_SELL
            and g_i18n:getText("rm_fm_neg_counterAsk")
            or g_i18n:getText("rm_fm_neg_counterOffer")
        self:showPrimaryAction(counterLabel)
        self:showSecondaryAction(g_i18n:getText("rm_fm_neg_accept"))
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), false)

    elseif state == RmNegotiationDialog.STATE_ACCEPT_WALK then
        -- Walk Away + Accept
        self:showPrimaryAction(g_i18n:getText("rm_fm_neg_accept"))
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), false)

    elseif state == RmNegotiationDialog.STATE_PROPOSAL then
        -- Walk Away + Accept + Decline
        self:showPrimaryAction(g_i18n:getText("rm_fm_neg_accept"))
        self:showSecondaryAction(g_i18n:getText("rm_fm_neg_decline"))
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), false)

    elseif state == RmNegotiationDialog.STATE_COMPLETED then
        -- Close only (no action buttons)
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_close"), false)

    elseif state == RmNegotiationDialog.STATE_WAITING then
        -- Walk Away disabled (no action buttons)
        self:updateBottomBar(g_i18n:getText("rm_fm_neg_walkAway"), true)
    end

    -- Force BoxLayout to recalculate positions after visibility changes
    if self.footerButtonBox ~= nil then
        self.footerButtonBox:invalidateLayout()
    end
end

--- Shows the primary action button with the given text and its separator.
---@param text string
function RmNegotiationDialog:showPrimaryAction(text)
    if self.primaryActionButton ~= nil then
        self.primaryActionButton:setVisible(true)
        self.primaryActionButton:setText(text)
        local sep = self.primaryActionButton:getDescendantByName("separator")
        if sep ~= nil then
            sep:setVisible(true)
        end
    end
end

--- Shows the secondary action button with the given text and its separator.
---@param text string
function RmNegotiationDialog:showSecondaryAction(text)
    if self.secondaryActionButton ~= nil then
        self.secondaryActionButton:setVisible(true)
        self.secondaryActionButton:setText(text)
        local sep = self.secondaryActionButton:getDescendantByName("separator")
        if sep ~= nil then
            sep:setVisible(true)
        end
    end
end

--- Updates the bottom bar button text and disabled state.
---@param text string
---@param disabled boolean
function RmNegotiationDialog:updateBottomBar(text, disabled)
    if self.bottomBarButton == nil then
        return
    end
    self.bottomBarButton:setText(text)
    self.bottomBarButton:setDisabled(disabled)
end

--- Relinks FocusManager chain for the current action state.
---@param state number
function RmNegotiationDialog:relinkFocus(state)
    local focusTargets = {}

    -- Text input (if visible)
    if state == RmNegotiationDialog.STATE_OFFER_INPUT and self.textInputElement ~= nil then
        table.insert(focusTargets, self.textInputElement)
    end

    -- Footer buttons in visual order: bottomBar (left), secondary (middle), primary (right)
    if self.bottomBarButton ~= nil and not self.bottomBarButton.disabled then
        table.insert(focusTargets, self.bottomBarButton)
    end
    if self.secondaryActionButton ~= nil and self.secondaryActionButton.visible then
        table.insert(focusTargets, self.secondaryActionButton)
    end
    if self.primaryActionButton ~= nil and self.primaryActionButton.visible then
        table.insert(focusTargets, self.primaryActionButton)
    end

    -- Link elements bidirectionally (left/right for footer row)
    for i = 1, #focusTargets - 1 do
        FocusManager:linkElements(focusTargets[i], FocusManager.RIGHT, focusTargets[i + 1])
        FocusManager:linkElements(focusTargets[i + 1], FocusManager.LEFT, focusTargets[i])
    end
    -- Also link top/bottom for text input → footer navigation
    for i = 1, #focusTargets - 1 do
        FocusManager:linkElements(focusTargets[i], FocusManager.BOTTOM, focusTargets[i + 1])
        FocusManager:linkElements(focusTargets[i + 1], FocusManager.TOP, focusTargets[i])
    end

    -- Set initial focus
    if #focusTargets > 0 then
        self:setSoundSuppressed(true)
        FocusManager:setFocus(focusTargets[1])
        self:setSoundSuppressed(false)

        -- Defer text input activation to next frame (matches TextInputDialog pattern).
        -- Activating during a button click handler gets stomped by event processing.
        if state == RmNegotiationDialog.STATE_OFFER_INPUT and self.textInputElement ~= nil then
            local textInput = self.textInputElement
            Timer.createOneshot(0, function()
                FocusManager:setFocus(textInput)
                textInput.blockTime = 0
                textInput:onFocusActivate()
            end)
        end
    end
end

-- ============================================================================
-- BUTTON CLICK HANDLERS
-- ============================================================================

--- Primary action button dispatcher (mapped via XML onClick="onClickPrimaryAction")
function RmNegotiationDialog:onClickPrimaryAction()
    Log:trace(">>> onClickPrimaryAction() state=%s", tostring(self.currentState))

    if self.currentState == RmNegotiationDialog.STATE_OPENING then
        -- Make Offer
        if self.onMakeOffer ~= nil then
            self.onMakeOffer()
        end

    elseif self.currentState == RmNegotiationDialog.STATE_OFFER_INPUT then
        -- Submit offer
        self:handleSubmitOffer()

    elseif self.currentState == RmNegotiationDialog.STATE_ACCEPT_COUNTER then
        -- Counter-offer: store state + status text so ESC can return
        self.previousButtonState = self.currentState
        self.previousStatusText = self.statusTextElement ~= nil and self.statusTextElement:getText() or nil
        self:setActionState(RmNegotiationDialog.STATE_OFFER_INPUT, {
            statusText = self.currentMode == RmNegotiationEngine.MODE_SELL
                and g_i18n:getText("rm_fm_neg_enterCounterAsk")
                or g_i18n:getText("rm_fm_neg_enterOffer"),
        })

    elseif self.currentState == RmNegotiationDialog.STATE_ACCEPT_WALK then
        -- Accept price (only option when rounds exhausted)
        if self.onAcceptPrice ~= nil then
            self.onAcceptPrice()
        end

    elseif self.currentState == RmNegotiationDialog.STATE_PROPOSAL then
        -- Accept proposal
        if self.onAcceptProposal ~= nil then
            self.onAcceptProposal()
        end
    end
end

--- Secondary action button dispatcher (mapped via XML onClick="onClickSecondaryAction")
function RmNegotiationDialog:onClickSecondaryAction()
    Log:trace(">>> onClickSecondaryAction() state=%s", tostring(self.currentState))

    if self.currentState == RmNegotiationDialog.STATE_ACCEPT_COUNTER then
        -- Accept price (secondary action - deliberate choice)
        if self.onAcceptPrice ~= nil then
            self.onAcceptPrice()
        end

    elseif self.currentState == RmNegotiationDialog.STATE_PROPOSAL then
        -- Decline proposal
        if self.onDeclineProposal ~= nil then
            self.onDeclineProposal()
        end
    end
end

--- Validates and submits the offer amount from the text input.
function RmNegotiationDialog:handleSubmitOffer()
    if self.textInputElement == nil then
        return
    end

    local text = self.textInputElement:getText() or ""
    local amount = tonumber(text)

    if amount == nil or amount <= 0 then
        if self.statusTextElement ~= nil then
            self.statusTextElement:setText(g_i18n:getText("rm_fm_neg_invalidAmount"))
        end
        return
    end

    if self.onSubmitOffer ~= nil then
        self.onSubmitOffer(amount)
    end
end

--- Bottom bar button handler (mapped via XML onClick="onClickBottomBar")
function RmNegotiationDialog:onClickBottomBar()
    Log:trace(">>> onClickBottomBar() state=%s", tostring(self.currentState))
    if self.currentState == RmNegotiationDialog.STATE_COMPLETED then
        self:close()
    elseif self.currentState == RmNegotiationDialog.STATE_OFFER_INPUT
       and self.previousButtonState ~= nil then
        -- ESC from text input returns to previous button state + status text
        self:setActionState(self.previousButtonState, { statusText = self.previousStatusText })
        self.previousButtonState = nil
        self.previousStatusText = nil
    else
        if self.onWalkAway ~= nil then
            self.onWalkAway()
        end
    end
end

-- ============================================================================
-- TEXT INPUT HANDLERS
-- ============================================================================

--- Called by XML onIsUnicodeAllowed to restrict to digits only.
---@param unicode number
---@return boolean
function RmNegotiationDialog:onInputIsUnicodeAllowed(unicode)
    -- Allow digits 0-9 (unicode 48-57)
    return unicode >= 48 and unicode <= 57
end

-- ============================================================================
-- STATIC METHODS
-- ============================================================================

--- Registers the dialog with the GUI system.
function RmNegotiationDialog.register()
    Log:trace(">>> RmNegotiationDialog.register()")
    local modDir = RmFarmlandMarket.modDirectory
    g_gui:loadProfiles(modDir .. "gui/guiProfiles.xml")
    -- Create instance first (ASC pattern) - no 4th arg (isFrame is for TabbedMenu frames)
    local dialog = RmNegotiationDialog.new(g_i18n)
    g_gui:loadGui(modDir .. "gui/RmNegotiationDialog.xml", "RmNegotiationDialog", dialog)
    if dialog ~= nil then
        Log:debug("RmNegotiationDialog registered")
    else
        Log:error("Failed to register RmNegotiationDialog")
    end
    Log:trace("<<< RmNegotiationDialog.register()")
end

--- Returns the dialog instance from the GUI system.
---@return RmNegotiationDialog|nil
function RmNegotiationDialog.getInstance()
    local entry = g_gui.guis["RmNegotiationDialog"]
    return entry and entry.target or nil
end
