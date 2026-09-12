-- tests/wow_mock.lua — WoW client mock for ADAPTER tests only. Core specs must never load this
-- (docs/04): Core is pure Lua and a Core test that needs a client global is a hard-rule-3 violation
-- showing up as a test dependency.
--
-- This file writes into `_G`, so state leaks between specs unless `reset()` is called. Every spec
-- that loads it must call `mock.reset()` in before_each — `tests/spec/wow_mock_spec.lua` exists
-- precisely because until M2 nothing loaded this file at all, making it an untested harness that the
-- adapter specs were about to trust. A mock that lies produces green tests over a broken adapter.
--
-- Return values follow the Classic Era (1.15.x) signatures in the wow-addon-dev API cheat sheet, and
-- where the live client surprised us, THIS MOCK COPIES THE CLIENT, not the documentation. See
-- `GetSpellCooldown` (returns the GCD during the GCD) and `GetTalentTabInfo` (does not return the
-- name first) below — both verified in game, both recorded in docs/07 §9.
local M = {}

-- Defaults live here so reset() is a single assignment and can never drift from the initial state.
local function defaults()
  return {
    time = 0,
    cooldowns = {},          -- [spellID] = { start, duration }
    gcdActive = false,       -- when true, GetSpellCooldown reports the GCD for spells with no real CD
    castTimes = {},          -- [spellID] = milliseconds
    knownSpells = {},        -- [spellID] = true; nil means "not known"
    -- [spellID] = name. Classic has RANKS: several ids share one name, and that is precisely what
    -- lets a bar hold Rank 5 while the data pack ships Rank 6. Without this the mock gave every id a
    -- unique name, so a rank mismatch was unrepresentable and the bar-glow bug it causes could not
    -- be written as a test. Defaults to "Spell<id>" when unset, so existing specs are unaffected.
    spellNames = {},
    powerCosts = {},         -- [spellID] = amount (mana)
    auras = { player = {}, target = {} },
    power = { [0] = { 1000, 1000 } },
    comboPoints = 0,   -- GetComboPoints(unit, "target"); R2 D59, classic-only, not part of `power`
    inventory = {},          -- [slot] = itemID
    itemLinks = {},          -- [slot] = link string
    tooltipLines = {},       -- [slot] = { "line", ... }  (LEFT column)
    tooltipRight = {},       -- [slot] = { "line", ... }  (RIGHT column, same line numbers)
    itemInfo = {},           -- [itemID] = { name, equipLoc, speed }
    runes = {},              -- [slot] = { name =, learnedAbilitySpellIDs = {...} }
    engravingEnabled = true,
    creatureType = nil,
    attackSpeed = { 2.1, nil },
    level = 60,
    class = "PALADIN",
    talentTabs = { { 382, 31 }, { 383, 0 }, { 381, 20 } }, -- Arthorion's real spread, docs/07 §9.7
    speed = 0,
    health = { 100, 100 },
    inCombat = false,
    affectingCombat = false,   -- UnitAffectingCombat: the real "is the player fighting" answer
    targetExists = true,       -- was hardcoded true, so "no target" could never be tested
    -- PE9-D6: UnitCanAttack. Separate from targetExists because that is the whole point -- a bank
    -- NPC exists and cannot be attacked, and the visibility rule has to be able to tell them apart.
    targetAttackable = true,
    -- PE9-D2: the SECOND value IsUsableSpell returns (`noMana`). [spellID] = true means the spell
    -- is unusable for a resource reason rather than a range one.
    noMana = {},
    itemCooldowns = {},        -- [slot] = { start, duration }; was hardcoded (0,0)
    -- Weapon tooltips live in tooltipLines too; base speed is only readable there.
    -- World-server round trip in ms, what GetNetStats reports 4th. Non-zero by default would make
    -- every swing spec depend on it silently, so it starts at 0 and a spec that cares sets it.
    latency = 0,
    actionInfo = {},           -- [slot] = { kind, id }, e.g. {"spell", 415073} or {"macro", 3}
    macroSpells = {},          -- [macroIndex] = spellID; nil means the macro resolves to nothing
    -- [i] = { name =, memory =, pendingMemory =, metadata = { [field] = value }, load = { loaded, reason } }.
    -- `memory` is the STALE snapshot GetAddOnMemoryUsage reports until UpdateAddOnMemoryUsage() copies
    -- `pendingMemory` into it — the client only refreshes these figures on request, which is exactly
    -- the trap `/elm debug perf` exists to not fall into. A spec that never sets `pendingMemory` sees
    -- `memory` unchanged either way. `metadata`/`load` back GetAddOnMetadata/LoadAddOn for
    -- Vanilla.loadClassPack's `X-Elmira-Class` scan (ADR-0011 §3); an addon entry with neither set
    -- behaves as one with no TOC metadata and a bare successful load, matching an addon nobody asked
    -- anything of.
    addons = {},
  }
