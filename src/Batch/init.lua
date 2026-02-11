--[[
	Batch.luau
	
	This module is very important part in Graphite project, it used for batching events and send it in one package.
	
	Batch module using LIFO queues for very fast O(1) opertations

	Invariant:
		A slice must not mix different EventIds or targets.
	
	Graphite enforces the invariant that each slice
	contains events of exactly one EventId and one target (player or broadcast),
	which reduces protocol overhead to a single byte per slice, regardless of the number of events batched inside.
--]]

--!strict
--!optimize 2

local Buffers = require("./Buffers")
local BinBuffer = require("./BinBuffer")
local Dispatch = require("./Dispatch")
local QNC = require("@self/QNC")

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local IS_SERVER = RunService:IsServer()

local Remote: RemoteEvent =
	if IS_SERVER then
	Instance.new("RemoteEvent", ReplicatedStorage)
	else
	ReplicatedStorage:WaitForChild("__GRAPHITE__") :: RemoteEvent

Remote.Name = "__GRAPHITE__"

local CAPACITY = 1024

type Target = Player | "All"
type Array<T> = {T}
type Buffer = BinBuffer.Buffer

local NULL   = table.freeze({})
type  Slice  = Array<Buffer>
type  Nullable<T> = typeof(NULL) | T
type  HashMap<K, V> = {[K]: V}

local EMPTY = -1

local Queue:     Array<Nullable<Slice>>   = table.create(CAPACITY, NULL) -- this is not a FIFO queue, this is a LIFO queue
local Targets:   Array<Nullable<Target>>  = table.create(CAPACITY, NULL)
local Id:        Array<number>            = table.create(CAPACITY, EMPTY) -- 0 GC yayy, no rehashing and resizing
local IsDroppable: Array<Nullable<any>>   = table.create(CAPACITY, NULL) -- dumb typecheck error
local Count = 0
local TotalBuffers = 0
local LastTotalBuffers = 0

