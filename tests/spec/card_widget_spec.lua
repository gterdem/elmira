local helper = require("tests.helper")

-- Elmira/Options/CardWidget.lua -- W1's card widget (try/card-widget, may be discarded whole).
-- PA (2026-09-08) is the owner's own polish pass; see tasks/todo.md's PA section for the numbered
-- decisions this spec proves.
--
-- Same reasoning as tests/spec/queue_spec.lua's own fake, cited there: tests/wow_mock.lua's
-- CreateFrame answers every method with a no-op, so `button:Hide()` and never calling it are
-- indistinguishable through it. The fake below RECORDS what is asked of it -- text, shown/hidden,
-- width/height, anchor points, backdrop, parent -- so a line this file deletes actually fails a test
-- here, rather than surviving as an unread call into a mock that swallows everything.
-- `GetStringHeight` is a TEST LEVER, not a real font metric: this is a headless suite, so a test sets
-- `fontstring.stringHeight` directly to simulate wrapped text of a given height, the same "close
-- enough to be worth testing against" idiom the rest of this file already uses.
--
-- AceGUI itself is faked too, not loaded for real: a small stand-in mirroring the handful of
-- AceGUI-3.0.lua lines this widget actually touches (RegisterWidgetType/GetWidgetVersion :549,
-- :603-605; Create/Release :138-165, :172-207; the WidgetBase mixin RegisterAsWidget installs,
-- :527-535, :307-321; the real Button widget's own Constructor/OnClick/OnEnter/OnLeave wiring,
-- AceGUIWidget-Button.lua:19-31,75-101, since PA3 makes CardWidget.lua create real Button widgets) --
-- the same idiom tests/spec/options_window_spec.lua already uses for AceConfigDialog, and it is what
-- lets this spec prove real POOL REUSE (Release, then Create again, returns the SAME table) rather
-- than asserting against a widget this spec built by hand.
describe("Elmira/Options/CardWidget.lua (W1, the card widget)", function()
  local AceGUI, tooltip

  local function fakeFrame(kind)
    local f = { kind = kind, points = {}, shown = true, scripts = {} }
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:GetNumPoints() return #self.points end
    function f:ClearAllPoints() self.points = {} end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    function f:SetWidth(w) self.width = w end
    function f:GetWidth() return self.width end
    function f:SetHeight(h) self.height = h end
    function f:GetHeight() return self.height end
    -- A TEST LEVER, not a real font metric -- see the file header comment.
    function f:GetStringHeight() return self.stringHeight or 0 end
    function f:SetJustifyH(v) self.justifyH = v end
    function f:SetTexture(t) self.texture = t end
    function f:GetTexture() return self.texture end
    function f:SetAlpha(a) self.alpha = a end
    function f:GetAlpha() return self.alpha end
    function f:SetBackdrop(t) self.backdrop = t end
    function f:SetBackdropColor(...) self.backdropColor = { ... } end
    function f:SetBackdropBorderColor(...) self.backdropBorderColor = { ... } end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:SetParent(p) self.parent = p end
    function f:GetParent() return self.parent end
    function f:EnableMouse(v) self.mouseEnabled = v end
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:GetScript(event) return self.scripts[event] end
    -- NOT real WoW frame methods -- the cheapest way for a spec to fire a script without a real
    -- mouse event, matching wow_mock.lua's own precedent (`frame:Fire` for OnEvent).
    function f:Click(...)
      local fn = self.scripts.OnClick
      if fn then return fn(self, ...) end
    end
    function f:Enter(...)
      local fn = self.scripts.OnEnter
      if fn then return fn(self, ...) end
    end
    function f:Leave(...)
      local fn = self.scripts.OnLeave
      if fn then return fn(self, ...) end
    end
    function f:MouseUp(button)
      local fn = self.scripts.OnMouseUp
      if fn then return fn(self, button or "LeftButton") end
    end
    -- PascalCase falls through to a no-op (anything this spec does not care about: SetFrameStrata,
    -- EnableMouse, ...); a lowercase key falls through to nil, so a field the widget never set reads
    -- as absent rather than as a stray function (tests/spec/queue_spec.lua's own comment on why).
    return setmetatable(f, { __index = function(_, k)
      if type(k) == "string" and k:match("^%u") then return function() end end
      return nil
    end })
  end

  -- CreateFontString/CreateTexture return a fresh fake of their own -- the widget anchors title,
  -- summary, difficulty, meta to EACH OTHER, so each needs its own independent `.points`/`.text`.
  local function fakeParent(kind)
    local f = fakeFrame(kind)
    function f:CreateFontString(...) return fakeFrame("FontString") end
    function f:CreateTexture(...) return fakeFrame("Texture") end
    return f
  end

  -- A line-for-line stand-in for the real registry, not the vendored 1600-line file: only the
  -- subset CardWidget.lua actually calls -- now including a fake "Button" type (PA3), wired the same
  -- way the real AceGUIWidget-Button.lua wires its frame scripts to `frame.obj:Fire(name, ...)`.
  local function newFakeAceGUI()
    local registry, versions, pool = {}, {}, {}
    local Fake, WidgetBase = {}, {}

    -- Mirrors real AceGUI-3.0.lua:307-313: SetWidth fires `OnWidthSet` if the widget defines one --
    -- the "re-triggers on layout" test below depends on this, exactly as the real Flow layout does
    -- (AceGUI-3.0.lua:775) when it assigns a relWidth child its concrete pixel width.
    function WidgetBase:SetWidth(w)
      self.frame:SetWidth(w)
      self.frame.width = w
      if self.OnWidthSet then self:OnWidthSet(w) end
    end
    function WidgetBase:SetHeight(h) self.frame:SetHeight(h); self.frame.height = h end
    function WidgetBase:Release() Fake:Release(self) end

    function Fake:RegisterWidgetType(kind, ctor, version)
      registry[kind] = ctor
      versions[kind] = version
    end
    function Fake:GetWidgetVersion(kind) return versions[kind] end
    function Fake:RegisterAsWidget(widget)
      widget.frame.obj = widget
      widget.events = widget.events or {}
      return setmetatable(widget, { __index = WidgetBase })
    end
    function Fake:Create(kind)
      pool[kind] = pool[kind] or {}
      local widget = next(pool[kind])
      if widget then
        pool[kind][widget] = nil
      else
        widget = registry[kind]()
      end
      if widget.OnAcquire then widget:OnAcquire() end
      return widget
    end
    function Fake:Release(widget)
      widget.frame:Hide()
      if widget.OnRelease then widget:OnRelease() end
      pool[widget.type] = pool[widget.type] or {}
      pool[widget.type][widget] = true
    end

    -- The real AceGUIWidget-Button.lua (:19-31, :75-101): `Fire` dispatches through `.events`, and
    -- there is no getter, matching the real widget's own shape (SetText only) -- `GetText` below is
    -- a test convenience reading the same field `SetText` wrote, not a real AceGUI Button method.
    Fake:RegisterWidgetType("Button", function()
      local widget = { type = "Button", events = {} }
      local frame = fakeFrame("Button")
      frame:Hide() -- real AceGUIWidget-Button.lua's Constructor does this too (:78)
      widget.frame = frame
      frame.obj = widget
      frame:SetScript("OnClick", function(f, ...)
        if widget.events.OnClick then widget.events.OnClick(widget, "OnClick", ...) end
      end)
      frame:SetScript("OnEnter", function()
        if widget.events.OnEnter then widget.events.OnEnter(widget, "OnEnter") end
      end)
      frame:SetScript("OnLeave", function()
        if widget.events.OnLeave then widget.events.OnLeave(widget, "OnLeave") end
      end)
      function widget:SetText(t) frame:SetText(t) end
      function widget:GetText() return frame:GetText() end
      function widget:SetWidth(w) frame:SetWidth(w) end
      function widget:SetHeight(h) frame:SetHeight(h) end
      -- Real AceGUIWidget-Button.lua's own OnAcquire (:37-44) never calls `frame:Show()` either --
      -- visibility is the CALLER's job (a container's `AddChild`, or here, CardWidget's own
      -- `applyButton`) -- so a freshly (re)acquired button starts exactly as hidden as the real one.
      function widget:OnAcquire() frame:SetText("") end
      function widget:Release() Fake:Release(widget) end
      return widget
    end, 1)

    return Fake
  end

  local function newCard() return AceGUI:Create("ElmiraCard") end

  before_each(function()
    helper.reset()
    _G.UIParent = fakeParent("Frame")
    _G.CreateFrame = function(kind) return fakeParent(kind) end
    tooltip = {}
    function tooltip:SetOwner(owner, anchor) self.owner = owner; self.anchor = anchor end
    function tooltip:SetWidth(w) self.width = w end
    function tooltip:SetText(text) self.text = text end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    _G.GameTooltip = tooltip
    AceGUI = newFakeAceGUI()
    _G.LibStub = function(major) return major == "AceGUI-3.0" and AceGUI or nil end
    helper.load("Elmira/Options/CardWidget.lua")
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent, _G.GameTooltip, _G.LibStub = nil, nil, nil, nil
  end)

  it("registers ElmiraCard under an explicit version", function()
    assert.equal(2, AceGUI:GetWidgetVersion("ElmiraCard"))
  end)

  -- The global-registry hazard (W1a): a second load with an equal-or-newer version already
  -- registered must not overwrite it -- the exact guard every AceGUI widget file opens with.
  it("does not overwrite a widget type already at least as new", function()
    AceGUI:RegisterWidgetType("ElmiraCard", function() error("should not run") end, 99)
    helper.load("Elmira/Options/CardWidget.lua")
    assert.equal(99, AceGUI:GetWidgetVersion("ElmiraCard"))
  end)

  -- The 2026-09-08 incident: AceConfigDialog-3.0.lua:1400-1437's own `type = "description"` branch
  -- calls `control:SetText(name)` UNCONDITIONALLY (:1402) on whatever `dialogControl` produced, then
  -- `SetFontObject` (:1406/1408/1410, also unconditional), then `SetImage`/`SetImageSize` whenever
  -- the option carries an `image`. This widget shipped without any of the four; the FIRST person to
  -- open the Rotations page in game hit `FeedOptions` (:1118, an ancestor of `FeedGroup` in the same
  -- call chain) calling a nil value, and the WHOLE PAGE failed to render. Every earlier test in this
  -- file drove `SetCustomData` directly -- proving our own assumptions about the widget, never
  -- AceConfig's actual requirements of it (the same shape of gap a StaticPopup mock with an
  -- `editBox` field the real client does not have left behind once before).
  local DESCRIPTION_CONTRACT = { "SetText", "SetFontObject", "SetImage", "SetImageSize" }

  it("implements the full AceConfigDialog `description` control contract, or the page cannot render",
    function()
      local card = newCard()
      for _, method in ipairs(DESCRIPTION_CONTRACT) do
        assert.equal("function", type(card[method]),
          method .. " is missing -- AceConfigDialog calls it for every type=\"description\" control")
      end
    end)

  -- Drives the EXACT sequence FeedOptions runs, in the REAL order (the Label-shaped calls all
  -- happen BEFORE InjectInfo's own SetCustomData, AceConfigDialog-3.0.lua:1401-1464): proof the
  -- widget survives being fed the way the library actually feeds it, not merely that the four
  -- methods exist in isolation -- and that none of them clobber what SetCustomData draws right
  -- after. A version of this test that jumped straight to SetCustomData would still pass against
  -- the widget that shipped with no SetText at all.
  it("survives AceConfigDialog's own description call sequence and still renders its real data",
    function()
      local card = newCard()
      assert.has_no.errors(function()
        card:SetText("Exodin\nFast 2H.") -- the Label fallback string `templateCard` builds, unused
        card:SetFontObject({})           -- stand-in for GameFontHighlight
        card:SetImage("Interface\\Icons\\INV_Misc_QuestionMark", 0, 1, 0, 1)
        card:SetImageSize(32, 32)
      end)
      card:SetCustomData({ title = "Exodin", summary = "Fast 2H.",
        actions = { open = { name = "Open", func = function() end } } })
      assert.equal("Exodin", card.title:GetText())
      assert.equal("Fast 2H.", card.summary:GetText())
    end)

  it("starts blank on acquire, before any SetCustomData call", function()
    local card = newCard()
    assert.equal("", card.title:GetText())
    assert.equal("", card.summary:GetText())
    assert.equal("", card.difficultyLabel:GetText())
    for i = 1, 3 do assert.is_false(card.pips[i]:IsShown()) end
    assert.equal(0, card.difficultyLine:GetHeight())
    assert.equal("", card.meta:GetText())
    for i = 1, 2 do assert.is_false(card.buttons[i].frame:IsShown()) end
    -- PA2: already sized to its own (minimal, blank) content on acquire, not left at whatever
    -- height the frame happened to have before. PE1-D2: PAD*2 + title + GAP + summary -- an EMPTY
    -- `meta` reserves neither its own height nor a GAP above it any more, which is 6px less than
    -- the blank card used to claim.
    assert.equal(10 * 2 + 6, card.frame:GetHeight())
  end)

  it("draws a bordered panel with the given colours", function()
    local card = newCard()
    local backdrop = card.frame.backdrop
    assert.equal("Interface\\ChatFrame\\ChatFrameBackground", backdrop.bgFile)
    assert.equal("Interface\\Tooltips\\UI-Tooltip-Border", backdrop.edgeFile)
    assert.is_true(backdrop.tile)
    assert.equal(16, backdrop.tileSize)
    assert.equal(16, backdrop.edgeSize)
    assert.same({ left = 3, right = 3, top = 3, bottom = 3 }, backdrop.insets)
  end)

  it("left-aligns every text line", function()
    local card = newCard()
    assert.equal("LEFT", card.title.justifyH)
    assert.equal("LEFT", card.summary.justifyH)
    assert.equal("LEFT", card.difficultyLabel.justifyH)
    assert.equal("LEFT", card.meta.justifyH)
  end)

  it("stacks title then summary top to bottom, stretched across the card", function()
    local card = newCard()
    assert.same({ "TOPLEFT", 10, -10 }, card.title.points[1])
    assert.same({ "TOPRIGHT", -10, -10 }, card.title.points[2])
    assert.same({ "TOPLEFT", card.title, "BOTTOMLEFT", 0, -6 }, card.summary.points[1])
    assert.same({ "TOPRIGHT", card.title, "BOTTOMRIGHT", 0, -6 }, card.summary.points[2])
  end)

  -- PB2 (2026-09-08): the difficulty line, `meta` and the buttons anchor to the card's own BOTTOM
  -- edge, built bottom-up, instead of chaining down from `summary` -- with no buttons shown, `meta`
  -- claims the frame's own BOTTOMLEFT/BOTTOMRIGHT directly and `difficultyLine` sits above it.
  it("anchors the difficulty line and meta to the card's own bottom edge, bottom-up, with no buttons",
    function()
      local card = newCard()
      card:SetCustomData({ title = "T", meta = "Unproven" })
      assert.same({ "BOTTOMLEFT", card.frame, "BOTTOMLEFT", 10, 10 }, card.meta.points[1])
      assert.same({ "BOTTOMRIGHT", card.frame, "BOTTOMRIGHT", -10, 10 }, card.meta.points[2])
      assert.same({ "BOTTOMLEFT", card.meta, "TOPLEFT", 0, 6 }, card.difficultyLine.points[1])
      assert.same({ "BOTTOMRIGHT", card.meta, "TOPRIGHT", 0, 6 }, card.difficultyLine.points[2])
    end)

  -- PE1-D2: with the recommended/Unproven bits folded onto the difficulty line, a template card's
  -- `meta` is usually EMPTY -- and an empty line still claimed a GAP and its own measured height,
  -- leaving a blank row under every card. An empty `meta` reserves NOTHING now: the difficulty line
  -- takes over the bottom slot itself, at the card's own PAD, not GAP above a zero-height sibling.
  describe("PE1-D2: an empty meta line reserves no row at all", function()
    it("hands the bottom slot to the difficulty line when meta is empty", function()
      local card = newCard()
      card:SetCustomData({ title = "T", difficultyLevel = 1, difficultyLabel = "Easy" })
      assert.same({ "BOTTOMLEFT", card.frame, "BOTTOMLEFT", 10, 10 }, card.difficultyLine.points[1])
      assert.same({ "BOTTOMRIGHT", card.frame, "BOTTOMRIGHT", -10, 10 }, card.difficultyLine.points[2])
    end)

    it("anchors the difficulty line above the topmost button, not above an empty meta", function()
      local card = newCard()
      card:SetCustomData({ title = "T", difficultyLevel = 1, difficultyLabel = "Easy",
        actions = { use = { name = "Use", func = function() end } } })
      assert.same({ "BOTTOMLEFT", card.buttons[1].frame, "TOPLEFT", 0, 10 },
        card.difficultyLine.points[1])
    end)

    it("counts neither the empty meta's height nor a gap for it", function()
      local card = newCard()
      card.meta.stringHeight = 12 -- a FontString that would still measure tall while showing ""
      card:SetCustomData({ title = "T" })
      local blank = card.frame:GetHeight()
      card:SetCustomData({ title = "T", meta = "recommended" })
      assert.equal(blank + 6 + 12, card.frame:GetHeight(),
        "a meta line with text costs GAP + its height; an empty one must cost nothing")
    end)

    it("goes back to reserving the row when meta is filled in again", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      card:SetCustomData({ title = "T", meta = "recommended" })
      assert.same({ "BOTTOMLEFT", card.meta, "TOPLEFT", 0, 6 }, card.difficultyLine.points[1])
    end)
  end)

  -- PB2: `meta` and `difficultyLine` move to a DIFFERENT anchor (a button's edge instead of the
  -- frame's own) once a button appears -- proving `ClearAllPoints` actually runs, not just that a
  -- new `SetPoint` was added on top of a stale one the fake `points` array would otherwise still
  -- show at index 1 (exactly the shape of bug D15/PA1's own button test already guards against).
  it("re-anchors meta and the difficulty line, not just adds to their old points, when a button appears",
    function()
      local card = newCard()
      card:SetCustomData({ title = "T", meta = "m" }) -- no buttons: meta anchors to the frame
      card:SetCustomData({ title = "T", meta = "m", actions = {
        use = { name = "Use", func = function() end } } })
      assert.equal(2, #card.meta.points)
      assert.equal(2, #card.difficultyLine.points)
      assert.same({ "BOTTOMLEFT", card.buttons[1].frame, "TOPLEFT", 0, 10 }, card.meta.points[1])
      assert.same({ "BOTTOMLEFT", card.meta, "TOPLEFT", 0, 6 }, card.difficultyLine.points[1])
    end)

  -- PB2's actual regression pin: the owner's complaint was that a LONGER description pushed this
  -- block further down than a shorter card's. A description's height never enters the formula this
  -- block anchors with any more, so it must not move `meta`/`difficultyLine` at all -- proven here by
  -- inflating `summary`'s measured height and re-running `SetCustomData` (which is what a real
  -- content update does) and checking the points are byte-for-byte the same as the short-summary
  -- case above.
  it("does not move meta or the difficulty line when the description grows taller", function()
    local card = newCard()
    card:SetCustomData({ title = "T", summary = "Short.", meta = "m" })
    local shortMeta, shortDifficulty = card.meta.points[1], card.difficultyLine.points[1]

    card.summary.stringHeight = 300 -- simulates a long, wrapped description
    card:SetCustomData({ title = "T", meta = "m",
                         summary = "A much, much longer description that wraps." })
    assert.same(shortMeta, card.meta.points[1])
    assert.same(shortDifficulty, card.difficultyLine.points[1])
  end)

  describe("PA6: difficulty is drawn as real pip TEXTURES, not FontString glyphs", function()
    -- The 2026-09-08 correction: this client's font has no ●/○ glyphs at all (tasks/lessons.md), so
    -- a glyph-based test would have passed against a card that renders three identical boxes
    -- regardless of difficulty -- proving nothing about what a player actually sees. These tests
    -- check the TEXTURE side: that three exist, that alpha (never colour) is what tells them apart,
    -- and that the filled count is the one thing that changes with the level.
    it("creates exactly three pip textures, using this widget's own confirmed-present texture",
      function()
        local card = newCard()
        assert.equal(3, #card.pips)
        for i = 1, 3 do assert.equal("Interface\\ChatFrame\\ChatFrameBackground", card.pips[i]:GetTexture()) end
      end)

    it("sizes every pip the same and chains them left to right, the label after the last one",
      function()
        local card = newCard()
        for i = 1, 3 do
          assert.equal(10, card.pips[i]:GetWidth())
          assert.equal(10, card.pips[i]:GetHeight())
        end
        assert.same({ "TOPLEFT", card.difficultyLine, "TOPLEFT", 0, 0 }, card.pips[1].points[1])
        assert.same({ "LEFT", card.pips[1], "RIGHT", 3, 0 }, card.pips[2].points[1])
        assert.same({ "LEFT", card.pips[2], "RIGHT", 3, 0 }, card.pips[3].points[1])
        assert.same({ "LEFT", card.pips[3], "RIGHT", 6, 0 }, card.difficultyLabel.points[1])
      end)

    it("hides all three pips and the label, and collapses the line, when no difficulty is given",
      function()
        local card = newCard()
        card:SetCustomData({ title = "T" })
        for i = 1, 3 do assert.is_false(card.pips[i]:IsShown()) end
        assert.equal("", card.difficultyLabel:GetText())
        assert.equal(0, card.difficultyLine:GetHeight())
      end)

    it("shows the label and fills exactly the pips up to the given level, by ALPHA not colour",
      function()
        local card = newCard()
        card:SetCustomData({ title = "T", difficultyLevel = 2, difficultyLabel = "Medium" })
        assert.equal("Medium", card.difficultyLabel:GetText())
        assert.equal(1, card.pips[1]:GetAlpha())
        assert.equal(1, card.pips[2]:GetAlpha())
        assert.is_true(card.pips[3]:GetAlpha() < 1)
        for i = 1, 3 do assert.is_true(card.pips[i]:IsShown()) end
      end)

    it("fills every pip for the top tier and only the first for the bottom one", function()
      local card = newCard()
      card:SetCustomData({ title = "T", difficultyLevel = 3, difficultyLabel = "Hard" })
      for i = 1, 3 do assert.equal(1, card.pips[i]:GetAlpha()) end

      card:SetCustomData({ title = "T", difficultyLevel = 1, difficultyLabel = "Easy" })
      assert.equal(1, card.pips[1]:GetAlpha())
      assert.is_true(card.pips[2]:GetAlpha() < 1)
      assert.is_true(card.pips[3]:GetAlpha() < 1)
    end)

    -- The pooled-widget trap review flagged: a card released at one difficulty and
    -- reacquired for a DIFFERENT one must show the NEW count, not the previous card's -- exactly the
    -- class of bug a glyph-based test could never have caught, because it is about STATE surviving
    -- release, not about what character renders.
    it("shows the new card's own difficulty after being released and reacquired for a different one",
      function()
        local card = newCard()
        card:SetCustomData({ title = "T", difficultyLevel = 3, difficultyLabel = "Hard" })
        card:Release()

        local reused = newCard()
        assert.equal(card, reused, "the pool must hand back the same table, or this proves nothing")
        -- Blanked in between (OnAcquire's own applyData(nil)), not still showing "Hard".
        for i = 1, 3 do assert.is_false(reused.pips[i]:IsShown()) end
        assert.equal("", reused.difficultyLabel:GetText())

        reused:SetCustomData({ title = "T2", difficultyLevel = 1, difficultyLabel = "Easy" })
        assert.equal(1, reused.pips[1]:GetAlpha())
        assert.is_true(reused.pips[2]:GetAlpha() < 1)
        assert.is_true(reused.pips[3]:GetAlpha() < 1)
        assert.equal("Easy", reused.difficultyLabel:GetText())
      end)
  end)

  describe("PA1/PA4: two stacked buttons instead of three chained ones", function()
    it("parents each button to the card and sizes it to the shared button height", function()
      local card = newCard()
      assert.equal(card.frame, card.buttons[1].frame:GetParent())
      assert.equal(card.frame, card.buttons[2].frame:GetParent())
      assert.equal(20, card.buttons[1].frame:GetHeight())
      assert.equal(20, card.buttons[2].frame:GetHeight())
    end)

    -- PB2: a lone button claims the card's own bottom edge directly (it is now the bottom-most
    -- element in the stack), not an offset chained down from `meta`.
    it("anchors a lone shown button to the card's own bottom edge, spanning its width", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() end } } })
      local button = card.buttons[1].frame
      assert.same({ "BOTTOMLEFT", card.frame, "BOTTOMLEFT", 10, 10 }, button.points[1])
      assert.same({ "BOTTOMRIGHT", card.frame, "BOTTOMRIGHT", -10, 10 }, button.points[2])
    end)

    -- A card is fed `SetCustomData` again every time the Rotations page rebuilds (e.g. after a Use
    -- switches the active build); a button's anchors must be RESET first, not accumulate a stale
    -- pair from every earlier update on top of the current one.
    it("clears a button's previous anchors before re-anchoring it on a later update", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = { use = { name = "Use", func = function() end } } })
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() end },
        link = { name = "Copy link", func = function() end } } })
      assert.equal(2, #card.buttons[1].frame.points)
    end)

    -- PB2: built bottom-up, so "link" (the LAST action) is what claims the card's own bottom edge,
    -- and "use" stacks on TOP of it -- the reverse reference of the old top-down chain, but the same
    -- visible order (use above link).
    it("stacks 'use' above 'link', with 'link' owning the card's own bottom edge", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() end },
        link = { name = "Copy link", func = function() end } } })
      local use, link = card.buttons[1].frame, card.buttons[2].frame
      assert.same({ "BOTTOMLEFT", card.frame, "BOTTOMLEFT", 10, 10 }, link.points[1])
      assert.same({ "BOTTOMLEFT", link, "TOPLEFT", 0, 6 }, use.points[1])
    end)

    -- The slot that would have been "use" is simply absent -- "link" must not inherit a gap sized
    -- for a button that never rendered, and must still claim the card's own bottom edge exactly like
    -- the lone-button case above.
    it("anchors the surviving button to the card's own bottom edge when the other slot has no action",
      function()
        local card = newCard()
        card:SetCustomData({ title = "T", actions = {
          link = { name = "Copy link", func = function() end } } })
        assert.is_false(card.buttons[1].frame:IsShown())
        local link = card.buttons[2].frame
        assert.same({ "BOTTOMLEFT", card.frame, "BOTTOMLEFT", 10, 10 }, link.points[1])
      end)

    it("draws every button it is given and fires the right action on click", function()
      local card = newCard()
      local used, linked = false, false
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() used = true end },
        link = { name = "Copy link", func = function() linked = true end },
      } })
      assert.equal("Use", card.buttons[1]:GetText())
      assert.equal("Copy link", card.buttons[2]:GetText())
      assert.is_true(card.buttons[1].frame:IsShown())
      assert.is_true(card.buttons[2].frame:IsShown())
      card.buttons[1].frame:Click(); assert.is_true(used)
      card.buttons[2].frame:Click(); assert.is_true(linked)
    end)

    it("hides and clears a button slot when a later update no longer offers that action", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", desc = "d", func = function() end } } })
      card:SetCustomData({ title = "T", actions = {} })
      assert.is_false(card.buttons[1].frame:IsShown())
      assert.equal("", card.buttons[1]:GetText())
      assert.is_nil(card.buttons[1].events.OnClick)
      assert.is_nil(card.buttons[1].events.OnEnter)
      assert.is_nil(card.buttons[1].events.OnLeave)
    end)

    it("shows a tooltip with the action's own desc on hover, and hides it on leave", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use this anyway", desc = "Weapon: 2H (you have 1H)", func = function() end } } })
      card.buttons[1].frame:Enter()
      assert.equal(card.buttons[1].frame, tooltip.owner)
      assert.equal("ANCHOR_TOPRIGHT", tooltip.anchor)
      assert.equal("Weapon: 2H (you have 1H)", tooltip.text)
      assert.is_true(tooltip.shown)
      card.buttons[1].frame:Leave()
      assert.is_false(tooltip.shown)
    end)

    it("shows no tooltip for an action with no desc", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() end } } })
      card.buttons[1].frame:Enter()
      assert.is_nil(tooltip.text)
      assert.is_falsy(tooltip.shown)
    end)

    -- PA3's own required test: every button this card created is RELEASED (returned to the pool),
    -- not merely hidden -- the exact shape of bug this project shipped once (our buttons on ElvUI's
    -- config window), just one layer down: the leaked object here would be a pooled AceGUI Button,
    -- not the card itself.
    it("releases every button it created back to AceGUI's own pool when the card is released",
      function()
        local card = newCard()
        card:SetCustomData({ title = "T", actions = {
          use = { name = "Use", func = function() end },
          link = { name = "Copy link", func = function() end } } })
        local first, second = card.buttons[1], card.buttons[2]
        card:Release()

        local seen = {}
        seen[AceGUI:Create("Button")] = true
        seen[AceGUI:Create("Button")] = true
        assert.is_true(seen[first], "the first button must come back out of the Button pool")
        assert.is_true(seen[second], "the second button must come back out of the Button pool")
      end)

    -- D4 (review of 65896ad): releasing a card while the cursor is still over it used
    -- to rely on the client firing OnLeave first; GameTooltip is shared cross-addon state, so a
    -- stuck tooltip pointing at a widget that no longer belongs to this card is ours to clean up,
    -- not the next addon's.
    it("hides a showing tooltip when the card is released, even with no OnLeave", function()
      local card = newCard()
      card:SetCustomData({ title = "T", tooltip = "full text" })
      card.frame:Enter()
      assert.is_true(tooltip.shown)
      card:Release()
      assert.is_false(tooltip.shown)
    end)
  end)

  describe("PA9: border and fill carry state, hover brightens the border", function()
    it("uses the normal border/fill by default", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      assert.same({ 0.4, 0.4, 0.4 }, card.frame.backdropBorderColor)
      assert.same({ 0.1, 0.1, 0.1, 0.5 }, card.frame.backdropColor)
    end)

    it("brightens the border and dims neither fill for the rotation in use", function()
      local card = newCard()
      card:SetCustomData({ title = "T", active = true })
      assert.are_not.same({ 0.4, 0.4, 0.4 }, card.frame.backdropBorderColor)
      assert.same({ 0.1, 0.1, 0.1, 0.5 }, card.frame.backdropColor)
    end)

    it("dims both border and fill for a playstyle that cannot run yet", function()
      local card = newCard()
      card:SetCustomData({ title = "T", unavailable = true })
      assert.are_not.same({ 0.4, 0.4, 0.4 }, card.frame.backdropBorderColor)
      assert.are_not.same({ 0.1, 0.1, 0.1, 0.5 }, card.frame.backdropColor)
      -- and it is genuinely DIMMER, not just different
      assert.is_true(card.frame.backdropColor[4] < 0.5)
    end)

    it("brightens whatever the current base border is on hover, and restores it on leave", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      local base = card.frame.backdropBorderColor
      card.frame:Enter()
      local hovered = card.frame.backdropBorderColor
      assert.are_not.same(base, hovered)
      for i = 1, 3 do assert.is_true(hovered[i] >= base[i]) end
      card.frame:Leave()
      assert.same(base, card.frame.backdropBorderColor)
    end)

    -- Not the border from whenever the card was FIRST drawn: a card is fed `SetCustomData` again
    -- every rebuild, and hovering it right after must brighten THIS row's current colour.
    it("hovers the row's current state, not a stale one from an earlier update", function()
      local card = newCard()
      card:SetCustomData({ title = "T", active = true }) -- gold border first
      card:SetCustomData({ title = "T", unavailable = true }) -- then dimmed
      card.frame:Enter()
      -- Exact value, computed the same way `brighten` does (0.22 + 0.25), not just "well below
      -- gold's capped 1.0" -- that alone would not tell dimmed-and-brightened (0.47) apart from a
      -- widget that forgot to update its hover baseline at ALL and fell back to plain NORMAL
      -- brightened (0.4 + 0.25 = 0.65), which is also well below 1.0.
      assert.equal(0.22 + 0.25, card.frame.backdropBorderColor[1])
    end)

    -- PD1-D5: a card can be SELECTED (last clicked, PD1-D2) without a mouse anywhere near it -- shown
    -- as the persistent form of the same brightening hover already applies, so it never invents a
    -- fourth colour or collides with the gold "in use" border above.
    it("brightens a selected card even with no hover, matching the hover value", function()
      local unselected = newCard()
      unselected:SetCustomData({ title = "T", selected = false })
      local card = newCard()
      card:SetCustomData({ title = "T", selected = true })
      assert.are_not.same(unselected.frame.backdropBorderColor, card.frame.backdropBorderColor)
      for i = 1, 3 do
        assert.equal(unselected.frame.backdropBorderColor[i] + 0.25, card.frame.backdropBorderColor[i])
      end
    end)

    it("still shows the gold border on a selected card that is also in use", function()
      local card = newCard()
      card:SetCustomData({ title = "T", active = true, selected = true })
      local color = card.frame.backdropBorderColor
      -- brighten({1.0, 0.83, 0.48}) -- still recognisably gold (red and green pinned at the 1.0 cap,
      -- blue lifted), never the normal or dimmed hue.
      assert.equal(1, color[1])
      assert.equal(1, color[2])
      assert.equal(0.48 + 0.25, color[3])
    end)

    -- PD1b-D1 (the hover glitch this fix closes): PD1-D5 stored an ALREADY-brightened value in
    -- `self.baseBorder` for a selected card, so `OnEnter`'s own `brighten(self.baseBorder)` brightened
    -- it a SECOND time -- a selected card read 0.9 on hover where an unselected card's hover read
    -- 0.65. The full required matrix: {unselected, selected} x {unhovered, hovered} x {normal, gold
    -- BORDER_ACTIVE, dim BORDER_DIM}, asserted as rendered colour VALUES -- the one combination
    -- (selected + hovered) no earlier spec in this file ever exercised.
    describe("hover always brightens from the UNSELECTED base, exactly once, in every state", function()
      local function makeCard(extra)
        local data = { title = "T" }
        for k, v in pairs(extra) do data[k] = v end
        local card = newCard()
        card:SetCustomData(data)
        return card
      end

      it("normal base", function()
        local unselected = makeCard({})
        assert.same({ 0.4, 0.4, 0.4 }, unselected.frame.backdropBorderColor)

        unselected.frame:Enter()
        local unselectedHovered = { unpack(unselected.frame.backdropBorderColor) }
        assert.equal(0.4 + 0.25, unselectedHovered[1])
        unselected.frame:Leave()
        assert.same({ 0.4, 0.4, 0.4 }, unselected.frame.backdropBorderColor)

        local selected = makeCard({ selected = true })
        assert.equal(0.4 + 0.25, selected.frame.backdropBorderColor[1])
        assert.same(unselectedHovered, selected.frame.backdropBorderColor)

        selected.frame:Enter()
        assert.equal(0.4 + 0.25, selected.frame.backdropBorderColor[1],
          "hovering an already-selected card must not brighten it a second time")

        selected.frame:Leave()
        assert.equal(0.4 + 0.25, selected.frame.backdropBorderColor[1],
          "leaving a selected card must not visually deselect it")
      end)

      it("gold BORDER_ACTIVE base (in use)", function()
        local unselected = makeCard({ active = true })
        assert.same({ 1.0, 0.83, 0.48 }, unselected.frame.backdropBorderColor)

        unselected.frame:Enter()
        local unselectedHovered = { unpack(unselected.frame.backdropBorderColor) }
        assert.same({ 1, 1, 0.48 + 0.25 }, unselectedHovered)
        unselected.frame:Leave()
        assert.same({ 1.0, 0.83, 0.48 }, unselected.frame.backdropBorderColor)

        local selected = makeCard({ active = true, selected = true })
        assert.same({ 1, 1, 0.48 + 0.25 }, selected.frame.backdropBorderColor)
        assert.same(unselectedHovered, selected.frame.backdropBorderColor)

        selected.frame:Enter()
        assert.same({ 1, 1, 0.48 + 0.25 }, selected.frame.backdropBorderColor,
          "hovering an already-selected in-use card must not brighten it a second time")

        selected.frame:Leave()
        assert.same({ 1, 1, 0.48 + 0.25 }, selected.frame.backdropBorderColor)
      end)

      it("dim BORDER_DIM base (unavailable)", function()
        local unselected = makeCard({ unavailable = true })
        assert.same({ 0.22, 0.22, 0.22 }, unselected.frame.backdropBorderColor)

        unselected.frame:Enter()
        local unselectedHovered = { unpack(unselected.frame.backdropBorderColor) }
        assert.equal(0.22 + 0.25, unselectedHovered[1])
        unselected.frame:Leave()
        assert.same({ 0.22, 0.22, 0.22 }, unselected.frame.backdropBorderColor)

        local selected = makeCard({ unavailable = true, selected = true })
        assert.equal(0.22 + 0.25, selected.frame.backdropBorderColor[1])
        assert.same(unselectedHovered, selected.frame.backdropBorderColor)

        selected.frame:Enter()
        assert.equal(0.22 + 0.25, selected.frame.backdropBorderColor[1],
          "hovering an already-selected unavailable card must not brighten it a second time")

        selected.frame:Leave()
        assert.equal(0.22 + 0.25, selected.frame.backdropBorderColor[1],
          "leaving a selected card must not visually deselect it")
      end)
    end)
  end)

  describe("PA4: the card body is the Open action", function()
    it("runs the actions.open func on a left click on the card body", function()
      local card = newCard()
      local opened = false
      card:SetCustomData({ title = "T", actions = {
        open = { name = "Open", func = function() opened = true end } } })
      card.frame:MouseUp("LeftButton")
      assert.is_true(opened)
    end)

    it("does not run it on a right click", function()
      local card = newCard()
      local opened = false
      card:SetCustomData({ title = "T", actions = {
        open = { name = "Open", func = function() opened = true end } } })
      card.frame:MouseUp("RightButton")
      assert.is_false(opened)
    end)

    it("draws no Open button -- the body is the only way to trigger it", function()
      local card = newCard()
      card:SetCustomData({ title = "T", actions = {
        open = { name = "Open", func = function() end } } })
      assert.equal("", card.buttons[1]:GetText())
      assert.equal("", card.buttons[2]:GetText())
    end)

    it("shows the given tooltip text on hovering the card body", function()
      local card = newCard()
      card:SetCustomData({ title = "T", tooltip = "Exodin -- fast 2H, single seal (Ret)" })
      card.frame:Enter()
      assert.equal("Exodin -- fast 2H, single seal (Ret)", tooltip.text)
      assert.equal(280, tooltip.width)
    end)

    it("hides the tooltip when the mouse leaves the card body", function()
      local card = newCard()
      card:SetCustomData({ title = "T", tooltip = "full text" })
      card.frame:Enter()
      card.frame:Leave()
      assert.is_false(tooltip.shown)
    end)

    it("enables mouse on the card body, or none of the above ever fires in game", function()
      local card = newCard()
      assert.is_true(card.frame.mouseEnabled)
    end)
  end)

  describe("PA2: height follows content and equalises across a shared layout parent", function()
    it("computes height from the sum of its own content, not a fixed constant", function()
      local card = newCard()
      card.title.stringHeight = 20
      card.summary.stringHeight = 10
      card.meta.stringHeight = 10
      card:SetCustomData({ title = "T", summary = "S", meta = "M" })
      -- PAD*2 + title + GAP + summary + GAP + meta (no difficulty line, no buttons)
      assert.equal(10 * 2 + 20 + 6 + 10 + 6 + 10, card.frame:GetHeight())
    end)

    it("grows when its own content grows", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      local before = card.frame:GetHeight()
      card.summary.stringHeight = 400
      card:SetCustomData({ title = "T", summary = "a much longer paragraph" })
      assert.is_true(card.frame:GetHeight() > before)
    end)

    -- PB2 correction (2026-09-08, owner's next screenshot): `SetCustomData` runs BEFORE AceGUI's
    -- Flow layout ever hands the card its real relWidth, so measuring there answers for whatever
    -- (narrow, or no) width the FontStrings had before -- an undercount for text that will actually
    -- wrap to more lines once the real width lands, which is why the bottom-anchored block (PB2)
    -- started drawing on top of the still-overflowing description. `SetWidth` (AceGUI's own
    -- `WidgetBase:SetWidth`, fired by Flow once it knows the real width) is what must trigger the
    -- AUTHORITATIVE re-measurement -- proven here with a case that only fails against the broken
    -- code: the description's measured height GROWS once the width arrives, simulating text that
    -- did not wrap until the real (narrower) width was known.
    describe("PB2 correction: re-measures once AceGUI hands it a real width", function()
      it("grows taller after SetWidth than the provisional height SetCustomData gave it", function()
        local card = newCard()
        card:SetCustomData({ title = "T", summary = "short" })
        local provisional = card.frame:GetHeight()

        -- Simulates the description turning out to wrap to more lines once the real width is known
        -- (AceGUI's Flow assigning the relWidth pixel width is what fires this, AceGUI-3.0.lua:
        -- 307-313) -- a width-independent fake `GetStringHeight` cannot wrap on its own, so the test
        -- moves the lever the same way the real client's own wrap recompute would.
        card.summary.stringHeight = 60
        card:SetWidth(150)

        assert.is_true(card.frame:GetHeight() > provisional,
          "SetWidth must re-measure and grow the card, not keep SetCustomData's provisional height")
      end)

      it("applies the card's real inner width to the wrapping FontStrings before measuring", function()
        local card = newCard()
        card:SetCustomData({ title = "T", summary = "short" })
        card:SetWidth(150)
        -- PAD (10) inset on both sides -- the same inner width `title`/`summary` are stretch-anchored
        -- to via the frame's own edges.
        assert.equal(130, card.title.width)
        assert.equal(130, card.summary.width)
        assert.equal(130, card.meta.width)
      end)

      -- The regression itself: with the description under-measured, the frame stayed too short and
      -- the bottom-anchored footer (difficultyLine/meta/buttons, PB2) drew on top of the still-
      -- overflowing summary text. A correctly re-measured frame is tall enough that the footer's own
      -- fixed distance from the BOTTOM edge no longer reaches into the space the (now taller) summary
      -- occupies from the TOP -- provable here as the frame growing to at least contain both blocks.
      it("grows enough that the bottom-anchored footer no longer overlaps a description that wraps",
        function()
          local card = newCard()
          card:SetCustomData({ title = "T", summary = "short", meta = "m" })
          card.summary.stringHeight = 200
          card:SetWidth(150)
          -- naturalHeight = PAD*2 + title(0) + GAP + summary(200) + GAP + meta(0); footer (meta) is
          -- anchored PAD above the frame's own bottom edge, so the frame must be at least tall enough
          -- to hold summary's own block PLUS that footer without the two sharing any vertical space.
          assert.equal(10 * 2 + 0 + 6 + 200 + 6 + 0, card.frame:GetHeight())
        end)
    end)

    it("adds the difficulty line's height only when a difficulty is actually shown", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      local without = card.frame:GetHeight()
      card.difficultyLabel.stringHeight = 50
      card:SetCustomData({ title = "T", difficultyLevel = 1, difficultyLabel = "Easy" })
      -- the line's own height is max(pip size, label height) -- 50 here, since 50 > the pip size
      assert.equal(without + 6 + 50, card.frame:GetHeight())
    end)

    it("counts the button rows in its own height", function()
      local card = newCard()
      card:SetCustomData({ title = "T" })
      local without = card.frame:GetHeight()
      card:SetCustomData({ title = "T", actions = {
        use = { name = "Use", func = function() end },
        link = { name = "Copy link", func = function() end } } })
      -- BUTTON_GAP_TOP + 20 + BUTTON_GAP + 20 = 10 + 20 + 6 + 20
      assert.equal(without + 10 + 20 + 6 + 20, card.frame:GetHeight())
    end)

    -- PA2's own required behaviour: cards sharing a ROW (in AceConfigDialog terms, a layout PARENT
    -- -- the page's own content frame, or an inline group's, PA11) equalise to the tallest, so their
    -- button rows still line up, rather than each growing only to its own content.
    it("equalises every card sharing a layout parent to the tallest among them", function()
      local rowParent = fakeParent("Frame")
      local short = newCard()
      short.frame:SetParent(rowParent)
      short:SetCustomData({ title = "T" })

      local tall = newCard()
      tall.frame:SetParent(rowParent)
      tall.summary.stringHeight = 300
      tall:SetCustomData({ title = "T", summary = "a much longer paragraph" })

      assert.equal(tall.frame:GetHeight(), short.frame:GetHeight())
    end)

    it("does not equalise cards that do not share a layout parent", function()
      local pageA, pageB = fakeParent("Frame"), fakeParent("Frame")
      local a = newCard()
      a.frame:SetParent(pageA)
      a:SetCustomData({ title = "T" })
      local shortHeight = a.frame:GetHeight()

      local b = newCard()
      b.frame:SetParent(pageB)
      b.summary.stringHeight = 500
      b:SetCustomData({ title = "T", summary = "a much longer paragraph" })

      assert.is_true(b.frame:GetHeight() > shortHeight)
      assert.equal(shortHeight, a.frame:GetHeight(), "a card on an unrelated page must not be resized")
    end)

    -- Isolates OnWidthSet's OWN contribution: `tall`'s content grows WITHOUT a second
    -- `SetCustomData` call, so the only thing that can possibly re-measure and propagate it is the
    -- `SetWidth` the real Flow layout calls when it assigns a relWidth child its concrete pixel
    -- width (AceGUI-3.0.lua:775/307-313).
    it("recomputes and propagates height via OnWidthSet alone, without a SetCustomData call",
      function()
        local rowParent = fakeParent("Frame")
        local short = newCard()
        short.frame:SetParent(rowParent)
        short:SetCustomData({ title = "T" })

        local tall = newCard()
        tall.frame:SetParent(rowParent)
        tall:SetCustomData({ title = "T" }) -- starts equal to `short`
        assert.equal(short.frame:GetHeight(), tall.frame:GetHeight())

        tall.summary.stringHeight = 300 -- grow the CONTENT directly, no second SetCustomData
        tall:SetWidth(240)

        assert.is_true(tall.frame:GetHeight() > 40, "OnWidthSet itself must have re-measured")
        assert.equal(tall.frame:GetHeight(), short.frame:GetHeight())
      end)

    -- A released card must not keep propping up (or shrinking) a row it no longer belongs to. Uses
    -- a SEPARATE sibling that stays in the row throughout, because a lone released-and-reacquired
    -- card is handed back the SAME pooled table (correct pool behaviour) and so cannot tell a
    -- genuine row-membership bug from its own fresh content.
    it("drops a released card from its row instead of leaving it registered", function()
      local rowParent = fakeParent("Frame")
      local short = newCard()
      short.frame:SetParent(rowParent)
      short:SetCustomData({ title = "T" })

      local tall = newCard()
      tall.frame:SetParent(rowParent)
      tall.summary.stringHeight = 300
      tall:SetCustomData({ title = "T", summary = "a much longer paragraph" })
      local sharedHeight = short.frame:GetHeight()
      assert.equal(tall.frame:GetHeight(), sharedHeight, "sanity: both share the row's height first")

      tall:Release()

      -- Re-measuring `short` on its own is what actually shrinks it back down; PA2 does not promise
      -- a row retroactively shrinks the INSTANT a member leaves, only that a released member stops
      -- being counted the next time the row IS re-measured.
      short:SetCustomData({ title = "T" })
      assert.is_true(short.frame:GetHeight() < sharedHeight,
        "a released card's old height must not still dominate its former row")
    end)

    -- The registry key is `self.row`, kept in sync on every ACTUAL move (not just every call) --
    -- proven across THREE parents so a card that forgets to update its own bookkeeping (as opposed
    -- to just failing to clean up the immediately-previous one) still shows up: it would clean the
    -- wrong (stale) row on its second move and leave itself registered in the row it just left.
    it("keeps its row bookkeeping correct across more than one move, not just the first", function()
      local rowA, rowB, rowC = fakeParent("Frame"), fakeParent("Frame"), fakeParent("Frame")
      local card = newCard()
      card.frame:SetParent(rowA)
      card:SetCustomData({ title = "T" })

      card.frame:SetParent(rowB)
      card.summary.stringHeight = 300
      card:SetCustomData({ title = "T", summary = "long" }) -- big while briefly in row B

      local bInhabitant = newCard()
      bInhabitant.frame:SetParent(rowB)
      bInhabitant:SetCustomData({ title = "T" })
      local sharedHeight = bInhabitant.frame:GetHeight()

      card.frame:SetParent(rowC)
      card.summary.stringHeight = nil
      card:SetCustomData({ title = "T" }) -- small again, now in row C

      -- `card` has left row B for good; re-measuring the only thing still there must shrink back
      -- down, not stay pinned to a stale entry `card` left behind.
      bInhabitant:SetCustomData({ title = "T" })
      assert.is_true(bInhabitant.frame:GetHeight() < sharedHeight)
    end)
  end)

  -- W1a's own required test: hand the released widget to the next consumer and prove nothing of
  -- this card is still on it -- the exact shape of bug this project shipped once (our buttons on
  -- ElvUI's config window).
  it("clears every field on release, so the next consumer of the pool sees nothing of this card",
    function()
      local card = newCard()
      card:SetCustomData({
        title = "Exodin", summary = "Fast 2H.", difficultyLevel = 1, difficultyLabel = "Easy",
        meta = "meta", active = true, selected = true, tooltip = "full text",
        actions = {
          open = { name = "Open", func = function() end },
          use = { name = "Use", func = function() end },
          link = { name = "Copy link", func = function() end },
        },
      })
      card:Release()

      -- Checked BEFORE the next Create(): AceGUI calls OnAcquire on every Create regardless (real
      -- AceGUI-3.0.lua:155-159), which would ALSO blank a widget that only cleared on acquire and
      -- never on release -- so that alone cannot tell "Release cleaned up" from "the next Acquire
      -- happened to". This is the state a widget sits in between the two, which is what W1a is
      -- actually about: nothing may still read as this card while it waits in the pool.
      assert.equal("", card.title:GetText())
      assert.equal("", card.summary:GetText())
      assert.equal("", card.difficultyLabel:GetText())
      for i = 1, 3 do assert.is_false(card.pips[i]:IsShown()) end
      assert.equal(0, card.difficultyLine:GetHeight())
      assert.equal("", card.meta:GetText())
      assert.same({ 0.4, 0.4, 0.4 }, card.frame.backdropBorderColor)
      assert.is_nil(card.onClick)
      assert.is_nil(card.tooltipText)
      -- PD1b-D1: `self.selected` is a field this fix adds -- a pooled card that kept reading as
      -- selected would return the WRONG (brightened) border to `OnLeave` for whichever addon's page
      -- acquires it next, even though `applyData(self, nil)` already reset the visible backdrop above.
      card.frame:Enter()
      card.frame:Leave()
      assert.same({ 0.4, 0.4, 0.4 }, card.frame.backdropBorderColor,
        "a released card must not still read as selected on the next hover/leave")
      -- Every button slot dropped its OWN reference too, not just the pool's -- a card holding on to
      -- an already-released button object is exactly the shape of stale reference this test exists
      -- to catch.
      assert.is_nil(card.buttons[1])
      assert.is_nil(card.buttons[2])

      -- And the next consumer (a second AceConfig page, or another addon's `dialogControl` reuse of
      -- the same TYPE elsewhere) gets the exact same table back, still clean.
      local reused = newCard()
      assert.equal(card, reused, "the pool must hand back the same table, or this proves nothing")
      assert.equal("", reused.title:GetText())
      for i = 1, 2 do assert.is_false(reused.buttons[i].frame:IsShown()) end
    end)
end)