end

local GCD = 1.5

-- Keys whose default is nil. `pairs()` skips nil values, so a plain copy of defaults() can never
-- clear them and a value set by one spec survives into the next — which is exactly how a stale
-- creatureType made an adapter spec see "Undead" after asking for no target. Nil defaults must be
-- erased explicitly, not assigned.
local NIL_DEFAULTS = { "creatureType" }

function M.reset()
  for _, key in ipairs(NIL_DEFAULTS) do M[key] = nil end
  for key, value in pairs(defaults()) do M[key] = value end
  return M
end

-- Convenience: makes a spell known AND gives it a cooldown/cost in one call, so a spec's intent
-- reads as one line instead of three assignments that can fall out of sync.
function M.spell(id, opts)
  opts = opts or {}
  M.knownSpells[id] = opts.known ~= false
  if opts.cooldown then M.cooldowns[id] = { opts.start or M.time, opts.cooldown } end
  if opts.cost then M.powerCosts[id] = opts.cost end
  if opts.castTime then M.castTimes[id] = opts.castTime end
end

function GetTime() return M.time end

-- Verified in game (docs/07 §9.10): this returns the GLOBAL cooldown for any spell while the GCD is
-- running, not that spell's own cooldown. An adapter that caches the return blindly records 1.5 s as
-- Exorcism's cooldown. The mock reproduces the trap so a spec can prove the filter works.
function GetSpellCooldown(id)
  local c = M.cooldowns[id]
  if c then return c[1], c[2], 1 end
  if M.gcdActive then return M.time, GCD, 1 end
  return 0, 0, 1
end

-- Two returns, like the client: `usable, noMana`. The second used to be a flat `false` here, which
-- made the out-of-mana case unrepresentable -- so a mock that lied was the reason a strip could
-- confidently suggest a spell you could not pay for.
function IsUsableSpell(id)
  local noMana = M.noMana[id] == true
  return M.knownSpells[id] == true and not noMana, noMana
end
function IsPlayerSpell(id) return M.knownSpells[id] == true end
function IsSpellKnown(id) return M.knownSpells[id] == true end

-- Takes an id OR a name, matching the real client (Vanilla.spellIDByName relies on the latter).
-- Field 2 (rank) is absent on this client — docs/07 §9.6. Field 7 (spellID) is real: three
-- independent addons on the live install destructure it this way (see Adapters/Vanilla.lua's
-- S:power COMBO_POINTS comment for the exact file:line citations of the same client sweep).
function GetSpellInfo(idOrName)
  local id = idOrName
  if type(idOrName) == "string" then
    id = nil
    -- Case-INSENSITIVE, like the real client's name cache: this is what lets a spec prove
    -- Vanilla.spellIDByName's exact-match check earns its keep, by querying "exorcism" and getting
    -- back the CANONICALLY-cased "Exorcism" rather than nothing at all.
    for sid, sname in pairs(M.spellNames) do
      if sname:lower() == idOrName:lower() then id = sid; break end
    end
  end
  if id == nil or M.knownSpells[id] == nil then return nil end
  return M.spellNames[id] or ("Spell" .. tostring(id)), nil, nil, M.castTimes[id] or 0, nil, nil, id
