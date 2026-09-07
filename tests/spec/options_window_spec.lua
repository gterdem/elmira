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
    local t = { points = {} }
    function t:GetTexture() return id end
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
    function f:SetWidth(v) self.width = v end
    function f:SetHeight(v) self.height = v end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:SetNormalTexture(t) self.normalTexture = t end
    function f:SetPushedTexture(t) self.pushedTexture = t end
    function f:SetHighlightTexture(t) self.highlightTexture = t end
    function f:Hide() self.hidden = true end
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
    if opts.noCloseButton then w.frame.children = { notAButton }; w.stockClose = nil end
    if opts.noChildren then w.frame.GetChildren = nil end
    return w
  end

  -- AceConfigDialog, reduced to what Options.Open touches. `FrameOnClose` is the real one's
  -- behaviour: clear OpenFrames and let the widget go back to the pool.
  local function fakeDialog(widget)
    local d = { OpenFrames = {}, defaultSize = nil }
    function d:SetDefaultSize(app, w, h) self.defaultSize = { app, w, h } end
    function d:Open()
      self.OpenFrames.Elmira = widget
      widget:SetCallback("OnClose", function(wid)
        self.OpenFrames.Elmira = nil
        wid.released = true
      end)
    end
    return d
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
      f.kind, f.parent, f.template = kind, parent, template
      created[#created + 1] = f
      return f
    end
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
  end)

  -- Opens the panel the way /elm config does, and hands back the widget it opened onto.
  local function open(opts)
    local widget = fakeWidget(opts)
    Options.dialog = fakeDialog(widget)
    assert.is_true(Options.Open())
    return widget
  end

  describe("scale", function()
    it("draws the frame at the stored scale, clamped so it cannot walk off screen", function()
      local w = open()
      assert.equal(1.2, w.frame.scale)
      -- Scaling happens about the anchor, so without this a scaled-up window drags its own title
      -- bar off the top of the screen -- and the title bar is the only handle it has.
      assert.is_true(w.frame.clamped)
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
    it("installs hooksecurefunc only once across repeated opens", function()
      local w = fakeWidget()
      Options.dialog = fakeDialog(w)
      local hookCalls = 0
      local realHook = _G.hooksecurefunc
      _G.hooksecurefunc = function(...) hookCalls = hookCalls + 1; return realHook(...) end
      Options.Open()
      Options.Open()
      _G.hooksecurefunc = realHook
      assert.equal(1, hookCalls, "hooksecurefunc was called again on a dialog already hooked")
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
