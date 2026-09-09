local helper = require("tests.helper")

-- Elmira/Display/Textures.lua — the per-ability indicator textures (AB3-D1, AB3-D2).
--
-- The frame fake below RECORDS what was asked of it rather than swallowing it, for the reason
-- queue_spec's does: tests/wow_mock.lua answers every frame method with a no-op, which makes
-- "the texture was placed at x = -28" and "nothing was placed at all" the same observation -- and
-- an indicator that is drawn on top of another indicator is exactly the defect this pass is about.
describe("Display.Textures", function()
  local Textures, A, ns, frames, clock

  local function fakeFrame(kind, name, parent, template)
    -- `mouse` starts nil, not false: EnableMouse(false) and never calling it must not be the same
    -- observation. `points` accumulates, because the real SetPoint ADDS an anchor rather than
    -- replacing one -- which is what makes a missing ClearAllPoints a real defect.
    local f = { kind = kind, name = name, parent = parent, template = template,
                textures = {}, scripts = {}, shown = true,
                points = {}, moving = false, alpha = 1, centre = { 0, 0 } }
    function f:SetSize(w, h) self.size = { w, h } end
    function f:SetMovable(v) self.movable = v and true or false end
    function f:SetClampedToScreen(v) self.clamped = v and true or false end
    function f:SetFrameStrata(v) self.strata = v end
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:RegisterForDrag(...) self.dragButtons = { ... } end
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:GetScript(event) return self.scripts[event] end
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false end
    function f:SetAlpha(v) self.alpha = v end
    function f:GetAlpha() return self.alpha end
    function f:SetPoint(p, rel, rp, x, y)
      self.point = { p, rel, rp, x, y }
      self.points[#self.points + 1] = self.point
    end
    function f:GetPoint()
      local pt = self.point or {}
      return pt[1], pt[2], pt[3], pt[4], pt[5]
    end
    function f:ClearAllPoints() self.point = nil; self.points = {} end
    function f:GetCenter() return self.centre[1], self.centre[2] end
    -- AB4-D1: the `Cooldown` region's own methods, RECORDED. tests/wow_mock.lua answers all six
    -- with a no-op, which makes "the swipe was set to 6 seconds" and "nothing was drawn at all" the
    -- same observation -- and a progress fill that quietly measures nothing is exactly the defect
    -- this project keeps shipping. `cooldownCalls` counts, because SetCooldown RESTARTS the
    -- client's animation: calling it every tick freezes the swipe at its first frame forever.
    function f:SetCooldown(start, duration)
      self.cooldown = { start, duration }
      self.cooldownCalls = (self.cooldownCalls or 0) + 1
    end
    function f:SetReverse(v) self.reverse = v and true or false end
    function f:SetDrawEdge(v) self.drawEdge = v and true or false end
    function f:SetDrawBling(v) self.drawBling = v and true or false end
    function f:SetSwipeColor(r, g, b, a) self.swipeColor = { r, g, b, a } end
    function f:SetHideCountdownNumbers(v) self.hideNumbers = v and true or false end
    function f:SetTexture(t) self.texture = t end
    function f:SetColorTexture(...) self.colorTexture = { ... } end
    function f:SetVertexColor(r, g, b) self.vertexColor = { r, g, b } end
    function f:SetAllPoints() self.allPoints = true end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:CreateTexture()
      local t = fakeFrame("Texture")
      t.shown = true
      self.textures[#self.textures + 1] = t
      return t
    end
    -- PascalCase only, so a field the module assigns (`f.icon`) reads as nil rather than as a
    -- stray function -- a catch-all that answers every key makes a missing child untestable.
    return setmetatable(f, { __index = function(_, k)
      if type(k) == "string" and k:match("^%u") then return function() end end
      return nil
    end })
  end

  local function stubPack(spells)
    ns.Display = {
      currentPack = function() return spells and { class = "PALADIN", spells = spells } end,
      spellName = function(key) return "Name of " .. key end,
      spellIcon = function(key) return spells and spells[key] and spells[key].icon or nil end,
    }
  end

  before_each(function()
    ns = helper.reset()
    frames = {}
    clock = 100
    _G.UIParent = fakeFrame("Frame", "UIParent")
    _G.UIParent.centre = { 500, 400 }
    _G.CreateFrame = function(kind, name, parent, template)
      local f = fakeFrame(kind, name, parent, template)
      frames[#frames + 1] = f
      return f
    end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Spells.lua")
    A = helper.load("Elmira/Core/AbilitySettings.lua")
    Textures = helper.load("Elmira/Display/Textures.lua")
    ns.db = { char = { spells = {}, abilities = {}, textures = { anchor = false } } }
    ns.now = function() return clock end
    stubPack({ EXORCISM = { id = 1, icon = "icon:exorcism" } })
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent = nil, nil
  end)

  local function anchor() return Textures.Create() end

  -- Every frame that is currently drawing an indicator: the anchor is the one CreateFrame made
  -- first, and a pooled frame that was given back is hidden. The `Cooldown` swipe each texture
  -- carries (AB4-D1) is a frame too and is deliberately not one of these -- it is part of the
  -- texture above it, not a second indicator.
  local function showing()
    local out = {}
    for _, f in ipairs(frames) do
      if f ~= Textures.Create() and f.shown and f.kind ~= "Cooldown" then out[#out + 1] = f end
    end
    return out
  end

  -- The swipe belonging to one indicator frame.
  local function swipeOf(f) return f.swipe end

  local function switchOn(key)
    A.set(key, "texture", "enabled", true)
  end

  -- ------------------------------------------------------------------ AB3-D2: the pure row flow

  describe("rowFlow", function()
    it("centres a single texture on the anchor", function()
      assert.same({ { key = "A", x = 0, y = 0, size = 48 } },
        Textures.rowFlow({ { key = "A", size = 48 } }, 8))
    end)

    -- The whole reason the row exists: two textures that would sit on the same pixel are pushed
    -- apart by exactly their two half-widths plus the gap.
    it("separates two textures by their sizes and the gap, still centred", function()
      local out = Textures.rowFlow({ { key = "A", size = 40 }, { key = "B", size = 40 } }, 8)
      assert.equal(-24, out[1].x)
      assert.equal(24, out[2].x)
      assert.equal(48, out[2].x - out[1].x)
      assert.equal(0, out[1].x + out[2].x)
    end)

    it("keeps different sizes from overlapping", function()
      local out = Textures.rowFlow({ { key = "A", size = 16 }, { key = "B", size = 64 } }, 10)
      assert.equal(-37, out[1].x)
      assert.equal(13, out[2].x)
      -- the space between their EDGES is the gap, not a guess: half of each size is what decides
      -- whether a 16px dot beside a 64px ring touches it.
      assert.equal(10, (out[2].x - 32) - (out[1].x + 8))
    end)

    it("defaults the gap rather than treating a missing one as zero", function()
      local out = Textures.rowFlow({ { key = "A", size = 20 }, { key = "B", size = 20 } })
      assert.equal(28, out[2].x - out[1].x)
    end)

    it("returns nothing for nothing", function()
      assert.same({}, Textures.rowFlow({}, 8))
    end)
  end)

  -- ------------------------------------------------------------------ values that arrive from data

  describe("sizeOf / placementOf / texturePath", function()
    it("clamps a size to the slider's own range", function()
      assert.equal(48, Textures.sizeOf({}))
      assert.equal(16, Textures.sizeOf({ size = 4 }))
      assert.equal(256, Textures.sizeOf({ size = 4000 }))
      assert.equal(96, Textures.sizeOf({ size = 96 }))
    end)

    -- An unknown placement leaves the frame unanchored in the real client, which draws it in the
    -- bottom-left corner with no hint why. A class pack's defaults and an imported settings string
    -- can both produce one.
    it("falls back to the row for a placement it cannot draw", function()
      assert.equal("row", Textures.placementOf(nil))
      assert.equal("row", Textures.placementOf({ place = "somewhere" }))
      assert.equal("centre", Textures.placementOf({ place = "centre" }))
      assert.equal("custom", Textures.placementOf({ place = "custom" }))
    end)

    it("resolves a shipped shape to its media file, and an unknown shape to the ring", function()
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_star",
        Textures.texturePath({ source = "shape", shape = "star" }))
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring",
        Textures.texturePath({ source = "shape", shape = "octagon" }))
    end)

    it("resolves the ability's own icon through Display, and reports nil when there is none", function()
      assert.equal("icon:exorcism", Textures.texturePath({ source = "icon" }, "EXORCISM"))
      assert.is_nil(Textures.texturePath({ source = "icon" }, "JUDGEMENT"))
      -- an unknown source is the icon, not nothing
      assert.equal("icon:exorcism", Textures.texturePath({ source = "spraypaint" }, "EXORCISM"))
    end)

    it("hands back a custom path, and nil for an empty one", function()
      assert.equal("Interface\\Icons\\X", Textures.texturePath({ source = "custom", path = "Interface\\Icons\\X" }))
      assert.is_nil(Textures.texturePath({ source = "custom", path = "" }))
      assert.is_nil(Textures.texturePath({ source = "custom" }))
    end)
  end)

  -- ------------------------------------------------------------------ AB3-D2: the anchor

  describe("Create", function()
    it("builds one named, movable, click-through anchor and reuses it", function()
      local a = Textures.Create()
      assert.equal("ElmiraIndicators", a.name)
      assert.same({ 1, 1 }, a.size)
      assert.is_true(a.movable)
      assert.is_true(a.clamped, "a row dragged off the edge cannot be dragged back")
      assert.is_false(a.mouse, "an invisible point in the middle of the screen must not eat clicks")
      assert.same({ "LeftButton" }, a.dragButtons)
      assert.equal(a, Textures.Create())
      assert.equal(1, #frames)
    end)

    it("gives it a grip that covers it, in the brand colour, hidden until it is being placed",
      function()
        local grip = Textures.Create().textures[1]
        assert.is_true(grip.allPoints)
        assert.same({ ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.35 },
          grip.colorTexture)
        assert.is_false(grip:IsShown(), "the grip is only for the Move mode")
      end)

    -- AB3-D2's default: above the queue strip, ANCHORED to it rather than copied from it, so
    -- moving the strip takes the indicators with it.
    it("hangs above the queue strip while nothing has dragged it", function()
      local strip = fakeFrame("Frame", "ElmiraQueue")
      ns.Queue = { frame = function() return strip end }
      local a = Textures.Create()
      assert.same({ "BOTTOM", strip, "TOP", 0, 40 }, a.point)
    end)

    it("uses the stored anchor once the row has been placed, and forgets the strip", function()
      local strip = fakeFrame("Frame", "ElmiraQueue")
      ns.Queue = { frame = function() return strip end }
      ns.db.char.textures.anchor = { point = "TOP", relPoint = "TOP", x = 12, y = -300 }
      local a = Textures.Create()
      assert.same({ "TOP", _G.UIParent, "TOP", 12, -300 }, a.point)
    end)

    it("falls back to the middle of the screen with no strip at all", function()
      local a = Textures.Create()
      assert.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, a.point)
    end)

    -- The row follows the strip until it is dragged, so a strip that moved -- or an anchor that
    -- arrived in a settings string -- has to be able to reach it. SetPoint ADDS an anchor point in
    -- the real client, so re-placing without clearing first leaves two fighting each other.
    it("re-places the row on a refresh, with one anchor point and not two", function()
      local a = Textures.Create()
      ns.db.char.textures.anchor = { point = "TOP", relPoint = "TOP", x = 5, y = -50 }
      assert.is_true(Textures.Refresh())
      assert.same({ "TOP", _G.UIParent, "TOP", 5, -50 }, a.point)
      assert.equal(1, #a.points, "the old anchor point was left fighting the new one")
    end)

    it("leaves the row exactly where it is being dragged to", function()
      local a = Textures.Create()
      Textures.StartPositioning()
      a.point = { "TOPLEFT", _G.UIParent, "TOPLEFT", 300, -300 }
      Textures.Refresh()
      assert.same({ "TOPLEFT", _G.UIParent, "TOPLEFT", 300, -300 }, a.point,
        "a slider moved mid-drag snapped the row back")
    end)
  end)

  -- ------------------------------------------------------------------ AB3-D1: Fire

  describe("Fire", function()
    it("draws nothing for an ability whose texture is off -- the default install", function()
      assert.is_false(Textures.Fire("EXORCISM", "suggested"))
      assert.equal(0, #showing())
    end)

    it("builds a click-through, draggable, high-strata frame with a full-size icon", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      local f = showing()[1]
      assert.equal("HIGH", f.strata)
      assert.is_true(f.movable)
      assert.is_true(f.clamped)
      assert.is_false(f.mouse, "a texture must not eat clicks until its own Move mode is on")
      assert.same({ "LeftButton" }, f.dragButtons)
      assert.is_true(f.textures[1].allPoints, "the icon did not cover the frame")
    end)

    it("re-anchors rather than adding a second point every time it is laid out", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Refresh()
      Textures.Refresh()
      assert.equal(1, #showing()[1].points)
    end)

    it("shows the ability's icon at its size, colour and opacity once it is switched on", function()
      switchOn("EXORCISM")
      assert.is_true(Textures.Fire("EXORCISM", "suggested"))
      local f = showing()[1]
      assert.same({ 48, 48 }, f.size)
      assert.equal("icon:exorcism", f.textures[1].texture)
      assert.same({ 1, 1, 1 }, f.textures[1].vertexColor)
      assert.equal(1, f.alpha)
      assert.same({ "CENTER", anchor(), "CENTER", 0, 0 }, f.point)
    end)

    it("draws the chosen shape in the chosen colour at the chosen size", function()
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "source", "shape")
      A.set("EXORCISM", "texture", "shape", "diamond")
      A.set("EXORCISM", "texture", "color", { r = 0.2, g = 0.4, b = 0.9 })
      A.set("EXORCISM", "texture", "size", 120)
      A.set("EXORCISM", "texture", "alpha", 0.5)
      Textures.Fire("EXORCISM", "suggested")
      local f = showing()[1]
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_diamond", f.textures[1].texture)
      assert.same({ 0.2, 0.4, 0.9 }, f.textures[1].vertexColor)
      assert.same({ 120, 120 }, f.size)
      assert.equal(0.5, f.alpha)
    end)

    -- A source that resolves to no file draws the ring rather than nothing: an invisible cue and a
    -- working one look identical, and this way at least something appears to be questioned.
    it("falls back to the ring when the source resolves to no file", function()
      switchOn("JUDGEMENT")
      Textures.Fire("JUDGEMENT", "suggested")
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", showing()[1].textures[1].texture)
    end)

    it("stays silent for a moment that is not ticked", function()
      switchOn("EXORCISM")
      assert.is_false(Textures.Fire("EXORCISM", "ready"))
      assert.equal(0, #showing())
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "ready", true)
      assert.is_true(Textures.Fire("EXORCISM", "ready"))
      assert.equal(1, #showing())
    end)

    -- AB3-D1: `suggested` and `active` ship on, the other three off, and switching the tab on has
    -- to do something the first time or it is the silent failure this project keeps shipping.
    it("ships suggested and active on, and ready/used/expiring off", function()
      switchOn("EXORCISM")
      assert.is_true(Textures.Fire("EXORCISM", "suggested"))
      assert.is_true(Textures.Fire("EXORCISM", "active"))
      assert.is_false(Textures.Fire("EXORCISM", "used"))
      assert.is_false(Textures.Fire("EXORCISM", "expiring"))
    end)

    it("places two textures in a row so they never overlap", function()
      switchOn("EXORCISM")
      switchOn("JUDGEMENT")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Fire("JUDGEMENT", "suggested")
      local out = showing()
      assert.equal(2, #out)
      assert.equal(56, math.abs(out[1].point[4] - out[2].point[4]))
    end)

    -- The row has to read the same way twice: `pairs` has no order, so two ticks showing the same
    -- textures would otherwise swap them round under the player's eyes.
    it("orders the row by key, whatever order the events arrived in", function()
      -- A distinct size per key is what makes the ORDER readable from the coordinates alone: five
      -- identical textures would land on the same five spots in any order.
      local sizes = { A_KEY = 16, B_KEY = 24, C_KEY = 32, D_KEY = 40, E_KEY = 48 }
      for _, key in ipairs({ "E_KEY", "D_KEY", "C_KEY", "B_KEY", "A_KEY" }) do
        switchOn(key)
        A.setInherit(key, "texture", false)
        A.set(key, "texture", "size", sizes[key])
        Textures.Fire(key, "suggested")
      end
      local at = {}
      for _, f in ipairs(showing()) do at[f.size[1]] = f.point[4] end
      -- 16+24+32+40+48 with four 8px gaps is 192 wide, centred, smallest first
      assert.same({ [16] = -88, [24] = -60, [32] = -24, [40] = 20, [48] = 72 }, at)
    end)

    it("anchors a centred texture to the screen, not to the row", function()
      switchOn("EXORCISM")
      A.set("EXORCISM", "texture", "place", "centre")
      Textures.Fire("EXORCISM", "suggested")
      assert.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, showing()[1].point)
    end)

    it("anchors a custom texture at its stored offset from screen centre", function()
      switchOn("EXORCISM")
      A.set("EXORCISM", "texture", "place", "custom")
      A.set("EXORCISM", "texture", "x", -120)
      A.set("EXORCISM", "texture", "y", 260)
      Textures.Fire("EXORCISM", "suggested")
      assert.same({ "CENTER", _G.UIParent, "CENTER", -120, 260 }, showing()[1].point)
    end)
  end)

  -- ------------------------------------------------------------------ AB3-D1: Sync

  describe("Sync", function()
    it("keeps a suggested texture up while it is still the suggestion", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      assert.is_false(Textures.Sync("EXORCISM", {}, clock))
      assert.equal(1, #showing())
    end)

    -- The half a "show while it holds" cue cannot do without: nothing else ever notices the
    -- suggestion moved on, and the texture would sit there for the rest of the session.
    it("takes it down when the suggestion moves on", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      assert.is_true(Textures.Sync("JUDGEMENT", {}, clock))
      assert.equal(0, #showing())
    end)

    it("keeps an active texture up while the buff is up, and drops it when it falls off", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "active")
      assert.is_false(Textures.Sync(nil, { EXORCISM = { active = true } }, clock))
      assert.equal(1, #showing())
      assert.is_true(Textures.Sync(nil, { EXORCISM = { active = false } }, clock))
      assert.equal(0, #showing())
    end)

    it("takes it down the moment the channel is switched off", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      A.set("EXORCISM", "texture", "enabled", false)
      assert.is_true(Textures.Sync("EXORCISM", {}, clock))
      assert.equal(0, #showing())
    end)

    -- AB3-D1: ready/used/expiring are INSTANTS. 1.5 s, then gone, without anything else deciding.
    it("clears a flash after a second and a half and not before", function()
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "used", true)
      Textures.Fire("EXORCISM", "used")
      assert.equal(1.5, Textures.FLASH_SECONDS)
      assert.is_false(Textures.Sync(nil, {}, clock + 1.4))
      assert.equal(1, #showing())
      assert.is_true(Textures.Sync(nil, {}, clock + 1.5))
      assert.equal(0, #showing())
    end)

    it("takes its time from the injected clock when it is not handed one", function()
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "used", true)
      Textures.Fire("EXORCISM", "used")
      clock = clock + 2
      assert.is_true(Textures.Sync(nil, {}))
      assert.equal(0, #showing())
    end)

    it("does nothing at all before Core/AbilitySettings exists", function()
      ns.AbilitySettings = nil
      assert.is_false(Textures.Sync("EXORCISM", {}, clock))
    end)
  end)

  -- ------------------------------------------------------------------ pooling

  describe("pooling", function()
    it("reuses the frame of a texture that came down instead of making a second one", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      local made = #frames
      Textures.Sync("SOMETHING_ELSE", {}, clock)
      switchOn("JUDGEMENT")
      Textures.Fire("JUDGEMENT", "suggested")
      assert.equal(made, #frames, "a second frame was created for a texture the pool could serve")
      assert.equal(1, #showing())

      -- ...and the frame really was given BACK, not lent out twice: showing both at once has to
      -- produce two frames in two places, not one frame answering to two keys.
      Textures.Fire("EXORCISM", "suggested")
      local out = showing()
      assert.equal(2, #out)
      assert.are_not.equal(out[1], out[2])
    end)
  end)

  -- ------------------------------------------------------------------ AB3-D2: the two Move modes

  describe("the Indicators Move mode", function()
    it("puts a sample on screen, makes the anchor grabbable, and puts it all back", function()
      assert.is_false(Textures.isPositioning())
      assert.is_true(Textures.StartPositioning())
      assert.is_true(Textures.isPositioning())
      local a = anchor()
      assert.same({ 160, 40 }, a.size)
      assert.is_true(a.mouse)
      assert.is_true(a.textures[1]:IsShown())
      assert.equal(1, #showing(), "nothing to drag is nothing to place")

      assert.is_true(Textures.StopMoveMode())
      assert.is_false(Textures.isPositioning())
      assert.same({ 1, 1 }, a.size)
      assert.is_false(a.mouse)
      assert.is_false(a.textures[1]:IsShown())
      assert.equal(0, #showing())
    end)

    it("refuses to start twice and reports nothing to stop when no mode is running", function()
      assert.is_false(Textures.StopMoveMode())
      assert.is_true(Textures.StartPositioning())
      assert.is_false(Textures.StartPositioning())
    end)

    it("only drags while the mode is on", function()
      local a = anchor()
      a.scripts.OnDragStart(a)
      assert.is_false(a.moving, "the row must not be draggable by accident at a boss")
      Textures.StartPositioning()
      a.scripts.OnDragStart(a)
      assert.is_true(a.moving)
    end)

    it("stores where it was dropped, and places itself there next time", function()
      local a = anchor()
      Textures.StartPositioning()
      a.scripts.OnDragStart(a)
      a.point = { "TOPLEFT", _G.UIParent, "TOPLEFT", 44, -180 }
      a.scripts.OnDragStop(a)
      assert.is_false(a.moving)
      assert.same({ point = "TOPLEFT", relPoint = "TOPLEFT", x = 44, y = -180 },
        ns.db.char.textures.anchor)
    end)

    it("stores nothing from a drag that never started", function()
      local a = anchor()
      a.point = { "TOPLEFT", _G.UIParent, "TOPLEFT", 44, -180 }
      a.scripts.OnDragStop(a)
      assert.is_false(ns.db.char.textures.anchor)
    end)

    -- Before OnInitialize there is no SavedVariables table to write into, and a drag is still
    -- possible in principle -- storing into nothing must not take the drag down with it.
    it("survives a drag with no settings store at all", function()
      local a = anchor()
      Textures.StartPositioning()
      a.scripts.OnDragStart(a)
      ns.db = nil
      assert.is_true(pcall(function() a.scripts.OnDragStop(a) end))
      assert.is_false(a.moving)
    end)

    it("builds the anchor itself when nothing has yet", function()
      assert.equal(0, #frames)
      assert.is_true(Textures.StartPositioning())
      assert.is_true(#frames >= 1, "the mode had no anchor to place")
    end)

    -- A Move mode the render loop can undo is not a mode: the sample is held by neither a
    -- suggestion nor a buff, so the very next Sync would take it away mid-drag.
    it("is immune to the render loop while it runs", function()
      Textures.StartPositioning()
      assert.is_false(Textures.Sync("NOTHING", {}, clock + 99))
      assert.equal(1, #showing())
    end)
  end)

  describe("moving one texture", function()
    it("shows it whether or not it is switched on, and lets that one frame be dragged", function()
      assert.is_true(Textures.StartMove("EXORCISM"))
      assert.equal("EXORCISM", Textures.movingKey())
      local f = showing()[1]
      assert.is_not_nil(f)
      assert.is_true(f.mouse)
      f.scripts.OnDragStart(f)
      assert.is_true(f.moving)
    end)

    it("refuses a key that is not one", function()
      assert.is_false(Textures.StartMove(nil))
      assert.is_false(Textures.StartMove(""))
      assert.is_nil(Textures.movingKey())
    end)

    -- AB3-D2: "stores an offset from screen centre". Not from the parent, not from the anchor --
    -- the one reference point that survives a resolution change and a strip that moved.
    it("stores where it was dropped as an offset from screen centre, and switches to custom", function()
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      f.scripts.OnDragStart(f)
      f.centre = { 620, 330 }
      f.scripts.OnDragStop(f)
      assert.is_false(f.moving, "the drag was never ended, so the frame follows the cursor for ever")
      local e = A.effective("EXORCISM", "texture")
      assert.equal("custom", e.place)
      assert.equal(120, e.x)
      assert.equal(-70, e.y)
    end)

    -- The offset is OWN, never inherited (AB1-D4's list, extended by AB3-D2): dragging a linked
    -- ability's texture has to move that one and no other.
    it("moves that texture alone, even while it inherits everything else", function()
      -- Both abilities still say "Same as All abilities", and the All abilities row has an offset
      -- of its own. Neither fact may reach the other ability: position is OWN.
      A.set(A.ALL, "texture", "place", "custom")
      A.set(A.ALL, "texture", "x", 999)
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      f.scripts.OnDragStart(f)
      f.centre = { 400, 400 }
      f.scripts.OnDragStop(f)
      assert.is_true(A.inherits("EXORCISM", "texture"))
      assert.equal(-100, A.effective("EXORCISM", "texture").x)
      assert.equal("custom", A.effective("EXORCISM", "texture").place)
      assert.equal(0, A.effective("JUDGEMENT", "texture").x)
      assert.equal("row", A.effective("JUDGEMENT", "texture").place)
    end)

    -- Without the guard, ANY texture's drag-stop stores ITS position against whichever key the
    -- mode is on -- so dragging the wrong shape moves the right one.
    it("ignores a drag of a frame that is not the one being moved", function()
      switchOn("JUDGEMENT")
      Textures.StartMove("EXORCISM")
      Textures.Fire("JUDGEMENT", "suggested")
      local mine, other
      for _, f in ipairs(showing()) do
        if f.mouse then mine = f else other = f end
      end
      assert.is_not_nil(other, "the second texture was never drawn")
      other.centre = { 900, 900 }
      other.scripts.OnDragStop(other)
      assert.equal(0, A.effective("EXORCISM", "texture").x)
      assert.equal("row", A.effective("EXORCISM", "texture").place)
      -- ...and the right frame still works
      mine.centre = { 700, 400 }
      mine.scripts.OnDragStop(mine)
      assert.equal(200, A.effective("EXORCISM", "texture").x)
      assert.is_false(mine.moving, "the drag was never ended")
    end)

    it("stores nothing after the mode has ended", function()
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      Textures.StopMoveMode()
      f.centre = { 900, 900 }
      f.scripts.OnDragStop(f)
      assert.equal(0, A.effective("EXORCISM", "texture").x)
    end)

    -- Two readings that are not a position: a client whose regions cannot report a centre, and a
    -- frame that has never been drawn. Storing either would write a nil offset as if it were one.
    it("stores nothing when no centre can be read", function()
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      f.scripts.OnDragStart(f)
      f.centre = {}
      f.scripts.OnDragStop(f)
      assert.equal(0, A.effective("EXORCISM", "texture").x)

      -- and a client whose UIParent cannot answer at all
      f.centre = { 700, 400 }
      _G.UIParent = {}
      f.scripts.OnDragStop(f)
      assert.equal(0, A.effective("EXORCISM", "texture").x)
    end)

    it("takes the sample away and gives the mouse back when the mode ends", function()
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      assert.is_true(Textures.StopMoveMode())
      assert.is_nil(Textures.movingKey())
      assert.is_false(f.mouse, "a pooled frame that kept mouse input swallows clicks later")
      assert.is_false(f:IsShown())
    end)

    it("ends one mode when the other starts", function()
      Textures.StartPositioning()
      Textures.StartMove("EXORCISM")
      assert.is_false(Textures.isPositioning())
      Textures.StartPositioning()
      assert.is_nil(Textures.movingKey())
    end)
  end)

  -- FX1-D5, and this is the mode the owner was using when he found the problem: "I can not move it
  -- around since the Configuration page is too big and I can not move the configuration page out of
  -- the screen." Both modes ask the options window to step aside, and both give it back.
  describe("the Move modes and the options window (FX1-D5)", function()
    local moves

    before_each(function()
      moves = {}
      ns.Options = {
        BeginMove = function(what, key) moves[#moves + 1] = { "begin", what, key } end,
        EndMove = function() moves[#moves + 1] = { "end" } end,
      }
    end)

    it("asks the window to step aside for the Indicators row, and gives it back", function()
      Textures.StartPositioning()
      assert.same({ "begin", "indicators" }, moves[1])
      Textures.StopMoveMode()
      assert.same({ "end" }, moves[2])
      assert.equal(2, #moves)
    end)

    -- Named, because the bar that replaces the window has to say WHICH texture is being placed.
    it("names the ability whose texture is being moved", function()
      Textures.StartMove("EXORCISM")
      assert.same({ "begin", "texture", "EXORCISM" }, moves[1])
      Textures.StopMoveMode()
      assert.same({ "end" }, moves[2])
    end)

    it("says nothing when there was no mode to start or to end", function()
      assert.is_false(Textures.StopMoveMode())
      assert.is_false(Textures.StartMove(nil))
      assert.equal(0, #moves)
    end)

    it("does not need an options window to move anything", function()
      ns.Options = nil
      assert.is_true(Textures.StartPositioning())
      assert.is_true(Textures.StopMoveMode())
      assert.is_true(Textures.StartMove("EXORCISM"))
      assert.is_true(Textures.StopMoveMode())
    end)
  end)

  -- ------------------------------------------------------------------ against the REAL Display

  -- The tab's DEFAULT source is "this ability's icon", and it resolves through the real
  -- Display.spellIcon -- so this block loads Driver.lua and drives it, instead of stubbing the one
  -- lookup the whole default depends on. A stubbed Display is precisely what hid the defect this
  -- covers (rule review, AB3): the lookup guarded on the class PACK before consulting the merged
  -- registry, so on a character with no shipped data -- every class but paladin, and the standing
  -- rule's own case -- it answered nil for an ability with a perfectly good id, and every texture
  -- silently drew the fallback ring instead.
  describe("the icon source, with no class pack at all", function()
    local Driver

    before_each(function()
      ns.Display = nil
      -- No ns.API and no ns.Adapter, so Display.currentPack() answers nil -- which is what a
      -- character with no shipped class data actually looks like, not an error.
      Driver = helper.load("Elmira/Display/Driver.lua")
      _G.GetSpellTexture = function(id) return "texture:" .. tostring(id) end
      ns.Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
    end)

    after_each(function()
      _G.GetSpellTexture = nil
    end)

    it("really has no pack", function()
      assert.is_nil(Driver.currentPack())
    end)

    it("resolves a registry-only ability's icon", function()
      assert.equal("texture:900", Driver.spellIcon("SLICE_AND_DICE"))
      assert.is_nil(Driver.spellIcon("NOTHING_KNOWS_THIS"), "a key nothing carries still has none")
    end)

    it("draws that icon rather than falling back to the ring", function()
      assert.equal("texture:900", Textures.texturePath({ source = "icon" }, "SLICE_AND_DICE"))
      switchOn("SLICE_AND_DICE")
      Textures.Fire("SLICE_AND_DICE", "suggested")
      assert.equal("texture:900", showing()[1].textures[1].texture)
    end)

    -- The same short-circuit sat on the name lookup, so the ability the texture belongs to was also
    -- reported by its raw key everywhere a sentence names one.
    it("names a registry-only ability from the client, not from its raw key", function()
      ns.BarGlow = { spellName = function(id) return id == 900 and "Slice and Dice" or nil end }
      assert.equal("Slice and Dice", Driver.spellName("SLICE_AND_DICE"))
    end)
  end)

  -- ------------------------------------------------------------------ the Options panel's hooks

  describe("Refresh", function()
    -- Called from the options panel, which a player can open before the display has ever started.
    -- Placing an anchor that does not exist yet throws out of a settings getter, which takes the
    -- whole page down with it.
    it("builds the anchor itself when the panel is opened before the display starts", function()
      assert.equal(0, #frames)
      assert.is_true(Textures.Refresh())
      assert.equal(1, #frames)
    end)

    it("repaints what is already on screen, so a slider is not a slider that does nothing", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      A.set(A.ALL, "texture", "size", 128)
      assert.same({ 48, 48 }, showing()[1].size)
      assert.is_true(Textures.Refresh())
      assert.same({ 128, 128 }, showing()[1].size)
    end)
  end)

  -- ------------------------------------------------------------------ AB4-D1: the progress fill

  -- "Growing textures": a radial swipe over the indicator showing how much of a cooldown or a buff
  -- is left, animated by the client's own `Cooldown` region rather than by our 10 Hz loop.
  describe("fillOf and fillTiming (the pure half)", function()
    it("ships with no fill, and refuses one it cannot draw", function()
      assert.equal("none", Textures.fillOf(nil))
      assert.equal("none", Textures.fillOf({}))
      assert.equal("none", Textures.fillOf({ fill = "mana" }))
      assert.equal("cooldown", Textures.fillOf({ fill = "cooldown" }))
      assert.equal("buff", Textures.fillOf({ fill = "buff" }))
      assert.same({ "none", "cooldown", "buff" }, Textures.FILLS)
    end)

    -- The client animates from a START and a LENGTH; Core/Track reports a REMAINING and a length.
    -- Four seconds left of a six-second cooldown means it started two seconds ago.
    it("back-dates the start of a cooldown by however much has already elapsed", function()
      local start, duration, reverse =
        Textures.fillTiming({ fill = "cooldown" }, { cooldown = 4, cooldownFull = 6 }, 100)
      assert.equal(98, start)
      assert.equal(6, duration)
      assert.is_false(reverse, "a cooldown reads the way every cooldown in the game reads")
    end)

    -- The other way round on purpose: what is LIT is what is left, so the shape shrinks as the
    -- buff runs out instead of growing while it disappears.
    it("runs a buff backwards, so the lit part is what is left of it", function()
      local start, duration, reverse =
        Textures.fillTiming({ fill = "buff" }, { remaining = 5, duration = 20 }, 100)
      assert.equal(85, start)
      assert.equal(20, duration)
      assert.is_true(reverse)
    end)

    it("draws nothing when there is nothing running, and nothing when the fill is off", function()
      assert.is_nil(Textures.fillTiming({ fill = "none" }, { cooldown = 4, cooldownFull = 6 }, 100))
      assert.is_nil(Textures.fillTiming({ fill = "cooldown" }, nil, 100))
      -- off cooldown: Core/Track deliberately reports no LENGTH, because the cached one is not a
      -- fact about now -- a full swipe over a ready ability is worse than no swipe.
      assert.is_nil(Textures.fillTiming({ fill = "cooldown" }, { cooldown = 0 }, 100))
      assert.is_nil(Textures.fillTiming({ fill = "cooldown" }, { cooldown = 4 }, 100))
      assert.is_nil(Textures.fillTiming({ fill = "buff" }, { remaining = 0, duration = 20 }, 100))
      assert.is_nil(Textures.fillTiming({ fill = "buff" }, { remaining = 5 }, 100))
    end)

    -- A reading taken after the length was observed can exceed it (a cooldown lengthened by a rune,
    -- a buff refreshed to longer than the length last seen). A start in the future draws an empty
    -- swipe that never moves.
    it("clamps a remaining that is longer than the length it is measured against", function()
      local start, duration = Textures.fillTiming({ fill = "buff" }, { remaining = 40, duration = 20 }, 100)
      assert.equal(100, start)
      assert.equal(20, duration)
    end)

    it("takes a missing clock as zero rather than erroring", function()
      assert.equal(-2, Textures.fillTiming({ fill = "cooldown" }, { cooldown = 4, cooldownFull = 6 }))
    end)
  end)

  describe("the swipe on screen", function()
    local function fill(kind)
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "fill", kind)
    end

    it("gives every texture a bare Cooldown region that starts hidden", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      local cd = swipeOf(showing()[1])
      assert.equal("Cooldown", cd.kind)
      assert.equal("CooldownFrameTemplate", cd.template)
      assert.equal(showing()[1], cd.parent)
      assert.is_true(cd.allPoints)
      assert.is_true(cd.hideNumbers, "the swipe is a shape, not a second timer to read")
      assert.is_false(cd.drawBling)
      assert.is_false(cd.drawEdge)
      assert.same({ 0, 0, 0, 0.7 }, cd.swipeColor)
      -- Nothing was picked, so nothing is drawn: the shipped answer is "no fill".
      assert.is_false(cd.shown)
      assert.is_nil(cd.cooldownCalls)
    end)

    -- AB4 review. `Cooldown` is a frame type this addon had never used before, and every one of the
    -- calls it needs is unguarded client API. A client that has dropped one must lose the SWIPE,
    -- not every indicator texture on every ability -- and "the texture stopped appearing at all"
    -- would be reported as the texture feature being broken, not as one decoration missing.
    describe("a client whose Cooldown region is missing a method", function()
      -- Rebuilds the module with a Cooldown that answers everything EXCEPT the named methods.
      local function withoutCooldownMethods(...)
        local gone = {}
        for _, name in ipairs({ ... }) do gone[name] = true end
        local realCreate = _G.CreateFrame
        _G.CreateFrame = function(kind, name, parent, template)
          local f = realCreate(kind, name, parent, template)
          if kind == "Cooldown" then
            for stripped in pairs(gone) do rawset(f, stripped, false) end
          end
          return f
        end
        return function() _G.CreateFrame = realCreate end
      end

      it("still draws the texture when a decoration setter is missing", function()
        local restore = withoutCooldownMethods("SetHideCountdownNumbers", "SetSwipeColor")
        switchOn("EXORCISM")
        assert.is_true(Textures.Fire("EXORCISM", "suggested"))
        restore()
        local f = showing()[1]
        assert.equal(1, #showing(), "one missing setter took the whole indicator down")
        assert.equal("icon:exorcism", f.textures[1].texture)
        -- ...and the ones that ARE there were still applied.
        assert.is_false(swipeOf(f).drawEdge)
      end)

      -- SetCooldown and SetReverse are the fill itself. With either gone the swipe is dropped whole
      -- rather than left half-built, so nothing downstream calls into a frame it cannot drive.
      it("drops the swipe entirely, and still fills nothing, when SetCooldown is missing", function()
        local restore = withoutCooldownMethods("SetCooldown")
        switchOn("EXORCISM")
        A.setInherit("EXORCISM", "texture", false)
        A.set("EXORCISM", "texture", "fill", "cooldown")
        assert.is_true(Textures.Fire("EXORCISM", "suggested"))
        -- A tick with real numbers to fill from: this is the call that would reach into the frame.
        Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
        restore()
        assert.equal(1, #showing())
        assert.is_nil(swipeOf(showing()[1]), "a swipe that cannot be driven was kept anyway")
        assert.is_nil(Textures.describe().textures[1].filling)
      end)

      it("drops the swipe when SetReverse is missing too", function()
        local restore = withoutCooldownMethods("SetReverse")
        switchOn("EXORCISM")
        Textures.Fire("EXORCISM", "suggested")
        restore()
        assert.equal(1, #showing())
        assert.is_nil(swipeOf(showing()[1]))
      end)
    end)

    it("sweeps a cooldown from Core/Track's numbers", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      local cd = swipeOf(showing()[1])
      assert.is_true(cd.shown)
      assert.same({ clock - 2, 6 }, cd.cooldown)
      assert.is_false(cd.reverse)
    end)

    it("sweeps a buff the other way", function()
      fill("buff")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { active = true, remaining = 5, duration = 20 } }, clock)
      local cd = swipeOf(showing()[1])
      assert.is_true(cd.shown)
      assert.same({ clock - 15, 20 }, cd.cooldown)
      assert.is_true(cd.reverse)
    end)

    -- The one that decides whether this works at all. SetCooldown RESTARTS the client's animation,
    -- and this runs on every tick -- a re-push ten times a second would leave the swipe frozen at
    -- its opening frame, which looks exactly like a fill that works and measures nothing.
    it("does not re-push a cooldown that is merely ticking down", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      local cd = swipeOf(showing()[1])
      assert.equal(1, cd.cooldownCalls)
      -- The +0.02 is deliberate: two readings of the same running cooldown a tick apart do not
      -- back-date to EXACTLY the same start, and a comparison with no tolerance would call this a
      -- new cooldown every time.
      for i = 1, 5 do
        Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4 - i * 0.1 + 0.02, cooldownFull = 6 } },
                      clock + i * 0.1)
      end
      assert.equal(1, cd.cooldownCalls, "the swipe was restarted on every tick")
    end)

    it("does push again when the cooldown is genuinely re-triggered", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 1, cooldownFull = 6 } }, clock)
      local cd = swipeOf(showing()[1])
      assert.equal(1, cd.cooldownCalls)
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 6, cooldownFull = 6 } }, clock + 5)
      assert.equal(2, cd.cooldownCalls)
      assert.same({ clock + 5, 6 }, cd.cooldown)
    end)

    -- The client's own "there is no cooldown here" is start 0, length 0. Leaving the last swipe
    -- running would show a cooldown recovering on an ability that came off cooldown ages ago.
    it("clears the swipe when there is no longer anything to measure", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      local cd = swipeOf(showing()[1])
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 0 } }, clock + 4)
      assert.is_false(cd.shown)
      assert.same({ 0, 0 }, cd.cooldown)
    end)

    -- Nothing to clear yet: a fresh frame with no fill picked must not push a swipe at all, or
    -- every texture in the addon starts by telling the client about a cooldown of zero.
    it("says nothing to the client at all while the fill is off", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      assert.is_nil(swipeOf(showing()[1]).cooldownCalls)
    end)

    -- A texture appears in the same frame its event fires (Fire, not Sync), so the fill has to come
    -- from the numbers the loop last handed over. Without this the swipe is missing until something
    -- else changes the set of textures on screen -- which can be the whole fight.
    it("fills a texture in the same frame the event that showed it fired", function()
      fill("cooldown")
      Textures.Sync(nil, { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      Textures.Fire("EXORCISM", "suggested")
      assert.same({ clock - 2, 6 }, swipeOf(showing()[1]).cooldown)
    end)

    -- A pooled frame still remembering the last ability's swipe would let the NEXT ability's
    -- identical-looking numbers be skipped as "already pushed", and run somebody else's cooldown.
    it("forgets the swipe when the frame goes back to the pool", function()
      fill("cooldown")
      A.set("JUDGEMENT", "texture", "enabled", true)
      A.setInherit("JUDGEMENT", "texture", false)
      A.set("JUDGEMENT", "texture", "fill", "cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      local cd = swipeOf(showing()[1])
      assert.equal(1, cd.cooldownCalls)

      Textures.Sync("SOMETHING_ELSE", {}, clock)          -- EXORCISM comes down, frame is pooled
      assert.is_false(cd.shown)
      assert.same({ 0, 0 }, cd.cooldown)

      -- The same frame comes back for a different ability with the same numbers, and is re-pushed.
      Textures.Sync("JUDGEMENT", { JUDGEMENT = { cooldown = 4, cooldownFull = 6 } }, clock)
      Textures.Fire("JUDGEMENT", "suggested")
      assert.equal(cd, swipeOf(showing()[1]), "the pool did not serve the same frame")
      assert.equal(3, cd.cooldownCalls)
      assert.same({ clock - 2, 6 }, cd.cooldown)
    end)

    it("reports what the fill is set to and whether anything is running", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      local row = Textures.describe().textures[1]
      assert.equal("cooldown", row.fill)
      assert.equal(6, row.filling)

      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 0 } }, clock)
      assert.is_nil(Textures.describe().textures[1].filling,
        "a fill that is drawing nothing must not read as one that is working")
    end)
  end)

  -- ------------------------------------------------------------------ /elm debug textures

  describe("describe", function()
    it("says nothing about the thirty-eight abilities that are off", function()
      local d = Textures.describe()
      assert.same({}, d.textures)
      assert.is_nil(d.anchor)
    end)

    it("reports the anchor once it has been placed", function()
      ns.db.char.textures.anchor = { point = "CENTER", relPoint = "CENTER", x = 1, y = 2 }
      assert.same({ point = "CENTER", relPoint = "CENTER", x = 1, y = 2 }, Textures.describe().anchor)
    end)

    it("separates 'switched off' from 'on with no moment ticked' from 'never appeared'", function()
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "suggested", false)
      A.set("EXORCISM", "texture", "active", false)
      local row = Textures.describe().textures[1]
      assert.equal("EXORCISM", row.key)
      assert.is_true(row.enabled)
      assert.same({}, row.events)
      assert.is_nil(row.shownAt)
      assert.is_false(row.visible)
    end)

    it("reports what is on screen, when it last appeared, and an unresolvable file", function()
      switchOn("JUDGEMENT")
      Textures.Fire("JUDGEMENT", "suggested")
      local row = Textures.describe().textures[1]
      assert.equal("JUDGEMENT", row.key)
      assert.same({ "suggested", "active" }, row.events)
      assert.equal(100, row.shownAt)
      assert.is_true(row.visible)
      assert.is_nil(row.path, "an icon this client cannot resolve must not read as a working file")
      assert.equal(48, row.size)
      assert.equal("row", row.place)
      assert.equal("icon", row.source)
    end)

    it("still lists an imported settings row for a spell this client has never seen", function()
      A.import({ MYSTERY = { texture = { enabled = true } } }, nil)
      local keys = {}
      for _, row in ipairs(Textures.describe().textures) do keys[#keys + 1] = row.key end
      assert.same({ "MYSTERY" }, keys)
    end)

    it("lists the pack's abilities with no merged registry to read", function()
      ns.Spells = nil
      A.set("EXORCISM", "texture", "enabled", true)
      local keys = {}
      for _, row in ipairs(Textures.describe().textures) do keys[#keys + 1] = row.key end
      assert.same({ "EXORCISM" }, keys)
    end)

    it("reports the abilities in a stable order", function()
      -- EXORCISM is the PACK's key and the other three are the character's own, so the two lists
      -- have to be merged and sorted together -- appending one to the other is not an order.
      for _, key in ipairs({ "E_KEY", "A_KEY", "C_KEY", "EXORCISM" }) do
        A.set(key, "texture", "enabled", true)
      end
      local keys = {}
      for _, row in ipairs(Textures.describe().textures) do keys[#keys + 1] = row.key end
      assert.same({ "A_KEY", "C_KEY", "EXORCISM", "E_KEY" }, keys)
    end)

    it("answers with an empty report before Core/AbilitySettings exists", function()
      ns.AbilitySettings = nil
      assert.same({}, Textures.describe().textures)
    end)
  end)

  describe("TestFire", function()
    it("refuses anything that is not an ability key", function()
      local ok, why = Textures.TestFire(nil)
      assert.is_false(ok)
      assert.is_truthy(why:find("not an ability key", 1, true))
      assert.equal(0, #showing())
    end)

    it("refuses a key this character has never heard of", function()
      local ok, why = Textures.TestFire("HAMMER_OF_WRATH")
      assert.is_false(ok)
      assert.equal("no ability HAMMER_OF_WRATH on this character", why)
      assert.equal(0, #showing())
    end)

    -- The Texture tab's own Preview button, which has to work on the All abilities entry.
    it("previews the All abilities entry by name", function()
      assert.is_true(Textures.TestFire("*"))
      assert.equal(1, #showing())
    end)

    -- Deliberately ignores the switch -- what it answers is "can this draw at all" -- but it must
    -- SAY so, or a bare success line reads as a promise that it will fire in play.
    it("draws a switched-off texture and says it is switched off", function()
      local ok, label = Textures.TestFire("EXORCISM")
      assert.is_true(ok)
      assert.is_truthy(label:find("Name of EXORCISM", 1, true))
      assert.is_truthy(label:find("will not appear in play", 1, true))
      assert.equal(1, #showing())
    end)

    it("says only the name once it is switched on", function()
      switchOn("EXORCISM")
      local _, label = Textures.TestFire("EXORCISM")
      assert.equal("Name of EXORCISM", label)
    end)

    it("clears itself after a second and a half, like any other flash", function()
      Textures.TestFire("EXORCISM")
      assert.is_true(Textures.Sync(nil, {}, clock + 1.5))
      assert.equal(0, #showing())
    end)
  end)
end)
