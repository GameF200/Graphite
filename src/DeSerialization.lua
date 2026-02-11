local BinBuffer = require("./BinBuffer")
local Buffers   = require("./Buffers")

local readers = BinBuffer.readers

local Select = select
local Unpack = table.unpack

return function(struct: {number})
	local funcs = table.create(#struct)
	for i = 1, #struct do
		funcs[i] = readers[struct[i]]
	end

	local count = #funcs
	return function(start_from: number, buf: buffer): (number?, string | {any})
		local bufLen = buffer.len(buf)
		local out = table.create(count)

		local cursor = start_from

		for i = 1, count do
			local oldCursor = cursor
			local bytes_read, data = funcs[i](buf, cursor)

			if not bytes_read then
				return nil, "invalid data"
			end

			if bytes_read <= 0 then
				return nil, "cursor not advanced"
			end

			local newCursor = cursor + bytes_read

			if newCursor <= oldCursor then
				return nil, "cursor not advanced"
			end

			if newCursor > bufLen then
				return nil, "out of bounds"
			end

			cursor = newCursor
			out[i] = data
		end

		return cursor, out
	end
end