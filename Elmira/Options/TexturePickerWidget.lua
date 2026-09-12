-- Elmira/Options/TexturePickerWidget.lua — ElmiraTexturePicker, the preview grid inside the
-- texture picker window (AT4-D2).
--
-- The owner, on picking a texture by typing a path: WeakAuras shows you the pictures. So does this.
-- A grid of large previews, one category at a time, filtered by the window's search box: hover for
-- the name and the path, click to choose. A path typed by hand is the one setting in this addon
-- whose failure looks exactly like success (the ring is drawn either way), so seeing the picture
-- before choosing it IS the feature.
--
-- THE GRID ONLY. Which category is showing, what was typed in the search box, Okay and Cancel and
-- the live preview all belong to Options/TexturePanel.lua -- this widget is handed a finished list
-- and reports clicks back. That split is why the window can filter, restore and cancel without any
-- of it being re-implemented against a second copy of the grid.
--
-- Registered under an addon-prefixed name with an explicit version, and it leaves NOTHING on a
-- released widget: AceGUI:RegisterWidgetType (AceGUI-3.0.lua:549) is a registry shared by every
-- Ace3 addon in the client, and a widget that keeps state across a release leaks into whichever
-- addon's window acquires it next -- this project has shipped that bug once already (our buttons on
-- ElvUI's config window). Options/CardWidget.lua is the precedent this file follows.
--
-- No `local ADDON, ns = ...`: like CardWidget, this file exports nothing into the addon namespace
-- and reads nothing from it. Everything it draws arrives through `SetCustomData`, the same channel
-- any third-party widget author is handed.
local Type, Version = "ElmiraTexturePicker", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

