-- RmWatchlistUI - Map-frame integration for the Watchlist feature.
-- Author: Ritter
--
-- Clones the Back button in the map frame's bottom buttonBox to insert a
-- Watchlist button visible only on the Farmlands subcategory, which opens
-- RmWatchlistDialog (also bound to MENU_EXTRA_2, the C key by default).
-- Also owns the local watched-id cache, the "Add to watchlist" /
-- "Remove from watchlist" action-menu toggle, and the for-sale and
-- cooldown-expiry notifications. See the section banners below.

RmWatchlistUI = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- Cloned controls awaiting FocusManager registration.
local fmClonedControls = {}

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Recursively assign unique focusIds to a cloned element and all its children.
--- Cloned elements inherit duplicate focusIds from their templates, which breaks
--- FocusManager navigation. Mirrors RmFmSettings.updateFocusIds.
---@param element table|nil GUI element
local function updateFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    if element.elements ~= nil then
        for _, child in pairs(element.elements) do
            updateFocusIds(child)
        end
    end
end

--- Predicate: should the Watchlist button be visible for the given subcategory state?
--- Single source of truth shared by visibility checks and tests.
---@param state number|nil InGameMenuMapFrame subcategory enum value
---@return boolean
function RmWatchlistUI.shouldShow(state)
    Log:trace(">>> RmWatchlistUI.shouldShow(state=%s)", tostring(state))
    local result = state == InGameMenuMapFrame.MAP_FARMLANDS
    Log:trace("<<< RmWatchlistUI.shouldShow -> %s", tostring(result))
    return result
end

--- Open the Watchlist dialog.
function RmWatchlistUI.openDialog()
    Log:trace(">>> RmWatchlistUI.openDialog()")
    RmWatchlistDialog.show()
    Log:trace("<<< RmWatchlistUI.openDialog()")
end

--- Action-event handler for MENU_EXTRA_2 (the C key by default), registered on
--- the InGameMenuMapFrame instance during onFrameOpen. Only opens the dialog
--- when the Watchlist button is currently visible (Farmlands subcategory).
---@param self table InGameMenuMapFrame instance
local function onMenuExtra2KeyEvent(self)
    Log:trace(">>> RmWatchlistUI.onMenuExtra2KeyEvent")
    local state = nil
    if self.mapOverviewSelector ~= nil then
        state = self.mapOverviewSelector:getState()
    end
    if not RmWatchlistUI.shouldShow(state) then
        Log:trace("RmWatchlistUI.onMenuExtra2KeyEvent: not on Farmlands subcat, ignore")
        return
    end
    RmWatchlistUI.openDialog()
    Log:trace("<<< RmWatchlistUI.onMenuExtra2KeyEvent")
end

--- Insert a child element into a parent's element list at a specific index.
---@param parent table BoxLayout / container element
---@param child table element to insert
---@param index number 1-based index in parent.elements
local function insertElementAt(parent, child, index)
    if parent.elements == nil then return end
    table.insert(parent.elements, index, child)
    child.parent = parent
end

--- Find the index of an element in its parent's elements array.
---@param parent table
---@param element table
---@return number|nil 1-based index, or nil if not found
local function indexOfElement(parent, element)
    if parent == nil or parent.elements == nil then return nil end
    for i, e in ipairs(parent.elements) do
        if e == element then
            return i
        end
    end
    return nil
end

-- ============================================================================
-- HOOK BODIES
-- ============================================================================

--- Patch the live frame instance's mapOverviewSelector.onClickCallback to point
--- at the (now-wrapped) onClickMapOverviewSelector method.
---
--- WHY: GUI XML callbacks are captured by reference at load time, so wrapping
--- the class method afterwards has no effect on already-instantiated controls.
--- Without this re-bind, user arrow clicks dispatch to the unwrapped original
--- and our hook never fires. Same per-instance patch pattern RmNegotiationUI
--- uses for BUY/SELL contextActions.
---@param self table InGameMenuMapFrame instance
local function patchMapOverviewSelectorCallback(self)
    if self.mapOverviewSelector == nil then
        return
    end
    if self.mapOverviewSelector.onClickCallback == self.onClickMapOverviewSelector then
        return  -- already pointing at the live wrapped method
    end
    self.mapOverviewSelector.onClickCallback = self.onClickMapOverviewSelector
    Log:trace("RmWatchlistUI: patched mapOverviewSelector.onClickCallback to live wrapped method")
end

