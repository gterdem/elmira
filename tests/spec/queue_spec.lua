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
    -- PE9-D3: an outline is the whole point of the keybind change, and the catch-all below would
    -- make "outlined at 16pt" and "never re-fonted at all" the same observation.
    function f:SetFont(file, size, flags) self.font = { file, size, flags } end
    function f:GetFont() local ft = self.font or {}; return ft[1] or "Fonts\\FRIZQT__.TTF", ft[2], ft[3] end
    function f:SetTextColor(r, g, b) self.textColor = { r, g, b } end
    -- PE9-D2: the dimming is a texture call, and a swallowed one is exactly this project's
    -- "looks right, does nothing".
    function f:SetDesaturated(v) self.desaturated = v and true or false end
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false end
    function f:SetPoint(p, rel, rp, x, y)
      if type(rel) == "string" then p, rel, rp, x, y = p, nil, rel, rp, x end
      self.point = { p, rel, rp, x, y }
      -- EVERY point, not just the last: a frame anchored twice without a ClearAllPoints between
      -- is stretched between both in the client, and `GetPoint` alone cannot tell that from a
      -- frame that was moved.
      self.points = self.points or {}
      self.points[#self.points + 1] = self.point
    end
    function f:GetPoint()
      local pt = self.point or {}
      return pt[1], pt[2], pt[3], pt[4], pt[5]
    end
    function f:ClearAllPoints()
      self.point, self.points = nil, {}
      self.cleared = (self.cleared or 0) + 1
    end
    function f:SetTexture(t) self.texture = t; self.colorTexture = nil end
    -- PE11-D5's sample paints flat brand squares where it has no icon to show, and the swallowed
    -- version of this call made "a coloured square" and "the icon that happened to be there
    -- already" the same observation.
    function f:SetColorTexture(r, g, b, a) self.colorTexture = { r, g, b, a }; self.texture = nil end
    -- AB4-D1's cooldown swipe. `Clear` is what takes a sweep back off a slot, and every path that
    -- stops showing a suggestion calls it -- so a no-op here would make "cleared" untestable.
    function f:SetCooldown(start, duration) self.cooldown = { start, duration } end
    function f:Clear() self.cooldown = nil; self.cdCleared = (self.cdCleared or 0) + 1 end
    -- Only UIParent is ever given one (PE10-D4's scale match reads it); every other frame answers
    -- nil, exactly as the catch-all did.
    function f:GetEffectiveScale() return self.effectiveScale end
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

  -- The REAL Display/Driver.lua underneath (AB4-D4), with only `currentPack` and `activeBuild`
  -- replaced. The strip draws its icons and its tooltip through the Driver's merged-registry
  -- lookups, and those merge THIS CHARACTER'S own registry under the pack -- so a stub shaped like
  -- a pack could never show the case the change is about: no pack at all.
  local pack
  local function stubBuild(entries)
    pack = { spells = { EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } } }
    ns.Display.currentPack = function() return pack end
    ns.Display.activeBuild = function() return { entries = entries or {} }, "PALADIN_EXODIN", "pinned" end
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
    helper.load("Elmira/Core/Spells.lua")
    helper.load("Elmira/Display/Driver.lua")
    Queue = helper.load("Elmira/Display/Queue.lua")
    ns.db = { char = { spells = {} }, profile = {
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

    -- PE13-D2. The on-screen message's move mode overrides the SAME lock this writes, so locking or
    -- unlocking has to end it here -- /elm lock goes nowhere near the options panel, and it used to
    -- leave a mouse-enabled frame across the middle of the screen with nothing to explain it.
    it("ends the on-screen message's move mode on any lock decision", function()
      local stopped = 0
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      Queue.SetLocked(true)
      assert.equal(1, stopped)
      Queue.SetLocked(false)
      assert.equal(2, stopped, "unlocking left the message frame in move mode")
    end)

    it("still stores the lock when leaving move mode errors, and says so", function()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      ns.Announcers = { StopMoving = function() error("MessageFrame has no Clear()") end }
      assert.is_true(Queue.SetLocked(true))
      assert.is_true(ns.db.profile.locked)
      assert.equal(1, #logged)
      assert.is_truthy(logged[1]:find("move mode", 1, true))
    end)

    it("locks without an Announcers module loaded at all", function()
      ns.Announcers = nil
      assert.is_true(Queue.SetLocked(true))
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

    -- The spell's OWN tooltip is the first thing the hover shows, and it needs the id. Nothing
    -- asserted it before AB4-D4, which is how the lookup behind it sat on `pack.spells` alone.
    it("opens the client's own tooltip for the spell, by id", function()
      hover{ spell = "EXORCISM", entry = { conditions = {} } }
      assert.equal(415073, tooltip.subject)
    end)

    -- AB4-D4. With no shipped pack -- every class but paladin, the standing rule of this redesign
    -- -- the strip used to fall back to printing the raw key at the top of the tooltip for an
    -- ability the player had added from their own spellbook.
    it("opens it for a registry-only ability on a class with no pack at all", function()
      ns.db.char.spells.REGISTERED_SPELL =
        { key = "REGISTERED_SPELL", id = 990001, name = "Registered Spell" }
      ns.Display.currentPack = function() return nil end
      hover{ spell = "REGISTERED_SPELL", entry = { conditions = {} } }
      assert.equal(990001, tooltip.subject)
    end)

    it("falls back to the bare key for a slot with no id anywhere", function()
      hover{ spell = "NOT_A_SPELL", entry = { conditions = {} } }
      assert.equal("NOT_A_SPELL", tooltip.subject)
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

    -- PE9-D4: the restriction above is now the default of a setting, not a law.
    it("puts it on every icon, or on none, when the player says so", function()
      ns.BarGlow = { keybindFor = function() return "3" end }
      Queue.Create()
      ns.db.profile.keybinds = "all"
      Queue.Render({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" } }, "PALADIN_EXODIN", true)
      assert.equal("3", icons()[2].keybind.text)

      ns.db.profile.keybinds = "off"
      Queue.Render({ { spell = "JUDGEMENT" }, { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal("", icons()[1].keybind.text)
      assert.equal("", icons()[2].keybind.text)
    end)

    -- PE9-D3. Three separate defects in one label: no outline (illegible over bright spell art),
    -- the palette's "must not compete" grey, and one fixed font object across slots of two sizes --
    -- so the biggest icon carried the proportionally smallest text.
    it("outlines the keybind in near-white and sizes it to the slot it sits on", function()
      Queue.Create()
      local b = icons()
      assert.equal("OUTLINE", b[1].keybind.font[3])
      assert.equal("OUTLINE", b[1].wait.font[3])
      -- Slot 1 is 52px and slot 2 is 40px, so its keybind must be the LARGER of the two.
      assert.is_true(b[1].keybind.font[2] > b[2].keybind.font[2],
                     "slot 1's keybind is not larger than slot 2's")
      assert.same({ ns.Colors.LABEL.r, ns.Colors.LABEL.g, ns.Colors.LABEL.b }, b[1].keybind.textColor)
      assert.is_not.same({ ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b },
                         b[1].keybind.textColor)
    end)
  end)

  -- PE9-D1. Every slot already carried `slot.t` -- the simulation's projected offset -- and the
  -- strip read it nowhere: the engine knew and the display threw it away.
  describe("how long until it happens", function()
    local function withT(...)
      local out = {}
      for i, t in ipairs({ ... }) do out[i] = { spell = "EXORCISM", t = t } end
      return out
    end

    it("prints a wait longer than one GCD, and stays silent about one that is not", function()
      Queue.Create()
      Queue.Render(withT(0, 4, 1.5), "PALADIN_EXODIN", true)
      local b = icons()
      assert.equal("4.0s", b[2].wait.text)
      assert.equal("", b[3].wait.text, "a next-GCD slot is not worth a number")

      -- The trap this feature dies of. `slot.t` is CUMULATIVE from now, so a perfectly smooth
      -- rotation reads 0 / 1.5 / 3.0 -- and testing the cumulative value against one GCD makes slot
      -- 3 clear the bar on every render and print "3.0s" forever, which is exactly the always-on
      -- countdown the design exists to avoid. WHETHER to speak is the slot's own GAP; WHAT is shown
      -- is still the time from now.
      Queue.Render(withT(0, 1.5, 3.0), "PALADIN_EXODIN", true)
      local smooth = icons()
      assert.equal("", smooth[2].wait.text, "a smooth queue says nothing")
      assert.equal("", smooth[3].wait.text, "and slot 3 of a smooth queue says nothing either")

      Queue.Render(withT(0, 1.5, 5.0), "PALADIN_EXODIN", true)
      local gap = icons()
      assert.equal("", gap[2].wait.text, "slot 2 follows on the next global")
      assert.equal("5.0s", gap[3].wait.text, "the real gap is announced, timed from NOW not from slot 2")
    end)

    it("never puts one on slot 1: slot 1 is 'press this now'", function()
      Queue.Create()
      ns.db.profile.waits = "always"
      Queue.Render(withT(0, 1.5), "PALADIN_EXODIN", true)
      assert.equal("", icons()[1].wait.text)
      assert.equal("1.5s", icons()[2].wait.text, "'Always' must print the next-GCD slot too")
    end)

    it("says nothing at all when it is switched off", function()
      Queue.Create()
      ns.db.profile.waits = "off"
      Queue.Render(withT(0, 4), "PALADIN_EXODIN", true)
      assert.equal("", icons()[2].wait.text)
    end)

    -- THE point of the feature. Renderers only run when the queue CHANGES, which in a steady
    -- rotation is seconds apart, so a number painted once and left alone freezes -- which looks
    -- alive and is not, and is worse than showing nothing.
    it("keeps counting down between queue changes, without a second ticker", function()
      Queue.Create()
      Queue.Render(withT(0, 4), "PALADIN_EXODIN", true)
      assert.equal("4.0s", icons()[2].wait.text)
      clockNow = 1.4
      assert.is_true(Queue.Tick(clockNow))
      assert.equal("2.6s", icons()[2].wait.text)
      -- And it stops rather than going negative: the cast should already have happened.
      clockNow = 9
      Queue.Tick(clockNow)
      assert.equal("", icons()[2].wait.text)
    end)

    it("one decimal below ten seconds, whole seconds above, never a bare number", function()
      assert.equal("2.4s", Queue.formatWait(2.4))
      assert.equal("12s", Queue.formatWait(12.7))
      assert.equal("10s", Queue.formatWait(10))
    end)

    it("forgets a captured countdown when the strip leaves the screen", function()
      Queue.Create()
      Queue.Render(withT(0, 4), "PALADIN_EXODIN", true)
      Queue.Render(nil, nil, false)            -- out of combat, no target
      assert.is_false(Queue.Tick(clockNow), "the tick still painted a hidden strip")
      ns.db.profile.waits = "off"              -- proves the text below is not a fresh render's
      Queue.Render(withT(0, 4), "PALADIN_EXODIN", true)
      assert.equal("", icons()[2].wait.text)
    end)
  end)

  -- PE9-D5. The rule name was the valuable third of Learning mode, and the only way to have it was
  -- to give up the lookahead entirely -- so the only way to see reasons in combat was to blind
  -- yourself to what was coming.
  describe("the name of the rule that chose it", function()
    it("is off by default, and appears on its own at any icon count", function()
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM", label = "Seal expiring" }, { spell = "JUDGEMENT" } },
                   "PALADIN_EXODIN", true)
      assert.is_false(icons()[1].reason:IsShown())

      ns.db.profile.showReason = true
      Queue.Render({ { spell = "JUDGEMENT", label = "Seal expiring" }, { spell = "EXORCISM" } },
                   "PALADIN_EXODIN", true)
      assert.is_true(icons()[1].reason:IsShown())
      assert.equal("Seal expiring", icons()[1].reason.text)
      assert.is_false(ns.db.profile.learning, "it must not need Learning mode any more")
    end)

    it("Learning mode still works, and now switches the rule name on too", function()
      Queue.Create()
      local applied = Queue.ApplyLearningPreset(true)
      assert.equal(1, ns.db.profile.depth)
      assert.equal(1.4, ns.db.profile.scale)
      assert.is_true(ns.db.profile.learning)
      assert.is_true(ns.db.profile.showReason)
      assert.is_true(applied.showReason)
    end)

    -- PE12: the owner hit this twice. Turning it ON was a one-way door -- you looked at a couple of
    -- suggestions and then had to remember, by hand, what your strip used to be.
    it("puts your settings back when you switch it off", function()
      Queue.Create()
      ns.db.profile.depth, ns.db.profile.scale, ns.db.profile.showReason = 4, 0.9, false

      Queue.ApplyLearningPreset(true)
      assert.equal(1, ns.db.profile.depth)
      assert.equal(1.4, ns.db.profile.scale)

      local restored = Queue.ApplyLearningPreset(false)
      assert.is_false(ns.db.profile.learning)
      assert.equal(4, ns.db.profile.depth, "the icon count was not put back")
      assert.equal(0.9, ns.db.profile.scale, "the size was not put back")
      assert.is_false(ns.db.profile.showReason)
      assert.is_truthy(restored and restored.restored, "the caller cannot say what came back")
      -- WHICH settings came back, not just that some did: the Queue page names them in the line it
      -- prints, and a report of "something was restored" is a report of nothing.
      assert.equal(4, restored.depth)
      assert.equal(0.9, restored.scale)
      assert.is_false(restored.showReason)
      assert.is_nil(ns.db.profile.learningPrior, "the remembered values outlived their use")
    end)

    -- The other half of the design: a setting the player CHANGED while learning is theirs, and
    -- handing it back to the pre-learning value would be this toggle overwriting a deliberate choice.
    it("keeps what you changed yourself while it was on", function()
      Queue.Create()
      ns.db.profile.depth, ns.db.profile.scale = 4, 0.9
      Queue.ApplyLearningPreset(true)
      ns.db.profile.scale = 1.8            -- the player widens it themselves, mid-lesson

      Queue.ApplyLearningPreset(false)
      assert.equal(4, ns.db.profile.depth, "an untouched setting is ours to restore")
      assert.equal(1.8, ns.db.profile.scale, "a setting they changed is theirs to keep")
    end)

    -- Turning it on while already on must not capture the PRESET's own values as the "prior" --
    -- that would quietly destroy the real ones and make the restore a no-op.
    it("survives being switched on twice", function()
      Queue.Create()
      ns.db.profile.depth, ns.db.profile.scale = 3, 0.8
      Queue.ApplyLearningPreset(true)
      Queue.ApplyLearningPreset(true)
      Queue.ApplyLearningPreset(false)
      assert.equal(3, ns.db.profile.depth)
      assert.equal(0.8, ns.db.profile.scale)
    end)

    -- Switching it OFF having never switched it on through us: a hand-edited or imported profile
    -- can arrive with `learning` already set, and there is nothing of that player's to put back.
    it("says nothing when it was never the one that switched it on", function()
      Queue.Create()
      -- The settings already ARE the preset's and there is no record of us having written them:
      -- an imported or hand-edited profile. Nothing of this player's exists to put back, and the
      -- one thing that must not happen is the toggle inventing values.
      ns.db.profile.depth, ns.db.profile.scale, ns.db.profile.showReason = 1, 1.4, true
      ns.db.profile.learning = true
      assert.is_nil(Queue.ApplyLearningPreset(false))
      assert.is_false(ns.db.profile.learning)
      assert.equal(1, ns.db.profile.depth)
      assert.equal(1.4, ns.db.profile.scale)
      assert.is_true(ns.db.profile.showReason)
    end)

    -- ...and the answer is built fresh every time. The one before it described a different
    -- switch-off, and reporting it again would name settings that nothing has just changed.
    it("does not report the previous switch-off's restore a second time", function()
      Queue.Create()
      ns.db.profile.depth, ns.db.profile.scale, ns.db.profile.showReason = 4, 0.9, false
      Queue.ApplyLearningPreset(true)
      assert.is_truthy(Queue.ApplyLearningPreset(false), "the first restore never happened")

      Queue.ApplyLearningPreset(true)
      -- Every setting changed by hand while learning, so every one of them is theirs to keep.
      ns.db.profile.depth, ns.db.profile.scale, ns.db.profile.showReason = 5, 1.8, false
      assert.is_nil(Queue.ApplyLearningPreset(false),
        "reported a restore that belonged to the previous time it was switched off")
      assert.equal(5, ns.db.profile.depth)
    end)
  end)

  -- PE9-D2. Nothing in the strip reacted to resources: on low mana it confidently told you to cast
  -- something, you pressed it, and it failed.
  describe("what you cannot actually cast", function()
    local function stateWhere(usable, noResource)
      ns.API = { GetState = function()
        return FakeState.new{ now = clockNow, usable = { EXORCISM = usable },
                              noResource = { EXORCISM = noResource } }
      end }
    end

    it("dims slot 1 when the reason is a resource one", function()
      Queue.Create()
      stateWhere(false, true)
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_true(icons()[1].icon.desaturated)
    end)

    -- A melee player running at a target is out of range for a second or two on every pull, and an
    -- icon strobing through that teaches you to stop looking at it.
    it("leaves it alone when you are merely out of range", function()
      Queue.Create()
      stateWhere(false, false)
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_false(icons()[1].icon.desaturated)
    end)

    it("undims again as soon as you can pay for it, on the tick, not on the next queue change",
      function()
        Queue.Create()
        stateWhere(false, true)
        Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
        assert.is_true(icons()[1].icon.desaturated)
        stateWhere(true, false)
        Queue.Tick(clockNow)
        assert.is_false(icons()[1].icon.desaturated)
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
      -- Centre to centre: 20 (half of slot 2) + 4 (the gap) + 26 (half of slot 1), leftward.
      assert.same({ -50, 0 }, slide.anims.Translation.offset)
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
      assert.equal(6, b.point[4])                  -- parked at slot 2's centre while it slides
      b.groups[1].scripts.OnFinished()
      assert.equal(-44, b.point[4])                -- and settled on slot 1's
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
      -- PE10-D1: every slot is anchored CENTRE-to-CENTRE now, so one set of offsets works for all
      -- four growth directions. Slot 1's centre is 44px left of the middle of a 140-wide strip.
      assert.equal("CENTER", b[1].point[1])
      assert.equal("CENTER", b[1].point[3])
      assert.equal(-44, b[1].point[4])
      assert.equal(0, b[1].point[5])
      assert.equal(6, b[2].point[4])
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
      assert.equal(6, b.point[4])
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
      assert.equal("CENTER", g.point[3])
      assert.equal(6, g.point[4])             -- slot 2's centre, from the strip's centre
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

    -- AB4 review: the fourth lookup of the shape AB4-D4 fixed. This gave up before doing anything
    -- when there was no class pack, so on such a class a cast of an ability the player registered
    -- from their own spellbook resolved to nothing -- the strip could not tell "you pressed it"
    -- from "the rotation changed its mind", and Display.noteCast never fired its `used` cue.
    it("recognises a cast of a registry-only ability with no pack at all", function()
      Queue.Create()
      ns.db.char.spells.REGISTERED_SPELL =
        { key = "REGISTERED_SPELL", id = 990001, name = "Registered Spell" }
      ns.Display.currentPack = function() return nil end
      assert.equal("REGISTERED_SPELL", Queue.keyForSpellID(990001))
      assert.is_true(Queue.noteCast(990001))
    end)

    -- ...and by NAME too, which is the whole reason this index exists: Classic gives every rank its
    -- own id, so the id a cast reports is usually not the one the registry holds.
    it("matches another rank of a registry-only ability by name", function()
      Queue.Create()
      ns.db.char.spells.REGISTERED_SPELL =
        { key = "REGISTERED_SPELL", id = 990001, name = "Registered Spell" }
      ns.Display.currentPack = function() return nil end
      _G.GetSpellInfo = function(id)
        if id == 990001 or id == 990002 then return "Registered Spell" end
        return "Spell " .. tostring(id)
      end
      assert.equal("REGISTERED_SPELL", Queue.keyForSpellID(990002))
    end)

    -- No id, no work. Without this guard a nil id walks the whole registry asking the client for a
    -- name for each entry -- a full map rebuild, on every call, to answer a question that has no
    -- answer. It is cheap to get wrong because the RESULT is the same either way.
    it("costs nothing at all when there is no id to look up", function()
      Queue.Create()
      ns.db.char.spells.REGISTERED_SPELL =
        { key = "REGISTERED_SPELL", id = 990001, name = "Registered Spell" }
      local lookups = 0
      _G.GetSpellInfo = function(id) lookups = lookups + 1; return "Spell " .. tostring(id) end
      assert.is_nil(Queue.keyForSpellID(nil))
      assert.equal(0, lookups, "a nil id rebuilt the whole name index")
      Queue.keyForSpellID(990001)
      assert.is_true(lookups > 0, "...and a real id still builds it")
    end)

    -- A spell added mid-session must not wait for a reload to be recognised: the map is rebuilt
    -- when the registry gains or loses an entry, not only when the class pack changes.
    it("picks up an ability registered after the map was first built", function()
      Queue.Create()
      assert.is_false(Queue.noteCast(990001))
      ns.db.char.spells.REGISTERED_SPELL =
        { key = "REGISTERED_SPELL", id = 990001, name = "Registered Spell" }
      assert.equal("REGISTERED_SPELL", Queue.keyForSpellID(990001))
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
  -- FX1-D5. The options window is very often sitting exactly where the strip is being dragged to,
  -- so entering a Move mode hides it and leaves a small bar on screen instead. Asked for from HERE
  -- rather than from the button that started the mode: "Lock all positions" and /elm lock end this
  -- mode too (Queue.SetLocked), and neither goes anywhere near the panel.
  describe("positioning mode and the options window (FX1-D5)", function()
    local moves

    before_each(function()
      moves = {}
      ns.Options = {
        BeginMove = function(what, key) moves[#moves + 1] = { "begin", what, key } end,
        EndMove = function() moves[#moves + 1] = { "end" } end,
      }
    end)

    it("asks the window to step aside when positioning starts", function()
      assert.is_true(Queue.StartPositioning())
      assert.is_true(container().shown, "the strip is not even on screen to be positioned")
      assert.same({ "begin", "strip" }, moves[1])
      assert.equal(1, #moves)
    end)

    it("gives the window back when positioning ends", function()
      Queue.StartPositioning()
      assert.is_true(Queue.StopPositioning())
      assert.same({ "end" }, moves[2])
      assert.equal(2, #moves)
    end)

    -- The exit nobody remembers: locking positions ends the mode without the panel's button.
    it("gives the window back when the positions are locked instead", function()
      Queue.StartPositioning()
      Queue.SetLocked(true)
      assert.same({ "end" }, moves[2])
    end)

    it("says nothing when there was no mode to start or to end", function()
      Queue.StartPositioning()
      assert.is_false(Queue.StartPositioning())
      Queue.StopPositioning()
      assert.is_false(Queue.StopPositioning())
      assert.equal(2, #moves)
    end)

    it("does not need an options window to be positioned at all", function()
      ns.Options = nil
      assert.is_true(Queue.StartPositioning())
      assert.is_true(Queue.StopPositioning())
    end)
  end)

  -- PE11-D5. Positioning mode replaces the rotation with a SAMPLE, and the sample is the thing the
  -- placement is judged by: it has to be the real strip at the real settings, showing the real
  -- rotation's icons, and it must carry NOTHING a live render left on the slots -- no tooltip about
  -- a suggestion nobody is making, no countdown to a cast that is not coming, no greyed-out icon.
  -- Every line of it was eyeballed in the client and none of it was pinned.
  describe("the sample shown while the strip is being positioned (PE11-D5)", function()
    local function liveRender()
      ns.db.profile.keybinds, ns.db.profile.waits = "all", "always"
      ns.db.profile.showReason = true
      ns.BarGlow = { keybindFor = function() return "Q" end }
      ns.API = { GetState = function()
        return FakeState.new{ now = 0, cooldowns = { EXORCISM = 5 }, baseCooldown = { EXORCISM = 10 },
                              usable = { EXORCISM = false }, noResource = { EXORCISM = true } }
      end }
      Queue.Render({ { spell = "EXORCISM", t = 0, label = "Seal expiring" },
                     { spell = "JUDGEMENT", t = 5 } }, "PALADIN_EXODIN", true)
    end

    before_each(function()
      stubBuild({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" } })
      Queue.Create()
    end)

    it("carries nothing a live render left on the slots", function()
      liveRender()
      local one, two = icons()[1], icons()[2]
      -- Asserted BEFORE the mode starts, or every assertion below could pass against a strip that
      -- had never drawn anything in the first place.
      assert.is_truthy(one.slot)
      assert.equal("Q", one.keybind.text)
      assert.is_truthy(two.waitUntil)
      assert.is_true(one.reason.shown)
      assert.is_truthy(one.cd.cooldown)
      assert.is_true(one.icon.desaturated)

      Queue.StartPositioning()
      assert.is_nil(one.slot, "hovering a sample icon would explain a suggestion nobody is making")
      assert.is_nil(one.waitUntil)
      assert.is_nil(two.waitUntil)
      assert.equal("", one.keybind.text)
      assert.equal("", two.wait.text)
      assert.is_false(one.reason.shown)
      assert.is_nil(one.cd.cooldown)
      assert.is_false(one.icon.desaturated)
    end)

    it("shows the active rotation\'s own icons, which is the point of sampling at all", function()
      Queue.StartPositioning()
      assert.equal("icon", icons()[1].icon.texture)
      assert.equal("icon", icons()[2].icon.texture)
      assert.is_nil(icons()[1].icon.colorTexture, "a real icon must not be painted over")
    end)

    -- No rotation chosen yet is exactly when someone positions the strip for the first time. Flat
    -- brand squares rather than an `Interface\\Icons\\...` path written from memory: Classic Era
    -- ships a subset of retail\'s icons and a missing one draws nothing at all.
    it("falls back to flat brand squares when there is no rotation to sample", function()
      ns.Display.activeBuild = function() return nil, nil, "no pack" end
      Queue.StartPositioning()
      assert.same({ ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.8 },
                  icons()[1].icon.colorTexture)
      assert.is_nil(icons()[1].icon.texture)
    end)

    -- The sample is the strip AT THE SETTINGS IN FORCE. The panel writes depth, direction and
    -- spacing while the strip is hidden and nothing lays it out, so entering the mode is where they
    -- have to land -- otherwise the thing being positioned is the shape it had last time.
    it("lays the strip out at the settings in force right now", function()
      ns.db.profile.grow, ns.db.profile.depth, ns.db.profile.spacing = "down", 5, 10
      Queue.StartPositioning()
      local _, _, _, x1, y1 = icons()[1]:GetPoint()
      local _, _, _, x2, y2 = icons()[2]:GetPoint()
      assert.equal(0, x1)
      assert.equal(0, x2, "slot two is beside slot one, not under it")
      assert.is_true(y2 < y1, "the strip is still laid out the way it grew last time")
      -- ...and the fifth slot the deeper strip added exists to be dragged with the rest.
      assert.is_true(icons()[5].shown)
    end)

    -- The mode shows the grip whatever the lock says, because something has to be draggable. What
    -- it must not do is leave it out afterwards: the grip is how a player TELLS whether the strip
    -- is locked.
    it("puts the drag handle back where the saved lock says it belongs", function()
      ns.db.profile.locked = true
      Queue.StartPositioning()
      assert.is_true(container().grip.shown)
      Queue.StopPositioning()
      assert.is_false(container().grip.shown)

      ns.db.profile.locked = false
      Queue.StartPositioning()
      Queue.StopPositioning()
      assert.is_true(container().grip.shown)
    end)

    it("puts the strip on screen at full opacity with its drag handle out", function()
      ns.db.profile.locked = true          -- the grip is normally hidden while locked
      container().grip:Hide()
      container():Hide()
      container():SetAlpha(0.3)            -- as the out-of-combat fade would have left it
      assert.is_true(Queue.StartPositioning())
      assert.is_true(container().shown)
      assert.equal(1, container().alpha, "you cannot place what you can barely see")
      assert.is_true(container().grip.shown, "there is nothing to grab hold of")
      -- ...and the lock the player saved is not rewritten to get it (PE11-D5).
      assert.is_true(ns.db.profile.locked)
    end)

    -- D38\'s nudge sits where the sample is about to be drawn, and a left click on it opens the
    -- Rotations page -- which, mid-drag, is the last thing that should happen.
    it("takes the no-rotation nudge down and stops it answering clicks", function()
      ns.db.profile.activeBuild = false
      ns.API = { GetState = function() return FakeState.new{ inCombat = false } end }
      Queue.Render({}, nil, true)
      assert.is_true(container().placeholder.shown)
      local opened = 0
      ns.Options = { Open = function() opened = opened + 1 end,
                     BeginMove = function() end, EndMove = function() end }
      container().scripts.OnMouseUp(container(), "LeftButton")
      assert.equal(1, opened, "the click this mode has to suppress does not happen at all")

      Queue.StartPositioning()
      assert.is_false(container().placeholder.shown)
      container().scripts.OnMouseUp(container(), "LeftButton")
      assert.equal(1, opened)
    end)

    -- Layout is what every settings change runs, and a deeper strip or a new direction reveals a
    -- slot that was hidden. Without the repaint those arrive as blank squares in the middle of the
    -- thing being placed.
    it("repaints the sample when a setting changes mid-drag", function()
      Queue.StartPositioning()
      assert.is_false(icons()[4].shown)
      ns.db.profile.depth = 5
      Queue.Layout()
      assert.is_true(icons()[4].shown)
      assert.same({ ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.8 },
                  icons()[4].icon.colorTexture)
    end)

    it("ignores the render loop, so no tick pulls the strip out from under the drag", function()
      Queue.StartPositioning()
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", false)
      assert.is_true(container().shown)
      assert.is_nil(icons()[1].slot)
      -- The live repaint stands down too: there is no countdown to run and no mana to check, and
      -- paintFade would dim a strip the player is trying to see well enough to drag.
      assert.is_false(Queue.Tick(0))
    end)

    it("takes the strip back off screen when the mode ends", function()
      local refreshes = 0
      ns.Display.refresh = function() refreshes = refreshes + 1 end
      Queue.StartPositioning()
      assert.is_true(Queue.StopPositioning())
      assert.is_false(container().shown, "a preview with no way to dismiss it")
      assert.equal(1, refreshes, "nothing asks for the real strip back")
    end)

    -- `rendered` is what the next paint animates OUT of, and after the mode the buttons are
    -- carrying sample art the rotation was never in.
    it("forgets what was on screen, so the paint after the mode is a first paint", function()
      local function played()
        local total = 0
        for _, f in ipairs(icons()) do
          for _, g in ipairs(f.groups or {}) do total = total + g.played end
        end
        return total
      end
      local first = { { spell = "EXORCISM" }, { spell = "JUDGEMENT" } }
      local second = { { spell = "JUDGEMENT" }, { spell = "EXORCISM" } }
      Queue.Render(first, "PALADIN_EXODIN", true)
      Queue.Render(second, "PALADIN_EXODIN", true)
      assert.is_true(played() > 0, "an ordinary second paint animates; the control is broken")

      local before = played()
      Queue.StartPositioning()
      Queue.StopPositioning()
      Queue.Render(first, "PALADIN_EXODIN", true)
      assert.equal(before, played())
    end)
  end)

  -- PE10-D4, "Match my action bars". The arithmetic is in SCREEN pixels on both sides, which is the
  -- only place a strip scale and an action button are comparable -- and the button it measures has
  -- to be one this character actually uses, or it measures nothing.
  describe("matching the action bars (PE10-D4)", function()
    local asked

    before_each(function()
      asked = nil
      Queue.Create()
      _G.UIParent.effectiveScale = nil
      ns.BarGlow = { buttonSize = function(keys) asked = keys; return 36 end }
    end)

    it("offers what is on screen first, then the rest of the rotation, each key once", function()
      stubBuild({ { spell = "EXORCISM" }, { spell = "HOLY_SHOCK" }, { item = 13 } })
      ns.Display.currentQueue = function()
        return { { spell = "JUDGEMENT" }, { spell = "EXORCISM" } }
      end
      Queue.matchBarScale()
      assert.same({ "JUDGEMENT", "EXORCISM", "HOLY_SHOCK" }, asked)
    end)

    it("sets the scale so slot one is drawn the size of a real button, to the whole percent",
      function()
        -- 36px of screen against slot one\'s 52 container-pixels, through UIParent\'s own scale.
        _G.UIParent.effectiveScale = 0.8
        assert.equal(0.87, Queue.matchBarScale())        -- 36 / (52 * 0.8) = 0.8654, to the percent
        assert.equal(0.87, ns.db.profile.scale, "the slider still shows the old number")
        -- A client that will not give a scale is assumed to be at 1, not left at nothing.
        _G.UIParent.effectiveScale = nil
        assert.equal(0.69, Queue.matchBarScale())        -- 36 / 52 = 0.6923
      end)

    -- Both ends of the Queue page\'s Size slider, so a computed scale can never leave the panel
    -- showing a value the control cannot represent.
    it("never computes a scale the size slider could not show", function()
      ns.BarGlow = { buttonSize = function() return 400 end }
      assert.equal(2.0, Queue.matchBarScale())
      assert.equal(2.0, Queue.SCALE_MAX)
      ns.BarGlow = { buttonSize = function() return 4 end }
      assert.equal(0.5, Queue.matchBarScale())
      assert.equal(0.5, Queue.SCALE_MIN)
    end)

    -- Nil MUST leave the setting alone: a button that silently applies a made-up number is worse
    -- than one that says it could not find a bar, because the player then has to undo something
    -- they cannot see the cause of.
    it("changes nothing and says why when no button can be measured", function()
      ns.db.profile.scale = 1.25
      ns.BarGlow = { buttonSize = function() return nil end }
      local scale, why = Queue.matchBarScale()
      assert.is_nil(scale)
      assert.equal("no button", why)
      assert.equal(1.25, ns.db.profile.scale)

      ns.BarGlow = nil
      scale, why = Queue.matchBarScale()
      assert.is_nil(scale)
      assert.equal("no button", why)
      assert.equal(1.25, ns.db.profile.scale)
    end)
  end)

  -- What a render has to FORGET. Every one of these is a value captured for a moment that has
  -- passed: a countdown to a cast that is no longer coming, a suggestion on a slot the strip does
  -- not show any more. They look right on screen because the icon is hidden -- and then the strip
  -- comes back, or the tooltip is opened, and the stale value is what answers.
  describe("what a render forgets", function()
    local queue = { { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 5 } }

    local function withWaits()
      ns.db.profile.waits = "always"
      ns.API = { GetState = function() return FakeState.new{ now = 0, inCombat = false } end }
      Queue.Create()
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.is_truthy(icons()[2].waitUntil, "nothing was captured to forget")
    end

    it("drops every countdown when the strip is switched off", function()
      withWaits()
      ns.db.profile.showQueue = false
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.is_nil(icons()[2].waitUntil)
    end)

    it("drops every countdown when the strip goes out of sight", function()
      withWaits()
      Queue.Render(queue, "PALADIN_EXODIN", false)
      assert.is_nil(icons()[2].waitUntil)
    end)

    -- The placeholder replaces the whole strip, so anything captured for the rotation that WAS
    -- chosen is about a rotation that is no longer running.
    it("drops every countdown, and the fade, when the placeholder takes over", function()
      ns.db.profile.oocAlpha = 0.3
      withWaits()
      assert.equal(0.3, container().alpha, "the fade under test never happened")
      ns.db.profile.activeBuild = false
      Queue.Render({}, nil, true)
      assert.is_true(container().placeholder.shown)
      assert.is_nil(icons()[2].waitUntil)
      assert.equal(1, container().alpha,
        "the one message asking for a rotation is the one thing the fade could hide")
    end)

    -- A rotation that ran out of suggestions leaves slots 2..n empty rather than hidden, and an
    -- empty slot that keeps its countdown prints a time for a cast that is not coming at all.
    it("drops the countdown from a slot the rotation no longer fills", function()
      withWaits()
      Queue.Render({ { spell = "EXORCISM", t = 0 } }, "PALADIN_EXODIN", true)
      assert.is_nil(icons()[2].slot)
      assert.is_nil(icons()[2].waitUntil)
      assert.equal("", icons()[2].wait.text)
    end)

    it("drops a countdown the settings just turned off", function()
      withWaits()
      ns.db.profile.waits = "off"
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.is_nil(icons()[2].waitUntil)
      assert.equal("", icons()[2].wait.text)
    end)

    -- A shallower strip hides slots 3..5 without repainting them, so the suggestion and the
    -- countdown they were last given would answer a tooltip about a strip that is not on screen.
    it("clears the slots a shallower strip no longer shows", function()
      ns.db.profile.depth, ns.db.profile.waits = 5, "always"
      ns.API = { GetState = function() return FakeState.new{ now = 0, inCombat = false } end }
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 5 },
                     { spell = "EXORCISM", t = 10 }, { spell = "JUDGEMENT", t = 15 } },
                   "PALADIN_EXODIN", true)
      assert.is_truthy(icons()[4].slot)
      assert.is_truthy(icons()[4].waitUntil)
      ns.db.profile.depth = 2
      Queue.Render({ { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 5 } },
                   "PALADIN_EXODIN", true)
      assert.is_nil(icons()[4].slot)
      assert.is_nil(icons()[4].waitUntil)
    end)
  end)

  -- PE9-D1. "Is this wait worth saying" is measured against how long a global cooldown LASTS on
  -- THIS character -- not against `gcd`, which is how much of one is LEFT, and not against a number
  -- written down here. A haste-stacked caster at a 1.0s global and a warrior at 1.5s do not want
  -- the same strip.
  describe("how long a global cooldown lasts", function()
    local queue = { { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 2.0 } }

    before_each(function()
      ns.db.profile.waits = "gcd"
      Queue.Create()
    end)

    it("says nothing about a two-second gap on a client whose global is three seconds", function()
      ns.API = { GetState = function() return FakeState.new{ now = 0, gcdDuration = 3.0 } end }
      _G.oneGCD = nil
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.is_nil(icons()[2].waitUntil)
      -- The threshold is a LOCAL: `oneGCD` in the client's one global table would carry this
      -- character's global cooldown into whatever rendered next. `make lint` is the standing gate
      -- for that; this is what lets the mutation gate see it too.
      assert.is_nil(_G.oneGCD)
    end)

    it("says so about the same gap when the global is the usual second and a half", function()
      ns.API = { GetState = function() return FakeState.new{ now = 0, gcdDuration = 1.5 } end }
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.equal(2.0, icons()[2].waitUntil)
    end)

    -- A State that will not answer at all (Adapters/Interface: an answer of nil is a reading the
    -- client refused, not a duration). The shipped 1.5s stands in -- pinned to the VALUE, because a
    -- fallback of nil errors and a fallback of zero makes every slot announce a wait.
    it("falls back to the shipped global when the client will not say", function()
      local blind = setmetatable({ gcdDuration = false },
                                 { __index = FakeState.new{ now = 0 } })
      ns.API = { GetState = function() return blind end }
      Queue.Render(queue, "PALADIN_EXODIN", true)
      assert.equal(2.0, icons()[2].waitUntil)
      Queue.Render({ { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 1.0 } },
                   "PALADIN_EXODIN", true)
      assert.is_nil(icons()[2].waitUntil, "a one-second gap IS the global; it is not news")
    end)
  end)

  -- PE10-D1. The saved anchor positions the container's BOX, and the box changes shape with the
  -- growth direction: a strip grown right is 140x52 with slot one at its left end, the same strip
  -- grown up is 52x140 with slot one at its bottom. Re-placing the same box point after a flip
  -- would slide the icon the player spent time putting under their character halfway across the
  -- screen -- and nothing about the anchor it saved and read back would look wrong.
  describe("where the container is placed", function()
    -- An off-centre anchor, because the compensation is zero for a CENTER one: half the arithmetic
    -- only exists for a strip anchored by an edge, which is where anyone puts it.
    before_each(function()
      ns.db.profile.anchor = { point = "LEFT", relPoint = "LEFT", x = 40, y = -20 }
      Queue.Create()
    end)

    it("keeps slot one on the same pixel in all four directions", function()
      local function slotOne(grow)
        ns.db.profile.grow = grow
        Queue.Layout()
        local point, _, relPoint, x, y = container():GetPoint()
        assert.equal("LEFT", point)
        assert.equal("LEFT", relPoint)
        local slots, width = ns.Transition.layout(3, grow, 4)
        -- Anchored by its LEFT edge, so the container's centre is half a width to the right of it.
        return { x + width / 2 + slots[1].x, y + slots[1].y }
      end
      local right = slotOne("right")
      assert.same(right, slotOne("left"))
      assert.same(right, slotOne("down"))
      assert.same(right, slotOne("up"))
      -- ...and the anchor on disk is untouched, so a profile switch or an import still reads it.
      assert.equal(40, ns.db.profile.anchor.x)
      assert.equal(-20, ns.db.profile.anchor.y)
    end)

    it("leaves the container on exactly one anchor point, however often it is laid out", function()
      Queue.Layout()
      Queue.Layout()
      assert.equal(1, #container().points)
    end)
  end)

  describe("Layout, continued", function()
    it("shows exactly the slots the depth asks for, whatever was on screen before", function()
      Queue.Create()
      for _, b in ipairs(icons()) do b:Hide() end
      ns.db.profile.depth = 3
      Queue.Layout()
      assert.is_true(icons()[3].shown, "a slot the depth asks for is still hidden")
      assert.is_false(icons()[4].shown)

      for _, b in ipairs(icons()) do b:Show() end
      Queue.Layout()
      assert.is_false(icons()[5].shown, "a slot past the depth is still on screen")
    end)

    -- The Queue page's "Position the Strip" button relabels itself from this, and /elm lock and
    -- "Lock all positions" both end the mode without going near the panel.
    it("answers whether the strip is being positioned", function()
      Queue.Create()
      assert.is_false(Queue.isPositioning())
      Queue.StartPositioning()
      assert.is_true(Queue.isPositioning())
      Queue.StopPositioning()
      assert.is_false(Queue.isPositioning())
    end)

    -- Every icon forwards its drag here, and a drag can arrive before anything has been built:
    -- an OnDragStart fired against a strip that is not on screen must answer, not error.
    it("cannot be dragged before it exists", function()
      ns.db.profile.locked = false     -- unlocked, so nothing else can be what refuses the drag
      assert.is_false(Queue.StartMoving())
      assert.is_false(Queue.StopMoving())
      assert.has_no.errors(function() Queue.Layout() end)
    end)

    -- Nothing this file declares may end up in the client's one global table. `make lint` is the
    -- standing gate; it cannot run here, and a forward declaration or a loop-local is invisible to
    -- every other assertion in this spec -- a global works exactly as well right up until two
    -- addons pick the same name.
    it("leaves nothing of its own in _G", function()
      for _, name in ipairs({ "paintSample", "oneGCD", "restored" }) do _G[name] = nil end
      ns.db.profile.depth, ns.db.profile.scale = 4, 0.9
      Queue.Create()
      Queue.ApplyLearningPreset(true)
      Queue.ApplyLearningPreset(false)
      Queue.StartPositioning()
      Queue.Layout()
      Queue.StopPositioning()
      Queue.Render({ { spell = "EXORCISM", t = 0 }, { spell = "JUDGEMENT", t = 5 } },
                   "PALADIN_EXODIN", true)
      for _, name in ipairs({ "paintSample", "oneGCD", "restored" }) do
        assert.is_nil(_G[name], name .. " leaked into the global table")
      end
    end)
  end)

  -- PE9-D3. Both labels drawn ON an icon are sized from the slot they sit on, so slot one's 30%
  -- larger icon does not end up carrying the proportionally smallest text. The re-fonting reads the
  -- fontstring's OWN file back rather than naming one, so a locale whose client ships different
  -- glyphs (zhCN, koKR) keeps them -- which means it also has to cope with a client that will not
  -- answer.
  describe("sizing the labels on an icon", function()
    before_each(function() Queue.Create() end)

    -- PE9-D1/D3. Diagonally opposite corners, so however long either label gets they can never
    -- collide: the keybind is a fact about the cast you are making now and reads as a label, the
    -- countdown is a projection and reads as an aside.
    it("puts the two labels in opposite corners, in their own weights", function()
      local b = icons()[1]
      assert.equal("TOPRIGHT", b.keybind.point[1])
      assert.equal("BOTTOMLEFT", b.wait.point[1])
      assert.same({ 1, 1 }, { b.wait.point[2], b.wait.point[3] })
      assert.same({ ns.Colors.LABEL.r, ns.Colors.LABEL.g, ns.Colors.LABEL.b }, b.keybind.textColor)
      assert.same({ ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b }, b.wait.textColor)
    end)

    it("outlines each label and scales it to the slot it sits on", function()
      local one, two = icons()[1], icons()[2]
      assert.equal("Fonts\\FRIZQT__.TTF", one.keybind.font[1])
      assert.equal("OUTLINE", one.keybind.font[3])
      -- Slot one is 52 across, the rest are 40: the keybind is 30% of that, the wait 28%.
      assert.equal(16, one.keybind.font[2])
      assert.equal(15, one.wait.font[2])
      assert.equal(12, two.keybind.font[2])
      assert.equal(11, two.wait.font[2])
    end)

    -- The strip's geometry is data (Core/Transition.LAYOUT), not a constant written here, so a
    -- smaller base is a change someone can make -- and text that scales all the way down stops
    -- being text. The floor is what keeps a label readable rather than merely present.
    it("never sizes a label below the readable floor", function()
      ns.Transition.LAYOUT.base = 12
      Queue.Layout()
      assert.equal(8, icons()[1].keybind.font[2])
      assert.equal(8, icons()[2].wait.font[2])
    end)

    -- Both of these are about a client that answers differently from ours. Neither may take the
    -- layout down with it: the strip is drawn from Layout, and an error here means no strip at all.
    it("lays the strip out anyway when a label cannot be re-fonted", function()
      for _, b in ipairs(icons()) do
        b.keybind = setmetatable({}, { __index = function() return nil end })
      end
      assert.has_no.errors(function() Queue.Layout() end)
      assert.same({ 52, 52 }, icons()[1].size, "the layout stopped at the first odd fontstring")
    end)

    it("leaves a label alone rather than re-fonting it to nothing", function()
      _G.STANDARD_TEXT_FONT = nil
      for _, b in ipairs(icons()) do
        b.wait.font = nil
        b.wait.GetFont = function() return nil end
      end
      Queue.Layout()
      assert.is_nil(icons()[1].wait.font, "SetFont was called with no font file at all")
      -- The label beside it, whose client DID answer, is still re-fonted.
      assert.equal(16, icons()[1].keybind.font[2])
    end)
  end)

  -- PE10-D2. How opaque the strip is while you are NOT fighting: for people who keep it up out of
  -- combat and want it quieter, not gone. It multiplies the per-slot ramp rather than replacing it,
  -- and it never applies in combat.
  describe("the out-of-combat fade", function()
    local function renderAt(alpha, inCombat)
      ns.db.profile.oocAlpha = alpha
      ns.API = { GetState = function() return FakeState.new{ now = 0, inCombat = inCombat } end }
      Queue.Create()
      Queue.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      return container().alpha
    end

    it("goes back to full the moment you enter combat", function()
      assert.equal(0.3, renderAt(0.3, false))
      assert.equal(1, renderAt(0.3, true))
    end)

    -- The slider stops at 10%, but a profile can carry anything (an import, a hand-edit). A strip
    -- at 2% is one the player cannot find to fix.
    it("never fades the strip past the point of finding it again", function()
      assert.equal(0.1, renderAt(0.02, false))
    end)
  end)

  -- PE10-D1. The promotion entrance drops in ACROSS the strip, never along it, so it can never be
  -- mistaken for an ordinary shift -- which means the render has to know which way the strip grows.
  it("drops a promoted icon in across the direction the strip actually grows", function()
    ns.db.profile.grow, ns.db.profile.animate = "up", true
    Queue.Create()
    Queue.Render({ { spell = "EXORCISM" }, { spell = "JUDGEMENT" } }, "PALADIN_EXODIN", true)
    Queue.Render({ { spell = "HOLY_SHOCK" }, { spell = "EXORCISM" }, { spell = "JUDGEMENT" } },
                 "PALADIN_EXODIN", true)
    -- Slot one is 52 wide; on a strip that grows UP the entrance is horizontal.
    assert.same({ 52, 0 }, icons()[1].slideMove.offset)
  end)
end)
