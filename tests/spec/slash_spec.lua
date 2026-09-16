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

    it("export names a missing key", function()
      assert.truthy(Slash.run("export GHOST")[1]:find("GHOST", 1, true))
    end)

    -- PF-D7: export has no pack precondition of its own any more -- with no pack it still resolves
    -- the active key and asks UserBuilds, which is what actually names the failure.
    it("works with no pack for the class, reporting UserBuilds' own failure rather than a blanket refusal", function()
      ns.Display.currentPack = function() return nil end
      local lines = Slash.run("export")
      assert.is_falsy(lines[1]:find("no data pack", 1, true))
      assert.truthy(lines[1]:find("PALADIN_EXODIN", 1, true))
    end)

    it("still says there is no active build once the Display module itself is gone", function()
      ns.Display = nil
      assert.truthy(Slash.run("export")[1]:find("no active build", 1, true))
    end)

    -- AB4-D5: how many ability settings came with the rotation, the way the options window has
    -- said since AB2-D5. Settings that arrived silently and overwrote a glow colour are the worst
    -- possible surprise, and settings that did NOT arrive look identical from the chat frame.
    --
    -- The bundled string comes from the Share tab's "export with its abilities' settings"; a plain
    -- `/elm export` carries no settings, which is what the second test here holds.
    it("import reports the ability settings that travelled with the rotation", function()
      ns.db.char = { abilities = {} }
      helper.load("Elmira/Core/AbilitySettings.lua")
      local str = ns.UserBuilds.exportKey(pack, "PALADIN_EXODIN", {
        abilities = { EXORCISM = { glow = { color = { r = 1, g = 0, b = 0 } } },
                      JUDGEMENT = { edge = { enabled = true } } },
        spells = { EXORCISM = { id = 415073, name = "Exorcism" } },
      })
      local line = Slash.run("import " .. str .. " shared")[1]
      assert.truthy(line:find("Also merged the settings of 2 abilities", 1, true))
      assert.same({ r = 1, g = 0, b = 0 }, ns.db.char.abilities.EXORCISM.glow.color)
    end)

    it("import says nothing about settings when a rotation carried none", function()
      local str = Slash.run("export PALADIN_WRATHLIKE")[2]
      assert.is_nil(Slash.run("import " .. str .. " bare")[1]:find("Also merged", 1, true))
    end)

    it("import stores a fork, dated, and the profile command then knows it", function()
      local str = Slash.run("export PALADIN_WRATHLIKE")[2]
      local lines = Slash.run("import " .. str .. " my wrath")
      assert.truthy(lines[1]:find("Imported as USER_MY_WRATH", 1, true))
      assert.equal("2026-09-03", ns.db.global.userBuilds.USER_MY_WRATH.importedAt)
      -- The FIRST line only ("Builds: ..."): the second line ("Active: PALADIN_EXODIN (...)") names
      -- PALADIN_EXODIN regardless of this list, which would make that assertion pass even with the
      -- shipped-builds loop deleted outright.
      local builds = Slash.run("profile")[1]
      assert.truthy(builds:find("USER_MY_WRATH", 1, true))
      -- The shipped builds themselves, from pack.builds -- not only the user's own fork.
      assert.truthy(builds:find("PALADIN_EXODIN", 1, true), builds)
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

  -- Options.lua's General page reads this instead of walking `entries` itself: it is what keeps the
  -- panel's list from drifting away from what `/elm` actually offers.
  describe("Slash.availableEntries", function()
    it("lists every command except the unavailableNamed placeholders", function()
      local rows = Slash.availableEntries()
      local keys = {}
      for _, r in ipairs(rows) do keys[r.key] = r.desc end
      assert.is_string(keys.help)
      assert.is_string(keys.rotation)
      assert.is_nil(keys.sim, "sim is not available yet and must not be listed")
      assert.is_nil(keys.history, "history is not available yet and must not be listed")
      assert.is_nil(keys.rotdiag, "rotdiag is not available yet and must not be listed")
    end)

    -- /elm help lists every command, including the unavailableNamed placeholders; availableEntries
    -- must appear as a SUBSEQUENCE of it, in the same order, or a command that moves in the
    -- registration order would silently reorder on one list and not the other.
    it("keeps the same relative order as /elm help, for the entries it lists", function()
      local order = {}
      for _, line in ipairs(Slash.help()) do
        local verb = line:match("^%s%s(%S+)")
        if verb then order[#order + 1] = verb end
      end
      local listed = {}
      for _, r in ipairs(Slash.availableEntries()) do listed[#listed + 1] = r.key end
      assert.is_true(#listed > 0)
      local matched = 0
      for _, verb in ipairs(order) do
        if listed[matched + 1] == verb then matched = matched + 1 end
      end
      assert.equal(#listed, matched, "availableEntries drifted from /elm help's own order")
    end)
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

  it("'debug' with no subcommand returns the usage line, naming every sub-report", function()
    local lines = Slash.run("debug")
    assert.is_true(hasLineMatching(lines, "^Usage: /elm debug"))
    -- A diagnostic nothing points at is a diagnostic nobody runs.
    assert.is_true(hasLineMatching(lines, "cues|textures"))
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

  -- AB1-D3: the glow's style is a per-ability setting, so this line reports the All abilities one
  -- -- what an ability that has been given none of its own draws in. It used to read
  -- `profile.glow.style`, which is not a key any more and printed "style=nil".
  it("'debug bars' reports the All abilities glow style, not a profile key that is gone", function()
    local ns = _G.__ELM_NS
    ns.db = { profile = { glow = { barGlow = true } }, char = { abilities = {} } }
    ns.Glow = { styleFor = function() return "AUTOCAST" end, activeCount = function() return 2 end }
    local lines = Slash.run("debug bars")
    assert.is_true(hasLineMatching(lines, "glow: barGlow=true style=AUTOCAST active=2"))
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

  -- FX1-D5. Every Move mode hides the options window for as long as it runs, so "my configuration
  -- window vanished" is a real question a player can arrive with -- and the little bar that says
  -- what is being moved is exactly the thing they will have missed. `/elm debug state` answers it.
  describe("'debug state' and the Move modes", function()
    before_each(function()
      _G.__ELM_NS.Adapter = { describe = function()
        return { project = 2, version = "1.15.7", interface = 11509,
                 caps = { glow = true }, state = "ready" }
      end }
    end)

    it("says nothing is being moved when no Move mode is running", function()
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^moving: nothing$"))
      -- ...and with Options loaded but idle, which is the ordinary case.
      _G.__ELM_NS.Options = { moveSubject = function() return nil end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^moving: nothing$"))
    end)

    it("names what is being moved while a Move mode has the window off the screen", function()
      _G.__ELM_NS.Options = { moveSubject = function() return "the indicator row" end }
      local lines = Slash.run("debug state")
      assert.is_true(hasLineMatching(lines, "^moving: the indicator row$"))
      assert.is_false(hasLineMatching(lines, "^moving: nothing$"))
    end)

    -- FX2-D3. The owner reported the window's header losing its version text and its full-width
    -- drag bar, and answering "is it dressed right now" needed a screenshot. This is the line that
    -- replaces the screenshot.
    it("says whether the window on screen still has its title bar and version", function()
      _G.__ELM_NS.Options = { chromeState = function() return "dressed" end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^window chrome: dressed$"))
      _G.__ELM_NS.Options = { chromeState = function() return "stripped" end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^window chrome: stripped$"))
    end)

    it("says so plainly when there is no standalone window to inspect", function()
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^window chrome: no window open$"))
      -- ...and with Options loaded but no window up, which is what chromeState answers with nil.
      _G.__ELM_NS.Options = { chromeState = function() return nil end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^window chrome: no window open$"))
    end)
  end)

  -- AT7-D5: a rank mismatch -- a registry entry whose stored id no longer matches what this
  -- character's spellbook currently resolves for its name -- has to be visible from one command.
  describe("'debug state' lists ability ranks (AT7-D5)", function()
    before_each(function()
      _G.__ELM_NS.Adapter = { describe = function()
        return { project = 2, version = "1.15.7", interface = 11509, caps = {}, state = "ready" }
      end }
      helper.load("Elmira/Core/Spells.lua")
    end)

    it("adds nothing at all with no registry entries", function()
      _G.__ELM_NS.db = { char = { spells = {} } }
      assert.is_false(hasLineMatching(Slash.run("debug state"), "^abilities"))
    end)

    it("names every entry, its stored id and what the spellbook answers now", function()
      _G.__ELM_NS.db = { char = { spells = {
        EXORCISM = { key = "EXORCISM", id = 415072, name = "Exorcism", source = "id" },
      } } }
      _G.__ELM_NS.Adapter.spellIDByName = function(name) return name == "Exorcism" and 415073 or nil end
      local lines = Slash.run("debug state")
      assert.is_true(hasLineMatching(lines, "^abilities %(name: stored id %-> spellbook now%):$"))
      -- AT9-D3: and whether anything has ever seen this ability buff you. "unknown" is the honest
      -- answer for a registry entry no pack flagged and nobody has cast yet.
      assert.is_true(hasLineMatching(lines,
        "Exorcism: 415072 %-> 415073  has buff: unknown  <%- MISMATCH$"))
    end)

    it("flags nothing when the stored id already matches the spellbook", function()
      _G.__ELM_NS.db = { char = { spells = {
        EXORCISM = { key = "EXORCISM", id = 415073, name = "Exorcism", source = "id" },
      } } }
      _G.__ELM_NS.Adapter.spellIDByName = function() return 415073 end
      local lines = Slash.run("debug state")
      assert.is_true(hasLineMatching(lines, "Exorcism: 415073 %-> 415073  has buff: unknown$"))
      assert.is_false(hasLineMatching(lines, "MISMATCH"))
    end)

    it("calls a pack entry on another rank expected, not a mismatch, and says when a spell is not known", function()
      _G.__ELM_NS.db = { char = { spells = {
        HOLY_SHOCK = { key = "HOLY_SHOCK", id = 20473, name = "Holy Shock", source = "pack" },
        HOLY_SHIELD = { key = "HOLY_SHIELD", id = 20928, name = "Holy Shield", source = "pack" },
      } } }
      _G.__ELM_NS.Adapter.spellIDByName = function(name) return name == "Holy Shock" and 20930 or nil end
      local lines = Slash.run("debug state")
      assert.is_true(hasLineMatching(lines, "Holy Shock: 20473 %-> 20930  has buff: unknown  %(another rank; the pack id is kept, matched by name%)$"))
      assert.is_true(hasLineMatching(lines, "Holy Shield: 20928 %-> nil  has buff: unknown  %(not known on this character%)$"))
      assert.is_false(hasLineMatching(lines, "MISMATCH"))
    end)

    -- AT9-D3: "has buff" has to actually consult AbilitySettings, not just print "unknown" for
    -- everything -- an ability the tracker has SEEN buff the player reports "learned" here.
    it("says 'learned' once AbilitySettings has seen this ability buff the player", function()
      local A = helper.load("Elmira/Core/AbilitySettings.lua")
      _G.__ELM_NS.db = { char = { abilities = {}, spells = {
        EXORCISM = { key = "EXORCISM", id = 415073, name = "Exorcism", source = "id" },
      } } }
      _G.__ELM_NS.Adapter.spellIDByName = function() return 415073 end
      A.set("EXORCISM", "general", "hasBuff", true)
      local lines = Slash.run("debug state")
      assert.is_true(hasLineMatching(lines, "Exorcism: 415073 %-> 415073  has buff: learned$"))
    end)

    it("copes with no spellbook answer at all, without erroring", function()
      _G.__ELM_NS.db = { char = { spells = {
        EXORCISM = { key = "EXORCISM", id = 415073, name = "Exorcism", source = "id" },
      } } }
      local lines
      assert.has_no.errors(function() lines = Slash.run("debug state") end)
      assert.is_true(hasLineMatching(lines, "Exorcism: 415073 %-> nil  has buff: unknown  %(not known on this character%)$"))
    end)
  end)

  -- M5a-i-D4: the reading every `enemies`/`mode` condition and Auto mode currently see.
  describe("'debug state' shows the enemy count (M5a-i-D4)", function()
    before_each(function()
      _G.__ELM_NS.Adapter = { describe = function()
        return { project = 2, version = "1.15.7", interface = 11509, caps = {}, state = "ready" }
      end }
    end)

    it("adds no Enemies line at all when there is no live state to ask", function()
      assert.is_false(hasLineMatching(Slash.run("debug state"), "^Enemies"))
    end)

    it("shows the count when the state answers a number", function()
      local ns = helper.ns()
      ns.API = { GetState = function() return { enemies = function() return 3 end } end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^Enemies: 3$"))
    end)

    it("says nameplates off rather than a number when the state cannot answer", function()
      local ns = helper.ns()
      ns.API = { GetState = function() return { enemies = function() return nil end } end }
      assert.is_true(hasLineMatching(Slash.run("debug state"), "^Enemies: nameplates off$"))
    end)

    it("says nameplates off rather than erroring when the accessor itself errors", function()
      local ns = helper.ns()
      ns.API = { GetState = function() return { enemies = function() error("nope") end } end }
      local lines
      assert.has_no.errors(function() lines = Slash.run("debug state") end)
      assert.is_true(hasLineMatching(lines, "^Enemies: nameplates off$"))
    end)
  end)

  describe("'debug enemies'", function()
    it("says the adapter is not loaded when it has no enemyDebugCounts", function()
      assert.equal("enemies: adapter not loaded", Slash.run("debug enemies")[1])
    end)

    it("reports plates seen, attackable and in combat", function()
      local ns = helper.ns()
      ns.Adapter = { enemyDebugCounts = function()
        return { seen = 5, attackable = 4, inCombat = 3, nameplatesOn = true }
      end }
      local lines = Slash.run("debug enemies")
      assert.is_true(hasLineMatching(lines, "^enemies: 5 plate%(s%) seen, 4 attackable, 3 in combat$"))
      assert.equal(2, #lines)
      assert.is_true(hasLineMatching(lines, "in combat.* is the number every"))
    end)

    it("says nameplates are off instead of a zeroed-out count", function()
      local ns = helper.ns()
      ns.Adapter = { enemyDebugCounts = function()
        return { seen = 0, attackable = 0, inCombat = 0, nameplatesOn = false }
      end }
      local line = Slash.run("debug enemies")[1]
      assert.is_true(line:find("nameplates are off", 1, true) ~= nil)
    end)
  end)

  describe("'mode' (M5a-i-D2)", function()
    it("says it is not loaded when RotationMode is not loaded", function()
      assert.equal("mode: not loaded", Slash.run("mode")[1])
    end)

    describe("with RotationMode loaded", function()
      local ns
      before_each(function()
        ns = helper.ns()
        ns.db = { char = {} }
        ns.RotationMode = helper.load("Elmira/Core/RotationMode.lua")
      end)

      it("reports the current mode and usage with no argument", function()
        local line = Slash.run("mode")[1]
        assert.is_true(line:find("Rotation mode: Auto", 1, true) ~= nil)
        assert.is_true(line:find("Usage", 1, true) ~= nil)
      end)

      it("forces a mode, case-insensitively, and confirms it", function()
        assert.equal("Rotation mode: AoE.", Slash.run("mode aoe")[1])
        assert.equal("AoE", ns.db.char.rotationMode)
        assert.equal("Rotation mode: Cleave.", Slash.run("mode CLEAVE")[1])
        assert.equal("Cleave", ns.db.char.rotationMode)
      end)

      it("returns to Auto", function()
        Slash.run("mode single")
        assert.equal("Rotation mode: Auto.", Slash.run("mode auto")[1])
        assert.equal("Auto", ns.db.char.rotationMode)
      end)

      it("rejects an unrecognised mode and changes nothing", function()
        ns.db.char.rotationMode = "Cleave"
        local line = Slash.run("mode nonsense")[1]
        assert.is_true(line:find("No mode", 1, true) ~= nil)
        assert.equal("Cleave", ns.db.char.rotationMode)
      end)
    end)
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

  -- D39: the setup wizard window is gone (R1); 'setup' is now an alias of 'rotation'. Rewritten
  -- rather than deleted: the property worth keeping is that the command DEGRADES with a designed
  -- line instead of erroring when Options is not loaded, which is what this spec's Core-only harness
  -- reproduces.
  it("'setup' is an alias of 'rotation' and degrades the same way when Options is not loaded", function()
    local lines = Slash.run("setup")
    assert.equal(1, #lines)
    assert.equal("setup: options are not loaded", lines[1])
  end)

  it("'setup' opens the Rotations tree, same as 'rotation'", function()
    local opened
    _G.__ELM_NS.Options = { Open = function(...) opened = { ... }; return true end }
    local lines = Slash.run("setup")
    assert.same({ "rotation" }, opened)
    assert.equal("Opening your rotations.", lines[1])
  end)

  -- PF-D7: 'profile' dropped its pack precondition -- with no pack and no Display module at all it
  -- still lists (empty) rather than refusing outright. 'advise' reads pack-only gear data and keeps
  -- its own, earlier refusal (the advisor module is not loaded here at all).
  it("'profile' lists rather than refusing with no pack, and 'advise' still degrades without erroring", function()
    assert.equal("Builds: ", Slash.run("profile")[1])
    assert.equal("advise: the advisor is not loaded", Slash.run("advise")[1])
  end)

  -- PF-D7: gear advice lives on the pack's own `advice` table, so 'advise' keeps its refusal on a
  -- pack-less class once past its EARLIER "advisor not loaded" guard -- only the wording changed.
  it("'advise' needs a class data pack once the advisor itself is loaded", function()
    local ns = helper.ns()
    ns.Advisor, ns.Detect, ns.API = {}, {}, {}
    ns.Display = { currentPack = function() return nil end }
    assert.equal("advise: needs a class data pack", Slash.run("advise")[1])
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

    -- R2b: `/elm debug queue` compiles against the REAL Schema, so a build naming a registry-only
    -- spell must reach the queue instead of "failed validation" -- the same merge Save uses. The
    -- Simulation stub reads `compiled.entries[1].data` (populated ONLY when `ctx.spells` actually
    -- carried the registry entry) and prints its id into the queue line, which is what actually
    -- distinguishes "compiled against the merged table" from "compiled against nothing at all" --
    -- `Schema.validate` alone cannot: an ABSENT ctx.spells is documented as unchecked, so a build
    -- would "pass validation" either way and a pass/fail assertion alone would not catch a
    -- regression here.
    it("compiles a build naming a registry-only spell instead of failing validation", function()
      local ns = helper.ns()
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Spells.lua")
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.db = { char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } } }
      local pack = { builds = { MY = { schema = 1, key = "MY", name = "Mine", class = "PALADIN",
                                        entries = { { spell = "SLICE" } } } } }
      ns.API = { GetProviders = function() return { PALADIN = pack } end,
                 GetState = function() return { usable = function() return true end,
                                                cooldown = function() return 0 end } end }
      ns.Simulation = { queue = function(compiled)
        local id = compiled.entries[1].data and compiled.entries[1].data.id or -1
        return { { spell = "SLICE", t = id } }
      end }
      local out = table.concat(Slash.run("debug queue MY"), "\n")
      assert.truthy(out:find("queue for MY", 1, true), out)
      assert.falsy(out:find("failed validation", 1, true), out)
      assert.truthy(out:find("t=900.0s", 1, true), out)
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

    -- R2b: the REAL Schema and Spells registry, so a build naming a spell only this character has
    -- registered compiles instead of failing "not in the spells data pack" -- the same merge Save
    -- (Core/UserBuilds.ctxFor) and the live render loop (Display.packContext) use. As above, the
    -- Simulation stub surfaces `compiled.entries[1].data.id` through the returned queue: that field
    -- is populated ONLY from a `ctx.spells` that actually carried the registry entry, which is the
    -- part `error == nil` alone cannot prove (an absent ctx.spells validates too).
    it("compiles a build naming a registry-only spell", function()
      local ns = helper.ns()
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Spells.lua")
      ns.Simulation = { queue = function(compiled)
        local id = compiled.entries[1].data and compiled.entries[1].data.id
        return { { spell = "SLICE", t = id } }
      end }
      ns.API = { GetState = function() return { usable = function() return true end,
                                                cooldown = function() return 0 end,
                                                inCombat = function() return false end } end }
      ns.db = { char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } } }
      local pack = { spells = { EXORCISM = { id = 415073 } },
                     builds = { MY_ROTATION = { schema = 1, key = "MY_ROTATION", name = "Mine",
                                                 class = "PALADIN", entries = { { spell = "SLICE" } } } } }
      local snap = ns.queueSnapshot(pack)
      assert.is_nil(snap.MY_ROTATION.error, snap.MY_ROTATION.error and table.concat(snap.MY_ROTATION.error, " "))
      assert.equal("SLICE", snap.MY_ROTATION.entries[1].spell)
      assert.equal(900, snap.MY_ROTATION.queue[1].t)
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

    -- PF-D7: a mark captures PACK-ONLY data (Collector.snapshot's comparisons), so it keeps its
    -- refusal on a pack-less class -- only the wording changed.
    it("needs a class data pack to record a mark", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset(); ns.Recorder.start(0)
      ns.API = { GetProviders = function() return {} end }
      assert.equal("rec: needs a class data pack", Slash.run("rec mark")[1])
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

  -- PF-D7: `/elm debug dump` reads PACK-ONLY data (Collector.snapshot's comparisons), so it keeps
  -- its refusal on a pack-less class -- only the wording changed.
  describe("debug dump", function()
    it("needs a class data pack", function()
      local ns = helper.ns()
      ns.Collector = { snapshot = function() return {} end }
      ns.Adapter = { playerClass = function() return "ROGUE" end }
      ns.API = { GetProviders = function() return {} end }
      assert.equal("dump: needs a class data pack", Slash.run("debug dump")[1])
    end)
  end)

  -- R2b: `ns.topSuggestions` (the cast log's "what was Elmira saying?" column) compiles against the
  -- same merged ctx as `queueSnapshot`, so a build naming a registry-only spell suggests it rather
  -- than compiling to nothing. As above, the Simulation stub only names the spell when
  -- `compiled.entries[1].data` (populated from the merged `ctx.spells`) is actually present.
  describe("topSuggestions()", function()
    it("suggests a registry-only spell", function()
      local ns = helper.ns()
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Spells.lua")
      ns.Simulation = { queue = function(compiled)
        local resolved = compiled.entries[1].data ~= nil
        return { { spell = resolved and "SLICE" or "UNRESOLVED", t = 0 } }
      end }
      ns.API = { GetState = function() return {} end }
      ns.db = { char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } } }
      local pack = { builds = { MY = { schema = 1, key = "MY", name = "Mine", class = "PALADIN",
                                        entries = { { spell = "SLICE" } } } } }
      local out = ns.topSuggestions(pack)
      assert.equal("SLICE", out.MY)
    end)
  end)

  -- Contract (docs/01-ARCHITECTURE.md §2): ns.now() is the addon's single source of time. It reads
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

    -- PE15-D2. A rune ability the owner does not have was announced as gained and lost three times
    -- in one fight, and nothing could say whether the reading behind it had wobbled or held steady.
    -- EVERY gated spell, not only the dimmed ones: a row the client could not read stays LIVE, so
    -- listing the dimmed rows alone would hide the one case this exists to catch.
    it("says what the client answers right now for every gated spell", function()
      helper.ns().Display = {
        inactiveRows = function() return {}, "PALADIN_EXODIN" end,
        gateRows = function()
          return {}, { { index = 1, spell = "JUDGEMENT", active = true, reasons = {} },
                       { index = 2, spell = "DIVINE_STORM", active = true, reasons = {} },
                       { index = 3, spell = "DIVINE_STORM", active = true, reasons = {} },
                       { index = 4, item = 13, active = true, reasons = {} } }, "PALADIN_EXODIN"
        end,
      }
      helper.ns().API = { GetState = function()
        return { known = function(_, spell)
          if spell == "JUDGEMENT" then return true end
          return nil
        end }
      end }
      local lines = Slash.run("debug gates")
      assert.equal(4, #lines)
      assert.is_truthy(lines[2]:find("cannot tell", 1, true))
      -- Sorted and de-duplicated: one line per spell, in the same order every time.
      assert.equal("  DIVINE_STORM = cannot tell", lines[3])
      assert.equal("  JUDGEMENT = true", lines[4])
    end)

    -- A rotation can gate on items alone (a trinket line, an engineering glove tinker): there is no
    -- spell to ask about, so the section is not printed at all. A bare "known:" heading with
    -- nothing under it reads as "the client answered nothing for everything", which is the opposite
    -- of what it would mean.
    it("prints no known section at all when no gated row names a spell", function()
      helper.ns().Display = {
        inactiveRows = function() return {}, "PALADIN_EXODIN" end,
        gateRows = function()
          return {}, { { index = 1, item = 13, active = true, reasons = {} } }, "PALADIN_EXODIN"
        end,
      }
      helper.ns().API = { GetState = function()
        return { known = function() return true end }
      end }
      local lines = Slash.run("debug gates")
      for _, line in ipairs(lines) do
        assert.is_nil(line:find("known", 1, true), "printed a known section with nothing in it")
      end
    end)

    it("says it has nothing to ask when there is no state", function()
      helper.ns().Display = {
        inactiveRows = function() return {}, "PALADIN_EXODIN" end,
        gateRows = function()
          return {}, { { index = 1, spell = "JUDGEMENT", active = true, reasons = {} } }, "PALADIN_EXODIN"
        end,
      }
      helper.ns().API = { GetState = function() return nil end }
      local lines = Slash.run("debug gates")
      assert.equal("known: no state to ask.", lines[#lines])
    end)
  end)

  it("'debug cues' degrades with a designed line when the overlay is not loaded", function()
    local ns = helper.ns()
    assert.is_nil(ns.Overlay)
    local lines = Slash.run("debug cues")
    assert.same({ "cues: overlay not loaded" }, lines)
  end)

  -- Drives Overlay.lua for real (loaded fresh per test) rather than faking its output: the whole
  -- value of this command is that it reports what the RENDERER will actually do, and a fake would
  -- report what the spec believes instead.
  describe("debug cues", function()
    local ns, A, calls

    before_each(function()
      ns = helper.ns()
      helper.load("Elmira/Core/Spells.lua")
      A = helper.load("Elmira/Core/AbilitySettings.lua")
      helper.load("Elmira/Display/Overlay.lua")
      ns.db = { char = { spells = {}, abilities = {} } }
      ns.Display = { currentPack = function() return { class = "PALADIN",
                       spells = { EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } } } end,
                     spellName = function(key) return key end }
      -- Stubbed so no frame is ever created (Core specs must stay WoW-API-free) and so a flash can
      -- be counted instead of animated.
      calls = 0
      ns.Overlay.Flare = function() calls = calls + 1; return true end
    end)

    it("says so plainly when no ability has its screen edge switched on", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "no ability has its screen edge switched on"))
    end)

    it("names the ability, its edge and the moments it fires on", function()
      A.set("EXORCISM", "edge", "enabled", true)
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "EXORCISM"))
      assert.is_true(hasLineMatching(lines, "edge=left"))
      assert.is_true(hasLineMatching(lines, "fires on: suggested"))
      assert.is_true(hasLineMatching(lines, "last fired=never"))
    end)

    -- The one state that looks exactly like a broken renderer from the outside: switched on, and
    -- firing on nothing.
    it("says when an ability is on but no moment is ticked", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("EXORCISM", "edge", "suggested", false)
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "no event is ticked"))
    end)

    it("reports a real elapsed time once an ability has flashed", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      A.set("EXORCISM", "edge", "enabled", true)
      ns.Overlay.Fire("EXORCISM", "suggested")
      clock._now = 53
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "last fired=3%.0s ago"))
    end)

    it("'debug cues <KEY>' test-fires that ability and flashes exactly once", function()
      local lines = Slash.run("debug cues EXORCISM")
      assert.equal(1, calls)
      assert.is_true(hasLineMatching(lines, "test%-fired: EXORCISM"))
    end)

    -- A switched-off ability still flashes -- the question this answers is "can this edge flash at
    -- all" -- but the line must say so, or it reads as a promise that it will fire in play.
    it("test-firing a switched-off ability says it will not fire in play", function()
      local lines = Slash.run("debug cues EXORCISM")
      assert.equal(1, calls)
      assert.is_true(hasLineMatching(lines, "will not fire in play"))
      A.set("EXORCISM", "edge", "enabled", true)
      lines = Slash.run("debug cues EXORCISM")
      assert.is_false(hasLineMatching(lines, "will not fire in play"))
    end)

    -- Not "default to the first ability": flashing something the user did not name attributes the
    -- flash to the wrong ability, in the one command whose job is to stop exactly that.
    it("refuses a word that is not an ability key, and flashes nothing", function()
      local lines = Slash.run("debug cues zzz")
      assert.equal(0, calls)
      assert.is_true(hasLineMatching(lines, "cannot test%-fire"))
    end)

    -- An ability that HAS flashed is still listed after being switched off, and says which of the
    -- two it is: "it fired earlier and is off now" and "it is on and has never fired" are the two
    -- readings of an empty screen edge that this command exists to separate.
    it("keeps a switched-off ability that has flashed, and says it is off", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      A.set("EXORCISM", "edge", "enabled", true)
      ns.Overlay.Fire("EXORCISM", "suggested")
      A.set("EXORCISM", "edge", "enabled", false)
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "EXORCISM"))
      assert.is_true(hasLineMatching(lines, "off — switch it on"))
      assert.is_false(hasLineMatching(lines, "fires on:"))
    end)

    -- Mutation regression: the output must tell the user how to test-fire one, or the feature is
    -- undiscoverable from inside the command that lists them.
    it("tells the user how to test-fire one", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "test%-fires"))
    end)
  end)

  it("'debug textures' degrades with a designed line when the module is not loaded", function()
    local ns = helper.ns()
    assert.is_nil(ns.Textures)
    assert.same({ "textures: not loaded" }, Slash.run("debug textures"))
  end)

  -- The screen edge's twin (AB3-D1). Drives Display/Textures.lua for real, like the cues block
  -- above and for the same reason: the value of the command is that it reports what the RENDERER
  -- will do, and a fake would report what the spec believes instead.
  describe("debug textures", function()
    local ns, A

    before_each(function()
      ns = helper.ns()
      -- Frames, reduced to "answer every METHOD call": nothing here asserts on one
      -- (tests/spec/textures_spec.lua does), it only has to be creatable.
      --
      -- PascalCase only, the same rule textures_spec and queue_spec use: a catch-all that answers
      -- every key answers `frame.fillDuration` too, and a diagnostic whose whole job is to say
      -- "this fill is measuring nothing" would then report a running swipe on every frame.
      local function method(_, k)
        if type(k) == "string" and k:match("^%u") then
          return function() return setmetatable({}, { __index = method }) end
        end
        return nil
      end
      _G.UIParent = setmetatable({}, { __index = method })
      _G.CreateFrame = function() return setmetatable({}, { __index = method }) end
      helper.load("Elmira/Core/Colors.lua")
      helper.load("Elmira/Core/Spells.lua")
      A = helper.load("Elmira/Core/AbilitySettings.lua")
      helper.load("Elmira/Display/Textures.lua")
      -- AT4-D2: the path library Textures reads to answer "does this file need another addon".
      helper.load("Elmira/Display/TextureLibrary.lua")
      ns.db = { char = { spells = {}, abilities = {} } }
      ns.Display = { currentPack = function() return { class = "PALADIN",
                       spells = { EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } } } end,
                     spellName = function(key) return key end }
    end)

    after_each(function()
      _G.CreateFrame, _G.UIParent = nil, nil
    end)

    it("says that nothing is switched on", function()
      local lines = Slash.run("debug textures")
      assert.is_true(hasLineMatching(lines, "no ability has a texture switched on"))
    end)

    -- AT6-D4: where a texture sits is an offset from the centre of the screen and nothing else, so
    -- the diagnostic reports the two numbers a drag stored rather than a placement mode.
    it("names the ability, its source, size, offset and the moments it appears at", function()
      A.set("EXORCISM", "texture", "enabled", true)
      local lines = Slash.run("debug textures")
      assert.is_true(hasLineMatching(lines, "EXORCISM  source=icon size=48 offset=%+0,%+0 fill=none"))
      assert.is_true(hasLineMatching(lines, "shows on: suggested, active"))
      assert.is_true(hasLineMatching(lines, "last shown=never"))
    end)

    it("reports an offset a drag stored", function()
      A.set("EXORCISM", "texture", "enabled", true)
      A.set("EXORCISM", "texture", "x", -120)
      A.set("EXORCISM", "texture", "y", 260)
      assert.is_true(hasLineMatching(Slash.run("debug textures"), "offset=%-120,%+260"))
    end)

    it("says when an ability is on but appears at no moment", function()
      A.set("EXORCISM", "texture", "enabled", true)
      A.set("EXORCISM", "texture", "suggested", false)
      A.set("EXORCISM", "texture", "active", false)
      assert.is_true(hasLineMatching(Slash.run("debug textures"), "no moment is ticked"))
    end)

    -- The silence a texture has that a screen edge does not: a source that resolves to no file
    -- draws the fallback ring and looks exactly like a working setting.
    it("says when the source resolves to no file at all", function()
      A.set("EXORCISM", "texture", "enabled", true)
      assert.is_true(hasLineMatching(Slash.run("debug textures"), "no file"))
      -- AT4-D2: a file source resolves to the shipped ring even before anything is picked, so
      -- there is nothing left to warn about.
      A.set("EXORCISM", "texture", "source", "path")
      assert.is_false(hasLineMatching(Slash.run("debug textures"), "no file"))
    end)

    -- AT4-D3. A path inside WeakAuras' own folder is a file on the character that has WeakAuras and
    -- nothing at all on the one that does not -- where the ring is drawn instead and looks exactly
    -- like a working setting. The two silences must not read the same.
    it("says when a texture needs an addon this character does not have", function()
      A.set("EXORCISM", "texture", "enabled", true)
      A.set("EXORCISM", "texture", "source", "path")
      A.set("EXORCISM", "texture", "path", "Interface\\AddOns\\WeakAuras\\Media\\Textures\\Ring_10px.tga")
      local lines = Slash.run("debug textures")
      assert.is_true(hasLineMatching(lines, "needs WeakAuras, which is not installed"))
      assert.is_false(hasLineMatching(lines, "no file"), "two warnings about one texture")

      ns.Adapter = { addonLoaded = function(name) return name == "WeakAuras" end }
      assert.is_false(hasLineMatching(Slash.run("debug textures"), "needs WeakAuras"))
    end)

    it("says a switched-off ability is off, and how to switch it on", function()
      ns.Textures.TestFire("EXORCISM")
      assert.is_true(hasLineMatching(Slash.run("debug textures"), "off — switch it on"))
    end)

    it("reports a real elapsed time once a texture has appeared", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      A.set("EXORCISM", "texture", "enabled", true)
      ns.Textures.Fire("EXORCISM", "suggested")
      clock._now = 54
      local lines = Slash.run("debug textures")
      assert.is_true(hasLineMatching(lines, "on screen=true"))
      assert.is_true(hasLineMatching(lines, "last shown=4%.0s ago"))
    end)

    -- AB4-D1. A fill picked for an ability whose cooldown or buff the client has no numbers for
    -- draws nothing at all, and a texture with no swipe on it looks exactly like one whose fill was
    -- never picked.
    it("names the fill, and says when it is measuring nothing", function()
      A.set("EXORCISM", "texture", "enabled", true)
      A.set("EXORCISM", "texture", "fill", "cooldown")
      ns.Textures.Fire("EXORCISM", "suggested")
      local lines = Slash.run("debug textures")
      assert.is_true(hasLineMatching(lines, "fill=cooldown"))
      assert.is_true(hasLineMatching(lines, "nothing to measure right now"))
      -- ...and it stops saying so the moment there IS something to measure.
      ns.Textures.Sync("EXORCISM", { EXORCISM = { cooldown = 4, cooldownFull = 6 } }, 0)
      assert.is_false(hasLineMatching(Slash.run("debug textures"), "nothing to measure right now"))
    end)

    it("says nothing about a fill nobody asked for", function()
      A.set("EXORCISM", "texture", "enabled", true)
      ns.Textures.Fire("EXORCISM", "suggested")
      assert.is_false(hasLineMatching(Slash.run("debug textures"), "nothing to measure right now"))
    end)

    it("'debug textures <KEY>' test-fires that ability, and refuses a word that is not one", function()
      assert.is_true(hasLineMatching(Slash.run("debug textures EXORCISM"), "test%-fired: EXORCISM"))
      assert.is_true(hasLineMatching(Slash.run("debug textures zzz"), "cannot test%-fire"))
    end)

    it("tells the user how to test-fire one", function()
      assert.is_true(hasLineMatching(Slash.run("debug textures"), "test%-fires"))
    end)
  end)
end)
