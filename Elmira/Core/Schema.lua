-- Elmira/Core/Schema.lua — build validation and condition compilation (docs/02-CONDITION-SCHEMA.md,
-- ADR-0002). Pure Lua, no WoW globals: dofile-able headlessly.
--
-- Two entry points:
--   Schema.validate(build, ctx) -> ok, errors   -- never raises; errors name the entry and the field
--   Schema.compile(build, ctx)  -> compiled, errors
--
-- Conditions are compiled to closures once at load rather than walked as tuples every frame. That is
-- ADR-0002, and it is what lets the M3 update loop run at 10 Hz without allocating.
--
-- Predicate signature is f(state, t). `t` is the SIMULATED offset in seconds and is used for exactly
-- one thing: suppressing proc auras for t>0 (docs/02 "Simulation semantics"). Cooldowns are NOT
-- adjusted by t here — Simulation's virtual state already returns remaining cooldown relative to t,
-- so a predicate that consulted both would double-count.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

-- Same guard as Core/API.lua:17. Schema is documented as dofile-able on its own, and Schema.compile
-- reports rejected builds through ns.log — without this, validating a bad build headlessly dies with
-- "attempt to call field 'log' (a nil value)" whenever API.lua has not been loaded first.
ns.log = ns.log or function() end

local Schema = {}
Schema.VERSION = 1

-- Which ctx table each key-taking condition resolves against. A key absent from a data pack that WAS
-- supplied is a validation error (a port to a new flavor fails loudly at load). A ctx table that was
-- not supplied at all is simply not checked — the staged engine_spec passes only `spells`.
local KEY_SOURCE = {
  buff = "spells", no_buff = "spells", debuff = "spells", no_debuff = "spells",
  cooldown_ready = "spells", cooldown_gt = "spells", seal = "spells", seal_linger = "spells",
  rune = "spells", no_rune = "spells",
  set = "sets", bonus = "bonuses",
}

local function inRange(v, min, max)
  if v == nil then return false end
  if min and v < min then return false end
  if max and v > max then return false end
  return true
end

-- ---------------------------------------------------------------- condition implementations
-- Each entry: check(cond, ctx, fail) validates beyond the generic key/type checks; make(cond, ctx)
-- returns the predicate. `make` closes over resolved values so the hot path does no table lookups
-- into ctx.
local C = {}

C.buff = {
  make = function(cond, ctx)
    local key, min = cond[2], cond.min or 1
    local maxRem, minRem = cond.maxRemaining, cond.minRemaining
    local spell = ctx.spells and ctx.spells[key]
    local isProc = spell ~= nil and spell.proc == true
    return function(state, t)
      if isProc and t and t > 0 then return false end -- procs are unpredictable; absent in the future
      local stacks, remaining = state:buff(key)
      if not stacks or stacks < min then return false end
      if maxRem and (remaining == nil or remaining > maxRem) then return false end
      if minRem and (remaining == nil or remaining < minRem) then return false end
      return true
    end
  end,
}

C.no_buff = { make = function(cond)
  local key = cond[2]
  return function(state) return state:buff(key) == nil end
end }

C.debuff = { make = function(cond)
  local key = cond[2]
  local mine = cond.mine
  if mine == nil then mine = true end -- docs/02: defaults to true
  local minRem = cond.minRemaining
  return function(state)
    local stacks, remaining = state:debuff(key, mine)
    if not stacks then return false end
    if minRem and (remaining == nil or remaining < minRem) then return false end
    return true
  end
end }

C.no_debuff = { make = function(cond)
  local key = cond[2]
  local mine = cond.mine
  if mine == nil then mine = true end
  return function(state) return state:debuff(key, mine) == nil end
end }

C.resource = {
  check = function(cond, _, fail)
    if type(cond[2]) ~= "string" then fail("resource needs a power kind, e.g. {\"resource\",\"MANA\"}") end
  end,
  make = function(cond)
    local kind, min, max, minPct, maxPct = cond[2], cond.min, cond.max, cond.minPct, cond.maxPct
    return function(state)
      local cur, cap = state:power(kind)
      if not inRange(cur, min, max) then return false end
      if minPct or maxPct then
        if not cap or cap <= 0 then return false end
        if not inRange(cur / cap * 100, minPct, maxPct) then return false end
      end
      return true
    end
  end,
}

