local helper = require("tests.helper")

describe("Core.Slash", function()
  local Slash

  before_each(function()
    helper.reset()
    Slash = helper.load("Elmira/Core/Slash.lua")
  end)

  local function hasLineMatching(lines, pattern)
    for _, l in ipairs(lines) do
      if l:match(pattern) then return true end
    end
    return false
  end

  -- PRD F9 / ADR-0010: export and import through the real codec, against the shipped paladin data.
  describe("export / import", function()
    local pack, ns
    local function loadCodec()
      if not _G.CreateFrame then dofile("tests/wow_mock.lua") end
      _G.LibStub = nil
      for _, path in ipairs({ "Elmira/Libs/LibStub/LibStub.lua", "Elmira/Libs/LibSerialize/LibSerialize.lua",
                              "Elmira/Libs/LibDeflate/LibDeflate.lua" }) do
        local chunk = assert(loadfile(path), path .. " — run `make libs`"); chunk()
      end
      return LibStub("LibSerialize"), LibStub("LibDeflate")
    end
    before_each(function()
      ns = helper.ns()
      helper.load("Elmira/Adapters/Interface.lua")
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Serialize.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      local LS, LD = loadCodec()
      ns.Serialize.use{ serializer = LS, deflate = LD }
      pack = helper.classPack("Paladin")
      ns.db = { profile = { activeBuild = false }, global = { userBuilds = {} } }
      ns.Display = { currentPack = function() return pack end,
                     activeBuild = function() return nil, "PALADIN_EXODIN", "recommended" end,
                     refresh = function() end }
      ns.Adapter = { today = function() return "2026-09-03" end }
    end)

    it("export with no key exports the active build as one ELM1: line", function()
      local lines = Slash.run("export")
      assert.equal(2, #lines)
      assert.truthy(lines[1]:find("PALADIN_EXODIN exported", 1, true))
      assert.equal("ELM1:", lines[2]:sub(1, 5))
    end)

    it("export names a missing key, and says so without a pack", function()
      assert.truthy(Slash.run("export GHOST")[1]:find("GHOST", 1, true))
      ns.Display = nil
      assert.truthy(Slash.run("export")[1]:find("no data pack", 1, true))
    end)

    it("import stores a fork, dated, and the profile command then knows it", function()
      local str = Slash.run("export PALADIN_WRATHLIKE")[2]
      local lines = Slash.run("import " .. str .. " my wrath")
      assert.truthy(lines[1]:find("Imported as USER_MY_WRATH", 1, true))
      assert.equal("2026-09-03", ns.db.global.userBuilds.USER_MY_WRATH.importedAt)
      assert.truthy(table.concat(Slash.run("profile"), "\n"):find("USER_MY_WRATH", 1, true))
      assert.truthy(Slash.run("profile USER_MY_WRATH")[1]:find("Pinned to USER_MY_WRATH", 1, true))
      assert.equal("USER_MY_WRATH", ns.db.profile.activeBuild)
    end)

    it("export says when there is no active build, and when the builds module is missing", function()
      ns.Display.activeBuild = function() return nil, nil, "no build" end
      assert.truthy(Slash.run("export")[1]:find("no active build", 1, true))
      ns.UserBuilds = nil
      assert.truthy(Slash.run("export PALADIN_EXODIN")[1]:find("builds module is not loaded", 1, true))
      assert.truthy(Slash.run("import ELM1:x")[1]:find("builds module is not loaded", 1, true))
    end)

    -- ADR-0015 SS1: /elm rotation is the front door, and it must land ON the Rotation section
    -- rather than wherever the panel happened to be left. `setup` stays as an alias until the
    -- Builder lands, so no release has the old verb gone and the new panel not yet able to edit.
    it("rotation opens the panel at the Rotation section", function()
      local openedAt
      ns.Options = { Open = function(path) openedAt = path; return true end }
      assert.same({ "Opening your rotations." }, Slash.run("rotation"))
      assert.equal("rotation", openedAt)
    end)

    -- Above `config` and `setup`: the front door should be the first of the three you see in help,
    -- not buried under the verb it replaces.
    it("lists rotation ahead of config and setup in help", function()
      local order = {}
      for _, line in ipairs(Slash.run("help")) do
        local verb = line:match("^%s%s(%S+)")
        if verb then order[verb] = #order + 1; order[#order + 1] = verb end
      end
      assert.is_truthy(order.rotation, "rotation is missing from help")
      assert.is_true(order.rotation < order.config, "rotation should sort above config")
      assert.is_true(order.rotation < order.setup, "rotation should sort above setup")
    end)

    it("rotation says so when the options are not loaded", function()
      ns.Options = nil
      assert.truthy(Slash.run("rotation")[1]:find("not loaded", 1, true))
    end)

    it("rotation reports rather than claiming success when the panel refuses to open", function()
      ns.Options = { Open = function() return false end }
      assert.truthy(Slash.run("rotation")[1]:find("not loaded", 1, true))
    end)

    it("export hands the string to the Options box, where it can actually be copied from", function()
      local placed
      ns.Options = { setExchangeText = function(str) placed = str end }
      local lines = Slash.run("export PALADIN_PROT")
      assert.equal(lines[2], placed)
    end)

    it("import says when there is no pack, and refreshes the display on success", function()
      local refreshes = 0
      ns.Display.refresh = function() refreshes = refreshes + 1 end
      local str = Slash.run("export PALADIN_EXODIN")[2]
      Slash.run("import " .. str .. " again")
      assert.equal(1, refreshes)
      ns.Display = nil
      assert.truthy(Slash.run("import " .. str)[1]:find("no data pack", 1, true))
    end)

    it("import shows usage without a string, and the codec's reason on a bad one", function()
      assert.truthy(Slash.run("import")[1]:find("Usage", 1, true))
      assert.truthy(Slash.run("import ELM1:notreally")[1]:find("import: corrupted", 1, true))
    end)
  end)

  it("help output lists the debug command", function()
    assert.is_true(hasLineMatching(Slash.run(""), "debug"))
  end)

  it("empty input and 'help' produce byte-identical output (fixed order, never pairs())", function()
    local a = table.concat(Slash.run(""), "\n")
    local b = table.concat(Slash.run("help"), "\n")
    assert.equal(a, b)
  end)

  it("help output is stable across repeated calls", function()
    local a = table.concat(Slash.run(""), "\n")
    local b = table.concat(Slash.run(""), "\n")
    assert.equal(a, b)
  end)

  it("'debug' with no subcommand returns the usage line", function()
    local lines = Slash.run("debug")
    assert.is_true(hasLineMatching(lines, "^Usage: /elm debug"))
  end)

  it("'debug perf' returns at least one line and does not error", function()
    local lines = Slash.run("debug perf")
    assert.is_true(#lines >= 1)
  end)

  -- Reported from a client: `/elm debug bars` said ElvUI held 43 mapped spells while
  -- `/elm debug perf` said "bar map: 0 spells, built=false" in the same install. Both numbers were
  -- right and the LABEL was the lie -- perf reports the Blizzard FALLBACK, which is unbuilt
  -- precisely because a bar addon is doing the work. Read bare, it said the display was broken.
  describe("'debug perf' bar map reporting", function()
    -- The bar-map line only renders once the display is loaded, so it needs the same Display stub
    -- the build-reason cases use.
    local function withMap(stats)
      local ns = helper.ns()
      ns.Display = {
        isEnabled = function() return true end,
        stats = function()
          return { build = "PALADIN_EXODIN", renderers = 1, runs = 1, skipped = 1,
                   visible = true, visibleReason = "ok", mode = "always" }
        end,
      }
      ns.BarGlow = { stats = function() return stats end }
      return Slash.run("debug perf")
    end

    it("names which map the numbers are about, and how to see the rest", function()
      local lines = withMap{ mapped = 0, providers = 2, built = false }
      assert.is_true(hasLineMatching(lines, "2 bar addon provider%(s%)"))
      assert.is_true(hasLineMatching(lines, "Blizzard fallback 0 spell%(s%)"))
      assert.is_true(hasLineMatching(lines, "/elm debug bars"))
    end)

    -- An unbuilt fallback with a bar addon present is not a fault, and the line has to say so or
    -- the next person reads it the same way.
    it("explains an unbuilt fallback differently depending on why", function()
      assert.is_true(hasLineMatching(withMap{ mapped = 0, providers = 2, built = false },
        "not needed while a bar addon"))
      local lines = withMap{ mapped = 0, providers = 0, built = false }
      assert.is_true(hasLineMatching(lines, "nothing has asked for a button yet"))
      assert.is_false(hasLineMatching(lines, "not needed while a bar addon"))
    end)

    it("says nothing about why once the fallback is built", function()
      local lines = withMap{ mapped = 9, providers = 0, built = true }
      assert.is_true(hasLineMatching(lines, "Blizzard fallback 9 spell%(s%), built=true"))
      assert.is_false(hasLineMatching(lines, "not needed"))
      assert.is_false(hasLineMatching(lines, "nothing has asked"))
    end)
  end)

  -- This command exists to answer "is Elmira expensive" — it used to open with the WHOLE client's
  -- Lua heap under a bare "lua memory:" label, which read as if Elmira itself used 300 MB.
  describe("'debug perf' memory reporting", function()
    -- The capability, not the accessor's mere presence, is what decides the wording. Those are two
    -- different facts about the client and the user gets a different sentence for each.
    local function adapterWith(caps, kb)
      return { capabilities = function() return caps end, addonMemoryKB = function() return kb end }
    end

    it("prints Elmira's own figure first when the adapter reports one", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, 1234)
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "^Elmira memory: 1234 KB$"))
    end)

    it("says it could not tell when the client cannot report per-addon usage at all", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = false }, 1234)
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines,
        "^Elmira memory: could not tell %(this client does not report per%-addon usage%)$"))
    end)

    -- A capable client whose read failed is a DIFFERENT answer: permanent limitation vs retry.
    -- Collapsing the two is what let the addonMemory capability ship with no reader at all.
    it("says to try again when the client is capable but the read returned nothing", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, nil)
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "^Elmira memory: could not read it just now %(try again%)$"))
    end)

    it("ignores a stale accessor when the capability says the client cannot report", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = false }, 9999)
      local lines = Slash.run("debug perf")
      assert.is_false(hasLineMatching(lines, "9999"))
    end)

    it("says it could not tell when there is no adapter loaded at all", function()
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "^Elmira memory: could not tell"))
    end)

    it("no longer prints the old bare 'lua memory:' line", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, 1234)
      local lines = Slash.run("debug perf")
      assert.is_false(hasLineMatching(lines, "^lua memory:"))
    end)

    it("labels the heap total as covering ALL addons, not just Elmira's", function()
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "^client Lua heap, ALL addons: %d+ KB$"))
    end)

    -- The figure above is only Elmira's if Elmira's copies of the shared libraries did not win
    -- LibStub. When they did, the client charges every other addon's use of them to us, and reading
    -- the number as a leak sends the next three days in the wrong direction -- which is exactly what
    -- happened. The caveat belongs where the number is read, not only in a command nobody runs.
    it("warns beside the figure when Elmira owns shared libraries the whole UI is using", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, 1234)
      ns.LibOwner = { ownedCount = function() return 4 end }
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "4 shared libraries Elmira embeds"))
      assert.is_true(hasLineMatching(lines, "/elm debug libs"))
    end)

    it("says nothing about libraries when none of ours won", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, 1234)
      ns.LibOwner = { ownedCount = function() return 0 end }
      assert.is_false(hasLineMatching(Slash.run("debug perf"), "shared librar"))
    end)

    it("says nothing about libraries when the probe could not tell", function()
      local ns = helper.ns()
      ns.Adapter = adapterWith({ addonMemory = true }, 1234)
      ns.LibOwner = { ownedCount = function() return nil end }
      assert.is_false(hasLineMatching(Slash.run("debug perf"), "shared librar"))
    end)
  end)

  -- Both of these exist because the memory question could not be answered by reading code: the
  -- headless benchmark says the render loop allocates 0.016 KB a frame and retains nothing, while
  -- the client reported ~70 KB/s. These are the two commands that tell those apart in game.
  describe("'debug alloc'", function()
    local function wire(opts)
      opts = opts or {}
      local ns = helper.ns()
      local env = { pending = {}, printed = {} }
      helper.load("Elmira/Core/MemProbe.lua")
      helper.load("Elmira/Adapters/Interface.lua")
      ns.log = function(fmt, ...) env.printed[#env.printed + 1] = string.format(fmt, ...) end
      ns.addon = { ScheduleTimer = function(_, fn, s) env.pending[#env.pending + 1] = { fn = fn, s = s } end }
      local state = ns.Interface.newNullState()
      ns.API = { GetState = function() return state end }
      ns.db = { profile = { depth = 4 } }
      local compiled = { entries = {} }
      ns.Display = { activeBuild = function()
        if opts.noBuild then return nil, nil, "no data pack for this class" end
        return compiled, "PALADIN_EXODIN", "pinned"
      end }
      env.queued = {}
      ns.Simulation = { queue = function(build, st, depth, into)
        env.queued[#env.queued + 1] = { build = build, state = st, depth = depth, into = into }
        st:cooldown("X")
        return into or {}
      end }
      ns.Adapter = { spellbookStatus = function() return "spellbook: cached, 12 entries read" end }
      return ns, env
    end

    it("says what is missing rather than silently doing nothing", function()
      assert.is_true(hasLineMatching(Slash.run("debug alloc"), "probe is not loaded"))
      helper.load("Elmira/Core/MemProbe.lua")
      assert.is_true(hasLineMatching(Slash.run("debug alloc"), "not loaded"))
      wire{ noBuild = true }
      assert.is_true(hasLineMatching(Slash.run("debug alloc"), "no build to simulate"))
    end)

    -- Warm now, measure next frame: a same-frame measurement only shows cache hits, and the point
    -- is what a real tick pays when every per-frame memo has to refill.
    it("warms in this frame and measures one recompute on the next, into the same buffer", function()
      local ns, env = wire()
      assert.is_true(hasLineMatching(Slash.run("debug alloc"), "next frame"))
      assert.equal(1, #env.queued, "warmed once, synchronously")
      assert.equal(4, env.queued[1].depth, "the profile's depth")
      assert.equal(1, #env.pending)
      env.pending[1].fn()
      assert.equal(2, #env.queued)
      assert.equal(env.queued[1].state, env.queued[2].state)
      assert.is_table(env.queued[2].into, "measured into the warmed buffer, as the tick does")
      assert.is_true(hasLineMatching(env.printed, "^one recompute of PALADIN_EXODIN at depth 4"))
      assert.is_true(hasLineMatching(env.printed, "^  cooldown%s+[%d%.]+ KB over   1 call"))
      assert.is_true(hasLineMatching(env.printed, "^  unattributed"))
      assert.is_true(hasLineMatching(env.printed, "^spellbook: cached"))
      assert.equal(ns.Interface.newNullState().cooldown ~= nil, true)
    end)

    it("reports a measurement that threw, with the display's state restored", function()
      local ns, env = wire()
      Slash.run("debug alloc")
      local state = ns.API.GetState()
      local before = state.cooldown
      ns.Simulation.queue = function() error("kaboom") end
      env.pending[1].fn()
      assert.is_true(hasLineMatching(env.printed, "measurement failed .*kaboom"))
      assert.is_false(hasLineMatching(env.printed, "^spellbook"), "no rows, no status: the run did not happen")
      assert.equal(before, state.cooldown)
    end)
  end)

  describe("'debug libs'", function()
    it("says so when the probe never loaded, rather than reporting no libraries", function()
      assert.is_true(hasLineMatching(Slash.run("debug libs"), "probe is not loaded"))
    end)

    -- "we never looked" and "we own nothing" are different answers and the second one would end the
    -- investigation on a false negative.
    it("passes on the reason when the snapshots were never sealed", function()
      helper.ns().LibOwner = { report = function() return nil, "never sealed" end }
      assert.is_true(hasLineMatching(Slash.run("debug libs"), "never sealed"))
    end)

    it("marks a library we still own separately from one a later addon took back", function()
      helper.ns().LibOwner = { report = function()
        return {
          { name = "LibCustomGlow-1.0", minor = 25, current = 25, ours = true },
          { name = "AceTimer-3.0", minor = 17, current = 18, ours = false, replacedBy = 18 },
        }
      end }
      local lines = Slash.run("debug libs")
      assert.is_true(hasLineMatching(lines, "^  OURS  LibCustomGlow%-1%.0%s+r25$"))
      assert.is_true(hasLineMatching(lines, "^  was   AceTimer%-3%.0%s+r17, replaced by r18$"))
      assert.is_true(hasLineMatching(lines, "^libraries Elmira installed: 1 still ours, 1 taken over"))
      assert.is_true(hasLineMatching(lines, "charged to"))
      -- Both halves of the sentence: "charged to" alone stops mid-thought, and the second line is
      -- the one that says this is the client's accounting rather than a leak to go hunting.
      assert.is_true(hasLineMatching(lines, "not a leak"))
    end)

    -- An empty audit is a real, reportable outcome: every library was already loaded elsewhere at a
    -- same-or-higher version. Printing a bare header for it reads as a broken command.
    it("says why the list is empty when Elmira installed nothing", function()
      helper.ns().LibOwner = { report = function() return {} end }
      local lines = Slash.run("debug libs")
      assert.is_true(hasLineMatching(lines, "already loaded at a same%-or%-higher version"))
      assert.is_false(hasLineMatching(lines, "charged to"))
    end)
  end)

  describe("'debug memory'", function()
    -- Everything the command needs, wired to fakes. `pending` is the scheduler: draining it by hand
    -- is what makes a forty-second measurement testable in a millisecond.
    local function wire(opts)
      opts = opts or {}
      local ns = helper.ns()
      local env = { pending = {}, printed = {}, kb = 1000, clock = 0, suspended = false }
      helper.load("Elmira/Core/MemProbe.lua")
      ns.log = function(fmt, ...) env.printed[#env.printed + 1] = string.format(fmt, ...) end
      ns.now = function() return env.clock end
      ns.addon = { ScheduleTimer = function(_, fn, s) env.pending[#env.pending + 1] = { fn = fn, s = s } end }
      -- NOT `opts.noMemory and nil or env.kb`: `x and nil or y` always answers y in Lua, so the
      -- "client cannot report memory" case would have handed back a real figure and tested nothing.
      ns.Adapter = { addonMemoryKB = function()
        if opts.noMemory then return nil end
        return env.kb
      end }
      ns.API = { GetState = function()
        return { inCombat = function() return opts.inCombat == true end }
      end }
      ns.Display = {
        isEnabled = function() return opts.enabled ~= false end,
        Disable = function() env.suspended = true end,
        Enable = function() env.suspended = false end,
      }
      -- KB/s while running vs while suspended, so a spec can make the two windows agree or diverge.
      function env.drain(running, idle)
        local guard = 0
        while #env.pending > 0 and guard < 500 do
          guard = guard + 1
          local job = table.remove(env.pending, 1)
          env.clock = env.clock + job.s
          env.kb = env.kb + job.s * (env.suspended and idle or running)
          job.fn()
        end
      end
      return ns, env
    end

    -- Both guards answer the same question -- "why did nothing happen?" -- and each names a
    -- different missing piece. Collapsed into one, or dropped, the command returns nothing and
    -- looks like it silently started.
    it("says which piece is missing rather than starting a run it cannot finish", function()
      local ns = helper.ns()
      ns.Display = { isEnabled = function() return true end }
      assert.is_true(hasLineMatching(Slash.run("debug memory"), "probe is not loaded"))
      local _, env = wire()
      ns.Display = nil
      assert.is_true(hasLineMatching(Slash.run("debug memory"), "display not loaded"))
      assert.equal(0, #env.pending, "nothing may be scheduled for a run that cannot start")
    end)

    -- The command runs for forty seconds and blanks the display for twenty of them. Saying so up
    -- front is the difference between a measurement and an apparent bug, so both lines are pinned
    -- with the real numbers the probe will actually use.
    it("says how long it will take and warns that the display goes dark", function()
      wire()
      local lines = Slash.run("debug memory")
      local half = helper.ns().MemProbe.PHASE_SECONDS
      assert.is_true(hasLineMatching(lines,
        "^measuring for " .. (half * 2) .. " seconds%. Stand still and do not fight%.$"))
      assert.is_true(hasLineMatching(lines,
        "^the display goes dark for the last " .. half .. " of them; that is the measurement%.$"))
    end)

    it("refuses to start in combat: the display goes dark for half the run", function()
      local _, env = wire{ inCombat = true }
      assert.is_true(hasLineMatching(Slash.run("debug memory"), "you are in combat"))
      assert.equal(0, #env.pending)
    end)

    it("refuses on a client that will not report per-addon memory", function()
      local _, env = wire{ noMemory = true }
      assert.is_true(hasLineMatching(Slash.run("debug memory"), "does not report per%-addon memory"))
      assert.is_false(env.suspended, "nothing may be suspended for a measurement that cannot run")
    end)

    it("says a second run is already in flight rather than starting one underneath it", function()
      local _, env = wire()
      Slash.run("debug memory")
      assert.is_true(hasLineMatching(Slash.run("debug memory"), "already running"))
      env.drain(20, 20)
    end)

    -- The whole point of the command: the same growth with the display suspended means the render
    -- loop is not where the memory is going.
    it("reports both windows and calls it not-the-render-loop when they agree", function()
      local ns, env = wire()
      ns.LibOwner = { ownedCount = function() return 4 end }
      Slash.run("debug memory")
      env.drain(20, 20)
      assert.is_true(hasLineMatching(env.printed, "^display RUNNING:   20%.0 KB/s"))
      assert.is_true(hasLineMatching(env.printed, "^display SUSPENDED: 20%.0 KB/s"))
      assert.is_true(hasLineMatching(env.printed, "NOT the render loop"))
      assert.is_true(hasLineMatching(env.printed, "^shared libraries: 4 of the libraries"))
      assert.is_false(env.suspended, "the display must be running again when the run finishes")
    end)

    it("names the render loop's share when suspending it changes the rate", function()
      local _, env = wire()
      Slash.run("debug memory")
      env.drain(100, 10)
      assert.is_true(hasLineMatching(env.printed, "render loop accounts for 90%% of the growth"))
    end)

    -- Running it with the display already off must not turn it on: the command restores what the
    -- player had, not what it wanted.
    it("leaves a display the player had switched off switched off", function()
      local _, env = wire{ enabled = false }
      Slash.run("debug memory")
      env.drain(20, 20)
      assert.is_true(env.suspended, "resume must not enable a display that was never enabled")
    end)
  end)

  -- Display.stats().build falls back to a resolved (not rendered) build when the display is hidden;
  -- the reason belongs in the output only in that resolved case, never alongside a real render.
  describe("'debug perf' build reason", function()
    it("shows the reason in parentheses when the build was resolved, not rendered", function()
      local ns = helper.ns()
      ns.Display = {
        isEnabled = function() return true end,
        stats = function()
          return { build = "PALADIN_EXODIN", buildReason = "no data pack for this class",
                    renderers = 0, runs = 0, skipped = 0, visible = true, visibleReason = "ok",
                    mode = "always" }
        end,
      }
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "build=PALADIN_EXODIN %(no data pack for this class%)"))
    end)

    it("shows no parenthetical when the build key came from a real render", function()
      local ns = helper.ns()
      ns.Display = {
        isEnabled = function() return true end,
        stats = function()
          return { build = "PALADIN_EXODIN", buildReason = nil,
                    renderers = 1, runs = 4, skipped = 20, visible = true, visibleReason = "ok",
                    mode = "always" }
        end,
      }
      local lines = Slash.run("debug perf")
      assert.is_true(hasLineMatching(lines, "build=PALADIN_EXODIN, renderers=1"))
      assert.is_false(hasLineMatching(lines, "build=PALADIN_EXODIN %("))
    end)
  end)

  it("'debug bars' reports zero providers when none are registered", function()
    local lines = Slash.run("debug bars")
    assert.is_true(hasLineMatching(lines, "bar providers: 0"))
  end)

  -- The branch above is the degraded one, reached without Display. This is the real one, and its
  -- message used to name Elmira_ElvUI -- an addon that no longer exists (ADR-0014). What replaces
  -- it has to say what IS in use, or a reader with no bar addon concludes the glow is broken when
  -- it is working exactly as designed against the default Blizzard bars.
  it("'debug bars' names the bar addons it looks for, and says the Blizzard scan is in use", function()
    _G.__ELM_NS.BarGlow = { describe = function() return { providers = {}, blizzard = 4, rows = {} } end }
    local lines = Slash.run("debug bars")
    assert.is_true(hasLineMatching(lines, "bar providers: 0"))
    assert.is_true(hasLineMatching(lines, "ElvUI, Bartender4"))
    assert.is_true(hasLineMatching(lines, "Blizzard bar scan below is what is in use"))
    assert.is_false(hasLineMatching(lines, "Elmira_ElvUI"))
  end)

  it("verb matching is case-insensitive", function()
    local lower = table.concat(Slash.run("debug state"), "\n")
    local upper = table.concat(Slash.run("DEBUG state"), "\n")
    assert.equal(lower, upper)
  end)

  it("unknown input returns exactly one line and does not error", function()
    local lines = Slash.run("nonsense")
    assert.equal(1, #lines)
    assert.equal("Unknown command 'nonsense'. Type /elm for help.", lines[1])
  end)

  -- Was "not available yet (M4)" until M4 landed. Rewritten rather than deleted: the property worth
  -- keeping is that the command DEGRADES with a designed line instead of erroring when the module
  -- behind it is absent, which is what this spec's Core-only harness reproduces.
  it("'setup' degrades with a designed line when the wizard is not loaded", function()
    local lines = Slash.run("setup")
    assert.equal(1, #lines)
    assert.equal("setup: the wizard is not loaded", lines[1])
  end)

  it("'profile' and 'advise' degrade the same way rather than erroring", function()
    assert.equal("profile: no data pack for your class", Slash.run("profile")[1])
    assert.equal("advise: the advisor is not loaded", Slash.run("advise")[1])
  end)

  it("'sim' names a non-integer milestone label correctly", function()
    local lines = Slash.run("sim")
    assert.matches("not available yet %(M5c%)", lines[1])
  end)

  -- M2 acceptance runs through this command, so it must degrade with a DIAGNOSIS rather than an
  -- empty list — "nothing happened" is the shape that wastes an in-game round trip.
  describe("debug queue", function()
    it("says which builds exist when asked for one that does not", function()
      local ns = helper.ns()
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return { PALADIN = { builds = { PALADIN_EXODIN = {} } } } end,
                 GetState = function() return {} end }
      local out = table.concat(Slash.run("debug queue NOPE"), "\n")
      assert.truthy(out:find("PALADIN_EXODIN", 1, true), out)
    end)

    it("reports no builds rather than printing an empty queue", function()
      local ns = helper.ns()
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return {} end, GetState = function() return {} end }
      local out = table.concat(Slash.run("debug queue"), "\n")
      assert.truthy(out:find("no builds registered", 1, true), out)
    end)

    -- The player's own feedback after the acceptance run: copying chat output mid-combat is not
    -- workable. The queue has to reach the saved file, not just the chat frame.
    it("captures the queue as data for the dump file", function()
      local ns = helper.ns()
      ns.Schema = { compile = function(b) return { entries = { { spell = "EXORCISM", test = function() return true end } } } end,
                    errorLines = function() return {} end }
      ns.Simulation = { queue = function() return { { spell = "EXORCISM", t = 0 } } end }
      ns.API = { GetState = function() return { usable = function() return true end,
                                                cooldown = function() return 0 end,
                                                inCombat = function() return true end } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.is_table(snap.PALADIN_EXODIN)
      assert.equal("EXORCISM", snap.PALADIN_EXODIN.queue[1].spell)
      assert.equal("EXORCISM", snap.PALADIN_EXODIN.entries[1].spell)
      assert.is_true(snap.PALADIN_EXODIN.inCombat)
    end)

    -- Contract: entries[i].usable is a real boolean for any entry that has a spell — true when the
    -- state reports it usable, and exactly `false` (never nil) when it does not. The bug this guards
    -- against was `entry.spell and (state:usable(entry.spell) == true) or nil`, which in Lua collapses
    -- `false or nil` to nil, so a not-usable spell read back as "not asked" instead of "not usable".
    it("records usable=true (a real boolean) for a spell the state reports usable", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "EXORCISM", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return true end,
        cooldown = function() return 3 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      assert.is_true(entry.usable)
    end)

    it("records usable=false, never nil, for a spell the state reports as not usable", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "AVENGERS_SHIELD", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return false end,
        cooldown = function() return 5 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      -- assert.falsy would also pass for nil, which is exactly the bug this test exists to catch —
      -- so the check has to distinguish false from nil explicitly.
      assert.is_false(entry.usable, "a not-usable spell must record usable=false, not nil")
      assert.is_not_nil(entry.usable, "nil means \"not asked\"; this spell WAS asked and said no")
    end)

    it("keeps a spell's cooldown of exactly 0 as 0, not nil or false", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "EXORCISM", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return true end,
        cooldown = function() return 0 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.equal(0, snap.PALADIN_EXODIN.entries[1].cooldown)
    end)

    -- Contract: an item entry has no spell to ask about, so usable and cooldown are nil — reserved
    -- for "not asked" rather than repurposed as a false verdict on a spell that was never in play.
    it("leaves usable and cooldown nil for an entry with no spell (an item entry)", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { item = 13 },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        -- Return truthy values on purpose: a correct implementation gates on entry.spell existing,
        -- not on what these would answer if asked.
        usable = function() return true end,
        cooldown = function() return 42 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      assert.equal(13, entry.item)
      assert.is_nil(entry.usable)
      assert.is_nil(entry.cooldown)
    end)

    it("records a validation failure instead of an empty queue", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return nil, { { message = "bad" } } end,
                    errorLines = function() return { "entry 1: bad" } end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {} end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.same({ "entry 1: bad" }, snap.PALADIN_EXODIN.error)
    end)

    -- Caught by luacheck as "never set", but it was a real defect: `local a, b = x and x:match(...)`
    -- truncates to one value, so every recorded mark would have been unlabelled.
    it("keeps the label given to rec mark", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset(); ns.Recorder.start(0)
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return { PALADIN = { spells = {}, sets = {} } } end,
                 GetState = function() return {} end }
      ns.captureMark = function() return {} end

      Slash.run("rec mark 4of9-t3")
      assert.equal("4of9-t3", ns.Recorder.marks()[1].label)
    end)

    -- The first live run was started mid-combat, so its baseline mark was a combat snapshot and
    -- meant something different from every mark after it.
    it("refuses to start recording while in combat", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.API = { GetState = function() return { inCombat = function() return true end } end,
                 GetProviders = function() return {} end }
      local out = table.concat(Slash.run("rec start"), "\n")
      assert.truthy(out:find("in combat", 1, true), out)
      assert.is_false(ns.Recorder.isRecording())
    end)

    it("starts out of combat and prints the plan", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.API = { GetState = function() return { inCombat = function() return false end } end,
                 GetProviders = function() return {} end }
      local out = table.concat(Slash.run("rec start"), "\n")
      assert.is_true(ns.Recorder.isRecording())
      assert.truthy(out:find("baseline", 1, true), out)
      assert.truthy(out:find("/reload", 1, true), out)
    end)

    it("lists queue as an available debug subcommand", function()
      local out = table.concat(Slash.run("debug"), "\n")
      assert.truthy(out:find("queue", 1, true), out)
    end)
  end)

  -- Contract (docs/01 §2, rule 3): ns.now() is the addon's single source of time. It reads
  -- ns.API.GetState():now() and never calls the client's GetTime() directly. Nothing ever assigned
  -- ns.now, and every call site guarded it as `ns.now and ns.now() or 0`, so a real 4-fight recording
  -- stamped every mark at=0, elapsed=0, startedAt=0 — a recording with no time axis at all.
  describe("ns.now (the recorder's clock)", function()
    it("always exists and always returns a number, never nil", function()
      local ns = helper.ns()
      assert.is_function(ns.now)
      assert.is_number(ns.now())
    end)

    it("returns 0 when ns.API itself is not set yet (pre-OnInitialize)", function()
      local ns = helper.ns()
      ns.API = nil
      assert.equal(0, ns.now())
    end)

    it("returns 0 when ns.API is set but GetState() has nothing to give yet", function()
      local ns = helper.ns()
      ns.API = { GetState = function() return nil end }
      assert.equal(0, ns.now())
    end)

    -- The direct test for "reads from the injected state, never GetTime()": rig GetTime() to answer
    -- with a value nothing in the test set up, then prove ns.now() answers with the state's value
    -- instead. If ns.now() ever called GetTime() directly, this would observe the sentinel, not the
    -- state's clock.
    it("reads the time from ns.API.GetState():now(), not from GetTime()", function()
      local ns = helper.ns()
      local clock = { _now = 4242 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      local realGetTime = _G.GetTime
      _G.GetTime = function() return 999999 end
      local result = ns.now()
      _G.GetTime = realGetTime
      assert.equal(4242, result)
    end)

    -- Drives the actual /elm rec start and /elm rec mark paths, since those are the call sites the
    -- live bug broke. A fake clock that changes between calls is what catches a hard-coded 0 or an
    -- unassigned ns.now — a spec that only checks "at is a number" would pass on either.
    it("stamps rec marks with the real elapsed time, and different marks get different `at`", function()
      local ns = helper.ns()
      local clock = { _now = 100 }
      function clock:now() return self._now end
      function clock:inCombat() return false end
      ns.API = { GetState = function() return clock end,
                 GetProviders = function() return { PALADIN = { spells = {}, sets = {} } } end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.captureMark = function() return {} end

      local startOut = table.concat(Slash.run("rec start"), "\n")
      assert.is_true(ns.Recorder.isRecording(), startOut)

      clock._now = 130
      Slash.run("rec mark first")
      clock._now = 175
      Slash.run("rec mark second")

      local marks = ns.Recorder.marks()
      assert.equal(2, #marks)
      assert.equal(130, marks[1].at)
      assert.equal(175, marks[2].at)
      assert.is_not.equal(marks[1].at, marks[2].at,
        "two marks taken at different times must carry different `at` values")
      assert.equal(30, marks[1].elapsed, "elapsed is `at` minus the recording's startedAt (100)")
      assert.equal(75, marks[2].elapsed)
    end)
  end)

  it("'debug swing' degrades with a designed line when the swing adapter is absent", function()
    local lines = Slash.run("debug swing")
    assert.equal(1, #lines)
    assert.equal("swing: adapter not loaded", lines[1])
  end)

  it("'debug' usage line mentions cues (peripheral cue diagnostics)", function()
    local lines = Slash.run("debug")
    assert.is_true(hasLineMatching(lines, "cues"))
  end)

  -- ADR-0015: the same answer the announcement gives at the moment it changes, on demand and in
  -- full. Without it a player who missed the message has no way to ask again.
  describe("debug gates", function()
    it("degrades with a designed line when the display is not loaded", function()
      assert.is_nil(helper.ns().Display)
      assert.same({ "gates: display not loaded" }, Slash.run("debug gates"))
    end)

    -- "every row of nil is live for this character" is reassuring, and wrong, at exactly the
    -- moment nothing is loaded.
    it("says there is no build rather than reporting on one", function()
      helper.ns().Display = { inactiveRows = function() return {}, nil end }
      assert.same({ "gates: no build is active." }, Slash.run("debug gates"))
    end)

    it("says so plainly when every row is live", function()
      helper.ns().Display = { inactiveRows = function() return {}, "PALADIN_EXODIN" end }
      local lines = Slash.run("debug gates")
      assert.equal(1, #lines)
      assert.is_truthy(lines[1]:find("every row of PALADIN_EXODIN is live"))
    end)

    it("names each row that cannot fire, and why", function()
      helper.ns().Display = { inactiveRows = function()
        return { { index = 4, spell = "DIVINE_STORM", reasons = { "needs the 4-set", "level 60" } },
                 { index = 7, item = 13, reasons = { "no trinket equipped" } } }, "PALADIN_EXODIN"
      end }
      local lines = Slash.run("debug gates")
      assert.equal(3, #lines)
      assert.is_truthy(lines[1]:find("2 row"))
      assert.is_truthy(lines[2]:find("4. DIVINE_STORM"))
      assert.is_truthy(lines[2]:find("needs the 4%-set; level 60"))
      assert.is_truthy(lines[3]:find("7. item 13"))
    end)
  end)

  it("'debug cues' degrades with a designed line when the overlay is not loaded", function()
    local ns = helper.ns()
    assert.is_nil(ns.Overlay)
    local lines = Slash.run("debug cues")
    assert.same({ "cues: overlay not loaded" }, lines)
  end)

  -- Drives Overlay.lua for real (loaded fresh per test) rather than faking its output, so these
  -- tests catch the two fixed defects: TestFire silently attributing a bad index to cue 1, and a
  -- test-fired `event = "check"` cue printing a bare success line that contradicts the options
  -- screen (ADR-0009: check cues stay inert until M5b).
  describe("debug cues", function()
    local ns, calls

    -- Cue 1 is a now_slot cue (the ordinary, fireable case). Cue 2 is an event="check" cue, which
    -- Overlay.availableCues() always marks unavailable — Core/Checks.lua does not exist until M5b.
    local function cues()
      return {
        { event = "now_slot", spell = "EXORCISM", reason = "Exorcism up", edge = "left", color = { 1, 1, 1 } },
        { event = "check", spell = "SEAL_OF_MARTYRDOM", reason = "Seal dropped" },
      }
    end

    before_each(function()
      ns = helper.ns()
      helper.load("Elmira/Display/Overlay.lua")
      ns.db = { profile = { overlay = { cues = {} } } }
      ns.Display = { activeBuild = function() return { visuals = { cues = cues() } } end }
      -- Stubbed so no frame is ever created (Core specs must stay WoW-API-free) and so a flare can
      -- be counted instead of animated.
      calls = 0
      ns.Overlay.Flare = function() calls = calls + 1; return true end
    end)

    local function enableCue(id)
      ns.db.profile.overlay.cues[id] = { enabled = true, edge = "left", intensity = 0.5 }
    end

    it("lists each cue and marks the check cue UNAVAILABLE with its reason", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "1%. Exorcism up %[now_slot:EXORCISM%]"))
      assert.is_true(hasLineMatching(lines, "2%. Seal dropped %[check:SEAL_OF_MARTYRDOM%]"))
      assert.is_true(hasLineMatching(lines, "UNAVAILABLE: needs readiness checks %(M5b%)"))
    end)

    it("an enabled cue reports on, and reports last fired=never before anything has flared", function()
      enableCue("now_slot:EXORCISM")
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "on  edge=left"))
      assert.is_true(hasLineMatching(lines, "last fired=never"))
    end)

    -- Regression coverage for the deliberate `ns.now` guard in Overlay.Render/describe: no flare has
    -- happened yet, so lastFired must carry nothing for this cue. (The separate case of a flare
    -- recorded while no clock exists is Overlay's own contract and is covered in overlay_spec.)
    it("reports never for a cue that is enabled but has not matched the now-slot", function()
      enableCue("now_slot:EXORCISM")
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "matches now%-slot=false  last fired=never"))
    end)

    it("reports a real elapsed time, not never, after a flare driven via Overlay.Render", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      enableCue("now_slot:EXORCISM")

      ns.Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, calls, "Render must flare the matching enabled now_slot cue exactly once")

      clock._now = 53
      local lines = Slash.run("debug cues")
      assert.is_false(hasLineMatching(lines, "last fired=never"))
      assert.is_true(hasLineMatching(lines, "last fired=3%.0s ago"))
    end)

    it("'debug cues 1' test-fires cue 1 and flares exactly once", function()
      local lines = Slash.run("debug cues 1")
      assert.equal(1, calls)
      assert.is_true(hasLineMatching(lines, "^test%-fired: Exorcism up$"))
    end)

    -- Fixed defect: `tonumber(index) or 1` silently fired cue 1 and attributed the flare to it for
    -- any non-numeric argument. The fix must refuse instead of guessing.
    it("regression: 'debug cues zzz' does not flare and reports it is not a cue number", function()
      local lines = Slash.run("debug cues zzz")
      assert.equal(0, calls, "a non-numeric argument must never flare any cue")
      assert.is_true(hasLineMatching(lines, "not a cue number: zzz"))
    end)

    -- Fixed defect: test-firing an event="check" cue printed a bare "test-fired: Seal dropped",
    -- which contradicts the options screen telling the user that cue cannot fire (ADR-0009). The
    -- renderer test still flares (that is the point of the command), but the line must say so.
    it("regression: test-firing the check cue still flares but says it will not fire in play", function()
      local lines = Slash.run("debug cues 2")
      assert.equal(1, calls, "TestFire answers \"can this edge flare at all\" even for an unavailable cue")
      assert.is_true(hasLineMatching(lines, "^test%-fired: Seal dropped %(needs readiness checks %(M5b%)"))
      assert.is_true(hasLineMatching(lines, "will not fire in play%)$"))
    end)

    it("'debug cues 99' reports no such cue and does not flare", function()
      local lines = Slash.run("debug cues 99")
      assert.equal(0, calls)
      assert.is_true(hasLineMatching(lines, "no cue 99"))
    end)

    -- Mutation regression: a cue that is off must be REPORTED as off, never as on. This is the
    -- diagnostic command's whole job — a cue that reads "on" while actually disabled is a
    -- diagnostic lying about the thing it exists to diagnose. Cue 1 is fireable (now_slot) but is
    -- never passed to enableCue() in this test, so it stays out of the profile entirely.
    it("an off cue is reported as off, never as on", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "1%. Exorcism up"))
      assert.is_false(hasLineMatching(lines, "on  edge="),
        "a cue that was never enabled must not render as on")
      assert.is_true(hasLineMatching(lines, "^   off"))
    end)

    -- Mutation regression: when a build suggests zero cues, the command must SAY so rather than
    -- silently printing nothing past the header line — an empty list and "nothing to report" look
    -- identical on screen otherwise.
    it("says the build suggests no cues when its cue list is empty", function()
      ns.Display.activeBuild = function() return { visuals = { cues = {} } } end
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "no cues"))
    end)

    -- Mutation regression: the header line is the only place the build key and now-slot are named,
    -- which is what makes a stale/wrong build diagnosable at all. Checked as substrings (information
    -- content), not the exact line format.
    it("names the build key and now-slot on the header line", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      enableCue("now_slot:EXORCISM")
      ns.Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "build=PALADIN_EXODIN"))
      assert.is_true(hasLineMatching(lines, "now%-slot=EXORCISM"))
    end)

    -- Mutation regression: the output must tell the user how to test-fire a cue, or the feature is
    -- undiscoverable from inside the command that lists the cues.
    it("tells the user how to test-fire a cue", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "test%-fires"))
    end)
  end)
end)
