-- Elmira/Display/BarProviders.lua — one bar provider per LibActionButton-1.0 library on the client.
--
-- ElvUI and Bartender4 never needed separate integrations. Both build their buttons with
-- LibActionButton-1.0 — ElvUI ships a fork under its own major, Bartender4 uses the stock one — so
-- the seam that matters is "LAB-based or not", not "which bar addon". Everything here is stock LAB;
-- the only ElvUI-specific thing in the addon this replaced was the library NAME it looked up.
--
-- The library's own button list is authoritative in a way no frame-name scan can be: which buttons
-- exist depends on which bars the ACTIVE profile enables (the author's ElvUI profile turns on bars
-- 1-6 plus stance and pet, ElvUI's default is a subset — docs/07 §2). Guessing at
-- `ElvUI_Bar1Button1..12` would silently miss half of them.
--
-- A spell on no enabled bar degrades to no bar glow. That is a normal state — the player has not
-- placed it — not an error, and the queue strip still shows the suggestion.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local BarProviders = {}

-- Matched as a PREFIX so a fork nobody here has heard of (KkthnxUI, NDui, ls_Toolbar all ship one)
-- is picked up on its own merits rather than needing to be listed.
local LAB_PATTERN = "^LibActionButton%-1%.0"

-- Who owns a set of buttons, decided FROM THE BUTTONS rather than from the library major or from a
-- list of installed addons. The frame names are evidence; a fork we do not recognise then gets an
-- honest generic label instead of a confidently wrong specific one. This is what lets the options
-- panel say "Bartender4" without the code ever asking whether Bartender4 is installed.
local OWNERS = {
  { pattern = "^ElvUI_",              name = "ElvUI",      priority = 10 },
  { pattern = "^BT4Button",           name = "Bartender4", priority = 9 },
  { pattern = "^DominosActionButton", name = "Dominos",    priority = 8 },
}
local GENERIC = { name = "Action bars", priority = 5 }

local function byMajor(a, b) return a.major < b.major end

local function allButtons(lib)
  if not (lib and lib.GetAllButtons) then return nil end
  local ok, buttons = pcall(lib.GetAllButtons, lib)
  if not ok or type(buttons) ~= "table" then return nil end
  return buttons
end

local function ownerOf(buttons)
  for button in pairs(buttons or {}) do
    if type(button) == "table" and type(button.GetName) == "function" then
      local ok, name = pcall(button.GetName, button)
      if ok and type(name) == "string" then
        for _, owner in ipairs(OWNERS) do
          if name:match(owner.pattern) then return owner end
        end
      end
    end
  end
  return GENERIC
end

-- LAB buttons answer `:GetSpellId()` themselves, and that method understands every button type the
-- library supports — action slots, macros, and `Spell`-type buttons which have no action slot at
-- all. The hand-rolled `_state_type == "action"` walk this replaces dropped Spell-type buttons
-- entirely: they could never glow, and nothing reported it.
local function spellOf(button)
  if type(button) ~= "table" then return nil end
  if type(button.GetSpellId) == "function" then
    local ok, id = pcall(button.GetSpellId, button)
    if ok and type(id) == "number" and id > 0 then return id end
  end
  -- Fallback for a LAB old enough to lack GetSpellId. `_state_type`/`_state_action` are library
  -- internals, so every read is wrapped: a version that renames them must degrade to "no buttons
  -- found", never error into the display loop.
  local ok, kind, action = pcall(function() return button._state_type, button._state_action end)
  if not (ok and kind == "action" and action) then
    -- NOT `button.GetAction and button:GetAction()`: `and` truncates a call to its FIRST return
    -- value, and this one returns (type, action), so the fallback used to pass the string "action"
    -- onwards as if it were a slot number. Third time that exact shape has failed silently here.
    local ok2, kind2, action2 = pcall(button.GetAction, button)
    if not (ok2 and kind2 == "action" and action2) then return nil end
    action = action2
  end
  return ns.BarGlow and ns.BarGlow.spellInSlot(action) or nil
end

-- One provider's worth of state. Each library gets its own closure so two bar addons installed side
-- by side keep separate maps and separate `describe()` counts.
local function newProvider(major, lib)
  local map, byName

  -- Indexed by ID *and* by name. Classic has spell RANKS: every rank is a different spell id, the id
  -- on the bar is whichever rank the player dragged there, and the data pack carries exactly one id
  -- per ability. Matching on id alone silently misses a bar holding Exorcism (Rank 5) when the pack
  -- says Rank 6 — the glow fails for the spell the player presses most, and nothing reports it. The
  -- name is rank-free, so it is the reliable key.
  local function rebuild()
    map, byName = {}, {}
    for button in pairs(allButtons(lib) or {}) do
      local id = spellOf(button)
      if id then
        map[id] = map[id] or {}
        map[id][#map[id] + 1] = button
        local name = GetSpellInfo and GetSpellInfo(id)
        if name then
          byName[name] = byName[name] or {}
          byName[name][#byName[name] + 1] = button
        end
      end
    end
  end

  local function lookup(spellID)
    if not map then rebuild() end
    if map[spellID] then return map[spellID] end
    local name = GetSpellInfo and GetSpellInfo(spellID)
    return name and byName and byName[name] or nil
  end

  local owner = ownerOf(allButtons(lib))

  return {
    name = owner.name,
    priority = owner.priority,
    invalidate = function() map, byName = nil, nil end,
    buttonsForSpell = function(spellID)
      return lookup(spellID) or {}
    end,
    keybindForSpell = function(spellID)
      local buttons = lookup(spellID)
      local button = buttons and buttons[1]
      if not (button and button.HotKey) then return nil end
      local text = button.HotKey:GetText()
      -- Blizzard and ElvUI both park an unbound button's hotkey text at this sentinel rather than
      -- clearing it, so a naive read shows the range dot as if it were a keybind.
      if text and text ~= "" and text ~= RANGE_INDICATOR then return text end
      return nil -- mutants: equivalent falling off the end of a Lua function already answers nil
    end,
    -- Optional in the provider contract (docs/08). Separates the three ways this comes up empty:
    -- library missing, library present but holding no buttons (asked before the bars were built),
    -- and buttons present but none holding the spell (the player has not placed it).
    describe = function()
      local registered = 0
      for _ in pairs(allButtons(lib) or {}) do registered = registered + 1 end
      if not map then rebuild() end
      local mapped, named = 0, 0
      for _ in pairs(map or {}) do mapped = mapped + 1 end
      for _ in pairs(byName or {}) do named = named + 1 end
      return { library = major, present = lib ~= nil,
               buttons = registered, mapped = mapped, named = named }
    end,
  }
end

-- Every LibActionButton-1.0 major LibStub knows about. Sorted so two clients with the same set of
-- libraries register them in the same order; the registry then sorts by priority anyway, but a
-- deterministic input makes a `/elm debug bars` dump diffable against the last one.
function BarProviders.libraries()
  local out = {}
  if not (LibStub and type(LibStub.IterateLibraries) == "function") then return out end
  local ok, iter = pcall(LibStub.IterateLibraries, LibStub)
  if not ok or type(iter) ~= "table" then return out end
  for major, lib in pairs(iter) do
    if type(major) == "string" and major:match(LAB_PATTERN) then
      out[#out + 1] = { major = major, lib = lib }
    end
  end
  table.sort(out, byMajor)
  return out
end

-- Registers one provider per library found, and returns them so the caller can wire invalidation.
-- Safe to call more than once only in the sense that API.RegisterBarProvider refuses a duplicate
-- name — see the guard there, which exists because a stale companion addon left installed would
-- otherwise register a second provider on top of this one and silently win or lose at random.
function BarProviders.Register()
  local registered = {}
  local API = ns.API
  if not API then return registered end
  for _, entry in ipairs(BarProviders.libraries()) do
    local spec = newProvider(entry.major, entry.lib)
    if API.RegisterBarProvider(spec) then registered[#registered + 1] = spec end
  end
  return registered
end

-- Bar layout changed: drop every provider's map. Core owns the events (Core/Init.lua) so there is
-- one list, not one per provider — the old companion addon watched UPDATE_SHAPESHIFT_FORM while
-- core did not, so a stance swap cleared the provider's map and left core's Blizzard map stale.
-- Reading the API registry rather than a list of the providers this file built is the point: a
-- third-party provider registered through the public API used to own its own watcher frame, and
-- moving the events into core would otherwise leave it with none at all -- its map frozen at
-- whatever the bars looked like when it was first asked. `invalidate` is optional; a provider that
-- keeps no cache simply does not implement it.
function BarProviders.Invalidate()
  local API = ns.API
  for _, spec in ipairs(API and API.GetProviders("barProviders") or {}) do
    if type(spec.invalidate) == "function" then pcall(spec.invalidate) end
  end
end

-- The other direction: a provider that knows its bars changed tells US, so core drops its Blizzard
-- map and re-renders. `onLayoutChanged` has been in the documented contract since docs/08 was
-- written and had no caller in core until now -- the ElvUI companion implemented it and nothing
-- ever subscribed, which made it a function only a spec called.
function BarProviders.Subscribe(onChange)
  if type(onChange) ~= "function" then return 0 end
  local API = ns.API
  local wired = 0
  for _, spec in ipairs(API and API.GetProviders("barProviders") or {}) do
    if type(spec.onLayoutChanged) == "function" and pcall(spec.onLayoutChanged, onChange) then
      wired = wired + 1
    end
  end
  return wired
end

ns.BarProviders = BarProviders
return BarProviders
