local helper = require("tests.helper")

-- Elmira/Display/Announcers.lua — the four things that can actually speak (PRD F37).
--
-- Core/Announce decides what is said and where; this file is the only one that touches a chat
-- frame, a message frame, a sound or PARTY CHAT. That last one is why the fakes below record
-- arguments rather than counting calls: the one channel other people see must be provably gated on
-- both the category being shareable in code and there actually being a group to say it to.
describe("Display.Announcers", function()
  local Announcers, ns, frames, chat, sent, played, mediaFiles

  local function fakeFrame(kind, name)
    local f = { kind = kind, name = name, messages = {}, scripts = {}, shown = true,
                point = { "TOP", nil, "TOP", 0, -140 } }
    function f:AddMessage(text, r, g, b, a)
      self.messages[#self.messages + 1] = { text = text, r = r, g = g, b = b, a = a }
    end
    function f:Clear() self.messages = {} end
    function f:SetFont(path, size, flags) self.font = { path, size, flags } end
    function f:SetTimeVisible(v) self.timeVisible = v end
    function f:SetFadeDuration(v) self.fadeDuration = v end
    function f:SetInsertMode(v) self.insertMode = v end
    function f:SetJustifyH(v) self.justify = v end
    function f:SetFading(v) self.fading = v end
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:RegisterForDrag(...) self.dragButtons = { ... } end
    function f:SetScript(e, fn) self.scripts[e] = fn end
    function f:GetScript(e) return self.scripts[e] end
    function f:SetMovable(v) self.movable = v and true or false end
    function f:SetSize(w, h) self.size = { w, h } end
    function f:SetClampedToScreen(v) self.clamped = v and true or false end
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
    return setmetatable(f, { __index = function(_, k)
      -- D25's capability tiers must see a GENUINE absence, not this fixture's usual "any
      -- capitalised method is a harmless no-op" convenience -- otherwise every fake frame would
      -- silently "have" ContainsMessageGroup and the messageTypeList tier could never be reached.
      if k == "ContainsMessageGroup" then return nil end
      if type(k) == "string" and k:match("^%u") then return function() end end
      return nil
    end })
  end

  local function fakeMedia()
    return {
      List = function(_, kind)
        if kind == "font" then return { "Friz Quadrata TT", "Expressway" } end
        return { "Elmira chime", "Whisper" }
      end,
      Fetch = function(_, kind, name) return mediaFiles[kind .. ":" .. name] end,
    }
  end

  before_each(function()
    ns = helper.reset()
    frames, sent, played = {}, {}, {}
    mediaFiles = {
      ["font:Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
      ["font:Expressway"] = "Interface\\AddOns\\Media\\Expressway.ttf",
      ["sound:Elmira chime"] = "Interface\\AddOns\\Media\\chime.ogg",
    }
    _G.CreateFrame = function(kind, name)
      local f = fakeFrame(kind, name)
      frames[#frames + 1] = f
      return f
    end
    _G.UIParent = fakeFrame("Frame", "UIParent")
    -- ChatFrame1 IS the default chat frame, same object, same as the real client: D25 asks every
    -- chat window whether it shows System messages rather than trusting a stored index.
    chat = { default = fakeFrame("ChatFrame", "ChatFrame1"), two = fakeFrame("ChatFrame", "ChatFrame2") }
    _G.DEFAULT_CHAT_FRAME = chat.default
    _G.ChatFrame1 = chat.default
    _G.ChatFrame2 = chat.two
    _G.NUM_CHAT_WINDOWS = 2
    local chatGroups = { [chat.default] = { SYSTEM = true }, [chat.two] = {} }
    _G.ChatFrame_ContainsMessageGroup = function(f, group) local t = chatGroups[f]; return t and t[group] end
    _G.SendChatMessage = function(text, channel) sent[#sent + 1] = { text = text, channel = channel } end
    _G.PlaySoundFile = function(path) played[#played + 1] = path end
    _G.IsInGroup = function() return true end
    _G.IsInRaid = function() return false end
    _G.LibStub = function(major) return major == "LibSharedMedia-3.0" and fakeMedia() or nil end

    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    helper.load("Elmira/Core/Announce.lua")
    Announcers = helper.load("Elmira/Display/Announcers.lua")
    ns.db = {
      profile = {
        announce = {
          sound = "None", sounds = {},
          screen = { font = "Friz Quadrata TT", size = 18, duration = 4,
                     anchor = { point = "TOP", relPoint = "TOP", x = 0, y = -140 } },
          routes = {},
        },
      },
      global = { announceLog = {} },
    }
    ns.Announce.use{ now = function() return 1 end, inCombat = function() return false end }
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent, _G.DEFAULT_CHAT_FRAME, _G.ChatFrame1, _G.ChatFrame2 =
      nil, nil, nil, nil, nil
    _G.NUM_CHAT_WINDOWS, _G.ChatFrame_ContainsMessageGroup, _G.SendChatMessage = nil, nil, nil
    _G.PlaySoundFile, _G.IsInGroup, _G.IsInRaid, _G.LibStub = nil, nil, nil, nil
  end)

  local function row(text, icon) return { text = text, icon = icon } end
  local function cat(key) return ns.Announce.category(key) end

  describe("the on-screen frame", function()
    it("is a MessageFrame that fades, anchored where the profile says", function()
      local f = Announcers.Create()
      assert.equal("MessageFrame", f.kind)
      assert.equal("ElmiraToast", f.name)
      assert.is_true(f.fading)
      assert.equal(4, f.timeVisible)
      assert.equal(1, f.fadeDuration)
      assert.equal("TOP", f.insertMode)
      assert.equal("CENTER", f.justify)
      assert.equal(-140, f.point[5])
      assert.same({ 600, 120 }, f.size)
      -- Movable and clamped, or "Move" has nothing to drag and the frame can be lost off-screen.
      assert.is_true(f.movable)
      assert.is_true(f.clamped)
      assert.same({ "LeftButton" }, f.dragButtons)
    end)

    it("is registered on the namespace, which is how Core/Init reaches it", function()
      assert.equal(Announcers, ns.Announcers)
    end)

    it("answers before it has been built rather than erroring", function()
      helper.reset()
      helper.load("Elmira/Core/Colors.lua")
      helper.load("Elmira/Core/DB.lua")
      helper.load("Elmira/Core/Announce.lua")
      local fresh = helper.load("Elmira/Display/Announcers.lua")
      assert.is_false(fresh.ApplyFont())
      assert.is_false(fresh.SaveAnchor())
      assert.is_true(fresh.SetMoving(true))
    end)

    -- It sits over the middle of the screen. One that eats clicks there is worse than one you
    -- cannot move, so the mouse is off until the panel turns move mode on.
    it("ignores the mouse until you ask to move it", function()
      local f = Announcers.Create()
      assert.is_false(f.mouse)
      Announcers.SetMoving(true)
      assert.is_true(f.mouse)
      Announcers.SetMoving(false)
      assert.is_false(f.mouse)
    end)

    it("is built once", function()
      assert.equal(Announcers.Create(), Announcers.Create())
    end)

    it("takes its font and size from the media library", function()
      Announcers.Create()
      assert.same({ "Fonts\\FRIZQT__.TTF", 18, "OUTLINE" }, Announcers.frame().font)
      ns.db.profile.announce.screen.font = "Expressway"
      ns.db.profile.announce.screen.size = 24
      assert.is_true(Announcers.ApplyFont())
      assert.same({ "Interface\\AddOns\\Media\\Expressway.ttf", 24, "OUTLINE" }, Announcers.frame().font)
    end)

    -- A font pack the player has since uninstalled. Passing nil to SetFont blanks every message
    -- with no error anywhere, which is the silent failure this project keeps shipping.
    it("keeps its own font when the chosen one is gone", function()
      Announcers.Create()
      local before = Announcers.frame().font
      ns.db.profile.announce.screen.font = "A font nobody has"
      assert.is_false(Announcers.ApplyFont())
      assert.same(before, Announcers.frame().font)
    end)

    it("applies a new duration without a reload", function()
      Announcers.Create()
      ns.db.profile.announce.screen.duration = 9
      Announcers.ApplyFont()
      assert.equal(9, Announcers.frame().timeVisible)
    end)

    it("reports that it saved the anchor", function()
      Announcers.Create()
      assert.is_true(Announcers.SaveAnchor())
    end)

    it("remembers where it was dragged to", function()
      local f = Announcers.Create()
      Announcers.SetMoving(true)
      f.scripts.OnDragStart()
      assert.is_true(f.moving)
      f:SetPoint("CENTER", "CENTER", 10, 20)
      f.scripts.OnDragStop()
      assert.is_false(f.moving)
      local anchor = ns.db.profile.announce.screen.anchor
      assert.equal("CENTER", anchor.point)
      assert.equal(10, anchor.x)
      assert.equal(20, anchor.y)
    end)

    it("refuses to be dragged when move mode is off", function()
      local f = Announcers.Create()
      f.scripts.OnDragStart()
      assert.is_falsy(f.moving)
    end)

    -- A frame positioned while empty is a frame positioned wrongly: the samples show how tall it
    -- really gets, and in which colours.
    it("shows one sample of every kind while moving, and clears them after", function()
      Announcers.Create()
      assert.is_true(Announcers.SetMoving(true))
      assert.equal(#ns.Announce.CATEGORIES, #Announcers.frame().messages)
      assert.is_true(Announcers.isMoving())
      -- The samples must stay up while you drag; the real duration would fade them away mid-move.
      assert.is_true(Announcers.frame().timeVisible > 60)
      Announcers.SetMoving(false)
      assert.equal(0, #Announcers.frame().messages)
      assert.equal(4, Announcers.frame().timeVisible)   -- and the real duration comes back
    end)
  end)

  describe("the screen sink", function()
    before_each(function() Announcers.Create() end)

    it("says it did", function()
      assert.is_true(Announcers.screen(cat("rotation"), row("moved")))
    end)

    it("colours the message by category, not one colour for everything", function()
      Announcers.screen(cat("rotation"), row("moved"))
      Announcers.screen(cat("warning"), row("careful"))
      local msgs = Announcers.frame().messages
      assert.equal(ns.Colors.HIGHLIGHT.r, msgs[1].r)
      assert.equal(ns.Colors.WARN.r, msgs[2].r)
      assert.not_equal(msgs[1].r, msgs[2].r)
    end)

    it("says the sentence it was given", function()
      Announcers.screen(cat("rotation"), row("moved"))
      assert.equal("moved", Announcers.frame().messages[1].text)
    end)

    -- The icon of the spell the message is about, so a glance says which ability changed before
    -- the sentence has been read.
    it("inlines the icon in front of the text when there is one", function()
      Announcers.screen(cat("rotation"), row("moved", "Interface\\Icons\\X"))
      assert.equal("|TInterface\\Icons\\X:0|t moved", Announcers.frame().messages[1].text)
    end)

    it("says nothing before the frame exists", function()
      helper.reset()
      helper.load("Elmira/Core/Colors.lua")
      helper.load("Elmira/Core/DB.lua")
      helper.load("Elmira/Core/Announce.lua")
      local fresh = helper.load("Elmira/Display/Announcers.lua")
      assert.is_false(fresh.screen(cat("rotation"), row("moved")))
    end)
  end)

  describe("the chat sink", function()
    it("prints into the window that shows System messages", function()
      assert.is_true(Announcers.chat(cat("warning"), row("careful")))
      assert.equal(1, #chat.default.messages)
      assert.equal(0, #chat.two.messages)
    end)

    it("says nothing on a client with no chat frame at all", function()
      _G.DEFAULT_CHAT_FRAME = nil
      _G.ChatFrame1 = nil
      assert.is_false(Announcers.chat(cat("warning"), row("careful")))
    end)

    -- D25: no stored index any more -- Elmira asks every tab whether it shows System messages, so
    -- a tab the player configured that way gets the line even if it is not the default one.
    it("prints into every tab that shows System messages, not only the default", function()
      local chatGroups = { [chat.default] = { SYSTEM = true }, [chat.two] = { SYSTEM = true } }
      _G.ChatFrame_ContainsMessageGroup = function(f, g) return chatGroups[f] and chatGroups[f][g] end
      Announcers.chat(cat("warning"), row("careful"))
      assert.equal(1, #chat.default.messages)
      assert.equal(1, #chat.two.messages)
    end)

    it("falls back to the default frame when nothing shows System messages", function()
      _G.ChatFrame_ContainsMessageGroup = function() return nil end
      Announcers.chat(cat("warning"), row("careful"))
      assert.equal(1, #chat.default.messages)
    end)

    -- D25 (corrected): nothing on the live Classic Era install actually calls the global helper
    -- (grepped every installed addon, zero hits) -- so it is one of THREE tiers, not the only one,
    -- and each has to be provable on its own with the OTHER two absent.
    describe("the three capability tiers, each on its own", function()
      before_each(function()
        -- Every tier below starts from "none of the three can answer" and adds back exactly one.
        _G.ChatFrame_ContainsMessageGroup = nil
      end)

      it("tier A: the frame's OWN ContainsMessageGroup method, when the global does not exist", function()
        function chat.default:ContainsMessageGroup(group) return group == "SYSTEM" end
        function chat.two:ContainsMessageGroup(group) return group == "PARTY" end
        Announcers.chat(cat("warning"), row("careful"))
        assert.equal(1, #chat.default.messages)
        assert.equal(0, #chat.two.messages)
      end)

      it("tier B: the global ChatFrame_ContainsMessageGroup, when no frame has its own method", function()
        local chatGroups = { [chat.default] = { SYSTEM = true }, [chat.two] = {} }
        _G.ChatFrame_ContainsMessageGroup = function(f, g) return chatGroups[f] and chatGroups[f][g] end
        Announcers.chat(cat("warning"), row("careful"))
        assert.equal(1, #chat.default.messages)
        assert.equal(0, #chat.two.messages)
      end)

      -- The ground truth the other two wrap (Details reads it directly): a plain Lua list, so the
      -- compare has to be case-insensitive rather than assuming Blizzard's own casing.
      -- Deliberately the NON-default frame matches here: DEFAULT_CHAT_FRAME is chat.default (see
      -- the top-level before_each), so a broken tier C that never matches anything would still put
      -- the line in chat.default via the fallback -- this shape is the only one that tells "tier C
      -- matched" apart from "tier C found nothing and the fallback fired".
      it("tier C: chatFrame.messageTypeList, when neither method nor global exists", function()
        chat.two.messageTypeList = { "SAY", "system" }     -- lowercase: the compare is case-insensitive
        Announcers.chat(cat("warning"), row("careful"))
        assert.equal(0, #chat.default.messages)
        assert.equal(1, #chat.two.messages)
      end)

      it("falls back to the default frame when none of the three tiers can answer for anything", function()
        Announcers.chat(cat("warning"), row("careful"))
        assert.equal(1, #chat.default.messages)
      end)

      it("prefers the frame's own method over the global when both exist", function()
        function chat.default:ContainsMessageGroup() return false end   -- method says no...
        _G.ChatFrame_ContainsMessageGroup = function() return true end  -- ...global would say yes
        Announcers.chat(cat("warning"), row("careful"))
        assert.equal(0, #chat.default.messages)
      end)
    end)

    it("prefixes with the brand and colours by category", function()
      Announcers.chat(cat("warning"), row("careful"))
      local text = chat.default.messages[1].text
      assert.is_truthy(text:find("Elmira"))
      assert.is_truthy(text:find(ns.Colors.WARN.hex))
      assert.is_truthy(text:find("careful"))
      -- "Elmira: careful", like every other line the addon prints. Without the colon it read as
      -- "Elmira careful", which is a different sentence.
      assert.is_truthy(text:find("|r: ") or text:find("Elmira: "))
    end)

    it("lists every chat window that shows System messages", function()
      local windows = Announcers.systemChatFrames()
      assert.equal(1, #windows)
      assert.equal(chat.default, windows[1])
    end)
  end)

  describe("the sound sink", function()
    it("stays quiet while set to None, without even asking the media library", function()
      local asked = 0
      _G.LibStub = function()
        return { List = function() return {} end,
                 Fetch = function() asked = asked + 1; return "some/path.ogg" end }
      end
      assert.is_false(Announcers.sound())
      assert.equal(0, #played)
      assert.equal(0, asked)   -- "None" is not a sound to look up, it is the absence of one
    end)

    it("plays the chosen sound", function()
      ns.db.profile.announce.sound = "Elmira chime"
      assert.is_true(Announcers.sound())
      assert.same({ "Interface\\AddOns\\Media\\chime.ogg" }, played)
    end)

    it("stays quiet for a sound the media library cannot find", function()
      ns.db.profile.announce.sound = "A sound nobody has"
      assert.is_false(Announcers.sound())
      assert.equal(0, #played)
    end)

    -- D24: a category with its own sound overrides the shared one; a category that has never
    -- touched the per-kind select still falls back to it.
    it("plays a category's own sound when one is set", function()
      ns.db.profile.announce.sound = "None"
      ns.db.profile.announce.sounds.warning = "Elmira chime"
      assert.is_true(Announcers.sound(cat("warning")))
      assert.same({ "Interface\\AddOns\\Media\\chime.ogg" }, played)
    end)

    it("falls back to the shared sound for a category with no override", function()
      ns.db.profile.announce.sound = "Elmira chime"
      assert.is_true(Announcers.sound(cat("status")))
      assert.same({ "Interface\\AddOns\\Media\\chime.ogg" }, played)
    end)

    it("lists the fonts the player's media packs provide", function()
      local fonts = Announcers.fonts()
      assert.equal("Friz Quadrata TT", fonts["Friz Quadrata TT"])
      assert.equal("Expressway", fonts.Expressway)
    end)

    it("offers None alongside whatever packs the player has", function()
      local sounds = Announcers.sounds()
      assert.equal("None", sounds.None)
      assert.equal("Elmira chime", sounds["Elmira chime"])
    end)

    it("still offers a font and a sound with no media library at all", function()
      _G.LibStub = function() return nil end
      assert.is_not_nil(Announcers.fonts()["Friz Quadrata TT"])
      assert.is_not_nil(Announcers.sounds().None)
    end)
  end)

  -- The only channel other people see. D22 split one "party" flag into two (party/raid); this
  -- sink re-reads the CURRENT routing itself, since it is the only place group membership can be
  -- read (Core/Announce's dispatch only knows "at least one of the two is on").
  describe("the party sink", function()
    it("refuses a category that is not shareable, whatever the routing says", function()
      ns.db.profile.announce.routes.rotation = { party = true, raid = true }
      ns.db.profile.announce.routes.warning = { party = true, raid = true }
      assert.is_false(Announcers.party(cat("rotation"), row("Divine Storm is now active")))
      assert.is_false(Announcers.party(cat("warning"), row("careful")))
      assert.equal(0, #sent)
    end)

    it("says nothing on a client with no way to send", function()
      ns.db.profile.announce.routes.cooldown = { party = true }
      _G.SendChatMessage = nil
      assert.is_false(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
    end)

    it("sends to the party when routed there and in one", function()
      ns.db.profile.announce.routes.cooldown = { party = true }
      assert.is_true(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
      assert.same({ text = "Avenging Wrath", channel = "PARTY" }, sent[1])
    end)

    it("does not fire to the party when only raid is switched on", function()
      ns.db.profile.announce.routes.cooldown = { raid = true }
      assert.is_false(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
      assert.equal(0, #sent)
    end)

    it("sends to the raid when routed there and in one", function()
      ns.db.profile.announce.routes.cooldown = { raid = true }
      _G.IsInRaid = function() return true end
      assert.is_true(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
      assert.equal("RAID", sent[1].channel)
    end)

    -- The flag that matters is the one matching the group the player is ACTUALLY in: being in a
    -- raid with only `party` switched on must not leak into raid chat.
    it("does not fire to the raid when only party is switched on, while in a raid", function()
      ns.db.profile.announce.routes.cooldown = { party = true }
      _G.IsInRaid = function() return true end
      assert.is_false(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
      assert.equal(0, #sent)
    end)

    -- SendChatMessage to PARTY while solo is an error in the client, not a no-op.
    it("says nothing at all while solo", function()
      ns.db.profile.announce.routes.cooldown = { party = true }
      _G.IsInGroup = function() return false end
      assert.is_false(Announcers.party(cat("cooldown"), row("Avenging Wrath")))
      assert.equal(0, #sent)
    end)

    it("strips our colours and icons, which other people cannot render", function()
      ns.db.profile.announce.routes.cooldown = { party = true }
      Announcers.party(cat("cooldown"),
        row("|TInterface\\Icons\\X:0|t |cffFFD37AAvenging Wrath|r"))
      assert.equal("Avenging Wrath", sent[1].text)
    end)
  end)

  -- A 600x120 mouse-enabled frame across the middle of the screen must not outlive the panel that
  -- turned it on -- and must certainly not still be there in a fight.
  describe("leaving move mode", function()
    it("stops when asked, and says whether there was anything to stop", function()
      Announcers.Create()
      assert.is_false(Announcers.StopMoving())
      Announcers.SetMoving(true)
      assert.is_true(Announcers.StopMoving())
      assert.is_false(Announcers.isMoving())
      assert.is_false(Announcers.frame().mouse)
      assert.equal(0, #Announcers.frame().messages)
    end)

    -- Every MessageFrame method below is a first use at interface 11509 -- Clear is not even on the
    -- M5g checklist's list of unverified ones. Some are reached from the options panel closing, so
    -- a method that turns out not to exist would throw from inside a frame's OnHide. Each has to
    -- degrade to "that touch did nothing" instead.
    --
    -- Parameterised over the whole list on purpose: a spec that blinds only Clear leaves the other
    -- eight call sites unprotected, and reverting any one of them to a direct `frame:Method(...)`
    -- would break no test -- a covered function with an uncovered call site, which is this
    -- project's recurring defect.
    local GUARDED = { "SetInsertMode", "SetJustifyH", "SetFading", "SetFadeDuration",
                      "SetTimeVisible", "AddMessage", "Clear", "SetFont" }

    -- Not `f.Method = nil`: fakeFrame's metatable answers every capitalised key with a no-op, which
    -- would hide exactly the failure these tests are about.
    local function blindTo(method)
      return function(kind, name)
        local f = fakeFrame(kind, name)
        frames[#frames + 1] = f
        return setmetatable({}, { __index = function(_, k)
          if k == method then return nil end
          local v = f[k]
          if type(v) == "function" then return function(_, ...) return v(f, ...) end end
          return v
        end })
      end
    end

    for _, method in ipairs(GUARDED) do
      it("survives a client whose MessageFrame has no " .. method .. "()", function()
        _G.CreateFrame = blindTo(method)
        local logged = {}
        ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
        local fresh = helper.load("Elmira/Display/Announcers.lua")

        -- Every path that touches the frame: create, font, move in, move out, and a real message.
        fresh.Create()
        fresh.ApplyFont()
        -- Twice round, because a missing method is hit once per exit: the report has to be
        -- suppressed on the second, not merely happen to be single on the first.
        for _ = 1, 2 do
          fresh.SetMoving(true)
          assert.is_true(fresh.StopMoving())
          assert.is_false(fresh.isMoving())
        end
        fresh.screen(cat("status"), row("still speaking"))

        -- Said once, and it names the method, because "on-screen messages degrade" with no name is
        -- a report nobody can act on.
        local about = {}
        for _, line in ipairs(logged) do
          if line:find(method .. "()", 1, true) then about[#about + 1] = line end
        end
        assert.equal(1, #about,
          method .. " was reported " .. #about .. " times, wanted exactly once")
      end)
    end
  end)

  describe("registration", function()
    it("reports that it registered", function()
      assert.is_true(Announcers.Register())
    end)

    it("registers all four sinks under the names Core/Announce routes to", function()
      Announcers.Create()
      Announcers.Register()
      ns.db.profile.announce.routes.cooldown =
        { chat = true, screen = true, sound = true, party = true }
      ns.db.profile.announce.sound = "Elmira chime"
      ns.Announce.emit("cooldown", "Avenging Wrath")
      assert.equal(1, #Announcers.frame().messages)
      assert.equal(1, #chat.default.messages)
      assert.equal(1, #played)
      assert.equal(1, #sent)
    end)

    it("routes a rotation change everywhere except the party", function()
      Announcers.Create()
      Announcers.Register()
      ns.Announce.emit("rotation", "Divine Storm is now active")
      assert.equal(1, #Announcers.frame().messages)
      assert.equal(1, #chat.default.messages)
      assert.equal(0, #sent)
    end)
  end)
end)
