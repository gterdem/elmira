-- tests/spec/builtin_packs_spec.lua — Elmira/Core/Packs.lua, the built-in class-pack registry
-- (ADR-0011). Pure Core, no WoW globals: tests/fake_state.lua's world, never tests/wow_mock.lua.
--
-- Two things this file exists to pin:
--   1. Packs.RegisterBuiltinPack / Packs.BuiltinPack behave exactly as ADR-0011 §2 requires: a
--      rejected registration never errors, and a broken class file disables only that class.
--   2. The load-time STRUCTURAL property the whole ADR is built on and which nothing else in the
--      suite checks: every file under Elmira/Classes/ registers exactly one pack, and it is a
--      FUNCTION. A file that built its tables at the top level would still "work" (Init would hand
--      the table straight to RegisterDataPack) while silently costing every character every class's
--      data — a defect invisible to anything that only calls the registered value, which is why this
--      asserts on the raw, UNCALLED registration (helper.classRegistrations), never on classPack().
local helper = require("tests.helper")

describe("Core.Packs (ADR-0011 built-in class-pack registry)", function()
  local ns, Packs, logged

  before_each(function()
    ns = helper.reset()
    logged = {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    Packs = helper.load("Elmira/Core/Packs.lua")
  end)

  -- helper.load always hands the chunk an explicit `ns` table, so every test above exercises Packs.lua
  -- with `ns` already truthy — the `ns = ns or _G.__ELM_NS or {}` fallback on line 6 never actually
  -- runs under that call shape, which is why it survives `make mutants` there. This bypasses
  -- helper.load specifically to invoke the module the way the client does when a file's own varargs
  -- carry no ns (docs/04, the shared-`ns`-across-files idiom): with only the addon name.
  it("falls back to the shared _G.__ELM_NS table when loaded with no ns argument at all", function()
    _G.__ELM_NS = { log = function() end }
    local chunk = assert(loadfile("Elmira/Core/Packs.lua"))
    local ok, PacksViaFallback = pcall(chunk, "Elmira")
    assert.is_true(ok, "without the ns-or-fallback line, `ns.Packs = Packs` indexes a nil ns and errors")
    assert.equal(_G.__ELM_NS.Packs, PacksViaFallback,
      "the fallback ns must be the SAME table the module publishes onto")
    _G.__ELM_NS = nil
  end)

  describe("RegisterBuiltinPack(class, thunk)", function()
    it("stores the thunk itself, unevaluated, and reports success", function()
      local thunk = function() return { marker = true } end
      local ok = Packs.RegisterBuiltinPack("PALADIN", thunk)
      assert.is_true(ok)
      assert.equal(thunk, Packs.builtin.PALADIN, "must store the function, not call it or wrap it")
    end)

    it("rejects a non-string class without storing anything or erroring", function()
      local ok, reason = Packs.RegisterBuiltinPack(42, function() return {} end)
      assert.is_false(ok)
      assert.is_string(reason)
      assert.is_nil(Packs.builtin[42])
      assert.equal(1, #logged, "a rejection must be logged exactly once")
      assert.truthy(logged[1]:find("class must be a non-empty string", 1, true),
        "log text: " .. tostring(logged[1]))
    end)

    it("rejects an empty-string class", function()
      local ok, reason = Packs.RegisterBuiltinPack("", function() return {} end)
      assert.is_false(ok)
      assert.equal("class must be a non-empty string", reason)
      assert.truthy(logged[1]:find("class must be a non-empty string", 1, true))
    end)

    it("rejects a non-function thunk, naming the class and the actual type it got", function()
      local ok, reason = Packs.RegisterBuiltinPack("PALADIN", { not_a = "function" })
      assert.is_false(ok)
      assert.equal("data must be a function", reason)
      assert.is_nil(Packs.builtin.PALADIN)
      -- Arguments, not just occurrence: this is the exact %s/%s the source formats, and a mutation
      -- that drops or swaps either argument (class, type(thunk)) must fail this line, not merely
      -- "some log happened".
      assert.equal(1, #logged)
      assert.equal(
        "Elmira: built-in pack for PALADIN rejected (data must be a function, got table)",
        logged[1])
    end)

    it("rejects a nil thunk the same way, with type 'nil' in the message", function()
      local ok = Packs.RegisterBuiltinPack("MAGE", nil)
      assert.is_false(ok)
      assert.equal(
        "Elmira: built-in pack for MAGE rejected (data must be a function, got nil)",
        logged[1])
    end)

    it("never errors on any malformed input", function()
      local ok1 = pcall(Packs.RegisterBuiltinPack, nil, nil)
      local ok2 = pcall(Packs.RegisterBuiltinPack, {}, "not a function either")
      assert.is_true(ok1)
      assert.is_true(ok2)
    end)
  end)

  describe("BuiltinPack(class)", function()
    it("returns the built pack table for a registered class", function()
      Packs.RegisterBuiltinPack("PALADIN", function() return { class = "PALADIN", spells = {} } end)
      local pack = Packs.BuiltinPack("PALADIN")
      assert.is_table(pack)
      assert.equal("PALADIN", pack.class)
    end)

    it("returns nil for a class nothing registered, and logs nothing", function()
      assert.is_nil(Packs.BuiltinPack("WARRIOR"))
      assert.same({}, logged)
    end)

    it("returns nil for a nil class, and logs nothing", function()
      assert.is_nil(Packs.BuiltinPack(nil))
      assert.same({}, logged)
    end)

    it("returns nil and logs the class and the error when the thunk errors", function()
      Packs.RegisterBuiltinPack("PALADIN", function() error("gear table exploded") end)
      local pack = Packs.BuiltinPack("PALADIN")
      assert.is_nil(pack)
      assert.equal(1, #logged)
      assert.truthy(logged[1]:find("PALADIN", 1, true), "log must name the class: " .. logged[1])
      assert.truthy(logged[1]:find("gear table exploded", 1, true),
        "log must carry pcall's own error text: " .. logged[1])
    end)

    it("returns nil and logs the class and the wrong type when the thunk returns a non-table", function()
      Packs.RegisterBuiltinPack("MAGE", function() return "not a pack" end)
      local pack = Packs.BuiltinPack("MAGE")
      assert.is_nil(pack)
      assert.equal(1, #logged)
      assert.equal("Elmira: built-in MAGE pack returned string, not a table", logged[1])
    end)

    it("returns nil when the thunk returns nothing at all", function()
      Packs.RegisterBuiltinPack("MAGE", function() end)
      assert.is_nil(Packs.BuiltinPack("MAGE"))
      assert.equal("Elmira: built-in MAGE pack returned nil, not a table", logged[1])
    end)

    it("a broken class file disables only that class, not the whole registry", function()
      Packs.RegisterBuiltinPack("PALADIN", function() error("boom") end)
      Packs.RegisterBuiltinPack("MAGE", function() return { class = "MAGE" } end)
      assert.is_nil(Packs.BuiltinPack("PALADIN"))
      local mage = Packs.BuiltinPack("MAGE")
      assert.is_table(mage)
      assert.equal("MAGE", mage.class)
    end)

    it("calls the thunk fresh every time rather than caching the result", function()
      local calls = 0
      Packs.RegisterBuiltinPack("PALADIN", function() calls = calls + 1; return { n = calls } end)
      local a = Packs.BuiltinPack("PALADIN")
      local b = Packs.BuiltinPack("PALADIN")
      assert.equal(2, calls)
      assert.equal(1, a.n)
      assert.equal(2, b.n)
    end)
  end)

  -- ============================================================ the ADR-0011 structural property
  -- Nothing else in the suite drives this off DISCOVERY. data_sourcing_spec.lua globs
  -- Elmira/Classes/*.lua too, but only to police id-sourcing text; it never asserts the registered
  -- VALUE is a function rather than a table, which is the one property ADR-0011 §2's whole memory
  -- argument depends on.
  describe("every shipped Elmira/Classes/*.lua registers exactly one FUNCTION pack (ADR-0011 §2)", function()
    it("discovers at least one class file — a glob finding nothing makes everything below vacuous", function()
      local files = helper.classFiles()
      assert.is_true(#files > 0,
        "helper.classFiles() found nothing under Elmira/Classes/; every assertion in this describe "
        .. "block would otherwise pass on zero files checked")
    end)

    -- The registered value being a function is NECESSARY but not SUFFICIENT, and the difference is
    -- the whole ADR. A file can register a perfectly good thunk that merely RETURNS a table built at
    -- file scope -- every character still pays for every class, and the assertion above still passes.
    -- An audit reproduced exactly that and the suite stayed at 896/0.
    --
    -- So measure the thing the ADR is actually about: allocation. Compile first (the chunk's
    -- constants -- every id, every src URL -- are allocated by loadfile, and are not what we are
    -- measuring), then weigh executing the file scope against calling the thunk. A correct file
    -- allocates a closure at load and its tables only when called, so load cost is a small fraction
    -- of call cost. Hoisting the tables inverts that ratio, which is why this is a ratio and not a
    -- byte threshold: it holds as the data grows, and it needs no tuning when a class is added.
    local function loadVsCallKB(path)
      local chunk = assert(loadfile(path), path .. " does not load")
      local registered
      -- Named `packNs`, not `ns`: the outer describe already holds an `ns` upvalue, and shadowing it
      -- is a luacheck warning -- which makes `make lint` exit nonzero for a reason that has nothing
      -- to do with the gates, and silently satisfies every selftest case that asserts only "lint
      -- failed". Three of them did exactly that until this was found.
      local packNs = { RegisterBuiltinPack = function(_, value) registered = value end }

      collectgarbage("collect"); collectgarbage("collect")
      local before = collectgarbage("count")
      chunk("Elmira", packNs)                   -- file scope: registration only, if the ADR holds
      collectgarbage("collect"); collectgarbage("collect")
      local afterLoad = collectgarbage("count")
      assert(type(registered) == "function", path .. " registered no thunk")
      local pack = registered()                 -- the tables get built here, or they were cheating
      collectgarbage("collect"); collectgarbage("collect")
      local afterCall = collectgarbage("count")

      -- Keep the pack reachable across the final measurement, or the collector may reclaim it and
      -- report the call as free -- which would make this test pass for the wrong reason.
      assert.is_table(pack)
      return afterLoad - before, afterCall - afterLoad
    end

    it("builds its tables when CALLED, not when loaded (ADR-0011 §2's actual claim)", function()
      local files = helper.classFiles()
      assert.is_true(#files > 0, "no class files discovered")
      for _, path in ipairs(files) do
        local loadKB, callKB = loadVsCallKB(path)
        -- The data is hundreds of rows, so calling must cost real memory. Without this the ratio
        -- below could be satisfied by a file that allocates nothing anywhere.
        assert.is_true(callKB > 10,
          path .. ": calling the thunk allocated only " .. string.format("%.1f", callKB) ..
          " KB; too little for this test to mean anything -- has the data moved elsewhere?")
        assert.is_true(loadKB < callKB * 0.25,
          path .. ": loading the file allocated " .. string.format("%.1f", loadKB) ..
          " KB against " .. string.format("%.1f", callKB) .. " KB to call the thunk. Tables are " ..
          "being constructed at FILE SCOPE, so every character pays for every class (ADR-0011 §2).")
      end
    end)

    it("registers exactly one pack per file, and it is a function, not a table", function()
      local files = helper.classFiles()
      assert.is_true(#files > 0, "no class files discovered")
      for _, path in ipairs(files) do
        local registrations = helper.classRegistrations(path)
        assert.equal(1, #registrations,
          path .. " must call RegisterBuiltinPack exactly once (got " .. #registrations .. ")")
        local reg = registrations[1]
        assert.is_string(reg.class)
        assert.is_true(#reg.class > 0, path .. " registered an empty class key")
        assert.equal("function", type(reg.value),
          path .. " registered a " .. type(reg.value)
          .. ", not a thunk -- this is the exact defect ADR-0011 §2 needs caught: a table built at "
          .. "file scope costs every character every class's data")
      end
    end)
  end)
end)
