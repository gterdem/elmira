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
  -- AT2-D1: `show` is which moments this ability's glow (bar AND strip, D3) is allowed on screen --
  -- the SAME values Core/Visibility.MODES offers the display, but its OWN gate: a hidden strip with
  -- glow set to "Always" still glows, and a visible strip with glow set to "In combat only" does
  -- not. Ships as the display's own default so nothing changes for a player who never opens this
  -- tab; a plain string literal rather than `ns.Visibility.DEFAULT`, because ability_settings_spec
  -- (and any other spec that loads this file alone) never loads Core/Visibility.lua first.
  glow     = { enabled = true, style = "PROC", color = false, show = "combat_or_target",
               particles = false, frequency = false, thickness = false, speed = false },
  -- AB3-D1, as rewritten by AT4-D2: `source` is either `icon` (the ability's own spell icon, the
  -- shipped answer) or `path`, and then `path` says which file -- picked from the visual library or
  -- typed by hand, which are the same stored fact. The old `shape` field and its dropdown are gone
  -- with the sources that needed them; nothing has ever been released, so nothing migrates and a
  -- row still carrying one simply reads as `icon`.
  -- All five events are offered: `suggested` and `active` SHOW the texture
  -- while the state holds, the other three FLASH it, which is why a texture can afford the three
  -- events a screen edge cannot.
  --
  -- `x`/`y` are the per-texture placement (AB3-D2) and are OWN, not inherited (see below): an
  -- offset from the centre of the screen, which AT6-D4 made the only placement there is -- the
  -- `place` field that chose between the indicator row, the centre and a custom spot went with the
  -- row itself, and nothing has ever been released, so nothing migrates.
  --
  -- AB4-D1: `fill` is the progress swipe over the texture -- "none", "cooldown" (how much of the
  -- ability's own cooldown is left) or "buff" (how much of its buff is left). It ships "none"
  -- because a swipe over a texture that is only on screen for a second and a half is noise, and
  -- because both of the other two are meaningless for an ability the tracker has no numbers for.
  -- An appearance CHOICE, so it inherits like size and colour.
  texture  = { enabled = false, source = "icon", path = "",
               size = 48, color = false, alpha = 1, fill = "none",
               suggested = true, active = true, ready = false, used = false, expiring = false,
               x = 0, y = 0 },
  -- AB2-D1: `suggested` and `ready` are the two moments a screen edge can flash. `suggested` ships
  -- ON so that switching the tab on does something the first time (a channel that is "on" and fires
  -- on nothing is the silent failure this project keeps shipping); `ready` ships OFF, because a
  -- spell coming off cooldown while you are already pressing something else is the strobe ADR-0009
  -- is about. They are CHOICES, so they inherit -- only `enabled` is per ability (OWN, below).
  edge     = { enabled = false, edge = "left", color = false, intensity = 0.5,
               suggested = true, ready = false },
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
--
-- AB3-D2 adds three more to `texture`: WHERE one texture sits is a fact about that texture. The
-- decision says the custom Move mode "drags that texture alone and stores an offset from screen
-- centre", and an inherited offset cannot do that -- dragging a linked ability's texture would move
-- every other linked one with it, or (worse) write to a row nothing reads and move nothing at all,
-- which is this project's characteristic silent failure. Appearance still inherits; position does
-- not.
--
-- AT1-D2 removes even the appearance inheritance for these four: nothing in `OWN` matters for them
-- any more since `AbilitySettings.inherits` now refuses to inherit ANY field of a CUE_CHANNEL. The
-- table stays as the record of what was per-ability even while the rest of a channel still inherited.
local OWN = { texture = { enabled = true, x = true, y = true }, edge = { enabled = true },
              sound = { enabled = true }, announce = { enabled = true } }

AbilitySettings.CHANNELS = { "general", "glow", "texture", "edge", "sound", "announce" }
-- The channels that count as "this ability is configured": the tree's greyed icon, the tooltip's
-- on/off list and the "Show > Any configured" filter all read this one list.
--
-- AB2-D6 (owner's first look at AB1): GLOW IS NOT IN IT. Glow ships on for everything, so counting
-- it made every icon in the tree full colour and every tooltip say "Glow on" -- a mark that is true
-- of every row marks nothing. What is left is exactly the four channels whose on/off is per ability
-- and never inherited, which is also exactly what Core/Track has to watch the state for: glow
-- follows the now-slot the render loop already computes, and polling it would put every ability in
-- the addon into a 10 Hz cooldown/aura scan for an event nothing reads.
AbilitySettings.CUE_CHANNELS = { "texture", "edge", "sound", "announce" }
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
--
-- AT1-D2: Screen-edge, Sound, Texture and Announcement never inherit at all any more -- "I don't
-- think anyone will want to set the same texture, screen edge, sound or announcement for all the
-- abilities" (owner). Only General and Glow still fall back to the All abilities row.
local function isCueChannel(channel)
  for _, c in ipairs(AbilitySettings.CUE_CHANNELS) do
    if c == channel then return true end
  end
  return false
end

function AbilitySettings.inherits(key, channel)
  if key == ALL or isCueChannel(channel) then return false end
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

-- AB2-D3: what the CLASS PACK says this ability should do out of the box.
--
-- A shipped pack's spell entry may carry `defaults = { edge = { enabled = true, ... }, ... }`. This
-- is the amendment ADR-0009 gets in AB2: a screen flash is still never switched on by a global
-- toggle, and it is still per ability -- but the people who wrote the rotation are allowed to say
-- which two of its twenty abilities are worth a flash, because that is the judgement the ADR's
-- "opt in per cue" was protecting and a player has no way to make before their first pull.
--
-- Read through `ns.Display.currentPack()` rather than injected: this file stays free of the WoW API
-- (the class read behind that call is the adapter's), and a guarded read cannot be forgotten by a
-- wiring step the way an injected setter can. `nil` is a NORMAL answer -- a class with no shipped
-- pack configures everything by hand and gets every channel off (the standing rule for this pass).
local function packDefault(key, channel)
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  local spells = pack and pack.spells
  local entry = spells and spells[key]
  local block = entry and entry.defaults
  local t = block and block[channel]
  return type(t) == "table" and t or nil
end

-- AbilitySettings.effective(key, channel) -> a fresh table of resolved values
--
-- Four layers, lowest first: the shipped default, then the All abilities entry (only while this
-- ability inherits, and never for an OWN field), then the class pack's own default for THIS
-- ability, then this ability's own stored values (all of them when it does not inherit, its OWN
-- fields either way). Highest wins, so the precedence AB2-D3 names reads stored -> pack default ->
-- All abilities -> shipped. The pack sits above All abilities deliberately: it is a statement about
-- one ability, while All abilities is a statement about everything, and the more specific of the
-- two is the one a player means. Anything the player touches on the ability itself still wins over
-- both. Nothing outside this file reads the raw table -- that is what keeps the rule in one place.
--
-- AT1-D2: for the four CUE_CHANNELS, `inherits` always answers false, so the "All abilities" layer
-- below is skipped for them and the precedence collapses to shipped -> pack default -> own row.
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
  -- Filtered by the channel's own field list, exactly as `set` filters a write from the panel: a
  -- pack shipping `defaults = { edge = { colour = ... } }` is a typo, and storing it would put a
  -- field in the resolved table that nothing will ever read back.
  for field, value in pairs(packDefault(key, channel) or {}) do
    if def[field] ~= nil then out[field] = value end
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

-- Does the render loop have to watch this ability's cooldown and auras? The same question as
-- `anyOn` since AB2-D6 dropped glow from CUE_CHANNELS -- the four channels that are worth marking
-- in the tree are the four that fire on something Core/Track reads out of the state. Kept as its
-- own name because the two callers ask different questions of the same answer, and one of them
-- (Display/Driver) would have to change if a future channel were configured but not polled.
function AbilitySettings.tracked(key)
  return AbilitySettings.anyOn(key)
end

-- ---------------------------------------------------------------- AB2-D5: sharing

-- Values are copied, never referenced. A colour is a table, and handing the stored one out would
-- let whatever received it edit the settings it was only supposed to read -- the same reason
-- `effective` hands out a fresh table.
local function copyValue(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copyValue(x) end
  return out
end

-- One settings row, filtered to what this addon actually declares: unknown channels and undeclared
-- fields are dropped. Used on the way OUT and on the way IN, so an import string cannot write a
-- field into SavedVariables that nothing will ever read back -- the same rule `set` applies to the
-- options panel, in the one other place values arrive from outside.
local function cleanRow(row)
  local out = {}
  for channel, t in pairs(row) do
    local def = DEFAULTS[channel]
    if def and type(t) == "table" then
      local c = {}
      for field, value in pairs(t) do
        if field == "inherit" or def[field] ~= nil then c[field] = copyValue(value) end
      end
      out[channel] = c
    end
  end
  return out
end

-- AbilitySettings.export(keys) -> { [key] = row }
--
-- `keys` is a SET (`Spells.referencedKeys`'s shape) or nil for the whole store, All abilities row
-- included. Only what is actually STORED travels: an ability whose screen edge is on because its
-- class pack ships it that way (AB2-D3) has no row of its own, and the receiving character gets the
-- same default from the same pack -- writing it out as if the player had chosen it would freeze
-- today's shipped value into their SavedVariables.
function AbilitySettings.export(keys)
  local out = {}
  for key, row in pairs(AbilitySettings.store() or {}) do
    if (keys == nil or keys[key]) and type(row) == "table" then out[key] = cleanRow(row) end
  end
  return out
end

-- AbilitySettings.import(rows, spells) -> how many keys were written
--
-- Merges by key and OVERWRITES on a collision (AB2-D5: the panel confirms with the count first).
-- `spells` is the bundle's `{ [key] = { id =, name = } }`, remembered on the row so an ability this
-- client cannot resolve still has something to show in the tree instead of a bare key.
function AbilitySettings.import(rows, spells)
  local s = AbilitySettings.store()
  if not (s and type(rows) == "table") then return 0 end
  local n = 0
  for key, row in pairs(rows) do
    if type(key) == "string" and type(row) == "table" then
      local clean = cleanRow(row)
      local info = spells and spells[key]
      if type(info) == "table" then clean.spell = { id = info.id, name = info.name } end
      s[key] = clean
      n = n + 1
    end
  end
  if n > 0 then version = version + 1 end
  return n
end

-- What an imported row remembers about the spell it came from, or nil. The tree shows this for a
-- key that is in neither the registry nor the class pack ("not on this character"), and the export
-- puts it back into the bundle so passing a settings string on does not lose the id.
function AbilitySettings.spellInfo(key)
  local s = AbilitySettings.store()
  local row = s and s[key]
  local info = row and row.spell
  return type(info) == "table" and info or nil
end

-- Every key with a row of its own, sorted -- the tree needs a stable order, and `pairs` has none.
function AbilitySettings.keys()
  local out = {}
  for key in pairs(AbilitySettings.store() or {}) do
    if key ~= ALL then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

ns.AbilitySettings = AbilitySettings
return AbilitySettings
