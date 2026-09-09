-- Elmira/Display/Sounds.lua — the one place a sound is fetched and played (AB1-D8).
--
-- Lifted verbatim out of Display/Announcers.lua, which owned the only LibSharedMedia fetch and
-- `PlaySoundFile` call in the addon. It now has a second caller -- an ability's per-event sound --
-- and two copies of "resolve a media name and play it" would be two places for a name that no
-- longer resolves to fail differently. Every failure here is a quiet `false`: no media library, a
-- name the player's packs no longer provide, or a client with no PlaySoundFile. The options panel
-- plays a sound the moment it is picked, and an error thrown from a `set` takes the panel with it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Sounds = {}

local function media()
  return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

-- The sounds the player has, from whatever media packs they run, as an AceConfig `values` map.
-- "None" is always first and always present: it is the default for every ability event, and a
-- dropdown with no way back to silence is a cue you cannot switch off.
function Sounds.list()
  local out = { None = "None" }
  local lsm = media()
  for _, name in ipairs((lsm and lsm:List("sound")) or {}) do out[name] = name end
  return out
end

function Sounds.play(name)
  if not name or name == "None" then return false end
  local lsm = media()
  local path = lsm and lsm:Fetch("sound", name)
  if not (path and PlaySoundFile) then return false end
  PlaySoundFile(path)
  return true
end

-- The master mute (AB1-D8, "Ability sounds" on the Notifications page). Per CHARACTER, like every
-- other ability setting -- someone who plays a healer with sound and a tank without should not have
-- to keep two profiles to say so. Announcement sounds are NOT gated by it: those belong to
-- Core/Announce's routing, which has its own per-category switch.
function Sounds.abilitySoundsOn()
  local c = ns.db and ns.db.char and ns.db.char.sounds
  return (c and c.enabled) == true
end

ns.Sounds = Sounds
return Sounds
