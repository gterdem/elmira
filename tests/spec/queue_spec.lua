local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Elmira/Display/Queue.lua — the two things about the strip that are not "does it draw": can the
-- user MOVE it, and does hovering it explain anything.
--
-- Both shipped broken, and both looked correct in the source. The container registered for drag but
-- was never given EnableMouse, and every icon on top of it was mouse-enabled, so the drag events
-- went to children that dropped them. The tooltip looked up its entry by `slot.index`, a field
-- nothing sets. Neither had a spec; a spec that only asserted "Create() returns a frame" would have
-- passed against both.
--
-- The frame fake below records what was asked of it instead of swallowing it, which is the whole
-- point: tests/wow_mock.lua's CreateFrame answers every method with a no-op, so EnableMouse(true)
-- and never calling it are indistinguishable there.
describe("Display.Queue", function()
  local Queue, ns, frames, tooltip, clockNow

  local function fakeFrame(kind, name)
    local f = {
      kind = kind, name = name, children = {},
      mouse = false, dragButtons = nil, scripts = {}, shown = true,
      moving = false, movable = false,
      point = { "CENTER", nil, "CENTER", 0, -150 },
    }
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:RegisterForDrag(...) self.dragButtons = { ... } end
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:GetScript(event) return self.scripts[event] end
    function f:SetMovable(v) self.movable = v and true or false end
    function f:SetFrameLevel(v) self.frameLevel = v end
    function f:GetFrameLevel() return self.frameLevel or 3 end
    function f:SetSize(w, h) self.size = { w, h } end
    function f:SetAlpha(v) self.alpha = v end
    function f:GetAlpha() return self.alpha end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false end
    function f:SetPoint(p, rel, rp, x, y)
      if type(rel) == "string" then p, rel, rp, x, y = p, nil, rel, rp, x end
      self.point = { p, rel, rp, x, y }
    end
    function f:GetPoint()
      local pt = self.point or {}
      return pt[1], pt[2], pt[3], pt[4], pt[5]
    end
    function f:ClearAllPoints() self.point = nil; self.cleared = (self.cleared or 0) + 1 end
    function f:SetTexture(t) self.texture = t end
    function f:SetAllPoints() self.allPoints = true end
    function f:SetTexCoord(...) self.texCoord = { ... } end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:CreateTexture() local t = fakeFrame("Texture"); self.children[#self.children + 1] = t; return t end
    -- Animations are the whole point of ADR-0015's strip, so they are recorded rather than
    -- swallowed. wow_mock's catch-all returns nil from CreateAnimationGroup, which would make
    -- "the icon slid" and "nothing happened" the same observation.
    function f:CreateAnimationGroup()
      local group = { anims = {}, played = 0, stopped = 0, scripts = {} }
      group.CreateAnimation = function(grp, animKind)
        local a = { kind = animKind }
        a.SetDuration  = function(an, d) an.duration = d end
        a.SetSmoothing = function(an, m) an.smoothing = m end
        a.SetOffset    = function(an, x, y) an.offset = { x, y } end
        a.SetScale     = function(an, x, y) an.scale = { x, y } end
        a.SetFromAlpha = function(an, v) an.fromAlpha = v end
        a.SetToAlpha   = function(an, v) an.toAlpha = v end
        a.SetOrder     = function(an, o) an.order = o end
        grp.anims[#grp.anims + 1] = a
        grp.anims[animKind] = a
        return a
      end
      group.SetScript = function(grp, event, fn) grp.scripts[event] = fn end
      group.GetScript = function(grp, event) return grp.scripts[event] end
      group.Play = function(grp) grp.played = grp.played + 1 end
      group.Stop = function(grp) grp.stopped = grp.stopped + 1 end
      self.groups = self.groups or {}
      self.groups[#self.groups + 1] = group
      return group
    end
    function f:CreateFontString() local t = fakeFrame("FontString"); self.children[#self.children + 1] = t; return t end
    -- Anything the strip calls that this spec does not care about (SetSize, SetScale, SetAlpha,
    -- SetTexture, SetCooldown, ...) answers as a no-op, but only AFTER the recorded methods above.
    -- PascalCase only: every WoW frame method is PascalCase and every field the addon assigns is
    -- lowercase, so `b.slot` on a slot-less icon must read as nil rather than as a stray function --
    -- a catch-all that answers every key makes "the icon has no suggestion" untestable.
    return setmetatable(f, { __index = function(_, k)
      if type(k) == "string" and k:match("^%u") then return function() end end
      return nil
    end })
  end

  local pack
  local function stubBuild(entries)
    pack = { spells = { EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } } }
    ns.Display = {
      currentPack = function() return pack end,
      activeBuild = function() return { entries = entries or {} }, "PALADIN_EXODIN", "pinned" end,
      -- The strip draws its icons through the Driver's one lookup, so the stub has to answer it.
      spellIcon = function(key)
        local data = pack.spells[key]
        return data and data.id and _G.GetSpellTexture and _G.GetSpellTexture(data.id) or nil
      end,
    }
  end

  before_each(function()
    ns = helper.reset()
    frames = {}
    _G.UIParent = fakeFrame("Frame", "UIParent")
    _G.CreateFrame = function(kind, name)
      local f = fakeFrame(kind, name)
      frames[#frames + 1] = f
      return f
    end
    tooltip = { lines = {}, owner = nil, subject = nil }
    function tooltip:SetOwner(o) self.owner = o end
    function tooltip:SetSpellByID(id) self.subject = id; self.lines = {} end
    function tooltip:SetText(t) self.subject = t; self.lines = {} end
    function tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tooltip:Show() end
    function tooltip:Hide() end
    _G.GameTooltip = tooltip
    _G.GetSpellTexture = function() return "icon" end

    _G.GetSpellInfo = function(id) return "Spell " .. tostring(id) end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    helper.load("Elmira/Core/Transition.lua")
    helper.load("Elmira/Core/Slash.lua")
    Queue = helper.load("Elmira/Display/Queue.lua")
    ns.db = { profile = {
      enabled = true, depth = 3, scale = 1.0, locked = true, learning = false,
      showQueue = true, animate = true,
      -- Every test in this file is about a rotation that IS running; D38's placeholder (own
      -- describe block below) is the one place that unsets this.
      activeBuild = "PALADIN_EXODIN", showPlaceholder = true,
      anchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
      glow = { enabled = false, style = "PIXEL", barGlow = false },
    } }
    -- A clock the spec can move: Queue holds a cast for one GCD, so testing that it is eventually
    -- forgotten needs time to pass.
    clockNow = 0
    ns.API = { GetState = function() return FakeState.new{ now = clockNow } end }
    ns.now = function() return clockNow end
    stubBuild()
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent, _G.GameTooltip, _G.GetSpellTexture = nil, nil, nil, nil
    _G.GetSpellInfo = nil
  end)

  local function container() return Queue.frame() end
  -- Slot buttons only: the container, the five leave/pop ghosts and the Cooldown children are all
  -- frames too. An icon is the one that took a tooltip script.
  local function icons()
    local out = {}
    for _, f in ipairs(frames) do
      if f.kind == "Frame" and f ~= container() and f.scripts.OnEnter then out[#out + 1] = f end
    end
    return out
  end
  local function ghosts()
    local out = {}
    for _, f in ipairs(frames) do
      if f.kind == "Frame" and f ~= container() and not f.scripts.OnEnter and f.groups then
        out[#out + 1] = f
      end
    end
    return out
  end

  describe("it can actually be dragged", function()
    it("the container is mouse-enabled, or it receives no drag events at all", function()
      Queue.Create()
      assert.is_true(container().mouse)
      assert.is_true(container().movable)
      assert.same({ "LeftButton" }, container().dragButtons)
    end)

    it("every icon forwards its drag, because the icons cover the container completely", function()
      Queue.Create()
      local n = 0
      for _, b in ipairs(icons()) do
        if b.scripts.OnEnter then     -- an icon, not the cooldown frame
          n = n + 1
          assert.is_true(b.mouse, "icon " .. n .. " is not mouse-enabled")
          assert.same({ "LeftButton" }, b.dragButtons, "icon " .. n .. " is not registered for drag")
          assert.is_function(b.scripts.OnDragStart, "icon " .. n .. " does not forward OnDragStart")
          assert.is_function(b.scripts.OnDragStop, "icon " .. n .. " does not forward OnDragStop")
        end
      end
      assert.equal(5, n)   -- MAX_SLOTS, all created up front
    end)

    it("dragging an icon while unlocked moves the container and saves where it landed", function()
      Queue.Create()
      Queue.SetLocked(false)
      local icon
      for _, b in ipairs(icons()) do if b.scripts.OnDragStart then icon = icon or b end end

      icon.scripts.OnDragStart(icon)
      assert.is_true(container().moving)

      container().point = { "TOPLEFT", nil, "TOPLEFT", 120, -40 }   -- the user let go over here
      icon.scripts.OnDragStop(icon)
      assert.is_false(container().moving)

      local anchor = ns.db.profile.anchor
      assert.equal("TOPLEFT", anchor.point)
      assert.equal("TOPLEFT", anchor.relPoint)
      assert.equal(120, anchor.x)
      assert.equal(-40, anchor.y)
    end)

    it("dragging while locked does nothing", function()
      Queue.Create()
      Queue.SetLocked(true)
      local icon
      for _, b in ipairs(icons()) do if b.scripts.OnDragStart then icon = icon or b end end
      icon.scripts.OnDragStart(icon)
      assert.is_false(container().moving)
      assert.is_false(Queue.StartMoving())
    end)

    it("the grip reflects the saved lock state at creation, not always hidden", function()
      ns.db.profile.locked = false
      Queue.Create()
      assert.is_true(container().grip.shown)
    end)
  end)

  describe("the hover tooltip explains the suggestion", function()
    local function hover(slot)
      Queue.Create()
      Queue.Render({ slot })
      local icon
      for _, b in ipairs(icons()) do if b.scripts.OnEnter then icon = icon or b end end
      icon.scripts.OnEnter(icon)
      return table.concat(tooltip.lines, "\n")
    end

    it("names the rule that fired and lists its conditions, pass and fail", function()
      local text = hover{
        spell = "JUDGEMENT", label = "Seal expiring",
        entry = { conditions = {
          { label = "seal: Seal of Martyrdom", test = function() return true end },
          { label = "buff: Seal of Martyrdom <= 1.5s", test = function() return false end },
        } },
      }
      assert.truthy(text:find("Seal expiring", 1, true))
      assert.truthy(text:find("Why", 1, true))
      assert.truthy(text:find("seal: Seal of Martyrdom", 1, true))
      assert.truthy(text:find("buff: Seal of Martyrdom <= 1.5s", 1, true))
      -- Passing green, failing red — the colours are the whole message.
      assert.truthy(text:find(ns.Colors.OK.hex .. "seal: Seal of Martyrdom", 1, true))
      assert.truthy(text:find(ns.Colors.BAD.hex .. "buff: Seal of Martyrdom <= 1.5s", 1, true))
    end)

    it("still says something for an entry with no label and no conditions", function()
      -- Exorcism and Crusader Strike in the Exodin build are exactly this, and they are what a
      -- paladin without Seal of Martyrdom is shown all fight: the tooltip used to add nothing.
      local text = hover{ spell = "EXORCISM", entry = { conditions = {} } }
      assert.truthy(text:find("Baseline", 1, true))
      assert.truthy(text:find("Why", 1, true))
      assert.truthy(text:find("nothing above it was ready", 1, true))
    end)

    it("names the active build", function()
      local text = hover{ spell = "EXORCISM", entry = { conditions = {} } }
      assert.truthy(text:find("PALADIN_EXODIN", 1, true))
    end)

    it("takes the entry off the slot, not from an index that nothing sets", function()
      -- The regression, stated directly: a slot carrying its entry must explain itself even when
      -- the compiled build's `entries` list is empty.
      stubBuild({})
      local text = hover{
        spell = "JUDGEMENT", label = "Filler (nothing else ready)",
        entry = { conditions = { { label = "seal: Seal of Martyrdom", test = function() return true end } } },
      }
      assert.truthy(text:find("seal: Seal of Martyrdom", 1, true))
    end)

    it("does nothing at all for an empty slot", function()
      Queue.Create()
      Queue.Render({})
      local icon
      for _, b in ipairs(icons()) do if b.scripts.OnEnter then icon = icon or b end end
      icon.scripts.OnEnter(icon)
      assert.equal(0, #tooltip.lines)
    end)
  end)

  describe("visibility", function()
    it("hides the strip when the driver says hidden", function()
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", false)
      assert.is_false(container().shown)
    end)

    it("shows it again when visible, and omitting the argument still means visible", function()
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", false)
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_true(container().shown)
      Queue.Render({ { spell = "EXORCISM" } })
      assert.is_true(container().shown)
    end)

    -- ADR-0015 §3. The strip and the bar glow were one renderer, so a player who wanted only the
    -- glowing button could not have it: hiding the icons hid the glow with them.
    it("never touches the glow, hidden or shown", function()
      local touched = 0
      ns.Glow = { SetNowSlot = function() touched = touched + 1 end,
                  Render = function() touched = touched + 1 end }
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", false)
      assert.equal(0, touched)
    end)

    it("hides the strip alone when showQueue is off, leaving the display running", function()
      Queue.Create()
      ns.db.profile.showQueue = false
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_false(container().shown)
      assert.is_true(ns.db.profile.enabled)
    end)
  end)

  -- D38: the strip's own nudge while nothing is chosen yet. `wantsPlaceholder` reads
  -- `profile.activeBuild`, never the `key` Render was handed -- several tests above call
  -- `Queue.Render` with no key at all to mean "do not care", and treating that as "no rotation"
  -- would have shown the placeholder throughout the rest of this file.
  describe("the 'no rotation yet' placeholder (D38)", function()
    before_each(function()
      ns.db.profile.activeBuild = false
      ns.API = { GetState = function() return FakeState.new{ now = clockNow, inCombat = false } end }
    end)

    it("shows in place of the icons while nothing is chosen, out of combat", function()
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" } })
      assert.is_true(container().shown)
      assert.is_true(container().placeholder.shown)
      for _, b in ipairs(icons()) do assert.is_false(b.shown, "an icon is still showing") end
    end)

    it("says what it is and what to do", function()
      Queue.Create()
      assert.equal("Elmira: no rotation yet. Click to choose.", container().placeholder.text)
    end)

    it("clicking it opens the Rotations tree", function()
      Queue.Create()
      Queue.Render({})
      local opened
      ns.Options = { Open = function(...) opened = { ... } end }
      container().scripts.OnMouseUp(container(), "LeftButton")
      assert.same({ "rotation" }, opened)
    end)

    it("a right-click, or a click while it is not showing, does nothing", function()
      Queue.Create()
      ns.db.profile.activeBuild = "PALADIN_EXODIN"
      Queue.Render({})   -- the placeholder is hidden again now that a build is active
      local opened = 0
      ns.Options = { Open = function() opened = opened + 1 end }
      container().scripts.OnMouseUp(container(), "LeftButton")
      ns.db.profile.activeBuild = false
      Queue.Render({})
      container().scripts.OnMouseUp(container(), "RightButton")
      assert.equal(0, opened)
    end)

    it("never shows in combat, whatever the toggle says", function()
      Queue.Create()
      ns.API = { GetState = function() return FakeState.new{ now = clockNow, inCombat = true } end }
      -- `visible=false` is the ordinary "hidden, out of combat" reading; in combat, with nothing
      -- chosen, there is genuinely nothing to draw either way -- unlike the out-of-combat case,
      -- which is exactly the one the placeholder exists to override.
      Queue.Render({ { spell = "EXORCISM" } }, nil, false)
      assert.is_false(container().placeholder.shown)
      assert.is_false(container().shown)
    end)

    it("is switched off by its own toggle, not folded into any other setting", function()
      Queue.Create()
      ns.db.profile.showPlaceholder = false
      Queue.Render({}, nil, false)
      assert.is_false(container().placeholder.shown)
      assert.is_false(container().shown)
    end)

    it("disappears, and the icons come back, the moment a rotation is chosen", function()
      Queue.Create()
      Queue.Render({})
      assert.is_true(container().placeholder.shown)
      ns.db.profile.activeBuild = "PALADIN_EXODIN"
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_false(container().placeholder.shown)
      -- All `depth` (3) slots are shown -- alpha, not visibility, is what tells an empty one from a
      -- real suggestion -- so this is the icons coming back at all, not the placeholder's Hide-all.
      local n = 0
      for _, b in ipairs(icons()) do if b.shown then n = n + 1 end end
      assert.equal(3, n)
    end)

    it("is anchored to the left of the strip", function()
      Queue.Create()
      assert.same({ "LEFT", container(), "LEFT", 4, 0 }, container().placeholder.point)
    end)

    -- The click handler answers from its OWN remembered flag, not from the frame's visibility, so
    -- it must not go on believing the placeholder is up once something has hidden the whole strip.
    it("forgets it was showing once the display itself is switched off", function()
      Queue.Create()
      Queue.Render({})
      assert.is_true(container().placeholder.shown)
      ns.db.profile.showQueue = false
      Queue.Render({})
      local opened = 0
      ns.Options = { Open = function() opened = opened + 1 end }
      container().scripts.OnMouseUp(container(), "LeftButton")
      assert.equal(0, opened, "the click still thought the placeholder was showing")
    end)

    -- `rendered` is what the transition plan diffs against; left holding the placeholder's "nothing
    -- on screen" would make the first REAL render believe icons are leaving that were never drawn.
    it("forgets a pending cast and what was on screen while the placeholder is up", function()
      Queue.Create()
      ns.db.profile.activeBuild = "PALADIN_EXODIN" -- this describe's before_each turns it off
      Queue.Render({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" } }, "PALADIN_EXODIN", true)
      Queue.noteCast(415073) -- EXORCISM's shipped id (`stubBuild`, above)
      ns.db.profile.activeBuild = false
      Queue.Render({}) -- placeholder now up: the pending cast and `rendered` both have to go, or
      -- the NEXT real render reads as EXORCISM popping off screen -- exactly the "pops the icon the
      -- player actually cast" transition (above) -- rather than as a fresh rotation's first paint.
      ns.db.profile.activeBuild = "PALADIN_EXODIN"
      Queue.Render({ { spell = "JUDGEMENT" }, { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(0, ghosts()[1].anim.played, "a stale pending cast popped through the placeholder")
    end)
  end)

  describe("hierarchy (ADR-0015 §3)", function()
    it("makes slot 1 bigger and steps the rest down in opacity", function()
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" }, { spell = "EXORCISM" } },
                   "PALADIN_EXODIN", true)
      local b = icons()
      assert.same({ 52, 52 }, b[1].size)
      assert.same({ 40, 40 }, b[2].size)
      assert.equal(1, b[1].alpha)
      assert.equal(0.7, b[2].alpha)
      assert.equal(0.55, b[3].alpha)
    end)

    -- A key to press is a fact about the cast you are making NOW. On a projected slot it is a key
    -- not to press yet, which is worse than no text at all.
    it("puts the keybind on slot 1 only", function()
      ns.BarGlow = { keybindFor = function() return "3" end }
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" } }, "PALADIN_EXODIN", true)
      local b = icons()
      assert.equal("3", b[1].keybind.text)
      assert.equal("", b[2].keybind.text)
    end)
  end)

  describe("motion", function()
    local function slotsOf(...)
      local out = {}
      for i, key in ipairs({ ... }) do out[i] = { spell = key } end
      return out
    end

    it("plays nothing on the first paint: there is no 'before' to come from", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      for _, b in ipairs(icons()) do
        for _, g in ipairs(b.groups or {}) do assert.equal(0, g.played) end
      end
    end)

    it("slides a shifted icon in from where it used to be", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      local b = icons()[1]
      local slide = b.groups[1]
      assert.equal(1, slide.played)
      assert.same({ -56, -0 }, slide.anims.Translation.offset)  -- leftward from slot 2's x, no rise
    end)

    it("drops a promotion in from one icon height above", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("HAMMER", "EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      local slide = icons()[1].groups[1]
      assert.equal(1, slide.played)
      assert.same({ 0, -52 }, slide.anims.Translation.offset)   -- straight down, one slot-1 height
    end)

    it("only fades a tail arrival in", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT", "HAMMER"), "PALADIN_EXODIN", true)
      local b = icons()[3]
      assert.equal(0, b.groups[1].played)          -- no slide
      assert.equal(1, b.groups[2].played)          -- fade only
      assert.equal(0, b.groups[2].anims.Alpha.fromAlpha)
      assert.equal(0.55, b.groups[2].anims.Alpha.toAlpha)
    end)

    it("pops the icon the player actually cast", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.noteCast(415073)                        -- EXORCISM's shipped id
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      local ghost = ghosts()[1]
      assert.equal(1, ghost.anim.played)
      assert.is_true(ghost.shown)
      assert.same({ 52 * 1.15, 52 * 1.15 }, ghost.size)
      assert.is_true(math.abs(ghost.anim.anims.Scale.scale[1] - 1 / 1.15) < 1e-9)
    end)

    -- The defect the owner saw in game: casting slot 1 slid like an ordinary shift instead of
    -- popping. `noteCast` forces an immediate recompute so the pop lands with the press, but that
    -- render happens BEFORE the spell's cooldown registers, so the queue is still identical and
    -- there is nothing to pop. The cast was then cleared anyway, so the real change a fraction of a
    -- second later was drawn as a shift. Two renders, exactly as the client does it.
    it("still pops when the queue has not moved yet at the moment of the cast", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.noteCast(415073)
      -- The cooldown has not landed: same queue, so nothing has left and nothing may animate.
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      assert.equal(0, ghosts()[1].anim.played, "nothing should have left yet")
      -- Now it lands.
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      local ghost = ghosts()[1]
      assert.equal(1, ghost.anim.played, "the departing icon never animated")
      assert.is_truthy(ghost.anim.anims.Scale, "it faded away instead of popping")
      assert.is_true(math.abs(ghost.anim.anims.Scale.scale[1] - 1 / ns.Transition.POP_SCALE) < 1e-9,
        "it left as a shrink, not as a pop")
    end)

    -- Held, but not for ever: a cast whose queue never moves must not pop a change made a minute
    -- later for some unrelated reason.
    it("forgets a cast that was never spent, after one global cooldown", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.noteCast(415073)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      clockNow = clockNow + Queue.CAST_WINDOW + 0.1
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      -- Exorcism is still in the queue, one slot down, so with no pop it simply SHIFTS: nothing
      -- departs and no ghost animates at all. A ghost here would be praise for a press that
      -- happened a global cooldown ago.
      assert.equal(0, ghosts()[1].anim.played, "a stale cast should not pop")
    end)

    -- No clock is not a reason to hold a cast for ever. Without a state the cast is spent on the
    -- next render, which is exactly the behaviour before it was held at all -- no worse, and it
    -- cannot leave a press armed indefinitely.
    it("does not hold a cast on a client with no state to time it by", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.noteCast(415073)
      ns.API = { GetState = function() return nil end }
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      assert.equal(0, ghosts()[1].anim.played, "the cast should not have survived")
    end)

    it("shrinks an icon that just dropped out", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("EXORCISM"), "PALADIN_EXODIN", true)
      local ghost = ghosts()[2]
      assert.equal(1, ghost.anim.played)
      assert.same({ 0.8, 0.8 }, ghost.anim.anims.Scale.scale)
    end)

    it("plays nothing at all when animation is switched off", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      ns.db.profile.animate = false
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      for _, b in ipairs(icons()) do
        for _, g in ipairs(b.groups or {}) do assert.equal(0, g.played) end
      end
      for _, g in ipairs(ghosts()) do assert.equal(0, g.anim.played) end
    end)

    -- The snap-back: a Translation returns the frame to its anchor when it finishes, so without
    -- this the icon would rubber-band to wherever it started every single time.
    it("re-anchors a slid icon at its destination when the slide finishes", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      local b = icons()[1]
      assert.equal(56, b.point[4])                 -- parked at the old home while it slides
      b.groups[1].scripts.OnFinished()
      assert.equal(0, b.point[4])
    end)

    it("forgets the strip while hidden, so it arrives rather than teleports", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(nil, nil, false)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      for _, b in ipairs(icons()) do
        for _, g in ipairs(b.groups or {}) do assert.equal(0, g.played) end
      end
    end)
  end)

  describe("what the buttons and ghosts are built with", function()
    it("gives every slot a slide and a fade, timed and eased", function()
      Queue.Create()
      local b = icons()[1]
      local slide, fade = b.groups[1], b.groups[2]
      assert.equal(0.15, slide.anims.Translation.duration)
      assert.equal("OUT", slide.anims.Translation.smoothing)
      assert.equal(0.15, fade.anims.Alpha.duration)
      assert.equal(0, fade.anims.Alpha.fromAlpha)
    end)

    it("sizes the slots beyond the visible depth so they are ready when depth grows", function()
      Queue.Create()                                   -- depth 3
      assert.same({ 40, 40 }, icons()[5].size)
    end)

    it("builds a hidden ghost per slot that fades out and hides itself", function()
      Queue.Create()
      local g = ghosts()[1]
      -- Below the slot buttons: for 150 ms the departing icon overlaps the one that slid into its
      -- place, and the arriving suggestion is the one that has to stay readable.
      assert.equal(container():GetFrameLevel(), g.frameLevel)
      assert.equal(5, #ghosts())
      assert.is_false(g.shown)
      assert.is_true(g.icon.allPoints)
      assert.same({ 0.07, 0.93, 0.07, 0.93 }, g.icon.texCoord)
      assert.equal(0.15, g.anim.anims.Scale.duration)
      assert.equal(1, g.anim.anims.Alpha.fromAlpha)
      assert.equal(0, g.anim.anims.Alpha.toAlpha)
      assert.equal(0.15, g.anim.anims.Alpha.duration)
      g.shown = true
      g.anim.scripts.OnFinished()
      assert.is_false(g.shown)                         -- or every ghost stays on screen forever
    end)
  end)

  describe("Layout", function()
    it("sizes the container to the icons, tall enough for the big one", function()
      Queue.Create()
      assert.same({ 140, 52 }, container().size)
    end)

    it("anchors, sizes and dims each visible slot", function()
      Queue.Create()
      local b = icons()
      assert.equal(0, b[1].point[4])
      assert.equal(56, b[2].point[4])
      assert.same({ 52, 52 }, b[1].size)
      assert.equal(0.7, b[2].alpha)
    end)
  end)

  describe("motion, continued", function()
    local function slotsOf(...)
      local out = {}
      for i, key in ipairs({ ... }) do out[i] = { spell = key } end
      return out
    end

    it("restarts a slide that was already running rather than stacking two", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "K", true)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      assert.equal(2, icons()[1].groups[1].stopped)
    end)

    it("restarts a fade the same way", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      assert.equal(2, icons()[2].groups[2].stopped)
    end)

    it("re-anchors a sliding icon at its origin, not wherever it last stopped", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      local before = icons()[1].cleared
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "K", true)
      assert.is_true(icons()[1].cleared > before)
    end)

    -- Slot 1 settles at x=0, which is also what `b.destX or 0` falls back to -- so a slide that
    -- forgot its destination looks correct there and nowhere else. Slot 2 is where it shows.
    it("settles a slid icon at ITS slot, not at the start of the strip", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "K", true)
      local b = icons()[2]
      b.groups[1].scripts.OnFinished()
      assert.equal(56, b.point[4])
    end)

    it("clears the old anchor when a slide settles", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "K", true)
      local b = icons()[1]
      local before = b.cleared
      b.groups[1].scripts.OnFinished()
      assert.is_true(b.cleared > before)
    end)

    it("draws the leaving icon on the ghost, parked over the slot it left", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      local g = ghosts()[2]
      assert.equal("icon", g.icon.texture)
      assert.equal("CENTER", g.point[1])
      assert.equal(76, g.point[4])            -- slot 2's centre: 56 + 40/2
      assert.equal(1, g.alpha)                -- reset, or a ghost fades once and never again
    end)

    it("restarts a ghost that was still fading", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      assert.equal(2, ghosts()[2].anim.stopped)
    end)

    -- The strip can shrink between renders: the icon that left has no slot to leave FROM.
    it("skips a ghost for a slot the strip no longer has", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT", "HAMMER"), "K", true)
      ns.db.profile.depth = 1
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      assert.equal(0, ghosts()[2].anim.played)
      assert.equal(0, ghosts()[3].anim.played)
    end)

    it("skips a slide from a slot the strip no longer has", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT", "HAMMER"), "K", true)
      ns.db.profile.depth = 1
      Queue.Render(slotsOf("HAMMER"), "K", true)
      assert.equal(0, icons()[1].groups[1].played)
    end)

    -- An empty slot is dimmed to nothing; the next suggestion to land there must be visible again.
    it("restores a slot's opacity after it was empty", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT", "HAMMER"), "K", true)
      Queue.Render(slotsOf("EXORCISM"), "K", true)
      assert.equal(0, icons()[2].alpha)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT", "HAMMER"), "K", true)
      assert.equal(0.7, icons()[2].alpha)
    end)

    it("pops once per cast: the next icon to leave slot 1 only shrinks", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.noteCast(415073)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "K", true)
      assert.is_true(math.abs(ghosts()[1].anim.anims.Scale.scale[1] - 1 / 1.15) < 1e-9)
      -- Back to Exorcism on top, and now it leaves again with nothing cast. A pending cast that
      -- was never cleared would congratulate the player for a press they did not make.
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "K", true)
      Queue.Render(slotsOf("JUDGEMENT", "HAMMER"), "K", true)
      assert.same({ 0.8, 0.8 }, ghosts()[1].anim.anims.Scale.scale)
    end)
  end)

  describe("a build change is not a move", function()
    local function slotsOf(...)
      local out = {}
      for i, key in ipairs({ ... }) do out[i] = { spell = key } end
      return out
    end

    -- Switching profile, fork or build means every icon on screen belonged to another rotation.
    -- Sliding the new build's suggestions in from the old build's slots is a lie about what moved.
    it("does not animate the new build's icons as moves of the old build's", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_PROT", true)
      for _, b in ipairs(icons()) do
        for _, g in ipairs(b.groups or {}) do assert.equal(0, g.played) end
      end
      for _, g in ipairs(ghosts()) do assert.equal(0, g.anim.played) end
    end)

    it("still animates within one build", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      assert.equal(1, icons()[1].groups[1].played)
    end)

    -- The hidden path passes no key. Treating that as a build change would be harmless; treating
    -- the NEXT real key as unchanged would not be.
    it("does not mistake the hidden render's absent key for a build", function()
      Queue.Create()
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(nil, nil, false)
      Queue.Render(slotsOf("EXORCISM", "JUDGEMENT"), "PALADIN_EXODIN", true)
      Queue.Render(slotsOf("JUDGEMENT", "EXORCISM"), "PALADIN_EXODIN", true)
      assert.equal(1, icons()[1].groups[1].played)
    end)
  end)

  describe("noteCast", function()
    it("matches the shipped id", function()
      Queue.Create()
      assert.is_true(Queue.noteCast(415073))
    end)

    -- Classic gives every RANK its own id: the id the client reports for a cast is usually not the
    -- one the pack ships. This is the defect that stopped the bar glow finding buttons.
    it("matches a different rank by name", function()
      Queue.Create()
      _G.GetSpellInfo = function(id)
        if id == 415073 or id == 999999 then return "Exorcism" end
        return "Other " .. tostring(id)
      end
      assert.is_true(Queue.noteCast(999999))
    end)

    it("says so when the id belongs to no spell in the pack", function()
      Queue.Create()
      assert.is_false(Queue.noteCast(4242))
    end)

    it("prefers the id, so a client with no name for it still resolves", function()
      Queue.Create()
      _G.GetSpellInfo = function() return nil end
      assert.is_true(Queue.noteCast(415073))
    end)

    it("says so before there is a pack to look in", function()
      Queue.Create()
      ns.Display.currentPack = function() return nil end
      assert.is_false(Queue.noteCast(415073))
    end)

    it("builds the name index once, not on every cast", function()
      Queue.Create()
      local lookups = 0
      _G.GetSpellInfo = function(id) lookups = lookups + 1; return "Spell " .. tostring(id) end
      Queue.noteCast(415073)
      local afterFirst = lookups
      Queue.noteCast(20271)
      assert.equal(afterFirst, lookups)       -- the id hit the cache; no rebuild, no name lookup
    end)

    -- Nothing downstream of a cast can be seen when the strip is hidden or still, and the
    -- invalidate would force a recompute once per global cooldown for nothing.
    it("ignores a cast nobody can see", function()
      Queue.Create()
      ns.db.profile.showQueue = false
      assert.is_false(Queue.noteCast(415073))
      ns.db.profile.showQueue = true
      ns.db.profile.animate = false
      assert.is_false(Queue.noteCast(415073))
    end)

    -- GetSpellInfo answers nil for a spell whose data has not streamed in yet. Latching that empty
    -- index would silently drop every rank match for the rest of the session.
    it("does not cache an empty name index built before the client had names", function()
      Queue.Create()
      _G.GetSpellInfo = function() return nil end
      Queue.noteCast(415073)
      _G.GetSpellInfo = function(id)
        if id == 415073 or id == 999999 then return "Exorcism" end
        return "Other " .. tostring(id)
      end
      assert.is_true(Queue.noteCast(999999))
    end)

    it("marks the display dirty so the pop lands with the press", function()
      local dirty = 0
      ns.Display.invalidate = function() dirty = dirty + 1 end
      Queue.Create()
      Queue.noteCast(415073)
      assert.equal(1, dirty)
    end)
  end)
end)
