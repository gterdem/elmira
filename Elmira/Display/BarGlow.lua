-- Elmira/Display/BarGlow.lua — which on-screen buttons carry a given spell.
--
-- Two sources, in priority order:
--   1. Registered bar providers (docs/08 `API.RegisterBarProvider`). Display/BarProviders.lua
--      supplies one per LibActionButton-1.0 library on the client, which is how ElvUI and
--      Bartender4 are both covered; a provider knows its bar addon's internals far better than any
--      generic scan could. Third-party addons may register their own through the same API.
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
-- Spells we have already said we could not find a button for. Declared HERE, above every use: the
-- functions that read and clear it sit further up the file, and a `local` at the definition site
-- would leave those references resolving to a nil global — the exact shape that made Schema's
-- condition labels come back empty an hour ago.
--
-- FX1-D1: cleared by a button being FOUND (see `found` below), never by a bar event. It used to be
-- wiped by `BarGlow.Invalidate`, on the reasoning that changed bars may have placed the spell — but
-- Invalidate runs on ACTIONBAR_SLOT_CHANGED, UPDATE_SHAPESHIFT_FORM and five more
-- (Core/Init.lua), and on a paladin every aura swap fires one. The owner's log held FIVE copies of
-- the same "no button holds Divine Storm" line from one session, because the bars "changed" many
-- times per fight while nothing about them actually changed. The regression this latch must still
-- report -- a spell that HAD a button and lost it -- is now detected from the button, which is the
-- fact itself rather than a proxy for it.
local announced = {}

