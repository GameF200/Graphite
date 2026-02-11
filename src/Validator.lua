--!optimize 2
--!strict
--!native

export type CompiledValidator = (...any) -> ()

local Select = select
local Error = error
local TypeOf = typeof

local checkType = function(value: any, Type: number): boolean
	if Type == 1 then return TypeOf(value) == "boolean" end

	if Type >= 2 and Type <= 13 then
		if TypeOf(value) ~= "number" then return false end

		local valueNumber = value :: number
		
		if Type == 2 then -- u8
			return valueNumber >= 0 and valueNumber <= 255
		elseif Type == 3 then -- u16
			return valueNumber >= 0 and valueNumber <= 65535
		elseif Type == 4 then -- u32
			return valueNumber >= 0 and valueNumber <= 4294967295
		elseif Type == 5 then -- i8
			return valueNumber >= -128 and valueNumber <= 127
		elseif Type == 6 then -- i16
			return valueNumber >= -32768 and valueNumber <= 32767
		elseif Type == 7 then -- u24
			return valueNumber >= 0 and valueNumber <= 16777215
		elseif Type == 8 then -- i24 
			return valueNumber >= -8388608 and valueNumber <= 8388607
		elseif Type == 9 then -- i32
			return valueNumber >= -2147483648 and valueNumber <= 2147483647
		elseif Type == 10 then -- f16
			return math.abs(valueNumber) <= 65520.0
		elseif Type == 11 then -- f24
			return math.abs(valueNumber) <= 4294959104.0
		elseif Type == 12 then -- f32
			return math.abs(valueNumber) <= 3.4028235e38
		elseif Type == 13 then 
			return true 
		end
	end

	if Type == 14 then
		return TypeOf(value) == "string"
	end

	if Type == 15 then return TypeOf(value) == "Vector3" end
	if Type == 16 then return TypeOf(value) == "Vector2" end
	if Type == 17 then return TypeOf(value) == "Vector2" end -- Vector2F16
	if Type == 18 then return TypeOf(value) == "Vector3" end -- Vector3F16
	if Type == 19 then return TypeOf(value) == "Vector2" end -- Vector2F24
	if Type == 20 then return TypeOf(value) == "Vector3" end -- Vector3F24
	if Type == 21 then return TypeOf(value) == "Vector2int16" end
	if Type == 22 then return TypeOf(value) == "Vector3int16" end

	-- CFrame
	if Type == 23 then return TypeOf(value) == "CFrame" end 
	if Type == 24 then return TypeOf(value) == "CFrame" end 
	if Type == 25 then return TypeOf(value) == "CFrame" end 
	if Type == 26 then return TypeOf(value) == "CFrame" end
	if Type == 27 then return TypeOf(value) == "CFrame" end 

	if Type == 28 then return TypeOf(value) == "Color3" end
	if Type == 29 then return TypeOf(value) == "NumberSequence" end
	if Type == 30 then return TypeOf(value) == "ColorSequence" end

	if Type == 31 then return TypeOf(value) == "UDim" end
	if Type == 32 then return TypeOf(value) == "UDim2" end
	if Type == 33 then return TypeOf(value) == "Rect" end
	if Type == 34 then return TypeOf(value) == "NumberRange" end
	if Type == 35 then return TypeOf(value) == "BrickColor" end

	if Type == 36 then
		return TypeOf(value) == "table"
	end

	return false
end

local typeNames = {
	[1] = "boolean",
	[2] = "number (u8)",
	[3] = "number (u16)",
	[4] = "number (u32)",
	[5] = "number (i8)",
	[6] = "number (i16)",
	[7] = "number (u24)",
	[8] = "number (i24)",
	[9] = "number (i32)",
	[10] = "number (f16)",
	[11] = "number (f24)",
	[12] = "number (f32)",
	[13] = "number (f64)",
	[14] = "string",
	[15] = "Vector3",
	[16] = "Vector2",
	[17] = "Vector2 (f16)",
	[18] = "Vector3 (f16)",
	[19] = "Vector2 (f24)",
	[20] = "Vector3 (f24)",
	[21] = "Vector2int16",
	[22] = "Vector3int16",
	[23] = "CFrame",
	[24] = "CFrame (f16, uint8)",
	[25] = "CFrame (f24, uint8)",
	[26] = "CFrame (f16, uint16)",
	[27] = "CFrame (f24, uint16)",
	[28] = "Color3",
	[29] = "NumberSequence",
	[30] = "ColorSequence",
	[31] = "UDim",
	[32] = "UDim2",
	[33] = "Rect",
	[34] = "NumberRange",
	[35] = "BrickColor",
	[36] = "table",
}

local typeName = function(Type: number): string
	return typeNames[Type] or "unknown"
end

local compile = function(expectedTypes: {number}, eventName: string): CompiledValidator
	local typeCount = #expectedTypes

	if typeCount == 0 then
		return function(...)
			if Select("#", ...) ~= 0 then
				Error(`[Graphite] '{eventName}' Expected 0 arguments`)
			end
		end
	end

	if typeCount == 1 then
		local expected = expectedTypes[1]
		return function(arg1)
			if not checkType(arg1, expected) then
				Error(`[Graphite] '{eventName}' Argument #1 expected {typeName(expected)}, got {TypeOf(arg1)}`)
			end
		end
	end

	if typeCount == 2 then
		local t1, t2 = expectedTypes[1], expectedTypes[2]
		return function(arg1, arg2)
			if not checkType(arg1, t1) then
				Error(`[Graphite] '{eventName}' Argument #1 expected {typeName(t1)}, got {TypeOf(arg1)}`)
			end
			if not checkType(arg2, t2) then
				Error(`[Graphite] '{eventName}' Argument #2 expected {typeName(t2)}, got {TypeOf(arg2)}`)
			end
		end
	end

	return function(...)
		local argCount = Select("#", ...)
		if argCount ~= typeCount then
			Error(`[Graphite] '{eventName}' Expected {typeCount} arguments, got {argCount}`)
		end

		for i = 1, typeCount do
			local arg = Select(i, ...)
			local expected = expectedTypes[i]

			if not checkType(arg, expected) then
				Error(`[Graphite] '{eventName}' Argument #{i} expected {typeName(expected)}, got {TypeOf(arg)}`)
			end
		end
	end
end

return {
	compile = compile,
	typeName = typeName,
	checkType = checkType,
}