--- Append-hook body for InGameMenuMapFrame.onFrameOpen.
--- Creates the Watchlist button on first call, refreshes visibility on every call.
---@param self table InGameMenuMapFrame instance
local function onFrameOpenHook(self)
    Log:trace(">>> RmWatchlistUI.onFrameOpenHook")

    -- Always patch the live instance callback first - even if button creation
    -- below bails early, we still want subsequent subcat clicks to dispatch.
    patchMapOverviewSelectorCallback(self)

    -- Register the MENU_EXTRA_2 keyboard handler explicitly. The map frame's
    -- input context drops MENU_EXTRA_2 from the standard button-action path,
    -- so the cloned button's inputActionName alone wouldn't dispatch on
    -- keypress. By the time our append-hook fires, the slot is clean - we
    -- register fresh, no de-dup needed. The handler guards on subcategory
    -- state, so the C key only opens the dialog when the button is visible.
    g_inputBinding:registerActionEvent(InputAction.MENU_EXTRA_2, self,
        onMenuExtra2KeyEvent, false, true, false, true)

    if self.buttonBack == nil then
        Log:error("RmWatchlistUI: self.buttonBack is nil on InGameMenuMapFrame instance; skipping watchlist button creation")
        if self.elements ~= nil then
            for i, e in ipairs(self.elements) do
                Log:error("  element[%d] id=%s name=%s", i, tostring(e.id), tostring(e.name))
            end
        end
        return
    end

    if self.rmFmWatchlistButton == nil then
        Log:trace("RmWatchlistUI.onFrameOpenHook: first call, cloning buttonBack")
        local btn = self.buttonBack:clone()
        btn:setText(g_i18n:getText("rm_fm_btn_watchlist"))
        -- inputActionName drives the rendered key glyph and lets mouse click
        -- fire onClickCallback. Keyboard dispatch in this frame goes through
        -- the explicit g_inputBinding:registerActionEvent above instead of the
        -- standard button-discovery path.
        btn:setInputAction("MENU_EXTRA_2")
        btn.onClickCallback = RmWatchlistUI.openDialog

        -- Repair focus state for the cloned subtree.
        updateFocusIds(btn)
        table.insert(fmClonedControls, btn)

        -- Insert into buttonBox immediately after buttonBack and before buttonNext.
        local parent = self.buttonBack.parent
        if parent == nil or parent.elements == nil then
            Log:error("RmWatchlistUI: buttonBack has no parent/elements; cannot insert watchlist button")
            return
        end
        local backIndex = indexOfElement(parent, self.buttonBack)
        if backIndex == nil then
            Log:error("RmWatchlistUI: buttonBack not found in parent.elements; cannot insert watchlist button")
            return
        end
        insertElementAt(parent, btn, backIndex + 1)

        -- Default (0,0) anchor and pivot are required for BoxLayout to
        -- position the button correctly. A cloned element can inherit
        -- non-default values from its source, which causes BoxLayout to
        -- misplace or drop it on subsequent relayouts (e.g. on subcategory
        -- change).
        if btn.setAnchor ~= nil then btn:setAnchor(0, 0) end
        if btn.setPivot ~= nil then btn:setPivot(0, 0) end

        self.rmFmWatchlistButton = btn

        -- Register the cloned button with FocusManager immediately, while the
        -- map GUI's focus context is current. The setGui-append fallback below
        -- only runs on later GUI transitions, so first-open keyboard/controller
        -- navigation would otherwise skip the button.
        if FocusManager.currentFocusData ~= nil
            and FocusManager.currentFocusData.idToElementMapping ~= nil then
            if FocusManager:loadElementFromCustomValues(btn, nil, nil, false, false) then
                Log:debug("Watchlist button created and registered with FocusManager (insertedIndex=%d)", backIndex + 1)
            else
                Log:warning("Watchlist button created but FocusManager registration failed (insertedIndex=%d)", backIndex + 1)
            end
        else
            Log:debug("Watchlist button created (insertedIndex=%d); FocusManager not yet ready, will register via setGui hook", backIndex + 1)
        end
    else
        Log:debug("Watchlist button reused (cached on map frame instance)")
    end

    local btn = self.rmFmWatchlistButton
    local state = nil
    if self.mapOverviewSelector ~= nil then
        state = self.mapOverviewSelector:getState()
    end
    btn:setVisible(RmWatchlistUI.shouldShow(state))
    if self.buttonBack.parent ~= nil and self.buttonBack.parent.invalidateLayout ~= nil then
        self.buttonBack.parent:invalidateLayout()
    end

    Log:trace("<<< RmWatchlistUI.onFrameOpenHook")
end

--- Append-hook body for InGameMenuMapFrame.onClickMapOverviewSelector.
--- Refreshes Watchlist button visibility when the player toggles subcategory dots.
---@param self table InGameMenuMapFrame instance
---@param state number new subcategory state
local function onClickMapOverviewSelectorHook(self, state)
    Log:trace(">>> RmWatchlistUI.onClickMapOverviewSelectorHook(state=%s)", tostring(state))
    if self.rmFmWatchlistButton == nil then
        Log:trace("RmWatchlistUI.onClickMapOverviewSelectorHook: button not yet created, skip")
        return
    end
    local visible = RmWatchlistUI.shouldShow(state)
    self.rmFmWatchlistButton:setVisible(visible)
    if self.buttonBack ~= nil and self.buttonBack.parent ~= nil
        and self.buttonBack.parent.invalidateLayout ~= nil then
        self.buttonBack.parent:invalidateLayout()
    end
    Log:trace("<<< RmWatchlistUI.onClickMapOverviewSelectorHook (visible=%s)", tostring(visible))
end

-- ============================================================================
-- WATCHLIST STATE (local cache; the server master lives in RmWatchlistStore)
--
-- Curated set of farmlandIds the local player is watching, scoped to the
-- local farm only. Mutated via the map action-menu toggle button; read by
-- the dialog's filter and by the _recomputeAction helper.
--
-- Per-farm scope is enforced in the SERVER MASTER (RmWatchlistStore.byFarm,
-- keyed [farmId][farmlandId]). The client view stays single-level because a
-- client only ever sees its own farm's subset. Mutations on the client
-- update locally (optimistic) and dispatch through the store (host: direct
-- call; non-host client: RmWatchlistToggleEvent). On server rejection the
-- server sends a corrective RmWatchlistSyncEvent that overwrites this view.
-- ============================================================================

