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
  local Queue, ns, frames, tooltip

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
    function f:StartMoving() self.moving = true end
    function f:StopMovingOrSizing() self.moving = false end
    function f:SetPoint(p, rel, rp, x, y)
      if type(rel) == "string" then p, rel, rp, x, y = p, nil, rel, rp, x end
      self.point = { p, rel, rp, x, y }
    end
    function f:GetPoint() return self.point[1], self.point[2], self.point[3], self.point[4], self.point[5] end
    function f:ClearAllPoints() end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:CreateTexture() local t = fakeFrame("Texture"); self.children[#self.children + 1] = t; return t end
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

  local function stubBuild(entries)
    ns.Display = {
      currentPack = function() return { spells = { EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } } } end,
      activeBuild = function() return { entries = entries or {} }, "PALADIN_EXODIN", "pinned" end,
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

    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    Queue = helper.load("Elmira/Display/Queue.lua")
    ns.db = { profile = {
      enabled = true, depth = 3, scale = 1.0, locked = true, learning = false,
      anchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
      glow = { enabled = false, style = "PIXEL", barGlow = false },
    } }
    ns.API = { GetState = function() return FakeState.new{} end }
    ns.now = function() return 0 end
    stubBuild()
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent, _G.GameTooltip, _G.GetSpellTexture = nil, nil, nil, nil
  end)

  local function container() return Queue.frame() end
  local function icons()
    local out = {}
    for _, f in ipairs(frames) do
      if f.kind == "Frame" and f ~= container() then out[#out + 1] = f end
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
end)
