-- RTT.lua
-- Graphite QNC RTT Probe
-- Client-only latency measurement (ping-pong)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()
local REMOTE_NAME = "__GRAPHITE_RTT__"

local Remote

if IS_SERVER then
	Remote = Instance.new("RemoteEvent")
	Remote.Name = REMOTE_NAME
	Remote.Parent = ReplicatedStorage
else
	Remote = ReplicatedStorage:WaitForChild(REMOTE_NAME)
end

local PING_INTERVAL = 30      
local EMA_ALPHA = 0.2

local lastRttEma = 0
local lastSendTime = 0
local totalTime = 0
local seq = 0

if IS_SERVER then
	Remote.OnServerEvent:Connect(function(player, sendTime, seqId)
		if typeof(sendTime) ~= "number" then return end
		if typeof(seqId) ~= "number" then return end

		Remote:FireClient(player, sendTime, seqId)
	end)
end

if not IS_SERVER then
	seq += 1
	lastSendTime = time()
	Remote:FireServer(lastSendTime, seq)
	
	Remote.OnClientEvent:Connect(function(sendTime, seqId)
		if typeof(sendTime) ~= "number" then return end
		if typeof(seqId) ~= "number" then return end

		local now = time()
		local rtt = now - sendTime

		if rtt <= 0 or rtt > 1 then return end

		if lastRttEma == 0 then
			lastRttEma = rtt
		else
			lastRttEma = lastRttEma * (1 - EMA_ALPHA) + rtt * EMA_ALPHA
		end
	end)
	
	RunService.Heartbeat:Connect(function(dt)
		totalTime += dt
		if totalTime >= PING_INTERVAL then
			totalTime = 0
			seq += 1
			lastSendTime = time()
			Remote:FireServer(lastSendTime, seq)
		end
	end)
end

return function()
	return lastRttEma
end