-- Elmira/Core/Gates.lua — which rows of a build are live for THIS character (ADR-0015, PRD F37).
--
-- PURE (hard rule 3): takes a compiled build, a State and the pack's ctx tables; returns rows and
-- sentences. Display/Driver reads the live state and calls in.
--
-- The distinction this file exists for. A build is one static priority list shipped to everybody;
-- what makes it personal is that its rows carry gates, and the engine evaluates them against the
-- character in front of it (ADR-0013: "personalised by authored gates, not by simulation"). Some of
-- those gates are DYNAMIC -- target health, mana, enemy count, cooldowns -- and change second by
-- second; that is the rotation doing its job and it is not news. Others are STATIC: a set bonus, a
-- rune, a weapon, a level, a spell you have not learned. Those change when you change your
-- character, they stay changed, and a player who has just equipped their fourth tier piece has no
-- way of knowing their rotation grew a new line unless something says so.
--
-- Only static gates are reported. Reporting a dynamic one would make rows flicker mid-fight and
-- teach that the rotation is unstable, which is the opposite of what the display is for.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Gates = {}

-- The condition types that depend only on the character, not on the moment.
--
-- `item_ready` is deliberately NOT here: it looks static (a trinket is equipped or it is not) but
-- half of it is a cooldown, so it would flicker exactly like a dynamic gate. `seal` looks dynamic
-- and is; `enchant` covers shoulder souls, which are gear.
Gates.STATIC = {
  set = true, bonus = true, enchant = true, weapon = true,
  rune = true, no_rune = true, level = true,
}

-- A static gate the client may be unable to READ. On a flavour without engraving every rune gate
-- would otherwise decide "not engraved" and report a row dead for a reason that is not true and
-- that the player cannot act on -- the exact false claim this file's undecidable answer exists for.
-- Adapters/Vanilla answers `false` rather than nil for an unreadable rune (the engine wants a
-- boolean), so the capability is what tells the two apart.
Gates.NEEDS_CAPABILITY = { rune = "runes", no_rune = "runes" }

-- Evaluating one leaf reuses Core/Schema's own condition makers rather than reimplementing them.
-- A second copy of "what does `bonus` mean" is a second thing to keep in step, and the one that is
-- wrong would be this one -- it is the copy nothing casts from.
-- One pcall around the lookup, the build and the run. A condition type Schema has never heard of,
-- one it cannot build, and one that throws against this state are the same answer here -- "cannot
-- say" -- and a gate check must never be the thing that takes the display down. Separate guards for
-- each would each be unreachable, which is a check that cannot fail.
-- Second return: "the answer is missing because nothing could READ it", which is a different
-- thing from a gate that is simply about right now. PE15 hangs the whole certainty flag on that
-- distinction -- treat every nil alike and every row carrying a dynamic gate becomes "uncertain",
-- which would silence the announcements entirely instead of only the untrue ones.
local function leafTest(cond, state)
  local ok, passed = pcall(function()
    return ns.__schemaConditions[cond[1]].make(cond)(state)
  end)
  if not ok then return nil, true end
  return passed == true
end

-- true / false / nil, where nil means "not decidable from the character alone".
--
-- `all` fails if any static child fails, whatever the dynamic ones do. `any` fails only when EVERY
-- branch is static and every one of them fails -- one undecidable branch means the row may still
-- fire tonight, and calling it inactive would be a lie the player cannot check.
--
-- SECOND RETURN (PE15): whether that nil is "nothing could read this" rather than "this gate is
-- about right now". Only ever meaningful alongside a nil verdict -- an answer the client gave is
-- an answer, whatever its unreadable siblings did -- and it is what lets a row say "my verdict is
-- a guess" without pretending a dynamic gate is a client failure.
local function verdict(cond, state, caps)
  if type(cond) ~= "table" then return nil end
  local kind = cond[1]

  if kind == "all" then
    local undecided, unreadable = false, false
    for i = 2, #cond do
      local v, u = verdict(cond[i], state, caps)
      -- A gate that definitely blocks settles the row on its own: there is nothing uncertain about
      -- a false the client stated plainly, however little it would say about the gate next to it.
      if v == false then return false end
      if v == nil then undecided = true end
      if u then unreadable = true end
    end
    -- `return not undecided` would answer FALSE here, i.e. "statically blocked", for a row whose
    -- static gates all pass and whose remaining gates are simply about right now.
    if undecided then return nil, unreadable end
    return true
  elseif kind == "any" then
    local allStatic, unreadable = true, false
    for i = 2, #cond do
      local v, u = verdict(cond[i], state, caps)
      if v == true then return true end
      if v == nil then allStatic = false end
      if u then unreadable = true end
    end
    -- Not `allStatic and false or nil`: in Lua that yields nil whatever allStatic is, because the
    -- `and` arm is itself false. The one shape of this idiom that silently never works.
    if allStatic then return false end
    return nil, unreadable -- mutants: equivalent falling through answers nil for a composite kind too
  elseif kind == "not" then
    local v, u = verdict(cond[2], state, caps)
    if v == nil then return nil, u end
    return not v
  end

  if not Gates.STATIC[kind] then return nil end
  -- Only when the client has SAID it cannot read this. A nil `caps` is a client that has not been
  -- asked, which is how every spec and every pre-M5g caller arrives.
  local needed = Gates.NEEDS_CAPABILITY[kind]
  if needed and caps and caps[needed] == false then return nil, true end
  return leafTest(cond, state)
