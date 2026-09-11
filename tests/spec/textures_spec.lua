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
    -- AT9-D4: the countdown's FontString. A real one, recording what it was told: `SetText` with no
    -- `Show`, or a size nobody set, is exactly the "the number is there, you just cannot see it"
    -- failure this channel keeps producing.
    function f:CreateFontString()
      local fs = fakeFrame("FontString")
      fs.shown = false
      fs.SetFont = function(this, path, size, flags) this.font = { path, size, flags } end
      fs.SetTextColor = function(this, r, g, b) this.textColor = { r, g, b } end
      fs.SetText = function(this, t) this.text = t end
      fs.GetText = function(this) return this.text end
      self.fontStrings = self.fontStrings or {}
      self.fontStrings[#self.fontStrings + 1] = fs
      return fs
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
    ns.db = { char = { spells = {}, abilities = {} } }
    ns.now = function() return clock end
    stubPack({ EXORCISM = { id = 1, icon = "icon:exorcism" } })
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent = nil, nil
  end)

  -- Every frame that is currently drawing an indicator. AT6-D4 removed the Indicators anchor, so
  -- every frame this module makes is a texture and a pooled frame that was given back is hidden.
  local function showing()
    local out = {}
    for _, f in ipairs(frames) do
      if f.shown then out[#out + 1] = f end
    end
    return out
  end

  local function switchOn(key)
    A.set(key, "texture", "enabled", true)
  end

  -- ------------------------------------------------------------------ values that arrive from data

  describe("sizeOf / texturePath", function()
    -- AT8-D5: the two sources share one field but a different default -- 48 for the shipped icon,
    -- 200 for a picked file -- and the slider's own range is now 16-512.
    it("clamps a size to the slider's own range", function()
      assert.equal(48, Textures.sizeOf({}))
      assert.equal(48, Textures.sizeOf({ source = "icon" }))
      assert.equal(200, Textures.sizeOf({ source = "path" }))
      assert.equal(16, Textures.sizeOf({ size = 4 }))
      assert.equal(512, Textures.sizeOf({ size = 4000 }))
      assert.equal(96, Textures.sizeOf({ size = 96 }))
    end)

    -- AT8-D5: switching source only touches `size` while it still holds the source it is leaving's
    -- default -- never a size the player actually chose.
    it("flips the size default only when the ability is still sitting on the old one", function()
      assert.is_false(Textures.flipSize("EXORCISM", "icon", "icon"), "same source is a no-op")
      assert.is_true(Textures.flipSize("EXORCISM", "icon", "path"))
      assert.equal(200, A.effective("EXORCISM", "texture").size)
      assert.is_true(Textures.flipSize("EXORCISM", "path", "icon"))
      assert.equal(48, A.effective("EXORCISM", "texture").size)
      -- A size the player chose is left alone.
      A.set("JUDGEMENT", "texture", "size", 64)
      assert.is_false(Textures.flipSize("JUDGEMENT", "icon", "path"))
      assert.equal(64, A.effective("JUDGEMENT", "texture").size)
    end)

    -- AT4-D2: there is no `shape` source any more -- the shipped shapes are eight files in the
    -- picker's first category, reached like every other file, through `path`.
    it("draws the shipped ring for a file source nobody has chosen a file for yet", function()
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", Textures.DEFAULT_PATH)
      assert.equal(Textures.DEFAULT_PATH, Textures.texturePath({ source = "path", path = "" }))
      assert.equal(Textures.DEFAULT_PATH, Textures.texturePath({ source = "path" }))
      -- and a source this code has never heard of is the ability's own icon, not nothing
      assert.equal("icon:exorcism", Textures.texturePath({ source = "shape", shape = "star" }, "EXORCISM"))
    end)

    it("resolves the ability's own icon through Display, and reports nil when there is none", function()
      assert.equal("icon:exorcism", Textures.texturePath({ source = "icon" }, "EXORCISM"))
      assert.is_nil(Textures.texturePath({ source = "icon" }, "JUDGEMENT"))
      -- an unknown source is the icon, not nothing
      assert.equal("icon:exorcism", Textures.texturePath({ source = "spraypaint" }, "EXORCISM"))
    end)

    it("hands back the chosen file, whether it is a path or a numeric file id", function()
      assert.equal("Interface\\Icons\\X", Textures.texturePath({ source = "path", path = "Interface\\Icons\\X" }))
      -- Blizzard's own art is addressable only by file id on this client, stored as the string it
      -- was picked as; TextureLibrary.drawable is what turns it back into a number for SetTexture.
      assert.equal("165558", Textures.texturePath({ source = "path", path = "165558" }))
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
      -- AT6-D4: the centre of the SCREEN, with no anchor of ours in between.
      assert.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, f.point)
    end)

    it("draws the chosen file in the chosen colour at the chosen size", function()
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "source", "path")
      A.set("EXORCISM", "texture", "path", "Interface\\AddOns\\Elmira\\media\\shape_diamond")
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
      assert.is_false(Textures.Fire("EXORCISM", "used"))
      assert.is_false(Textures.Fire("EXORCISM", "expiring"))
      -- `active` ships on too -- asserted on an ability that is not already held for its
      -- suggestion, because one boolean holds a texture no matter how many states want it.
      switchOn("JUDGEMENT")
      assert.is_true(Textures.Fire("JUDGEMENT", "active"))
    end)

    -- AT9-D1 makes three of the five moments held, so two of them holding at once is now the
    -- normal case. The second one must not re-lay the screen out: `held` is one boolean per
    -- ability, and the texture is already standing exactly where the second state would put it.
    it("does nothing when a second held state starts while one already holds", function()
      switchOn("EXORCISM")
      assert.is_true(Textures.Fire("EXORCISM", "suggested"))
      assert.is_false(Textures.Fire("EXORCISM", "active"), "the same texture was shown twice")
      assert.equal(1, #showing())
    end)

    -- AT6-D4, and deliberately the opposite of what the row used to guarantee: two textures nobody
    -- has dragged sit on top of each other, WeakAuras-style. The row that kept them apart moved the
    -- one you had already placed every time a second appeared, which is worse -- and an overlap is
    -- visible and fixable in one drag.
    it("leaves two untouched textures on top of each other at the centre", function()
      switchOn("EXORCISM")
      switchOn("JUDGEMENT")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Fire("JUDGEMENT", "suggested")
      local out = showing()
      assert.equal(2, #out)
      assert.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, out[1].point)
      assert.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, out[2].point)
    end)

    it("anchors a dragged texture at its stored offset from screen centre", function()
      switchOn("EXORCISM")
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

    -- AT9-D1 (owner): the expiry warning is a HELD state now, not a flash. A warning that blinks
    -- once while you are watching the boss is a warning you never got.
    describe("the expiry warning (AT9-D1)", function()
      -- The warning ALONE: `suggested` and `active` ship on, and either would hold the same texture
      -- up for its own reason, which would make every assertion below vacuous.
      local function warnOn()
        switchOn("EXORCISM")
        A.set("EXORCISM", "texture", "suggested", false)
        A.set("EXORCISM", "texture", "active", false)
        A.set("EXORCISM", "texture", "expiring", true)
        Textures.Fire("EXORCISM", "expiring")
        assert.equal(1, #showing())
      end

      it("stays up past the flash length, for as long as the buff is running out", function()
        warnOn()
        local low = { EXORCISM = { active = true, expiring = true, remaining = 2, duration = 30 } }
        assert.is_false(Textures.Sync(nil, low, clock + 9))
        assert.equal(1, #showing(), "the warning was gone a second and a half in")
      end)

      it("goes when the buff is gone", function()
        warnOn()
        Textures.Sync(nil, { EXORCISM = { active = true, expiring = true, remaining = 1 } }, clock)
        assert.is_true(Textures.Sync(nil, { EXORCISM = { active = false } }, clock + 1))
        assert.equal(0, #showing())
      end)

      it("goes when the buff is refreshed back above the threshold", function()
        warnOn()
        assert.is_true(Textures.Sync(nil,
          { EXORCISM = { active = true, expiring = false, remaining = 30, duration = 30 } }, clock))
        assert.equal(0, #showing(), "a warning left standing over a full-length buff")
      end)
    end)

    -- AT9-D4: the countdown. What is asserted is the TEXT on the frame and whether it is shown --
    -- "the FontString exists" is exactly the observation that would pass while nothing was legible.
    describe("the countdown (AT9-D4)", function()
      local function count()
        local f = showing()[1]
        return f and f.fontStrings and f.fontStrings[1] or nil
      end

      local function buffUp(remaining)
        switchOn("EXORCISM")
        Textures.Fire("EXORCISM", "active")
        Textures.Sync(nil, { EXORCISM = { active = true, remaining = remaining, duration = 30 } },
                      clock)
      end

      it("draws the whole seconds left of the buff, rounded up, and follows them down", function()
        buffUp(29.6)
        assert.is_true(count().shown)
        assert.equal("30", count().text)
        Textures.Sync(nil, { EXORCISM = { active = true, remaining = 0.4, duration = 30 } }, clock)
        assert.equal("1", count().text, "the last second read as zero")
      end)

      it("sizes it to the texture in the game's number font, white with an outline", function()
        A.set("EXORCISM", "texture", "size", 120)
        buffUp(10)
        assert.equal(40, count().font[2], "a fixed point size is a smudge or a wall")
        assert.equal("OUTLINE", count().font[3])
        assert.same({ 1, 1, 1 }, count().textColor)
      end)

      it("draws nothing while the texture is up for the suggestion alone", function()
        switchOn("EXORCISM")
        Textures.Fire("EXORCISM", "suggested")
        Textures.Sync("EXORCISM", { EXORCISM = { active = false } }, clock)
        assert.is_false(count().shown, "a number counting down something that is not on you")
      end)

      it("draws nothing when the toggle is off, and clears a number already there", function()
        buffUp(12)
        assert.is_true(count().shown)
        A.set("EXORCISM", "texture", "seconds", false)
        Textures.Sync(nil, { EXORCISM = { active = true, remaining = 11, duration = 30 } }, clock)
        assert.is_false(count().shown)
      end)

      -- The toolbar and the tab's preview have no buff to count: a toggle that shows nothing while
      -- you are looking straight at it is a toggle that appears not to work.
      it("shows a sample while the texture is being moved or previewed", function()
        switchOn("EXORCISM")
        Textures.StartMove("EXORCISM")
        assert.equal("30", count().text)
        Textures.StopMoveMode()
        Textures.Preview("EXORCISM")
        assert.equal("30", count().text)
      end)
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

  -- ------------------------------------------------------------------ AB3-D2: the Move mode

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
    it("stores where it was dropped as an offset from screen centre", function()
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      f.scripts.OnDragStart(f)
      f.centre = { 620, 330 }
      f.scripts.OnDragStop(f)
      assert.is_false(f.moving, "the drag was never ended, so the frame follows the cursor for ever")
      local e = A.effective("EXORCISM", "texture")
      assert.equal(120, e.x)
      assert.equal(-70, e.y)
    end)

    -- The offset is OWN, and (AT1-D2) texture never inherits ANYTHING from All abilities any more:
    -- dragging a linked ability's texture has to move that one and no other.
    it("moves that texture alone, and never through what All abilities holds", function()
      -- The All abilities row has an offset of its own; it must not reach EXORCISM at all.
      A.set(A.ALL, "texture", "x", 999)
      Textures.StartMove("EXORCISM")
      local f = showing()[1]
      f.scripts.OnDragStart(f)
      f.centre = { 400, 400 }
      f.scripts.OnDragStop(f)
      assert.is_false(A.inherits("EXORCISM", "texture"))
      assert.equal(-100, A.effective("EXORCISM", "texture").x)
      assert.equal(0, A.effective("JUDGEMENT", "texture").x)
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

    it("moves the new texture instead of two at once when a second drag starts", function()
      Textures.StartMove("EXORCISM")
      Textures.StartMove("JUDGEMENT")
      assert.equal("JUDGEMENT", Textures.movingKey())
      -- One sample on screen, not two: the first mode's own texture was taken down by the second
      -- mode starting, or the player is dragging one shape while another sits there for ever.
      assert.equal(1, #showing())
      Textures.StopMoveMode()
      assert.equal(0, #showing())
    end)
  end)

  -- ------------------------------------------------------------------ AT6-D5: the held preview

  -- "While an ability's Texture tab is the selected tab in the options window (and the texture is
  -- switched on), the texture is held on screen exactly as configured and follows every change
  -- live." Nothing in the fight is holding it, so nothing in the fight will ever take it away --
  -- every test below is about the RELEASE, because a preview that is never released is a texture
  -- standing in the middle of the screen for the rest of the session with no control left anywhere
  -- to remove it.
  describe("the Texture tab's held preview", function()
    -- The key is remembered whether or not the channel is on, and whether it DRAWS is re-asked on
    -- every layout: ticking "Show a texture for this ability" while the tab is open has to bring
    -- the preview up on that click, and the tab is not re-fed by its own toggle.
    it("draws nothing for a switched-off texture, and everything the moment it is switched on",
      function()
        assert.is_true(Textures.Preview("EXORCISM"))
        assert.equal(0, #showing(), "a switched-off texture was previewed anyway")
        switchOn("EXORCISM")
        Textures.Refresh()
        assert.equal("EXORCISM", Textures.describe().previewKey)
        local f = showing()[1]
        assert.is_not_nil(f, "ticking the switch did not bring the preview up")
        assert.equal("icon:exorcism", f.textures[1].texture)
        assert.same({ 48, 48 }, f.size)
      end)

    it("follows every change on the tab without waiting for a cue to fire", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      A.set("EXORCISM", "texture", "size", 128)
      A.set("EXORCISM", "texture", "color", { r = 1, g = 0, b = 0 })
      Textures.Refresh()
      assert.same({ 128, 128 }, showing()[1].size)
      assert.same({ 1, 0, 0 }, showing()[1].textures[1].vertexColor)
    end)

    -- The tab's Opacity is what the player is dragging while they look at it; a preview that faded
    -- to the floor because the ability happens to be on cooldown reads as a slider doing nothing.
    it("draws at the tab's Opacity, with no fade applied to it", function()
      switchOn("EXORCISM")
      A.set("EXORCISM", "texture", "alpha", 0.6)
      A.set("EXORCISM", "texture", "fill", "cooldown")
      Textures.Preview("EXORCISM")
      assert.equal(0.6, showing()[1].alpha)
      Textures.Sync(nil, { EXORCISM = { cooldown = 10, cooldownFull = 10 } }, clock)
      assert.equal(0.6, showing()[1].alpha, "the fade was applied to the tab's own preview")
    end)

    it("is not taken away by the render loop the way a cue would be", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      Textures.Sync("SOMETHING_ELSE", {}, clock + 99)
      assert.equal(1, #showing())
    end)

    it("is released when the tab is left", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      assert.is_true(Textures.Preview(nil))
      assert.is_nil(Textures.describe().previewKey)
      assert.equal(0, #showing())
    end)

    it("is released when another ability is previewed instead", function()
      switchOn("EXORCISM")
      switchOn("JUDGEMENT")
      Textures.Preview("EXORCISM")
      Textures.Preview("JUDGEMENT")
      assert.equal(1, #showing(), "the previous ability's preview stayed on screen")
      assert.equal("JUDGEMENT", Textures.describe().previewKey)
    end)

    -- The switch at the top of the tab, unticked: the preview has to go on that click, which is
    -- `put` -> `restyle` -> `Refresh` and nothing else.
    it("is released the moment the texture is switched off", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      A.set("EXORCISM", "texture", "enabled", false)
      Textures.Refresh()
      assert.equal(0, #showing())
    end)

    it("is released when a Move mode starts and when it ends", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      Textures.StartMove("EXORCISM")
      assert.is_nil(Textures.describe().previewKey, "the tab's preview and the drag's sample both claimed it")
      assert.equal(1, #showing())
      Textures.StopMoveMode()
      assert.is_nil(Textures.describe().previewKey)
      assert.equal(0, #showing(), "the texture was left standing after Done")
    end)

    it("reports which ability it is holding, for /elm debug textures", function()
      switchOn("EXORCISM")
      Textures.Preview("EXORCISM")
      assert.equal("EXORCISM", Textures.describe().previewKey)
    end)
  end)

  -- FX1-D5, and this is the mode the owner was using when he found the problem: "I can not move it
  -- around since the Configuration page is too big and I can not move the configuration page out of
  -- the screen." The mode asks the options window to step aside, and gives it back.
  describe("the Move mode and the options window (FX1-D5)", function()
    local moves

    before_each(function()
      moves = {}
      ns.Options = {
        BeginMove = function(what, key) moves[#moves + 1] = { "begin", what, key } end,
        EndMove = function() moves[#moves + 1] = { "end" } end,
      }
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
    -- Called from the options panel, which a player can open before the display has ever started:
    -- it must build nothing and throw nothing when there is not one texture on screen.
    it("does nothing and survives with no texture showing at all", function()
      assert.is_true(Textures.Refresh())
      assert.equal(0, #frames)
    end)

    it("repaints what is already on screen, so a slider is not a slider that does nothing", function()
      switchOn("EXORCISM")
      Textures.Fire("EXORCISM", "suggested")
      A.set("EXORCISM", "texture", "size", 128)
      assert.same({ 48, 48 }, showing()[1].size)
      assert.is_true(Textures.Refresh())
      assert.same({ 128, 128 }, showing()[1].size)
    end)
  end)

  -- ------------------------------------------------------------------ AT5-D1: the progress fade

  -- The radial swipe AB4-D1 built drew a dark box over the texture (owner, seeing it over a
  -- PowerAuras arc: "not clockwise or anything -- start being visible or getting invisible"). This
  -- replaces it with a plain opacity multiplier -- no clock, no client animation to drive.
  describe("fillOf and fillFraction (the pure half)", function()
    it("ships with no fill, and refuses one it cannot draw", function()
      assert.equal("none", Textures.fillOf(nil))
      assert.equal("none", Textures.fillOf({}))
      assert.equal("none", Textures.fillOf({ fill = "mana" }))
      assert.equal("cooldown", Textures.fillOf({ fill = "cooldown" }))
      assert.equal("buff", Textures.fillOf({ fill = "buff" }))
      assert.same({ "none", "cooldown", "buff" }, Textures.FILLS)
    end)

    -- A cooldown is FAINT the instant it starts and brightens back up as it recovers: half its
    -- length still to go is half the multiplier.
    it("reads a cooldown as how far it has recovered", function()
      assert.equal(0.5, Textures.fillFraction({ fill = "cooldown" }, { cooldown = 3, cooldownFull = 6 }))
      -- Just cast: none of the cooldown has recovered yet, the faintest the multiplier gets.
      assert.equal(0, Textures.fillFraction({ fill = "cooldown" }, { cooldown = 6, cooldownFull = 6 }))
    end)

    -- The other way round on purpose: a buff is full the instant it appears and fades as it runs
    -- out, so the multiplier IS the fraction remaining.
    it("reads a buff as how much of it is left", function()
      assert.equal(0.75, Textures.fillFraction({ fill = "buff" }, { remaining = 15, duration = 20 }))
      assert.equal(0.25, Textures.fillFraction({ fill = "buff" }, { remaining = 5, duration = 20 }))
    end)

    it("gives nothing when there is nothing running, and nothing when the fade is off", function()
      assert.is_nil(Textures.fillFraction({ fill = "none" }, { cooldown = 4, cooldownFull = 6 }))
      assert.is_nil(Textures.fillFraction({ fill = "cooldown" }, nil))
      -- off cooldown: Core/Track deliberately reports no LENGTH, because the cached one is not a
      -- fact about now -- a bright texture over a cooldown that has not been observed is worse
      -- than one left at a static opacity.
      assert.is_nil(Textures.fillFraction({ fill = "cooldown" }, { cooldown = 0 }))
      assert.is_nil(Textures.fillFraction({ fill = "cooldown" }, { cooldown = 4 }))
      assert.is_nil(Textures.fillFraction({ fill = "buff" }, { remaining = 0, duration = 20 }))
      assert.is_nil(Textures.fillFraction({ fill = "buff" }, { remaining = 5 }))
    end)

    -- A reading taken after the length was observed can exceed it (a cooldown lengthened by a rune,
    -- a buff refreshed to longer than the length last seen). Clamped, so this never reads as MORE
    -- than fully lit.
    it("clamps a remaining that is longer than the length it is measured against", function()
      assert.equal(1, Textures.fillFraction({ fill = "buff" }, { remaining = 40, duration = 20 }))
    end)
  end)

  describe("the fade on screen", function()
    local function fill(kind)
      switchOn("EXORCISM")
      A.setInherit("EXORCISM", "texture", false)
      A.set("EXORCISM", "texture", "fill", kind)
    end

    it("is a static opacity when no fade is picked, even with real numbers in memory", function()
      switchOn("EXORCISM")
      Textures.Sync(nil, { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, clock)
      Textures.Fire("EXORCISM", "suggested")
      assert.equal(1, showing()[1].alpha)
    end)

    it("fades a cooldown texture up from faint as it recovers", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 3, cooldownFull = 6 } }, clock)
      assert.equal(0.5, showing()[1].alpha)
    end)

    it("fades a buff texture down toward the floor as it runs out", function()
      fill("buff")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { active = true, remaining = 5, duration = 20 } }, clock)
      assert.equal(0.25, showing()[1].alpha)
    end)

    -- The floor every static Opacity has always had (AB2-D3): a fade that reaches a zero multiplier
    -- must still read as "faint", not vanish outright.
    it("never goes below the 0.05 floor, even at a zero multiplier", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 6, cooldownFull = 6 } }, clock)
      assert.equal(0.05, showing()[1].alpha)
    end)

    -- The tab's own Opacity slider is the CEILING the fraction multiplies into, not something the
    -- fade replaces.
    it("multiplies the fraction into the tab's own Opacity, not just the fraction alone", function()
      fill("buff")
      A.set("EXORCISM", "texture", "alpha", 0.5)
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { active = true, remaining = 10, duration = 20 } }, clock)
      assert.equal(0.25, showing()[1].alpha)
    end)

    -- Nothing to fade with yet: a fade picked for an ability the client has no numbers for leaves
    -- the opacity exactly where a static one would sit.
    it("leaves the opacity alone while there is nothing to measure", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      assert.equal(1, showing()[1].alpha)
    end)

    -- A texture appears in the same frame its event fires (Fire, not Sync), so the fade has to come
    -- from the numbers the loop last handed over. Without this the opacity would sit static until
    -- something else changes the set of textures on screen -- which can be the whole fight.
    it("fades a texture in the same frame the event that showed it fired", function()
      fill("cooldown")
      Textures.Sync(nil, { EXORCISM = { cooldown = 3, cooldownFull = 6 } }, clock)
      Textures.Fire("EXORCISM", "suggested")
      assert.equal(0.5, showing()[1].alpha)
    end)

    -- `SetAlpha` restarts no animation, so unlike the swipe it replaces there is nothing to guard
    -- against re-pushing: the opacity has to move on every tick that the numbers move, not only on
    -- the ticks the SET of textures on screen changed.
    it("keeps updating on every Sync tick while the texture stays on screen", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 6, cooldownFull = 6 } }, clock)
      assert.equal(0.05, showing()[1].alpha)
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 3, cooldownFull = 6 } }, clock + 1)
      assert.equal(0.5, showing()[1].alpha)
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 0 } }, clock + 2)
      assert.equal(1, showing()[1].alpha, "off cooldown is a static opacity again")
    end)

    it("reports the fill and the current fade fraction, nil when nothing is running", function()
      fill("cooldown")
      Textures.Fire("EXORCISM", "suggested")
      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 3, cooldownFull = 6 } }, clock)
      local row = Textures.describe().textures[1]
      assert.equal("cooldown", row.fill)
      assert.equal(0.5, row.fade)

      Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 0 } }, clock)
      assert.is_nil(Textures.describe().textures[1].fade,
        "a fade that is measuring nothing must not read as one that is working")
    end)
  end)

  -- ------------------------------------------------------------------ /elm debug textures

  describe("describe", function()
    it("says nothing about the thirty-eight abilities that are off", function()
      local d = Textures.describe()
      assert.same({}, d.textures)
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
      -- AT6-D4: the offset from the centre of the screen is the whole of "where", and 0,0 IS the
      -- centre -- there is no placement mode left for the diagnostic to report.
      assert.equal(0, row.x)
      assert.equal(0, row.y)
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
  -- ------------------------------------------------------------------ AT4-D2/D3: the library

  -- What the picker is offered, and why a stored file can draw nothing. Both are answered here
  -- rather than in the picker, so the tab, the window and `/elm debug textures` cannot disagree.
  describe("the texture library on this character", function()
    local function withAddons(loaded)
      ns.Adapter = { addonLoaded = function(name) return loaded[name] == true end }
    end

    before_each(function()
      helper.load("Elmira/Display/TextureLibrary.lua")
      withAddons({})
    end)

    after_each(function()
      _G.LibStub = nil
    end)

    local function keysOf(list)
      local out = {}
      for _, group in ipairs(list) do out[#out + 1] = group.key end
      return out
    end

    it("asks the adapter before offering another addon's files", function()
      local asked = {}
      ns.Adapter = { addonLoaded = function(name) asked[#asked + 1] = name; return true end }
      assert.is_true(Textures.addonLoaded("WeakAuras"))
      assert.same({ "WeakAuras" }, asked)
      -- A client (or a load order) with no adapter cannot say, and "cannot say" must read as no.
      ns.Adapter = nil
      assert.is_false(Textures.addonLoaded("WeakAuras"))
    end)

    it("drops the WeakAuras categories on a character that is not running it", function()
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers" },
        keysOf(Textures.libraryGroups()))
      withAddons({ WeakAuras = true })
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers",
                    "weakauras", "powerauras" }, keysOf(Textures.libraryGroups()))
    end)

    -- LibSharedMedia's category is LIVE -- whatever media packs this player runs -- so it is built
    -- here rather than listed in the library, and it is absent altogether when they run none.
    it("adds the player's own media packs, bar textures and backgrounds alike, once each", function()
      assert.is_falsy(keysOf(Textures.libraryGroups())[8], "a media category with no media library")
      local media = {
        List = function(_, kind)
          if kind == "statusbar" then return { "Smooth", "Shared" } end
          return { "Shared", "Parchment" }
        end,
        Fetch = function(_, kind, name) return "Interface\\Media\\" .. name end,
      }
      _G.LibStub = function(name) return name == "LibSharedMedia-3.0" and media or nil end
      local groups = Textures.libraryGroups()
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers", "sharedmedia" },
        keysOf(groups))
      local entries = groups[8].textures
      assert.equal(3, #entries, "a file registered under both types was listed twice")
      assert.same({ path = "Interface\\Media\\Smooth", name = "Smooth" }, entries[1])
      assert.equal("Parchment", entries[3].name, "the player's own name for it, not one of ours")
    end)

    -- ...and it sits BEFORE the two categories that need WeakAuras, wherever those land.
    it("puts the media category ahead of the WeakAuras ones", function()
      _G.LibStub = function()
        return { List = function() return { "Smooth" } end, Fetch = function() return "file" end }
      end
      withAddons({ WeakAuras = true })
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers",
                    "sharedmedia", "weakauras", "powerauras" }, keysOf(Textures.libraryGroups()))
    end)

    -- AT4-D3. The ring is drawn either way, so the two silences must not read the same.
    it("says which addon a stored file needs, and draws the ring meanwhile", function()
      local e = { source = "path",
                  path = "Interface\\AddOns\\WeakAuras\\Media\\Textures\\Ring_10px.tga" }
      assert.equal("WeakAuras", Textures.missingAddon(e))
      assert.is_nil(Textures.texturePath(e, "EXORCISM"), "it drew a file that is not there")

      withAddons({ WeakAuras = true })
      assert.is_nil(Textures.missingAddon(e))
      assert.equal(e.path, Textures.texturePath(e, "EXORCISM"))
    end)

    it("asks nothing of any addon for a file every client has", function()
      assert.is_nil(Textures.missingAddon({ source = "path", path = "165558" }))
      assert.is_nil(Textures.missingAddon({ source = "icon" }))
      assert.is_nil(Textures.missingAddon(nil))
    end)

    -- The library is a separate file and a load order could leave it out; the indicator must still
    -- paint, and the picker must offer nothing rather than error.
    it("carries on with no library loaded at all", function()
      ns.TextureLibrary = nil
      assert.same({}, Textures.libraryGroups())
      assert.is_nil(Textures.missingAddon({ source = "path", path = "x" }))
      assert.equal("x", Textures.texturePath({ source = "path", path = "x" }))
    end)
  end)
end)
