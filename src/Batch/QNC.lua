--[[
	QNC - Queue Network Control
	
	Congestion control for Batch module
	
	@author super_sonic
--]]

local GetRtt = require("./RTT")

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

local baseRTT = math.huge
   
local maxDelay = 0.1    

local target = 0.005
local CoDelTarget = 0.005
local CoDelInterval = 0.005

local firstAboveTime = 0
local dropCount = 0
local nextDropTime = 0

local dropPackets = 0

local pidBoost = 0
local pidBoostMax = 3.0

local rttEMA = 0

local Kp = 8
local Ki = 2
local Kd = 4      

local integral = 0
local lastDelay = 0

local budgetMin = 4
local budgetMax = 100

local sliceMin = 25
local sliceMax = 10000

local budget = 10
local sliceSize = 60

local panic = false
local arrivalRateEMA = 0
local drainRateEMA = 0
local lastDeltaCount = 0

local highCount = 500
local lowCount = 50
local spikeThreshold = 1000
local sliceDefault = 60
local lastArrivalRate = 0

local needDrop = false
local dropPackets = 0

local function UpdateFromRTT(rtt: number)
	if rtt <= 0 then return end
	if rtt > 0.5 then return end 

	baseRTT = math.min(baseRTT, rtt)

	if rttEMA == 0 then
		rttEMA = rtt
	else
		rttEMA = rttEMA * 0.8 + rtt * 0.2
	end

	local targetTime = math.clamp(baseRTT * 1.1 + 0.001, 0.003, 0.05)
	local codelTarget = targetTime
	local codelInterval = math.clamp(baseRTT * 0.005, 0.01, 0.05)
	return targetTime, codelTarget, codelInterval
end

return function(
	Count: number,
	DeltaCount: number,
	TotalTime: number,
	DeltaTime: number
)
	needDrop = false
	dropPackets = 0
	
	if not IS_SERVER then
		local CurrentRTT = GetRtt()
		local newTarget, newCoDelTarget, newCoDelInterval = UpdateFromRTT(CurrentRTT)

		if newTarget then
			target = target * 0.8 + newTarget * 0.2
			CoDelTarget = CoDelTarget * 0.8 + newCoDelTarget * 0.2
			CoDelInterval = CoDelInterval * 0.5 + newCoDelInterval * 0.1
		end
	end

	print(TotalTime)

	--print(" CoDelTarget ".. CoDelTarget .. " CoDelInterval ".. CoDelInterval.. " Target(PID) ".. target)
	
	-- PID Part
	local dt = math.max(DeltaTime, 1e-3)
	local delay = TotalTime

	local arrivalRate = math.max(DeltaCount, 0) / dt
	local drainRate = math.max(-DeltaCount, 0) / dt
	
	arrivalRateEMA = arrivalRateEMA * 0.8 + arrivalRate * 0.2
	drainRateEMA   = drainRateEMA   * 0.8 + drainRate   * 0.2
	
	arrivalRateEMA = math.max(arrivalRateEMA, 0)
	drainRateEMA = math.max(drainRateEMA, 1e-3)

	local accel = (arrivalRate - lastArrivalRate) / dt
	lastArrivalRate = arrivalRate
	
	local burst =
		arrivalRateEMA > drainRateEMA * 1.3 or
		accel > spikeThreshold

	local congestion =
		delay > maxDelay or
		(Count > highCount and DeltaCount > 0)

	local error = target - delay
	local dError = (delay - lastDelay) / dt

	integral = math.clamp(integral + error * dt, -5, 5)

	local control = Kp * error + Ki * integral - Kd * dError
	budget = budget + control

	if Count < lowCount and arrivalRateEMA < drainRateEMA and delay < target then
		burst = false
		panic = false
	end
	
	if not burst and not congestion then
		sliceSize = sliceSize + (sliceDefault - sliceSize) * 0.2
	end
	
	if burst then
		local rateRatio = arrivalRateEMA / math.max(drainRateEMA, 1e-3)
		local factor = math.clamp(1 + (rateRatio - 1) * 0.3, 1, 1.5)

		sliceSize = math.min(sliceMax, sliceSize * factor)
	end

	if congestion then
		local delayFactor = math.min(1.5 ^ (delay / maxDelay), 5)
		local queueFactor = math.min(Count / highCount, 2)

		local factor = delayFactor * queueFactor

		budget = math.max(budgetMin, budget / factor)
		integral = 0
	end

	if delay < target and DeltaCount <= 0 then
		integral = integral * 0.9
	end

	--print("DEBUG QNC".. budget, sliceSize)
	budget = math.clamp(budget, budgetMin, budgetMax)
	sliceSize = math.clamp(sliceSize, sliceMin, sliceMax)

	lastDelay = delay
	
	local now = time()
	
	-- CoDel part
	if delay > CoDelTarget then
		if firstAboveTime == 0 then
			firstAboveTime = now + CoDelInterval
			pidBoost = 0
		end
		
		pidBoost = math.clamp(pidBoost + 0.1, 1, pidBoostMax)
		budget = math.min(budgetMax, budget * (1 + pidBoost * 0.2))
		sliceSize = math.min(sliceMax, sliceSize * (1 + pidBoost * 0.2))

		if now >= firstAboveTime then
			if now >= nextDropTime then
				dropCount += 1
				nextDropTime = now + CoDelInterval / math.sqrt(dropCount)

				needDrop = true

				local overload = (delay - CoDelTarget) / CoDelTarget
				dropPackets = math.clamp(
					math.floor(overload * (2.25 ^ dropCount)),
					1,
					math.floor(Count * 0.25) -- 25% of the queue is max
				)
			end
		end
	else
		firstAboveTime = 0
		dropCount = 0
		nextDropTime = 0
		pidBoost = pidBoost * 0.8
		needDrop = false
		dropPackets = 0
	end

	return math.floor(budget), math.floor(sliceSize), needDrop, dropPackets
end