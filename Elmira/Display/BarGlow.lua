-- Elmira/Display/BarGlow.lua — which on-screen buttons carry a given spell.
--
-- Two sources, in priority order:
--   1. Registered bar providers (docs/08 `API.RegisterBarProvider`). Elmira_ElvUI supplies one; a
--      provider knows its own bar addon's internals far better than any generic scan could.
--   2. A Blizzard default-bar scan, as the fallback when no provider claims the spell.
--
-- Providers speak spell IDs (that is the registered contract), while the engine speaks symbolic keys
-- (hard rule 4). The translation happens here, once, so neither side has to know about the other.
--
-- A spell that is on no bar at all is a normal state, not an error: the player may simply not have
-- placed it. It degrades to no bar glow — the queue strip still shows it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local BarGlow = {}
local blizzMap = nil        -- spellID -> { buttons }, lazily built, invalidated by bar events
local blizzByName = nil     -- spell NAME -> { buttons }; Classic has ranks, see nameOf()
-- Spells we have already said we could not find a button for. Declared HERE, above every use:
-- `BarGlow.Invalidate` clears it and sits further up the file, and a `local` at the definition site
-- would leave that reference resolving to a nil global — the exact shape that made Schema's
-- condition labels come back empty an hour ago.
local announced = {}

local BLIZZ_BARS = {
  "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
  "MultiBarRightButton", "MultiBarLeftButton",
}

local function spellIDFor(key)
  if type(key) ~= "string" then return nil end
  local pack = ns.Display and ns.Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  return data and data.id or nil
end

-- Resolves whatever sits in an action slot to a spell ID. Macros are the interesting case: a
-- `#showtooltip` macro reports as kind "macro" and only GetMacroSpell knows what it will cast.
local function spellInSlot(slot)
  if not (slot and GetActionInfo) then return nil end
  local kind, id = GetActionInfo(slot)
  if kind == "spell" then return id end
  if kind == "macro" and GetMacroSpell then return (GetMacroSpell(id)) end
  return nil
end

-- A button that is not on screen cannot glow visibly, and a glow nobody can see is indistinguishable
-- from no glow at all. ElvUI HIDES Blizzard's bars rather than removing them: `ActionButton1..12`
-- still exist, still report the spell they hold, and still accept a glow. Without this filter the
-- Blizzard fallback happily answers for an ElvUI user and the glow lands on an invisible frame.
local function onScreen(button)
  if type(button) ~= "table" and type(button) ~= "userdata" then return false end
  if type(button.IsVisible) ~= "function" then return true end   -- unknown shape: do not filter it out
  local ok, visible = pcall(button.IsVisible, button)
  if not ok then return true end
  return visible == true
end