end

-- Returns a LIST of cost tables, not a bare number. Reflects runes on the live client (345 -> 69
-- measured), which is why the adapter may call it directly instead of shipping a static table.
function GetSpellPowerCost(id)
  local cost = M.powerCosts[id]
  if not cost then return {} end
  return { { cost = cost, type = 0, name = "MANA" } }
end

function UnitAura(unit, i, filter)
  local list = M.auras[unit] or {}
  local a = list[i]
  if not a then return nil end
  return a.name, nil, a.count or 1, nil, a.duration or 10, (a.expires or M.time + 10),
         a.source or "player", nil, nil, a.spellID
end

AuraUtil = {
  FindAuraByName = function(name, unit, filter)
    for i = 1, 40 do
      local auraName = UnitAura(unit, i, filter)
      if not auraName then return nil end
      if auraName == name then return UnitAura(unit, i, filter) end
    end
    return nil
  end,
}

function UnitPower(u, kind) return M.power[kind or 0][1] end
function UnitPowerMax(u, kind) return M.power[kind or 0][2] end
-- Classic-only global (R2 D59): current combo points, read the same way three independent addons on
-- the live install read it -- see Adapters/Vanilla.lua's S:power COMBO_POINTS comment.
function GetComboPoints(unit, target) return M.comboPoints or 0 end
-- The FrameXML constant, not a client-state value: real WoW never changes it mid-session, so it is
-- a plain global here too rather than something `M.reset()` touches -- a spec that needs to prove
-- the "not 0" guard sets `_G.MAX_COMBO_POINTS` directly and restores it itself, the same pattern
-- already used for `_G.GetSpellInfo` elsewhere in this suite.
MAX_COMBO_POINTS = 5
function UnitCreatureType(u) return M.creatureType end
function UnitExists(u)
  if u == "target" then return M.targetExists end
  return true
end
-- Answers false when there is no target at all, exactly as the client does -- which is what lets
-- the adapter use this one reading instead of pairing it with UnitExists.
function UnitCanAttack(unit, other)
  if other ~= "target" then return true end
  return M.targetExists == true and M.targetAttackable == true
end
function UnitHealth(u) return M.health[1] end
function UnitHealthMax(u) return M.health[2] end
function UnitLevel(u) return M.level end
function UnitClass(u) return "ClassName", M.class end
function GetUnitSpeed(u) return M.speed end
function GetInventoryItemID(u, slot) return M.inventory[slot] end
function GetInventoryItemLink(u, slot) return M.itemLinks[slot] end
function UnitAttackSpeed(u) return M.attackSpeed[1], M.attackSpeed[2] end
function GetInventoryItemCooldown(u, slot)
  local c = M.itemCooldowns[slot]
  if c then return c[1], c[2] end
  return 0, 0
end
function IsUsableItem(id) return true end

-- BarGlow's Blizzard-scan fallback (Elmira/Display/BarGlow.lua): `type, id = GetActionInfo(slot)`.
-- Only "spell" and "macro" kinds matter to the addon; the mock does not model the rest (item, etc.).
-- Written through `_G.` rather than as a bare global function: these three are not in the
-- `tests/` luacheck globals allowlist (.luacheckrc lives outside tests/, out of bounds for this
-- change), and an explicit `_G.` field assignment is not a "setting non-standard global variable"
-- warning the way an implicit bare assignment is.
_G.GetActionInfo = function(slot)
  local info = M.actionInfo[slot]
  if not info then return nil end
  return info[1], info[2]
end

-- A `#showtooltip` macro's resolved spell id, or nil if it casts nothing this addon recognises.
_G.GetMacroSpell = function(index)
  return M.macroSpells[index]
end