end
Gates.verdict = verdict

-- A spell key as a person would say it: RUNE_PURIFYING_POWER -> "Purifying Power". Done from the
-- key rather than from GetSpellInfo because this file is Core and may not call the client -- and
-- because a rune the player has NOT engraved has no name to look up anyway.
local function pretty(key)
  if type(key) ~= "string" then return tostring(key) end
  local out = key:gsub("^RUNE_", ""):gsub("_", " "):lower()
  return (out:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest end))
end
-- The REQUIREMENT a gate expresses, named in the voice of it being met: "Purifying Power engraved",
-- "level 40 or above", "the T3.5 4-set". One phrasing has to read correctly in both sentences the
-- announcement builds -- "X: Exorcism is now active" and "Exorcism is no longer active, needs X" --
-- and the negative voice ("Purifying Power NOT engraved") makes the first of those say the opposite
-- of what happened. Uses the pack's own words where it has any: a set's `name` and a bonus's `note`
-- were written to be read.
function Gates.describe(cond, ctx)
  ctx = ctx or {}
  if type(cond) ~= "table" then return "an unreadable condition" end
  local kind, key = cond[1], cond[2]

  if kind == "set" then
    local set = ctx.sets and ctx.sets[key]
    return string.format("%s (%d pieces)", (set and set.name) or pretty(key), cond.min or 1)
  elseif kind == "bonus" then
    local bonus = ctx.bonuses and ctx.bonuses[key]
    return (bonus and bonus.note) or pretty(key)
  elseif kind == "rune" then
    return pretty(key) .. " engraved"
  elseif kind == "no_rune" then
    return pretty(key) .. " not engraved"
  elseif kind == "level" then
    if cond.min and cond.max then return string.format("level %d to %d", cond.min, cond.max) end
    if cond.min then return string.format("level %d or above", cond.min) end
    return string.format("level %d or below", cond.max or 0)
  elseif kind == "weapon" then
    return string.format("a %s equipped", tostring(key))
  elseif kind == "enchant" then
    -- PE3-D5: the slot by its name when the caller can name one ("Soul of the Exile on Shoulder"),
    -- never the raw number that only the inventory API cares about.
    local slot = ctx.slotName and ctx.slotName(key)
    if slot then return string.format("%s on %s", pretty(cond[3]), slot) end
    return string.format("%s on slot %s", pretty(cond[3]), tostring(key))
  -- Composites in words. Schema's label grammar ("any(rune:RUNE_ART_OF_WAR,bonus:X)") is right for
  -- a debug dump and wrong in a sentence a player reads.
  elseif kind == "all" or kind == "any" then
    local parts = {}
    for i = 2, #cond do parts[#parts + 1] = Gates.describe(cond[i], ctx) end
    if #parts == 0 then return "nothing" end
    local last = table.remove(parts)
    if #parts == 0 then return last end
    return table.concat(parts, ", ") .. (kind == "any" and " or " or " and ") .. last
  elseif kind == "not" then
    return "not " .. Gates.describe(cond[2], ctx)
  end
  return tostring(kind)
end

