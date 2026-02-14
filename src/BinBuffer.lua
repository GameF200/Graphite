--!strict
--!optimize 2

--[[
    .______    __  .__   __. .______    __    __   _______  _______  _______ .______      
    |   _  \  |  | |  \ |  | |   _  \  |  |  |  | |   ____||   ____||   ____||   _  \     
    |  |_)  | |  | |   \|  | |  |_)  | |  |  |  | |  |__   |  |__   |  |__   |  |_)  |    
    |   _  <  |  | |  . `  | |   _  <  |  |  |  | |   __|  |   __|  |   __|  |      /     
    |  |_)  | |  | |  |\   | |  |_)  | |  `--'  | |  |     |  |     |  |____ |  |\  \----.
    |______/  |__| |__| \__| |______/   \______/  |__|     |__|     |_______|| _| `._____|
          
    BinBuffer - advanced buffering module
    
    @author super_sonic
    @version 1.5.2 Modifided for Graphite Project
    @license MIT
    
    @changelog:
        - fixed read bug for i24/u24
        - added "truncate" function for buffer
        - changed read functions to accept raw buffer and return bytes read
        
    @what next
        - optimized i24/u24 writing
        - maybe more types
]]

local MEGABYTE = 1048576
local MAX_REASONABLE_SIZE = 67108864
local CFRAME_SCALE = 10430.219195527361
local CFRAME_INV_SCALE = 1 / CFRAME_SCALE
local CFRAME_SCALE_U8 = 40.58451048843331
local CFRAME_INV_SCALE_U8 = 1 / CFRAME_SCALE_U8
local UDIM_SCALE = 1000
local UDIM_INV_SCALE = 0.001
local FLOAT_TO_BYTE_SCALE = 255
local FLOAT_FROM_BYTE_SCALE = 0.00392156862745098 -- equivalent to 1/255
local U8_MAX = 255
local U16_MAX = 65535
local U32_MAX = 4294967295
local I8_MIN = -128
local I32_MIN = -2147483648
local F16_MAX = 65520.0
local F24_MAX = 4294959104.0
local F32_MAX = 3.4028235e38
local U24_MAX = 16777215

local math_max = math.max
local math_min = math.min

local math_floor          = math.floor
local math_abs            = math.abs
local math_frexp          = math.frexp
local table_insert        = table.insert
local table_clear         = table.clear
local string_len          = string.len

local buffer_create       = buffer.create
local buffer_copy         = buffer.copy
local buffer_len          = buffer.len
local buffer_writeu8      = buffer.writeu8
local buffer_writeu16     = buffer.writeu16
local buffer_writeu32     = buffer.writeu32
local buffer_writei8      = buffer.writei8
local buffer_writei16     = buffer.writei16
local buffer_writei32     = buffer.writei32
local buffer_writef32     = buffer.writef32
local buffer_writef64     = buffer.writef64
local buffer_writestring  = buffer.writestring
local buffer_writebits    = buffer.writebits

local buffer_readu8       = buffer.readu8
local buffer_readu16      = buffer.readu16
local buffer_readu32      = buffer.readu32
local buffer_readi8       = buffer.readi8
local buffer_readi16      = buffer.readi16
local buffer_readi32      = buffer.readi32
local buffer_readf32      = buffer.readf32
local buffer_readf64      = buffer.readf64
local buffer_readstring   = buffer.readstring
local buffer_readbits     = buffer.readbits

export type Buffer = {
	_buffer: buffer,
	_size: number,
	_destroyed: boolean,
	_writeOffset: number,
	_readOffset: number,
}

-- Table dispatchers
local writers = {} :: {[any]: any}
local readers = {} :: {[any]: any}

local function Alloc(buf: Buffer, requiredBytes: number): boolean
	local currentBufferSize = buffer_len(buf._buffer)
	local neededSpace = buf._writeOffset + requiredBytes

	if neededSpace > currentBufferSize then
		local newSize = currentBufferSize
		while newSize < neededSpace do
			newSize = newSize * 3
		end

		local newBuffer = buffer_create(newSize)
		buffer_copy(newBuffer, 0, buf._buffer, 0, buf._writeOffset)
		buf._buffer = newBuffer
		buf._size = newSize
	end
	return true
end

local FP_NAN = 0x7C01
local function WriteF16Data(buf: buffer, offset: number, value: number)
	local bitOffset = offset * 8
	if value == 0 then
		buffer_writebits(buf, bitOffset, 16, 0)
	elseif value ~= value then
		buffer_writebits(buf, bitOffset, 16, FP_NAN)
	else
		local sign = 0
		if value < 0 then 
			sign = 1 
			value = -value 
		end
		local mantissa, exponent = math_frexp(value)
		buffer_writebits(buf, bitOffset, 10, mantissa * 2048 - 1023.5)
		buffer_writebits(buf, bitOffset + 10, 5, exponent + 14)
		buffer_writebits(buf, bitOffset + 15, 1, sign)
	end
end

local function WriteU24Data(buf: buffer, offset: number, value: number)
	value = bit32.band(value, 0xFFFFFF)

	local low16 = bit32.band(value, 0xFFFF)       
	local high8 = bit32.rshift(value, 16)          

	buffer_writeu16(buf, offset, low16)             
	buffer_writeu8(buf, offset + 2, high8)
end


local function WriteI24Data(buf: buffer, offset: number, value: number)
	local unsignedValue
	if value < 0 then
		unsignedValue = bit32.lshift(1, 24) + value  
	else
		unsignedValue = value
	end

	unsignedValue = bit32.band(unsignedValue, 0xFFFFFF)

	local low16 = bit32.band(unsignedValue, 0xFFFF)
	local high8 = bit32.rshift(unsignedValue, 16)

	buffer_writeu16(buf, offset, low16)
	buffer_writeu8(buf, offset + 2, high8)
end

local function ReadF16(buf: buffer, offset: number): number
	local bitOffset = offset * 8
	local mantissa = buffer_readbits(buf, bitOffset, 10)
	local exponent = buffer_readbits(buf, bitOffset + 10, 5)
	local sign = buffer_readbits(buf, bitOffset + 15, 1)

	if exponent == 0 and mantissa == 0 then
		return 0
	end
	if exponent == 31 then
		return 0/0
	end

	local value = math.ldexp(mantissa / 1024 + 1, exponent - 15)
	return sign == 0 and value or -value
end

local function ReadF24(buf: buffer, offset: number): number
	local bitOffset = offset * 8
	local mantissa = buffer_readbits(buf, bitOffset, 17)
	local exponent = buffer_readbits(buf, bitOffset + 17, 6)
	local sign = buffer_readbits(buf, bitOffset + 23, 1)

	if exponent == 0 and mantissa == 0 then
		return 0
	end
	if exponent == 63 then
		return 0/0
	end

	local value = math.ldexp(mantissa / 131072 + 1, exponent - 31)
	return sign == 0 and value or -value
end

local function ReadU24(buf: buffer, offset: number): number
	local low16 = buffer_readu16(buf, offset)   
	local high8 = buffer_readu8(buf, offset + 2)  

	return bit32.bor(low16, bit32.lshift(high8, 16))
end


local function ReadI24(buf: buffer, offset: number): number
	local low16 = buffer_readu16(buf, offset)
	local high8 = buffer_readu8(buf, offset + 2)

	local unsignedValue = bit32.bor(low16, bit32.lshift(high8, 16))

	if unsignedValue >= bit32.lshift(1, 23) then
		return unsignedValue - bit32.lshift(1, 24)
	else
		return unsignedValue
	end
end

local function WriteF24Data(buf: buffer, offset: number, value: number)
	local bitOffset = offset * 8
	if value == 0 then
		buffer_writebits(buf, bitOffset, 24, 0)
	elseif value ~= value then
		buffer_writebits(buf, bitOffset, 24, 8323073)
	else
		local sign = 0
		if value < 0 then 
			sign = 1 
			value = -value 
		end
		local mantissa, exponent = math_frexp(value)
		buffer_writebits(buf, bitOffset, 17, mantissa * 262144 - 131071.5)
		buffer_writebits(buf, bitOffset + 17, 6, exponent + 30)
		buffer_writebits(buf, bitOffset + 23, 1, sign)
	end
end

-- simple help functions
local function bytes(bytes: number): number
	return bytes
end

local function kilobytes(kilobytes: number): number
	return kilobytes * 1024
end

local function megabytes(megabytes: number): number
	return megabytes * 1048576
end

-- creates a new buffer
local function create(): Buffer
	local size = 4

	return {
		_buffer = buffer_create(size),
		_destroyed = false,
		_size = size,
		_writeOffset = 0,
		_readOffset = 0,
	} :: Buffer
end

local function with_capacity(capacity: number): Buffer
	if capacity <= 0 then
		error(`[BinBuffer] invalid constructor capacity`)
	end

	return {
		_buffer = buffer_create(capacity),
		_destroyed = false,
		_size = capacity,
		_writeOffset = 0,
		_readOffset = 0,
	} :: Buffer
end

-- clears buffer but not destroys
local function clear(buf: Buffer)
	buf._writeOffset = 0
	buf._readOffset = 0

	local originalSize = buf._size
	buf._buffer = buffer_create(originalSize)
end

-- fully destroys buffer
local function destroy(buf: Buffer)
	buf._destroyed = true
	buf._buffer = nil
	buf._writeOffset = 0
	buf._readOffset = 0
	buf._size = 0
end

-- resets read position
local function reset_read(buf: Buffer)
	buf._readOffset = 0
end

-- Writers table dispatcher
writers[1] = function(buf: Buffer, value: boolean): boolean
	if buf._writeOffset + 1 > buffer_len(buf._buffer) then
		if not Alloc(buf, 1) then return false end
	end
	buffer_writeu8(buf._buffer, buf._writeOffset, value and 1 or 0)
	buf._writeOffset += 1
	return true
end

writers[2] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 1 > buffer_len(buf._buffer) then
		if not Alloc(buf, 1) then return false end
	end
	buffer_writeu8(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 1
	return true
end

writers[3] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 2 > buffer_len(buf._buffer) then
		if not Alloc(buf, 2) then return false end
	end
	buffer_writeu16(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 2
	return true
end

writers[4] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end
	buffer_writeu32(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 4
	return true
end

writers[5] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 1 > buffer_len(buf._buffer) then
		if not Alloc(buf, 1) then return false end
	end
	buffer_writei8(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 1
	return true
end

writers[6] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 2 > buffer_len(buf._buffer) then
		if not Alloc(buf, 2) then return false end
	end
	buffer_writei16(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 2
	return true
end

writers[7] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 3 > buffer_len(buf._buffer) then
		if not Alloc(buf, 3) then return false end
	end
	WriteU24Data(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 3
	return true
end

writers[8] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 3 > buffer_len(buf._buffer) then
		if not Alloc(buf, 3) then return false end
	end
	WriteI24Data(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 3
	return true
end

writers[9] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end
	buffer_writei32(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 4
	return true
end

writers[10] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 2 > buffer_len(buf._buffer) then
		if not Alloc(buf, 2) then return false end
	end
	WriteF16Data(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 2
	return true
end

writers[11] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 3 > buffer_len(buf._buffer) then
		if not Alloc(buf, 3) then return false end
	end
	WriteF24Data(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 3
	return true
end

writers[12] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end
	buffer_writef32(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 4
	return true
end

writers[13] = function(buf: Buffer, value: number): boolean
	if buf._writeOffset + 8 > buffer_len(buf._buffer) then
		if not Alloc(buf, 8) then return false end
	end
	buffer_writef64(buf._buffer, buf._writeOffset, value)
	buf._writeOffset += 8
	return true
end

writers[14] = function(buf: Buffer, value: string): boolean
	local len = string_len(value)
	local requiredBytes = 2 + len
	if buf._writeOffset + requiredBytes > buffer_len(buf._buffer) then
		if not Alloc(buf, requiredBytes) then return false end
	end
	buffer_writeu16(buf._buffer, buf._writeOffset, len)
	buffer_writestring(buf._buffer, buf._writeOffset + 2, value)
	buf._writeOffset += requiredBytes
	return true
end

writers[15] = function(buf: Buffer, value: Vector3): boolean
	if buf._writeOffset + 12 > buffer_len(buf._buffer) then
		if not Alloc(buf, 12) then return false end
	end

	buffer_writef32(buf._buffer, buf._writeOffset, value.X)
	buffer_writef32(buf._buffer, buf._writeOffset + 4, value.Y)
	buffer_writef32(buf._buffer, buf._writeOffset + 8, value.Z)
	buf._writeOffset += 12
	return true
end

writers[16] = function(buf: Buffer, value: Vector2): boolean
	if buf._writeOffset + 8 > buffer_len(buf._buffer) then
		if not Alloc(buf, 8) then return false end
	end

	buffer_writef32(buf._buffer, buf._writeOffset, value.X)
	buffer_writef32(buf._buffer, buf._writeOffset + 4, value.Y)
	buf._writeOffset += 8
	return true
end

-- CUSTOM VECTOR/CFRAME TYPES
writers[17] = function(buf: Buffer, value: Vector2): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end

	WriteF16Data(buf._buffer, buf._writeOffset, value.X)
	WriteF16Data(buf._buffer, buf._writeOffset + 2, value.Y)
	buf._writeOffset += 4
	return true
end

writers[18] = function(buf: Buffer, value: Vector3): boolean
	if buf._writeOffset + 6 > buffer_len(buf._buffer) then
		if not Alloc(buf, 6) then return false end
	end

	WriteF16Data(buf._buffer, buf._writeOffset, value.X)
	WriteF16Data(buf._buffer, buf._writeOffset + 2, value.Y)
	WriteF16Data(buf._buffer, buf._writeOffset + 4, value.Z)
	buf._writeOffset += 6
	return true
end

writers[19] = function(buf: Buffer, value: Vector2): boolean
	if buf._writeOffset + 6 > buffer_len(buf._buffer) then
		if not Alloc(buf, 6) then return false end
	end

	WriteF24Data(buf._buffer, buf._writeOffset, value.X)
	WriteF24Data(buf._buffer, buf._writeOffset + 3, value.Y)
	buf._writeOffset += 6
	return true
end

writers[20] = function(buf: Buffer, value: Vector3): boolean
	if buf._writeOffset + 9 > buffer_len(buf._buffer) then
		if not Alloc(buf, 9) then return false end
	end

	WriteF24Data(buf._buffer, buf._writeOffset, value.X)
	WriteF24Data(buf._buffer, buf._writeOffset + 3, value.Y)
	WriteF24Data(buf._buffer, buf._writeOffset + 6, value.Z)
	buf._writeOffset += 9
	return true
end

writers[21] = function(buf: Buffer, value: Vector2int16): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end

	buffer_writei16(buf._buffer, buf._writeOffset, value.X)
	buffer_writei16(buf._buffer, buf._writeOffset + 2, value.Y)
	buf._writeOffset += 4
	return true
end

writers[22] = function(buf: Buffer, value: Vector3int16): boolean
	if buf._destroyed then return false end
	if buf._writeOffset + 6 > buffer_len(buf._buffer) then
		if not Alloc(buf, 6) then return false end
	end

	buffer_writei16(buf._buffer, buf._writeOffset, value.X)
	buffer_writei16(buf._buffer, buf._writeOffset + 2, value.Y)
	buffer_writei16(buf._buffer, buf._writeOffset + 4, value.Z)
	buf._writeOffset += 6
	return true
end

writers[23] = function(buf: Buffer, value: CFrame): boolean
	if buf._writeOffset + 18 > buffer_len(buf._buffer) then
		if not Alloc(buf, 18) then return false end
	end

	local rx, ry, rz = value:ToEulerAnglesXYZ()

	buffer_writeu16(buf._buffer, buf._writeOffset, rx * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 2, ry * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 4, rz * CFRAME_SCALE + 0.5)
	buffer_writef32(buf._buffer, buf._writeOffset + 6, value.X)
	buffer_writef32(buf._buffer, buf._writeOffset + 10, value.Y)
	buffer_writef32(buf._buffer, buf._writeOffset + 14, value.Z)
	buf._writeOffset += 18

	return true
end

writers[24] = function(buf: Buffer, value: CFrame): boolean
	if buf._writeOffset + 9 > buffer_len(buf._buffer) then
		if not Alloc(buf, 9) then return false end
	end

	local rx, ry, rz = value:ToEulerAnglesXYZ()

	buffer_writeu8(buf._buffer, buf._writeOffset, rx * CFRAME_SCALE_U8 + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 1, ry * CFRAME_SCALE_U8 + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 2, rz * CFRAME_SCALE_U8 + 0.5)
	WriteF16Data(buf._buffer, buf._writeOffset + 3, value.X)
	WriteF16Data(buf._buffer, buf._writeOffset + 5, value.Y)
	WriteF16Data(buf._buffer, buf._writeOffset + 7, value.Z)
	buf._writeOffset += 9

	return true
end

writers[25] = function(buf: Buffer, value: CFrame): boolean
	if buf._writeOffset + 12 > buffer_len(buf._buffer) then
		if not Alloc(buf, 12) then return false end
	end

	local rx, ry, rz = value:ToEulerAnglesXYZ()

	buffer_writeu8(buf._buffer, buf._writeOffset, rx * CFRAME_SCALE_U8 + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 1, ry * CFRAME_SCALE_U8 + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 2, rz * CFRAME_SCALE_U8 + 0.5)
	WriteF24Data(buf._buffer, buf._writeOffset + 3, value.X)
	WriteF24Data(buf._buffer, buf._writeOffset + 6, value.Y)
	WriteF24Data(buf._buffer, buf._writeOffset + 9, value.Z)
	buf._writeOffset += 12

	return true
end

writers[26] = function(buf: Buffer, value: CFrame): boolean
	if buf._writeOffset + 12 > buffer_len(buf._buffer) then
		if not Alloc(buf, 12) then return false end
	end

	local rx, ry, rz = value:ToEulerAnglesXYZ()

	buffer_writeu16(buf._buffer, buf._writeOffset, rx * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 2, ry * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 4, rz * CFRAME_SCALE + 0.5)
	WriteF16Data(buf._buffer, buf._writeOffset + 6, value.X)
	WriteF16Data(buf._buffer, buf._writeOffset + 8, value.Y)
	WriteF16Data(buf._buffer, buf._writeOffset + 10, value.Z)
	buf._writeOffset += 12

	return true
end

writers[27] = function(buf: Buffer, value: CFrame): boolean
	if buf._writeOffset + 15 > buffer_len(buf._buffer) then
		if not Alloc(buf, 15) then return false end
	end

	local rx, ry, rz = value:ToEulerAnglesXYZ()

	buffer_writeu16(buf._buffer, buf._writeOffset, rx * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 2, ry * CFRAME_SCALE + 0.5)
	buffer_writeu16(buf._buffer, buf._writeOffset + 4, rz * CFRAME_SCALE + 0.5)
	WriteF24Data(buf._buffer, buf._writeOffset + 6, value.X)
	WriteF24Data(buf._buffer, buf._writeOffset + 9, value.Y)
	WriteF24Data(buf._buffer, buf._writeOffset + 12, value.Z)
	buf._writeOffset += 15

	return true
end

writers[28] = function(buf: Buffer, value: Color3): boolean
	if buf._writeOffset + 3 > buffer_len(buf._buffer) then
		if not Alloc(buf, 3) then return false end
	end

	buffer_writeu8(buf._buffer, buf._writeOffset, value.R * FLOAT_TO_BYTE_SCALE + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 1, value.G * FLOAT_TO_BYTE_SCALE + 0.5)
	buffer_writeu8(buf._buffer, buf._writeOffset + 2, value.B * FLOAT_TO_BYTE_SCALE + 0.5)
	buf._writeOffset += 3
	return true
end

writers[29] = function(buf: Buffer, value: NumberSequence): boolean
	local len = #value.Keypoints
	local requiredBytes = 1 + len * 3

	if buf._writeOffset + requiredBytes > buffer_len(buf._buffer) then
		if not Alloc(buf, requiredBytes) then return false end
	end

	buffer_writeu8(buf._buffer, buf._writeOffset, len)

	local offset = buf._writeOffset + 1
	for _, keypoint in ipairs(value.Keypoints) do
		buffer_writeu8(buf._buffer, offset, keypoint.Time * FLOAT_TO_BYTE_SCALE + 0.5)
		buffer_writeu8(buf._buffer, offset + 1, keypoint.Value * FLOAT_TO_BYTE_SCALE + 0.5)
		buffer_writeu8(buf._buffer, offset + 2, keypoint.Envelope * FLOAT_TO_BYTE_SCALE + 0.5)
		offset += 3
	end

	buf._writeOffset += requiredBytes
	return true
end

writers[30] = function(buf: Buffer, value: ColorSequence): boolean
	local len = #value.Keypoints
	local requiredBytes = 1 + len * 4

	if buf._writeOffset + requiredBytes > buffer_len(buf._buffer) then
		if not Alloc(buf, requiredBytes) then return false end
	end

	buffer_writeu8(buf._buffer, buf._writeOffset, len)

	local offset = buf._writeOffset + 1
	for _, keypoint in ipairs(value.Keypoints) do
		buffer_writeu8(buf._buffer, offset, keypoint.Time * FLOAT_TO_BYTE_SCALE + 0.5)
		buffer_writeu8(buf._buffer, offset + 1, keypoint.Value.R * FLOAT_TO_BYTE_SCALE + 0.5)
		buffer_writeu8(buf._buffer, offset + 2, keypoint.Value.G * FLOAT_TO_BYTE_SCALE + 0.5)
		buffer_writeu8(buf._buffer, offset + 3, keypoint.Value.B * FLOAT_TO_BYTE_SCALE + 0.5)
		offset += 4
	end

	buf._writeOffset += requiredBytes
	return true
end

writers[31] = function(buf: Buffer, value: UDim): boolean
	if buf._writeOffset + 4 > buffer_len(buf._buffer) then
		if not Alloc(buf, 4) then return false end
	end

	buffer_writei16(buf._buffer, buf._writeOffset, value.Scale * UDIM_SCALE)
	buffer_writei16(buf._buffer, buf._writeOffset + 2, value.Offset)
	buf._writeOffset += 4
	return true
end

writers[32] = function(buf: Buffer, value: UDim2): boolean
	if buf._writeOffset + 8 > buffer_len(buf._buffer) then
		if not Alloc(buf, 8) then return false end
	end

	buffer_writei16(buf._buffer, buf._writeOffset, value.X.Scale * UDIM_SCALE)
	buffer_writei16(buf._buffer, buf._writeOffset + 2, value.X.Offset)
	buffer_writei16(buf._buffer, buf._writeOffset + 4, value.Y.Scale * UDIM_SCALE)
	buffer_writei16(buf._buffer, buf._writeOffset + 6, value.Y.Offset)
	buf._writeOffset += 8
	return true
end

writers[33] = function(buf: Buffer, value: Rect): boolean
	if buf._writeOffset + 16 > buffer_len(buf._buffer) then
		if not Alloc(buf, 16) then return false end
	end

	buffer_writef32(buf._buffer, buf._writeOffset, value.Min.X)
	buffer_writef32(buf._buffer, buf._writeOffset + 4, value.Min.Y)
	buffer_writef32(buf._buffer, buf._writeOffset + 8, value.Max.X)
	buffer_writef32(buf._buffer, buf._writeOffset + 12, value.Max.Y)
	buf._writeOffset += 16
	return true
end

writers[34] = function(buf: Buffer, value: NumberRange): boolean
	if buf._writeOffset + 8 > buffer_len(buf._buffer) then
		if not Alloc(buf, 8) then return false end
	end

	buffer_writef32(buf._buffer, buf._writeOffset, value.Min)
	buffer_writef32(buf._buffer, buf._writeOffset + 4, value.Max)
	buf._writeOffset += 8
	return true
end

writers[35] = function(buf: Buffer, value: BrickColor): boolean
	if buf._writeOffset + 2 > buffer_len(buf._buffer) then
		if not Alloc(buf, 2) then return false end
	end

	buffer_writeu16(buf._buffer, buf._writeOffset, value.Number)
	buf._writeOffset += 2
	return true
end

local ToWriter = {
	["Vector2"] = writers[19],
	["Vector3"] = writers[20],
	["CFrame"] = writers[25],
	["UDim"] = writers[31],
	["UDim2"] = writers[32],
	["Rect"] = writers[33],
	["NumberRange"] = writers[34],
	["BrickColor"] = writers[35],
	["Color3"] = writers[28],
	["string"] = writers[14],
	["number"] = writers[9],
	["boolean"] = writers[1],
	["NumberSequence"] = writers[29],
	["Vector2int16"] = writers[21],
	["Vector3int16"] = writers[22],
	["ColorSequence"] = writers[30],	
}

local TypeToId = {
	["boolean"] = 1,
	["number"] = 9,
	["string"] = 14,
	["Vector2"] = 19,
	["Vector3"] = 20,
	["Vector2int16"] = 21,
	["Vector3int16"] = 22,
	["CFrame"] = 25,
	["Color3"] = 28,
	["NumberSequence"] = 29,
	["ColorSequence"] = 30,
	["UDim"] = 31,
	["UDim2"] = 32,
	["Rect"] = 33,
	["NumberRange"] = 34,
	["BrickColor"] = 35,
	["table"] = 36,
}

local TypeOf = typeof

writers[36] = function(buf: Buffer, tbl: {[any]: any}): boolean
	for key, value in pairs(tbl) do
		local keyType = TypeOf(key)
		local keyTypeId = TypeToId[keyType]
		if not keyTypeId then error("Unsupported key type: "..keyType) end

		writers[2](buf, keyTypeId)
		ToWriter[keyType](buf, key)

		local valueType = TypeOf(value)
		local valueTypeId = TypeToId[valueType]
		if not valueTypeId then error("Unsupported value type: "..valueType) end
		
		
		writers[2](buf, valueTypeId)
		ToWriter[valueType](buf, value)
	end

	writers[2](buf, 0) -- terminator
	return true
end

writers[37] = function(buf: Buffer, value: string): boolean
	local len = string_len(value)
	local requiredBytes = 1 + len
	if buf._writeOffset + requiredBytes > buffer_len(buf._buffer) then
		if not Alloc(buf, requiredBytes) then return false end
	end
	buffer_writeu8(buf._buffer, buf._writeOffset, len)
	buffer_writestring(buf._buffer, buf._writeOffset + 1, value)
	buf._writeOffset += requiredBytes
	return true
end

readers[1] = function(buf: buffer, offset: number): (number, boolean?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readu8(buf, offset) == 1
	return 1, value
end

readers[2] = function(buf: buffer, offset: number): (number, number?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readu8(buf, offset)
	return 1, value
end

readers[3] = function(buf: buffer, offset: number): (number, number?)
	if offset + 2 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readu16(buf, offset)
	return 2, value
end

readers[4] = function(buf: buffer, offset: number): (number, number?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readu32(buf, offset)
	return 4, value
end

readers[5] = function(buf: buffer, offset: number): (number, number?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readi8(buf, offset)
	return 1, value
end

readers[6] = function(buf: buffer, offset: number): (number, number?)
	if offset + 2 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readi16(buf, offset)
	return 2, value
end

readers[7] = function(buf: buffer, offset: number): (number, number?)
	if offset + 3 > buffer_len(buf) then
		return 0, nil
	end

	local value = ReadU24(buf, offset)
	return 3, value
end

readers[8] = function(buf: buffer, offset: number): (number, number?)
	if offset + 3 > buffer_len(buf) then
		return 0, nil
	end

	local value = ReadI24(buf, offset)
	return 3, value
end

readers[9] = function(buf: buffer, offset: number): (number, number?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readi32(buf, offset)
	return 4, value
end

readers[10] = function(buf: buffer, offset: number): (number, number?)
	if offset + 2 > buffer_len(buf) then
		return 0, nil
	end

	local value = ReadF16(buf, offset)
	return 2, value
end

readers[11] = function(buf: buffer, offset: number): (number, number?)
	if offset + 3 > buffer_len(buf) then
		return 0, nil
	end

	local value = ReadF24(buf, offset)
	return 3, value
end

readers[12] = function(buf: buffer, offset: number): (number, number?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readf32(buf, offset)
	return 4, value
end

readers[13] = function(buf: buffer, offset: number): (number, number?)
	if offset + 8 > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readf64(buf, offset)
	return 8, value
end

readers[14] = function(buf: buffer, offset: number): (number, string?)
	if offset + 2 > buffer_len(buf) then
		return 0, nil
	end

	local length = buffer_readu16(buf, offset)

	if offset + 2 + length > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readstring(buf, offset + 2, length)
	return 2 + length, value
end

readers[15] = function(buf: buffer, offset: number): (number, Vector3?)
	if offset + 12 > buffer_len(buf) then
		return 0, nil
	end

	local x = buffer_readf32(buf, offset)
	local y = buffer_readf32(buf, offset + 4)
	local z = buffer_readf32(buf, offset + 8)
	return 12, Vector3.new(x, y, z)
end

readers[16] = function(buf: buffer, offset: number): (number, Vector2?)
	if offset + 8 > buffer_len(buf) then
		return 0, nil
	end

	local x = buffer_readf32(buf, offset)
	local y = buffer_readf32(buf, offset + 4)
	return 8, Vector2.new(x, y)
end

readers[17] = function(buf: buffer, offset: number): (number, Vector2?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local x = ReadF16(buf, offset)
	local y = ReadF16(buf, offset + 2)
	return 4, Vector2.new(x, y)
end

readers[18] = function(buf: buffer, offset: number): (number, Vector3?)
	if offset + 6 > buffer_len(buf) then
		return 0, nil
	end

	local x = ReadF16(buf, offset)
	local y = ReadF16(buf, offset + 2)
	local z = ReadF16(buf, offset + 4)
	return 6, Vector3.new(x, y, z)
end

readers[19] = function(buf: buffer, offset: number): (number, Vector2?)
	if offset + 6 > buffer_len(buf) then
		return 0, nil
	end

	local x = ReadF24(buf, offset)
	local y = ReadF24(buf, offset + 3)
	return 6, Vector2.new(x, y)
end

readers[20] = function(buf: buffer, offset: number): (number, Vector3?)
	if offset + 9 > buffer_len(buf) then
		return 0, nil
	end

	local x = ReadF24(buf, offset)
	local y = ReadF24(buf, offset + 3)
	local z = ReadF24(buf, offset + 6)
	return 9, Vector3.new(x, y, z)
end

readers[21] = function(buf: buffer, offset: number): (number, Vector2int16?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local x = buffer_readi16(buf, offset)
	local y = buffer_readi16(buf, offset + 2)
	return 4, Vector2int16.new(x, y)
end

readers[22] = function(buf: buffer, offset: number): (number, Vector3int16?)
	if offset + 6 > buffer_len(buf) then
		return 0, nil
	end

	local x = buffer_readi16(buf, offset)
	local y = buffer_readi16(buf, offset + 2)
	local z = buffer_readi16(buf, offset + 4)
	return 6, Vector3int16.new(x, y, z)
end

readers[23] = function(buf: buffer, offset: number): (number, CFrame?)
	if offset + 18 > buffer_len(buf) then
		return 0, nil
	end

	local rx = buffer_readu16(buf, offset) * CFRAME_INV_SCALE
	local ry = buffer_readu16(buf, offset + 2) * CFRAME_INV_SCALE
	local rz = buffer_readu16(buf, offset + 4) * CFRAME_INV_SCALE
	local x = buffer_readf32(buf, offset + 6)
	local y = buffer_readf32(buf, offset + 10)
	local z = buffer_readf32(buf, offset + 14)
	return 18, CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(x, y, z)
end

readers[24] = function(buf: buffer, offset: number): (number, CFrame?)
	if offset + 9 > buffer_len(buf) then
		return 0, nil
	end

	local rx = buffer_readu8(buf, offset) * CFRAME_INV_SCALE_U8
	local ry = buffer_readu8(buf, offset + 1) * CFRAME_INV_SCALE_U8
	local rz = buffer_readu8(buf, offset + 2) * CFRAME_INV_SCALE_U8
	local x = ReadF16(buf, offset + 3)
	local y = ReadF16(buf, offset + 5)
	local z = ReadF16(buf, offset + 7)
	return 9, CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(x, y, z)
end

readers[25] = function(buf: buffer, offset: number): (number, CFrame?)
	if offset + 12 > buffer_len(buf) then
		return 0, nil
	end

	local rx = buffer_readu8(buf, offset) * CFRAME_INV_SCALE_U8
	local ry = buffer_readu8(buf, offset + 1) * CFRAME_INV_SCALE_U8
	local rz = buffer_readu8(buf, offset + 2) * CFRAME_INV_SCALE_U8
	local x = ReadF24(buf, offset + 3)
	local y = ReadF24(buf, offset + 6)
	local z = ReadF24(buf, offset + 9)
	return 12, CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(x, y, z)
end

readers[26] = function(buf: buffer, offset: number): (number, CFrame?)
	if offset + 12 > buffer_len(buf) then
		return 0, nil
	end

	local rx = buffer_readu16(buf, offset) * CFRAME_INV_SCALE
	local ry = buffer_readu16(buf, offset + 2) * CFRAME_INV_SCALE
	local rz = buffer_readu16(buf, offset + 4) * CFRAME_INV_SCALE
	local x = ReadF16(buf, offset + 6)
	local y = ReadF16(buf, offset + 8)
	local z = ReadF16(buf, offset + 10)
	return 12, CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(x, y, z)
end

readers[27] = function(buf: buffer, offset: number): (number, CFrame?)
	if offset + 15 > buffer_len(buf) then
		return 0, nil
	end

	local rx = buffer_readu16(buf, offset) * CFRAME_INV_SCALE
	local ry = buffer_readu16(buf, offset + 2) * CFRAME_INV_SCALE
	local rz = buffer_readu16(buf, offset + 4) * CFRAME_INV_SCALE
	local x = ReadF24(buf, offset + 6)
	local y = ReadF24(buf, offset + 9)
	local z = ReadF24(buf, offset + 12)
	return 15, CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(x, y, z)
end

readers[28] = function(buf: buffer, offset: number): (number, Color3?)
	if offset + 3 > buffer_len(buf) then
		return 0, nil
	end

	local r = buffer_readu8(buf, offset)
	local g = buffer_readu8(buf, offset + 1)
	local b = buffer_readu8(buf, offset + 2)
	return 3, Color3.fromRGB(r, g, b)
end

readers[29] = function(buf: buffer, offset: number): (number, NumberSequence?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local length = buffer_readu8(buf, offset)
	if offset + 1 + length * 3 > buffer_len(buf) then
		return 0, nil
	end

	local keypoints = {}
	local currentOffset = offset + 1

	for i = 1, length do
		local time = buffer_readu8(buf, currentOffset) * FLOAT_FROM_BYTE_SCALE
		local value = buffer_readu8(buf, currentOffset + 1) * FLOAT_FROM_BYTE_SCALE
		local envelope = buffer_readu8(buf, currentOffset + 2) * FLOAT_FROM_BYTE_SCALE
		table_insert(keypoints, NumberSequenceKeypoint.new(time, value, envelope))
		currentOffset += 3
	end

	return 1 + length * 3, NumberSequence.new(keypoints)
end

readers[30] = function(buf: buffer, offset: number): (number, ColorSequence?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local length = buffer_readu8(buf, offset)
	if offset + 1 + length * 4 > buffer_len(buf) then
		return 0, nil
	end

	local keypoints = {}
	local currentOffset = offset + 1

	for i = 1, length do
		local time = buffer_readu8(buf, currentOffset) * FLOAT_FROM_BYTE_SCALE
		local r = buffer_readu8(buf, currentOffset + 1)
		local g = buffer_readu8(buf, currentOffset + 2)
		local b = buffer_readu8(buf, currentOffset + 3)
		table_insert(keypoints, ColorSequenceKeypoint.new(time, Color3.fromRGB(r, g, b)))
		currentOffset += 4
	end

	return 1 + length * 4, ColorSequence.new(keypoints)
end

readers[31] = function(buf: buffer, offset: number): (number, UDim?)
	if offset + 4 > buffer_len(buf) then
		return 0, nil
	end

	local scale = buffer_readi16(buf, offset) * UDIM_INV_SCALE
	local offsetValue = buffer_readi16(buf, offset + 2)
	return 4, UDim.new(scale, offsetValue)
end

readers[32] = function(buf: buffer, offset: number): (number, UDim2?)
	if offset + 8 > buffer_len(buf) then
		return 0, nil
	end

	local xScale = buffer_readi16(buf, offset) * UDIM_INV_SCALE
	local xOffset = buffer_readi16(buf, offset + 2)
	local yScale = buffer_readi16(buf, offset + 4) * UDIM_INV_SCALE
	local yOffset = buffer_readi16(buf, offset + 6)
	return 8, UDim2.new(xScale, xOffset, yScale, yOffset)
end

readers[33] = function(buf: buffer, offset: number): (number, Rect?)
	if offset + 16 > buffer_len(buf) then
		return 0, nil
	end

	local minX = buffer_readf32(buf, offset)
	local minY = buffer_readf32(buf, offset + 4)
	local maxX = buffer_readf32(buf, offset + 8)
	local maxY = buffer_readf32(buf, offset + 12)
	return 16, Rect.new(minX, minY, maxX, maxY)
end

readers[34] = function(buf: buffer, offset: number): (number, NumberRange?)
	if offset + 8 > buffer_len(buf) then
		return 0, nil
	end

	local min = buffer_readf32(buf, offset)
	local max = buffer_readf32(buf, offset + 4)
	return 8, NumberRange.new(min, max)
end

readers[35] = function(buf: buffer, offset: number): (number, BrickColor?)
	if offset + 2 > buffer_len(buf) then
		return 0, nil
	end

	local number = buffer_readu16(buf, offset)
	return 2, BrickColor.new(number)
end

readers[36] = function(buf: buffer, offset: number): (number, {[any]: any}?)
	local result = {}
	local currentOffset = offset

	while true do
		local bytesRead1, typeId = readers[2](buf, currentOffset)
		if bytesRead1 == 0 then return 0, nil end


		currentOffset += bytesRead1

		if typeId == 0 then
			return currentOffset - offset, result
		end


		local bytesRead2, key = readers[typeId](buf, currentOffset)
		if bytesRead2 == 0 then return 0, nil end
		currentOffset += bytesRead2

		
		local bytesRead3, valueTypeId = readers[2](buf, currentOffset)
		if bytesRead3 == 0 then return 0, nil end
		currentOffset += bytesRead3

		local bytesRead4, value = readers[valueTypeId](buf, currentOffset)
		if bytesRead4 == 0 then return 0, nil end
		currentOffset += bytesRead4

		result[key] = value
	end
end

readers[37] = function(buf :buffer, offset: number): (number, string?)
	if offset + 1 > buffer_len(buf) then
		return 0, nil
	end

	local length = buffer_readu8(buf, offset)

	if offset + 1 + length > buffer_len(buf) then
		return 0, nil
	end

	local value = buffer_readstring(buf, offset + 1, length)
	return 1 + length, value
end

-- creates a basic buffer from BinBuffer
local function tobuffer(buf: Buffer): buffer
	local raw_buf = buffer_create(buf._writeOffset)
	buffer_copy(raw_buf, 0, buf._buffer, 0, buf._writeOffset)
	return raw_buf
end

local function truncate(buf: Buffer)
	local truncated = buffer_create(buf._writeOffset)
	buffer_copy(truncated, 0, buf._buffer, 0, buf._writeOffset)
	buf._buffer = truncated
	buf._size = buf._writeOffset
end


-- API
return {
	writers = writers,
	readers = readers,
	bytes = bytes,
	kilobytes = kilobytes,
	megabytes = megabytes,
	destroy = destroy,
	clear = clear,
	tobuffer = tobuffer,
	create = create,
	with_capacity = with_capacity,
	truncate = truncate,
	reset_read = reset_read,
}