-- Elmira/Core/Serialize.lua — a build to and from an import string (docs/02 "Import/export string",
-- PRD F9). Format: `ELM1:` + LibDeflate EncodeForPrint(CompressDeflate(LibSerialize({v=1, build}))).
--
-- Pure Lua. The two libraries are INJECTED by Core/Init.lua through `Serialize.use`, so this file
-- never names LibStub (hard rule 3's spirit: Core stays dofile-able) and a spec hands in the real
-- LibSerialize/LibDeflate loaded headlessly — the round trip that ships is the round trip tested.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Serialize = {}
Serialize.PREFIX = "ELM1:"
Serialize.VERSION = 1

local libs = nil -- mutants: equivalent deleting the declaration leaves a global write the suite cannot see; luacheck catches it

-- { serializer = LibSerialize, deflate = LibDeflate }. Returns false, and leaves the codec
-- unavailable, when either is missing: an addon shipped without its libraries must say "cannot
-- export" rather than crash on the first `/elm export`.
function Serialize.use(t)
  if type(t) ~= "table" or type(t.serializer) ~= "table" or type(t.deflate) ~= "table" then
    libs = nil
    return false
  end
  libs = t
  return true
end

function Serialize.available()
  return libs ~= nil
end

-- Functions are never serialized. `Schema.exportable` owns the rule for what that means for a build
-- (docs/02: an entry carrying a `custom` condition exports marked `disabled = true` with its `when`
-- gone, and compiled artefacts never travel); this file only has to drop any function that could
-- remain and hand the result to the codec. One rule, one owner.
local function copyPlain(v)
  if type(v) == "function" then return nil end
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if type(k) ~= "function" then
      local c = copyPlain(x)
      if c ~= nil then out[k] = c end
    end
  end
  return out
end

-- Serialize.encode(build) -> string | nil, reason
function Serialize.encode(build)
  if not libs then return nil, "cannot export: serializer libraries are not loaded" end
  if type(build) ~= "table" then return nil, "not a build" end
  local exportable = ns.Schema and ns.Schema.exportable and ns.Schema.exportable(build) or build
  local out = copyPlain(exportable)
  local ok, payload = pcall(libs.serializer.Serialize, libs.serializer, { v = Serialize.VERSION, build = out })
  if not ok or type(payload) ~= "string" then
    return nil, "serialize failed: " .. tostring(payload)
  end
  local compressed = libs.deflate:CompressDeflate(payload)
  if type(compressed) ~= "string" then return nil, "compress failed" end
  return Serialize.PREFIX .. libs.deflate:EncodeForPrint(compressed)
end

-- Serialize.decode(str, ctx) -> build | nil, reason
-- `ctx` is what Schema.validate needs (`spells`, `sets`, `souls`, `bonuses` of the pack the build is
-- meant for): a string can be well-formed and still name spells this class pack does not have.
function Serialize.decode(str, ctx)
  if not libs then return nil, "cannot import: serializer libraries are not loaded" end
  if type(str) ~= "string" then return nil, "not a string" end
  str = str:gsub("^%s+", ""):gsub("%s+$", "")
  local prefix = str:sub(1, #Serialize.PREFIX)
  if prefix ~= Serialize.PREFIX then
    return nil, string.format("not an Elmira build string (expected it to start with %s)", Serialize.PREFIX)
  end
  local decoded = libs.deflate:DecodeForPrint(str:sub(#Serialize.PREFIX + 1))
  if not decoded then return nil, "corrupted string (could not decode)" end
  local raw = libs.deflate:DecompressDeflate(decoded)
  if not raw then return nil, "corrupted string (could not decompress)" end
  local ok, t = libs.serializer:Deserialize(raw)
  if not ok or type(t) ~= "table" then return nil, "corrupted string (could not deserialize)" end
  if t.v ~= Serialize.VERSION then
    return nil, string.format("unsupported build string version %s (this Elmira reads %d)", tostring(t.v), Serialize.VERSION)
  end
  local build = t.build
  if type(build) ~= "table" then return nil, "no build in string" end
  if ns.Schema then
    local valid, errors = ns.Schema.validate(build, ctx or {})
    if not valid then
      return nil, "invalid build: " .. table.concat(ns.Schema.errorLines(errors or {}), "; ")
    end
  end
  return build
end

ns.Serialize = Serialize
return Serialize
