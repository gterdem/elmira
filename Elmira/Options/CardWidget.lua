-- Elmira/Options/CardWidget.lua -- ElmiraCard, W1's card widget (owner pass, 2026-09-07, on branch
-- try/card-widget; may be discarded whole if the owner does not like it -- see tasks/todo.md's
-- QUEUED W1 section). PA (2026-09-08) is the owner's own polish pass after looking at it in game --
-- see the ACTIVE WORK PA section for the numbered decisions this file implements.
--
-- AceConfig's own inline GROUPS can never share a row: AceConfigDialog-3.0.lua:1131-1142 sets
-- `GroupContainer.width = "fill"` unconditionally on every one. A plain CONTROL, though, honours
-- `width = "relative"` + `relWidth` (AceConfigDialog-3.0.lua:1444-1452, applied by
-- AceGUI-3.0.lua:307-321's WidgetBase.SetRelativeWidth), and a `dialogControl` IS created as a
-- control (CreateControl, AceConfigDialog-3.0.lua:1093). So one custom widget is what lets three
-- "cards" sit on one row -- nothing built from AceConfig groups alone can.
--
-- Registered under a name prefixed with the addon, with an explicit version, because
-- AceGUI:RegisterWidgetType (AceGUI-3.0.lua:549) is a GLOBAL registry shared by every Ace3 addon
-- running: a generic name ("Card") could collide with someone else's widget of the same name, and a
-- widget that leaves state behind on release leaks into whichever addon's window acquires it next --
-- this project has already shipped exactly that bug once (our buttons on ElvUI's config window).
-- Version bumped to 2 for PA: the widget's own shape changed enough (real AceGUI Button children,
-- content-driven height, hover state) that this is not the same contract v1 pooled instances were
-- built against.
--
-- No `local ADDON, ns = ...`: this file exports nothing into the addon's own namespace and reaches
-- nothing in it either -- Rotation.lua hands it everything it draws through AceConfig's own `arg`
-- channel (SetCustomData), the same channel any third-party `dialogControl` author uses.
local Type, Version = "ElmiraCard", 2
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

-- PA3: the two remaining buttons ("Open" becomes the card BODY's own click, PA4). Rotation.lua still
-- hands actions by NAME, never by position, so a row that skips `use` does not shift `link` into
-- `use`'s slot.
local BUTTON_ACTIONS = { "use", "link" }

local PAD = 10
local GAP = 6
local BUTTON_HEIGHT = 20
local BUTTON_GAP = 6
local TOOLTIP_WIDTH = 280

-- PA6 CORRECTION (2026-09-08): this client's font has no ●/○ glyphs -- tasks/lessons.md already
-- recorded it, from an earlier in-game round, as identical empty tofu boxes regardless of the
-- codepoint, which would have made every difficulty tier look the same: the exact "every status
-- marker looks the same" failure a difficulty indicator exists to prevent. A Texture renders where a
-- font glyph does not (the same reason the `|T...|t` spell icons work elsewhere in this addon), so
-- difficulty is real filled/empty Texture objects, not characters in a FontString. `PIP_TEXTURE` is
-- this widget's OWN `bgFile` (also used by ElvUI on this install, so it is confirmed present);
-- filled vs. empty is ALPHA only, never a colour swap -- green/amber/grey already carry a different
-- meaning on this page (D43's need-marks), and PA6/PA9 are both explicit that one colour must not
-- teach two things.
local PIP_COUNT = 3
local PIP_SIZE = 10
local PIP_GAP = 3
local PIP_LABEL_GAP = 6
local PIP_TEXTURE = "Interface\\ChatFrame\\ChatFrameBackground"
local PIP_EMPTY_ALPHA = 0.25

-- PA9: state colours. BORDER_ACTIVE mirrors Core/Colors.lua's HIGHLIGHT (`FFD37A`, "the now-slot")
-- as 0-1 floats -- duplicated rather than required, because this file deliberately takes no `ns`
-- dependency (see the header comment above); keep the two in sync if that palette ever changes.
-- Deliberately not reusing the green/amber/grey need-marks anywhere near here (PA6/PA9): one colour
-- must not teach two different things on the same screen.
local BORDER_NORMAL = { 0.4, 0.4, 0.4 }
local BORDER_ACTIVE = { 1.0, 0.83, 0.48 }
local BORDER_DIM = { 0.22, 0.22, 0.22 }
local FILL_NORMAL = { 0.1, 0.1, 0.1, 0.5 }
local FILL_DIM = { 0.1, 0.1, 0.1, 0.22 }
local HOVER_DELTA = 0.25

-- PA4: "Brighten the border on hover so that is discoverable" -- brightens whatever the CURRENT base
-- border is (normal/active/dim), so hovering an in-use card does not fight its own gold border.
local function brighten(color)
  return { math.min(1, color[1] + HOVER_DELTA), math.min(1, color[2] + HOVER_DELTA),
           math.min(1, color[3] + HOVER_DELTA) }
end

-- PA5: a readable wrap width for every tooltip this widget shows -- an action's refusal reason can
-- run as long as a catalog summary (Protection's is five lines unwrapped), and `SetText`'s own
-- `wrap` flag alone does not reliably bound a tooltip's width without one, letting a long line render
-- as a single very wide box under the cursor instead of wrapping.
local function showTooltip(owner, text)
  if not text or text == "" then return end
  GameTooltip:SetOwner(owner, "ANCHOR_TOPRIGHT")
  GameTooltip:SetWidth(TOOLTIP_WIDTH)
  GameTooltip:SetText(text, 1, 1, 1, 1, true)
  GameTooltip:Show()
end

local function hideTooltip()
  GameTooltip:Hide()
end

-- PA3: buttons are real AceGUI Button widgets now (ElvUI and similar skin Ace widgets through
-- `RegisterAsWidget`, AceGUI-3.0.lua:527, hooked at ElvUI/Game/Shared/Modules/Skins/Ace3.lua:195; a
-- raw `CreateFrame(..., "UIPanelButtonTemplate")` never passes through that hook). A Button widget
-- has no getter/clearer of its own callbacks, so this reaches into `.events` directly -- the same
-- table `WidgetBase.Fire` (AceGUI-3.0.lua:298) reads -- rather than `SetCallback`, which only ever
-- ASSIGNS a function and so cannot be used to clear one back to nothing (D15's exact shape of bug:
-- a clear path that does less than the path that set it).
local function applyButton(button, action)
  if not action then
    button.frame:Hide()
    button:SetText("")
    button.events.OnClick = nil
    button.events.OnEnter = nil
    button.events.OnLeave = nil
    return
  end
  button:SetText(action.name or "")
  button.events.OnClick = action.func
  button.events.OnEnter = function() showTooltip(button.frame, action.desc) end
  button.events.OnLeave = hideTooltip
  button.frame:Show()
end

-- PA2: height follows content instead of a fixed constant, and every card that shares a LAYOUT
-- PARENT is equalised to the tallest among them, so their button rows still line up. AceConfigDialog
-- feeds every page (and, PA11, every inline group inside one) through the "Flow" layout
-- (AceGUI-3.0.lua:674-801, wired at AceConfigDialog-3.0.lua:1634/1143), which wraps children onto a
-- new row by WIDTH, not by a fixed count -- a literal "3 per row" would drift the moment the Panel
-- scale slider changes how many fit. `self.frame:GetParent()` is exactly what Flow anchors every
-- card sharing a row (or an inline group's own `content`, PA11) into and nothing outside it, so
-- keying equalisation off it needs no row index from Rotation.lua at all.
local rowRegistry = {}

-- Memory bookkeeping only, both marked below: `equalize`'s `rowRegistry[parent] = rowRegistry[parent]
-- or {}` treats a leftover empty table exactly like a fresh one (:145), and `self.row`'s only two
-- readers (`equalize`'s own "did the row change" check, and a later `equalize` call after
-- `OnRelease`) both reach the SAME final registration regardless of which branch that check takes --
-- so neither line changes anything the suite, or a real render, can observe.
local function clearRow(self)
  local row = self.row
  if row and rowRegistry[row] then
    rowRegistry[row][self] = nil
    if not next(rowRegistry[row]) then rowRegistry[row] = nil end -- mutants: equivalent see above
  end
  self.row = nil -- mutants: equivalent see above
end

local function naturalHeight(self)
  local h = PAD * 2
  h = h + self.title:GetStringHeight()
  h = h + GAP + self.summary:GetStringHeight()
  if self.difficultyShown then
    h = h + GAP + self.difficultyLine:GetHeight()
  end
  h = h + GAP + self.meta:GetStringHeight()
  return h + (self.buttonAreaHeight or 0)
end

-- PB2 correction (2026-09-08, owner's next screenshot): `naturalHeight` reads `GetStringHeight()`
-- off `title`/`summary`/`meta`, but `SetCustomData` (the only caller until now) runs BEFORE
-- AceConfigDialog's Flow layout ever assigns this card its real relWidth pixel width
-- (`WidgetBase:SetWidth`, AceGUI-3.0.lua:307-313, is what fires `OnWidthSet`, always AFTER
-- `SetCustomData`) -- so at `SetCustomData` time these FontStrings answer for whatever width the
-- frame happened to have before (often none at all), under-counting any text that will actually
-- wrap to more lines once the real width lands. Nothing re-measured after that, so the frame kept
-- the too-short height and PB2's own bottom-anchored block (pips/meta/buttons) drew on top of the
-- still-overflowing description.
--
-- AceGUI's own Label widget hits the identical problem and solves it the identical way
-- (`AceGUIWidget-Label.lua:22-51/93`, `UpdateImageAnchor`'s `label:SetWidth(width)` before
-- `label:GetStringHeight()`): a STRETCH-anchored (two opposite points, which is how `title`/
-- `summary`/`meta` are anchored here) region's width is DERIVED from its anchors and is not
-- guaranteed to be reflected by `GetStringHeight()` synchronously within the very callback a
-- parent's own `SetWidth` fires from -- an explicit `SetWidth` call on the region itself forces
-- that recompute right now, which is all this function exists to do before anything reads a height
-- back off these FontStrings.
local function remeasure(self)
  local width = self.frame:GetWidth() or 0
  local inner = math.max(0, width - PAD * 2)
  self.title:SetWidth(inner)
  self.summary:SetWidth(inner)
  self.meta:SetWidth(inner)
end

-- Re-measures this card and, once it knows its row (only available once AceConfigDialog has
-- actually parented it -- `frame:GetParent()` is nil before that), pushes the ROW's max height onto
-- EVERY card sharing it, including ones that measured smaller and were already sized before this one
-- arrived -- which a one-way "grow to fit yourself" would miss.
local function equalize(self)
  local own = naturalHeight(self)
  local parent = self.frame:GetParent()
  if not parent then
    self:SetHeight(own)
    return
  end
  if self.row ~= parent then
    clearRow(self)
    self.row = parent
  end
  rowRegistry[parent] = rowRegistry[parent] or {}
  rowRegistry[parent][self] = own
  local tallest = 0
  for _, h in pairs(rowRegistry[parent]) do
    if h > tallest then tallest = h end
  end
  for widget in pairs(rowRegistry[parent]) do
    widget:SetHeight(tallest)
  end
end

-- The populate-or-blank body `SetCustomData` and the two lifecycle hooks all need, kept as ONE
-- function for the same reason `applyButton` above is one function: a "clear" path that draws less
-- than the "set" path drew is exactly D15's shape of bug. Deliberately does NOT touch the row
-- registry itself (that is `equalize`'s job, called once by every caller of this) -- OnRelease needs
-- to blank a card's fields and drop it from its row WITHOUT re-registering it mid-drop, which calling
-- `equalize` here would do (the just-blanked card would immediately re-join its old row at a small
-- height, only for `clearRow` to then remove it -- and everything in between is one frame of a wrong
-- shared height for its still-live siblings).
-- PA9: gold for the rotation in use, dimmed for one that cannot run yet, normal otherwise. Its own
-- function (not inlined at the one call site) so a mutant deleting the assignment errors immediately
-- (indexing a nil `border` right after) instead of silently leaving stale globals behind.
local function stateColors(data)
  if data.active then return BORDER_ACTIVE, FILL_NORMAL end
  if data.unavailable then return BORDER_DIM, FILL_DIM end
  return BORDER_NORMAL, FILL_NORMAL
end

local function applyData(self, data)
  data = data or {}
  self.title:SetText(data.title or "")
  self.summary:SetText(data.summary or "")

  -- PA6: difficulty as pip TEXTURES (see the PIP_* constants above for why) plus a normal-weight
  -- label, on its own line -- Rotation.lua owns the easy/medium/hard -> level mapping and hands over
  -- a plain number and a label string; this widget only draws them. `difficultyLine`'s own height is
  -- measured and resized every call, in BOTH branches, so `naturalHeight` can read a real number off
  -- it whether or not a difficulty is shown this time.
  self.difficultyShown = data.difficultyLevel ~= nil
  if self.difficultyShown then
    self.difficultyLabel:SetText(data.difficultyLabel or "")
    for i = 1, PIP_COUNT do
      self.pips[i]:SetAlpha(i <= data.difficultyLevel and 1 or PIP_EMPTY_ALPHA)
      self.pips[i]:Show()
    end
    self.difficultyLine:SetHeight(math.max(PIP_SIZE, self.difficultyLabel:GetStringHeight()))
  else
    self.difficultyLabel:SetText("")
    for i = 1, PIP_COUNT do
      self.pips[i]:Hide()
    end
    self.difficultyLine:SetHeight(0)
  end

  self.meta:SetText(data.meta or "")

  -- PA9: border (and PA9's own "colour alone is a poor sole signal" -- fill too) carries state
  -- instead of a title badge: gold for the rotation in use, dimmed for one that cannot run yet,
  -- normal otherwise.
  local border, fill = stateColors(data)
  -- PD1-D5: selection is a THIRD, orthogonal state (a card can be both selected and in use) -- shown
  -- as the PERSISTENT form of the existing hover brightening rather than a new colour that would have
  -- to avoid colliding with the gold "in use" border. `brighten` is exactly what `OnEnter` below
  -- applies on hover, over whichever base this same branch just picked.
  if data.selected then border = brighten(border) end
  self.baseBorder = border
  self.frame:SetBackdropBorderColor(border[1], border[2], border[3])
  self.frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])

  -- PA5/PA8: the full playstyle text and the exact "updated" date live in the mouseover tooltip
  -- now, not on the card face.
  self.tooltipText = data.tooltip

  local actions = data.actions or {}
  -- PA4: the card BODY is the "Open" action now -- same `func` Rotation.lua always built for the
  -- (now absent) Open button, just wired to a click on the card itself instead of to a button.
  self.onClick = actions.open and actions.open.func

  -- PB2 (2026-09-08, owner's second look): the difficulty line, `meta` and the buttons used to
  -- chain DOWN from `summary`, so a longer description pushed this whole block further down than a
  -- shorter card's -- `equalize` (PA2) makes every card in a row the same total HEIGHT, but that
  -- padding landed below this block, not above it, so pips/meta/buttons never lined up across the
  -- row. Anchored bottom-up instead, off `self.frame`'s own BOTTOMLEFT/BOTTOMRIGHT -- a WoW anchor
  -- point that sits at the frame's bottom edge no matter the frame's height -- so every card in an
  -- equalised row lands this block in the same place regardless of how much room `summary` used.
  -- Walked from the LAST button up to the first (PA1: any count of them, without a skipped slot
  -- shifting the next one into its place) because the first element placed is the one that claims
  -- the frame's own bottom edge; everything after stacks onto what was already placed instead.
  local anchor, anchorSide, anyButtonShown = self.frame, "BOTTOM", false
  self.buttonAreaHeight = 0
  for i = #BUTTON_ACTIONS, 1, -1 do
    local key = BUTTON_ACTIONS[i]
    local action = actions[key]
    local button = self.buttons[i]
    applyButton(button, action)
    if action then
      local gap = anyButtonShown and BUTTON_GAP or PAD
      local xInset = (anchor == self.frame) and PAD or 0
      button.frame:ClearAllPoints()
      button.frame:SetPoint("BOTTOMLEFT", anchor, anchorSide .. "LEFT", xInset, gap)
      button.frame:SetPoint("BOTTOMRIGHT", anchor, anchorSide .. "RIGHT", -xInset, gap)
      self.buttonAreaHeight = self.buttonAreaHeight + gap + BUTTON_HEIGHT
      anchor, anchorSide, anyButtonShown = button.frame, "TOP", true
    end
  end

  -- PB2: the gap from `meta` down to whatever it sits above (the frame's own edge, or the topmost
  -- shown button) is PAD either way -- there is no product reason for the two to differ, so this is
  -- one constant rather than a second one that would only ever equal it by coincidence.
  local metaXInset = (anchor == self.frame) and PAD or 0
  self.meta:ClearAllPoints()
  self.meta:SetPoint("BOTTOMLEFT", anchor, anchorSide .. "LEFT", metaXInset, PAD)
  self.meta:SetPoint("BOTTOMRIGHT", anchor, anchorSide .. "RIGHT", -metaXInset, PAD)

  self.difficultyLine:ClearAllPoints()
  self.difficultyLine:SetPoint("BOTTOMLEFT", self.meta, "TOPLEFT", 0, GAP)
  self.difficultyLine:SetPoint("BOTTOMRIGHT", self.meta, "TOPRIGHT", 0, GAP)
end

local methods = {
  -- `self.buttons` is the table the Constructor set (`buttons = {}`, once, ever) -- it is never
  -- nilled out (OnRelease clears its ENTRIES, not the table itself), so there is nothing to
  -- reinitialise here on a later acquire; only the slots need (re)filling.
  ["OnAcquire"] = function(self)
    for i = 1, #BUTTON_ACTIONS do
      local button = AceGUI:Create("Button")
      button.frame:SetParent(self.frame)
      button:SetHeight(BUTTON_HEIGHT)
      self.buttons[i] = button
    end
    applyData(self, nil)
    equalize(self)
  end,

  -- PA3's own required behaviour: every button THIS card created is released back to AceGUI's
  -- shared Button pool, not merely hidden -- a button only hidden-and-forgotten is neither pooled
  -- nor visible, but it is also never coming back, which starves every OTHER addon's Button pool of
  -- a slot it should have gotten back. Blank the fields (and hide/clear the still-live buttons)
  -- BEFORE releasing them -- releasing first would leave `applyData`'s own button loop indexing
  -- widgets that no longer belong to this card.
  -- D4 (review of 65896ad): releasing a card whose tooltip is showing used to rely on
  -- the client firing OnLeave first -- but a release can happen without that (AceConfigDialog
  -- rebuilding the page out from under the cursor), and GameTooltip is shared cross-addon state, so
  -- a stuck tooltip pointing at a widget that no longer belongs to this card is ours to clean up.
  ["OnRelease"] = function(self)
    hideTooltip()
    applyData(self, nil)
    for i = 1, #BUTTON_ACTIONS do
      if self.buttons[i] then self.buttons[i]:Release() end
      self.buttons[i] = nil
    end
    clearRow(self)
  end,

  -- PB2 correction: `SetCustomData`'s own height (set through `equalize`, below) is provisional --
  -- taken before AceGUI ever hands this card its real pixel width, so it is measured against
  -- whatever width the FontStrings had before, not the one about to apply. This is the AUTHORITATIVE
  -- measurement: `remeasure` applies the new width to the wrapping FontStrings FIRST, so the
  -- `naturalHeight` reading `equalize` takes right after reflects how tall the text actually wraps
  -- at the width AceGUI just assigned, not the one it replaced.
  --
  -- Re-entrancy: this cannot loop. `remeasure` calls `SetWidth` only on plain FontString REGIONS
  -- (`title`/`summary`/`meta`), which carry no AceGUI widget wiring and so fire no callback of ours
  -- at all; `equalize`'s own `SetHeight` calls (on this card and on every sibling sharing its row)
  -- go through `WidgetBase.SetHeight` (AceGUI-3.0.lua:323-329), which fires `OnHeightSet`, not
  -- `OnWidthSet` -- and this widget does not define `OnHeightSet`. Nothing here can re-trigger
  -- `OnWidthSet`, on this card or on any sibling `equalize` resizes.
  ["OnWidthSet"] = function(self)
    remeasure(self)
    equalize(self)
  end,

  -- AceConfigDialog's own `type = "description"` branch calls these FOUR methods on whatever
  -- `dialogControl` produced, unconditionally for SetText/SetFontObject and whenever the option
  -- carries an `image` for the other two (AceConfigDialog-3.0.lua:1400-1437) -- this is the Label
  -- contract, and a `dialogControl` stands in for Label, not just for the parts of Label a given
  -- option happens to exercise. Missing even one of these is not a degraded card: it is
  -- `FeedOptions` (:1118) calling a nil value and the WHOLE PAGE failing to render, which is exactly
  -- what shipped once this was actually tested in game rather than only against our own assumptions
  -- about the widget (see the contract tests below, and the popup-mock incident they cite).
  --
  -- `SetText` receives `name`, `templateCard`'s own FALLBACK string for the Label AceConfig would
  -- draw if this widget never registered -- since it DID register, that string is not the card's
  -- title (SetCustomData's `data.title` is), so it is intentionally dropped rather than drawn
  -- anywhere. `SetFontObject`/`SetImage`/`SetImageSize` have nothing to apply to on a card built
  -- from independently-styled lines and no image, so all four are harmless no-ops -- but they must
  -- EXIST, and calling them must not disturb whatever SetCustomData already drew or is about to draw.
  ["SetText"] = function() end,
  ["SetFontObject"] = function() end,
  ["SetImage"] = function() end,
  ["SetImageSize"] = function() end,

  -- Fed straight from AceConfigDialog's InjectInfo (AceConfigDialog-3.0.lua:1088-1090): any
  -- `dialogControl`'d option's own `arg` table reaches the control's SetCustomData right after
  -- creation, if the control has one -- the channel every custom-widget author uses, not a second
  -- contract invented here.
  ["SetCustomData"] = function(self, data)
    applyData(self, data)
    equalize(self)
  end,
}

local function Constructor()
  local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  -- No initial SetBackdropColor/BorderColor here: OnAcquire's own `applyData(self, nil)` (below)
  -- runs immediately after this Constructor, every single time, and its "normal" branch sets the
  -- exact same colours -- a second copy here would only be able to drift from that one, never win.

  -- PA4: the whole card body is clickable (the Open target) and hoverable (border brightens, PA5's
  -- tooltip shows) -- a plain Frame, so `OnClick` is not a real script on it (that only exists on
  -- Button-type frames); `OnMouseUp` is the correct generic-frame equivalent.
  frame:EnableMouse(true)
  -- `f.obj` is set by `RegisterAsWidget` (below) before Constructor even returns -- before anything
  -- else could get a reference to `frame` to fire a script on -- so it is never nil here; no guard.
  frame:SetScript("OnEnter", function(f)
    local self = f.obj
    local border = brighten(self.baseBorder or BORDER_NORMAL)
    f:SetBackdropBorderColor(border[1], border[2], border[3])
    showTooltip(f, self.tooltipText)
  end)
  frame:SetScript("OnLeave", function(f)
    local self = f.obj
    local border = self.baseBorder or BORDER_NORMAL
    f:SetBackdropBorderColor(border[1], border[2], border[3])
    hideTooltip()
  end)
  frame:SetScript("OnMouseUp", function(f, mouseButton)
    local self = f.obj
    if self.onClick and mouseButton == "LeftButton" then self.onClick() end
  end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -PAD)
  title:SetPoint("TOPRIGHT", -PAD, -PAD)
  title:SetJustifyH("LEFT")

  local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -GAP)
  summary:SetPoint("TOPRIGHT", title, "BOTTOMRIGHT", 0, -GAP)
  summary:SetJustifyH("LEFT")

  -- PA6: a plain child FRAME, not a FontString -- its own height is set explicitly by `applyData`
  -- (0 when no difficulty is shown). PB2: its position is no longer set here at all -- `applyData`
  -- anchors it (and `meta` below) to the card's own BOTTOM edge, bottom-up, every call, since which
  -- widget owns "the bottom of the stack" depends on how many buttons are shown that time.
  -- No initial SetHeight here either, for the same reason the backdrop colours above have none:
  -- OnAcquire's own `applyData(self, nil)` runs immediately after and always sets a real height
  -- (0, its "no difficulty shown" branch) before anything could ever read this one.
  local difficultyLine = CreateFrame("Frame", nil, frame)

  local pips, previousPip = {}, nil
  for i = 1, PIP_COUNT do
    local pip = difficultyLine:CreateTexture(nil, "ARTWORK")
    pip:SetTexture(PIP_TEXTURE)
    pip:SetWidth(PIP_SIZE)
    pip:SetHeight(PIP_SIZE)
    if previousPip then
      pip:SetPoint("LEFT", previousPip, "RIGHT", PIP_GAP, 0)
    else
      pip:SetPoint("TOPLEFT", difficultyLine, "TOPLEFT", 0, 0)
    end
    pips[i] = pip
    previousPip = pip
  end

  -- Normal weight, never muted -- deliberately a different font object than `meta` below.
  local difficultyLabel = difficultyLine:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  difficultyLabel:SetPoint("LEFT", pips[PIP_COUNT], "RIGHT", PIP_LABEL_GAP, 0)
  difficultyLabel:SetJustifyH("LEFT")

  -- PB2: no static anchor here either -- see `difficultyLine` above, `applyData` positions this
  -- every call.
  local meta = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  meta:SetJustifyH("LEFT")

  local widget = {
    frame = frame, title = title, summary = summary, difficultyLine = difficultyLine,
    pips = pips, difficultyLabel = difficultyLabel, meta = meta,
    buttons = {}, type = Type,
  }
  for method, func in pairs(methods) do
    widget[method] = func
  end

  return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