RmWatchlistUI.watched = {}

--- Local farm id helper. Used by add/remove on the host short-circuit path.
--- Mirrors RmNegotiationManager's resolution of the local farmId.
---@return number|nil
function RmWatchlistUI._localFarmId()
    if g_currentMission == nil or g_currentMission.getFarmId == nil then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    if type(farmId) ~= "number" or farmId <= 0 then
        return nil
    end
    return farmId
end

--- Replace the local watched cache from a server-pushed id list. Used by
--- RmWatchlistSyncEvent (late-join + corrective syncs) AND by the host's
--- post-load rehydrate hook. Mutates the table in place so external
--- references stay valid.
---@param ids number[] farmlandIds for this client's farm
function RmWatchlistUI.replaceFromSync(ids)
    for k in pairs(RmWatchlistUI.watched) do
        RmWatchlistUI.watched[k] = nil
    end
    if ids ~= nil then
        for _, farmlandId in ipairs(ids) do
            RmWatchlistUI.watched[farmlandId] = true
        end
    end
    Log:debug("RmWatchlistUI.replaceFromSync: %d entries", ids and #ids or 0)
end

--- Roll back the local optimistic mutation when dispatch can't reach the
--- server (or when the host short-circuit rejects). Mirror image of the
--- mutation add/remove just performed: addOp=true -> remove, addOp=false
--- -> add. Keeps watched in sync with the server master without waiting
--- for a corrective sync (which the host short-circuit can't trigger
--- and which a no-connection client will never receive).
---@param farmlandId number
---@param addOp boolean operation that just happened locally and must be undone
local function rollbackLocal(farmlandId, addOp)
    if addOp then
        RmWatchlistUI.watched[farmlandId] = nil
    else
        RmWatchlistUI.watched[farmlandId] = true
    end
    Log:debug("rollbackLocal: undid %s for farmlandId=%s",
        addOp and "add" or "remove", tostring(farmlandId))
end

--- Dispatch a toggle to the server. Host short-circuits to RmWatchlistStore
--- (no event round-trip); non-host clients send RmWatchlistToggleEvent.
--- Internal: callers should use add/remove which apply optimistic local
--- updates first.
---
--- Rollback policy: when the host's applyToggle rejects, OR when a client
--- has no path to the server (no g_client / no conn), the optimistic local
--- update is undone here. For accepted client sends, divergence is
--- self-correcting - the server either commits or sends a corrective sync.
--- Test-only seam. When set true, dispatchToggle becomes a no-op that
--- always returns true, leaving the optimistic local mutation in place
--- and bypassing the server master entirely. Used by RmWatchlistStateTests
--- (which only exercise the local-cache contract with synthetic ids that
--- would otherwise be rejected by RmWatchlistStore.applyToggle). Tests
--- MUST flip this back to false (or nil) on teardown.
RmWatchlistUI._bypassDispatchForTest = false

---@param farmlandId number
---@param addOp boolean
---@return boolean committed true when the local mutation should be reported
---  as the function's outcome (host applyToggle accepted, OR client event
---  was sent successfully). false when the local mutation was rolled back.
local function dispatchToggle(farmlandId, addOp)
    if RmWatchlistUI._bypassDispatchForTest then
        return true
    end
    if g_server ~= nil then
        local farmId = RmWatchlistUI._localFarmId()
        if farmId == nil then
            Log:warning("dispatchToggle: no local farmId, host short-circuit skipped; rolling back")
            rollbackLocal(farmlandId, addOp)
            return false
        end
        local ok, reason = RmWatchlistStore.applyToggle(farmId, farmlandId, addOp)
        if not ok then
            Log:debug("dispatchToggle: host applyToggle rejected (reason=%s); rolling back",
                tostring(reason))
            rollbackLocal(farmlandId, addOp)
            return false
        end
        return true
    end
    if g_client == nil then
        Log:warning("dispatchToggle: no g_client connection, dropping; rolling back")
        rollbackLocal(farmlandId, addOp)
        return false
    end
    local conn = g_client:getServerConnection()
    if conn == nil then
        Log:warning("dispatchToggle: no server connection, dropping; rolling back")
        rollbackLocal(farmlandId, addOp)
        return false
    end
    conn:sendEvent(RmWatchlistToggleEvent.new(farmlandId, addOp))
    return true
end

--- Check whether a farmland is on the player's watchlist.
---@param farmlandId number
---@return boolean
function RmWatchlistUI.isWatched(farmlandId)
    return RmWatchlistUI.watched[farmlandId] == true
end

--- Add a farmland to the watchlist. Idempotent.
--- Side-effect model: optimistic local update + dispatch to the server
--- master (host: direct RmWatchlistStore.applyToggle; non-host client:
--- RmWatchlistToggleEvent). The return value reflects the COMMITTED
--- outcome - i.e. it is `true` only when dispatch accepted (host: store
--- accepted; client: event sent successfully). On host rejection or no
--- client connection, the optimistic mutation is rolled back and we
--- return false, so callers (and the regression suite) see truthful
--- state transitions rather than transient optimistic ones.
---@param farmlandId number
---@return boolean wasAdded true if newly added AND dispatch committed; false otherwise
function RmWatchlistUI.add(farmlandId)
    if RmWatchlistUI.watched[farmlandId] == true then
        return false
    end
    RmWatchlistUI.watched[farmlandId] = true
    -- %s + tostring is defensive: production callers pass numeric ids, but a
    -- bad caller passing a string id would crash a %d formatter.
    Log:debug("RmWatchlistUI.add: farmlandId=%s added (local)", tostring(farmlandId))
    return dispatchToggle(farmlandId, true)
