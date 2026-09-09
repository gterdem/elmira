-- Elmira/Core/AbilitySettings.lua — what every ability is allowed to do on screen (AB1-D3/D4).
--
-- PURE (hard rule 3): no WoW API, no frames. A plain store over `ns.db.char.abilities[<spellKey>]`
-- plus the inheritance rule that resolves it, so the Options page, the render loop and the tracker
-- all read one answer instead of three.
--
-- SEPARATE FROM THE REGISTRY, on purpose. `Core/Spells.lua` owns `db.char.spells[key]` -- what a
-- spell IS -- and `Spells.merged` overwrites a registry entry with the pack's own on a key collision
-- (pack wins, hard rule 2). Settings kept inside that entry would be dropped by that merge the first
-- time a shipped pack named the same key. They live in their own table, keyed the same way, so a
-- pack arriving later can never take a player's glow colour with it.
--
-- PER CHARACTER (AB1-D3, amending the profile scope these settings shipped under): what you want
-- flashing at you is a fact about the character you are playing, not about a profile you might share
-- with an alt. ADR-0010 (user builds are account-wide) is untouched.
--
-- THE ALL-ABILITIES ENTRY is the key `"*"`. Nothing else can produce it: `Core/Spells.slug` maps
-- every non-alphanumeric to `_`, so a registry key is always `[A-Z0-9_]+` and can never collide.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local AbilitySettings = {}
local ALL = "*"
AbilitySettings.ALL = ALL

-- What every channel is worth before anyone touches anything. A field that is absent from here
-- cannot be written (`set` refuses an unknown field), so this table is the schema as well as the
-- default -- there is no second list to drift from it.
--
-- `false` rather than nil for "the library's own default" is the same sentinel Core/DB.lua uses and
-- for the same reason: nil cannot be told apart from "unset" once AceDB has omitted it.
--
-- `glow.enabled` ships TRUE and every other channel ships FALSE. That is ADR-0009 as amended by
-- AB1-D4: a bar glow on everything is what this addon already did, while a screen flash, a sound, a
-- texture or a party-visible announcement on everything is the strobe the ADR exists to prevent.
local DEFAULTS = {
  general  = { onlyInCombat = false, expiringSeconds = 3 },
  glow     = { enabled = true, style = "PIXEL", color = false,
               particles = false, frequency = false, thickness = false, speed = false },
  texture  = { enabled = false },
  edge     = { enabled = false, edge = "left", color = false, intensity = 0.5 },
  sound    = { enabled = false, suggested = "None", ready = "None", used = "None",
               active = "None", expiring = "None" },
  announce = { enabled = false, duration = false },
}
AbilitySettings.DEFAULTS = DEFAULTS

-- AB1-D4: inheritance covers appearance and CHOICES only. Whether a channel is ON is a per-ability
-- fact for Screen-edge, Sound, Texture and Announcement, and is never inherited -- otherwise one
-- switch on the All abilities entry turns a flash on for every spell in the rotation at once, which
-- is the exact failure ADR-0009 was written against. Glow is deliberately absent: its on/off DOES
-- inherit, because glowing the button you are about to press is this addon's normal state.
local OWN = { texture = { enabled = true }, edge = { enabled = true },
              sound = { enabled = true }, announce = { enabled = true } }

AbilitySettings.CHANNELS = { "general", "glow", "texture", "edge", "sound", "announce" }
-- The five channels that have an on/off a player can read off the tree (AB1-D9b). `general` is not
-- one of them: it holds facts about the ability, not a cue that fires.
AbilitySettings.CUE_CHANNELS = { "glow", "texture", "edge", "sound", "announce" }
-- The channels Core/Track has to watch the state for. Glow is absent because it follows the
-- now-slot the render loop already computes -- adding it here would put every ability in the addon
-- into a 10 Hz cooldown/aura poll for an event nothing reads.
local TRACK_CHANNELS = { "texture", "edge", "sound", "announce" }
AbilitySettings.EVENTS = { "suggested", "ready", "used", "active", "expiring" }

-- Bumped by every write. Display/Driver compares it to decide whether its tracked set is stale,
-- which is how "recomputed on every settings change" (AB1-D5) happens without every setter in the
-- options panel having to remember to say so.
local version = 0
function AbilitySettings.version() return version end

function AbilitySettings.store()
  local db = ns.db
  return db and db.char and db.char.abilities
end

