local helper = require("tests.helper")

-- Elmira/Display/Glow.lua — argument POSITIONS, not behaviour.
--
-- This spec exists because of a live crash: LibCustomGlow's three starters take their `key` at three
-- different positions, our call sites passed it by counting nils, and the AutoCast one landed the
-- string "Elmira" in `yOffset`. The library then did `yOffset+0.05` and the whole queue renderer
-- died — on a code path that reads, at a glance, exactly like the two correct ones next to it.
--
-- The fake below is the real library's signature written out by name. That is the point: a spec that
-- only checked "the library was called" would have passed against the bug.
describe("Display.Glow", function()
  local Glow, ns, calls

  -- Named parameters, copied from LibCustomGlow-1.0 v25 (DBM's copy, the one that wins LibStub on
  -- the author's install). If a future version reorders these, this spec is where it shows up.
  local function fakeLib()
    local L = {}
    function L.PixelGlow_Start(r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)
      calls[#calls + 1] = { fn = "PixelGlow_Start", r = r, color = color, N = N, frequency = frequency,
                            length = length, th = th, xOffset = xOffset, yOffset = yOffset,
                            border = border, key = key, frameLevel = frameLevel }
    end
    function L.AutoCastGlow_Start(r, color, N, frequency, scale, xOffset, yOffset, key, frameLevel)
      calls[#calls + 1] = { fn = "AutoCastGlow_Start", r = r, color = color, N = N, frequency = frequency,
                            scale = scale, xOffset = xOffset, yOffset = yOffset, key = key,
                            frameLevel = frameLevel }
    end
    function L.ButtonGlow_Start(r, color, frequency, frameLevel)
      calls[#calls + 1] = { fn = "ButtonGlow_Start", r = r, color = color, frequency = frequency,
                            frameLevel = frameLevel }
    end
    -- ProcGlow_Start is the odd one: an options TABLE, not a positional row.
    function L.ProcGlow_Start(r, options)
      calls[#calls + 1] = { fn = "ProcGlow_Start", r = r, options = options }
    end
    function L.ProcGlow_Stop(r, key) calls[#calls + 1] = { fn = "ProcGlow_Stop", r = r, key = key } end
    function L.PixelGlow_Stop(r, key) calls[#calls + 1] = { fn = "PixelGlow_Stop", r = r, key = key } end
    function L.AutoCastGlow_Stop(r, key) calls[#calls + 1] = { fn = "AutoCastGlow_Stop", r = r, key = key } end
    function L.ButtonGlow_Stop(r, key) calls[#calls + 1] = { fn = "ButtonGlow_Stop", r = r, key = key } end
    return L
  end

  before_each(function()
    ns = helper.reset()
    calls = {}
    local lib = fakeLib()
    _G.LibStub = function(major) return major == "LibCustomGlow-1.0" and lib or nil end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    Glow = helper.load("Elmira/Display/Glow.lua")
    ns.db = { profile = { glow = { enabled = true, style = "PIXEL", barGlow = false } } }
  end)

  after_each(function() _G.LibStub = nil end)

  -- The frame is only ever an identity here; nothing in Glow reads it.
  local function frame(name) return { name = name or "f" } end

  describe("the key reaches the library's key parameter", function()
    it("PIXEL: 10th argument, and no numeric parameter is polluted", function()
      local f = frame()
      assert.is_true(Glow.Start(f, "PIXEL"))
      local c = calls[1]
      assert.equal("PixelGlow_Start", c.fn)
      assert.equal("Elmira", c.key)
      assert.equal(f, c.r)
      -- Every geometry parameter must be nil so the library applies its own defaults.
      assert.is_nil(c.N); assert.is_nil(c.frequency); assert.is_nil(c.length)
      assert.is_nil(c.th); assert.is_nil(c.xOffset); assert.is_nil(c.yOffset)
      assert.is_nil(c.border); assert.is_nil(c.frameLevel)
    end)

    it("AUTOCAST: 8th argument — the regression that killed the queue renderer in game", function()
      assert.is_true(Glow.Start(frame(), "AUTOCAST"))
      local c = calls[1]
      assert.equal("AutoCastGlow_Start", c.fn)
      assert.equal("Elmira", c.key)
      -- The bug: "Elmira" arrived here and the library did arithmetic on it.
      assert.is_nil(c.yOffset)
      assert.is_nil(c.xOffset); assert.is_nil(c.scale)
      assert.is_nil(c.N); assert.is_nil(c.frequency); assert.is_nil(c.frameLevel)
    end)

    it("BUTTON: the library takes no key, so nothing extra is passed", function()
      assert.is_true(Glow.Start(frame(), "BUTTON"))
      local c = calls[1]
      assert.equal("ButtonGlow_Start", c.fn)
      assert.is_nil(c.frequency)
      assert.is_nil(c.frameLevel)
    end)

    it("every arithmetic parameter the library will use is a number or nil, never a string", function()
      for _, style in ipairs({ "PIXEL", "AUTOCAST", "BUTTON" }) do
        calls = {}
        Glow.Start(frame(style), style)
        for name, value in pairs(calls[1]) do
          if name ~= "fn" and name ~= "key" and name ~= "r" and name ~= "color" then
            assert.is_not_equal("string", type(value),
              style .. " passed a string into '" .. name .. "'")
          end
        end
      end
    end)
  end)

  describe("stopping", function()
    it("stops with the same key it started with, per style", function()
      for _, case in ipairs({ { "PIXEL", "PixelGlow_Stop", "Elmira" },
                              { "AUTOCAST", "AutoCastGlow_Stop", "Elmira" },
                              { "BUTTON", "ButtonGlow_Stop", nil } }) do
        calls = {}
        local f = frame(case[1])
        Glow.Start(f, case[1])
        assert.is_true(Glow.Stop(f))
        local c = calls[#calls]
        assert.equal(case[2], c.fn)
        assert.equal(f, c.r)
        assert.equal(case[3], c.key)
      end
    end)

    it("an unknown style falls back to PIXEL rather than calling nothing", function()
      assert.is_true(Glow.Start(frame(), "NOPE"))
      assert.equal("PixelGlow_Start", calls[1].fn)
    end)
  end)

  describe("idempotence", function()
    it("does not restart a glow that is already in that style", function()
      local f = frame()
      Glow.Start(f, "PIXEL")
      Glow.Start(f, "PIXEL")
      assert.equal(1, #calls)
    end)

    it("switching style stops the old one before starting the new", function()
      local f = frame()
      Glow.Start(f, "PIXEL")
      Glow.Start(f, "AUTOCAST")
      assert.equal("PixelGlow_Start", calls[1].fn)
      assert.equal("PixelGlow_Stop", calls[2].fn)
      assert.equal("AutoCastGlow_Start", calls[3].fn)
    end)
  end)

  describe("appearance settings reach the library", function()
    it("passes nothing at all when the user has chosen nothing", function()
      Glow.Start(frame(), "PIXEL")
      local c = calls[1]
      assert.is_nil(c.N)          -- the library's own default, not a number of ours
      assert.is_nil(c.frequency)
      assert.is_nil(c.th)
    end)

    it("PIXEL takes particles, speed and thickness at their own positions", function()
      ns.db.profile.glow.particles = 12
      ns.db.profile.glow.frequency = 0.5
      ns.db.profile.glow.thickness = 3
      Glow.Start(frame(), "PIXEL")
      local c = calls[1]
      assert.equal(12, c.N)
      assert.equal(0.5, c.frequency)
      assert.equal(3, c.th)
      assert.equal("Elmira", c.key)     -- still 10th; the numbers must not have shifted it
      assert.is_nil(c.length)
      assert.is_nil(c.xOffset)
    end)

    it("AUTOCAST takes particles and speed, and has no thickness to take", function()
      ns.db.profile.glow.style = "AUTOCAST"
      ns.db.profile.glow.particles = 6
      ns.db.profile.glow.frequency = 0.4
      ns.db.profile.glow.thickness = 3
      Glow.Start(frame(), "AUTOCAST")
      local c = calls[1]
      assert.equal(6, c.N)
      assert.equal(0.4, c.frequency)
      assert.equal("Elmira", c.key)     -- 8th
      assert.is_nil(c.scale)            -- thickness must not have leaked into it
      assert.is_nil(c.xOffset)
    end)

    it("BUTTON takes only speed", function()
      ns.db.profile.glow.frequency = 0.6
      ns.db.profile.glow.particles = 9
      Glow.Start(frame(), "BUTTON")
      local c = calls[1]
      assert.equal(0.6, c.frequency)
      assert.is_nil(c.frameLevel)       -- particles must not have landed here
    end)

    it("PROC is called with an options table, not a row of arguments", function()
      ns.db.profile.glow.speed = 2
      Glow.Start(frame(), "PROC")
      local c = calls[1]
      assert.equal("ProcGlow_Start", c.fn)
      assert.equal(2, c.options.duration)
      assert.equal("Elmira", c.options.key)
      assert.equal(4, #c.options.color)
    end)

    it("stops PROC with our key, so another addon's proc glow survives", function()
      Glow.Start(frame(), "PROC")
      Glow.Stop(calls[1].r)
      assert.equal("ProcGlow_Stop", calls[2].fn)
      assert.equal("Elmira", calls[2].key)
    end)

    it("uses the brand highlight until the user picks a colour", function()
      Glow.Start(frame(), "PIXEL")
      assert.same({ ns.Colors.HIGHLIGHT.r, ns.Colors.HIGHLIGHT.g, ns.Colors.HIGHLIGHT.b, 1 },
                  calls[1].color)
    end)

    it("uses the chosen colour once there is one", function()
      ns.db.profile.glow.color = { r = 0.1, g = 0.2, b = 0.3 }
      Glow.Start(frame(), "PIXEL")
      assert.same({ 0.1, 0.2, 0.3, 1 }, calls[1].color)
    end)
  end)

  describe("what each style can and cannot be told", function()
    it("knows which settings a style actually uses", function()
      assert.is_true(Glow.applies("PIXEL", "thickness"))
      assert.is_false(Glow.applies("AUTOCAST", "thickness"))
      assert.is_true(Glow.applies("AUTOCAST", "particles"))
      assert.is_false(Glow.applies("BUTTON", "particles"))
      assert.is_true(Glow.applies("BUTTON", "frequency"))
      assert.is_true(Glow.applies("PROC", "speed"))
      assert.is_false(Glow.applies("PIXEL", "speed"))
      assert.is_false(Glow.applies("NOT_A_STYLE", "frequency"))
    end)

    -- The sliders would otherwise all read zero, and moving one would look like switching it on.
    it("shows the library's own default until the user chooses", function()
      assert.equal(8, Glow.effective("PIXEL", "particles"))
      assert.equal(0.25, Glow.effective("PIXEL", "frequency"))
      assert.equal(1, Glow.effective("PIXEL", "thickness"))
      assert.equal(4, Glow.effective("AUTOCAST", "particles"))
      assert.equal(0.125, Glow.effective("AUTOCAST", "frequency"))
      assert.equal(0.25, Glow.effective("BUTTON", "frequency"))
      assert.equal(1, Glow.effective("PROC", "speed"))
    end)

    it("shows the user's number once there is one", function()
      ns.db.profile.glow.particles = 15
      assert.equal(15, Glow.effective("PIXEL", "particles"))
    end)

    it("offers Proc as a style the renderer really has", function()
      assert.is_not_nil(Glow.STYLES.PROC)
      assert.equal("ProcGlow_Start", Glow.STYLES.PROC.start)
    end)
  end)

  describe("the dim hint on the cast after next", function()
    local now, later

    before_each(function()
      now, later = frame("now"), frame("later")
      ns.db.profile.glow.barGlow = true
      ns.BarGlow = {
        buttonsFor = function(key)
          if key == "NOW" then return { now }, "ElvUI" end
          if key == "LATER" then return { later }, "ElvUI" end
          return {}, nil
        end,
        noteMissing = function() end,
      }
    end)

    it("stays off until asked for", function()
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      assert.equal(1, Glow.activeCount())
      assert.equal(1, #calls)
      assert.equal(now, calls[1].r)
    end)

    -- How dim "dim" needs to be depends on the style: Proc drives its own alpha animation
    -- (SetToFinalAlpha, from 1 to 1), so a value that reads clearly dimmer on Pixel can look
    -- identical there. Reported from a client 2026-09-05, which is why it is a setting.
    it("takes the dimness from the profile, and falls back to the shipped default", function()
      -- A concrete number, not just "whatever the constant says": asserting them equal to each
      -- other passes just as well when both are nil.
      assert.equal(0.35, Glow.SECONDARY_ALPHA)
      assert.equal(0.35, Glow.secondaryAlpha())
      ns.db.profile.glow.secondaryAlpha = 0.6
      assert.equal(0.6, Glow.secondaryAlpha())
      ns.db.profile.glow.secondaryAlpha = nil
      assert.equal(Glow.SECONDARY_ALPHA, Glow.secondaryAlpha())
    end)

    -- 0 is an invisible hint, which is what the OFF switch is for; above 1 is not a dimming at all.
    it("clamps a dimness that would make the hint pointless", function()
      ns.db.profile.glow.secondaryAlpha = 0
      assert.equal(0.05, Glow.secondaryAlpha())
      ns.db.profile.glow.secondaryAlpha = 5
      assert.equal(1, Glow.secondaryAlpha())
      ns.db.profile.glow.secondaryAlpha = "nonsense"
      assert.equal(Glow.SECONDARY_ALPHA, Glow.secondaryAlpha())
      ns.db.profile.glow.secondaryAlpha = nil
    end)

    it("uses the chosen dimness when it lights the hint", function()
      ns.db.profile.glow.secondary = true
      ns.db.profile.glow.secondaryAlpha = 0.7
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      local second
      for _, c in ipairs(calls) do if c.r == later then second = c end end
      assert.is_not_nil(second, "the hint was never lit")
      assert.equal(0.7, second.color[4])
      assert.equal(1, calls[1].color[4], "the real answer stays at full strength")
      ns.db.profile.glow.secondaryAlpha = nil
    end)

    it("lights the second button under its own key, dimmed", function()
      ns.db.profile.glow.secondary = true
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      assert.equal(2, Glow.activeCount())
      local second
      for _, c in ipairs(calls) do if c.r == later then second = c end end
      assert.is_not_nil(second, "the second suggestion was never glowed")
      assert.equal("ElmiraNext", second.key)
      assert.equal(Glow.SECONDARY_ALPHA, second.color[4])
      assert.equal(1, calls[1].color[4])          -- and the real answer stays at full strength
    end)

    -- Two glows on one button is not more information, it is a flicker.
    it("gives a spell that is both now and next only the bright glow", function()
      ns.db.profile.glow.secondary = true
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "NOW" })
      assert.equal(1, Glow.activeCount())
      -- The END state, not just the first call: lighting it bright and then dim leaves one active
      -- glow and a correct-looking calls[1], and the button is dim. Only the count catches that.
      assert.equal(1, #calls)
      assert.equal("Elmira", calls[1].key)
      assert.equal(1, calls[1].color[4])
    end)

    it("releases the dim glow when the second suggestion changes", function()
      ns.db.profile.glow.secondary = true
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      calls = {}
      Glow.SetNowSlot({ spell = "NOW" }, nil)
      assert.equal(1, Glow.activeCount())
      assert.equal("PixelGlow_Stop", calls[1].fn)
      assert.equal("ElmiraNext", calls[1].key)
    end)

    it("promotes the dim button to bright when it becomes the answer", function()
      ns.db.profile.glow.secondary = true
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      calls = {}
      Glow.SetNowSlot({ spell = "LATER" }, nil)
      local stoppedNext, startedNow = false, false
      for _, c in ipairs(calls) do
        if c.fn == "PixelGlow_Stop" and c.key == "ElmiraNext" then stoppedNext = true end
        if c.fn == "PixelGlow_Start" and c.key == "Elmira" and c.r == later then startedNow = true end
      end
      assert.is_true(stoppedNext, "the dim glow was left on the button")
      assert.is_true(startedNow, "it never got the bright glow")
    end)

    it("drops both when everything goes away", function()
      ns.db.profile.glow.secondary = true
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      Glow.StopAll()
      assert.equal(0, Glow.activeCount())
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      assert.equal(2, Glow.activeCount())   -- StopAll cleared its memory, so both relight
    end)

    -- SetNowSlot picks the style out of the profile. Losing that line falls back to Pixel, which
    -- is invisible in any test that was already using Pixel.
    it("glows in the style the user chose, not always the fallback", function()
      ns.db.profile.glow.style = "BUTTON"
      Glow.SetNowSlot({ spell = "NOW" })
      assert.equal("ButtonGlow_Start", calls[1].fn)
    end)

    -- The only style whose key travels inside an options table. A wrong key here means
    -- ProcGlow_Stop looks for a frame that does not exist and the dim glow is never released.
    it("keys the dim Proc glow separately, so it can be released again", function()
      ns.db.profile.glow.secondary = true
      ns.db.profile.glow.style = "PROC"
      Glow.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
      local second
      for _, c in ipairs(calls) do if c.r == later then second = c end end
      assert.equal("ProcGlow_Start", second.fn)
      assert.equal("ElmiraNext", second.options.key)
      assert.equal(Glow.SECONDARY_ALPHA, second.options.color[4])
      calls = {}
      Glow.SetNowSlot({ spell = "NOW" }, nil)
      assert.equal("ProcGlow_Stop", calls[1].fn)
      assert.equal("ElmiraNext", calls[1].key)
      assert.equal(1, Glow.activeCount())
    end)

    it("passes the second slot through from the renderer", function()
      ns.db.profile.glow.secondary = true
      Glow.Render({ { spell = "NOW" }, { spell = "LATER" } }, "K", true)
      assert.equal(2, Glow.activeCount())
    end)
  end)

  -- Wiring, not behaviour. `BarGlow.noteMissing` was covered in barglow_spec and the CALL to it from
  -- here was not, so deleting the call broke no test at all — "correct code that is never reached"
  -- is this codebase's most reliable failure, and a spec that cannot notice it is decoration.
  describe("SetNowSlot reports a suggestion with no bar button", function()
    local missing

    before_each(function()
      missing = {}
      ns.db = { profile = { glow = { enabled = true, style = "PIXEL", barGlow = true } } }
      ns.BarGlow = {
        buttonsFor = function() return {}, nil end,
        noteMissing = function(key) missing[#missing + 1] = key end,
      }
    end)

    it("tells BarGlow which spell it could not place", function()
      Glow.SetNowSlot({ spell = "EXORCISM" })
      assert.same({ "EXORCISM" }, missing)
    end)

    it("says nothing when a button WAS found", function()
      ns.BarGlow.buttonsFor = function() return { frame("bar") }, "ElvUI" end
      Glow.SetNowSlot({ spell = "EXORCISM" })
      assert.same({}, missing)
    end)

    it("says nothing when the user has bar glow switched off", function()
      ns.db.profile.glow.barGlow = false
      Glow.SetNowSlot({ spell = "EXORCISM" })
      assert.same({}, missing)
    end)

    -- ADR-0015 §3: when the bars cannot be found there is now nothing left to light. The strip is
    -- deliberately not a fallback -- it says "this one" with size, and noteMissing above is what
    -- makes the failure audible instead of silent.
    it("lights nothing at all when the bar lookup finds nothing", function()
      Glow.SetNowSlot({ spell = "EXORCISM" })
      assert.equal(0, Glow.activeCount())
    end)
  end)
end)

-- Its own renderer, not something the strip does on the side. Joined, hiding the icons hid the glow.
describe("Glow.Render", function()
  local Glow, ns, started, stopped

  local function frame(name) return { name = name } end

  before_each(function()
    ns = helper.reset()
    started, stopped = {}, {}
    _G.LibStub = function() return {
      PixelGlow_Start = function(f) started[#started + 1] = f end,
      PixelGlow_Stop = function(f) stopped[#stopped + 1] = f end,
    } end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    Glow = helper.load("Elmira/Display/Glow.lua")
    ns.db = { profile = { glow = { enabled = true, style = "PIXEL", barGlow = true } } }
    ns.BarGlow = { buttonsFor = function() return { frame("bar") }, "ElvUI" end }
  end)

  after_each(function() _G.LibStub = nil end)

  it("glows the first slot of a visible queue", function()
    Glow.Render({ { spell = "EXORCISM" } }, "K", true)
    assert.equal(1, #started)
    assert.equal(1, Glow.activeCount())
  end)

  it("releases everything when the driver says hidden", function()
    Glow.Render({ { spell = "EXORCISM" } }, "K", true)
    Glow.Render({ { spell = "EXORCISM" } }, "K", false)
    assert.equal(1, #stopped)
    assert.equal(0, Glow.activeCount())
  end)

  it("treats an omitted visibility as visible, like every other renderer", function()
    Glow.Render({ { spell = "EXORCISM" } }, "K")
    assert.equal(1, Glow.activeCount())
  end)

  it("releases everything on an empty queue", function()
    Glow.Render({ { spell = "EXORCISM" } }, "K", true)
    Glow.Render({}, "K", true)
    assert.equal(0, Glow.activeCount())
  end)
end)

-- The options panel's preview asks this before stopping a glow it started: between lighting a
-- button and its timer firing, the render loop can take the same frame for the real suggestion.
-- The preview asks this before stopping a glow it started. Asking only about the NOW set left the
-- dim hint to be torn down by a four-second timer, with the render loop still believing it was lit.
describe("Glow.isRendererFrame", function()
  local G, ns, now, later

  before_each(function()
    ns = helper.reset()
    _G.LibStub = function() return {
      PixelGlow_Start = function() end, PixelGlow_Stop = function() end,
    } end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    G = helper.load("Elmira/Display/Glow.lua")
    now, later = { name = "now" }, { name = "later" }
    ns.db = { profile = { glow = { enabled = true, style = "PIXEL", barGlow = true, secondary = true } } }
    ns.BarGlow = {
      buttonsFor = function(key)
        if key == "NOW" then return { now }, "ElvUI" end
        if key == "LATER" then return { later }, "ElvUI" end
        return {}, nil
      end,
      noteMissing = function() end,
    }
  end)

  after_each(function() _G.LibStub = nil end)

  it("owns both the bright button and the dim one", function()
    G.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
    assert.is_true(G.isRendererFrame(now))
    assert.is_true(G.isRendererFrame(later))
  end)

  it("disowns a button the loop has released", function()
    G.SetNowSlot({ spell = "NOW" }, { spell = "LATER" })
    G.SetNowSlot({ spell = "NOW" }, nil)
    assert.is_false(G.isRendererFrame(later))
    assert.is_false(G.isRendererFrame(nil))
  end)
end)

-- The dropdown must not offer a style the loaded library cannot draw: Proc arrived in minor 25.
describe("Glow.available", function()
  local G

  local function loadWith(lib)
    helper.reset()
    _G.LibStub = function() return lib end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    G = helper.load("Elmira/Display/Glow.lua")
  end

  after_each(function() _G.LibStub = nil end)

  it("lists every style a current library can draw", function()
    loadWith({ PixelGlow_Start = function() end, AutoCastGlow_Start = function() end,
               ButtonGlow_Start = function() end, ProcGlow_Start = function() end })
    assert.is_true(G.available().PROC)
    assert.is_true(G.available().PIXEL)
  end)

  it("drops Proc against a library too old to have it", function()
    loadWith({ PixelGlow_Start = function() end, AutoCastGlow_Start = function() end,
               ButtonGlow_Start = function() end })
    assert.is_nil(G.available().PROC)
    assert.is_true(G.available().PIXEL)
  end)

  it("offers nothing at all with no library", function()
    loadWith(nil)
    assert.same({}, G.available())
  end)
end)

describe("Glow.isNowFrame", function()
  local helper5 = require("tests.helper")

  it("knows which frames the render loop is lighting", function()
    helper5.reset()
    local G = helper5.load("Elmira/Display/Glow.lua")
    local frame = { "button" }
    assert.is_false(G.isNowFrame(frame))
    assert.is_false(G.isNowFrame(nil))
    G.StopAll()
    assert.is_false(G.isNowFrame(frame))
  end)
end)
