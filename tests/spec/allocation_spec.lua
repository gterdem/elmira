-- tests/spec/allocation_spec.lua — the render loop, end to end, must not allocate while nothing
-- changes.
--
-- The whole stack the client runs -- the real adapter over the mock, the shipped paladin pack, the
-- real Simulation, Ticker and Driver -- ticked with a MOVING clock and the collector stopped. The
-- moving clock is the point. An earlier benchmark of this same stack reported 0.016 KB per frame and
-- concluded the growth the client showed (~110 KB/s) could not be ours; its clock never advanced, so
-- Core/Ticker skipped every tick and every per-frame memo hit for ever. With the clock moving the
-- same stack allocated 21.5 KB per recompute, and the client's 32 KB was that plus its own overhead.
--
-- The number below is a gate, not a measurement: a change that puts an allocation back on the
-- steady-state path fails here, not in game three round trips later.
local helper = require("tests.helper")
local mock = require("tests.wow_mock")

describe("the render loop allocates nothing on a steady rotation", function()
  local ns, Display

  local function loadStack()
    mock.reset()
    ns = helper.reset()
    ns.log = function() end
    for _, path in ipairs({
      "Elmira/Adapters/Interface.lua", "Elmira/Adapters/Vanilla.lua", "Elmira/Core/Schema.lua",
      "Elmira/Core/Engine.lua", "Elmira/Core/Simulation.lua", "Elmira/Core/Ticker.lua",
      "Elmira/Core/Visibility.lua", "Elmira/Core/Profiles.lua", "Elmira/Core/UserBuilds.lua",
      "Elmira/Core/API.lua", "Elmira/Core/Packs.lua", "Elmira/Core/Slash.lua", "Elmira/Display/Driver.lua",
    }) do helper.load(path) end
    Display = ns.Display
    local pack = helper.classPack("Paladin")
    ns.API.RegisterDataPack(pack)
    ns.Adapter.attachPack(pack)
    ns.now = function() return GetTime() end
    ns.db = { profile = { enabled = true, depth = 5, visibility = "always", activeBuild = "PALADIN_SHOCKADIN" },
              global = { userBuilds = {} } }
    -- A character with plenty to read: every non-rune spell known, fifteen buffs, nineteen items.
    for _, rec in pairs(pack.spells) do
      if type(rec) == "table" and rec.id and not rec.rune and not rec.aura then mock.knownSpells[rec.id] = true end
    end
    for i = 1, 15 do mock.auras.player[i] = { name = "Buff" .. i, spellID = 900000 + i } end
    for slot = 1, 19 do mock.inventory[slot] = 100000 + slot end
    mock.targetExists = false
    return pack
  end

  local function tick(dt)
    mock.time = mock.time + dt
    return Display.tick(mock.time)
  end

  before_each(loadStack)

  it("recomputes on every tick of a moving clock -- the property the old benchmark lacked", function()
    tick(0.3)
    local outcomes = {}
    for _ = 1, 10 do outcomes[tick(0.3)] = true end
    assert.is_nil(outcomes.skipped, "a moving clock past IDLE_REFRESH must recompute, not skip")
  end)

  it("allocates under half a kilobyte across a hundred recomputes once warm", function()
    for _ = 1, 3 do tick(0.3) end                 -- the memo fills, the buffers exist
    local changed = 0
    local kb = helper.allocatedKB(function()
      for _ = 1, 100 do
        if tick(0.3) ~= "unchanged" then changed = changed + 1 end
      end
    end)
    assert.equal(0, changed, "every steady tick recomputes and finds the same queue")
    assert.is_true(kb == nil or kb < 0.5,
      string.format("100 steady recomputes allocated %.2f KB (%.3f KB each)", kb or 0, (kb or 0) / 100))
  end)

  it("retains nothing across three thousand ticks", function()
    for _ = 1, 3 do tick(0.3) end
    collectgarbage("collect"); collectgarbage("collect")
    local base = collectgarbage("count")
    for _ = 1, 3000 do tick(0.3) end
    collectgarbage("collect"); collectgarbage("collect")
    local grew = collectgarbage("count") - base
    assert.is_true(grew < 1, string.format("retained %.2f KB across 3000 ticks", grew))
  end)

  it("would have caught the frozen clock: the same ticks with dt = 0 never recompute", function()
    tick(0.3)
    for _ = 1, 10 do assert.equal("skipped", tick(0)) end
  end)
end)
