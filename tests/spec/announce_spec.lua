local helper = require("tests.helper")

-- Elmira/Core/Announce.lua — everything Elmira says, and where it goes (PRD F37).
--
-- Before this every message went to the default chat frame through `ns.log`, so the only choices
-- were "all of it, in your main window" and "edit the addon". The rules the owner set are all
-- testable and all of them are here: the Log cannot be switched off, a category's shareability is
-- decided in code rather than by a checkbox, and an on-screen message waits for the fight to end.
describe("Core.Announce", function()
  local A, ns

  local function db()
    return { profile = { announce = { routes = {} } }, global = { announceLog = {}, announceDropped = 0 } }
  end

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    A = helper.load("Elmira/Core/Announce.lua")
    ns.db = db()
    A.use{ now = function() return 100 end, inCombat = function() return false end }
  end)

  -- Each row is a design decision, so each row is asserted rather than counted.
  describe("the kinds of thing it says", function()
    it("names six categories in the order the panel lists them", function()
      local keys = {}
      for _, c in ipairs(A.CATEGORIES) do keys[#keys + 1] = c.key end
      assert.same({ "rotation", "template", "mode", "warning", "status", "cooldown" }, keys)
    end)

    it("gives each one its own colour and label", function()
      assert.equal("HIGHLIGHT", A.category("rotation").color)
      assert.equal("Rotation changed", A.category("rotation").label)
      assert.equal("BRAND", A.category("template").color)
      assert.equal("BRAND", A.category("mode").color)
      assert.equal("WARN", A.category("warning").color)
      assert.equal("MUTED", A.category("status").color)
      assert.equal("OK", A.category("cooldown").color)
    end)

    -- The rule the owner set: a message about YOUR rotation is not something a group should see.
    -- It is a property of the category in code, not a checkbox a user can widen.
    it("lets only cooldowns ever leave the client", function()
      for _, c in ipairs(A.CATEGORIES) do
        if c.key == "cooldown" then
          assert.is_true(c.shareable)
        else
          assert.is_false(c.shareable, c.key .. " must never reach party chat")
        end
      end
    end)

    it("has no category for anything it cannot name", function()
      assert.is_nil(A.category("nonsense"))
    end)
  end)

  describe("the routing it ships with", function()
    it("interrupts for a rotation change and nothing else", function()
      assert.same({ chat = true, screen = true, sound = false, party = false },
                  A.DEFAULT_ROUTES.rotation)
    end)

    it("puts warnings, templates and status in chat, and a mode change on screen", function()
      assert.same({ chat = true, screen = false, sound = false, party = false },
                  A.DEFAULT_ROUTES.warning)
      assert.same({ chat = true, screen = false, sound = false, party = false },
                  A.DEFAULT_ROUTES.template)
      assert.same({ chat = false, screen = true, sound = false, party = false },
                  A.DEFAULT_ROUTES.mode)
      assert.same({ chat = true, screen = false, sound = false, party = false },
                  A.DEFAULT_ROUTES.status)
    end)

    -- The defect this spec was missing: `status` shipped routed to nothing, so the first-login
    -- line and the learning-mode confirmation were silent, with every test green. A message the
    -- player cannot hear is not an announcement.
    it("gives every kind the player is meant to hear at least one channel out loud", function()
      local heard = {}
      A.registerSink("chat", function(cat) heard[cat.key] = true end)
      A.registerSink("screen", function(cat) heard[cat.key] = true end)
      A.registerSink("sound", function(cat) heard[cat.key] = true end)
      for _, c in ipairs(A.CATEGORIES) do A.emit(c.key, "a " .. c.key .. " message") end
      for _, c in ipairs(A.CATEGORIES) do
        if c.key == "cooldown" then
          -- Nothing emits one yet (M5a), and it is the shareable one: it starts quiet on purpose.
          assert.is_nil(heard[c.key])
        else
          assert.is_true(heard[c.key], c.key .. " is announced to nobody")
        end
      end
    end)

    -- Handing out the shipped table lets one caller write a channel into it and change that
    -- default for every category and every profile at once, with nothing on screen to say so.
    it("hands back a copy of the shipped routing, not the shipped table", function()
      local got = A.routes("rotation")
      got.chat = false
      assert.is_true(A.DEFAULT_ROUTES.rotation.chat)
      assert.is_true(A.routes("rotation").chat)
    end)

    -- The same hazard on the other side: `noShare` wrote into what routes() handed it and turned
    -- a user's party routing off for the rest of the session.
    it("hands back a copy of the user's routing too", function()
      ns.db.profile.announce.routes.cooldown = { chat = true, party = true }
      local got = A.routes("cooldown")
      got.party = false
      assert.is_true(ns.db.profile.announce.routes.cooldown.party)
    end)

    it("ships every category silent in party, shareable or not", function()
      for _, c in ipairs(A.CATEGORIES) do
        assert.is_false(A.DEFAULT_ROUTES[c.key].party, c.key .. " ships routed to party")
      end
    end)

    -- A fresh profile has no stored routes. Reading that as "everything off" would ship an addon
    -- that says nothing at all.
    it("falls back to the shipped routing when the profile has none", function()
      assert.is_true(A.routes("rotation").chat)
    end)

    it("prefers the user's routing once there is some", function()
      ns.db.profile.announce.routes.rotation = { chat = false, screen = false }
      assert.is_false(A.routes("rotation").chat)
    end)
  end)

  describe("the log", function()
    it("counts what it dropped, so the panel can say so", function()
      assert.equal(0, A.dropped())
      for i = 1, A.MAX_LOG + 2 do A.emit("status", "line " .. i) end
      assert.equal(2, A.dropped())
    end)

    it("records what was said, with its category and time", function()
      A.emit("status", "hello")
      local rows = A.log()
      assert.equal(1, #rows)
      assert.equal("hello", rows[1].text)
      assert.equal("status", rows[1].category)
      assert.equal(100, rows[1].at)
    end)

    it("reads newest first, because that is the order anyone reads a log in", function()
      A.emit("status", "first")
      A.emit("status", "second")
      local rows = A.log()
      assert.equal("second", rows[1].text)
      assert.equal("first", rows[2].text)
    end)

    it("returns only as many as asked for", function()
      for i = 1, 5 do A.emit("status", "line " .. i) end
      assert.equal(2, #A.log(2))
      assert.equal("line 5", A.log(2)[1].text)
    end)

    it("drops the oldest past its cap and counts what it dropped", function()
      for i = 1, A.MAX_LOG + 3 do A.emit("status", "line " .. i) end
      assert.equal(A.MAX_LOG, #ns.db.global.announceLog)
      assert.equal(3, ns.db.global.announceDropped)
      assert.equal("line 4", ns.db.global.announceLog[1].text)
    end)

    it("caps at 200, which is more than anyone reads and small on disk", function()
      assert.equal(200, A.MAX_LOG)
    end)

    it("empties on request", function()
      A.emit("status", "x")
      assert.is_true(A.clear())
      assert.equal(0, #A.log())
      assert.equal(0, ns.db.global.announceDropped)
    end)

    -- The Log is the record. Routing decides how loudly something announces itself on the way in,
    -- never whether it is kept.
    it("records even a category routed nowhere at all", function()
      ns.db.profile.announce.routes.status = { chat = false, screen = false, sound = false, party = false }
      A.emit("status", "quiet")
      assert.equal(1, #A.log())
    end)
  end)

  describe("dispatch", function()
    local seen

    before_each(function()
      seen = {}
      A.registerSink("chat", function(cat, row) seen[#seen + 1] = { "chat", cat.key, row.text } end)
      A.registerSink("screen", function(cat, row) seen[#seen + 1] = { "screen", cat.key, row.text } end)
      A.registerSink("sound", function() seen[#seen + 1] = { "sound" } end)
      A.registerSink("party", function() seen[#seen + 1] = { "party" } end)
    end)

    -- Fixed order, not pairs(): two runs of one announcement should look the same, and party --
    -- the only channel other people see -- goes last, after anything that might error.
    it("speaks in a fixed order, party last", function()
      assert.same({ "chat", "screen", "sound", "party" }, A.CHANNELS)
      ns.db.profile.announce.routes.cooldown =
        { chat = true, screen = true, sound = true, party = true }
      A.emit("cooldown", "Avenging Wrath")
      local names = {}
      for _, row in ipairs(seen) do names[#names + 1] = row[1] end
      assert.same({ "chat", "screen", "sound", "party" }, names)
    end)

    it("reaches exactly the channels the category is routed to", function()
      A.emit("rotation", "moved")
      local names = {}
      for _, row in ipairs(seen) do names[row[1]] = true end
      assert.is_true(names.chat)
      assert.is_true(names.screen)
      assert.is_nil(names.sound)
      assert.is_nil(names.party)
    end)

    it("hands the sink the category and the logged row", function()
      A.emit("warning", "careful")
      assert.same({ "chat", "warning", "careful" }, seen[1])
    end)

    it("obeys a user who has switched a channel off", function()
      ns.db.profile.announce.routes.warning = { chat = false, screen = true }
      A.emit("warning", "careful")
      assert.equal("screen", seen[1][1])
      assert.equal(1, #seen)
    end)

    -- One broken sink must not silence the rest, and none of them can un-log what was already said.
    it("keeps going when a sink errors", function()
      A.registerSink("chat", function() error("chat frame is gone") end)
      A.emit("rotation", "moved")
      assert.equal(1, #seen)
      assert.equal("screen", seen[1][1])
      assert.equal(1, #A.log())
    end)

    it("refuses a sink that is not a function", function()
      assert.is_false(A.registerSink("chat", "nope"))
      assert.is_false(A.registerSink(nil, function() end))
    end)
  end)

  describe("waiting for the fight to end", function()
    local seen

    before_each(function()
      seen = {}
      A.registerSink("chat", function() seen[#seen + 1] = "chat" end)
      A.registerSink("screen", function() seen[#seen + 1] = "screen" end)
      A.use{ now = function() return 1 end, inCombat = function() return true end }
    end)

    -- A toast at the moment a set bonus turns on is reading material dropped in front of someone
    -- mid-pull. The Log and chat have it already.
    it("holds the on-screen message but still says the rest", function()
      A.emit("rotation", "moved")
      assert.same({ "chat" }, seen)
      assert.equal(1, A.pending())
      assert.equal(1, #A.log())
    end)

    it("delivers it when combat drops", function()
      A.emit("rotation", "moved")
      assert.equal(1, A.flush())
      assert.same({ "chat", "screen" }, seen)
      assert.equal(0, A.pending())
    end)

    it("delivers held messages in the order they were said", function()
      local texts = {}
      A.registerSink("screen", function(_, row) texts[#texts + 1] = row.text end)
      A.emit("rotation", "first")
      A.emit("rotation", "second")
      A.flush()
      assert.same({ "first", "second" }, texts)
    end)

    it("holds nothing when the message was not going to the screen anyway", function()
      A.emit("warning", "careful")
      assert.equal(0, A.pending())
    end)

    -- A fight producing fifty toasts is already telling the player something is wrong; dumping all
    -- fifty the moment they stop fighting is not the way to say it. The Log keeps them all.
    it("holds only the newest few, however long the fight goes on", function()
      local texts = {}
      A.registerSink("screen", function(_, r) texts[#texts + 1] = r.text end)
      for i = 1, A.MAX_DEFERRED + 3 do A.emit("rotation", "line " .. i) end
      assert.equal(A.MAX_DEFERRED, A.pending())
      A.flush()
      assert.equal(A.MAX_DEFERRED, #texts)
      assert.equal("line 4", texts[1])                       -- oldest dropped, newest kept
      assert.equal("line " .. (A.MAX_DEFERRED + 3), texts[#texts])
      assert.equal(A.MAX_DEFERRED + 3, #A.log())             -- and the Log has every one of them
    end)

    it("caps the held messages at twenty", function()
      assert.equal(20, A.MAX_DEFERRED)
    end)

    it("flushes to nothing when nothing was held", function()
      assert.equal(0, A.flush())
    end)

    it("does not hold anything out of combat", function()
      A.use{ now = function() return 1 end, inCombat = function() return false end }
      A.emit("rotation", "moved")
      assert.same({ "chat", "screen" }, seen)
      assert.equal(0, A.pending())
    end)
  end)

  -- The one channel other people see. A control for previewing your OWN settings must never put a
  -- line in a group's chat, whatever the routing happens to say.
  describe("noShare", function()
    it("keeps a message out of party even when the user routed it there", function()
      local partied = 0
      A.registerSink("party", function() partied = partied + 1 end)
      A.registerSink("chat", function() end)
      ns.db.profile.announce.routes.cooldown = { chat = true, party = true }
      A.emit("cooldown", "Avenging Wrath", { noShare = true })
      assert.equal(0, partied)
      A.emit("cooldown", "Avenging Wrath")
      assert.equal(1, partied)
    end)

    it("is what the test button uses", function()
      local partied = 0
      A.registerSink("party", function() partied = partied + 1 end)
      ns.db.profile.announce.routes.cooldown = { party = true }
      A.test()
      assert.equal(0, partied)
    end)
  end)

  describe("what it refuses", function()
    it("says nothing for a category it does not have", function()
      assert.is_nil(A.emit("nonsense", "x"))
      assert.equal(0, #A.log())
    end)

    it("says nothing for an empty message", function()
      assert.is_nil(A.emit("status", ""))
      assert.is_nil(A.emit("status", nil))
    end)

    -- Load failures happen exactly when there is no database yet. Swallowing them would silence
    -- the messages most worth hearing.
    it("falls back to plain printing before the database exists", function()
      local printed = {}
      ns.db = nil
      ns.log = function(fmt, ...) printed[#printed + 1] = string.format(fmt, ...) end
      assert.is_nil(A.emit("warning", "the pack did not load"))
      assert.same({ "the pack did not load" }, printed)
    end)

    it("refuses a clock that is not one, and accepts one that is", function()
      assert.is_false(A.use(nil))
      assert.is_false(A.use({ now = "not a function" }))
      assert.is_true(A.use({ now = function() return 5 end }))
      A.emit("status", "stamped")
      assert.equal(5, A.log()[1].at)
    end)

    it("stops stamping from a clock it rejected", function()
      A.use(nil)
      A.emit("status", "unstamped")
      assert.equal(0, A.log()[1].at)
    end)

    it("says nothing to any sink before the database exists", function()
      local heard = 0
      A.registerSink("chat", function() heard = heard + 1 end)
      ns.db = nil
      A.emit("warning", "the pack did not load")
      assert.equal(0, heard)
    end)

    it("starts a log in a database that has never had one", function()
      ns.db.global = {}
      A.emit("status", "first ever")
      assert.equal(1, #ns.db.global.announceLog)
    end)

    it("cannot clear a log that is not there", function()
      ns.db = nil
      assert.is_false(A.clear())
    end)

    it("accepts a sink it can call", function()
      assert.is_true(A.registerSink("chat", function() end))
    end)
  end)

  describe("plain text for other people's screens", function()
    it("strips our colours and icons", function()
      assert.equal("Divine Storm is active",
                   A.plain("|TInterface\\Icons\\x:0|t |cffFFD37ADivine Storm is active|r"))
    end)

    it("leaves a plain sentence alone", function()
      assert.equal("nothing to strip", A.plain("nothing to strip"))
    end)

    it("answers empty for anything that is not a string", function()
      assert.equal("", A.plain(nil))
      assert.equal("", A.plain(42))
    end)
  end)

  describe("the test button", function()
    it("sends one of every kind", function()
      assert.equal(#A.CATEGORIES, A.test())
      assert.equal(#A.CATEGORIES, #A.log())
    end)

    -- The point of pressing it is to see the result now, not after the next fight.
    it("does not hold its samples back in combat", function()
      local screens = 0
      A.registerSink("screen", function() screens = screens + 1 end)
      A.use{ now = function() return 1 end, inCombat = function() return true end }
      A.test()
      assert.equal(0, A.pending())
      assert.is_true(screens > 0)
    end)

    it("leaves the real clock in place afterwards", function()
      A.use{ now = function() return 7 end, inCombat = function() return true end }
      A.test()
      A.emit("rotation", "after")
      assert.equal(1, A.pending())      -- still deferring, so the combat question survived
    end)
  end)

  it("forgets its sinks and its queue on reset", function()
    local seen = 0
    A.registerSink("chat", function() seen = seen + 1 end)
    A.reset()
    A.emit("warning", "x")
    assert.equal(0, seen)
  end)
end)