--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
-- Insert
--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
local Index: HashMap<number, HashMap<Target, number>> = {}
local Push = function(eventId: number, buf: Buffer, target: Target?, droppable: boolean)
	target = target or "All"

	local byEvent = Index[eventId]
	if byEvent then
		local idx = byEvent[target]
		if idx then
			local arr = Queue[idx]
			IsDroppable[idx] = IsDroppable[idx] and droppable
		
			
			arr[#arr + 1] = buf
			TotalBuffers += 1
			return
		end
	else
		byEvent = {} :: HashMap<"All" | Player, number>
		Index[eventId] = byEvent
	end

	Count += 1
	local idx = Count

	Id[idx] = eventId
	Targets[idx] = target

	local arr = table.create(4)
	arr[1] = buf
	Queue[idx] = arr

	byEvent[target] = idx
	TotalBuffers += 1
end

--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
-- Slice
--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#

local Slice = function(
	buf: Array<Buffer>,
	sliceSize: number
): Slice?
	local len = #buf
	if len == 0 then
		return nil
	end
	
	if sliceSize >= len then
		local out = table.create(len)
		table.move(buf, 1, len, 1, out)

		for i = 1, len do
			buf[i] = nil
		end

		return out
	end
	
	local out = table.create(sliceSize)
	table.move(buf, 1, sliceSize, 1, out)
	
	local newLen = len - sliceSize
	table.move(buf, sliceSize+1, len, 1, buf)
	
	for i = newLen + 1, len do
		buf[i] = nil
	end
	
	return out :: Slice
end


local free = function(slice: Array<Buffer>)
	for i = 1, #slice do
		BinBuffer.truncate(slice[i])
		Buffers.Release(slice[i])
	end
	TotalBuffers -= #slice
end

local Merge = function(id: number, bufs: Array<Buffer>): buffer
	local size = 0
	for i = 1, #bufs do
		size += bufs[i]._writeOffset
	end

	local out = buffer.create(2 + size)
	buffer.writeu16(out, 0, id)

	local cursor = 2
	for i = 1, #bufs do
		local src = bufs[i]
		local len = src._writeOffset

		buffer.copy(out, cursor, src._buffer, 0, len)
		cursor += len
	end

	return out
end

local DropBuffers = function(bufs: Array<Buffer>, amount: number)
	local len = #bufs
	if len == 0 then return end

	local drop = math.min(amount, len)

	for i = len, len - drop + 1, -1 do
		local buf = bufs[i]
		BinBuffer.truncate(buf)
		Buffers.Release(buf)
		bufs[i] = nil
	end

	TotalBuffers -= drop
end

--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#
-- Main Loop
--#-#-#-#-#-#-#-#-#-#-#-#-#-#-#-#


local budget = 5
local sliceSize = 20
local TotalTime = 0

local TypeOf = typeof

if IS_SERVER then
	RunService.Heartbeat:Connect(function(DeltaTime: number)		
		if Count == 0 then
			LastTotalBuffers = 0
			return
		end

		TotalTime += DeltaTime


		local newBudget, newSize, needDrop, dropAmount = QNC(
			TotalBuffers,
			TotalBuffers - LastTotalBuffers,
			TotalTime,
			DeltaTime
		)		
		budget = newBudget; sliceSize = newSize
		LastTotalBuffers = TotalBuffers
		
			
		local used = 0
		local index = Count
		while index > 0 and used < budget do
			local id = Id[index]
			local target = Targets[index] :: Target
			local bufs = Queue[index] :: Slice
			local isDroppable = IsDroppable[index]
			if bufs == NULL or target == NULL then break end
			
			if needDrop and isDroppable	 then
				DropBuffers(bufs, dropAmount)
			end
			
			
			local slice = Slice(bufs, sliceSize) :: Slice
			
			if not slice then
				index -= 1
				continue
			end
			
			local merged = Merge(id, slice)
			
			if target == "All" then
				Remote:FireAllClients(merged)
			else
				Remote:FireClient(target, merged)
			end
			
			free(slice)
			used += 1
		
			local clear = (#bufs == 0)
			if clear then
				Index[id][target :: Target] = nil 

				local last = Count
				if index ~= last then
					Queue[index] = Queue[last]
					Targets[index] = Targets[last]
					Id[index] = Id[last]
					Index[Id[index]][Targets[index] :: Target] = index
					IsDroppable[index] = IsDroppable[last]
				end

				IsDroppable[last] = NULL
				Queue[last] = NULL
				Targets[last] = NULL
				Id[last] = EMPTY

				Count -= 1
				TotalTime = 0
				LastTotalBuffers = 0
			else
				index -= 1
			end
		end
		
	end)
	
	Remote.OnServerEvent:Connect(function(player, buf)
		if TypeOf(buf) ~= "buffer" then return end
		if buffer.len(buf) < 2 then return end

		local eventId = buffer.readu16(buf, 0)
		local deserializer = Dispatch.GetDeserializaer(eventId)
		if not deserializer then return end

		local cursor = 2
		local maxLen = buffer.len(buf)

		while cursor < maxLen do
			local newCursor, data = deserializer(cursor, buf)

			if newCursor > maxLen then
				warn("[Graphite] cursor overflow in packet, packet droped")
				return
			end

			if not newCursor or newCursor <= cursor then
				warn("[Graphite] packet droped, reason: ".. tostring(data))
				return
			end

			cursor = newCursor

			Dispatch.CallListener(eventId, player, table.unpack(data))
		end
	end)
else
	RunService.Heartbeat:Connect(function(DeltaTime: number)
		if Count == 0 then
			LastTotalBuffers = 0
			return
		end

		local newBudget, newSize, needDrop, dropAmount = QNC(
			TotalBuffers,
			TotalBuffers - LastTotalBuffers,
			TotalTime,
			DeltaTime
		)
		budget = newBudget; sliceSize = newSize
		LastTotalBuffers = TotalBuffers
		

		local used = 0
		local index = Count
		while index > 0 and used < budget do
			local id = Id[index]
			local target = Targets[index] :: Target
			local bufs = Queue[index] :: Slice
			local isDroppable = IsDroppable[index]
			if bufs == NULL or target == NULL then break end
			
			if needDrop and isDroppable then
				DropBuffers(bufs, dropAmount)
			end

			local slice = Slice(bufs, sliceSize) :: Slice
			if not slice then
				index -= 1
				continue
			end

			local merged = Merge(id, slice)

			if target == "All" then
				Remote:FireServer(merged)
			end

			free(slice)
			used += 1

			local clear = (#bufs == 0)
			if clear then
				Index[id][target] = nil

				local last = Count
				if index ~= last then
					Queue[index] = Queue[last]
					Targets[index] = Targets[last]
					Id[index] = Id[last]
					Index[Id[index]][Targets[index] :: Target] = index
					IsDroppable[index] = IsDroppable[last]
				end

				IsDroppable[index] = NULL
				Queue[last] = NULL
				Targets[last] = NULL
				Id[last] = EMPTY

			
				Count -= 1
				LastTotalBuffers = 0
			else
				index -= 1
			end
		end
	end)
	
	Remote.OnClientEvent:Connect(function(buf: buffer)
		local eventId = buffer.readu16(buf, 0)
		local deserializer = Dispatch.GetDeserializaer(eventId)
		if not deserializer then return end

		local cursor = 2
		local maxLen = buffer.len(buf)

		while cursor < maxLen do
			local newCursor, data = deserializer(cursor, buf)

			if not newCursor or newCursor <= cursor then
				warn("[Graphite] packet droped, reason: ".. tostring(data))
				return
			end

			cursor = newCursor

			Dispatch.CallListener(eventId, table.unpack(data))
		end
	end)
end

return Push