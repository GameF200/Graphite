local BinBuffer = require("./BinBuffer")
local Buffers   = require("./Buffers")

local acquire = Buffers.Acquire
local release = Buffers.Release

local new = BinBuffer.create
local with_capacity = BinBuffer.with_capacity

local writers = BinBuffer.writers

local Select = select

return function(struct: {number})
	local funcs = table.create(#struct)
	for i = 1, #struct do
		funcs[i] = writers[struct[i]]
	end

	local count = #funcs
	return function(...)
		local buf = acquire()

		for i = 1, count do
			funcs[i](buf, Select(i, ...))
		end

		return buf
	end
end