end

--- Remove a farmland from the watchlist. Idempotent.
--- See add() for the side-effect model. Return value reflects the
--- committed outcome.
---@param farmlandId number
---@return boolean wasRemoved true if was present AND dispatch committed; false otherwise
function RmWatchlistUI.remove(farmlandId)
    if RmWatchlistUI.watched[farmlandId] ~= true then
        return false
    end
    RmWatchlistUI.watched[farmlandId] = nil
    Log:debug("RmWatchlistUI.remove: farmlandId=%s removed (local)", tostring(farmlandId))
    return dispatchToggle(farmlandId, false)
end

--- Flip a farmland's watchlist membership. Returns the watched state AFTER
--- dispatch settles, so a host rejection on add (or a no-conn rollback)
--- correctly reports `false` rather than the optimistic intent.
---@param farmlandId number
---@return boolean isNowWatched the new state, post-dispatch
function RmWatchlistUI.toggle(farmlandId)
    if RmWatchlistUI.isWatched(farmlandId) then
        RmWatchlistUI.remove(farmlandId)
    else
        RmWatchlistUI.add(farmlandId)
    end
    return RmWatchlistUI.isWatched(farmlandId)
end

--- Drop every entry. Called on map unload via the BaseMission.delete hook.
--- Mutates the table in place (rather than re-binding it) so any external
--- reference holders see the cleared state - matches the test helper's
--- contract and keeps add/remove/clear consistent. Always emits the DEBUG
--- count line so the lifecycle hook stays diagnosable even on no-op session.
function RmWatchlistUI.clear()
    local count = 0
    for k in pairs(RmWatchlistUI.watched) do
        RmWatchlistUI.watched[k] = nil
        count = count + 1
    end
    Log:debug("RmWatchlistUI.clear: cleared %d entries", count)
end

--- Drop watched ids whose farmland is missing from the input table or no
--- longer passes the eligibility helper. Prevents stale residue when a
--- watched farmland transitions to owned (e.g. the player buys it).
---@param farmlandsTable table map of farmlandId -> Farmland (e.g. g_farmlandManager:getFarmlands())
---@return number prunedCount how many entries were removed
function RmWatchlistUI.pruneStale(farmlandsTable)
    if farmlandsTable == nil then
        return 0
    end
    local pruned = 0
    local toRemove = {}
    for farmlandId in pairs(RmWatchlistUI.watched) do
        local farmland = farmlandsTable[farmlandId]
        -- type(...) == "table" guard: custom maps have produced surprising
        -- non-table scalars before. RmFmAvailability.isEligibleForAvailability
        -- dereferences farmland.farmId without its own nil-guard, so a non-
        -- table value would crash this loop and the whole dialog open.
        if type(farmland) ~= "table"
            or not RmFmAvailability.isEligibleForAvailability(farmland) then
            table.insert(toRemove, farmlandId)
        end
    end
    for _, id in ipairs(toRemove) do
        RmWatchlistUI.watched[id] = nil
        pruned = pruned + 1
    end
    if pruned > 0 then
        Log:debug("RmWatchlistUI.pruneStale: pruned %d stale entries", pruned)
    end
    return pruned
end

-- ============================================================================
-- FOR-SALE TRANSITION NOTIFICATION
--
-- When a watched farmland flips isForSale=false -> isForSale=true, we surface
-- an in-game message that the player must dismiss. Two paths feed this helper:
--   - Host: RmFarmlandMarket.onDayChanged calls notifyForSaleTransitions
--     AFTER ensureListedProfiles has materialized listingPrice values.
--   - Client: RmAvailabilitySyncEvent:run computes the diff against the old
--     local availability state and calls notifyForSaleTransitions, gated by
--     RmFmAvailability._initialSyncSeen so the first sync after join is silent.
-- ============================================================================

local FOR_SALE_OVERFLOW_CAP = 8

--- Compute false->true transitions between two availability snapshots.
--- Returns array of {id, listingPrice} for ids where old.isForSale was false
--- (or missing) and new.isForSale is true. Order is undefined; the caller
--- (or the formatter) sorts by id. Pure function for testability.
---@param oldAvail table map of {[id] = {isForSale, ...}} from before the change
---@param newAvail table map of {[id] = {isForSale, listingPrice, ...}} after the change
---@return table[] transitions list of {id=number, listingPrice=number|nil}
function RmWatchlistUI._collectTransitions(oldAvail, newAvail)
    local transitions = {}
    if newAvail == nil then return transitions end
    for id, newEntry in pairs(newAvail) do
        local nowForSale = type(newEntry) == "table" and newEntry.isForSale == true
        if nowForSale then
            local oldEntry = oldAvail and oldAvail[id] or nil
            local wasForSale = type(oldEntry) == "table" and oldEntry.isForSale == true
            if not wasForSale then
                table.insert(transitions, {
                    id = id,
                    listingPrice = newEntry.listingPrice,
                })
            end
        end
    end
    return transitions
