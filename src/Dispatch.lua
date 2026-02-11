--!strict
--!optimize 2


type Array<T> = {T}
type Fn = (...any) -> ()
type DeserializeFn = (start_from: number, buf: buffer) -> (number, {any})

local Listeners     : Array<Fn>            = table.create(255)
local Deserializaers: Array<DeserializeFn> = table.create(255)
local Validators    : Array<Fn>            = table.create(255)

local AddListener = function(
	id: number,
	listener: (...any) -> ()
)
	if not Listeners[id] then
		Listeners[id] = listener
		return
	end
	
	Listeners[id] = listener
end

local RemoveListener = function(
	id: number
)
	if not Listeners[id] then
		return
	end
	Listeners[id] = nil
end

local AddValidator = function(
	id: number, Fn: Fn
)
	if not Validators[id] then
		return
	end
	Validators[id] = Fn
end

local RemoveValidator = function(
	id: number
)
	if not Validators[id] then
		return
	end
	Validators[id] = nil
end

local CallValidator = function(id: number, ...)
	local validator = Validators[id]
	if not validator then
		return
	end
	validator(...)
end

local CallListener = function(id: number, ...)
	local listener = Listeners[id]
	if not listener then
		return
	end
	listener(...)
end

local AddDeserializer = function(
	id: number,
	Fn: DeserializeFn
)
	if Deserializaers[id] then
		Deserializaers[id] = Fn
		return
	end
	Deserializaers[id] = Fn
end

local GetDeserializaer = function(id: number): DeserializeFn?
	local fn = Deserializaers[id]
	if not fn then
		return nil
	end
	return fn 
end

return {
	AddDeserializer = AddDeserializer,
	GetDeserializaer = GetDeserializaer,
	CallListener = CallListener,
	AddListener = AddListener,
	RemoveListener = RemoveListener,
	AddValidator = AddValidator,
	RemoveValidator = RemoveValidator,
	CallValidator = CallValidator,
}