-- A LARGE cell (owner, 2026-09-11: five across at the window's default width). Big enough that a
-- ring, a disc and a ring-with-a-border are three different pictures rather than three grey dots --
-- which is the whole reason a picker beats a dropdown of file names.
local CELL = 120
local GAP = 8
local PAD = 8
local SCROLLBAR_ROOM = 20       -- kept clear on the right so the last column is never under the bar
local TOOLTIP_WIDTH = 280
-- The now-slot gold, Core/Colors.lua's HIGHLIGHT as 0-1 floats. Duplicated rather than required for
-- the same reason CardWidget duplicates it: this file deliberately takes no `ns` dependency.
local SELECTED_R, SELECTED_G, SELECTED_B = 1.0, 0.83, 0.48
local BORDER = 3

local function showTooltip(owner, name, path)
  if not (GameTooltip and owner) then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if GameTooltip.SetWidth then GameTooltip:SetWidth(TOOLTIP_WIDTH) end
  GameTooltip:SetText(tostring(name or ""), 1, 1, 1, 1, true)
  -- The path as well as the name, because the name is generated FROM the path: a player comparing
  -- what they see here with what another addon shows them has only the path in common.
  if GameTooltip.AddLine then GameTooltip:AddLine(tostring(path or ""), 0.6, 0.6, 0.6, true) end
  GameTooltip:Show()
end

local function hideTooltip()
  if GameTooltip then GameTooltip:Hide() end
end

-- The chosen cell gets a gold BORDER, not a gold fill: the cell's whole job is to show the texture,
-- and washing it in colour changes the one thing the player is trying to judge. Four thin edge
-- textures rather than a backdrop, so this needs no template and no client version check.
local function applySelection(cell, on)
  cell.elmiraSelected = on and true or false
  for _, edge in ipairs(cell.elmiraBorder) do
    if on then edge:Show() else edge:Hide() end
  end
end

local function cellEnter(cell)
  showTooltip(cell, cell.elmiraName, cell.elmiraPath)
end

local function cellLeave()
  hideTooltip()
end

-- The click. `elmiraOwner` is set once, in `cellFor` below, so a cell always knows which picker it
-- belongs to even after the grid has been laid out again for a different category.
local function cellClick(cell)
  local self = cell.elmiraOwner
  if not (self and self.onSelect and cell.elmiraPath) then return end
  self.onSelect(cell.elmiraPath)
end

-- Mouse wheel. Clamped to the real scroll range rather than left to the client: a ScrollFrame
-- scrolled past its own content shows an empty grid, which reads as "the library is broken".
local function onWheel(scroll, delta)
  local parent = scroll.GetParent and scroll:GetParent()
  local self = parent and parent.obj
  if not self then return end
  local current = (scroll.GetVerticalScroll and scroll:GetVerticalScroll()) or 0
  local range = (scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange()) or 0
  local target = math.max(0, math.min(range, current - (delta or 0) * (CELL + GAP)))
  if scroll.SetVerticalScroll then scroll:SetVerticalScroll(target) end
  self.scrollOffset = target
end

-- Cells are created on demand and POOLED ON THE WIDGET: the biggest category holds 145 textures and
-- a picker that rebuilt its frames on every keystroke in the search box would rebuild all of them,
-- ten times a second, while somebody types. Beyond the count needed this time the leftovers are
-- hidden, never destroyed.
local function cellFor(self, index)
  local cell = self.cells[index]
  if cell then return cell end
  cell = CreateFrame("Button", nil, self.content)
  cell:SetWidth(CELL)
  cell:SetHeight(CELL)
  -- The dark plate the texture is drawn ON. Most of the library is white art with the shape in its
  -- alpha channel, which is invisible against a light background and unjudgeable against none.
  local back = cell:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints(cell)
  back:SetColorTexture(0, 0, 0, 0.55)
  local icon = cell:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", cell, "TOPLEFT", BORDER, -BORDER)
  icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -BORDER, BORDER)
  local border = {}
  for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local line = cell:CreateTexture(nil, "OVERLAY")
    line:SetColorTexture(SELECTED_R, SELECTED_G, SELECTED_B, 1)
    if edge == "TOP" or edge == "BOTTOM" then
      line:SetPoint(edge .. "LEFT", cell, edge .. "LEFT", 0, 0)
      line:SetPoint(edge .. "RIGHT", cell, edge .. "RIGHT", 0, 0)
      line:SetHeight(BORDER)
    else
      line:SetPoint("TOP" .. edge, cell, "TOP" .. edge, 0, 0)
      line:SetPoint("BOTTOM" .. edge, cell, "BOTTOM" .. edge, 0, 0)
      line:SetWidth(BORDER)
    end
    -- mutants: this starting Hide is equivalent -- `redraw` always runs `applySelection` on a cell
    -- right after `cellFor` builds it (never before), and that call already Shows or Hides every
    -- edge from real data on the very same pass.
    line:Hide() -- mutants: equivalent see above
    border[#border + 1] = line
  end
  cell.elmiraIcon, cell.elmiraBorder, cell.elmiraOwner = icon, border, self
  cell:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  cell:SetScript("OnEnter", cellEnter)
  cell:SetScript("OnLeave", cellLeave)
  cell:SetScript("OnClick", cellClick)
  self.cells[index] = cell
  return cell
end

-- How many previews fit across, from the width AceGUI has actually assigned. Its own function
-- because it is the one piece of arithmetic here a test can hold: a column count that comes out 0
-- would put every texture in the category on top of the one before it.
local function columnsFor(width)
  local inner = (width or 0) - PAD * 2 - SCROLLBAR_ROOM
  local fit = math.floor((inner + GAP) / (CELL + GAP))
  return math.max(1, fit)
end

-- Lay the grid out. Runs on every SetCustomData (so on every category change and every keystroke in
-- the search box) and on every width change, and always places EVERY cell it shows -- a cell left
-- at an anchor from the previous layout is the drifting-grid bug pooling would otherwise invite.
local function redraw(self)
  local columns = columnsFor(self.frame:GetWidth())
  local index, column, y = 0, 0, 0
  for _, entry in ipairs(self.textures or {}) do
    index = index + 1
    local cell = cellFor(self, index)
    cell.elmiraPath, cell.elmiraName = entry.path, entry.name
    -- A numeric file id has to reach SetTexture as a NUMBER; a path reaches it as a string.
    -- `tonumber` tells them apart, which is what lets Blizzard's own art (addressable only by id on
    -- this client) sit in the same grid as a file path.
    cell.elmiraIcon:SetTexture(tonumber(entry.path) or entry.path)
    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", self.content, "TOPLEFT", column * (CELL + GAP), -y)
    cell:Show()
    applySelection(cell, entry.path == self.selected)
    column = column + 1
    if column >= columns then
      column = 0
      y = y + CELL + GAP
    end
  end
  if column > 0 then y = y + CELL + GAP end
  for i = index + 1, #self.cells do
    self.cells[i]:Hide()
    self.cells[i].elmiraPath, self.cells[i].elmiraName = nil, nil
    applySelection(self.cells[i], false)
  end
  self.content:SetWidth(math.max(CELL, columns * (CELL + GAP)))
  self.content:SetHeight(math.max(CELL, y))
  self.shownCount, self.contentHeight = index, y
  -- mutants: this return is equivalent -- every caller uses `redraw(self)` as a bare statement,
  -- and `self.shownCount` above already carries this same value for anyone who wants it.
  return index -- mutants: equivalent see above