end

--- Predicate: should `rawName` be replaced with the "Farmland N"
--- fallback when rendered? Pure function with no globals - safe to
--- call from anywhere, including `buildEntries` whose tests stub
--- g_i18n / g_currentMission / g_farmlandManager.
---
--- Returns true for: nil, non-string types (number / table / ...),
--- empty string, all-whitespace string, and any string whose trimmed
--- value parses via `tonumber` (covers "11", " 11 ", "-1", "1.0").
---
--- Returns false for non-empty strings with at least one non-numeric
--- character that aren't pure-whitespace, like "Alpha", "1a",
--- "North Pasture", or "50% off".
---@param rawName any
---@return boolean isFallback true when the displayed name should be
---  "Farmland <id>" rather than rawName
function RmWatchlistUI._isFallbackName(rawName)
    if type(rawName) ~= "string" or rawName == "" then
        return true
    end
    local trimmed = rawName:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return true
    end
    return tonumber(trimmed) ~= nil
end

--- Format a farmland display name. Returns rawName verbatim when it's
--- a real distinct label; otherwise falls back to the localized
--- "Farmland N" label.
---
--- Shared by the dialog populator AND the for-sale notification's
--- _resolveFarmlandName. Single source of truth for the fallback rule
--- so the two paths can't diverge again (they did before this helper
--- existed).
---
--- '%' in raw names is NOT escaped: names flow through `%s` placeholders
--- in `string.format`, which copies the argument verbatim. A name like
--- "50% off" renders as "50% off" in the final body.
---@param rawName string|nil|any the candidate raw name (often farmland.name)
---@param farmlandId number the id to use in the fallback label
---@return string display name (always a string)
function RmWatchlistUI._formatFarmlandName(rawName, farmlandId)
    if not RmWatchlistUI._isFallbackName(rawName) then
        return rawName
    end
    local label = (g_i18n ~= nil and g_i18n.getText) and g_i18n:getText("rm_fm_farmland_label") or "Farmland"
    return label .. " " .. tostring(farmlandId)
end

--- Resolve a display name for a farmland id by looking the farmland up in
--- g_farmlandManager and delegating to _formatFarmlandName. Returns nil if
--- the farmland is missing or not a table (custom-map defense - same
--- type-table guard pattern RmWatchlistUI.pruneStale uses).
---@param id number farmlandId
---@return string|nil name display name, or nil if the farmland is unusable
function RmWatchlistUI._resolveFarmlandName(id)
    local farmlands = g_farmlandManager and g_farmlandManager:getFarmlands() or nil
    if farmlands == nil then return nil end
    local farmland = farmlands[id]
    if type(farmland) ~= "table" then return nil end
    return RmWatchlistUI._formatFarmlandName(farmland.name, id)
end

--- Format a built-items list (after filtering + name resolution + sort) into
--- the title and body strings that go to showInGameMessage. Pure function.
---@param items table[] list of {id, name, listingPrice}; assumed sorted by id ascending
---@return string title, string body
function RmWatchlistUI._formatMessage(items)
    local title = (g_i18n ~= nil and g_i18n.getText)
        and g_i18n:getText("rm_fm_watchlist_now_for_sale_title") or "Watchlist update"

    if #items == 1 then
        local item = items[1]
        if type(item.listingPrice) == "number" and item.listingPrice > 0 then
            -- formatMoney(amount, 0, true, true) = "with currency unit and
            -- space" - matches the convention used elsewhere in the mod
            -- (RmNegotiationUI, RmFarmlandMarket contextbox), so the
            -- player's selected currency (EUR / GBP / USD / ...) is
            -- honoured rather than hardcoded. pcall guards against
            -- formatMoney choking on huge / non-finite values; on failure
            -- we fall back to a plain integer string with no unit.
            local ok, priceStr = pcall(function()
                if g_i18n ~= nil and g_i18n.formatMoney then
                    return g_i18n:formatMoney(item.listingPrice, 0, true, true)
                end
                return tostring(item.listingPrice)
            end)
            if not ok then priceStr = tostring(item.listingPrice) end
            local fmt = (g_i18n ~= nil and g_i18n.getText)
                and g_i18n:getText("rm_fm_watchlist_now_for_sale_single_with_price")
                or "%s is now for sale at %s"
            return title, string.format(fmt, item.name, priceStr)
        end
        local fmt = (g_i18n ~= nil and g_i18n.getText)
            and g_i18n:getText("rm_fm_watchlist_now_for_sale_single_no_price")
            or "%s is now for sale"
        return title, string.format(fmt, item.name)
    end

    -- Batched: comma-separate up to 8 names, then "and N more".
    local count = #items
    local names = {}
    local cap = math.min(count, FOR_SALE_OVERFLOW_CAP)
    for i = 1, cap do
        names[i] = items[i].name
    end
    local nameList = table.concat(names, ", ")
    if count > FOR_SALE_OVERFLOW_CAP then
        local overflowFmt = (g_i18n ~= nil and g_i18n.getText)
            and g_i18n:getText("rm_fm_watchlist_now_for_sale_overflow_suffix")
            or ", and %d more"
        nameList = nameList .. string.format(overflowFmt, count - FOR_SALE_OVERFLOW_CAP)
    end
    local fmt = (g_i18n ~= nil and g_i18n.getText)
        and g_i18n:getText("rm_fm_watchlist_now_for_sale_batched")
        or "%d watched farmlands are now for sale: %s"
    return title, string.format(fmt, count, nameList)
