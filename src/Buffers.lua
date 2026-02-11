--!strict
--!optimize 2

local BinBuffer = require("./BinBuffer")

type Array<T> = {T}
type Buffer = BinBuffer.Buffer
local NULL = table.freeze({})
type Nullable<T> = T | typeof(NULL)

local BUFFER_POOL: Array<Nullable<Buffer>> = table.create(4096, NULL)
local POOL_SIZE = 0
local INITIAL_CAPACITY = 4

local Acquire = function(): Buffer
	if POOL_SIZE > 0 then
		local buf = BUFFER_POOL[POOL_SIZE]
		if buf == NULL then
			error("Buffer corruption, got shared ref")
		end
		BUFFER_POOL[POOL_SIZE] = NULL
		POOL_SIZE = POOL_SIZE - 1

		return buf :: Buffer
	end

	return BinBuffer.with_capacity(INITIAL_CAPACITY)
end

local Release = function(buf: Buffer)
	BinBuffer.clear(buf)

	POOL_SIZE = POOL_SIZE + 1
	BUFFER_POOL[POOL_SIZE] = buf
end

local ClearPool = function()
	for i = 1, POOL_SIZE do
		BUFFER_POOL[i] = NULL
	end
	POOL_SIZE = 0
end

return {
	Acquire = Acquire,
	Release = Release,
	ClearPool = ClearPool,
}