-- PREFIXES, to which 1..12 is appended below. This shipped without MultiBar5/6/7, which DO exist on
-- Classic Era 1.15 -- a spell on one of those bars was invisible to the fallback scan and simply
-- never glowed for anyone not running a LibActionButton bar addon.
--
-- The client also publishes `ActionButtonUtil.ActionBarButtonNames`, and preferring it would keep
-- this list current for free. It is NOT used, deliberately: nobody here has read that table on a
-- live 1.15 client, and if it holds full button NAMES rather than prefixes then appending an index
-- yields `ActionButton11`..`ActionButton112` and the scan silently maps nothing -- trading a list
-- that is merely out of date for one that is confidently wrong. Read it in game first (docs/07),
-- then switch if the shape is right.
local BLIZZ_BARS = {
  "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
  "MultiBarRightButton", "MultiBarLeftButton",
  "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}

local function spellIDFor(key)
  if type(key) ~= "string" then return nil end
  local pack = ns.Display and ns.Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  return data and data.id or nil
end

-- Resolves whatever sits in an action slot to a spell ID. Macros are the interesting case: a
-- `#showtooltip` macro reports as kind "macro" and only GetMacroSpell knows what it will cast.
function BarGlow.spellInSlot(slot)
  if not (slot and GetActionInfo) then return nil end
  local kind, id = GetActionInfo(slot)
  if kind == "spell" then return id end
  if kind == "macro" and GetMacroSpell then return (GetMacroSpell(id)) end
  return nil
end

-- Which action slot a button is showing. `ActionButton_GetPagedID` used to be the fallback here and
-- DOES NOT EXIST on Classic Era 1.15 (nor does ActionButton_CalculateAction) -- verified against the
-- whole client UI source, zero hits. It was guarded, so it never errored; it was simply a safety net
-- made of nothing. These three are the real chain: secure templates keep the paged slot on the
-- `action` attribute, plain frames keep it in the field, and `CalculateAction` is the method the
-- secure template itself uses.
local function slotOf(button)
  if type(button) ~= "table" then return nil end
  if type(button.GetAttribute) == "function" then
    local ok, slot = pcall(button.GetAttribute, button, "action")
    if ok and type(slot) == "number" then return slot end
  end
  if type(button.action) == "number" then return button.action end
  if type(button.CalculateAction) == "function" then
    local ok, slot = pcall(button.CalculateAction, button)
    if ok and type(slot) == "number" then return slot end
  end
  return nil -- mutants: equivalent falling off the end of a Lua function already answers nil
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
        local id = BarGlow.spellInSlot(slotOf(button))
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

-- FX1-D1. A button was found for this spell, so the next time it has none is NEWS again. Every
-- success path of `buttonsFor` goes through here rather than the callers being asked to remember:
-- the renderer, the diagnostic and the strip's size probe all ask the same question, and a latch
-- cleared at one call site and not the others is the silent half of this bug back again.
local function found(spellKey, buttons)
  announced[spellKey] = nil
  return buttons
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
        if #visible > 0 then return found(spellKey, visible), p.name or "provider" end
      end
    end
  end

  local fallback = onlyOnScreen(blizzButtons(id))
  if #fallback > 0 then return found(spellKey, fallback), "blizzard" end
  return {}, nil
end

-- PE10-D4. How big one of the player's real action buttons is ON SCREEN, in pixels, so the queue
-- strip can be scaled to match it. Returns the size and the spell key it was measured from, or nil
-- when none of the keys offered is on a visible bar -- which the caller must treat as "say so and
-- change nothing", never as a default.
--
-- `GetWidth` alone is the wrong reading and the reason this is not a one-liner at the call site: a
-- button reports its width in its OWN coordinate space, and every bar addon scales its bars. A
-- 32-wide button on a bar at 1.25 covers 40 screen pixels, and matching against the 32 would leave
-- the strip a fifth too small with no hint as to why.
function BarGlow.buttonSize(spellKeys)
  for _, key in ipairs(spellKeys or {}) do
    local buttons = BarGlow.buttonsFor(key)
    local button = buttons and buttons[1]
    if type(button) == "table" and type(button.GetWidth) == "function" then
      local ok, width = pcall(button.GetWidth, button)
      if ok and type(width) == "number" and width > 0 then
        local scale = 1
        if type(button.GetEffectiveScale) == "function" then
          local okScale, s = pcall(button.GetEffectiveScale, button)
          if okScale and type(s) == "number" and s > 0 then scale = s end
        end
        return width * scale, key
      end
    end
  end
  return nil
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

-- Says, once per spell, that we could not find a button for the suggestion — and not again until a
-- render finds one (FX1-D1).
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
  if not (profileGlow and profileGlow.barGlow) then return false end
  -- Routed as a warning (F37) rather than printed: the player decides whether this reaches chat,
  -- the screen or only the Log. The latch above stays -- it is per SPELL, which is finer than
  -- Announce's per-sentence one.
  --
  -- FX1-D2: the spell as the player knows it ("Divine Storm"), through the merged lookup every
  -- other sentence about an ability already uses. A log line reading DIVINE_STORM names an internal
  -- key nothing in the game is called, in the one message whose whole job is to send somebody to
  -- look at their action bars. The key remains the fallback, for a spell the client cannot name.
  local name = (ns.Display and ns.Display.spellName and ns.Display.spellName(spellKey))
    or tostring(spellKey)
  local text = string.format(
    "No visible action-bar button holds %s, so nothing can glow for it. /elm debug bars explains why.",
    name)
  if ns.Announce then
    ns.Announce.emit("warning", text)
  elseif ns.log then
    ns.log("%s", text)
  end
  return true
end

-- What `/elm debug perf` reports about the bar map.
--
-- `mapped` and `built` are about the BLIZZARD FALLBACK only, and the caller has to say so. Reported
-- as a bare "bar map: 0 spells, built=false" they read as "Elmira has mapped nothing", which is
-- what an owner saw while ElvUI was quite happily holding 43 mapped spells -- a diagnostic saying
-- the display was broken when it was working. With a provider active the fallback is SUPPOSED to
-- be unbuilt: nothing has needed it.
--
-- Deliberately does not build. `/elm debug bars` and the provider `describe()` both rebuild on
-- demand, which is right for a question about what WOULD be found; a performance report must not
-- change the thing it is measuring, or the two commands can never agree about the same session.
function BarGlow.stats()
  local n = 0
  if blizzMap then for _ in pairs(blizzMap) do n = n + 1 end end
  return { mapped = n, providers = #providers(), built = blizzMap ~= nil }
end

-- The client's name for a spell id, for the options panel to show instead of a symbolic key.
function BarGlow.spellName(id)
  -- pcall already covers a nil id and a client with no GetSpellInfo; a guard in front of it would
  -- only restate what the failure path does.
  local ok, name = pcall(function() return GetSpellInfo(id) end)
  return ok and name or nil
end

-- A button's frame name, for the diagnostic to quote back. Never trusted to exist: a provider may
-- hand back anything, and this is a diagnostic -- it must not be the thing that breaks.
local function buttonName(button)
  local ok, name = pcall(function() return button:GetName() end)
  return ok and name or nil
end

-- The chain behind "why is nothing glowing", as ordered rows a person can read.
--
-- `describe()` above answers the same question for a developer, in one dense dump; this answers it
-- for the player, and the difference that matters is SEPARATING the causes. "No glow" has half a
-- dozen distinct ones -- the spell is not on a bar, the button is on a page or stance you cannot
-- see, the bar glow is off, Elmira is switched off entirely, or Elmira is simply hidden right now
-- -- and each needs a different action. Collapsing them into "not found" is
-- what sends somebody to reinstall an addon that was never the problem.
--
-- Two rules this function is easy to get wrong, and did:
--   * It must agree with what actually glows. `buttonsFor` is the authority -- it walks providers in
--     priority order, skips any whose buttons are all hidden, and falls through to the Blizzard
--     scan. An independent walk that stopped at the first provider returning ANY button reported
--     "you cannot see that button" while the glow was working fine on a second bar addon.
--   * A green chain must mean a glow. Reporting every bar question green while the bar glow is off,
--     or while the queue is hidden out of combat, is the exact lie this panel exists to prevent.
--
-- Each row is { label, ok, detail }: ok true (passed), false (this is the problem) or nil (not
-- reached, because an earlier row failed). `detail` is DATA -- a name, a count, a mode -- never a
-- sentence: the words are Options' job and have to go through AceLocale.
function BarGlow.check(spellKey)
  local rows = {}
  local function row(label, ok, detail)
    rows[#rows + 1] = { label = label, ok = ok, detail = detail }
    return rows
  end

  local id = spellIDFor(spellKey)
  if not id then return row("spell", false), nil end

  -- The authority: the same call the renderer makes, so this cannot disagree with the glow.
  local visible, source = BarGlow.buttonsFor(spellKey)
  -- Which source ANSWERED for this spell when there is one, because that is the specific fact; the
  -- registered bar addon when nothing answered, because "blizzard" would then be reporting a
  -- fallback that did not actually supply anything either.
  local registered = providers()
  row("bars", true, source or (registered[1] and registered[1].name) or "blizzard")

  -- Unfiltered, and across EVERY provider plus the Blizzard scan, because "is it placed anywhere"
  -- and "can you see it right now" are the two questions this whole function exists to separate.
  local placed = 0
  for _, p in ipairs(registered) do
    if type(p.buttonsForSpell) == "function" then
      local ok, buttons = pcall(p.buttonsForSpell, id)
      if ok and type(buttons) == "table" then placed = placed + #buttons end
    end
  end
  placed = placed + #(blizzButtons(id) or {})

  if placed == 0 then
    row("placed", false)
    row("visible", nil)
    row("glow", nil)
    return rows, id
  end
  row("placed", true, placed)

  if #visible == 0 then
    row("visible", false)
    row("glow", nil)
    return rows, id
  end
  row("visible", true, buttonName(visible[1]))

  -- Everything above can pass while no glow happens, for three different reasons. Naming the wrong
  -- one is worse than naming none: the panel told a player to turn on a toggle that was already on.
  local p = ns.db and ns.db.profile
  if p and p.enabled == false then return row("glow", false, "addon"), id end
  if not (p and p.glow and p.glow.barGlow) then return row("glow", false, "bars"), id end
  row("glow", true)

  -- Last, and deliberately after the glow settings: being hidden is not a misconfiguration, it is
  -- the display doing what it was told. It still has to be said, because a green chain and a dark
  -- bar is exactly the report this panel exists to pre-empt.
  local shouldShow = ns.Display and ns.Display.shouldShow
  if type(shouldShow) == "function" then
    local shown, why = shouldShow()
    if shown == false then row("showing", false, why) end
  end
  return rows, id
end

ns.BarGlow = BarGlow
return BarGlow