end

--- Main entry point. Takes raw transitions (id + listingPrice from the
--- transition site), filters to local watched + still-eligible + non-self,
--- resolves names, sorts by id ascending, formats, and calls
--- showInGameMessage. Silent no-op when there is no HUD (dedicated server,
--- mid-teardown) or when no transitions survive filtering.
---@param transitions table[] list of {id=number, listingPrice=number|nil}
function RmWatchlistUI.notifyForSaleTransitions(transitions)
    if transitions == nil or #transitions == 0 then return end
    if g_currentMission == nil or g_currentMission.hud == nil
        or g_currentMission.hud.showInGameMessage == nil then
        Log:debug("notifyForSaleTransitions: HUD unavailable, silent return")
        return
    end

    local localFarmId = RmWatchlistUI._localFarmId()
    local farmlands = g_farmlandManager and g_farmlandManager:getFarmlands() or nil

    -- Dedupe by id: a caller passing the same id twice (race / batched
    -- syncs / future bug) would otherwise show "Farmland 7, Farmland 7"
    -- and inflate the count.
    local items = {}
    local seen = {}
    for _, t in ipairs(transitions) do
        if not seen[t.id] and RmWatchlistUI.isWatched(t.id) then
            local farmland = farmlands and farmlands[t.id] or nil
            if type(farmland) == "table"
                and RmFmAvailability.isEligibleForAvailability(farmland)
                and farmland.farmId ~= localFarmId then
                local name = RmWatchlistUI._resolveFarmlandName(t.id)
                if name ~= nil then
                    seen[t.id] = true
                    table.insert(items, {
                        id = t.id,
                        name = name,
                        listingPrice = t.listingPrice,
                    })
                end
            end
        end
    end

    if #items == 0 then return end

    table.sort(items, function(a, b) return a.id < b.id end)

    local title, body = RmWatchlistUI._formatMessage(items)
    -- duration=-1 -> engine MAX_DURATION (5min ceiling). Player can dismiss
    -- any time via MENU_ACCEPT / SKIP_MESSAGE_BOX. Silent (no sound).
    g_currentMission.hud:showInGameMessage(title, body, -1, nil, nil, nil)
    Log:info("WATCHLIST: notified %d for-sale transition%s",
        #items, #items == 1 and "" or "s")
end

-- ============================================================================
-- COOLDOWN-EXPIRY NOTIFICATION
--
-- Fired from RmCooldownExpiryEvent:run (clients) AND directly from
-- RmNegotiationManager.onDayChanged for the host (broadcastEvent skips
-- the host loopback). The incoming list carries {farmId, farmlandId} pairs
-- for every cooldown that just reached expiry. Each client filters to its own
-- farm, then to watched + still-eligible, dedupes, sorts, formats once,
-- and calls showInGameMessage once. Non-committal copy ("Cooldown ended on
-- {farmland}") stays truthful even if settings drifted between the
-- cooldown being set and now.
-- ============================================================================

--- Format the cooldown-ended HUD body from a built-items list (post-filter,
--- post-name-resolution, post-sort). Pure function. Mirrors _formatMessage's
--- single / batched / overflow-cap structure but with non-committal copy.
---@param items table[] list of {id, name}; assumed sorted by id ascending
---@return string title, string body
function RmWatchlistUI._formatCooldownMessage(items)
    local title = (g_i18n ~= nil and g_i18n.getText)
        and g_i18n:getText("rm_fm_watchlist_cooldown_ended_title")
        or "Watchlist update"

    if #items == 1 then
        local fmt = (g_i18n ~= nil and g_i18n.getText)
            and g_i18n:getText("rm_fm_watchlist_cooldown_ended_single")
            or "Cooldown ended on %s"
        return title, string.format(fmt, items[1].name)
    end

    local count = #items
    local names = {}
    local cap = math.min(count, FOR_SALE_OVERFLOW_CAP)
    for i = 1, cap do
        names[i] = items[i].name
    end
    local nameList = table.concat(names, ", ")
    if count > FOR_SALE_OVERFLOW_CAP then
        local overflowFmt = (g_i18n ~= nil and g_i18n.getText)
            and g_i18n:getText("rm_fm_watchlist_now_for_sale_overflow_suffix")
            or ", and %d more"
        nameList = nameList .. string.format(overflowFmt, count - FOR_SALE_OVERFLOW_CAP)
    end
    local fmt = (g_i18n ~= nil and g_i18n.getText)
        and g_i18n:getText("rm_fm_watchlist_cooldown_ended_batched")
        or "Cooldown ended on %d watched farmlands: %s"
    return title, string.format(fmt, count, nameList)
end

--- Main entry point. Takes raw expiries (farmId + farmlandId from the period-
--- change site), filters to local farm + watched + still-eligible, resolves
--- names, sorts by id ascending, formats, and calls showInGameMessage once.
--- Silent no-op when there is no HUD (dedicated server, mid-teardown), when
--- the local farmId is unresolved, or when no entries survive filtering.
---@param expiries table[] list of {farmId=number, farmlandId=number}
function RmWatchlistUI.notifyCooldownExpiries(expiries)
    if expiries == nil or #expiries == 0 then
        Log:debug("notifyCooldownExpiries: empty input, silent return")
        return
    end
    if g_currentMission == nil or g_currentMission.hud == nil
        or g_currentMission.hud.showInGameMessage == nil then
        Log:debug("notifyCooldownExpiries: HUD unavailable, silent return")
        return
    end

    local localFarmId = RmWatchlistUI._localFarmId()
    if localFarmId == nil then
        Log:debug("notifyCooldownExpiries: local farmId unresolved, silent return")
        return
    end
    local farmlands = g_farmlandManager and g_farmlandManager:getFarmlands() or nil

    -- Dedupe by farmlandId: the same id could in theory appear twice in the
    -- payload (caller bug / future change). Single message with each id once.
    local items = {}
    local seen = {}
    for _, e in ipairs(expiries) do
        if e.farmId == localFarmId and not seen[e.farmlandId]
            and RmWatchlistUI.isWatched(e.farmlandId) then
            local farmland = farmlands and farmlands[e.farmlandId] or nil
            -- isEligibleForAvailability already enforces NO_OWNER, which
            -- covers "not owned by local farm" (and indeed any owner). The
            -- check is defensive: onOwnershipChanged clears cooldowns, so
            -- a still-watched-and-now-owned farmland here is a race window.
            if type(farmland) == "table"
                and RmFmAvailability.isEligibleForAvailability(farmland) then
                local name = RmWatchlistUI._resolveFarmlandName(e.farmlandId)
                if name ~= nil then
                    seen[e.farmlandId] = true
                    table.insert(items, { id = e.farmlandId, name = name })
                else
                    Log:debug("notifyCooldownExpiries: dropping farmlandId=%d, name unresolved",
                        e.farmlandId)
                end
            end
        end
    end

    if #items == 0 then
        Log:debug("notifyCooldownExpiries: no survivors after filter (input=%d)",
            #expiries)
        return
    end

    table.sort(items, function(a, b) return a.id < b.id end)

    local title, body = RmWatchlistUI._formatCooldownMessage(items)
    g_currentMission.hud:showInGameMessage(title, body, -1, nil, nil, nil)
    Log:info("WATCHLIST: notified %d cooldown-expir%s",
        #items, #items == 1 and "y" or "ies")
end

-- ============================================================================
-- ACTION-MENU TOGGLE (Add to watchlist / Remove from watchlist)
--
-- Registration: contextActions is iterated with ipairs, so only contiguous
-- integer keys render. Sparse / high-integer keys do not render (verified
-- empirically). We append via table.insert (Lua picks the next integer
-- automatically), then capture the resolved index on the live frame instance
-- (self.rmFmWatchlistActionKey) so both the click handler and _recomputeAction
-- can look the action back up.
-- ============================================================================

--- Resolve the farmland the player currently has selected on the map.
--- Returns nil on any guard miss (no hotspot, hotspot is not a farmland,
--- or the farmland resolves to a non-table value).
---@param frame table InGameMenuMapFrame instance
---@return table|nil farmland the resolved Farmland or nil
local function getCurrentFarmland(frame)
    local hotspot = frame.currentHotspot
    if hotspot == nil or hotspot.getFarmland == nil then
        return nil
    end
    local farmland = hotspot:getFarmland()
    if type(farmland) ~= "table" then
        return nil
    end
    return farmland
end

--- Single source of truth for the watchlist action's isActive + title.
--- Called from the setMapInputContext append-hook AND from the click handler
--- so both paths agree on what the button should look like RIGHT NOW.
--- Module-attached (not file-local) so tests can exercise it directly.
---@param frame table InGameMenuMapFrame instance
---@param farmland table|nil the resolved current farmland (or nil)
function RmWatchlistUI._recomputeAction(frame, farmland)
    if frame == nil or frame.contextActions == nil then return end
    local key = frame.rmFmWatchlistActionKey
    if key == nil then return end
    local action = frame.contextActions[key]
    if action == nil then return end

    local isEligible = type(farmland) == "table"
        and RmFmAvailability.isEligibleForAvailability(farmland)
    if not isEligible then
        action.isActive = false
        action.title = nil
        return
    end

    action.isActive = true
    if RmWatchlistUI.isWatched(farmland.id) then
        action.title = g_i18n:getText("rm_fm_btn_removeFromWatchlist")
    else
        action.title = g_i18n:getText("rm_fm_btn_addToWatchlist")
    end
end

--- Click handler for the watchlist toggle context action. Defends against UI
--- race / stale callback by re-validating eligibility before mutating state.
---@param frame table InGameMenuMapFrame instance
local function onWatchlistToggleClick(frame)
    Log:trace(">>> onWatchlistToggleClick")
    -- Dedupe same-physical-click double-fire. Observed: the cell's click
    -- callback fires twice within ~1ms when the user clicks a row that
    -- already has focus. Without this guard each user click would toggle
    -- state twice and net to zero, making the button look unresponsive.
    -- The 100ms window catches the same-tick repeat but is tight enough
    -- that deliberate fast clicks (>=100ms apart) still register.
    local now = g_time or 0
    if frame.rmFmWatchlistLastClickMs ~= nil
        and (now - frame.rmFmWatchlistLastClickMs) < 100 then
        Log:trace("  duplicate click within 100ms (dt=%dms), ignoring",
            now - frame.rmFmWatchlistLastClickMs)
        return
    end
    frame.rmFmWatchlistLastClickMs = now

    local farmland = getCurrentFarmland(frame)
    if farmland == nil then
        Log:trace("  no current farmland, no-op")
        return
    end
    if not RmFmAvailability.isEligibleForAvailability(farmland) then
        Log:trace("  farmland %s not eligible, no-op", tostring(farmland.id))
        return
    end
    local isNowWatched = RmWatchlistUI.toggle(farmland.id)
    -- Update the visible label immediately so the player sees the new state
    -- without waiting for the next setMapInputContext pass.
    RmWatchlistUI._recomputeAction(frame, farmland)
    -- Repaint the action panel so the row's text element picks up the
    -- new action.title. Without this, the data flips but the visible
    -- cell keeps showing the old label and the player concludes the
    -- click did nothing. reloadData only re-runs the populator and has
    -- no other side effects on the panel. We do NOT snap focus to a
    -- different row: Tag/Untag (the precedent we considered mirroring)
    -- also keeps focus on the just-clicked toggle, so the previous
    -- assumption that focus should snap was an in-game misobservation.
    if frame.contextButtonListFarmland ~= nil then
        frame.contextButtonListFarmland:reloadData()
    end
    Log:info("WATCHLIST: farmlandId=%s isWatched=%s",
        tostring(farmland.id), tostring(isNowWatched))
end

--- onFrameOpen append-hook that registers the watchlist toggle by APPENDING
--- a new entry to self.contextActions via table.insert (so the resolved
--- integer key stays contiguous and reachable by ipairs). Idempotent:
--- re-runs against the same frame instance bail out.
---@param frame table InGameMenuMapFrame instance
local function registerWatchlistContextAction(frame)
    if frame.contextActions == nil then return end
    -- Re-arm the per-frame-open trace flag on EVERY onFrameOpen, even when
    -- the action entry already exists. Otherwise reopens of the same frame
    -- instance silence setMapInputContext TRACE after the first open and
    -- the "one TRACE entry per frame open" invariant is violated for every
    -- subsequent open.
    frame.rmFmWatchlistContextTraceArmed = true

    if frame.rmFmWatchlistActionKey ~= nil
        and frame.contextActions[frame.rmFmWatchlistActionKey] ~= nil then
        -- Action already registered against this frame instance; nothing to do.
        return
    end
    table.insert(frame.contextActions, {
        isActive    = false,
        callback    = onWatchlistToggleClick,
        text        = nil,
        title       = nil,
        inputAction = InputAction.NONE,
    })
    frame.rmFmWatchlistActionKey = #frame.contextActions
    Log:trace("RmWatchlistUI: registered context action key=%d (instance)",
        frame.rmFmWatchlistActionKey)
end

--- setMapInputContext append-hook. Runs after the existing FM logic; resolves
--- the current hotspot's farmland and recomputes the watchlist action's
--- isActive + title via the single-source-of-truth helper. Emits a one-shot
--- TRACE per frame open so the steady-state path is diagnosable without
--- spamming the log on every hotspot change.
---@param frame table InGameMenuMapFrame instance
local function setMapInputContextHook(frame)
    if frame.rmFmWatchlistContextTraceArmed == true then
        Log:trace(">>> setMapInputContext (watchlist hook, first call this frame open)")
        frame.rmFmWatchlistContextTraceArmed = false
    end
    RmWatchlistUI._recomputeAction(frame, getCurrentFarmland(frame))
end

--- Named cleanup callback for BaseMission.delete - keeps a stable identity so
--- Utils.appendedFunction does not create a fresh anonymous closure on each
--- script reload.
local function clearWatchlistOnMissionDelete()
    RmWatchlistUI.clear()
end

-- ============================================================================
-- HOOK INSTALLATION
-- ============================================================================

InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameOpen,
    onFrameOpenHook
)

InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameOpen,
    registerWatchlistContextAction
)

InGameMenuMapFrame.setMapInputContext = Utils.appendedFunction(
    InGameMenuMapFrame.setMapInputContext,
    setMapInputContextHook
)

InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(
    InGameMenuMapFrame.onClickMapOverviewSelector,
    onClickMapOverviewSelectorHook
)

-- Wipe the in-memory watchlist when the mission unloads, so a savegame
-- switch starts fresh and never leaks farmlandIds across sessions. Uses a
-- named local closure so re-sourcing the script does not leave duplicate
-- anonymous functions chained via Utils.appendedFunction.
BaseMission.delete = Utils.appendedFunction(BaseMission.delete, clearWatchlistOnMissionDelete)

-- Register cloned controls with FocusManager once the GUI is set up.
-- Without this, cloned elements are not reachable via keyboard/controller
-- navigation. Mirrors RmFmSettings hook.
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == nil or #fmClonedControls == 0 then return end

    local registered = 0
    for _, control in ipairs(fmClonedControls) do
        if not control.focusId
            or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
            if FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                registered = registered + 1
            else
                Log:warning("RmWatchlistUI: failed to register %s with FocusManager",
                    control.id or control.typeName or "?")
            end
        end
    end

    if registered > 0 then
        Log:trace("RmWatchlistUI: registered %d cloned controls with FocusManager", registered)
    end
end)

Log:info("RmWatchlistUI hooks installed")