C.cooldown_ready = { make = function(cond)
  local key = cond[2]
  return function(state) return state:cooldown(key) <= 0 end
end }

C.cooldown_gt = {
  check = function(cond, _, fail)
    if type(cond[3]) ~= "number" then fail("cooldown_gt needs seconds, e.g. {\"cooldown_gt\",\"KEY\",1}") end
  end,
  make = function(cond)
    local key, secs = cond[2], cond[3]
    return function(state) return state:cooldown(key) > secs end
  end,
}

C.target_type = {
  check = function(cond, _, fail)
    if cond[2] == nil then fail("target_type needs at least one creature type") end
  end,
  make = function(cond)
    local wanted = {}
    for i = 2, #cond do wanted[cond[i]] = true end -- variadic: {"target_type","Undead","Demon"}
    return function(state)
      local tt = state:targetType()
      return tt ~= nil and wanted[tt] == true
    end
  end,
}

C.target_hp = { make = function(cond)
  local minPct, maxPct = cond.minPct, cond.maxPct
  return function(state) return inRange(state:targetHPPct(), minPct, maxPct) end
end }

C.not_moving = { make = function()
  -- Deliberately reads live state even under simulation: future movement is unknowable (docs/02).
  return function(state) return not state:moving() end
end }

C.in_combat = { make = function() return function(state) return state:inCombat() == true end end }
C.out_of_combat = { make = function() return function(state) return state:inCombat() ~= true end end }

C.set = { make = function(cond)
  local key, min = cond[2], cond.min or 1
  return function(state) return state:setCount(key) >= min end
end }

C.bonus = { make = function(cond)
  local key = cond[2]
  return function(state) return state:bonus(key) == true end
end }

C.enchant = {
  check = function(cond, _, fail)
    if type(cond[2]) ~= "number" then fail("enchant needs an inventory slot number") end
    if cond[3] == nil then fail("enchant needs an enchant key") end
  end,
  make = function(cond)
    local slot, key = cond[2], cond[3]
    return function(state) return state:enchant(slot) == key end
  end,
}

C.weapon = {
  check = function(cond, _, fail)
    local kind = cond[2]
    if kind ~= "2H" and kind ~= "1H" and kind ~= "Shield" then
      fail("weapon kind must be 2H, 1H or Shield (got " .. tostring(kind) .. ")")
    end
  end,
  make = function(cond)
    local kind, minSpeed, maxSpeed = cond[2], cond.minSpeed, cond.maxSpeed
    local slot = (kind == "Shield") and 17 or 16 -- off-hand vs main-hand
    return function(state)
      local w = state:weapon(slot)
      if not w or w.type ~= kind then return false end
      if minSpeed or maxSpeed then return inRange(w.speed, minSpeed, maxSpeed) end
      return true
    end
  end,
}

C.seal = { make = function(cond)
  local key = cond[2]
  return function(state) return state:seal() == key end
end }

C.no_seal = { make = function() return function(state) return state:seal() == nil end end }

C.item_ready = {
  check = function(cond, _, fail)
    if type(cond[2]) ~= "number" then fail("item_ready needs an inventory slot number, e.g. 13") end
  end,
  make = function(cond)
    local slot = cond[2]
    return function(state) return state:itemUsable(slot) and state:itemCooldown(slot) <= 0 end
  end,
}

C.rune = { make = function(cond)
  local key = cond[2]
  return function(state) return state:rune(key) == true end
end }

C.no_rune = { make = function(cond)
  local key = cond[2]
  return function(state) return state:rune(key) ~= true end
end }

C.level = { make = function(cond)
  local min, max = cond.min, cond.max
  return function(state) return inRange(state:level(), min, max) end
end }

C.ttd = { make = function(cond)
  local min, max = cond.min, cond.max
  return function(state) return inRange(state:ttd(), min, max) end -- nil (unknown) never passes
end }

C.enemies = { make = function(cond)
  local min, max, range = cond.min, cond.max, cond.range
  return function(state) return inRange(state:enemies(range), min, max) end
end }

C.mode = {
  check = function(cond, _, fail)
    local m = cond[2]
    if m ~= "Single" and m ~= "Cleave" and m ~= "AoE" then
      fail("mode must be Single, Cleave or AoE (got " .. tostring(m) .. ")")
    end
  end,
  make = function(cond)
    local want = cond[2]
    return function(state) return state:mode() == want end
  end,
}

