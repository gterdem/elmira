local helper = require("tests.helper")

-- Elmira/Options/Options.lua — the options WINDOW itself: the frame AceConfigDialog opens, rather
-- than the settings inside it. Scale, size, position, the full-width title bar, the X and the
-- reposition button.
--
-- Everything here is asserted against the FRAME, never against the call: "SetScale was called" and
-- "the frame is drawn at 1.2" are different claims, and only the second one is what a player sees.
-- That distinction is the entire reason this file exists -- the panel's chrome is the part of the
-- addon where a setter that runs and changes nothing looks exactly like success.
--
-- The fakes below copy AceGUI rather than invent a frame: `ApplyStatus` is a line-for-line stand-in
-- for AceGUIContainer-Frame.lua:145-158, and the stock Close button is found the way ElvUI finds it
-- (by its text). A fake that is kinder than the real widget would let a broken decoration pass.
describe("Options window", function()
  local Options, ns
  local created   -- every frame Options asked CreateFrame for, in order

  -- A stand-in for the WoW frame. Records rather than draws; `points` is what every position
  -- assertion below reads.
  -- A title-bar texture. AceGUI draws three, all file id 131080; only the middle one is exposed on
  -- the widget, so the end caps have to be found by texture and told apart by identity. Also stands
  -- in for a font string (the version text): real WoW font strings answer to the same SetPoint /
  -- Show / Hide surface as a texture. Declared before fakeFrame, which hands one back from
  -- CreateFontString.
  local function fakeTexture(id)
    local t = { points = {}, texture = id }
    function t:GetTexture() return self.texture end
    -- AT4-D1: the Move toolbar's ability icon is a texture the bar SETS, not one it was built with.
    function t:SetTexture(v) self.texture = v end
    function t:SetHeight(v) self.height = v end
    function t:ClearAllPoints() self.points = {} end
    function t:SetPoint(...) self.points[#self.points + 1] = { ... } end
    -- Real GetPoint/GetNumPoints, not a mock-only shortcut: Options.Undecorate reads a region's own
    -- anchors back through this pair (ElvUI's Config_SaveOldPosition does the same,
    -- Game/Shared/General/Config.lua:998-1006), so a fake that skipped them would let a broken
    -- restore pass.
    function t:GetNumPoints() return #self.points end
    function t:GetPoint(i) return unpack(self.points[i]) end
    function t:SetWidth(v) self.width = v end
    function t:SetJustifyH(v) self.justify = v end
    function t:SetText(v) self.text = v end
    function t:GetText() return self.text end
    function t:SetTextColor(r, g, b) self.color = { r, g, b } end
    function t:Hide() self.hidden = true end
    function t:Show() self.hidden = false end
    return t
  end

  local function fakeFrame(opts)
    opts = opts or {}
    local f = { points = {}, children = {}, regions = {}, scripts = {}, level = 100 }
    function f:SetScale(v) self.scale = v end
    function f:SetClampedToScreen(v) self.clamped = v end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:GetChildren() return unpack(self.children) end
    function f:GetRegions() return unpack(self.regions) end
    function f:GetFrameLevel() return self.level end
    function f:SetFrameLevel(v) self.level = v end
    function f:SetFrameStrata(v) self.strata = v end
    function f:SetWidth(v) self.width = v end
    function f:SetHeight(v) self.height = v end
    -- The four the AceGUI mover/sizer handler reads back off the frame it just dropped
    -- (AceGUIContainer-Frame.lua:39-48). `top`/`left` are set by a test to say where it was dragged.
    function f:GetWidth() return self.width end
    function f:GetHeight() return self.height end
    function f:GetTop() return self.top end
    function f:GetLeft() return self.left end
    function f:GetParent() return self.parent end
    function f:SetText(v) self.text = v end
    function f:SetAllPoints(other) self.allPointsOf = other end
    function f:SetColorTexture(...) self.colorTexture = { ... } end
    function f:CreateTexture()
      local t = fakeTexture(nil)
      t.SetAllPoints = function(tex, other) tex.allPointsOf = other end
      t.SetColorTexture = function(tex, ...) tex.colorTexture = { ... } end
      self.textures = (self.textures or 0) + 1
      -- Both ends of the list are asserted on: the bar's backdrop is the FIRST texture it draws
      -- and the toolbar's ability icon (AT4-D1) is a later one, so "the last texture" alone stopped
      -- being able to identify either.
      self.textureList = self.textureList or {}
      self.textureList[#self.textureList + 1] = t
      self.lastTexture = t
      return t
    end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:GetScript(name) return self.scripts[name] end
    -- The real HookScript APPENDS: the original handler still runs, and ours runs after it. A fake
    -- that replaced would let a SetScript -- which would delete AceGUI's own resize -- pass here.
    function f:HookScript(name, fn)
      local prior = self.scripts[name]
      self.scripts[name] = function(...)
        if prior then prior(...) end
        return fn(...)
      end
    end
    -- AT4-D1: the Move toolbar's two sliders. `SetValue` FIRES OnValueChanged, exactly as the real
    -- one does whether the value came from a drag or from code -- which is the whole reason the
    -- toolbar has to stand its own setter down while it loads an ability's current numbers.
    function f:SetMinMaxValues(low, high) self.range = { low, high } end
    function f:SetValueStep(v) self.valueStep = v end
    function f:SetObeyStepOnDrag(v) self.obeyStep = v and true or false end
    function f:SetOrientation(v) self.orientation = v end
    function f:SetValue(v)
      self.value = v
      if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
    end
    function f:GetValue() return self.value end
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:SetNormalTexture(t) self.normalTexture = t end
    function f:SetPushedTexture(t) self.pushedTexture = t end
    function f:SetHighlightTexture(t) self.highlightTexture = t end
    -- The client fires OnHide when a shown frame is hidden, and does NOT when it was hidden
    -- already. The move bar's own OnHide is how Escape ends a Move mode, so a fake that hid
    -- quietly would make the Done button and Escape indistinguishable here.
    function f:Hide()
      if self.hidden then return end
      self.hidden = true
      if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:Show() self.hidden = false end
    -- The version font string (D12): a plain child created directly on the frame, the same way the
    -- X and the reposition button are.
    function f:CreateFontString()
      local fs = fakeTexture(nil)
      self.fontStrings = (self.fontStrings or 0) + 1
      return fs
    end
    if opts.resizeBounds ~= false then
      function f:SetResizeBounds(a, b, c, d) self.bounds = { a, b, c, d } end
    else
      function f:SetMinResize(a, b) self.minResize = { a, b } end
      function f:SetMaxResize(a, b) self.maxResize = { a, b } end
    end
    return f
  end

  -- The AceGUI Frame container, close enough to the real one to be worth testing against.
  local function fakeWidget(opts)
    opts = opts or {}
    local w = {
      frame = fakeFrame(opts),
      status = (not opts.noStatus) and (opts.status or {}) or nil,
      titlebg = fakeTexture(131080),
      titletext = fakeTexture(nil),
      events = {},
    }
    -- The anchors AceGUI's constructor gives them. Without these, code that forgets to clear the
    -- old points before setting new ones looks identical to code that remembers.
    w.titlebg.points = { { "TOP", 0, 12 } }                       -- AceGUIContainer-Frame.lua:226
    w.titletext.points = { { "TOP", w.titlebg, "TOP", 0, -14 } }  -- AceGUIContainer-Frame.lua:237
    w.capLeft, w.capRight = fakeTexture(131080), fakeTexture(131080)
    -- A texture that is NOT part of the title bar; hiding it would be a bug, so it is here to be
    -- left alone.
    w.other = fakeTexture(137057)
    w.frame.regions = { w.titlebg, w.capLeft, w.capRight, w.other }

    -- AceGUI wires the frame's OnHide to fire OnClose (AceGUIContainer-Frame.lua:28-30, 195), so
    -- HIDING this frame -- by any route, a Move mode included -- runs the whole close chain. A fake
    -- that hid quietly would make "the close chain stood down while it was hidden" untestable, and
    -- the leak it guards against invisible. The client does not fire OnHide on a frame that is
    -- already hidden, and neither does this.
    function w.frame:Hide()
      if self.hidden then return end
      self.hidden = true
      if w.events.OnClose then w.events.OnClose(w, "OnClose") end
    end
    function w.frame:Show() self.hidden = false end

    -- AceGUI's SetTitle: sets the text and re-sizes titlebg to fit it, on EVERY open.
    function w:SetTitle(t) self.titletext:SetText(t); self.titlebg:SetWidth(80) end
    -- A line-for-line stand-in for AceGUIContainer-Frame.lua:145-158.
    function w:ApplyStatus()
      local s = self.status
      self.frame:SetWidth(s.width or 700)
      self.frame:SetHeight(s.height or 500)
      self.frame:ClearAllPoints()
      if s.top and s.left then
        self.frame:SetPoint("TOP", "UIParent", "BOTTOM", 0, s.top)
        self.frame:SetPoint("LEFT", "UIParent", "LEFT", s.left, 0)
      else
        self.frame:SetPoint("CENTER")
      end
    end
    function w:SetCallback(event, fn) self.events[event] = fn end

    -- AceGUI's own Close button: an anonymous child whose text is the client's CLOSE string, whose
    -- click ends in the widget firing OnClose (Button_OnClick -> Hide -> Frame_OnClose).
    local close = fakeFrame()
    function close:GetText() return _G.CLOSE end
    function close:Click()
      w.closeClicks = (w.closeClicks or 0) + 1
      if w.events.OnClose then w.events.OnClose(w, "OnClose") end
    end
    local notAButton = fakeFrame()   -- a child with no text at all, e.g. the status bar
    w.frame.children = { notAButton, close }
    w.stockClose = close

    -- The title drag bar and the three sizers. All four carry the SAME OnMouseUp function
    -- (`MoverSizer_OnMouseUp`, AceGUIContainer-Frame.lua:39-48, installed at :237/:283/:290/:297),
    -- and only the sizers are named on the widget -- which is why Options finds them by that shared
    -- function rather than by name. Behaviour copied line for line: it writes the dropped frame's
    -- size and place into the status table and nothing else.
    w.frame.obj = w
    local function moverUp(mover)
      local frame = mover:GetParent()
      local self = frame.obj
      local status = self.status or self.localstatus
      status.width, status.height = frame:GetWidth(), frame:GetHeight()
      status.top, status.left = frame:GetTop(), frame:GetLeft()
    end
    w.movers = {}
    for _, name in ipairs({ "title", "sizer_se", "sizer_s", "sizer_e" }) do
      local mover = fakeFrame()
      mover.parent = w.frame
      mover:SetScript("OnMouseUp", moverUp)
      w[name] = mover
      w.movers[#w.movers + 1] = mover
      w.frame.children[#w.frame.children + 1] = mover
    end

    if opts.noCloseButton then w.frame.children = { notAButton }; w.stockClose = nil end
    if opts.noChildren then w.frame.GetChildren = nil end
    return w
  end

  -- Drag the window: AceGUI's own handler runs, exactly as it does in game, and whatever Options
  -- has hooked onto it runs after.
  local function dragTo(w, top, left)
    w.frame.top, w.frame.left = top, left
    w.title.scripts.OnMouseUp(w.title)
  end

  -- AceConfigDialog, reduced to what Options.Open touches. `FrameOnClose` is the real one's
  -- behaviour: clear OpenFrames and let the widget go back to the pool.
  local function fakeDialog(widget)
    -- `frame` is the library's own OnUpdate driver, and `closeAllOverride` the opt-out from its
    -- close-everything sweep (AceConfigDialog-3.0.lua:17-22, 1774-1782) -- the one thing FX1-D5
    -- writes on the library itself.
    local d = { OpenFrames = {}, defaultSize = nil, selected = {},
                frame = { closeAllOverride = {} } }
    function d:SetDefaultSize(app, w, h) self.defaultSize = { app, w, h } end
    -- D61e: Options.Open() with no path now selects "general" explicitly (AceConfigDialog-3.0
    -- would otherwise default to the lowest-order group, Rotations); this fake only needs to answer
    -- the call, not track it -- the selection itself is options_spec.lua's job.
    function d:SelectGroup(app, ...) self.selected[#self.selected + 1] = { app, ... } end
    function d:Open()
      self.OpenFrames.Elmira = widget
      widget:SetCallback("OnClose", function(wid)
        self.OpenFrames.Elmira = nil
        wid.released = true
      end)
      -- AceConfigDialog-3.0.lua:1930-1933: every Open ends by showing the frame, whether it was
      -- just created or came back out of the pool.
      widget.frame:Show()
    end
    -- A line-for-line stand-in for AceConfigDialog-3.0.lua:401-425: one status table per appName,
    -- nested one level per path segment, memoized so the SAME table comes back on the next call --
    -- which is what lets `SelectGroup` and the D31 hook agree on which node is "expanded".
    function d:GetStatusTable(appName, path)
      self.status = self.status or {}
      self.status[appName] = self.status[appName] or {}
      local node = self.status[appName]
      for _, key in ipairs(path or {}) do
        node.children = node.children or {}
        node.children[key] = node.children[key] or {}
        node = node.children[key]
      end
      node.status = node.status or {}
      return node.status
    end
    return d
  end

  -- A TreeGroup widget, reduced to what the D31/PE3-D6 hook touches: it is found by `.type`, its
  -- OnButtonEnter callback can be replaced, and it can be told to redraw.
  --
  -- `SetCallback` carries AceGUI's OWN guard (`WidgetBase.SetCallback`, AceGUI-3.0.lua:292-296:
  -- `if type(func) == "function" then`). Without it this stand-in accepted a nil the real widget
  -- silently drops -- which is exactly how the D31 suppression shipped green and left the tooltip
  -- covering the page in game. `hover()` fires the callback the way the tree does on mouseover, so
  -- what a test asserts is whether anything was DRAWN, never which function is installed.
  -- `events` rather than a name of our own: that is the field AceGUI's `WidgetBase.SetCallback`
  -- writes into (AceGUI-3.0.lua:292-296) and the field Options reads to CHAIN a callback instead of
  -- replacing one. A stand-in that kept its callbacks somewhere else would let a chain that never
  -- found the prior handler pass green.
  local function fakeTree()
    local t = { type = "TreeGroup", events = {}, drew = nil }
    function t:SetCallback(name, fn)
      if type(fn) == "function" then self.events[name] = fn end
    end
    function t:RefreshTree() self.refreshed = (self.refreshed or 0) + 1 end
    -- Stands in for AceConfigDialog's TreeOnButtonEnter, whose whole body is "draw a tooltip".
    function t:showsATooltip()
      self.drew = nil
      if self.events.OnButtonEnter then
        self.events.OnButtonEnter(self, "OnButtonEnter", "rotation", {})
      end
      return self.drew == true
    end
    t:SetCallback("OnButtonEnter", function(widget) widget.drew = true end)
    return t
  end

  -- One tree row, reduced to what AB1-D9(a) touches: the icon texture and the row's uniquevalue.
  local function fakeButton(value)
    local icon = { SetDesaturated = function(self, on) self.desaturated = on end }
    return { uniquevalue = value, icon = icon }
  end

  before_each(function()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    ns.db = { global = { window = { scale = 1.2, width = 960, height = 680,
                                    top = false, left = false } } }
    ns.Adapter = { addonVersion = function() return "1.4.0" end }
    ns.Announcers = { StopMoving = function() end }

    created = {}
    _G.CLOSE = "Close"
    _G.UIParent = { GetWidth = function() return 1920 end,
                    GetHeight = function() return 1080 end }
    _G.GameTooltip = {
      SetOwner = function(self, owner) self.owner = owner end,
      SetText = function(self, text) self.text = text end,
      Show = function(self) self.shown = true end,
      Hide = function(self) self.shown = false end,
    }
    _G.CreateFrame = function(kind, name, parent, template)
      local f = fakeFrame()
      f.kind, f.name, f.parent, f.template = kind, name, parent, template
      created[#created + 1] = f
      -- OptionsSliderTemplate publishes three children under the SLIDER's own name (the real
      -- template's low/high end labels and its own title), the same way wow_mock.lua's own
      -- UIDropDownMenuTemplate handling does for a dropdown: AT4-D1's toolbar sliders read all
      -- three back out of `_G` by name, and a template that handed back nothing would leave the
      -- toolbar's own title permanently blank.
      if name and template == "OptionsSliderTemplate" then
        _G[name .. "Low"] = fakeTexture(nil)
        _G[name .. "High"] = fakeTexture(nil)
        _G[name .. "Text"] = fakeTexture(nil)
      end
      return f
    end
    -- The client's list of frame NAMES Escape closes. A table, because that is what the move bar
    -- joins itself to (FX1-D5).
    _G.UISpecialFrames = {}
    -- A real wrapping hooksecurefunc, not the record-only fake other specs use: D13/D15 need the
    -- installed hook to actually FIRE when something (production code, or a test simulating
    -- AceConfigDialog's own refresh) calls the wrapped method, forwarding whatever args the call
    -- site used regardless of what the original function itself declared.
    _G.hooksecurefunc = function(tbl, name, fn)
      local orig = tbl[name]
      tbl[name] = function(...)
        if orig then orig(...) end
        fn(...)
      end
    end

    Options = helper.load("Elmira/Options/Options.lua")
  end)

  after_each(function()
    _G.CLOSE, _G.UIParent, _G.GameTooltip, _G.CreateFrame, _G.hooksecurefunc =
      nil, nil, nil, nil, nil
    _G.UISpecialFrames = nil
    -- The OptionsSliderTemplate stand-ins CreateFrame above publishes by name: real plain globals,
    -- so they must not leak into a spec after this one the way a `ns` table reset cannot reach.
    for _, name in ipairs({ "ElmiraMoveBarSize", "ElmiraMoveBarAlpha" }) do
      _G[name .. "Low"], _G[name .. "High"], _G[name .. "Text"] = nil, nil, nil
    end
  end)

  -- Opens the panel the way /elm config does, and hands back the widget it opened onto.
  local function open(opts)
    local widget = fakeWidget(opts)
    Options.dialog = fakeDialog(widget)
    assert.is_true(Options.Open())
    return widget
  end

  describe("scale", function()
    it("draws the frame at the stored scale", function()
      local w = open()
      assert.equal(1.2, w.frame.scale)
    end)

    -- FX1-D6, the owner: "you can push off many of the addon's screens, so I don't think clamping
    -- was a good idea." The window is free to hang off the edge like every other frame; what
    -- clamping was really guaranteeing -- that the title bar can always be grabbed -- is kept by
    -- the off-screen check below instead.
    it("never clamps the window to the screen", function()
      local w = open()
      assert.is_nil(w.frame.clamped, "the window is still pinned inside the screen")
      Options.SetWindowScale(1.4)
      Options.ResetWindow()
      assert.is_nil(w.frame.clamped)
    end)

    it("ships at 1.2, not at AceGUI's 1.0", function()
      assert.equal(1.2, ns.DB.defaults.global.window.scale)
    end)

    it("applies a new scale to the open frame while the slider is still moving", function()
      local w = open()
      assert.is_true(Options.SetWindowScale(1.35))
      assert.equal(1.35, ns.db.global.window.scale)
      assert.equal(1.35, w.frame.scale, "the slider changed the setting but not the window")
    end)

    it("clamps to the slider's own range, whatever it is handed", function()
      open()
      Options.SetWindowScale(5)
      assert.equal(1.4, Options.windowScale())
      Options.SetWindowScale(0.1)
      assert.equal(0.9, Options.windowScale())
      Options.SetWindowScale(1.05)
      assert.equal(1.05, Options.windowScale())
    end)

    it("falls back to the shipped scale when nothing sensible is stored", function()
      ns.db.global.window.scale = nil
      assert.equal(1.2, Options.windowScale())
      ns.db.global.window.scale = "big"
      assert.equal(1.2, Options.windowScale())
    end)

    -- A position recorded in the frame's own coordinates means a different place on screen at a
    -- different scale, so keeping it is how the title bar ends up above the top of the monitor.
    it("re-centres the window on every scale change", function()
      ns.db.global.window.top, ns.db.global.window.left = 700, 400
      local w = open()
      assert.same({ "TOP", "UIParent", "BOTTOM", 0, 700 }, w.frame.points[1])

      Options.SetWindowScale(1.4)
      assert.is_false(ns.db.global.window.top)
      assert.is_false(ns.db.global.window.left)
      assert.equal(1, #w.frame.points)
      assert.same({ "CENTER" }, w.frame.points[1])
    end)

    it("does nothing but say so when there is no database yet", function()
      ns.db = nil
      assert.is_false(Options.SetWindowScale(1.1))
    end)
  end)

  describe("size and position", function()
    it("seeds the size BEFORE opening, which is the only hook a frame that does not exist has", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      Options.Open()
      assert.same({ "Elmira", 960, 680 }, Options.dialog.defaultSize)
    end)

    it("opens at the remembered size, not at AceGUI's 700x500", function()
      ns.db.global.window.width, ns.db.global.window.height = 1100, 720
      local w = open()
      assert.same({ "Elmira", 1100, 720 }, Options.dialog.defaultSize)
      assert.equal(1100, w.frame.width)
      assert.equal(720, w.frame.height)
      assert.is_true(Options.ApplyWindow(), "applying the stored geometry reported failure")
    end)

    it("ships 960x680 with a floor of 800x560 and a margin off the screen edge", function()
      assert.equal(960, ns.DB.defaults.global.window.width)
      assert.equal(680, ns.DB.defaults.global.window.height)
      local w = open()
      assert.same({ 800, 560, 1870, 1030 }, w.frame.bounds)
    end)

    -- SetResizeBounds replaced the pair in 10.0 and Classic Era got it in stages, so the frame is
    -- asked which one it has. A client with only the old spelling must still be bounded.
    it("uses SetMinResize/SetMaxResize on a frame that has no SetResizeBounds", function()
      local w = open{ resizeBounds = false }
      assert.same({ 800, 560 }, w.frame.minResize)
      assert.same({ 1870, 1030 }, w.frame.maxResize)
    end)

    it("centres a window that has never been positioned", function()
      local w = open()
      assert.same({ "CENTER" }, w.frame.points[1])
      assert.equal(1, #w.frame.points)
    end)

    it("restores a remembered position instead of centring", function()
      ns.db.global.window.top, ns.db.global.window.left = 812.5, 240
      local w = open()
      assert.same({ "TOP", "UIParent", "BOTTOM", 0, 812.5 }, w.frame.points[1])
      assert.same({ "LEFT", "UIParent", "LEFT", 240, 0 }, w.frame.points[2])
    end)

    -- FX1-D6. Nothing is clamped any more, so the one thing clamping guaranteed is kept on its own:
    -- a position stored at another resolution or another scale can leave the title bar -- the only
    -- handle the window has -- entirely off the monitor, and the window would open there with no way
    -- to reach it. Screen is 1920x1080 and the window's scale is 1.2, so the frame's own coordinate
    -- space is 1600x900 wide.
    describe("a stored position that is no longer on the screen", function()
      local function opensAt(top, left)
        ns.db.global.window.top, ns.db.global.window.left = top, left
        return open()
      end

      it("centres, and forgets the position, when the title bar is off the bottom", function()
        local w = opensAt(0, 240)
        assert.same({ "CENTER" }, w.frame.points[1])
        assert.equal(1, #w.frame.points)
        assert.is_false(ns.db.global.window.top, "it would find the same place again next time")
        assert.is_false(ns.db.global.window.left)
      end)

      it("centres when the title bar is above the top of the screen", function()
        -- 900 in frame coordinates is the top edge; the bar is 40 tall, so 941 puts all of it out.
        assert.same({ "CENTER" }, opensAt(941, 240).frame.points[1])
        assert.same({ "TOP", "UIParent", "BOTTOM", 0, 939 }, opensAt(939, 240).frame.points[1])
      end)

      it("centres when the window is off either side", function()
        assert.same({ "CENTER" }, opensAt(700, 1600).frame.points[1])
        assert.same({ "CENTER" }, opensAt(700, -960).frame.points[1])  -- 960 wide, so nothing shows
        assert.same({ "TOP", "UIParent", "BOTTOM", 0, 700 }, opensAt(700, -959).frame.points[1])
      end)

      it("keeps a position that is on the screen", function()
        assert.is_true(Options.positionOnScreen(700, 240, 960))
        assert.is_false(Options.positionOnScreen(0, 240, 960))
        assert.is_false(Options.positionOnScreen(941, 240, 960))
        assert.is_false(Options.positionOnScreen(700, 1600, 960))
        assert.is_false(Options.positionOnScreen(700, -960, 960))
        -- The measurement is in the FRAME's coordinates, which the scale divides: the same 941 that
        -- is off the top at 1.2 is comfortably on screen at 0.9.
        ns.db.global.window.scale = 0.9
        assert.is_true(Options.positionOnScreen(941, 240, 960))
      end)
    end)

    -- AceGUI writes size and position into the status table on every drag-stop, but that table is
    -- memory-only and is wiped when the widget goes back to the pool. Closing is the last moment
    -- the numbers exist.
    it("remembers where and how big it was left when the panel closes", function()
      local w = open()
      w.status.width, w.status.height = 1024, 700
      w.status.top, w.status.left = 900, 300
      w.events.OnClose(w, "OnClose")

      local stored = ns.db.global.window
      assert.equal(1024, stored.width)
      assert.equal(700, stored.height)
      assert.equal(900, stored.top)
      assert.equal(300, stored.left)
      assert.is_true(w.released, "AceConfigDialog's own cleanup was skipped")
    end)

    -- FX1-D7, the owner: "whenever I hit Preview for texture, the Configuration popup is centred on
    -- screen again." Every `execute` button makes AceConfigDialog re-Open the same frame
    -- (AceConfigDialog-3.0.lua:867-872), ApplyWindow re-applied db.top/left on every one of those,
    -- and SaveWindow only ran on close -- so a window dragged since it was opened snapped back to
    -- its last SAVED spot, or to the centre when it had never been positioned.
    describe("staying where the player dragged it", function()
      it("saves the position on drag-stop, without waiting for the window to close", function()
        local w = open()
        dragTo(w, 900, 300)
        assert.equal(900, ns.db.global.window.top, "the drag was never remembered")
        assert.equal(300, ns.db.global.window.left)
      end)

      it("saves the size on resize-stop, from every sizer", function()
        local w = open()
        for _, sizer in ipairs({ w.sizer_se, w.sizer_s, w.sizer_e }) do
          w.frame.width, w.frame.height = w.frame.width + 10, w.frame.height + 5
          sizer.scripts.OnMouseUp(sizer)
          assert.equal(w.frame.width, ns.db.global.window.width)
          assert.equal(w.frame.height, ns.db.global.window.height)
        end
      end)

      -- HookScript, never SetScript: AceGUI's own handler is what fills in the status table this
      -- reads, and it is also what ends the drag or the resize itself.
      it("leaves AceGUI's own drag-stop handler running", function()
        local w = open()
        dragTo(w, 880, 260)
        assert.equal(880, w.status.top, "AceGUI's own handler was replaced, not chained")
        assert.equal(260, w.status.left)
      end)

      it("keeps the dragged position through a re-open, and does not re-centre", function()
        local w = open()
        dragTo(w, 900, 300)
        local points = #w.frame.points

        -- What every execute button does: AceConfigDialog:Open on the SAME frame.
        Options.dialog:Open("Elmira")
        assert.equal(points, #w.frame.points, "the window was re-anchored under the player")
        assert.equal(900, w.status.top, "the status table was overwritten from the database")
        assert.equal(300, w.status.left)
        assert.equal(900, ns.db.global.window.top)
      end)

      -- The other half of the same bug: a window that had NEVER been positioned re-centred on
      -- every execute, which is what the owner actually saw.
      it("keeps a dragged position even when nothing was ever stored", function()
        local w = open()
        assert.same({ "CENTER" }, w.frame.points[1])
        dragTo(w, 700, 200)
        Options.dialog:Open("Elmira")
        assert.equal(1, #w.frame.points, "it was centred again on top of the drag")
        assert.equal(700, w.status.top)
      end)

      -- ...but a window being PUT on screen still gets the stored geometry, which is the whole
      -- point of storing it.
      it("applies the stored position again the next time the window is opened", function()
        local w = open()
        dragTo(w, 900, 300)
        w.frame.elmiraClose.scripts.OnClick()
        ns.db.global.window.top, ns.db.global.window.left = 500, 100

        Options.dialog:Open("Elmira")
        assert.same({ "TOP", "UIParent", "BOTTOM", 0, 500 }, w.frame.points[1])
        assert.same({ "LEFT", "UIParent", "LEFT", 100, 0 }, w.frame.points[2])
      end)

      -- AceGUI's Frame pool is shared with every other Ace3 addon and a script hook cannot be taken
      -- off again, so the hook has to check whose frame it is on before it writes anything.
      it("writes nothing when the frame it was hooked on now belongs to another addon", function()
        local w = open()
        w.frame.elmiraClose.scripts.OnClick()
        assert.is_nil(Options.dialog.OpenFrames.Elmira)
        Options.dialog.OpenFrames.ElvUI = { frame = w.frame }

        ns.db.global.window.top, ns.db.global.window.left = 500, 100
        dragTo(w, 111, 222)
        assert.equal(500, ns.db.global.window.top, "another addon's drag was saved as ours")
        assert.equal(100, ns.db.global.window.left)
      end)

      it("hooks each mover once however many times the panel is decorated", function()
        local w = open()
        local saves = 0
        local real = Options.SaveWindow
        Options.SaveWindow = function(...) saves = saves + 1; return real(...) end
        Options.Decorate()
        Options.Decorate()
        dragTo(w, 900, 300)
        assert.equal(1, saves, "the title bar's drag-stop hook was installed more than once")
        -- The sizers, separately: a second decoration can still SEE `sizer_se` (its handler is our
        -- own wrapper by then, which is what it is compared against), so it is the one a missing
        -- guard would hook again -- and a size saved twice per drag is a save from stale numbers.
        w.frame:SetWidth(1000)
        w.sizer_se.scripts.OnMouseUp(w.sizer_se)
        Options.SaveWindow = real
        assert.equal(2, saves, "the sizer's drag-stop hook was installed more than once")
      end)
    end)

    it("records 'never positioned' as false, not nil, so AceDB writes it", function()
      local w = open()
      w.status.width, w.status.height = 900, 600
      w.status.top, w.status.left = nil, nil
      w.events.OnClose(w, "OnClose")
      assert.is_false(ns.db.global.window.top)
      assert.is_false(ns.db.global.window.left)
    end)

    -- Our callback runs from the frame's OnHide. If it throws, AceConfigDialog's cleanup below it
    -- must still run, or the panel leaks -- and the failure has to be said out loud.
    it("still releases the frame when remembering the size fails, and says so", function()
      local w = open()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      w.status = setmetatable({}, { __index = function() error("status is gone") end })
      w.events.OnClose(w, "OnClose")
      assert.is_true(w.released, "an error in our callback skipped the dialog's cleanup")
      assert.equal(1, #logged)
      assert.is_truthy(logged[1]:find("size", 1, true))
    end)

    -- D45 (2026-09-07 R1b): the same D26 shape as the other conversions -- once Announce is
    -- loaded, this becomes a status update instead of only a log line.
    it("announces the failure as a status update once Announce is loaded, instead of only logging it",
      function()
        local w = open()
        local said = {}
        ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
        local logged = {}
        ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
        w.status = setmetatable({}, { __index = function() error("status is gone") end })
        w.events.OnClose(w, "OnClose")
        assert.equal(0, #logged, "went to the Log, not to a plain print")
        assert.equal(1, #said)
        assert.equal("status", said[1][1])
        assert.is_truthy(said[1][2]:find("size", 1, true))
      end)

    it("saves nothing, and does not error, with no panel open", function()
      Options.dialog = nil
      assert.is_false(Options.SaveWindow())
    end)

    -- Called with no widget it has to find the open one itself, which is what makes it usable from
    -- anywhere rather than only from the close callback that happens to be handed one.
    it("finds the open panel on its own when it is not handed one", function()
      local w = open()
      w.status.width, w.status.height = 880, 590
      assert.is_true(Options.SaveWindow())
      assert.equal(880, ns.db.global.window.width)
      assert.equal(590, ns.db.global.window.height)
    end)

    -- Everything below the status table still has to happen: a widget with no status is a frame
    -- that can still be scaled, clamped and bounded.
    it("scales and bounds a widget that has no status table at all", function()
      local w = open{ noStatus = true }
      assert.equal(1.2, w.frame.scale)
      assert.same({ 800, 560, 1870, 1030 }, w.frame.bounds)
      assert.is_true(Options.ApplyWindow())
    end)

    -- A profile from before this release stores no size, and AceDB only fills in defaults for keys
    -- it already knows. The shipped size is what a window with nothing remembered opens at.
    it("falls back to the shipped size when none was ever stored", function()
      ns.db.global.window.width, ns.db.global.window.height = nil, nil
      local w = open()
      assert.same({ "Elmira", 960, 680 }, Options.dialog.defaultSize)
      assert.equal(960, w.frame.width)
      assert.equal(680, w.frame.height)
    end)

    -- UIParent is how the maximum is worked out. A client that will not answer must still get a
    -- bounded window rather than an arithmetic error on the way to opening the panel.
    it("bounds the window against a default screen when UIParent will not answer", function()
      _G.UIParent = nil
      local w = open()
      assert.same({ 800, 560, 974, 718 }, w.frame.bounds)
    end)
  end)

  describe("the reposition button", function()
    it("puts the size, the scale and the position back, on the frame that is open", function()
      ns.db.global.window.top, ns.db.global.window.left = 900, 300
      ns.db.global.window.width, ns.db.global.window.height = 1300, 900
      ns.db.global.window.scale = 1.4
      local w = open()
      assert.equal(1300, w.frame.width)

      assert.is_true(Options.ResetWindow())

      local stored = ns.db.global.window
      assert.equal(1.2, stored.scale)
      assert.equal(960, stored.width)
      assert.equal(680, stored.height)
      assert.is_false(stored.top)
      assert.is_false(stored.left)
      -- And on the frame in front of the person who clicked it, not only on the next open.
      assert.equal(1.2, w.frame.scale)
      assert.equal(960, w.frame.width)
      assert.same({ "CENTER" }, w.frame.points[1])
    end)

    it("is a button next to the X, with the tooltip that explains it", function()
      local w = open()
      local button = w.frame.elmiraReposition
      assert.is_table(button, "no reposition button was added")
      assert.same({ "RIGHT", w.frame.elmiraClose, "LEFT", 2, 0 }, button.points[1])
      assert.equal(20, button.width)
      assert.equal(20, button.height)
      assert.is_true(button.level > w.frame:GetFrameLevel(), "the button is under the title bar")
      -- Three states, not one: a button that never changes under the cursor reads as decoration.
      assert.equal("Interface\\Buttons\\UI-RefreshButton", button.normalTexture)
      assert.equal("Interface\\Buttons\\UI-RefreshButton-Down", button.pushedTexture)
      assert.equal("Interface\\Buttons\\UI-Common-MouseHilight", button.highlightTexture)

      button.scripts.OnEnter(button)
      assert.equal(button, _G.GameTooltip.owner, "the tooltip is anchored to something else")
      assert.equal("Reset the size and position of this frame.", _G.GameTooltip.text)
      assert.is_true(_G.GameTooltip.shown)
      button.scripts.OnLeave(button)
      assert.is_false(_G.GameTooltip.shown)
    end)

    it("resets when clicked", function()
      ns.db.global.window.scale = 0.9
      local w = open()
      w.frame.elmiraReposition.scripts.OnClick()
      assert.equal(1.2, ns.db.global.window.scale)
      assert.equal(1.2, w.frame.scale)
    end)

    it("does nothing but say so when there is no database yet", function()
      ns.db = nil
      assert.is_false(Options.ResetWindow())
    end)
  end)

  describe("the close button", function()
    it("hides AceGUI's bottom Close button and puts an X in the top right", function()
      local w = open()
      assert.is_true(w.stockClose.hidden, "the stock Close button is still on the panel")
      local x = w.frame.elmiraClose
      assert.is_table(x, "no X was added")
      assert.equal("UIPanelCloseButton", x.template)
      assert.same({ "TOPRIGHT", w.frame, "TOPRIGHT", 2, 2 }, x.points[1])
      assert.is_true(x.level > w.frame:GetFrameLevel(), "the X is under the frame it closes")
    end)

    -- Closing any other way skips AceConfigDialog's FrameOnClose, so OpenFrames keeps pointing at a
    -- hidden widget and the next Open reuses a frame the pool believes is still out on loan.
    it("closes through the stock button, so the dialog's own cleanup still runs", function()
      local w = open()
      w.frame.elmiraClose.scripts.OnClick()
      assert.equal(1, w.closeClicks, "the X did not go through the stock Close button")
      assert.is_nil(Options.dialog.OpenFrames.Elmira, "the frame leaked: OpenFrames still holds it")
      assert.is_true(w.released)
    end)

    -- AceConfigDialog pools frames: the second Open hands back the same one, already decorated.
    it("does not add a second X or a second reposition button on the next open", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      Options.Open()
      local x, reset, count = w.frame.elmiraClose, w.frame.elmiraReposition, #created
      Options.Open()
      assert.equal(count, #created, "a second open created another set of buttons")
      assert.equal(x, w.frame.elmiraClose)
      assert.equal(reset, w.frame.elmiraReposition)
      -- And the stock button is re-hidden, because a pooled frame may have been re-shown.
      assert.is_true(w.stockClose.hidden)
    end)
  end)

  describe("the title bar", function()
    it("spans the whole window, which is what makes all of it draggable", function()
      local w = open()
      -- AceGUI's invisible drag frame is SetAllPoints(titlebg), so the texture's width IS the drag
      -- surface. Before this it was a 100px tab whose position moved with the title text.
      assert.same({ "TOPLEFT", w.frame, "TOPLEFT", 0, 12 }, w.titlebg.points[1])
      assert.same({ "TOPRIGHT", w.frame, "TOPRIGHT", 0, 12 }, w.titlebg.points[2])
      assert.equal(2, #w.titlebg.points)
    end)

    it("hides the two end caps, which would otherwise hang off the sides", function()
      local w = open()
      assert.is_true(w.capLeft.hidden)
      assert.is_true(w.capRight.hidden)
      assert.is_nil(w.titlebg.hidden, "the bar itself was hidden along with its caps")
      assert.is_nil(w.other.hidden, "a texture that is not part of the title bar was hidden")
    end)

    -- D11: no re-anchoring at all -- AceGUI's own TOP-of-titlebg anchor (AceGUIContainer-
    -- Frame.lua:236-237) is left standing, and now that titlebg spans the whole window that anchor
    -- alone centres the name.
    it("leaves the name on AceGUI's own centred anchor, now that the bar is full width", function()
      local w = open()
      assert.same({ { "TOP", w.titlebg, "TOP", 0, -14 } }, w.titletext.points,
        "something re-anchored titletext")
      assert.is_truthy(w.titletext.text:find("Elmira", 1, true))
      assert.is_nil(w.titletext.text:find("1.4.0", 1, true), "the version is still in the title")
    end)

    -- D12: the version lives on a font string of our own, not on titletext, so widget:SetTitle can
    -- never carry it away.
    it("puts the version on its own font string, left of the bar", function()
      local w = open()
      local fs = w.frame.elmiraVersion
      assert.is_table(fs, "no version font string was created")
      assert.same({ "LEFT", w.titlebg, "LEFT", 16, -6 }, fs.points[1])
      assert.equal("LEFT", fs.justify)
      assert.is_truthy(fs.text:find("1.4.0", 1, true))
      assert.same({ ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b }, fs.color)
      assert.is_false(fs.hidden)
    end)

    -- The packager substitutes @project-version@ at release; a dev tree never does, and the TOC's
    -- placeholder is not a version anybody has installed.
    it("says 'dev' rather than showing the unsubstituted placeholder", function()
      ns.Adapter.addonVersion = function() return "@project-version@" end
      assert.equal("dev", Options.versionLine():match("dev"))
      assert.is_nil(Options.versionLine():find("project", 1, true))
    end)

    it("says 'dev' when there is no adapter to ask at all", function()
      ns.Adapter = nil
      assert.is_truthy(Options.versionLine():find("dev", 1, true))
      ns.Adapter = { addonVersion = function() return "" end }
      assert.is_truthy(Options.versionLine():find("dev", 1, true))
    end)

    -- AceConfigDialog calls SetTitle on every Open with the options table's own name, so ours has
    -- to be re-applied after each one -- and the version font string re-created only once.
    it("re-titles on every open, and creates the version font string only once", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      Options.Open()
      local fs = w.frame.elmiraVersion
      w.titletext:SetText("Elmira")     -- what AceConfigDialog would have left behind
      Options.Open()
      assert.equal(Options.windowTitle(), w.titletext.text)
      assert.equal(fs, w.frame.elmiraVersion)
      assert.equal(1, w.frame.fontStrings)
    end)

    -- D13 ROOT CAUSE: the range option's OnMouseUp handler
    -- (AceConfigDialog-3.0.lua:856-862) calls AceConfigDialog:Open(appName, ...) directly -- no
    -- container, so the standalone-frame branch (AceConfigDialog-3.0.lua:1905-1925) runs
    -- f:SetTitle(name) with the OPTIONS TABLE's own `name` (just "Elmira", no version) on the
    -- SAME pooled widget, bypassing Options.Open and therefore Options.Decorate entirely. Before
    -- D12 that overwrote the version text living inside titletext; the hook below is what makes
    -- the fix survive a refresh even if something else about Decorate ever moves back onto
    -- titletext.
    describe("surviving a refresh AceConfigDialog triggers on its own", function()
      it("keeps the version and the centred title after a direct dialog:Open", function()
        local w = open()
        local fs = w.frame.elmiraVersion
        Options.dialog:Open("Elmira")     -- the slider's OnMouseUp path, not Options.Open
        assert.equal(fs, w.frame.elmiraVersion, "a second font string was created")
        assert.equal(1, w.frame.fontStrings)
        assert.is_false(fs.hidden)
        assert.is_truthy(fs.text:find("1.4.0", 1, true))
        assert.same({ { "TOP", w.titlebg, "TOP", 0, -14 } }, w.titletext.points)
      end)

      it("keeps the version after AceGUI's own SetTitle runs directly on the widget", function()
        local w = open()
        local fs = w.frame.elmiraVersion
        w:SetTitle("Elmira")              -- AceGUIContainer-Frame.lua:116-117, unmediated by us
        assert.is_false(fs.hidden)
        assert.is_truthy(fs.text:find("1.4.0", 1, true))
      end)
    end)
  end)

  -- D15: AceGUI's Frame widget pool is shared by every Ace3 addon on the widget TYPE alone
  -- (AceGUI-3.0.lua:88 objPools, ~91-124 newWidget/delWidget), and neither AceGUI's own release
  -- (AceGUI-3.0.lua:172-198) nor AceConfigDialog's FrameOnClose undoes an anchor we moved or a
  -- child we created. Options.Undecorate is what puts the frame back the way AceGUI drew it before
  -- AceConfigDialog hands it to whoever acquires it next.
  describe("giving the pooled frame back clean", function()
    it("undoes every visible trace before the next addon can see the frame", function()
      local w = open()
      local x, reset, version = w.frame.elmiraClose, w.frame.elmiraReposition, w.frame.elmiraVersion

      -- Close through the stock path, the only way a frame is ever supposed to leave OpenFrames.
      w.frame.elmiraClose.scripts.OnClick()
      assert.is_nil(Options.dialog.OpenFrames.Elmira)

      -- The pool hands the IDENTICAL frame table to a different addon; nothing distinguishes it
      -- from Elmira's own widget except which appName the dialog now remembers it under.
      Options.dialog.OpenFrames.ElvUI = { frame = w.frame }

      assert.is_true(x.hidden, "the X is still visible on someone else's window")
      assert.is_true(reset.hidden, "the reposition button is still visible on someone else's window")
      assert.is_true(version.hidden, "the version text is still visible on someone else's window")
      assert.same({ { "TOP", 0, 12 } }, w.titlebg.points, "the title bar was left full width")
      assert.is_false(w.capLeft.hidden, "the left end cap was not given back")
      assert.is_false(w.capRight.hidden, "the right end cap was not given back")
      assert.is_false(w.stockClose.hidden, "the stock Close button was not given back")
    end)

    it("decorates again, still as a single instance, once Elmira gets the frame back", function()
      local w = open()
      local x, reset, version = w.frame.elmiraClose, w.frame.elmiraReposition, w.frame.elmiraVersion
      w.frame.elmiraClose.scripts.OnClick()

      Options.dialog.OpenFrames.Elmira = w
      local countBefore = #created
      assert.is_true(Options.Decorate())

      assert.equal(x, w.frame.elmiraClose, "a second X was created")
      assert.equal(reset, w.frame.elmiraReposition, "a second reposition button was created")
      assert.equal(version, w.frame.elmiraVersion, "a second version font string was created")
      assert.equal(countBefore, #created)
      assert.is_false(x.hidden)
      assert.is_false(reset.hidden)
      assert.is_false(version.hidden)
      assert.same({ { "TOPLEFT", w.frame, "TOPLEFT", 0, 12 }, { "TOPRIGHT", w.frame, "TOPRIGHT", 0, 12 } },
        w.titlebg.points)
    end)

    -- PE11-D5's guard, and AB3-D2's twin of it: a mode that puts a sample on screen and tells the
    -- render loop to leave it alone is stranded by a panel closed mid-drag -- visible in town, with
    -- the button that ends it now behind a shut window.
    it("leaves both texture Move modes when the panel closes", function()
      local stopped = 0
      ns.Textures = { StopMoveMode = function() stopped = stopped + 1; return true end }
      local w = open()
      w.events.OnClose(w, "OnClose")
      assert.equal(1, stopped)
      assert.is_true(w.released)
    end)

    it("still releases the frame when leaving the strip's positioning mode fails, and says so",
      function()
        ns.Queue = { StopPositioning = function() error("the strip is gone") end }
        local w = open()
        local logged = {}
        ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
        w.events.OnClose(w, "OnClose")
        assert.is_true(w.released, "an error leaving the mode skipped the dialog's cleanup")
        local found = false
        for _, msg in ipairs(logged) do
          if msg:find("positioning mode", 1, true) then found = true end
        end
        assert.is_true(found, "no log line mentioned the mode it could not leave")
      end)

    it("still releases the frame when leaving the texture Move mode fails, and says so", function()
      ns.Textures = { StopMoveMode = function() error("the anchor is gone") end }
      local w = open()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      w.events.OnClose(w, "OnClose")
      assert.is_true(w.released, "an error leaving the mode skipped the dialog's cleanup")
      local found = false
      for _, msg in ipairs(logged) do
        if msg:find("texture move mode", 1, true) then found = true end
      end
      assert.is_true(found, "no log line mentioned the mode it could not leave")
    end)

    it("still releases cleanly when there was nothing to undecorate", function()
      assert.is_false(Options.Undecorate(nil))
      assert.is_false(Options.Undecorate({}))
    end)

    it("reports success when it undoes a real widget's chrome", function()
      local w = open()
      assert.is_true(Options.Undecorate(w))
    end)

    -- Same discipline as SaveWindow's own failure test below: an error undoing the chrome must
    -- never be the reason AceConfigDialog's own cleanup is skipped, and it has to say so.
    it("still releases the frame when undoing its chrome fails, and says so", function()
      local w = open()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      w.frame.GetRegions = function() error("regions are gone") end
      w.events.OnClose(w, "OnClose")
      assert.is_true(w.released, "an error in Undecorate skipped the dialog's cleanup")
      local found = false
      for _, msg in ipairs(logged) do
        if msg:find("chrome", 1, true) then found = true end
      end
      assert.is_true(found, "no log line mentioned the failed undecoration")
    end)

    -- Neither GetPoint/GetNumPoints nor CreateFontString is universal on every conceivable region --
    -- a defensive `if` guards each, and this is what proves the guard, not just the happy path,
    -- since every other test's fake answers to all three.
    it("skips saving and creating what a stripped-down frame cannot answer, without erroring", function()
      local w = fakeWidget()
      w.titlebg.GetNumPoints, w.titlebg.GetPoint = nil, nil
      w.frame.CreateFontString = nil
      Options.dialog = fakeDialog(w)
      assert.is_true(Options.Open())
      assert.is_nil(w.frame.elmiraOriginalTitlebg, "there was nothing to read GetPoint from")
      assert.is_nil(w.frame.elmiraVersion, "there was nothing to CreateFontString with")
      -- And closing such a frame -- restoreOriginalPoints handed a nil `saved` -- must not error
      -- either.
      w.events.OnClose(w, "OnClose")
      assert.is_true(w.released)
    end)
  end)

  describe("the refresh hook (D13/D15)", function()
    -- Two hooks live on the dialog now: the refresh hook (D13/D15) and the tree hook (D31). Each
    -- installs itself exactly once, on the FIRST open, and neither again on the second.
    it("installs hooksecurefunc only once per hook across repeated opens", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      local hookCalls = 0
      local realHook = _G.hooksecurefunc
      _G.hooksecurefunc = function(...) hookCalls = hookCalls + 1; return realHook(...) end
      Options.Open()
      Options.Open()
      _G.hooksecurefunc = realHook
      assert.equal(2, hookCalls, "a hook was (re)installed on a dialog already hooked")
    end)

    -- The hook fires synchronously inside dialog:Open, so Options.Open's own explicit fallback must
    -- not ALSO decorate -- otherwise a broken guard would hide behind the fallback's own correctness.
    it("decorates exactly once per open, not once from the hook and once from the fallback", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      local calls = 0
      local realDecorate = Options.Decorate
      Options.Decorate = function(...) calls = calls + 1; return realDecorate(...) end
      Options.Open()
      Options.Decorate = realDecorate
      assert.equal(1, calls)
    end)

    it("is a no-op when the hook fires for a different addon's Open", function()
      local w = open()
      w.frame.elmiraClose:Hide()
      Options.dialog:Open("ElvUI")
      assert.is_true(w.frame.elmiraClose.hidden, "Decorate ran for an app that was not Elmira")
    end)

    -- The one path Options.Open cannot lean on the hook for: no hooksecurefunc on the client at
    -- all. Never true in-game, but the panel still has to open decorated, and close having
    -- remembered itself.
    it("still decorates and chains close by hand when hooksecurefunc is unavailable", function()
      _G.hooksecurefunc = nil
      local w = open()
      assert.is_table(w.frame.elmiraClose, "the panel opened with no chrome at all")
      w.status.width, w.status.height = 900, 600
      w.events.OnClose(w, "OnClose")
      assert.equal(900, ns.db.global.window.width, "the size was never remembered on close")
      assert.is_true(w.frame.elmiraClose.hidden, "Undecorate never ran on close either")
    end)
  end)

  -- D31. FeedGroup builds a TreeGroup widget only once, at the very root -- every navigation after
  -- that re-feeds a group's own content INTO that same tree widget (GroupSelected hands its own
  -- `widget`, the tree, to FeedGroup as `container`; AceConfigDialog-3.0.lua ~1559-1578). So
  -- `container` IS the tree on every call but the first, where it is the standalone Frame with the
  -- tree as its one child (~1743-1751).
  describe("the tree hook (D31)", function()
    -- Fires the hook exactly the way AceConfigDialog's own hooksecurefunc wrapper would: through
    -- `Options.dialog.FeedGroup`, never by calling a private function directly.
    local function feed(appName, container, path)
      Options.dialog.FeedGroup(Options.dialog, appName, {}, container, {}, path or {})
    end

    it("stops the tree drawing a tooltip at all, container == the tree itself", function()
      open()
      local tree = fakeTree()
      assert.is_true(tree:showsATooltip(), "the stand-in never drew one to begin with")
      feed("Elmira", tree, { "rotation" })
      assert.is_false(tree:showsATooltip(),
        "TreeOnButtonEnter (AceConfigDialog-3.0.lua:1485-1524/1730) still covers the page")
    end)

    -- PE3-D6: the callback must still BE a function. `SetCallback(name, nil)` is dropped on the
    -- floor by AceGUI, which is how this suppression shipped and did nothing.
    it("leaves a real function installed, never a nil AceGUI would refuse", function()
      open()
      local tree = fakeTree()
      feed("Elmira", tree, { "rotation" })
      assert.is_function(tree.events.OnButtonEnter,
        "AceGUI drops a non-function, so the original tooltip callback would survive")
    end)

    it("finds the tree among a container's children, container == the root Frame", function()
      open()
      local tree = fakeTree()
      local root = { children = { { type = "SimpleGroup" }, tree } }
      feed("Elmira", root, {})
      assert.is_false(tree:showsATooltip())
    end)

    -- PD2-D3. Expansion of the outer tree belongs to AceConfigDialog, and this is the spec that
    -- decided it. Elmira used to force the just-clicked node open here, for the template/fork
    -- sub-pages PD2 deleted -- and modelled against the real widget it turns out it never opened
    -- anything: `BuildLevel` (AceGUIContainer-TreeGroup.lua:370-385) draws a node's children only
    -- while `tree.status.groups[uniquevalue]` is set, and `tree.status` IS the root status table's
    -- own `.groups` (AceConfigDialog-3.0.lua:1733-1738), so the write landed one level above the
    -- map that is read. Builder and Share open from the "+" arrow or from `SelectGroup`, which
    -- makes that write itself (:471-474).
    --
    -- Asserted as ROWS, not as a flag: "the menu shows Builder and Share" is the only form of this
    -- claim a player could tell apart from success. And the tree is POOLED across every Ace3 addon
    -- on the client, so the second half -- that feeding a page invents no key of ours in its status
    -- table -- is what keeps our bookkeeping off ElvUI's window.
    it("leaves the outer tree's expansion to AceConfigDialog, inventing no status key of its own",
      function()
        open()
        local definition = {
          { value = "general", text = "General" },
          { value = "rotation", text = "Rotations", children = {
              { value = "builder", text = "Builder" }, { value = "share", text = "Share" } } },
        }
        local tree = fakeTree()
        -- Wired exactly the way AceConfigDialog wires it (AceConfigDialog-3.0.lua:1733-1738) and
        -- the way TreeGroup:SetStatusTable then fills it in (AceGUIContainer-TreeGroup.lua:341-346).
        local rootStatus = Options.dialog:GetStatusTable("Elmira", {})
        rootStatus.groups = {}
        tree.status = rootStatus.groups
        tree.status.groups = {}
        -- `BuildLevel`, in shape: a child row exists on screen only while its parent is expanded.
        local function rows()
          local out, groups = {}, tree.status.groups
          local function level(nodes, prefix)
            for _, node in ipairs(nodes) do
              local unique = prefix and (prefix .. "\001" .. node.value) or node.value
              out[#out + 1] = unique
              if node.children and groups[unique] then level(node.children, unique) end
            end
          end
          level(definition, nil)
          return out
        end

        feed("Elmira", tree, { "rotation" })
        assert.same({ "general", "rotation" }, rows())
        -- What the hook IS still for on this tree, on the same feed.
        assert.is_false(tree:showsATooltip())
        -- Nothing of ours anywhere in the pooled widget's status table, at either level.
        assert.same({}, tree.status.groups)
        assert.is_nil(rootStatus.groups["rotation"])
        assert.is_nil(tree.refreshed, "the tree was redrawn for a change nobody made")

        -- The library's own write, for contrast: THIS is what opens the two children.
        tree.status.groups["rotation"] = true
        assert.same({ "general", "rotation", "rotation\001builder", "rotation\001share" }, rows())
      end)

    it("never mutates AceConfigDialog.tooltip -- only the tree widget it found", function()
      open()
      _G.AceConfigDialog = { tooltip = { Hide = function() end } }
      local tooltipBefore = _G.AceConfigDialog.tooltip
      local tree = fakeTree()
      feed("Elmira", tree, { "rotation" })
      assert.equal(tooltipBefore, _G.AceConfigDialog.tooltip)
      _G.AceConfigDialog = nil
    end)

    it("is a no-op for another addon's FeedGroup call, tooltip and status left alone", function()
      open()
      local tree = fakeTree()
      feed("ElvUI", tree, { "something" })
      assert.is_true(tree:showsATooltip(), "silenced another addon's tree tooltip")
      assert.is_nil(tree.refreshed)
    end)

    it("does nothing, without erroring, when the container holds no tree at all", function()
      open()
      assert.has_no.errors(function() feed("Elmira", { children = {} }, { "rotation" }) end)
      assert.has_no.errors(function() feed("Elmira", {}, { "rotation" }) end)
      assert.has_no.errors(function() feed("Elmira", nil, { "rotation" }) end)
      -- Children that exist but are not the tree either -- the loop has to run to the end and
      -- answer nil, not just short-circuit on the first non-match.
      assert.has_no.errors(function()
        feed("Elmira", { children = { { type = "SimpleGroup" }, { type = "Label" } } }, { "rotation" })
      end)
    end)

    it("does nothing when the tree cannot answer SetCallback at all", function()
      open()
      assert.has_no.errors(function() feed("Elmira", { type = "TreeGroup" }, { "rotation" }) end)
    end)
  end)

  -- AT10-D3. The Notifications Log's box is AceGUI's own MultiLineEditBox, and its "Accept" button
  -- (AceGUIWidget-MultiLineEditBox.lua:239 `DisableButton`) is meaningless on a read-only box.
  describe("AT10-D3: the Log box gets no Accept button", function()
    local function feed(container, path)
      Options.dialog.FeedGroup(Options.dialog, "Elmira", {}, container, {}, path or {})
    end

    local function fakeBox()
      local box = { type = "MultiLineEditBox", disableCalls = 0 }
      function box:DisableButton(v) self.disabled = v; self.disableCalls = self.disableCalls + 1 end
      return box
    end

    -- Nested two levels down, the way AceConfigDialog actually builds it: the page's own container
    -- holds the "Notifications Log" InlineGroup, which holds the box itself.
    local function notificationsPage(box)
      return { type = "SimpleGroup", children = { { type = "InlineGroup", children = { box } } } }
    end

    it("disables the Accept button on the Notifications page's log box", function()
      open()
      local box = fakeBox()
      feed(notificationsPage(box), { "notifications" })
      assert.is_true(box.disabled)
      assert.equal(1, box.disableCalls)
    end)

    -- OnAcquire re-enables it (AceGUIWidget-MultiLineEditBox.lua:187), and widgets are pooled --
    -- across every Ace3 addon, not only reused by Elmira -- so a fresh instance handed back to this
    -- page on a later feed starts enabled again and has to be disabled once more.
    it("re-applies it on every feed of the page, not only the first", function()
      open()
      local box = fakeBox()
      local page = notificationsPage(box)
      feed(page, { "notifications" })
      box.disabled = false  -- what OnAcquire does to a widget handed back out of the pool
      feed(page, { "notifications" })
      assert.is_true(box.disabled)
      assert.equal(2, box.disableCalls)
    end)

    it("leaves a MultiLineEditBox on another page alone", function()
      open()
      local box = fakeBox()
      feed(notificationsPage(box), { "general" })
      assert.is_nil(box.disabled)
      assert.equal(0, box.disableCalls)
    end)

    it("does nothing, without erroring, when the page carries no such box at all", function()
      open()
      assert.has_no.errors(function()
        feed({ type = "SimpleGroup", children = {} }, { "notifications" })
      end)
    end)

    it("does nothing, without erroring, when FeedGroup hands over no container at all", function()
      open()
      assert.has_no.errors(function() feed(nil, { "notifications" }) end)
    end)
  end)

  -- AT10-D4. `windowDB().lastPath` is what `Options.Open` reads when asked for no page at all, so
  -- the window reopens where it was left across a `/reload`. Kept current by re-reading the dialog's
  -- own status tree -- the same nested tables `SelectGroup` writes -- on every navigation this hook
  -- sees, whatever depth fired it.
  describe("AT10-D4: remembering the path on every navigation", function()
    local function feed(container, path)
      Options.dialog.FeedGroup(Options.dialog, "Elmira", {}, container, {}, path or {})
    end

    -- Written the way `SelectGroup` itself writes it (AceConfigDialog-3.0.lua:452-488): one
    -- `.groups.selected` per path depth, each in the node `GetStatusTable` hands back for the path
    -- so far.
    local function selectAt(path, key)
      Options.dialog:GetStatusTable("Elmira", path).groups = { selected = key }
    end

    it("writes the full path from the dialog's status tree, however deep it goes", function()
      open()
      selectAt({}, "spells")
      selectAt({ "spells" }, "list")
      selectAt({ "spells", "list" }, "EXORCISM")
      selectAt({ "spells", "list", "EXORCISM" }, "texture")

      feed({ type = "SimpleGroup" }, { "spells", "list", "EXORCISM", "texture" })
      assert.same({ "spells", "list", "EXORCISM", "texture" }, ns.db.global.window.lastPath)
    end)

    it("updates again on the next navigation, replacing what was remembered before", function()
      open()
      selectAt({}, "queue")
      feed({ type = "SimpleGroup" }, { "queue" })
      assert.same({ "queue" }, ns.db.global.window.lastPath)

      selectAt({}, "notifications")
      feed({ type = "SimpleGroup" }, { "notifications" })
      assert.same({ "notifications" }, ns.db.global.window.lastPath)
    end)

    it("leaves the remembered path alone when nothing is selected yet, without erroring", function()
      open()
      local before = ns.db.global.window.lastPath
      assert.has_no.errors(function() feed({ type = "SimpleGroup" }, {}) end)
      assert.same(before, ns.db.global.window.lastPath)
    end)

    it("does nothing for another addon's FeedGroup call", function()
      open()
      ns.db.global.window.lastPath = { "general" }
      selectAt({}, "queue")
      Options.dialog.FeedGroup(Options.dialog, "ElvUI", {}, { type = "SimpleGroup" }, {}, { "queue" })
      assert.same({ "general" }, ns.db.global.window.lastPath)
    end)
  end)

  -- AT6-D5. The Texture tab's texture stands on screen for as long as that tab is the one being
  -- read. Nothing in the fight is holding it, so nothing in the fight will take it away either --
  -- every test here is about the RELEASE, because a preview that outlives its tab is a texture in
  -- the middle of the screen for the rest of the session with no control left to remove it.
  --
  -- The ORDER is the whole difficulty: FeedGroup recurses into itself (a tab group feeds its own
  -- selected tab, AceConfigDialog-3.0.lua:1571), and a post-hook on a nested call runs BEFORE the
  -- hook of the call that made it -- so a rebuild fires deepest-first and "release on anything that
  -- is not a Texture tab" would release it a moment after setting it, every single time.
  describe("the Texture tab's live texture (AT6-D5)", function()
    local held

    local function feed(path)
      Options.dialog.FeedGroup(Options.dialog, "Elmira", {}, { type = "SimpleGroup" }, {}, path)
    end

    before_each(function()
      held = {}
      ns.Textures = { Preview = function(key) held[#held + 1] = key or false end,
                      StopMoveMode = function() end }
    end)

    it("holds the ability's texture when its Texture tab is fed", function()
      open()
      feed({ "spells", "list", "EXORCISM", "texture" })
      assert.same({ "EXORCISM" }, held)
    end)

    it("releases it when another tab of the same ability is fed", function()
      open()
      feed({ "spells", "list", "EXORCISM", "glow" })
      assert.same({ false }, held)
    end)

    it("releases it when another page of the window is fed", function()
      open()
      feed({ "spells", "list", "EXORCISM", "texture" })
      feed({ "queue" })
      assert.same({ "EXORCISM", false }, held)
    end)

    it("releases it on the Share tab, which is not the ability list at all", function()
      open()
      feed({ "spells", "share" })
      assert.same({ false }, held)
    end)

    -- Selecting another ability feeds {spells,list,KEY} and, nested inside it, that ability's
    -- remembered tab. The remembered tab is in the status table by the time our hook runs, so the
    -- shallower call reaches the SAME answer as the deeper one instead of undoing it.
    it("reads the remembered tab when a whole ability is fed", function()
      open()
      Options.dialog:GetStatusTable("Elmira", { "spells", "list", "EXORCISM" }).groups =
        { selected = "texture" }
      feed({ "spells", "list", "EXORCISM" })
      assert.same({ "EXORCISM" }, held)

      Options.dialog:GetStatusTable("Elmira", { "spells", "list", "JUDGEMENT" }).groups =
        { selected = "sound" }
      feed({ "spells", "list", "JUDGEMENT" })
      assert.same({ "EXORCISM", false }, held)
    end)

    -- The shallow rebuild paths fire LAST and must say nothing at all, or the whole window being
    -- re-fed (which AceConfigDialog does on every single option change) would take the preview off
    -- screen a moment after putting it there.
    it("says nothing on the paths that are only rebuilding the page around it", function()
      open()
      feed({ "spells", "list", "EXORCISM", "texture" })
      feed({ "spells", "list" })
      feed({ "spells" })
      feed({})
      assert.same({ "EXORCISM" }, held, "a rebuild of the page took the preview off screen")
    end)

    it("is a no-op for another addon's FeedGroup call", function()
      open()
      Options.dialog.FeedGroup(Options.dialog, "ElvUI", {}, { type = "SimpleGroup" }, {},
                               { "spells", "list", "EXORCISM", "texture" })
      assert.same({}, held)
    end)

    -- The one path every close goes through. Without this the window shuts on a Texture tab and
    -- leaves the texture standing there with nothing left anywhere to remove it.
    it("releases the texture when the options window is closed", function()
      local w = open()
      feed({ "spells", "list", "EXORCISM", "texture" })
      w.events.OnClose(w, "OnClose")
      assert.same({ "EXORCISM", false }, held)
    end)

    -- And every Move mode, which hides the window rather than closing it -- the close chain stands
    -- down on that path, so the release has to happen where the window is hidden.
    it("releases the texture when the window is hidden for a Move mode", function()
      open()
      feed({ "spells", "list", "EXORCISM", "texture" })
      Options.BeginMove("strip")
      assert.same({ "EXORCISM", false }, held)
    end)

    it("survives with no Textures module at all", function()
      ns.Textures = nil
      open()
      assert.has_no.errors(function() feed({ "spells", "list", "EXORCISM", "texture" }) end)
    end)
  end)

  -- AB1-D9. `spells` is a TAB group whose "Abilities" child is a tree, so FeedGroup builds a SECOND
  -- TreeGroup (`(parenttype ~= "tree")`, AceConfigDialog-3.0.lua:1721) and hands it over on the path
  -- {"spells","list"}. Everything here is about that widget alone.
  describe("the inner Abilities tree (AB1-D9)", function()
    local function feed(container, path)
      Options.dialog.FeedGroup(Options.dialog, "Elmira", {}, container, {}, path)
    end

    before_each(function()
      helper.load("Elmira/Core/AbilitySettings.lua")
      ns.db.char = { abilities = {} }
    end)

    -- The OUTER tree's tooltip is suppressed (PE3-D6: it covered the page). Silencing this one
    -- would take the per-ability "Glow, Sound on · ..." summary AB1-D9(b) exists to show with it.
    it("keeps the tooltip the outer tree has suppressed", function()
      open()
      local tree = fakeTree()
      feed(tree, { "spells", "list" })
      assert.is_true(tree:showsATooltip(), "the channel summary tooltip was silenced")
      assert.is_nil(tree.refreshed, "the inner tree's rows are flat; nothing to expand")
    end)

    -- AB1-D9(a). `UpdateButton` only ever calls SetTexture on a row's icon
    -- (AceGUIContainer-TreeGroup.lua:92-95), so there is no "greyed" flag to set in the options
    -- table -- it has to happen on the button.
    describe("desaturating the abilities with nothing switched on", function()
      -- AB2-D6: the mark counts the four non-inherited channels only. Glow is on for everything by
      -- default, so counting it left every icon full colour in the owner's first look.
      it("greys a row with nothing switched on and leaves a configured one alone", function()
        open()
        local A = ns.AbilitySettings
        A.set("EXORCISM", "sound", "enabled", true)
        A.set("EXORCISM", "sound", "used", "Chime")
        local tree = fakeTree()
        tree.buttons = { fakeButton("*"), fakeButton("EXORCISM"), fakeButton("QUIET") }
        feed(tree, { "spells", "list" })
        assert.is_false(tree.buttons[1].icon.desaturated, "All abilities is never greyed")
        assert.is_false(tree.buttons[2].icon.desaturated, "a sound is switched on for it")
        assert.is_true(tree.buttons[3].icon.desaturated, "glow alone must not colour a row")
      end)

      it("re-runs on every feed, so switching a cue on un-greys the row", function()
        open()
        local A = ns.AbilitySettings
        local tree = fakeTree()
        tree.buttons = { fakeButton("QUIET") }
        feed(tree, { "spells", "list" })
        assert.is_true(tree.buttons[1].icon.desaturated)
        A.set("QUIET", "announce", "enabled", true)
        feed(tree, { "spells", "list", "QUIET" })
        assert.is_false(tree.buttons[1].icon.desaturated)
      end)

      it("reports how many rows it marked, and marks none it cannot", function()
        open()
        local tree = fakeTree()
        tree.buttons = { fakeButton("EXORCISM"), { uniquevalue = "NO_ICON" },
                         { icon = { SetDesaturated = function() end } } }
        assert.equal(1, Options.markAbilityIcons(tree))
        assert.equal(0, Options.markAbilityIcons(fakeTree()))
        assert.equal(0, Options.markAbilityIcons(nil))
        ns.AbilitySettings = nil
        assert.equal(0, Options.markAbilityIcons(tree))
      end)
    end)

    -- AB1-D9(d). Each ability page is its own tab group with its own status table, so the Glow tab
    -- you were reading is "selected" for THAT ability and nothing for the next one.
    describe("keeping the tab when you select another ability", function()
      it("copies the previous ability's selected tab into the new one", function()
        open()
        assert.is_nil(Options.keepAbilityTab("EXORCISM"), "nothing to copy from on the first select")
        local from = Options.dialog:GetStatusTable("Elmira", { "spells", "list", "EXORCISM" })
        from.groups = { selected = "glow" }
        assert.equal("glow", Options.keepAbilityTab("JUDGEMENT"))
        local to = Options.dialog:GetStatusTable("Elmira", { "spells", "list", "JUDGEMENT" })
        assert.equal("glow", to.groups.selected)
      end)

      it("copies nothing when the previous ability had no tab selected, or is the same one", function()
        open()
        -- The destination already sits on a tab of its own; a source with nothing selected must
        -- leave that alone rather than writing nil over it.
        local to = Options.dialog:GetStatusTable("Elmira", { "spells", "list", "JUDGEMENT" })
        to.groups = { selected = "announce" }
        Options.keepAbilityTab("EXORCISM")
        assert.is_nil(Options.keepAbilityTab("JUDGEMENT"), "no tab was ever selected")
        assert.equal("announce", to.groups.selected, "it wrote a nil selection over a real one")
        assert.is_nil(Options.keepAbilityTab("JUDGEMENT"), "selecting the same row again")
      end)

      it("says nothing rather than erroring with no dialog", function()
        Options.dialog = nil
        assert.is_nil(Options.keepAbilityTab("EXORCISM"))
      end)

      -- CHAINED, never replaced: AceGUI holds ONE callback per event name, so overwriting
      -- OnGroupSelected would silently delete AceConfigDialog's own GroupSelected and the tree
      -- would stop feeding pages at all. This has cost two outages.
      it("chains onto AceConfigDialog's own OnGroupSelected rather than replacing it", function()
        open()
        local fedTo = {}
        local tree = fakeTree()
        tree:SetCallback("OnGroupSelected", function(_, _, value) fedTo[#fedTo + 1] = value end)
        feed(tree, { "spells", "list" })

        tree.events.OnGroupSelected(tree, "OnGroupSelected", "EXORCISM")
        local from = Options.dialog:GetStatusTable("Elmira", { "spells", "list", "EXORCISM" })
        from.groups = { selected = "sound" }
        tree.events.OnGroupSelected(tree, "OnGroupSelected", "JUDGEMENT")
        assert.same({ "EXORCISM", "JUDGEMENT" }, fedTo, "the library's own handler stopped running")
        local to = Options.dialog:GetStatusTable("Elmira", { "spells", "list", "JUDGEMENT" })
        assert.equal("sound", to.groups.selected)
      end)

      -- Re-feeding must not wrap the wrapper: a chain that grows on every navigation calls the
      -- library's handler N times and re-selects the tab N times.
      it("installs itself once however many times the tree is fed", function()
        open()
        local calls = 0
        local tree = fakeTree()
        tree:SetCallback("OnGroupSelected", function() calls = calls + 1 end)
        feed(tree, { "spells", "list" })
        local wrapper = tree.events.OnGroupSelected
        feed(tree, { "spells", "list", "EXORCISM" })
        assert.equal(wrapper, tree.events.OnGroupSelected)
        tree.events.OnGroupSelected(tree, "OnGroupSelected", "EXORCISM")
        assert.equal(1, calls)
      end)

      -- AceGUI pools TreeGroups across every Ace3 addon on the client. `Release` wipes
      -- `widget.events`, so our chained callback goes with it -- and we must leave nothing else
      -- behind on the widget for the next addon to inherit.
      it("writes nothing onto the pooled widget except the callback AceGUI itself clears", function()
        open()
        local tree = fakeTree()
        local before = {}
        for key in pairs(tree) do before[key] = true end
        tree:SetCallback("OnGroupSelected", function() end)
        feed(tree, { "spells", "list" })
        for key in pairs(tree) do
          assert.is_true(before[key] == true, "left " .. tostring(key) .. " on a pooled widget")
        end
        -- AceGUI's Release wipes `widget.events` (AceGUI-3.0.lua:188-190), and with it every trace
        -- of us: the next addon handed this TreeGroup gets its own callbacks back.
        tree.events = {}
        assert.is_false(tree:showsATooltip())
      end)

      it("survives a tree that cannot answer SetCallback", function()
        open()
        assert.has_no.errors(function()
          Options.dialog.FeedGroup(Options.dialog, "Elmira", {}, { type = "TreeGroup" },
                                   {}, { "spells", "list" })
        end)
      end)
    end)

    -- AB1-D1. `SetStatusTable` fills `treewidth` in with AceGUI's 175 the moment the widget is
    -- built and there is no pre-hook to get in front of it, so the width is seeded into the status
    -- table at Open time instead.
    describe("the tree's opening width", function()
      it("seeds 220 into the status table once, and never fights a resize", function()
        open()
        local status = Options.dialog:GetStatusTable("Elmira", { "spells", "list" })
        assert.equal(220, status.groups.treewidth)
        status.groups.treewidth = 300
        assert.is_false(Options.seedAbilityTree(), "it wrote over a width the player had dragged")
        assert.equal(300, status.groups.treewidth)
        -- ...and it reports having seeded a status table that has never been touched, so a caller
        -- can tell "already set" from "there was nowhere to write".
        status.groups.treewidth = nil
        assert.is_true(Options.seedAbilityTree())
        assert.equal(220, status.groups.treewidth)
      end)

      it("says so rather than erroring with no dialog", function()
        Options.dialog = nil
        assert.is_false(Options.seedAbilityTree())
      end)
    end)
  end)

  -- FX1-D5. The owner, trying to place a texture: "I can not move it around since the Configuration
  -- page is too big and I can not move the configuration page out of the screen." Every Move mode
  -- now hides the window and leaves a small bar behind, the way ElvUI's movers do.
  --
  -- The load-bearing distinction, and the reason this whole block exists: the window is HIDDEN, not
  -- CLOSED. AceGUI fires OnClose from the frame's OnHide either way, so without the guard the close
  -- chain would end the mode one line after it started and hand the widget back to the pool.
  describe("hiding the window while something is being moved (FX1-D5)", function()
    local stopped

    local function bar()
      for _, f in ipairs(created) do
        if f.name == "ElmiraMoveBar" then return f end
      end
    end

    before_each(function()
      stopped = { strip = 0, textures = 0, messages = 0 }
      ns.Queue = { StopPositioning = function() stopped.strip = stopped.strip + 1 end }
      ns.Textures = { StopMoveMode = function() stopped.textures = stopped.textures + 1 end }
      ns.Announcers = { StopMoving = function() stopped.messages = stopped.messages + 1 end }
    end)

    it("takes the window off the screen and puts a bar there instead", function()
      local w = open()
      assert.is_true(Options.BeginMove("strip"))
      assert.is_true(w.frame.hidden, "the window is still covering what is being dragged")
      local b = bar()
      assert.is_table(b, "no bar was left on screen")
      assert.is_false(b.hidden)
      assert.is_truthy(b.elmiraText.text:find("the queue strip", 1, true))
      assert.is_truthy(b.elmiraText.text:find("Done", 1, true))
      assert.equal("Done", b.elmiraDone.text)
    end)

    -- A bar with no size, no anchor and no backdrop is a bar nobody can see, which is the same as
    -- no bar at all -- and there is nothing else on screen saying how to get the window back.
    it("is a readable bar and not an invisible one", function()
      open()
      Options.BeginMove("strip")
      local b = bar()
      assert.equal("Frame", b.kind)
      assert.equal(_G.UIParent, b.parent)
      assert.equal("FULLSCREEN_DIALOG", b.strata, "the bar draws under the frames being moved")
      assert.equal(380, b.width)
      assert.equal(76, b.height)
      assert.same({ "TOP", _G.UIParent, "TOP", 0, -40 }, b.points[1])
      local backdrop = b.textureList[1]
      assert.is_table(backdrop, "no backdrop was drawn behind the text")
      assert.equal(b, backdrop.allPointsOf, "the backdrop does not cover the bar")
      assert.same({ 0, 0, 0, 0.85 }, backdrop.colorTexture, "the backdrop is invisible")
      -- Both horizontal anchors, which is what makes the sentence wrap instead of running off the
      -- ends of the bar.
      assert.same({ "TOPLEFT", b, "TOPLEFT", 10, -10 }, b.elmiraText.points[1])
      assert.same({ "TOPRIGHT", b, "TOPRIGHT", -10, -10 }, b.elmiraText.points[2])
      assert.equal("CENTER", b.elmiraText.justify)

      local done = b.elmiraDone
      assert.equal("UIPanelButtonTemplate", done.template)
      assert.equal(b, done.parent)
      assert.equal(110, done.width)
      assert.equal(22, done.height)
      assert.same({ "BOTTOM", b, "BOTTOM", 0, 10 }, done.points[1])
    end)

    -- Every word on it goes through AceLocale, the same as every other user-facing string.
    it("puts everything it says through the locale", function()
      open()
      setmetatable(ns.L, { __index = function(_, k) return "[" .. k .. "]" end })
      ns.Display = { spellName = function() return "Exorcism" end }
      Options.BeginMove("texture", "EXORCISM")
      assert.equal("[Exorcism's texture]", Options.moveSubject())
      assert.equal("[Moving [Exorcism's texture]. Drag it where you want it, then press Done.]",
                   bar().elmiraText.text)
      assert.equal("[Done]", bar().elmiraDone.text)
      Options.EndMove()
      Options.BeginMove("strip")
      assert.equal("[Moving [the queue strip]. Drag it where you want it, then press Done.]",
                   bar().elmiraText.text)
    end)

    -- AT4-D1. The owner, dragging a texture around: "I also want to select the texture to try
    -- different stuff and also to be able to change the size, without seeing the Configuration
    -- popup; in a clear screen". So the bar grows a row of live controls -- but ONLY while one
    -- texture is being dragged, and every one of them writes the same `texture` channel the Texture
    -- tab writes, or the window would come back disagreeing with the screen.
    describe("the Move toolbar (AT4-D1)", function()
      local A, refreshes, panelCalls

      before_each(function()
        ns.db.char = { abilities = {} }
        A = helper.load("Elmira/Core/AbilitySettings.lua")
        refreshes = 0
        ns.Textures = {
          StopMoveMode = function() stopped.textures = stopped.textures + 1 end,
          sizeOf = function(e) return tonumber(e and e.size) or 48 end,
          Refresh = function() refreshes = refreshes + 1 end,
        }
        ns.Display = {
          spellName = function(key) return "Name of " .. key end,
          spellIcon = function(key) return "icon:" .. key end,
        }
        panelCalls = {}
        ns.TexturePanel = {
          Toggle = function(key) panelCalls[#panelCalls + 1] = { "toggle", key } end,
          isOpen = function() return true end,
          Close = function(cancelled) panelCalls[#panelCalls + 1] = { "close", cancelled } end,
        }
      end)

      it("names the ability it is for and opens at its current size, colour and opacity", function()
        open()
        A.set("EXORCISM", "texture", "size", 96)
        A.set("EXORCISM", "texture", "alpha", 0.4)
        A.set("EXORCISM", "texture", "color", { r = 0.2, g = 0.4, b = 0.9 })
        Options.BeginMove("texture", "EXORCISM")
        local b = bar()
        assert.equal("icon:EXORCISM", b.elmiraIcon:GetTexture())
        assert.equal("Name of EXORCISM", b.elmiraName.text)
        assert.equal(96, b.elmiraSize.value)
        assert.equal(0.4, b.elmiraAlpha.value)
        assert.same({ 0.2, 0.4, 0.9, 1 }, b.elmiraSwatch.elmiraFill.colorTexture)
        -- AT8-D5: the toolbar's own slider follows the tab's new 16-512 range.
        assert.same({ 16, 512 }, b.elmiraSize.range)
        assert.same({ 0.05, 1 }, b.elmiraAlpha.range)
        assert.same({ 120, 16 }, { b.elmiraSize.width, b.elmiraSize.height })
        assert.same({ 120, 16 }, { b.elmiraAlpha.width, b.elmiraAlpha.height })
        assert.same({ 24, 24 }, { b.elmiraSwatch.width, b.elmiraSwatch.height })
        -- Every control is sized and placed off the one before it, left to right, so a missing
        -- width anywhere would stack two of them on the same spot.
        assert.same({ 32, 32 }, { b.elmiraIcon.width, b.elmiraIcon.height })
        assert.equal(120, b.elmiraName.width)
        assert.equal("LEFT", b.elmiraName.justify)
        assert.same({ 90, 22 }, { b.elmiraChoose.width, b.elmiraChoose.height })
        assert.equal("Texture", b.elmiraChoose.text)
        assert.equal("Colour", b.elmiraSwatchLabel.text)
        -- Each control anchored off the one before it, left to right: a missing anchor anywhere
        -- would stack two controls on the same spot instead of shifting the row.
        assert.same({ "TOPLEFT", b, "TOPLEFT", 12, -44 }, b.elmiraIcon.points[1])
        assert.same({ "LEFT", b.elmiraIcon, "RIGHT", 8, 0 }, b.elmiraName.points[1])
        assert.same({ "LEFT", b.elmiraName, "RIGHT", 8, 0 }, b.elmiraChoose.points[1])
        assert.same({ "LEFT", b.elmiraChoose, "RIGHT", 20, 0 }, b.elmiraSize.points[#b.elmiraSize.points])
        assert.same({ "LEFT", b.elmiraSize, "RIGHT", 24, 10 }, b.elmiraSwatchLabel.points[1])
        assert.same({ "LEFT", b.elmiraSize, "RIGHT", 24, -6 }, b.elmiraSwatch.points[1])
        assert.equal(b.elmiraSwatch, b.elmiraSwatch.elmiraFill.allPointsOf,
          "the colour fill does not cover its own swatch")
        assert.same({ "LEFT", b.elmiraSwatch, "RIGHT", 24, 0 }, b.elmiraAlpha.points[#b.elmiraAlpha.points])
        assert.equal("HORIZONTAL", b.elmiraSize.orientation)
        assert.equal(8, b.elmiraSize.valueStep)
        assert.is_true(b.elmiraSize.obeyStep)
        assert.equal(0.05, b.elmiraAlpha.valueStep)
        -- The template's own end labels are blanked (the toolbar draws its own number in the
        -- title, in the middle), and the title itself reads "<label>: <value>" in each slider's
        -- own format.
        assert.equal("", _G.ElmiraMoveBarSizeLow:GetText())
        assert.equal("", _G.ElmiraMoveBarSizeHigh:GetText())
        assert.equal("Size: 96", _G.ElmiraMoveBarSizeText:GetText())
        assert.equal("Opacity: 0.40", _G.ElmiraMoveBarAlphaText:GetText())
        bar().elmiraSize:SetValue(200)
        assert.equal("Size: 200", _G.ElmiraMoveBarSizeText:GetText())
        for _, region in ipairs(b.elmiraTools) do
          assert.is_false(region.hidden, "a toolbar control was left off the bar")
        end
        assert.equal(620, b.width, "the bar did not make room for the toolbar")
        assert.equal(130, b.height)
      end)

      -- "The template's own label does not follow a SetValue on every client": a real Blizzard
      -- slider does not always re-fire OnValueChanged from a SetValue the way this harness's own
      -- fake always does, so applyToolbar retitles explicitly rather than trusting that call alone.
      it("retitles explicitly rather than trusting the slider's own OnValueChanged", function()
        open()
        A.set("EXORCISM", "texture", "size", 96)
        A.set("EXORCISM", "texture", "alpha", 0.4)
        Options.BeginMove("texture", "EXORCISM")
        local b = bar()
        -- Simulate the client quirk the comment describes: this slider's OnValueChanged does not
        -- fire from the load that is about to happen.
        b.elmiraSize.scripts.OnValueChanged, b.elmiraAlpha.scripts.OnValueChanged = nil, nil
        Options.EndMove()
        A.set("EXORCISM", "texture", "size", 200)
        A.set("EXORCISM", "texture", "alpha", 0.6)
        Options.BeginMove("texture", "EXORCISM")
        assert.equal("Size: 200", _G.ElmiraMoveBarSizeText:GetText())
        assert.equal("Opacity: 0.60", _G.ElmiraMoveBarAlphaText:GetText())
      end)

      -- Loading is not editing. SetValue fires OnValueChanged exactly as a drag does, so without
      -- the guard, opening the toolbar would write its own starting numbers back over the settings
      -- it had just read -- and a repaint on every open is how you hide that it happened.
      it("writes nothing while it is loading the ability's own values", function()
        open()
        A.set("EXORCISM", "texture", "size", 96)
        Options.BeginMove("texture", "EXORCISM")
        assert.equal(0, refreshes, "loading the toolbar repainted, so it was writing")
        assert.equal(96, A.effective("EXORCISM", "texture").size)
      end)

      it("writes the size and the opacity straight to the ability, and repaints", function()
        open()
        Options.BeginMove("texture", "EXORCISM")
        bar().elmiraSize:SetValue(120)
        assert.equal(120, A.effective("EXORCISM", "texture").size)
        assert.equal(1, refreshes, "the texture on screen was not repainted")
        bar().elmiraAlpha:SetValue(0.25)
        assert.equal(0.25, A.effective("EXORCISM", "texture").alpha)
        assert.equal(2, refreshes)
      end)

      -- The client's own colour picker, on the contract this client answers. What matters is what
      -- happens to the SETTING when a colour comes back, and what happens when the player cancels.
      it("opens the client's colour picker and stores what comes back", function()
        open()
        local shown
        _G.ColorPickerFrame = {
          SetupColorPickerAndShow = function(_, info) shown = info end,
          GetColorRGB = function() return 0.1, 0.2, 0.3 end,
        }
        Options.BeginMove("texture", "EXORCISM")
        bar().elmiraSwatch.scripts.OnClick()
        assert.is_table(shown, "no colour picker was opened")
        assert.is_false(shown.hasOpacity)
        assert.same({ 1.0, 0.8274509803921568, 0.47843137254901963 },
          { shown.r, shown.g, shown.b }, "the picker did not open on the current colour")

        shown.swatchFunc()
        assert.same({ r = 0.1, g = 0.2, b = 0.3 }, A.effective("EXORCISM", "texture").color)
        assert.same({ 0.1, 0.2, 0.3, 1 }, bar().elmiraSwatch.elmiraFill.colorTexture)

        -- Cancel puts back what the swatch opened on, so changing your mind changes nothing.
        shown.cancelFunc()
        local c = A.effective("EXORCISM", "texture").color
        assert.equal(1.0, c.r)
        _G.ColorPickerFrame = nil
      end)

      -- The pre-10.2.5 contract, which Classic Era has carried alongside the modern one the whole
      -- time (AceGUIWidget-ColorPicker.lua:64 branches on exactly this test): set the fields, then
      -- show it. `Hide` first, because that frame reads them in its own `OnShow`.
      it("falls back to the pre-10.2.5 colour picker contract and stores what comes back", function()
        open()
        local hid, shown, seeded = false, false, nil
        _G.ColorPickerFrame = {
          SetColorRGB = function(_, r, g, b) seeded = { r, g, b } end,
          Hide = function() hid = true end,
          Show = function() assert.is_true(hid, "shown before the pre-open hide"); shown = true end,
        }
        Options.BeginMove("texture", "EXORCISM")
        bar().elmiraSwatch.scripts.OnClick()
        assert.is_true(shown, "no colour picker was opened")
        assert.is_false(_G.ColorPickerFrame.hasOpacity)
        assert.same({ 1.0, 0.8274509803921568, 0.47843137254901963 }, seeded,
          "the picker did not open pre-loaded with the current colour")

        _G.ColorPickerFrame.func()
        assert.same({ r = 1.0, g = 0.8274509803921568, b = 0.47843137254901963 },
          A.effective("EXORCISM", "texture").color,
          "the pre-10.2.5 contract has no GetColorRGB, so the swatch's own colour is kept")

        -- Cancel puts back what the swatch opened on, so changing your mind changes nothing.
        A.set("EXORCISM", "texture", "color", { r = 0.2, g = 0.2, b = 0.2 })
        _G.ColorPickerFrame.cancelFunc()
        local c = A.effective("EXORCISM", "texture").color
        assert.equal(1.0, c.r)
        _G.ColorPickerFrame = nil
      end)

      it("says so rather than erroring on a client with no colour picker frame at all", function()
        open()
        _G.ColorPickerFrame = nil
        Options.BeginMove("texture", "EXORCISM")
        assert.has_no.errors(function() bar().elmiraSwatch.scripts.OnClick() end)
      end)

      it("does nothing, without erroring, with no settings store to read the colour from", function()
        open()
        local shown = false
        _G.ColorPickerFrame = { SetupColorPickerAndShow = function() shown = true end }
        Options.BeginMove("texture", "EXORCISM")
        ns.AbilitySettings = nil
        assert.has_no.errors(function() bar().elmiraSwatch.scripts.OnClick() end)
        assert.is_false(shown, "the picker opened with no colour to seed it from")
      end)

      it("opens the texture picker for the ability being moved", function()
        open()
        Options.BeginMove("texture", "EXORCISM")
        bar().elmiraChoose.scripts.OnClick()
        assert.same({ { "toggle", "EXORCISM" } }, panelCalls)
      end)

      -- Done must not throw away the texture the player has been looking at on screen: the picker
      -- is closed as KEPT, never cancelled.
      it("closes the picker window when the mode ends, keeping the choice", function()
        open()
        Options.BeginMove("texture", "EXORCISM")
        Options.EndMove()
        assert.same({ { "close", false } }, panelCalls)
      end)

      -- Every other Move mode keeps the bar it always had: there is nothing on a queue strip or a
      -- run of screen messages for these controls to write to, and a control that writes to nothing
      -- is this project's characteristic defect.
      it("is not on the bar for any other mode, and leaves none of itself behind", function()
        open()
        Options.BeginMove("texture", "EXORCISM")
        Options.EndMove()
        Options.BeginMove("strip")
        local b = bar()
        for _, region in ipairs(b.elmiraTools) do
          assert.is_true(region.hidden, "a texture control stayed on the bar for another mode")
        end
        assert.equal(380, b.width)
        assert.equal(76, b.height)
        -- ...and the slider is inert now: nothing to write to, so nothing is written.
        b.elmiraSize:SetValue(200)
        assert.equal(0, refreshes)
        assert.is_nil(ns.db.char.abilities.EXORCISM,
          "a slider with no ability behind it still wrote a settings row")
      end)

      -- EndMove's OWN clear, isolated from a later BeginMove("strip") also clearing it: nothing
      -- must write to the ability once the mode that was dragging it has simply ENDED.
      it("stops writing to the ability once EndMove itself has run, with no other mode started",
        function()
          open()
          A.set("EXORCISM", "texture", "size", 96)
          Options.BeginMove("texture", "EXORCISM")
          local b = bar()
          Options.EndMove()
          refreshes = 0
          b.elmiraSize:SetValue(300)
          assert.equal(0, refreshes, "a slider from an ended mode still repainted the screen")
          assert.equal(96, A.effective("EXORCISM", "texture").size, "the ended mode still wrote")
        end)
    end)

    -- A client with no CreateFrame at all is only reachable in a spec, but the mode still has to
    -- start: the window getting out of the way is the part that matters.
    it("still hides the window on a client that will not make the bar", function()
      local w = open()
      _G.CreateFrame = nil
      assert.is_true(Options.BeginMove("strip"))
      assert.is_true(w.frame.hidden)
      assert.is_nil(bar())
      assert.is_true(Options.EndMove())
      assert.is_false(w.frame.hidden)
    end)

    -- The whole of the difference between hiding and closing. If the chain runs, it stops the mode
    -- that just started, saves the window, undoes the chrome and -- through `prior` -- hands the
    -- widget back to AceGUI's pool for another addon to acquire while we still intend to show it.
    it("does not run the close chain, and does not let go of the frame", function()
      local w = open()
      Options.BeginMove("strip")
      assert.equal(0, stopped.strip, "the close chain stopped the mode that had just started")
      assert.equal(0, stopped.textures)
      assert.equal(0, stopped.messages)
      assert.is_nil(w.released, "the widget went back to the pool while it was only hidden")
      assert.equal(w, Options.dialog.OpenFrames.Elmira, "the panel is no longer the open one")
      assert.is_false(w.frame.elmiraClose.hidden, "the chrome was undecorated by a mere hide")
    end)

    -- The button that starts a Move mode is an `execute`, and AceConfigDialog re-Opens the whole
    -- panel the instant its func returns (AceConfigDialog-3.0.lua:867-872) -- Open ending in
    -- f:Show() (:1930-1933). Without the re-hide the mode's own button undoes the mode's own hide,
    -- which is the "looks right, does nothing in game" shape exactly.
    it("stays hidden through the re-open every execute button triggers", function()
      local w = open()
      Options.BeginMove("strip")
      Options.dialog:Open("Elmira")
      assert.is_true(w.frame.hidden, "the window came straight back over what is being moved")
      assert.is_nil(w.released, "re-hiding it released the widget to the pool")
      assert.equal(w, Options.dialog.OpenFrames.Elmira)
      assert.is_not_nil(Options.moveSubject(), "the mode was ended by the refresh")
      -- ...and it still comes back when the mode ends.
      Options.EndMove()
      assert.is_false(w.frame.hidden)
    end)

    it("leaves an ordinary refresh alone: it only re-hides while a mode is running", function()
      local w = open()
      Options.dialog:Open("Elmira")
      assert.is_false(w.frame.hidden, "a plain refresh hid the panel")
      assert.is_nil(w.released)
    end)

    it("puts the same window back, on the page it was on, and takes the bar away", function()
      local w = open()
      Options.dialog:GetStatusTable("Elmira", {}).groups = { selected = "spells\001list" }
      Options.BeginMove("strip")
      local before = #Options.dialog.selected

      assert.is_true(Options.EndMove())
      assert.is_false(w.frame.hidden, "the window never came back")
      assert.is_true(bar().hidden, "the bar is still on screen with nothing being moved")
      assert.is_nil(Options.moveSubject())
      assert.same({ "Elmira", "spells", "list" }, Options.dialog.selected[before + 1],
        "it came back on a different page from the one it left")
    end)

    it("ends every Move mode there is, not only the one that started it", function()
      open()
      Options.BeginMove("texture", "EXORCISM")
      Options.EndMove()
      assert.equal(1, stopped.strip)
      assert.equal(1, stopped.textures)
      assert.equal(1, stopped.messages)
    end)

    it("is a no-op when nothing is being moved", function()
      local w = open()
      assert.is_false(Options.EndMove())
      assert.is_false(Options.BeginMove("not a mode"))
      assert.is_false(w.frame.hidden)
      assert.equal(0, stopped.strip)
    end)

    -- Each Stop* calls EndMove, so EndMove must not call them back round again.
    it("does not loop when the mode it stops ends the mode itself", function()
      open()
      ns.Queue.StopPositioning = function()
        stopped.strip = stopped.strip + 1
        Options.EndMove()
      end
      Options.BeginMove("strip")
      assert.is_true(Options.EndMove())
      assert.equal(1, stopped.strip)
    end)

    it("names what is being moved, per mode, as a phrase a sentence can be built round", function()
      open()
      local function subjectOf(what, key)
        Options.EndMove()
        Options.BeginMove(what, key)
        return Options.moveSubject()
      end
      assert.is_truthy(subjectOf("strip"):find("the queue strip", 1, true))
      assert.is_truthy(subjectOf("messages"):find("your screen messages", 1, true))
      -- The ability as the player knows it, through the merged lookup -- not EXORCISM.
      ns.Display = { spellName = function(key) return key == "EXORCISM" and "Exorcism" or nil end }
      assert.is_truthy(subjectOf("texture", "EXORCISM"):find("Exorcism's texture", 1, true))
      ns.Display = nil
      assert.is_truthy(subjectOf("texture", "JUDGEMENT"):find("JUDGEMENT's texture", 1, true))
    end)

    -- Escape reaches the bar through the client's own UISpecialFrames list, which is a list of
    -- global frame NAMES.
    it("joins the list of frames Escape closes, once", function()
      open()
      Options.BeginMove("strip")
      Options.EndMove()
      Options.BeginMove("strip")
      local named = 0
      for _, name in ipairs(_G.UISpecialFrames) do
        if name == "ElmiraMoveBar" then named = named + 1 end
      end
      assert.equal(1, named)
    end)

    -- Done and Escape both end the mode, and each has to keep working after the other has been
    -- used: the flag that tells them apart is reset, not left standing.
    it("ends the mode by Escape again after the Done button was used once", function()
      local w = open()
      Options.BeginMove("strip")
      bar().elmiraDone.scripts.OnClick()
      Options.BeginMove("messages")
      assert.is_true(w.frame.hidden)
      bar().scripts.OnHide()
      assert.is_nil(Options.moveSubject(), "Escape no longer ends the mode")
      assert.is_false(w.frame.hidden)
    end)

    it("ends the mode when Escape hides the bar", function()
      local w = open()
      Options.BeginMove("strip")
      bar().scripts.OnHide()
      assert.is_nil(Options.moveSubject())
      assert.equal(1, stopped.strip)
      assert.is_false(w.frame.hidden, "Escape ended the mode but left the window hidden")
    end)

    -- AceConfigDialog wraps CloseSpecialWindows to close every options window a frame after Escape
    -- hides the bar (AceConfigDialog-3.0.lua:1854-1860, 1774-1782). Without the library's own opt-out
    -- the window we are putting back would be shut again on the next OnUpdate.
    it("keeps the restored window out of the close-everything sweep Escape triggers", function()
      open()
      Options.BeginMove("strip")
      bar().scripts.OnHide()
      assert.is_true(Options.dialog.frame.closeAllOverride.Elmira)
    end)

    it("leaves that sweep alone when the Done button ends the mode", function()
      local w = open()
      Options.BeginMove("strip")
      bar().elmiraDone.scripts.OnClick()
      assert.is_nil(Options.dialog.frame.closeAllOverride.Elmira,
        "a later Escape would no longer close the panel")
      assert.is_nil(Options.moveSubject())
      assert.is_false(w.frame.hidden)
    end)

    it("ends the mode rather than opening a second window over it", function()
      local w = open()
      Options.BeginMove("strip")
      assert.is_true(Options.Open("queue"))
      assert.is_nil(Options.moveSubject(), "the mode is still running with the window on top of it")
      assert.is_true(bar().hidden)
      assert.is_false(w.frame.hidden)
    end)

    -- The Builder's live refresh ends in AceConfigDialog re-Opening the app, which SHOWS the frame.
    -- While a mode has it hidden that would pop the window back up over the sample being dragged.
    it("keeps the Builder's live refresh from re-showing the hidden window", function()
      open()
      local status = Options.dialog:GetStatusTable("Elmira", { "rotation" })
      status.groups = { selected = "builder" }
      assert.is_true(Options.builderIdle())
      Options.BeginMove("strip")
      assert.is_false(Options.builderIdle())
      Options.EndMove()
      assert.is_true(Options.builderIdle())
    end)

    -- The pool again: if anything released the frame while it was hidden, showing it would put our
    -- page back onto a window that now belongs to somebody else.
    it("opens a fresh panel rather than showing a frame the pool has handed on", function()
      local w = open()
      Options.BeginMove("strip")
      Options.dialog.OpenFrames.Elmira = nil     -- released while we were not looking
      Options.dialog.OpenFrames.ElvUI = { frame = w.frame }
      local opened = 0
      Options.dialog.Open = function() opened = opened + 1 end

      assert.is_true(Options.EndMove())
      assert.equal(1, opened, "no panel was opened in its place")
      assert.is_true(w.frame.hidden, "another addon's window was shown with our page on it")
    end)

    it("says so rather than erroring when there is no window to hide", function()
      Options.dialog = { OpenFrames = {} }
      assert.is_true(Options.BeginMove("strip"))
      assert.is_false(bar().hidden, "the bar is the only thing left saying a mode is on")
      assert.is_true(Options.EndMove())
    end)
  end)

  describe("nothing to decorate", function()
    it("decorates nothing and reports it", function()
      Options.dialog = { OpenFrames = {} }
      assert.is_false(Options.Decorate())
      assert.is_false(Options.ApplyWindow())
    end)

    it("reports that it decorated the panel it was given", function()
      open()
      assert.is_true(Options.Decorate())
    end)

    -- Both are about a frame that is not the AceGUI Frame we expect. Neither may take the panel
    -- down on the way up: the settings are still worth opening without an X on them.
    it("opens a frame whose children cannot be enumerated", function()
      local w = open{ noChildren = true }
      assert.is_table(w.frame.elmiraClose)
    end)

    it("opens a frame with no stock Close button, and clicking the X then does nothing", function()
      local w = open{ noCloseButton = true }
      w.frame.elmiraClose.scripts.OnClick()
      assert.is_not_nil(Options.dialog.OpenFrames.Elmira)
    end)

    it("opens against a dialog that has no SetDefaultSize", function()
      local w = fakeWidget()
      local d = fakeDialog(w)
      d.SetDefaultSize = nil
      Options.dialog = d
      assert.is_true(Options.Open())
    end)

    -- A profile saved before this release has no `window` key at all, and AceDB only fills in
    -- defaults for tables it already knows about.
    it("creates the window table on a database that has never had one", function()
      ns.db.global.window = nil
      assert.equal(1.2, Options.windowScale())
      assert.is_table(ns.db.global.window)
    end)
  end)
end)
