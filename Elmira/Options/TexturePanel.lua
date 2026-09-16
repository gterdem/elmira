-- Elmira/Options/TexturePanel.lua — the texture picker WINDOW (AT4-D2).
--
-- Owner, 2026-09-11: a WeakAuras-style picker. A window of its own -- category dropdown top left,
-- search box top right, a grid of large previews, Okay and Cancel bottom right -- opened from two
-- places that must not disagree: the Texture tab's "Choose…" button, and the Texture button on the
-- Move toolbar while a texture is being dragged around the screen.
--
-- NOT AN ACECONFIG PAGE, deliberately. AceConfigDialog owns one pooled frame per app and re-Opens
-- it on every option change; a picker built inside it would be rebuilt (and its scroll position
-- thrown away) on every click, and it could not be on screen at all during a Move mode, which hides
-- that window. This is our own AceGUI Frame, acquired when it opens and released when it closes.
--
-- NOTHING IS LEFT ON THE POOLED FRAME. Every child here is an AceGUI widget of our own acquiring,
-- parented into the window's content and anchored by hand rather than through `AddChild` (the five
-- of them want fixed places, not a flow). `Close` releases each one -- which reparents it to
-- UIParent and clears its anchors -- BEFORE releasing the window itself, so the frame that goes
-- back to the shared pool carries none of our children and none of our scripts. Putting Elmira's
-- controls on the next Ace3 addon's window is a bug this project has already shipped once.
--
-- LIVE PREVIEW AND CANCEL. Clicking a cell WRITES the path straight into the ability's settings and
-- repaints -- that is the whole point, you judge a texture on screen at its real size and colour,
-- not in a grid. What makes that safe is that `Open` remembers the ability's `source` and `path`
-- first: Cancel (and the window's own X) writes the remembered pair back and repaints again, so
-- browsing costs nothing. Okay simply stops remembering.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local TexturePanel = {}
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

-- Five 120px cells across, plus the picker's own padding and the room it keeps for a scrollbar.
local WINDOW_W, WINDOW_H = 720, 560
-- What AceGUI's Frame keeps for its own border: `content` is inset 17 on each side
-- (AceGUIContainer-Frame.lua's content anchors). Used to give the grid a real WIDTH rather than
-- leaving it anchor-derived -- a frame that has only just been parented answers 0 to GetWidth, and
-- a grid that measures 0 lays every texture in the category out in a single column.
local WINDOW_INSET = 34
-- TX1-D3: 260 -> 200 so Category, Blend mode and Search all fit across the 686 px content width
-- (WINDOW_W - WINDOW_INSET) in the same 50 px strip; the category and search anchors themselves do
-- not move.
local CONTROL_W = 200
local CONTROLS_H = 50           -- the strip the dropdown and the search box sit in
local BUTTONS_H = 30            -- the strip Okay and Cancel sit in
local BUTTON_W = 100

-- The five widgets and the window are PUBLIC fields (`TexturePanel.window`, `.grid`, …), the way
-- `Options.dialog` and `Options.frame` are: what is on screen is the only evidence that any of this
-- worked, and a window nothing outside this file can name cannot be asserted against. They are nil
-- whenever the window is closed.
--
-- The rest is bookkeeping. One declaration for the lot: separately, deleting any of them only makes
-- a global, which luacheck fails on and no test can see.
local activeKey, groups, groupIndex, needle -- mutants: equivalent deletion only makes it a global; luacheck catches that
local beforeSource, beforePath, beforeBlend -- mutants: equivalent deletion only makes it a global; luacheck catches that
-- are WE releasing the window, or did the player press its X
local closing = false -- mutants: equivalent deletion only makes it a global; luacheck catches that

local function AS()
  return ns.AbilitySettings
end

local function library()
  return ns.TextureLibrary
end

function TexturePanel.isOpen()
  return TexturePanel.window ~= nil
end

-- Which ability the window is for, or nil. Read by the Texture tab (so its "Choose…" button can say
-- Choosing…) and by the Move toolbar's own button.
function TexturePanel.abilityKey()
  return activeKey
end

local function effective(key)
  local A = AS()
  return (A and A.effective(key, "texture")) or {}
end

-- TX1-D6. The window's own status line: normally which ability is being chosen for, but a stored
-- path that needs an addon this character lacks (AT4-D3's own `Textures.missingAddon`) says so
-- instead -- the one sentence a player staring at a picker full of pictures actually needs, rather
-- than a title that repeats what the tab already told them.
local function statusText(key)
  local T = ns.Textures
  local missing = T and T.missingAddon and T.missingAddon(effective(key))
  if missing then
    return string.format(L["This texture needs %s enabled on this character."], missing)
  end
  return string.format(L["Choosing a texture for %s"],
    (ns.Display and ns.Display.spellName and ns.Display.spellName(key)) or key)
end

-- The path the ability is drawing right now, which is what the grid highlights. Never nil: an empty
-- file field IS the shipped ring, the same answer Display/Textures.texturePath gives it.
local function currentPath()
  local e = effective(activeKey)
  local path = e.path
  if path == nil or path == "" then
    return (ns.Textures and ns.Textures.DEFAULT_PATH) or ""
  end
  return path
end

-- Write a file into the ability and put it on screen NOW. The same two fields the Texture tab
-- writes (`source`, `path`), through the same store, so the tab shows this the moment it is
-- reopened -- and through Textures.Refresh, which is what repaints a texture that is already up
-- (the Move mode's sample, during a drag). When it is NOT up -- picking from the tab, out of combat,
-- nothing suggested -- a test-fire flashes it instead, because "immediately" has to mean something
-- for the case the picker is most used in.
local function applyPath(path)
  local A = AS()
  if not (A and activeKey) then return false end
  -- AT8-D5: the other trigger the decision names for the size-default swap, alongside the tab's own
  -- icon toggle -- picking a texture out of the icon default is exactly as much a source change as
  -- unticking the box is, and `flipSize` is a no-op the moment the ability is already on a path (the
  -- common case of browsing between two files).
  local from = (A.effective(activeKey, "texture").source == "icon") and "icon" or "path"
  A.set(activeKey, "texture", "source", "path")
  if ns.Textures and ns.Textures.flipSize then ns.Textures.flipSize(activeKey, from, "path") end
  A.set(activeKey, "texture", "path", path)
  local T = ns.Textures
  if not T then return true end
  T.Refresh()
  if T.movingKey and T.movingKey() ~= activeKey then T.TestFire(activeKey) end
  return true -- mutants: equivalent the one caller (fillGrid's onSelect) uses this as a bare statement
end

-- TX1-D3. The blend mode this ability's Texture tab is set to, the same field and the same "blend"
-- fallback Options/Spells.lua's own select reads -- this window's dropdown is a second control on
-- the SAME setting, not a setting of its own.
local function currentBlend()
  return effective(activeKey).blend or "blend"
end

-- Written straight into the ability, live, the same as a cell click: the on-screen texture repaints
-- under the new mode and the grid (D2) redraws every preview under it too, so Runes stops looking
-- like a wall of black squares the moment Glow is picked.
local function applyBlend(v)
  local A = AS()
  if not (A and activeKey) then return false end
  A.set(activeKey, "texture", "blend", v)
  if ns.Textures then ns.Textures.Refresh() end
  return true -- mutants: equivalent the one caller (the dropdown's OnValueChanged) uses this as a bare statement
end

-- The current category, filtered by whatever is typed in the search box. `matches` is the library's
-- own plain-substring test -- never a Lua pattern, which would error the moment somebody typed `%`.
local function visibleTextures()
  local group = groups and groups[groupIndex]
  local lib = library()
  local out = {}
  for _, entry in ipairs((group and group.textures) or {}) do
    if not lib or lib.matches(entry.name, needle) then out[#out + 1] = entry end
  end
  return out
end

local function fillGrid(keepScroll)
  local grid = TexturePanel.grid
  if not grid then return false end
  -- mutants: `keepScroll` is equivalent -- every call site below passes literal `false`, which
  -- reads the same as the field being absent (the widget's own `data.keepScroll ~= true` check),
  -- so nobody currently distinguishes it from nil either way.
  -- TX1-D2: resolved here, through the one mapping (Display/Textures.blendModeFor), rather than in
  -- the widget -- ElmiraTexturePicker reads nothing from `ns`.
  local T = ns.Textures
  grid:SetCustomData({
    textures = visibleTextures(),
    selected = currentPath(),
    blendMode = (T and T.blendModeFor and T.blendModeFor(currentBlend())) or "BLEND",
    keepScroll = keepScroll == true, -- mutants: equivalent see above
    onSelect = function(path)
      applyPath(path)
      -- The border moves without the grid being laid out again: the player is still browsing and
      -- their scroll position is part of what they are browsing with.
      grid:SetSelected(path)
    end,
  })
  return true -- mutants: equivalent every caller uses `fillGrid(...)` as a bare statement
end

-- The dropdown's list, in the library's own order, with the category names taken through the locale
-- here rather than in Display/TextureLibrary.lua, which holds no `L` of its own. TX1-D6: a group
-- the library marked `unavailable` (its addon is not running on this character) is still LISTED --
-- its name grows the reason -- and its id comes back a third time, in `disabled`, so `Open` can grey
-- it out in the dropdown rather than merely naming it oddly.
local function categoryList()
  local values, order, disabled = {}, {}, {}
  for i, group in ipairs(groups or {}) do
    local id = tostring(i)
    if group.unavailable then
      values[id] = string.format(L["%s (needs %s)"], L[group.name] or group.name, group.unavailable)
      disabled[#disabled + 1] = id
    else
      values[id] = L[group.name] or group.name
    end
    order[#order + 1] = id
  end
  return values, order, disabled
end

-- Which category to open on: the one holding the texture this ability is already drawing, so a
-- player who opens the picker to change their mind lands on what they chose last time. First
-- category otherwise -- and TX1-D6 never a group the addon it needs is missing for, which a grid
-- opened straight onto would show as a disabled dropdown entry with nothing to change it to.
local function indexOfCurrent()
  local path = currentPath()
  for i, group in ipairs(groups or {}) do
    if not group.unavailable then
      for _, entry in ipairs(group.textures) do
        if entry.path == path then return i end
      end
    end
  end
  return 1
end

local CHILDREN = { "grid", "categories", "blend", "search", "okay", "cancel" }

local function releaseChildren()
  for _, field in ipairs(CHILDREN) do
    local widget = TexturePanel[field]
    if widget and widget.Release then widget:Release() end
    TexturePanel[field] = nil
  end
end

-- TexturePanel.Close(cancelled) -> did a window close
--
-- `cancelled` true puts the ability back the way `Open` found it (this is the Cancel button and the
-- window's own X); false keeps whatever was last clicked (Okay, and the Move toolbar's Done, which
-- must not throw away a choice the player has been staring at).
function TexturePanel.Close(cancelled)
  local window = TexturePanel.window
  if not window then return false end
  if cancelled and activeKey and AS() then
    AS().set(activeKey, "texture", "source", beforeSource)
    AS().set(activeKey, "texture", "path", beforePath)
    -- TX1-D4: the blend mode is part of what browsing changed, so Cancel puts it back too.
    AS().set(activeKey, "texture", "blend", beforeBlend)
    if ns.Textures then ns.Textures.Refresh() end
  end
  closing = true
  releaseChildren()
  window:Release()
  TexturePanel.window, closing = nil, false
  activeKey, groups, groupIndex, needle = nil, nil, nil, nil
  -- mutants: this clear is equivalent -- `Open` always overwrites both fields (below) before Close
  -- could ever read them again, and the guard above (`cancelled and activeKey and AS()`) already
  -- read them for THIS call before this line runs; nothing reads them while the window is shut.
  beforeSource, beforePath, beforeBlend = nil, nil, nil -- mutants: equivalent see above
  -- The Texture tab is showing the path in a text field; it is not rebuilt by a click in a window
  -- of ours, so say so. Through Rotation.notifyChange -- the addon's one NotifyChange call site --
  -- rather than a second LibStub lookup that could disagree with it.
  if ns.Rotation and ns.Rotation.notifyChange then ns.Rotation.notifyChange() end
  return true
end

-- TexturePanel.Open(key) -> did a window open
function TexturePanel.Open(key)
  if type(key) ~= "string" or key == "" then return false end
  local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
  local A = AS()
  if not (AceGUI and A and ns.Textures) then return false end
  -- Already open for something else: that ability keeps whatever is on it (the player clicked a
  -- picture and left it there), and this one starts fresh.
  if TexturePanel.window then TexturePanel.Close(false) end

  activeKey = key
  local e = A.effective(key, "texture")
  beforeSource, beforePath, beforeBlend = e.source or "icon", e.path or "", e.blend or "blend"
  groups = ns.Textures.libraryGroups()
  -- mutants: this reset is equivalent -- Close (line 196 above) already nils `needle` before this
  -- runs, on every path that reaches here (a fresh session or the `Close(false)` just above), and
  -- `TextureLibrary.matches` treats nil the same as "": both mean "show everything".
  needle = "" -- mutants: equivalent see above
  groupIndex = indexOfCurrent()

  local window = AceGUI:Create("Frame")
  if not window then activeKey = nil; return false end
  TexturePanel.window = window
  window:SetTitle(L["Elmira — Texture Picker"])
  window:SetStatusText(statusText(key))
  window:SetWidth(WINDOW_W)
  window:SetHeight(WINDOW_H)
  -- The X, and anything else that hides the window, means Cancel -- the one exit that has not said
  -- what it wants kept. `closing` stands this down while Close is doing the releasing itself, the
  -- same guard the Move bar uses for the same reason.
  window:SetCallback("OnClose", function()
    if closing then return end
    TexturePanel.Close(true)
  end)

  local content = window.content

  local categories = AceGUI:Create("Dropdown")
  categories.frame:SetParent(content)
  categories:SetLabel(L["Category"])
  categories:SetWidth(CONTROL_W)
  local values, order, disabledIds = categoryList()
  categories:SetList(values, order)
  -- TX1-D6: greyed rather than gone -- a category the current character's addons cannot back is
  -- still visible in the list, just not selectable.
  for _, id in ipairs(disabledIds) do
    if categories.SetItemDisabled then categories:SetItemDisabled(id, true) end
  end
  categories:SetValue(tostring(groupIndex))
  categories:SetCallback("OnValueChanged", function(_, _, value)
    groupIndex = tonumber(value) or 1
    fillGrid(false)
  end)
  -- mutants: this clear is equivalent -- AceGUI:Release already runs
  -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
  -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
  categories.frame:ClearAllPoints() -- mutants: equivalent see above
  categories.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
  categories.frame:Show()
  TexturePanel.categories = categories

  -- TX1-D3: the same setting, same values, same order as the Texture tab's own select
  -- (Options/Spells.lua) -- that control is UNCHANGED, this is a second way to reach it from
  -- inside the picker, live like a cell click.
  local blend = AceGUI:Create("Dropdown")
  blend.frame:SetParent(content)
  blend:SetLabel(L["Blend mode"])
  blend:SetWidth(CONTROL_W)
  blend:SetList({ blend = L["Opaque"], add = L["Glow"] }, { "blend", "add" })
  blend:SetValue(currentBlend())
  blend:SetCallback("OnValueChanged", function(_, _, value)
    applyBlend(value)
    fillGrid(false)
  end)
  -- mutants: this clear is equivalent -- AceGUI:Release already runs
  -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
  -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
  blend.frame:ClearAllPoints() -- mutants: equivalent see above
  blend.frame:SetPoint("TOP", content, "TOP", 0, 0)
  blend.frame:Show()
  TexturePanel.blend = blend

  local search = AceGUI:Create("EditBox")
  search.frame:SetParent(content)
  search:SetLabel(L["Search"])
  search:SetWidth(CONTROL_W)
  search:DisableButton(true)
  -- Filters as it is typed (OnTextChanged), not on Enter: a search box that needs a keystroke the
  -- player has no reason to expect reads as one that does not work.
  search:SetCallback("OnTextChanged", function(_, _, text)
    needle = text or ""
    fillGrid(false)
  end)
  -- mutants: this clear is equivalent -- AceGUI:Release already runs
  -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
  -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
  search.frame:ClearAllPoints() -- mutants: equivalent see above
  search.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
  search.frame:Show()
  TexturePanel.search = search

  local grid = AceGUI:Create("ElmiraTexturePicker")
  if grid then
    grid.frame:SetParent(content)
    -- mutants: this clear is equivalent -- AceGUI:Release already runs
    -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
    -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
    grid.frame:ClearAllPoints() -- mutants: equivalent see above
    grid.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -CONTROLS_H)
    grid.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, BUTTONS_H)
    -- Five 120px cells across at the shipped width, and the number the grid actually measures
    -- rather than one it has to wait for the layout engine to hand it.
    grid:SetWidth(WINDOW_W - WINDOW_INSET)
    grid.frame:Show()
    TexturePanel.grid = grid
  end

  local okay = AceGUI:Create("Button")
  okay.frame:SetParent(content)
  okay:SetText(L["Okay"])
  okay:SetWidth(BUTTON_W)
  okay:SetCallback("OnClick", function() TexturePanel.Close(false) end)
  -- mutants: this clear is equivalent -- AceGUI:Release already runs
  -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
  -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
  okay.frame:ClearAllPoints() -- mutants: equivalent see above
  okay.frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
  okay.frame:Show()
  TexturePanel.okay = okay

  local cancel = AceGUI:Create("Button")
  cancel.frame:SetParent(content)
  cancel:SetText(L["Cancel"])
  cancel:SetWidth(BUTTON_W)
  cancel:SetCallback("OnClick", function() TexturePanel.Close(true) end)
  -- mutants: this clear is equivalent -- AceGUI:Release already runs
  -- `widget.frame:ClearAllPoints()` on every widget it hands back to the
  -- pool (AceGUI-3.0.lua:196), before this file ever re-anchors one.
  cancel.frame:ClearAllPoints() -- mutants: equivalent see above
  cancel.frame:SetPoint("BOTTOMRIGHT", okay.frame, "BOTTOMLEFT", -6, 0)
  cancel.frame:Show()
  TexturePanel.cancel = cancel

  fillGrid(false)
  -- ABOVE the configuration window, which is in the same strata (both are AceGUI Frames) and was
  -- put on screen first: AceConfigDialog re-Opens its own window the instant the Choose… button's
  -- func returns, and a picker that opened behind it reads as a button that did nothing.
  if window.frame.Raise then window.frame:Raise() end
  return true
end

-- One button, two meanings: the Move toolbar's Texture button and the tab's "Choose…" both toggle,
-- so the thing that opened the window also shuts it.
function TexturePanel.Toggle(key)
  if TexturePanel.window and activeKey == key then return TexturePanel.Close(false) end
  return TexturePanel.Open(key)
end

ns.TexturePanel = TexturePanel
return TexturePanel