C.swing = { make = function(cond)
  local minRem, maxRem = cond.minRemaining, cond.maxRemaining
  return function(state) return inRange(state:swingRemaining(), minRem, maxRem) end
end }

C.seal_linger = { make = function(cond)
  local key = cond[2]
  return function(state) return state:sealLinger() == key end
end }

C.custom = {
  check = function(cond, _, fail)
    if type(cond[2]) ~= "function" then fail("custom needs a function") end
  end,
  make = function(cond)
    local fn = cond[2]
    return function(state, t) return fn(state, t) == true end
  end,
}

ns.__schemaConditions = C -- exposed for the spec's coverage check against docs/02

-- ---------------------------------------------------------------- compilation
-- `condLabel` is forward-declared here rather than at its definition below because Schema.compileWhen
-- (public API, further down but still above that definition) needs it: a `local` at the definition
-- site would leave the earlier reference resolving to a nil global, and the label would silently
-- come back as nothing rather than erroring.
local compileList, compileCond, condLabel

-- Forward-declared so all/any/not can recurse before compileCond is defined.
function compileCond(cond, ctx, fail)
  if type(cond) ~= "table" then
    fail("condition must be a table, got " .. type(cond))
    return nil
  end
  local kind = cond[1]
  if kind == "all" or kind == "any" then
    local subs = {}
    for i = 2, #cond do subs[#subs + 1] = compileCond(cond[i], ctx, fail) end
    if #subs == 0 then fail(kind .. " needs at least one nested condition"); return nil end
    if kind == "all" then
      return function(state, t)
        for i = 1, #subs do if not subs[i](state, t) then return false end end
        return true
      end
    end
    return function(state, t)
      for i = 1, #subs do if subs[i](state, t) then return true end end
      return false
    end
  elseif kind == "not" then
    local sub = compileCond(cond[2], ctx, fail)
    if not sub then return nil end
    return function(state, t) return not sub(state, t) end
  end

  local impl = C[kind]
  if not impl then
    fail("unknown condition type '" .. tostring(kind) .. "'")
    return nil
  end

  local source = KEY_SOURCE[kind]
  if source then
    local key = cond[2]
    if type(key) ~= "string" then
      fail(kind .. " needs a symbolic key")
      return nil
    end
    local pack = ctx and ctx[source]
    if pack and pack[key] == nil then
      fail(kind .. " references '" .. key .. "', which is not in the " .. source .. " data pack")
      return nil
    end
  end

  if impl.check then impl.check(cond, ctx, fail) end
  return impl.make(cond, ctx)
end

