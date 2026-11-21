--[[
    RmNegotiationResultEvent.lua
    Host -> client: negotiation result with sanitized snapshot.

    Sent by server after processing a RmNegotiationRequestEvent.
    Contains success/error status and a serialized session snapshot.

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

-- Event class declaration
RmNegotiationResultEvent = {}
local Mt = Class(RmNegotiationResultEvent, Event)
InitEventClass(RmNegotiationResultEvent, "RmNegotiationResultEvent")

--- Create empty event instance (required by event system)
---@return table event
function RmNegotiationResultEvent.emptyNew()
    Log:trace(">>> RmNegotiationResultEvent.emptyNew()")
    local self = Event.new(Mt)
    Log:trace("<<< RmNegotiationResultEvent.emptyNew()")
    return self
end

--- Create new event with result data
---@param success boolean
---@param errorReason string Error reason if failed ("" if success)
---@param snapshot table|nil Sanitized session snapshot
---@return table event
function RmNegotiationResultEvent.new(success, errorReason, snapshot)
    Log:trace(">>> RmNegotiationResultEvent.new(success=%s)", tostring(success))
    local self = Event.new(Mt)
    self.success = success
    self.errorReason = errorReason
    self.snapshot = snapshot
    Log:trace("<<< RmNegotiationResultEvent.new()")
    return self
end

--- Serialize event data to network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmNegotiationResultEvent:writeStream(streamId, connection)
    Log:trace(">>> RmNegotiationResultEvent:writeStream(success=%s)", tostring(self.success))

    streamWriteBool(streamId, self.success)
    streamWriteString(streamId, self.errorReason)
    streamWriteBool(streamId, self.snapshot ~= nil)

    if self.snapshot then
        local s = self.snapshot
        streamWriteInt32(streamId, s.farmlandId)
        streamWriteString(streamId, s.mode)
        streamWriteInt32(streamId, s.round)
        streamWriteString(streamId, s.state)
        streamWriteFloat32(streamId, s.lastCounter or 0)
        streamWriteBool(streamId, s.lastCounter ~= nil)
        streamWriteString(streamId, s.outcome or "")
        streamWriteFloat32(streamId, s.finalPrice or 0)
        streamWriteBool(streamId, s.finalPrice ~= nil)
        streamWriteFloat32(streamId, s.anchorPrice or 0)
        streamWriteBool(streamId, s.anchorPrice ~= nil)
        streamWriteFloat32(streamId, s.rejectFloor or 0)
        streamWriteBool(streamId, s.rejectFloor ~= nil)
        -- A stream cannot carry nil, so "" stands for no predicted buyer
        streamWriteString(streamId, s.buyerName or "")
        Log:trace("  writeStream: buyerName '%s'", tostring(s.buyerName))

        -- Pending proposal
        streamWriteBool(streamId, s.pendingProposal ~= nil)
        if s.pendingProposal then
            streamWriteString(streamId, s.pendingProposal.type)
            streamWriteFloat32(streamId, s.pendingProposal.price)
            streamWriteFloat32(streamId, s.pendingProposal.counter or 0)
            streamWriteBool(streamId, s.pendingProposal.counter ~= nil)
        end

        -- Offers array
        local offerCount = #s.offers
        streamWriteInt32(streamId, offerCount)
        local isSell = (s.mode == RmNegotiationEngine.MODE_SELL)
        for i = 1, offerCount do
            local entry = s.offers[i]
            streamWriteInt32(streamId, entry.round)
            if isSell then
                streamWriteFloat32(streamId, entry.npcOffer or 0)
                streamWriteFloat32(streamId, entry.playerAsk or 0)
                streamWriteFloat32(streamId, entry.npcResponse or 0)
                streamWriteBool(streamId, entry.npcResponse ~= nil)
            else
                streamWriteFloat32(streamId, entry.offer or 0)
                streamWriteFloat32(streamId, entry.counter or 0)
                streamWriteBool(streamId, entry.counter ~= nil)
            end
        end
    end

    Log:trace("<<< RmNegotiationResultEvent:writeStream()")
end

--- Deserialize event data from network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmNegotiationResultEvent:readStream(streamId, connection)
    Log:trace(">>> RmNegotiationResultEvent:readStream()")

    self.success = streamReadBool(streamId)
    self.errorReason = streamReadString(streamId)
    local hasSnapshot = streamReadBool(streamId)

    if hasSnapshot then
        local s = {}
        s.farmlandId = streamReadInt32(streamId)
        s.mode = streamReadString(streamId)
        s.round = streamReadInt32(streamId)
        s.state = streamReadString(streamId)
        local lastCounterVal = streamReadFloat32(streamId)
        local hasLastCounter = streamReadBool(streamId)
        s.lastCounter = hasLastCounter and lastCounterVal or nil
        s.outcome = streamReadString(streamId)
        if s.outcome == "" then s.outcome = nil end
        local finalPriceVal = streamReadFloat32(streamId)
        local hasFinalPrice = streamReadBool(streamId)
        s.finalPrice = hasFinalPrice and finalPriceVal or nil
        local anchorPriceVal = streamReadFloat32(streamId)
        local hasAnchorPrice = streamReadBool(streamId)
        s.anchorPrice = hasAnchorPrice and anchorPriceVal or nil
        local rejectFloorVal = streamReadFloat32(streamId)
        local hasRejectFloor = streamReadBool(streamId)
        s.rejectFloor = hasRejectFloor and rejectFloorVal or nil
        s.buyerName = streamReadString(streamId)
        if s.buyerName == "" then s.buyerName = nil end
        Log:trace("  readStream: buyerName '%s'", tostring(s.buyerName))

        -- Pending proposal
        local hasProposal = streamReadBool(streamId)
        if hasProposal then
            s.pendingProposal = {}
            s.pendingProposal.type = streamReadString(streamId)
            s.pendingProposal.price = streamReadFloat32(streamId)
            local proposalCounterVal = streamReadFloat32(streamId)
            local hasProposalCounter = streamReadBool(streamId)
            s.pendingProposal.counter = hasProposalCounter and proposalCounterVal or nil
        else
            s.pendingProposal = nil
        end

        -- Offers array (mode determines schema)
        local offerCount = streamReadInt32(streamId)
        s.offers = {}
        local isSellMode = (s.mode == RmNegotiationEngine.MODE_SELL)
        for i = 1, offerCount do
            local round = streamReadInt32(streamId)
            if isSellMode then
                local npcOffer = streamReadFloat32(streamId)
                local playerAsk = streamReadFloat32(streamId)
                local npcResponseVal = streamReadFloat32(streamId)
                local hasNpcResponse = streamReadBool(streamId)
                s.offers[i] = {
                    round = round,
                    npcOffer = npcOffer,
                    playerAsk = playerAsk,
                    npcResponse = hasNpcResponse and npcResponseVal or nil,
                }
            else
                local offer = streamReadFloat32(streamId)
                local counterVal = streamReadFloat32(streamId)
                local hasCounter = streamReadBool(streamId)
                s.offers[i] = { round = round, offer = offer, counter = hasCounter and counterVal or nil }
            end
        end

        self.snapshot = s
    else
        self.snapshot = nil
    end

    self:run(connection)
    Log:trace("<<< RmNegotiationResultEvent:readStream()")
end

--- Execute event on client: dispatch to UI callback if registered, otherwise log.
---@param connection table Connection object
function RmNegotiationResultEvent:run(connection)
    Log:trace(">>> RmNegotiationResultEvent:run()")

    if g_server ~= nil then
        Log:warning("NegotiationResult rejected: server should not receive results")
        return
    end

    -- CLIENT: dispatch to UI callback
    if RmNegotiationUI ~= nil and RmNegotiationUI.onResultReceived ~= nil then
        RmNegotiationUI.onResultReceived(self.success, self.errorReason, self.snapshot)
    end

    -- Always log for debugging
    if self.success and self.snapshot then
        Log:info("NEGOTIATION_RESULT: %s farmland %d - %s",
            self.snapshot.mode, self.snapshot.farmlandId, self.snapshot.state)
    elseif not self.success then
        Log:info("NEGOTIATION_RESULT: Failed - %s", self.errorReason)
    end

    Log:trace("<<< RmNegotiationResultEvent:run()")
end