-- Blizzard parks an unbound button's hotkey text at this sentinel string instead of clearing it
-- (docs/07 verified equivalent, see BarGlow.lua's own comment). Any plain non-empty placeholder
-- serves the mock; the real client's exact glyph is not something a headless spec can compare.
_G.RANGE_INDICATOR = "RANGE_INDICATOR_SENTINEL"
function InCombatLockdown() return M.inCombat end
-- Distinct from lockdown on purpose: the adapter must use this one, and a mock that aliased them
-- would let the wrong API keep passing. `combatLockdown` defaults to inCombat unless a spec splits
-- them, which is the case that reproduces PLAYER_REGEN_DISABLED firing before lockdown is set.
function UnitAffectingCombat(unit) return M.affectingCombat end

function GetItemInfo(id)
  local info = M.itemInfo[id]
  if not info then return nil end
  -- Real signature has itemEquipLoc at 9 and speed nowhere; specs read what the adapter reads.
  return info.name, nil, nil, nil, nil, nil, nil, nil, info.equipLoc, nil, nil, nil, nil, nil, nil,
         nil, nil
end

-- Verified in game (docs/07 §9.8): this does NOT return the name first. Position 1 held a numeric tab
-- id (382 Holy / 383 Prot / 381 Ret) and points spent were in position 5. The mock copies the client,
-- so any code written against the documented shape fails here rather than in game.
function GetTalentTabInfo(tab)
  local t = M.talentTabs[tab]
  if not t then return nil end
  return t[1], nil, nil, nil, t[2]
end

C_Engraving = {
  IsEngravingEnabled = function() return M.engravingEnabled end,
  GetRuneForEquipmentSlot = function(slot) return M.runes[slot] end,
  RefreshRunesList = function() end,
}

-- ---------------------------------------------------------------- frames and regions
--
-- A frame here answers the WoW frame API for real, not with a no-op: it remembers its anchors, its
-- textures and font strings, its children, its scripts -- and, above all, it FIRES OnShow/OnHide
-- when its shown state actually changes, exactly as the client does (and, as the client does, not
-- when Hide() is called on something already hidden).
--
-- That last line is not decoration. AceGUI's Frame container wires `frame:SetScript("OnHide",
-- Frame_OnClose)` (AceGUIContainer-Frame.lua:28-30, 195), so HIDING the options window is what runs
-- AceConfigDialog's whole close path -- clearing OpenFrames and handing the widget back to the
-- shared pool. A mock that hid quietly could not reach that path at all, which is how a window that
-- comes back stripped of its title bar passes a green suite (FX2).
--
-- Anything NOT modelled here still answers, but only for a name that starts with a capital letter:
-- every WoW frame method does, and nothing else may, or `frame.elmiraVersion` on a frame that has
-- never had one would come back as a function and read as "already created".
local function noop() end
local frameMeta = { __index = function(_, key)
  if type(key) == "string" and key:match("^%u") then return noop end
  return nil
end }

-- The half of the API a texture and a font string share with a frame. Anchors are stored the way
-- GetPoint hands them back, because restoring an anchor byte for byte is exactly what
-- Options.Undecorate does with them.
local function newRegion(kind, parent)
  local r = { __points = {}, __shown = true, __parent = parent }
  function r:GetObjectType() return kind end
  function r:GetParent() return self.__parent end
  function r:SetParent(p) self.__parent = p end
  function r:ClearAllPoints() self.__points = {} end
  function r:SetPoint(...) self.__points[#self.__points + 1] = { ... } end
  function r:GetNumPoints() return #self.__points end
  function r:GetPoint(i) return unpack(self.__points[i or 1] or {}) end
  function r:SetAllPoints(other) self.__allPoints = other end
  function r:SetWidth(v) self.__width = v end
  function r:SetHeight(v) self.__height = v end
  function r:SetSize(w, h) self.__width, self.__height = w, h end
  function r:GetWidth() return self.__width or 0 end
  function r:GetHeight() return self.__height or 0 end
  -- AceGUI sizes a Button from its label (AceGUIWidget-Button.lua:51); any monotonic answer will do.
  function r:GetStringWidth() return #tostring(self.__text or "") * 6 end
  function r:SetTexture(t) self.__texture = t end
  function r:GetTexture() return self.__texture end
  -- A solid-colour texture rather than a file, e.g. the dark plate under an indicator's art or a
  -- gold selection border. Four returns, matching the real client (r, g, b, a).
  function r:SetColorTexture(cr, cg, cb, ca) self.__colorTexture = { cr, cg, cb, ca } end
  function r:GetColorTexture() local c = self.__colorTexture or {}; return c[1], c[2], c[3], c[4] end
  function r:SetText(t) self.__text = t end
  function r:GetText() return self.__text end
  function r:Show() self.__shown = true end
  function r:Hide() self.__shown = false end
  function r:SetShown(v) self.__shown = v and true or false end
  function r:IsShown() return self.__shown and true or false end
  -- Visibility, unlike shown-ness, walks up the parents: a region on a hidden frame is not visible.
  function r:IsVisible()
    local node = self
    while node do
      if not node.__shown then return false end
      node = node.__parent
    end
    return true
  end
  return setmetatable(r, frameMeta)
end

-- A scanning tooltip: CreateFrame("GameTooltip", name, ...) must also publish the per-line font
-- strings as globals, because that is the only way Classic exposes tooltip text.
function CreateFrame(frameType, name, parent, template)
  local frame = newRegion(frameType or "Frame", parent)
  -- A frame starts hidden, the way CreateFrame hands one back, so the first Show() is a real
  -- transition and fires OnShow.
  frame.__shown = false
  frame.__regions, frame.__children = {}, {}
  local lines = {}
  function frame:GetName() return name end
  function frame:CreateTexture()
    local t = newRegion("Texture", self)
    self.__regions[#self.__regions + 1] = t
    return t
  end
  function frame:CreateFontString()
    local fs = newRegion("FontString", self)
    self.__regions[#self.__regions + 1] = fs
    return fs
  end
  -- A button built from a template already owns its label (AceGUI reads it back rather than making
  -- one, AceGUIWidget-Button.lua:85).
  function frame:GetFontString()
    if not self.__fontString then self.__fontString = self:CreateFontString() end
    return self.__fontString
  end
  -- Frame levels are real numbers, not no-ops: AceGUI stacks a dropdown's pullout one level above
  -- the control (AceGUIWidget-DropDown.lua:451) and does ARITHMETIC on what it reads back, so a
  -- frame that answers nil takes the widget's own constructor down.
  function frame:SetFrameLevel(v) self.__level = v end
  -- Counted, not swallowed: "this window opened above the one that was already there" is the only
  -- difference between a button that works and one that looks like it did nothing.
  function frame:Raise() self.__raised = (self.__raised or 0) + 1 end
  function frame:GetFrameLevel() return self.__level or 1 end
  function frame:GetRegions() return unpack(self.__regions) end
  function frame:GetChildren() return unpack(self.__children) end
  function frame:GetNumChildren() return #self.__children end
  -- ScrollFrame's own surface: EnableMouseWheel/SetScrollChild are real client calls a scroll
  -- frame answers regardless of type; the vertical getters/setters are what a widget built
  -- straight on `CreateFrame("ScrollFrame", ...)` (rather than through an AceGUI container) reads
  -- and writes. `GetVerticalScrollRange` is a TEST LEVER, not a real layout computation -- the
  -- client derives it from the scroll child's height, which nothing here lays out for real; a
  -- spec sets `frame.__scrollRange` directly to say what the range is for its own scenario.
  function frame:EnableMouseWheel(v) self.__mouseWheelEnabled = v and true or false end
  function frame:IsMouseWheelEnabled() return self.__mouseWheelEnabled == true end
  function frame:SetScrollChild(child) self.__scrollChild = child end
  function frame:GetScrollChild() return self.__scrollChild end
  function frame:SetVerticalScroll(v) self.__vScroll = v end
  function frame:GetVerticalScroll() return self.__vScroll or 0 end
  function frame:GetVerticalScrollRange() return self.__scrollRange or 0 end
  -- The three state textures are objects in the client, not the values that were set: AceConfigDialog
  -- sets one and immediately calls SetTexCoord on what it gets back (AceConfigDialog-3.0.lua:589).
  local function stateTexture(self, which)
    self.__stateTextures = self.__stateTextures or {}
    if not self.__stateTextures[which] then self.__stateTextures[which] = newRegion("Texture", self) end
    return self.__stateTextures[which]
  end
  for _, which in ipairs({ "Normal", "Pushed", "Highlight", "Disabled" }) do
    frame["Set" .. which .. "Texture"] = function(self, v) stateTexture(self, which):SetTexture(v) end
    frame["Get" .. which .. "Texture"] = function(self) return stateTexture(self, which) end
  end
  -- Real RegisterEvent/SetScript bookkeeping, not the generic no-op fallback below: without this,
  -- a frame-driven watcher (`watcher:SetScript("OnEvent", fn)`)
  -- cannot be proven wired at all — the call would succeed silently whether or not it did anything.
  local scripts, registered = {}, {}
  function frame:RegisterEvent(event) registered[event] = true end
  function frame:UnregisterEvent(event) registered[event] = nil end
  function frame:IsEventRegistered(event) return registered[event] == true end
  function frame:SetScript(event, handler) scripts[event] = handler end
  function frame:GetScript(event) return scripts[event] end
  -- The real HookScript APPENDS: the original handler still runs, and the new one runs after it. A
  -- fake that replaced would let a SetScript -- which deletes whatever AceGUI installed there --
  -- pass, and one-handler-per-name is the rule that has already cost this addon two outages.
  function frame:HookScript(event, handler)
    local prior = scripts[event]
    scripts[event] = function(...)
      if prior then prior(...) end
      return handler(...)
    end
  end
  -- Show/Hide fire OnShow/OnHide, and only on a real change of state -- the client's own rule, and
  -- the one that makes hiding the options window run AceGUI's OnClose chain.
  function frame:Show()
    if self.__shown then return end
    self.__shown = true
    if scripts.OnShow then scripts.OnShow(self) end
  end
  function frame:Hide()
    if not self.__shown then return end
    self.__shown = false
    if scripts.OnHide then scripts.OnHide(self) end
  end
  function frame:SetShown(v) if v then self:Show() else self:Hide() end end
  -- Button:Click() runs OnClick whatever the button's visibility -- which is load-bearing here:
  -- Elmira hides AceGUI's stock Close button and its own X clicks the hidden one, so that
  -- AceConfigDialog's FrameOnClose still clears OpenFrames and releases the widget to the pool.
  function frame:Click(button, down)
    local handler = scripts.OnClick
    if handler then return handler(self, button or "LeftButton", down or false) end
  end
  -- NOT a real WoW frame method. A spec-only hook to simulate the client delivering a REGISTERED
  -- event to this frame, mirroring how the client actually dispatches: every event, whichever one
  -- fired, is delivered through the single "OnEvent" script (not a script named after the event),
  -- and only if RegisterEvent(event) was called. A frame that never registered `event` stays quiet,
  -- same as in game.
  function frame:Fire(event, ...)
    if not registered[event] then return end
    local handler = scripts.OnEvent
    if handler then return handler(frame, event, ...) end
  end
  function frame:SetOwner() end
  function frame:ClearLines() lines = {} end
  function frame:NumLines() return #lines end
  -- Models BOTH columns, because the client does: a weapon's "Speed 2.10" is right-column text on
  -- the same line as its damage range. Modelling only the left let a left-only parse pass its test
  -- and then find nothing in game. `tooltipLines[slot]` is the left column; `tooltipRight[slot]` the
  -- right, indexed by the same line number.
  function frame:SetInventoryItem(unit, slot)
    lines = M.tooltipLines[slot] or {}
    local right = M.tooltipRight[slot] or {}
    if name then
      for i = 1, 40 do
        local l, r = lines[i], right[i]
        _G[name .. "TextLeft" .. i] = l and { GetText = function() return l end } or nil
        _G[name .. "TextRight" .. i] = r and { GetText = function() return r end } or nil
      end
    end
  end
  -- A child is reachable from its parent, which is how AceGUI's stock Close button and the title
  -- drag bar are found at all (both are anonymous; ElvUI identifies the first by its text,
  -- Config.lua:1441-1447, and Elmira finds the second by the script it carries).
  if parent and rawget(parent, "__children") then
    parent.__children[#parent.__children + 1] = frame
  end
  -- UIDropDownMenuTemplate publishes five children under the PARENT frame's name, and AceGUI's
  -- Dropdown widget reads all five straight out of _G and anchors them
  -- (AceGUIWidget-DropDown.lua:685-716) -- so a template that hands back nothing is a widget that
  -- errors in its own constructor. Only the names matter here; what they draw does not.
  if name and template and tostring(template):find("UIDropDownMenuTemplate", 1, true) then
    for _, part in ipairs({ "Left", "Middle", "Right" }) do
      _G[name .. part] = frame:CreateTexture()
    end
    _G[name .. "Text"] = frame:CreateFontString()
    _G[name .. "Button"] = CreateFrame("Button", name .. "Button", frame)
  end
  -- Named frames are reachable by name, because that is the whole contract UISpecialFrames rests on:
  -- the client's Escape closes frames by GLOBAL NAME, so a frame that never published its own could
  -- not be closed by Escape in a spec any more than in game.
  if name then _G[name] = frame end
  -- NOT a real WoW global. A file that builds its own event-watcher frame at load time (e.g.
  -- a bar provider's own watcher frame) gives a spec no other handle on it; the cheapest way to
  -- reach "the frame that file just made" without inventing a return value CreateFrame never has.
  _G.__lastFrame = frame
  return frame
end

-- down, up, lagHome, lagWorld. Only the 4th is ever read: home latency is the chat/realm server and
-- has nothing to do with when a swing lands.
function GetNetStats() return 0, 0, 0, M.latency end

-- Per-addon memory (KB), as read by Vanilla.addonMemoryKB. Classic Era exposes these as bare
-- globals; `C_AddOns.*` below mirrors the same DATA rather than delegating to the bare-global names,
-- so a spec can nil out the bare globals and prove the adapter's `C_AddOns.*` fallback path works on
-- its own, not merely by forwarding to a global that test just removed.
local function updateAddOnMemoryUsage()
  for _, a in ipairs(M.addons) do
    if a.pendingMemory ~= nil then a.memory = a.pendingMemory end
  end
end

local function getAddOnMemoryUsage(i)
  local a = M.addons[i]
  return a and a.memory or 0
end

function UpdateAddOnMemoryUsage() updateAddOnMemoryUsage() end
function GetAddOnMemoryUsage(i) return getAddOnMemoryUsage(i) end

-- By NAME, matching the real API (and Vanilla.loadClassPack's own call shape: it resolves a name via
-- GetAddOnInfo(i) first, then asks GetAddOnMetadata(name, field) — never GetAddOnMetadata(i, field)).
local function findAddonByName(name)
  for _, a in ipairs(M.addons) do
    if a.name == name then return a end
  end
  return nil
end

-- AT4-D2: IsAddOnLoaded, in both of the spellings the adapter accepts. `loaded` is a field a
-- fixture sets on an entry; an addon that is merely listed is INSTALLED but not loaded, which is
-- the distinction the texture library rests on -- a disabled WeakAuras has handed the client no
-- files, so offering its paths would draw a grid of nothing.
local function isAddOnLoaded(name)
  local a = findAddonByName(name)
  return (a and a.loaded == true) or false
end

function IsAddOnLoaded(name) return isAddOnLoaded(name) end

C_AddOns = {
  IsAddOnLoaded = function(name) return isAddOnLoaded(name) end,
  GetNumAddOns = function() return #M.addons end,
  GetAddOnInfo = function(i)
    local a = M.addons[i]
    return a and a.name or nil
  end,
  UpdateAddOnMemoryUsage = function() updateAddOnMemoryUsage() end,
  GetAddOnMemoryUsage = function(i) return getAddOnMemoryUsage(i) end,
  GetAddOnMetadata = function(name, field)
    local a = findAddonByName(name)
    return a and a.metadata and a.metadata[field] or nil
  end,
  -- Defaults to a plain success when a fixture named an addon but never configured `load`, so a spec
  -- only needs to set `load` when it cares about a specific failure reason.
  LoadAddOn = function(name)
    local a = findAddonByName(name)
    if not a then return nil, "MISSING" end
    local load = a.load or { true, nil }
    return load[1], load[2]
  end,
}

UIParent = {}
Enum = { PowerType = { Mana = 0, Rage = 1, Energy = 3 } }
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2

-- The Ace3 surface below is for specs that load the REAL vendored Ace3 libraries (Elmira/Libs/) --
-- e.g. tests/spec/init_spec.lua, which is Core/Init.lua's composition root and the one file
-- permitted to touch LibStub. Everything here is what those libraries read at their own file scope
-- or on every call; none of it is Elmira-specific behaviour, so faking it here (rather than in the
-- spec) is mirroring the client, not inventing a fixture that asserts the spec's own assumptions.
-- LibStub itself expects this WoW string-library alias (`strmatch(minor, "%d+")` in NewLibrary).
strmatch = string.match
-- The client's table/string extensions, which Ace3 uses as bare globals and as string METHODS
-- (AceGUIContainer-TreeGroup.lua:530 does `("\001"):split(uniquevalue)`, i.e. separator first).
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
table.wipe = wipe
function strsplit(sep, str)
  local out, escaped = {}, sep:gsub("(%W)", "%%%1")
  for piece in (str .. sep):gmatch("([^" .. escaped .. "]*)" .. escaped) do out[#out + 1] = piece end
  return unpack(out)
end
string.split = strsplit
-- WoW's xpcall forwards the extra arguments to `func`; stock Lua 5.1's does not. Ace3's `safecall`
-- captures `xpcall` as a FILE-SCOPE upvalue (AceGUI-3.0.lua:58, AceConfigDialog-3.0.lua:37), so a
-- spec that loads the real libraries has to install this before they load -- which is exactly when
-- the client installs its own. Handed out rather than written into _G: busted's own machinery runs
-- on the stock one, and every callback Ace3 fires would arrive with a nil `self` without it.
function M.wowXpcall(f, handler, ...)
  local args, n = { ... }, select("#", ...)
  return xpcall(function() return f(unpack(args, 1, n)) end, handler)
end
function geterrorhandler() return function(err) return err end end
function IsLoggedIn() return true end
function GetLocale() return "enUS" end
-- AceDB-3.0 builds its per-character/per-realm/per-faction profile keys from these at file scope.
-- Values are fixed and arbitrary (no spec depends on a particular realm/race/faction), unlike
-- `M.class`, which adapter specs do depend on and which already has its own real accessor above.
function GetRealmName() return "TestRealm" end
function UnitName(u) return "TestChar" end
function UnitRace(u) return "Human", "Human" end
function UnitFactionGroup(u) return "Alliance" end
function GetCurrentRegion() return 1 end
function GetCurrentRegionName() return "US" end
-- AceConsole-3.0 writes RegisterChatCommand entries into these; both are read/write tables the
-- client provides, never rebuilt per-spec (mirrors SLASH_* globals, which nothing ever resets either).
SlashCmdList = {}
hash_SlashCmdList = {}
-- CallbackHandler-1.0's Dispatch() runs every registered callback through this. The real one is a
-- taint boundary; headless code has no taint to guard against, so a straight pass-through is
-- behaviourally identical for a spec's purposes.
function securecallfunction(f, ...) return f(...) end
-- AceTimer-3.0 captures `C_Timer.After` as a file-scope upvalue, so the table must exist (with an
-- `.After` field) before that file loads, even though nothing in Core/Init.lua's own tests fires a
-- scheduled timer.
C_Timer = { After = function() end }

-- AceConsole-3.0 falls back to this when a caller doesn't hand it its own chat frame.
DEFAULT_CHAT_FRAME = CreateFrame("Frame")

M.GCD = GCD
return M.reset()
