--[[
	  -------                                 ---        ---   ---               
	 ---   ---                                ---              ---               
	---        --------  -------   ---------  ---------  ------------  --------  
	---  ----- ----           ---  ---    --- ---    --- ---   ---    ---    --- 
	---     -- ---       --------  ---    --- ---    --- ---   ---    ---------- 
	 ---  ---- ---      ---   ---  ----   --- ---    --- ---   ---    ---        
	  -------- ---       --------- ---------  ---    --- ---    -----  --------  
	                               ---                                           
	                               ---                                           
    ????????
    
    Graphite - High Perfomance | Type-Safe | Easy | Network library
    
    @version 0.1.1
    @author super_sonic
    @license Apache 2.0
    

]]


--!strict
--!optimize 2

local Validator       = require("@self/Validator")
local BinBuffer       = require("@self/BinBuffer")
local Buffers         = require("@self/Buffers")
local Serialization   = require("@self/Serialization")
local Batch           = require("@self/Batch")
local Deserialization = require("@self/DeSerialization")
local Dispatch        = require("@self/Dispatch")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local IsServer = RunService:IsServer()

type Fn = () -> ()

type BuildedAPI<T...> = {
	Fire: (T...) -> (),
	FireClient: (Player: Player, T...) -> (),

	OnServerEvent: (handler: (Player: Player, T...) -> ()) -> Fn, 
	OnClientEvent: (handler: (T...) -> ()) -> Fn
}

type StreamAPI<T...> = {
	type: (T...) -> StreamAPI<T...>,
	build: () -> BuildedAPI<T...>,
	droppable: () -> StreamAPI<T...>
}

local TypeOf = typeof

-- crc16/Modbus
local crc16 = function(str: string)
	local crc = 0xFFFF

	for i = 1, #str do
		crc = bit32.bxor(crc, string.byte(str, i))

		for _ = 1, 8 do
			if bit32.band(crc, 1) ~= 0 then
				crc = bit32.bxor(bit32.rshift(crc, 1), 0xA001)
			else
				crc = bit32.rshift(crc, 1)
			end
		end
	end

	return bit32.band(crc, 0xFFFF)
end

local Constructor = function<T...>(name: string): StreamAPI<T...>
	
	local validator: Validator.CompiledValidator
	local types: {number} = {}
	local droppable = false
	
	local self: StreamAPI<T...>
	self = {
		type = function(...): StreamAPI<T...>
			validator = Validator.compile({...}, name)
			types = {...}			
			
			return self
		end,
		
		droppable = function(): StreamAPI<T...>
			
			droppable = true
			return self
		end,
	
		build = function(): BuildedAPI<T...>
			if not validator then
				error("[Grpahite] Validator is not defined for event: " .. name .. "use .type(TYPE_ENUM) before building")
			end
			
			local EventId = crc16(name)
			
			local Serialize = Serialization(types)
			local Deserialize = Deserialization(types)			

			Dispatch.AddDeserializer(EventId, Deserialize)
			Dispatch.AddValidator(EventId, validator)
			
			return {
				Fire = function(...)
					validator(...)
					local buf = Serialize(...)
					
					Batch(EventId, buf, nil, droppable)
				end,
				
				FireClient = function(Player: Player, ...)
					validator(...)
					local buf = Serialize(...)
					
					Batch(EventId, buf, Player, droppable)
				end,
				
				OnServerEvent = function(fn: (Player, T...) -> ()): Fn
					Dispatch.AddListener(EventId, fn)
					return function()
						Dispatch.RemoveListener(EventId)
					end
				end,			
				OnClientEvent = function(fn: (T...) -> ()): Fn
					Dispatch.AddListener(EventId, fn)
					return function()
						Dispatch.RemoveListener(EventId)
					end
				end,
			} :: BuildedAPI<T...>
		end,
	}
	
	return self
end

return {
	Event = Constructor,
	
	Bool            = (1 :: any) :: boolean,
	Int8            = (5 :: any) :: number,
	Int16           = (6 :: any) :: number,
	Int32           = (9 :: any) :: number,
	Uint8           = (2 :: any) :: number,
	Uint16          = (3 :: any) :: number,
	Uint32          = (4 :: any) :: number,
	Float16         = (10 :: any) :: number,
	Float24         = (11 :: any) :: number,
	Float32         = (12 :: any) :: number,
	Float64         = (13 :: any) :: number,
	String16        = (14 :: any) :: string,
	Vector2         = (16 :: any) :: Vector2,
	Vector3         = (15 :: any) :: Vector3,
	Color3          = (28 :: any) :: Color3,
	UDim            = (31 :: any) :: UDim,
	UDim2           = (32 :: any) :: UDim2,
	CFrameF32       = (23 :: any) :: CFrame,
	Rect            = (33 :: any) :: Rect,
	NumberRange     = (34 :: any) :: NumberRange,
	NumberSequence  = (29 :: any) :: NumberSequence,
	ColorSequence   = (30 :: any) :: ColorSequence,
	BrickColor      = (35 :: any) :: BrickColor,
	Table           = (36 :: any) :: {},
	Vector2Float16  = (17 :: any) :: Vector2,
	Vector3Float16  = (18 :: any) :: Vector3,
	Vector2Float24  = (19 :: any) :: Vector2,
	Vector3Float24  = (20 :: any) :: Vector3,
	Vector2Int16    = (21 :: any) :: Vector2,
	Vector3Int16    = (22 :: any) :: Vector3,
	CFrameF16U8     = (24 :: any) :: CFrame,
	CFrameF24U8     = (25 :: any) :: CFrame,
	CFrameF16U16    = (26 :: any) :: CFrame,
	CFrameF24U16    = (27 :: any) :: CFrame,
	Int24           = (8 :: any) :: number,
	Uint24          = (7 :: any) :: number,
	

}