local function stored(key, channel)
  local s = AbilitySettings.store()
  local row = s and s[key]
  return row and row[channel]
end

local function ensure(key, channel)
  local s = AbilitySettings.store()
  if not (s and type(key) == "string") then return nil end
  local row = s[key]
  if not row then row = {}; s[key] = row end
  local t = row[channel]
  if not t then t = {}; row[channel] = t end
  return t
end

-- "Same as All abilities", the toggle every per-ability tab opens with. Default ON, and the All
-- abilities entry itself can never inherit -- it is what everything else inherits FROM.
function AbilitySettings.inherits(key, channel)
  if key == ALL then return false end
  local t = stored(key, channel)
  return not (t and t.inherit == false)
end

function AbilitySettings.setInherit(key, channel, on)
  if not DEFAULTS[channel] then return false end
  local t = ensure(key, channel)
  if not t then return false end
  t.inherit = on and true or false
  version = version + 1
  return true
end

-- AbilitySettings.effective(key, channel) -> a fresh table of resolved values
--
-- Three layers, applied in order: the shipped default, then the All abilities entry (only while
-- this ability inherits, and never for an OWN field), then this ability's own stored values (all of
-- them when it does not inherit, its OWN fields either way). Nothing outside this file reads the
-- raw table -- that is what keeps the inheritance rule in one place.
function AbilitySettings.effective(key, channel)
  local def = DEFAULTS[channel]
  if not def then return nil end
  local out = {}
  for field, value in pairs(def) do out[field] = value end
  local own = OWN[channel] or {}
  local inherit = AbilitySettings.inherits(key, channel)
  if inherit then
    for field, value in pairs(stored(ALL, channel) or {}) do
      if field ~= "inherit" and not own[field] then out[field] = value end
    end
  end
  for field, value in pairs(stored(key, channel) or {}) do
    if field ~= "inherit" and (own[field] or not inherit) then out[field] = value end
  end
  return out
end

-- Refuses a field the channel does not declare, so a typo in the options panel is a silent no-op
-- here rather than a value nothing will ever read back.
function AbilitySettings.set(key, channel, field, value)
  local def = DEFAULTS[channel]
  if not (def and def[field] ~= nil) then return false end
  local t = ensure(key, channel)
  if not t then return false end
  t[field] = value
  version = version + 1
  return true
end

-- Everything this ability has ever been given, gone (AB1-D6's Remove). The registry entry itself is
-- Core/Spells.remove's business; this is only the settings row beside it.
function AbilitySettings.clear(key)
  local s = AbilitySettings.store()
  if not (s and s[key]) then return false end
  s[key] = nil
  version = version + 1
  return true
end

-- One channel back to shipped, which is what All abilities > Glow's Reset means. Deleting the
-- sub-table rather than rewriting the defaults into it keeps "never chosen" and "chosen to equal
-- the default" the same state, the way an untouched install is.
function AbilitySettings.resetChannel(key, channel)
  local s = AbilitySettings.store()
  if not (s and DEFAULTS[channel]) then return false end
  local row = s[key]
  if row then row[channel] = nil end
  version = version + 1
  return true
end

-- Is this channel doing anything for this ability? Sound is the one that cannot answer from a
-- toggle alone (AB1-D8: "the tab is on when any event has a sound") -- switched on with every event
-- set to None is a channel that will never make a noise, and the tree must not claim otherwise.
function AbilitySettings.channelOn(key, channel)
  local e = AbilitySettings.effective(key, channel)
  if not (e and e.enabled == true) then return false end
  if channel ~= "sound" then return true end
  for _, event in ipairs(AbilitySettings.EVENTS) do
    if e[event] and e[event] ~= "None" then return true end
  end
  return false
end

-- Anything at all on: what the tree's desaturation and the "Any configured" filter ask (AB1-D9).
function AbilitySettings.anyOn(key)
  for _, channel in ipairs(AbilitySettings.CUE_CHANNELS) do
    if AbilitySettings.channelOn(key, channel) then return true end
  end
  return false
end

-- Does the render loop have to watch this ability's cooldown and auras? Only the channels that fire
-- on something Core/Track reads out of the state.
function AbilitySettings.tracked(key)
  for _, channel in ipairs(TRACK_CHANNELS) do
    if AbilitySettings.channelOn(key, channel) then return true end
  end
  return false
end

ns.AbilitySettings = AbilitySettings
return AbilitySettings