-- Gates.evaluate(compiled, state, ctx) -> rows
--
-- One row per entry, in priority order: { index, spell, item, active, reasons, certain }.
-- `active` false means this row cannot fire for this character until something about the character
-- changes. Display/Driver turns that into an announcement; M5e's Builder dims the row.
--
-- `certain` (PE15) is false when the verdict rests on a reading the client would not give: `known`
-- answering nil, or a static gate nothing could read. `active` is still a plain boolean for every
-- existing consumer -- the engine, the queue and the Builder's status dot are untouched -- but
-- Display/Driver refuses to REMEMBER an uncertain row, and Gates.diff refuses to announce one.
-- Without that, an unreadable moment reads as "you no longer have Divine Storm" and the next
-- readable one reads as "you have it again", and the addon reports its own blindness as news.
function Gates.evaluate(compiled, state, ctx)
  local rows = {}
  if not (compiled and compiled.entries and state) then return rows end

  for i, entry in ipairs(compiled.entries) do
    local reasons, active, certain = {}, true, true

    -- A spell the character has not learned is the commonest static gate of all, and it is not a
    -- condition: Core/Engine skips it silently (ADR-0006 rule 5), which is right for the rotation
    -- and useless for explaining it.
    --
    -- Three-valued on purpose (Adapters/Interface: "nil, not false"). A state with no `known` at
    -- all was never asked and is not uncertain; a `known` that answers nil was asked and would not
    -- say, and a row is not dimmed for that -- it is simply not spoken about.
    if entry.spell and state.known then
      local learned = state:known(entry.spell)
      if learned == false then
        active = false
        reasons[#reasons + 1] = pretty(entry.spell) .. " learned"
      elseif learned == nil then
        certain = false
      end
    end

    for _, cond in ipairs(entry.when or {}) do
      local passed, unreadable = verdict(cond, state, ctx and ctx.capabilities)
      if passed == false then
        active = false
        reasons[#reasons + 1] = Gates.describe(cond, ctx)
      elseif unreadable then
        certain = false
      end
    end

    -- One gate the client stated plainly settles the row, whatever else went unread: "this cannot
    -- fire, and here is the requirement" is a fact, and withholding it because some other gate was
    -- unreadable would lose the announcement this file exists for.
    if not active then certain = true end

    rows[#rows + 1] = {
      index = i, spell = entry.spell, item = entry.item,
      active = active, reasons = reasons, certain = certain,
    }
  end
  return rows
end

-- Collapse to one verdict per SPELL, which is the grain a player thinks in: two entries can both
-- produce Judgement, and "Judgement is now active" is true as soon as either of them is.
function Gates.snapshot(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local key = row.spell or (row.item and ("item:" .. tostring(row.item)))
    if key then
      local held = out[key]
      -- An active row wins over an inactive one, as it always has. Between two rows that AGREE,
      -- the one the client could actually read wins: a spell whose second entry is certainly
      -- available is certainly available, and inheriting the first row's doubt would suppress a
      -- change that is real.
      local wins = held == nil
        or (row.active and not held.active)
        or (row.active == held.active and row.certain ~= false and held.certain == false)
      if wins then
        out[key] = { active = row.active, reason = row.reasons[1], certain = row.certain ~= false }
      end
    end
  end
  return out
end

-- What changed between two snapshots. Sorted, because an unordered announcement lists the same two
-- spells in a different order every time and reads like two different messages.
--
-- PE15: only a transition between two verdicts the client actually gave. "I could not tell" is not
-- a state the character was ever in, so a change into or out of it is not news -- and announcing
-- one is how the addon came to report a rune being engraved and un-engraved during a fight, which
-- cannot happen. `certain` is only ever suppressing when explicitly false: a snapshot that carries
-- no flag at all is treated as certain, because a diff that quietly announces nothing is the worse
-- of the two failures.
function Gates.diff(before, after)
  local activated, deactivated = {}, {}
  for key, now in pairs(after or {}) do
    local was = (before or {})[key]
    if was and was.certain ~= false and now.certain ~= false and was.active ~= now.active then
      if now.active then
        -- The reason it USED to be blocked is the news: "you now have the 4-set".
        activated[#activated + 1] = { spell = key, reason = was.reason }
      else
        deactivated[#deactivated + 1] = { spell = key, reason = now.reason }
      end
    end
  end
  local function bySpell(a, b) return a.spell < b.spell end
  table.sort(activated, bySpell)
  table.sort(deactivated, bySpell)
  return { activated = activated, deactivated = deactivated }
end

-- One sentence, or nil when nothing changed. Names the requirement, the spell and the rotation,
-- because all three are things the player may be about to go looking for.
function Gates.announcement(diff, buildName)
  if not diff then return nil end
  local where = buildName and (" in " .. buildName) or ""
  local parts = {}
  for _, row in ipairs(diff.activated or {}) do
    parts[#parts + 1] = string.format("%s: %s is now active%s.",
      row.reason or "Your gear changed", pretty(row.spell), where)
  end
  for _, row in ipairs(diff.deactivated or {}) do
    parts[#parts + 1] = string.format("%s is no longer active%s — needs %s.",
      pretty(row.spell), where, row.reason or "something you no longer have")
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

ns.Gates = Gates
return Gates
