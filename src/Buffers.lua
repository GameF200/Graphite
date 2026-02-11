--!strict
--!optimize 2

local BinBuffer = require("./BinBuffer")

type Array<T> = {T}
type Buffer = BinBuffer.Buffer
local NULL = table.freeze({})
type Nullable<T> = T | typeof(NULL)

local BUFFER_POOL: Array<Nullable<Buffer>> = table.create(4096, NULL)
local TABLE_POOL : Array<Nullable<Array<any>>>  = table.create(4096, NULL)
local TABLE_POOL_SIZE = 0
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

local AcquireTable = function(): Array<any>
	if TABLE_POOL_SIZE > 0 then
		local table = TABLE_POOL[TABLE_POOL_SIZE]
		if table == NULL then
			error("Table corruption, got shared ref")
		end
		TABLE_POOL[TABLE_POOL_SIZE] = NULL
		TABLE_POOL_SIZE = POOL_SIZE - 1
		
		return table :: Array<any>
	end
	
	return table.create(INITIAL_CAPACITY)
end

local ReleaseTable = function(rel_table: Array<any>)
	if #rel_table > 0 then
		table.clear(rel_table)
	end
	TABLE_POOL_SIZE = TABLE_POOL_SIZE + 1
	TABLE_POOL[TABLE_POOL_SIZE] = rel_table
end


return {
	Acquire = Acquire,
	Release = Release,
	AcquireTable = AcquireTable,
	ReleaseTable = ReleaseTable,
}