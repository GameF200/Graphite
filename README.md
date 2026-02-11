# Graphite 

Make your networking easy, fast, predictable.

## [      GitHub Repo]()   |   [Creator Store](https://create.roblox.com/store/asset/123588415222554/Graphite) 

---
</div>

## About
Graphite is a continue of [Quartz Project](https://devforum.roblox.com/t/deprecated-quartz-quick-networking-library/4069336) Designed to make networking like a flow.
Graphite using CC(Congestion control) called `QNC (Queue Network Control)` which using technologies like PI/PID and CoDel

##  Features:
* Very easy API with builder pattern
* Type safe networking, Graphite using Validator
* Compact, structure binary serialization with no type tags
* `Slice batching`, Not just naive batching, only advanced
* `QNC` - Smart Congestion control algorithm 

#  Basic Usage(Client):
```
local Graphite = require(path.to.Graphite)

local Event = Graphite.Event("Test")
      .type(Graphite.Bool)
      .droppable()
      .build()

Event.Fire(false)
Event.OnClientEvent(function(bool: boolean)
    print("got from server:".. bool)
end)
-- autocomplete fully working!
```
# Server:
```
local Graphite = require(path.to.Graphite)

local Event = Graphite.Event("Test")
    .type(Graphite.Bool)
    .droppable()
    .build()
```