end

local methods = {
  -- Nothing is rebuilt here: `cells` is the table the constructor made once, and OnRelease empties
  -- its CONTENTS' state rather than the table, so an acquired picker starts from a pool of hidden,
  -- blank cells.
  ["OnAcquire"] = function(self)
    self.textures, self.selected, self.onSelect, self.scrollOffset = nil, nil, nil, 0
    if self.scroll.SetVerticalScroll then self.scroll:SetVerticalScroll(0) end
    redraw(self)
  end,

  -- Everything this picker was showing, gone -- the shared pool hands this widget to the next Ace3
  -- addon that asks for one of this type, and a leftover callback would fire into a window that no
  -- longer exists. The tooltip is cleaned up for the reason CardWidget's is: GameTooltip is shared
  -- cross-addon state and a release can happen without the cursor ever leaving a cell.
  ["OnRelease"] = function(self)
    hideTooltip()
    self.textures, self.selected, self.onSelect = nil, nil, nil
    self.scrollOffset = 0
    if self.scroll.SetVerticalScroll then self.scroll:SetVerticalScroll(0) end
    redraw(self)
  end,

  -- `textures` is the finished, already-filtered list ({ path =, name = }); `selected` is the path
  -- drawn with the gold border; `onSelect` is what a click calls. The window hands all three over
  -- again whenever the category or the search text changes.
  ["SetCustomData"] = function(self, data)
    data = data or {}
    self.textures = data.textures
    self.selected = data.selected
    self.onSelect = data.onSelect
    -- Back to the top on a new list: the scroll offset from a 145-picture category would otherwise
    -- leave a 6-picture one showing nothing but empty space.
    if data.keepScroll ~= true and self.scroll.SetVerticalScroll then
      self.scroll:SetVerticalScroll(0)
      self.scrollOffset = 0
    end
    redraw(self)
  end,

  -- Move the border without relaying the grid out: the window stays open across a choice, and
  -- rebuilding the cells to light one of them up would throw the player's scroll position away
  -- mid-browse.
  ["SetSelected"] = function(self, path)
    self.selected = path
    for _, cell in ipairs(self.cells) do
      applySelection(cell, cell.elmiraPath ~= nil and cell.elmiraPath == path)
    end
  end,

  -- AceGUI assigns the real width only after the control is parented, so this is the authoritative
  -- moment to decide how many previews fit across (the same ordering CardWidget documents). Cannot
  -- re-enter: `redraw` sets sizes on plain regions and on the content frame, none of which is an
  -- AceGUI widget with an OnWidthSet of its own.
  ["OnWidthSet"] = function(self)
    redraw(self)
  end,
}

local function Constructor()
  local frame = CreateFrame("Frame", nil, UIParent)

  local scroll = CreateFrame("ScrollFrame", nil, frame)
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", onWheel)

  local content = CreateFrame("Frame", nil, scroll)
  -- mutants: this starting size is equivalent -- `AceGUI:Create` runs `OnAcquire` (which calls
  -- `redraw`, overwriting both dimensions for real) before handing the widget back to anyone, so
  -- no caller ever sees the size set here.
  content:SetWidth(CELL) -- mutants: equivalent see above
  content:SetHeight(CELL) -- mutants: equivalent see above
  scroll:SetScrollChild(content)

  local widget = {
    frame = frame, scroll = scroll, content = content,
    cells = {}, type = Type,
  }
  for method, func in pairs(methods) do
    widget[method] = func
  end

  return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