-- A `when` list is an implicit `all`.
function compileList(when, ctx, fail)
  if when == nil then return function() return true end end
  if type(when) ~= "table" then
    fail("`when` must be a list of conditions, got " .. type(when))
    return function() return false end
  end
  local preds = {}
  for i = 1, #when do
    local p = compileCond(when[i], ctx, function(msg) fail("when[" .. i .. "]: " .. msg) end)
    preds[#preds + 1] = p or function() return false end
  end
  if #preds == 0 then return function() return true end end
  if #preds == 1 then return preds[1] end
  return function(state, t)
    for i = 1, #preds do if not preds[i](state, t) then return false end end
    return true
  end
end

-- ---------------------------------------------------------------- public API

-- Compiles a BARE `when` list — one that is not attached to a build entry — into the same
-- {test, conditions} shape `Schema.compile` produces per entry.
--
-- Exists because the condition language has a second consumer: Data/Advice/<Class>.lua gates its
-- recommendations with the same `when` syntax (`{{"set","PALADIN_T25_AVENGERS", min = 2}}`), and
-- until now the compiler was file-local, so the only way to evaluate one was to wrap it in a fake
-- build. The gear-matrix spec worked around that with a stand-in that could not evaluate `when` at
-- all and said so in its own comment — a test that quietly checked less than it appeared to.
--
-- One compiler, one condition language. A second evaluator for advice would drift from this one the
-- first time a condition type was added, and the drift would show up as advice that is subtly wrong
-- rather than as an error.
function Schema.compileWhen(when, ctx)
  ctx = ctx or {}
  local errors = {}
  local function fail(message) errors[#errors + 1] = { message = message } end
  local compiled = {
    test = compileList(when, ctx, fail),
    conditions = {},
  }
  for i = 1, #(when or {}) do
    compiled.conditions[i] = {
      label = condLabel(when[i]),
      test = compileCond(when[i], ctx, function() end),
    }
  end
  return compiled, errors
end

-- Returns ok, errors. Errors are {entry = n|nil, message = "..."} — structured so the M4 wizard can
-- group by entry, with Schema.errorLines() for chat and CI output.
function Schema.validate(build, ctx)
  ctx = ctx or {}
  local errors = {}
  local function add(entry, msg) errors[#errors + 1] = { entry = entry, message = msg } end

  if type(build) ~= "table" then
    add(nil, "build must be a table, got " .. type(build))
    return false, errors
  end
  if build.schema ~= Schema.VERSION then
    add(nil, "schema must be " .. Schema.VERSION .. " (got " .. tostring(build.schema) .. ")")
  end
  for _, field in ipairs({ "key", "name", "class" }) do
    if type(build[field]) ~= "string" then add(nil, field .. " is required and must be a string") end
  end
  if type(build.entries) ~= "table" or #build.entries == 0 then
    add(nil, "entries must be a non-empty list")
    return #errors == 0, errors
  end

  for i, entry in ipairs(build.entries) do
    if type(entry) ~= "table" then
      add(i, "entry must be a table, got " .. type(entry))
    else
      if entry.spell == nil and entry.item == nil then
        add(i, "entry needs either a spell key or an item slot")
      elseif entry.spell ~= nil and entry.item ~= nil then
        add(i, "entry has both spell and item; pick one")
      end
      if entry.spell ~= nil and type(entry.spell) ~= "string" then
        add(i, "spell must be a symbolic key string, not a raw ID")
      end
      if entry.spell and ctx.spells and ctx.spells[entry.spell] == nil then
        add(i, "spell '" .. entry.spell .. "' is not in the spells data pack")
      end
      -- Simulation debits `spent[kind] = spent[kind] + amount`, so a non-numeric cost raises a Lua
      -- error mid-queue instead of failing here. Wowhead states several paladin costs as a
      -- percentage of base mana ("6% of base mana"), which is exactly the shape that slips in.
      local costData = entry.spell and ctx.spells and ctx.spells[entry.spell]
      if costData and costData.cost ~= nil then
        if type(costData.cost) ~= "table" then
          add(i, "spell '" .. entry.spell .. "' has a non-table cost")
        else
          for kind, amount in pairs(costData.cost) do
            if type(amount) ~= "number" then
              add(i, "spell '" .. entry.spell .. "' has a non-numeric " .. tostring(kind) ..
                     " cost (" .. tostring(amount) .. "); costs are numbers, use state.powerCost() " ..
                     "for values the client must supply")
            end
          end
        end
      end
      compileList(entry.when, ctx, function(msg) add(i, msg) end)
    end
  end
  return #errors == 0, errors
end

function Schema.errorLines(errors)
  local lines = {}
  for _, e in ipairs(errors or {}) do
    lines[#lines + 1] = e.entry and ("entry " .. e.entry .. ": " .. e.message) or e.message
  end
  return lines
end

-- Returns compiled, errors. On any validation error it returns nil — a half-compiled build would
-- silently drop entries, which is the failure mode ADR-0002 exists to prevent.
-- A short readable name for ONE condition: "buff:VENGEANCE_BUFF", "no_seal", "item_ready:13".
-- Nested all/any/not recurse into "any(buff:X,bonus:Y)": a bare "any" names the operator but not
-- what it tested, which is the half that explains a rejected suggestion.
function condLabel(cond)
  if type(cond) ~= "table" then return "?" end
  local kind = tostring(cond[1])
  if kind == "all" or kind == "any" or kind == "not" then
    local parts = {}
    for i = 2, #cond do parts[#parts + 1] = condLabel(cond[i]) end
    return kind .. "(" .. table.concat(parts, ",") .. ")"
  end
  -- Variadic conditions ({"target_type","Undead","Demon"}) must show every argument: naming only
  -- the first describes a narrower test than the one that ran. "/" separates arguments so they
  -- cannot be misread as the "," that separates siblings inside any(...)/all(...).
  local args = {}
  for i = 2, #cond do
    local a = cond[i]
    if type(a) == "string" or type(a) == "number" then args[#args + 1] = tostring(a) end
  end
  if #args > 0 then return kind .. ":" .. table.concat(args, "/") end
  return kind
end

function Schema.compile(build, ctx)
  ctx = ctx or {}
  local ok, errors = Schema.validate(build, ctx)
  if not ok then
    ns.log("Elmira: build '%s' failed validation (%d problem(s))", tostring(build and build.key), #errors)
    return nil, errors
  end

  local compiled = {}
  for k, v in pairs(build) do compiled[k] = v end
  compiled.entries = {}

  for i, entry in ipairs(build.entries) do
    -- A disabled entry compiles to nothing. Schema.exportable marks an entry disabled when it strips
    -- a `custom` condition -- and removes the `when` with it -- so without this skip an imported line
    -- whose gate was hand-written code would arrive as an UNCONDITIONAL line: the exact inverse of
    -- "disabled". M5e's editor toggles the same flag.
    if not entry.disabled then
    local out = {}
    for k, v in pairs(entry) do out[k] = v end
    out.index = i
    out.test = compileList(entry.when, ctx, function() end) -- already validated; cannot fail here
    -- One compiled test PER top-level condition, alongside the combined `test`. `passes = false`
    -- cannot say WHY an entry was rejected, and explaining a suggestion is the entire value of a
    -- recording taken with no display to look at. Same closures, evaluated separately; the combined
    -- `test` stays authoritative for the queue. Also what M3's hover-"why" needs.
    out.conditions = {}
    for ci = 1, #(entry.when or {}) do
      out.conditions[ci] = {
        label = condLabel(entry.when[ci]),
        test = compileCond(entry.when[ci], ctx, function() end),
      }
    end
    local data = entry.spell and ctx.spells and ctx.spells[entry.spell] or nil
    out.data = data
    -- Surfaced on the entry so Simulation and M3's renderer never reach back into ctx.
    out.cdVolatile = data ~= nil and data.cdVolatile == true
    -- docs/03 writes cost keys lowercase (`cost = {mana = N}`) while docs/02 writes power kinds
    -- uppercase (`{"resource","MANA"}`). Left alone, the virtual state debits spent["mana"] while the
    -- condition reads power("MANA") and the pool silently never drains. Normalise once here, at load,
    -- rather than per frame in the queue.
    if data and data.cost then
      local cost = {}
      for kind, amount in pairs(data.cost) do cost[string.upper(kind)] = amount end
      out.cost = cost
    end
    out.cooldownSecs = data and data.cooldown or nil
    compiled.entries[#compiled.entries + 1] = out
    end
  end
  compiled.compiled = true
  return compiled, errors
end

-- Recurses through all/any/not exactly as compileCond does. Scanning only the top level of `when`
-- would let `{"any", {"custom", fn}, {"buff", ...}}` export with the raw function still embedded —
-- functions cannot serialize, so that is a broken export string, not a lost condition.
local function containsCustom(when)
  for _, cond in ipairs(when or {}) do
    if type(cond) == "table" then
      if cond[1] == "custom" then return true end
      if cond[1] == "all" or cond[1] == "any" or cond[1] == "not" then
        local nested = {}
        for i = 2, #cond do nested[#nested + 1] = cond[i] end
        if containsCustom(nested) then return true end
      end
    end
  end
  return false
end

-- docs/02 "Import/export string": functions are never serialized, so a build carrying `custom` exports
-- with those entries marked disabled rather than silently losing a condition.
function Schema.exportable(build)
  local out = {}
  for k, v in pairs(build) do out[k] = v end
  out.entries = {}
  local stripped = 0
  for i, entry in ipairs(build.entries or {}) do
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    -- compiled artefacts never serialize: the closures, the resolved data record, the per-condition
    -- labels, and the fields compile derives from data (index, cdVolatile, cost, cooldownSecs)
    copy.test, copy.data, copy.conditions = nil, nil, nil
    copy.index, copy.cdVolatile, copy.cost, copy.cooldownSecs = nil, nil, nil, nil
    local hasCustom = containsCustom(entry.when)
    if hasCustom then
      copy.when, copy.disabled = nil, true
      stripped = stripped + 1
    end
    out.entries[i] = copy
  end
  out.compiled = nil
  return out, stripped
end

ns.Schema = Schema
return Schema