local function onlyOnScreen(buttons)
  local out = {}
  for _, button in ipairs(buttons or {}) do
    if onScreen(button) then out[#out + 1] = button end
  end
  return out
end

-- Classic has spell RANKS: each rank is its own spell id, the bar holds whichever rank the player
-- dragged there, and the data pack ships exactly one id per ability. Matching on id alone misses a
-- bar holding Exorcism (Rank 5) when the pack says 415073 (Rank 6), for every spell that has ranks —
-- and misses it silently, which is the whole failure mode of this file. Names have no rank.
local function nameOf(id)
  if not (id and GetSpellInfo) then return nil end
  local name = GetSpellInfo(id)
  return name
end

local function buildBlizzMap()
  local map, names = {}, {}
  for _, prefix in ipairs(BLIZZ_BARS) do
    for i = 1, 12 do
      local button = _G[prefix .. i]
      if button then
        local slot = button.action
        if not slot and ActionButton_GetPagedID then slot = ActionButton_GetPagedID(button) end
        local id = spellInSlot(slot)
        if id then
          map[id] = map[id] or {}
          map[id][#map[id] + 1] = button
          local name = nameOf(id)
          if name then
            names[name] = names[name] or {}
            names[name][#names[name] + 1] = button
          end
        end
      end
    end
  end
  return map, names
end

-- Blizzard-scan buttons for an id, by id then by name.
local function blizzButtons(id)
  if not blizzMap then BarGlow.Rebuild() end
  if blizzMap[id] then return blizzMap[id] end
  local name = nameOf(id)
  return name and blizzByName and blizzByName[name] or nil
end

-- Bars change: the player drags a spell, pages a bar, edits a macro, or a stance swaps the whole
-- set. A stale map glows a button that no longer holds the spell, which is worse than not glowing.
function BarGlow.Invalidate()
  blizzMap, blizzByName = nil, nil
  -- Bars changed, so a spell we complained about may now be placed. Complaining again after that is
  -- correct; staying silent about a real regression is not.
  announced = {}
end

function BarGlow.Rebuild()
  blizzMap, blizzByName = buildBlizzMap()
  return blizzMap
end

local function providers()
  if not ns.API then return {} end
  local list = ns.API.GetProviders("barProviders") or {}
  return list
end

-- Returns the buttons, and (second) where they came from — "ElvUI", "blizzard", or nil. The source
-- is what makes `/elm debug bars` able to say WHICH link in the chain is empty; without it a silent
-- fallback to hidden Blizzard buttons looks exactly like a working provider.
function BarGlow.buttonsFor(spellKey)
  local id = spellIDFor(spellKey)
  if not id then return {}, nil end

  for _, p in ipairs(providers()) do
    if type(p.buttonsForSpell) == "function" then
      -- A provider reads another addon's internals; a change on their side must not take our
      -- display down with it.
      local ok, buttons = pcall(p.buttonsForSpell, id)
      if ok and type(buttons) == "table" then
        local visible = onlyOnScreen(buttons)
        if #visible > 0 then return visible, p.name or "provider" end
      end
    end
  end

  local fallback = onlyOnScreen(blizzButtons(id))
  if #fallback > 0 then return fallback, "blizzard" end
  return {}, nil
end

function BarGlow.keybindFor(spellKey)
  local id = spellIDFor(spellKey)
  if not id then return nil end

  for _, p in ipairs(providers()) do
    if type(p.keybindForSpell) == "function" then
      local ok, bind = pcall(p.keybindForSpell, id)
      if ok and type(bind) == "string" and bind ~= "" then return bind end
    end
  end

  local buttons = blizzButtons(id)
  local button = buttons and buttons[1]
  if button and button.HotKey then
    local text = button.HotKey:GetText()
    -- Blizzard parks an unbound button's hotkey text at this sentinel rather than clearing it.
    if text and text ~= "" and text ~= RANGE_INDICATOR then return text end
  end
  return nil
end

-- The whole chain, per spell, for `/elm debug bars`. Answering "is the bar glow working" needs four
-- separate facts — is a provider registered, does its library exist, did it find the spell, is that
-- button on screen — and every one of them fails silently on its own.
function BarGlow.describe(keys)
  local out = { providers = {}, rows = {} }
  for _, p in ipairs(providers()) do
    local row = { name = p.name or "?", priority = p.priority or 0,
                  buttonsForSpell = type(p.buttonsForSpell) == "function",
                  keybindForSpell = type(p.keybindForSpell) == "function" }
    if type(p.describe) == "function" then
      local ok, info = pcall(p.describe)
      if ok and type(info) == "table" then row.info = info end
    end
    out.providers[#out.providers + 1] = row
  end

  if not blizzMap then BarGlow.Rebuild() end
  local n = 0
  for _ in pairs(blizzMap) do n = n + 1 end
  out.blizzard = n

  for _, key in ipairs(keys or {}) do
    local id = spellIDFor(key)
    local buttons, source = BarGlow.buttonsFor(key)
    local first = buttons[1]
    local name
    if first and type(first.GetName) == "function" then
      local ok, got = pcall(first.GetName, first)
      if ok then name = got end
    end
    out.rows[#out.rows + 1] = {
      key = key, id = id, source = source, count = #buttons, button = name,
      bind = BarGlow.keybindFor(key),
    }
  end
  return out
end

-- Says, once per spell per session, that we could not find a button for the suggestion.
--
-- The bar glow is the channel that matters most — the queue tells you WHAT and the bar tells you
-- WHERE, and hunting your own bars is the work the addon is supposed to remove. Until now, failing
-- to find the button degraded silently to the queue icon: the most important output failed in the
-- way least likely to be noticed, which is how a rank mismatch survived an entire build.
--
-- Once per spell, not once per attempt: this is reached from the render path.
function BarGlow.noteMissing(spellKey)
  if not spellKey or announced[spellKey] then return false end
  announced[spellKey] = true
  local profileGlow = ns.db and ns.db.profile and ns.db.profile.glow
  if not (profileGlow and profileGlow.enabled and profileGlow.barGlow) then return false end
  if ns.log then
    ns.log("Elmira: no visible action-bar button holds %s, so only the queue icon can glow. "
        .. "/elm debug bars explains why.", tostring(spellKey))
  end
  return true
end

function BarGlow.resetAnnouncements()
  announced = {}
end

function BarGlow.stats()
  if not blizzMap then return { mapped = 0, providers = #providers(), built = false } end
  local n = 0
  for _ in pairs(blizzMap) do n = n + 1 end
  return { mapped = n, providers = #providers(), built = true }
end

ns.BarGlow = BarGlow
return BarGlow
