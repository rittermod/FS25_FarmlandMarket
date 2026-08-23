--[[
    RmWatchlistSyncEvent.lua
    Server -> client(s). Carries a byFarm snapshot of the watchlist.

    Used in three paths:
      1. Late-join sync (RmWatchlistStore.sendInitialClientState)
         -- server scopes the snapshot to the joining connection's farm.
      2. Corrective sync after a rejected RmWatchlistToggleEvent
         -- server scopes the snapshot to the rejected connection's farm.
      3. Live broadcast on applyToggle (RmWatchlistStore.broadcastFullState)
         -- snapshot covers all farms; uses g_server:broadcastEvent which
         defaults sendLocal=false, so the host loopback is skipped.
         (See wiki/conventions/server-client-guards Pattern 4 - Broadcast sync.)

    Wire format:
      Int32 farmCount
      For each farm:
        Int32 farmId
        Int32 idCount
        Int32[idCount] farmlandIds   (sorted ascending)

    Receiver picks self.byFarm[ownFarmId] (already a sorted dense number[])
    and hands it straight to RmWatchlistUI.replaceFromSync. No set-table
    conversion at any boundary -- replaceFromSync uses ipairs and would
    silently clear the cache if handed a set.

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

RmWatchlistSyncEvent = {}
local Mt = Class(RmWatchlistSyncEvent, Event)
InitEventClass(RmWatchlistSyncEvent, "RmWatchlistSyncEvent")

--- Empty constructor required by the event framework.
--- Test-only seam: when true, readStream skips the trailing self:run call so a
--- round-trip test can verify deserialization without mutating production
--- state. Tests MUST flip this back to false on teardown.
RmWatchlistSyncEvent._skipRunForTest = false

function RmWatchlistSyncEvent.emptyNew()
    return Event.new(Mt)
end

--- Construct the event with a byFarm snapshot.
---
--- The input is defensively COPIED + COMPACTED so a sparse caller (an array
--- with nil holes) cannot make writeStream's `#ids` count diverge from its
--- streamWriteInt32 write loop, which would crash the engine. All current
--- callers pass dense tables produced by pruneStaleSubset; the copy is a
--- guard against future refactors.
---
---@param byFarm table {[farmId] = number[]} dense, ascending-sorted ids per farm
---@return table event
function RmWatchlistSyncEvent.new(byFarm)
    local self = Event.new(Mt)
    self.byFarm = {}
    if type(byFarm) == "table" then
        for farmId, ids in pairs(byFarm) do
            if type(farmId) == "number" and farmId > 0 and type(ids) == "table" then
                local copy = {}
                for _, id in ipairs(ids) do
                    if type(id) == "number" then
                        table.insert(copy, id)
                    end
                end
                self.byFarm[farmId] = copy
            end
        end
    end
    return self
end

--- Sorted list of farmIds present in self.byFarm. Sorting is required so the
--- wire bytes are deterministic across runs (stream-mock tests assert order).
---@return number[]
function RmWatchlistSyncEvent:_sortedFarmIds()
    local out = {}
    for farmId in pairs(self.byFarm) do
        table.insert(out, farmId)
    end
    table.sort(out)
    return out
end

---@param streamId number
---@param connection table
function RmWatchlistSyncEvent:writeStream(streamId, connection)
    local farmIds = self:_sortedFarmIds()
    streamWriteInt32(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        local ids = self.byFarm[farmId]
        streamWriteInt32(streamId, farmId)
        streamWriteInt32(streamId, #ids)
        for i = 1, #ids do
            streamWriteInt32(streamId, ids[i])
        end
    end
    Log:trace("RmWatchlistSyncEvent:writeStream farms=%d", #farmIds)
end

---@param streamId number
---@param connection table
function RmWatchlistSyncEvent:readStream(streamId, connection)
    local farmCount = streamReadInt32(streamId)
    self.byFarm = {}
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        local idCount = streamReadInt32(streamId)
        local ids = {}
        for j = 1, idCount do
            ids[j] = streamReadInt32(streamId)
        end
        self.byFarm[farmId] = ids
    end
    Log:trace("RmWatchlistSyncEvent:readStream farms=%d", farmCount)
    if not RmWatchlistSyncEvent._skipRunForTest then
        self:run(connection)
    end
end

---@param connection table
function RmWatchlistSyncEvent:run(connection)
    if g_server ~= nil then
        -- Server-authoritative: clients should never send this event.
        -- Defensive backstop only -- broadcastEvent(sendLocal=false) skips the
        -- host loopback so this branch should never fire in normal operation.
        Log:warning("RmWatchlistSyncEvent rejected: clients cannot send (server-authoritative)")
        return
    end
    self:_applyClientSync(connection)
end

--- Apply an incoming sync as if we were a client. Split out so unit tests can
--- drive the client-side logic without stubbing g_server (the fmTest harness
--- keeps g_server set throughout, which would short-circuit run()).
---
--- Three-case dispatch (cache-clear discipline):
---  (a) own-farm present with non-empty ids -> replace cache with the array.
---  (b) own-farm present with empty array   -> clear cache (server says "your
---      farm is empty now"; e.g. removing the last entry).
---  (c) own-farm absent OR own farmId unresolved -> NO-OP (do not touch the
---      cache). Prevents optimistic-mutation-race wipes from cross-farm
---      broadcasts and prevents late-join data loss when a snapshot arrives
---      before farm-binding completes on the client.
---@param connection table|nil
function RmWatchlistSyncEvent:_applyClientSync(connection)
    local ownFarmId = nil
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local resolved = g_currentMission:getFarmId()
        if type(resolved) == "number" and resolved > 0 then
            ownFarmId = resolved
        end
    end

    if ownFarmId == nil then
        -- Case (c): unresolved farmId. Stray pre-binding broadcast or other
        -- race; leave the cache alone so a subsequent sync (or a server
        -- broadcast that arrives after binding) can populate it correctly.
        Log:warning("Watchlist sync ignored: own farmId not yet resolved")
        return
    end

    local ownIds = self.byFarm[ownFarmId]
    if ownIds == nil then
        -- Case (c): own-farm absent. Broadcast not addressed to my farm
        -- (e.g. an unrelated farm just toggled). Leave the cache alone.
        Log:debug("Watchlist sync: own farm=%d absent from snapshot, cache unchanged",
            ownFarmId)
        return
    end

    -- Case (a) or (b): own-farm present. Compare incoming ids against
    -- the current cache as sets. If unchanged, this is a no-op broadcast
    -- (some other farm toggled, our subset is just along for the ride);
    -- log DEBUG and skip the cache rewrite to avoid INFO log spam on
    -- every cross-farm toggle for clients that have any watchlist rows.
    if RmWatchlistSyncEvent._idsMatchWatched(ownIds) then
        Log:debug("Watchlist sync: own farm=%d unchanged (%d entries), no-op",
            ownFarmId, #ownIds)
        return
    end

    Log:info("Received watchlist sync: %d entries for own farm=%d",
        #ownIds, ownFarmId)
    RmWatchlistUI.replaceFromSync(ownIds)
end

--- Compare an incoming ids array against the current `RmWatchlistUI.watched`
--- set. Returns true iff they represent the same set of farmlandIds.
--- Cheap O(n) check (size + membership) -- avoids the cache rewrite and the
--- INFO log line when the broadcast doesn't actually change own state.
---@param ownIds number[]
---@return boolean
function RmWatchlistSyncEvent._idsMatchWatched(ownIds)
    if RmWatchlistUI == nil or RmWatchlistUI.watched == nil then
        return false
    end
    local watchedCount = 0
    for _ in pairs(RmWatchlistUI.watched) do watchedCount = watchedCount + 1 end
    if watchedCount ~= #ownIds then return false end
    for _, id in ipairs(ownIds) do
        if RmWatchlistUI.watched[id] ~= true then return false end
    end
    return true
end
