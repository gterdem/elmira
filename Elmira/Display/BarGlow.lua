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

local function buildBlizzMap()
  local map = {}
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
        end
      end
    end
  end
  return map
end

-- Bars change: the player drags a spell, pages a bar, edits a macro, or a stance swaps the whole
-- set. A stale map glows a button that no longer holds the spell, which is worse than not glowing.
function BarGlow.Invalidate()
  blizzMap = nil
end

function BarGlow.Rebuild()
  blizzMap = buildBlizzMap()
  return blizzMap
end

local function providers()
  if not ns.API then return {} end
  local list = ns.API.GetProviders("barProviders") or {}
  return list
end

function BarGlow.buttonsFor(spellKey)
  local id = spellIDFor(spellKey)
  if not id then return {} end

  for _, p in ipairs(providers()) do
    if type(p.buttonsForSpell) == "function" then
      -- A provider reads another addon's internals; a change on their side must not take our
      -- display down with it.
      local ok, buttons = pcall(p.buttonsForSpell, id)
      if ok and type(buttons) == "table" and #buttons > 0 then return buttons end
    end
  end

  if not blizzMap then BarGlow.Rebuild() end
  return blizzMap[id] or {}
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

  if not blizzMap then BarGlow.Rebuild() end
  local buttons = blizzMap[id]
  local button = buttons and buttons[1]
  if button and button.HotKey then
    local text = button.HotKey:GetText()
    -- Blizzard parks an unbound button's hotkey text at this sentinel rather than clearing it.
    if text and text ~= "" and text ~= RANGE_INDICATOR then return text end
  end
  return nil
end

function BarGlow.stats()
  if not blizzMap then return { mapped = 0, providers = #providers(), built = false } end
  local n = 0
  for _ in pairs(blizzMap) do n = n + 1 end
  return { mapped = n, providers = #providers(), built = true }
end

ns.BarGlow = BarGlow
return BarGlow
