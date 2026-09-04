local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- Elmira/Core/Init.lua — composition root: AceAddon lifecycle, the profile DB, StartDisplay()
-- (renderer registration), the data-pack attach, the minimap button.
--
-- This is the one file under Elmira/ allowed to touch LibStub, so it is the one Core spec allowed to
-- load an ADAPTER-grade environment (tests/wow_mock.lua) AND the real vendored Ace3 libraries
-- (Elmira/Libs/) rather than fake them. Faking AceAddon/AceEvent/AceConsole/AceTimer ourselves would
-- mean asserting our own guess about their semantics; the real libraries are already vendored, pure
-- Lua once CreateFrame/geterrorhandler/etc. are mocked, and this is exactly the file the lint config
-- carves out the LibStub exception for.
--
-- What is NOT exercised here: AceAddon-3.0's own ADDON_LOADED/PLAYER_LOGIN queueing
-- (AceAddon:InitializeAddon/EnableAddon). That path's `safecall` does `xpcall(func, errorhandler,
-- ...)`, relying on the WoW client's non-standard xpcall that forwards extra arguments to `func` --
-- a Blizzard Lua extension, not present in stock Lua 5.1 (confirmed empirically: under plain lua5.1,
-- `self` arrives as nil and OnInitialize aborts on its first line). The client always calls
-- OnInitialize/OnEnable with `self` bound correctly; this spec reproduces that by calling
-- `NA:OnInitialize()` / `NA:OnEnable()` directly, which is a normal Lua method call and exercises
-- 100% of Init.lua's own code -- it just bypasses Ace3's own (already-tested-upstream) dispatch
-- machinery, which is not Elmira's code and not this project's risk.
describe("Core.Init", function()
  local ACE_LIBS = {
    "Elmira/Libs/LibStub/LibStub.lua",
    "Elmira/Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "Elmira/Libs/AceEvent-3.0/AceEvent-3.0.lua",
    "Elmira/Libs/AceConsole-3.0/AceConsole-3.0.lua",
    "Elmira/Libs/AceTimer-3.0/AceTimer-3.0.lua",
    "Elmira/Libs/AceDB-3.0/AceDB-3.0.lua",
    "Elmira/Libs/AceAddon-3.0/AceAddon-3.0.lua",
  }

  -- Fresh LibStub (and therefore fresh AceAddon/AceEvent/... registries) every test: LibStub:New
  -- Library refuses to hand back a second copy of the same major/minor, so without this the SECOND
  -- test in this file would see `AceAddon.addons.Elmira` already occupied by the FIRST test's addon
  -- object and NewAddon() would error.
  local function loadRealAce3()
    _G.LibStub = nil
    for _, path in ipairs(ACE_LIBS) do
      -- Elmira/Libs/ is gitignored and supplied by the packager, so a fresh checkout does not have
      -- it. Say that outright: "cannot open .../LibStub.lua" sends the reader hunting a missing file
      -- rather than running the one command that creates it.
      local chunk, err = loadfile(path)
      assert(chunk, "Core/Init.lua runs on the real Ace3, which lives in the gitignored Elmira/Libs/."
                 .. " Run `make libs` once to populate it. (" .. tostring(err) .. ")")
      chunk()
    end
  end

  -- Minimal stand-ins for LibDataBroker-1.1 / LibDBIcon-1.0, registered through the REAL LibStub
  -- (not a fake LibStub function, unlike swing_spec/glow_spec's third-party-library pattern) --
  -- SetupMinimapButton's contract with these two is exactly `NewDataObject(name, obj)` and
  -- `Register(name, obj, db)`, so a narrow fake exposing only those two calls, with the results
  -- introspectable, tests the wiring without needing a real Minimap frame.
  local function installMinimapLibs()
    local ldb = LibStub:NewLibrary("LibDataBroker-1.1", 1)
    ldb.objects = {}
    function ldb:NewDataObject(name, obj) self.objects[name] = obj; return obj end

    local dbicon = LibStub:NewLibrary("LibDBIcon-1.0", 1)
    dbicon.registered = {}
    function dbicon:Register(name, obj, db)
      table.insert(self.registered, { name = name, obj = obj, db = db })
    end
    return ldb, dbicon
  end

  local ns, NA, logged, order

  -- `order` is a single shared list several fakes below push onto, so a test can assert RELATIVE
  -- ordering (e.g. "attachPack before the queue renderer is registered") without caring about the
  -- absolute call count of anything else.
  local function fakeAdapter()
    return {
      playerClass = function() return "PALADIN" end,
      loadClassPack = function(class) order[#order + 1] = "loadClassPack:" .. tostring(class) end,
      attachPack = function(pack) order[#order + 1] = "attachPack" end,
    }
  end

  local function fakeDisplay()
    return {
      register = function(name) order[#order + 1] = "register:" .. name end,
      Enable = function() order[#order + 1] = "Display.Enable" end,
      invalidate = function() order[#order + 1] = "Display.invalidate" end,
      refresh = function() order[#order + 1] = "Display.refresh" end,
    }
  end

  local function fakeQueue()
    return {
      Create = function() order[#order + 1] = "Queue.Create" end,
      SetLocked = function(v) order[#order + 1] = "Queue.SetLocked:" .. tostring(v) end,
      isLocked = function() return false end,
      Render = function() end,
    }
  end

  local function fakeOverlay()
    return {
      Create = function() order[#order + 1] = "Overlay.Create" end,
      Render = function() end,
    }
  end

  -- Loads the real file under test. Every dependency it reaches into is either the real, pure
  -- Core module (Colors, API, DB — all dofile-able per docs/04) or one of the fakes above; only
  -- ns.Adapter/ns.Display/ns.Queue/ns.Overlay/ns.Options/ns.Wizard/ns.BarGlow are ever faked, and
  -- only because their OWN wiring is covered elsewhere (adapter_vanilla_spec, queue_spec,
  -- overlay_spec, options_spec, wizard_spec, barglow_spec) — this file's job is only to prove
  -- Init.lua calls them correctly, not to re-prove they work.
  local function loadInit()
    mock.reset()
    ns = helper.reset()
    order, logged = {}, {}
    -- AceDB:New("ElmiraDB", ...) reuses `_G.ElmiraDB` if one already exists (that persistence
    -- across a real login IS the point of a SavedVariable) -- so without clearing it, the SECOND
    -- test in this file inherits whatever the FIRST wrote into its db.global/db.profile.
    _G.ElmiraDB = nil

    loadRealAce3()
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/API.lua")
    helper.load("Elmira/Core/DB.lua")

    ns.Adapter = fakeAdapter()
    ns.Display = fakeDisplay()
    ns.Queue = fakeQueue()
    ns.Overlay = fakeOverlay()
    ns.BarGlow = { Invalidate = function() order[#order + 1] = "BarGlow.Invalidate" end }
    ns.Options = { Register = function() order[#order + 1] = "Options.Register" end,
                   Open = function() order[#order + 1] = "Options.Open" end }
    ns.Wizard = { OfferOnLogin = function() order[#order + 1] = "Wizard.OfferOnLogin" end }
    ns.Slash = { run = function() return {} end }

    -- Init.lua is the entry point, not a `return Module` file (tests/README.md's pattern is for
    -- loadable modules); it publishes itself as `ns.addon` instead.
    helper.load("Elmira/Core/Init.lua")
    NA = ns.addon
    -- Init.lua's own `ns.log = function(...) NA:Printf(...) end` (set at file scope, above) is
    -- replaced AFTER load, same idiom as driver_spec.lua: nothing else in Init.lua reassigns
    -- ns.log, so every later call reads this closure, not the real chat-frame path.
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
  end

  before_each(loadInit)
  after_each(function() _G.LibStub = nil end)

  -- Core/Serialize.lua never names LibStub; Init hands it the two libraries at OnInitialize. Both
  -- are OptionalDeps, so the silent lookup must leave the codec merely unavailable when absent.
  describe("import/export codec wiring", function()
    local function loadCodecLibs()
      for _, path in ipairs({ "Elmira/Libs/LibSerialize/LibSerialize.lua", "Elmira/Libs/LibDeflate/LibDeflate.lua" }) do
        local chunk = assert(loadfile(path), path .. " — run `make libs`"); chunk()
      end
    end

    it("hands LibSerialize and LibDeflate to Core/Serialize at OnInitialize", function()
      helper.load("Elmira/Core/Serialize.lua")
      loadCodecLibs()
      NA:OnInitialize()
      assert.is_true(ns.Serialize.available())
    end)

    it("leaves the codec unavailable, without erroring, when the libraries did not ship", function()
      helper.load("Elmira/Core/Serialize.lua")
      NA:OnInitialize()
      assert.is_false(ns.Serialize.available())
    end)
  end)

  -- The fork store is created by ONE thing at runtime: `userBuilds = {}` in DB.defaults. Every
  -- other UserBuilds spec hand-builds `ns.db = { global = { userBuilds = {} } }`, so none of them
  -- can see that key go missing -- `store()` would return nil, and `/elm import`, `/elm profile
  -- USER_...` and the Options box would all answer "saved variables are not loaded" in game while
  -- the suite stayed green. This is the only spec that reaches the store through the real AceDB.
  describe("the fork store (ADR-0010)", function()
    it("exists on the AceDB-backed db, and a fork written into it is found again", function()
      helper.load("Elmira/Core/UserBuilds.lua")
      NA:OnInitialize()

      assert.is_table(ns.db.global.userBuilds)

      local pack = { class = "PALADIN", builds = {} }
      ns.db.global.userBuilds["USER_PROBE"] = {
        class = "PALADIN", name = "Probe", build = { name = "Probe", entries = {} },
      }
      local build, origin = ns.UserBuilds.find(pack, "USER_PROBE")
      assert.is_table(build)
      assert.equal("fork", origin)
      assert.same({ "USER_PROBE" }, ns.UserBuilds.list(pack))
    end)
  end)

  describe("composition (file scope)", function()
    it("publishes the addon object and Elmira.API as the Elmira global", function()
      assert.equal(NA, _G.Elmira)
      assert.equal(ns.API, _G.Elmira.API)
    end)
  end)

  describe("OnInitialize", function()
    it("builds the AceDB profile and hands it to ns.db", function()
      NA:OnInitialize()
      assert.is_table(NA.db)
      assert.equal(NA.db, ns.db)
      assert.is_true(NA.db.profile.enabled) -- DB.defaults.profile.enabled, round-tripped through AceDB
    end)

    it("runs the global AND profile migrations before anything reads ns.db", function()
      local migrateCalls = {}
      local realMigrate, realMigrateProfile = ns.DB.migrate, ns.DB.migrateProfile
      ns.DB.migrate = function(db) migrateCalls[#migrateCalls + 1] = "global"; return realMigrate(db) end
      ns.DB.migrateProfile = function(p) migrateCalls[#migrateCalls + 1] = "profile"; return realMigrateProfile(p) end

      NA:OnInitialize()

      assert.same({ "global", "profile" }, migrateCalls)
    end)

    it("registers OnProfileChanged for OnProfileChanged, OnProfileCopied AND OnProfileReset", function()
      NA:OnInitialize()
      local migrateProfileCalls = 0
      ns.DB.migrateProfile = function() migrateProfileCalls = migrateProfileCalls + 1 end

      NA.db.callbacks:Fire("OnProfileChanged")
      NA.db.callbacks:Fire("OnProfileCopied")
      NA.db.callbacks:Fire("OnProfileReset")

      assert.equal(3, migrateProfileCalls)
    end)

    it("registers /elm and /elmira, both routed to OnSlash", function()
      NA:OnInitialize()
      local slashCalls = {}
      NA.OnSlash = function(_, input) slashCalls[#slashCalls + 1] = input end

      SlashCmdList["ACECONSOLE_ELM"]("first")
      SlashCmdList["ACECONSOLE_ELMIRA"]("second")

      assert.same({ "first", "second" }, slashCalls)
    end)

    it("fires ns.Display.invalidate() when a state-changing event lands", function()
      NA:OnInitialize()
      local AceEvent = LibStub("AceEvent-3.0")
      for _, event in ipairs({ "SPELL_UPDATE_COOLDOWN", "UNIT_AURA", "PLAYER_TARGET_CHANGED" }) do
        order = {}
        AceEvent.events:Fire(event)
        assert.same({ "Display.invalidate" }, order, event .. " should invalidate the display")
      end
    end)

    it("fires ns.BarGlow.Invalidate() and ns.Display.refresh() when the bar map changes", function()
      NA:OnInitialize()
      local AceEvent = LibStub("AceEvent-3.0")
      for _, event in ipairs({ "ACTIONBAR_SLOT_CHANGED", "UPDATE_MACROS", "PLAYER_ENTERING_WORLD" }) do
        order = {}
        AceEvent.events:Fire(event)
        assert.same({ "BarGlow.Invalidate", "Display.refresh" }, order, event)
      end
    end)

    it("does not invalidate the display for a bar-map-only event, nor refresh bars for a state-only one", function()
      NA:OnInitialize()
      local AceEvent = LibStub("AceEvent-3.0")
      order = {}
      AceEvent.events:Fire("UPDATE_MACROS")
      assert.same({ "BarGlow.Invalidate", "Display.refresh" }, order)
      order = {}
      AceEvent.events:Fire("UNIT_AURA")
      assert.same({ "Display.invalidate" }, order)
    end)
  end)

  describe("data-pack attach order", function()
    local function registerPack()
      ns.API.RegisterDataPack{ class = "PALADIN", flavor = "SoD", spells = {} }
    end

    it("attaches the class's data pack BEFORE the queue renderer is registered", function()
      registerPack()
      NA:OnInitialize()
      NA:OnEnable()

      local attachAt, registerAt
      for i, event in ipairs(order) do
        if event == "attachPack" then attachAt = i end
        if event == "register:queue" then registerAt = i end
      end
      assert.is_not_nil(attachAt, "attachPack was never called")
      assert.is_not_nil(registerAt, "the queue renderer was never registered")
      assert.is_true(attachAt < registerAt,
        "a queue built before attach compiles against no data (Init.lua's own comment)")
    end)

    it("loads the class pack before attaching it", function()
      registerPack()
      NA:OnInitialize()
      NA:OnEnable()
      assert.same({ "loadClassPack:PALADIN", "attachPack" },
        { order[1], order[2] })
    end)

    it("degrades to a null state when no pack is registered for the class, and still starts the display", function()
      -- deliberately no ns.API.RegisterDataPack call
      NA:OnInitialize()
      NA:OnEnable()

      for _, event in ipairs(order) do
        assert.are_not.equal("attachPack", event)
      end
      assert.truthy(table.concat(logged, " "):find("null state", 1, true))
      assert.truthy((function()
        for _, e in ipairs(order) do if e == "register:queue" then return true end end
        return false
      end)())
    end)

    it("degrades to a null state, with a DIFFERENT message, when the adapter cannot accept a pack", function()
      registerPack()
      ns.Adapter.attachPack = nil
      NA:OnInitialize()
      NA:OnEnable()

      for _, event in ipairs(order) do
        assert.are_not.equal("attachPack", event)
      end
      assert.truthy(table.concat(logged, " "):find("cannot accept a data pack", 1, true))
    end)
  end)

  describe("StartDisplay", function()
    it("registers the queue renderer before the overlay renderer, only when both modules exist", function()
      NA:OnInitialize()
      NA:StartDisplay()
      local regs = {}
      for _, e in ipairs(order) do
        if e:match("^register:") then regs[#regs + 1] = e end
      end
      assert.same({ "register:queue", "register:overlay" }, regs)
    end)

    it("registers only the queue when no Overlay module is present", function()
      ns.Overlay = nil
      NA:OnInitialize()
      NA:StartDisplay()
      local regs = {}
      for _, e in ipairs(order) do
        if e:match("^register:") then regs[#regs + 1] = e end
      end
      assert.same({ "register:queue" }, regs)
    end)

    it("does nothing at all, and does not error, when the Display module is absent", function()
      ns.Display = nil
      NA:OnInitialize()
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)
      assert.same({}, order)
    end)

    it("does nothing at all, and does not error, when the Queue module is absent", function()
      ns.Queue = nil
      NA:OnInitialize()
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)
      assert.same({}, order)
    end)

    it("enables the display only when profile.enabled is true", function()
      NA:OnInitialize()
      NA.db.profile.enabled = false
      NA:StartDisplay()
      for _, e in ipairs(order) do assert.are_not.equal("Display.Enable", e) end

      order = {}
      NA.db.profile.enabled = true
      NA:StartDisplay()
      local enabled = false
      for _, e in ipairs(order) do if e == "Display.Enable" then enabled = true end end
      assert.is_true(enabled)
    end)

    it("registers Options when present, and is silent when it is not", function()
      NA:OnInitialize()
      NA:StartDisplay()
      local registered = false
      for _, e in ipairs(order) do if e == "Options.Register" then registered = true end end
      assert.is_true(registered)

      order = {}
      ns.Options = nil
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)
    end)
  end)

  describe("wizard offer is guarded", function()
    it("a failing OfferOnLogin is caught, logged, and does not stop the rest of StartDisplay", function()
      ns.Wizard.OfferOnLogin = function() error("wizard exploded") end
      NA:OnInitialize()
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)

      local sawQueue, sawEnable, sawOptions = false, false, false
      for _, e in ipairs(order) do
        if e == "register:queue" then sawQueue = true end
        if e == "Display.Enable" then sawEnable = true end
        if e == "Options.Register" then sawOptions = true end
      end
      assert.is_true(sawQueue)
      assert.is_true(sawEnable)
      assert.is_true(sawOptions)
      assert.truthy(table.concat(logged, " "):find("wizard exploded", 1, true))
    end)

    it("does nothing, without erroring, when no Wizard module is registered", function()
      ns.Wizard = nil
      NA:OnInitialize()
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)
      assert.same({}, logged)
    end)

    it("a successful OfferOnLogin is simply called", function()
      NA:OnInitialize()
      NA:StartDisplay()
      local offered = false
      for _, e in ipairs(order) do if e == "Wizard.OfferOnLogin" then offered = true end end
      assert.is_true(offered)
      assert.same({}, logged)
    end)
  end)

  describe("SetupMinimapButton", function()
    it("registers a launcher data object and hands it to LibDBIcon, when both libraries are present", function()
      local ldb, dbicon = installMinimapLibs()
      NA:OnInitialize()
      NA:StartDisplay()

      local obj = ldb.objects.Elmira
      assert.is_table(obj)
      assert.equal("launcher", obj.type)
      assert.equal(1, #dbicon.registered)
      assert.equal("Elmira", dbicon.registered[1].name)
      assert.equal(obj, dbicon.registered[1].obj)
      assert.equal(NA.db.global.minimap, dbicon.registered[1].db)
    end)

    it("left-click opens Options; right-click toggles the queue lock", function()
      local ldb = installMinimapLibs()
      NA:OnInitialize()
      NA:StartDisplay()
      local obj = ldb.objects.Elmira

      order = {}
      obj.OnClick(nil, "LeftButton")
      assert.same({ "Options.Open" }, order)

      order = {}
      obj.OnClick(nil, "RightButton")
      assert.same({ "Queue.SetLocked:true" }, order) -- fakeQueue().isLocked() always answers false
    end)

    it("does nothing, without erroring, when the libraries are not present", function()
      NA:OnInitialize()
      local ok = pcall(function() NA:StartDisplay() end)
      assert.is_true(ok)
      assert.is_nil(NA.db.global.minimap)
    end)
  end)
end)
