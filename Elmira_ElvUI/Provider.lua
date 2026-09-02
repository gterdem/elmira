-- Elmira_ElvUI/Provider.lua — maps a spell to the ElvUI action buttons that hold it.
--
-- ElvUI's bars are LibActionButton buttons from its own bundled `LibActionButton-1.0-ElvUI`, so the
-- authoritative list is the library's, not a scan of frame names. That matters because the buttons
-- that exist depend on which bars the ACTIVE ElvUI profile enables — the author's profile turns on
-- bars 1-6 plus the stance and pet bars, while ElvUI's default is a subset (docs/07 §2). Anything
-- that guessed at `ElvUI_Bar1Button1..12` would silently miss half of them.
--
-- A spell on no enabled bar degrades to no bar glow. That is a normal state (the player simply has
-- not placed it), not an error, and the queue strip still shows the suggestion.
local ADDON = ...
local API = Elmira and Elmira.API
-- `## Dependencies: Elmira` makes core's presence an invariant, so reaching this branch means the
-- load order is broken, not that the user is missing an addon. Say so out loud: a `## LoadWith:`
-- line used to hoist this file ahead of core, and the silent `return` that lived here turned that
-- into an invisible no-op that cost a full in-game verification round at M0.
if not API or API.version < 1 then
  print("|cffC08CF0Elmira|r: |cffff2020" .. ADDON .. " loaded before Elmira core; bar provider not registered.|r")
  return
end

local map                    -- spellID -> { buttons }
local listeners = {}

local function LAB()
  return LibStub and LibStub("LibActionButton-1.0-ElvUI", true) or nil
end

-- `_state_type` / `_state_action` are LibActionButton internals, so every read is wrapped: a bundled
-- version that renames them must degrade to "no buttons found", never error into the display loop.
local function actionOf(button)
  local ok, kind, action = pcall(function() return button._state_type, button._state_action end)
  if ok and kind == "action" and action then return action end
  ok, action = pcall(function() return button.GetAction and button:GetAction() end)
  if ok and action then return action end
  return nil
end

local function spellOf(action)
  if not (action and GetActionInfo) then return nil end
  local kind, id = GetActionInfo(action)
  if kind == "spell" then return id end
  -- `#showtooltip` macros are common on paladin bars; only GetMacroSpell knows what one will cast.
  if kind == "macro" and GetMacroSpell then return (GetMacroSpell(id)) end
  return nil
end

local function rebuild()
  map = {}
  local lib = LAB()
  if not lib or not lib.GetAllButtons then return map end
  local ok, buttons = pcall(lib.GetAllButtons, lib)
  if not ok or type(buttons) ~= "table" then return map end
  for button in pairs(buttons) do
    local id = spellOf(actionOf(button))
    if id then
      map[id] = map[id] or {}
      map[id][#map[id] + 1] = button
    end
  end
  return map
end

local function invalidate()
  map = nil
  for _, cb in ipairs(listeners) do pcall(cb) end
end

local watcher = CreateFrame("Frame")
for _, event in ipairs({
  "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
  "UPDATE_MACROS", "PLAYER_ENTERING_WORLD", "UPDATE_SHAPESHIFT_FORM",
}) do
  watcher:RegisterEvent(event)
end
watcher:SetScript("OnEvent", invalidate)

API.RegisterBarProvider{
  name = "ElvUI",
  priority = 10,
  buttonsForSpell = function(spellID)
    if not spellID then return {} end
    if not map then rebuild() end
    return map[spellID] or {}
  end,
  keybindForSpell = function(spellID)
    if not spellID then return nil end
    if not map then rebuild() end
    local button = map[spellID] and map[spellID][1]
    if not (button and button.HotKey) then return nil end
    local text = button.HotKey:GetText()
    -- Blizzard and ElvUI both park an unbound button's hotkey text at this sentinel rather than
    -- clearing it, so a naive read shows the range dot as if it were a keybind.
    if text and text ~= "" and text ~= RANGE_INDICATOR then return text end
    return nil
  end,
  -- Optional in the provider contract (docs/08). Exists so `/elm debug bars` can distinguish the
  -- three ways this provider comes up empty: the library missing (ElvUI changed its bundled name),
  -- the library present but holding no buttons (asked before ElvUI built its bars), and buttons
  -- present but none of them holding the spell (the player has not placed it).
  describe = function()
    local lib = LAB()
    local registered = 0
    if lib and lib.GetAllButtons then
      local ok, buttons = pcall(lib.GetAllButtons, lib)
      if ok and type(buttons) == "table" then
        for _ in pairs(buttons) do registered = registered + 1 end
      end
    end
    if not map then rebuild() end
    local mapped = 0
    for _ in pairs(map or {}) do mapped = mapped + 1 end
    return { library = "LibActionButton-1.0-ElvUI", present = lib ~= nil,
             buttons = registered, mapped = mapped }
  end,
  onLayoutChanged = function(cb)
    if type(cb) == "function" then listeners[#listeners + 1] = cb end
  end,
}
