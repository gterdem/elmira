-- Elmira/Core/Packs.lua — the built-in class-pack registry (ADR-0011).
-- Pure Lua, no WoW globals. Shipped class data lives in Elmira/Classes/<Class>.lua inside core;
-- third-party packs stay separate addons and register through Elmira.API.RegisterDataPack, which
-- this file deliberately does not touch. Core/Init.lua is the only caller of BuiltinPack().
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Packs = {}

-- class -> thunk. Never class -> pack: WoW parses and executes every file in a TOC, so a Classes
-- file that built its tables at load would cost every character all nine classes' data. Storing a
-- closure costs one per class and only the player's is ever called (ADR-0011 §2).
local builtin = {}
Packs.builtin = builtin

-- Rejects anything but a function, loudly. A table here still "works" — Init would hand it straight
-- to RegisterDataPack and the addon would behave correctly — while silently costing every character
-- every class's tables, which is the entire saving the ADR is built on. A defect that only shows up
-- as memory has to be caught at the point it is introduced or not at all.
function Packs.RegisterBuiltinPack(class, thunk)
  if type(class) ~= "string" or class == "" then
    ns.log("built-in pack rejected (class must be a non-empty string)")
    return false, "class must be a non-empty string"
  end
  if type(thunk) ~= "function" then
    ns.log("built-in pack for %s rejected (data must be a function, got %s)", class, type(thunk))
    return false, "data must be a function"
  end
  builtin[class] = thunk
  return true
end

-- Calls the one thunk for this class and returns the pack table. Protected: a syntax-clean but
-- runtime-broken class file must disable that class, not take the addon down with it.
function Packs.BuiltinPack(class)
  local thunk = class and builtin[class]
  if not thunk then return nil end
  local ok, pack = pcall(thunk)
  if not ok then
    ns.log("built-in %s pack failed to build (%s)", tostring(class), tostring(pack))
    return nil
  end
  if type(pack) ~= "table" then
    ns.log("built-in %s pack returned %s, not a table", tostring(class), type(pack))
    return nil
  end
  return pack
end

ns.Packs = Packs
ns.RegisterBuiltinPack = Packs.RegisterBuiltinPack
return Packs
