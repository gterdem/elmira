-- Elmira/Core/Diagnostics.lua — "what did my edit do?", answered without a raid (F36, F35).
--
-- PURE (hard rule 3): plain tables in, plain tables out. No WoW API, no frames, no simulation, no
-- state. Options/Rotation words the answers and draws them at the foot of the Builder (ADR-0015 §2).
--
-- Everything here is STRUCTURAL, and that is a deliberate limit rather than a shortcut. A diagnostic
-- that runs the rotation against sampled situations can only ever say "I did not see this line
-- fire", which is not the same claim as "this line cannot fire" -- and the second is the only one
-- worth putting on screen. Every answer below is decidable from the build alone, so none of them can
-- be wrong about a situation nobody thought to sample.
--
-- What is deliberately NOT here: a queue diff across gear points. F36's prose asks for one "reusing
-- tests/fixtures/gear_scenarios.lua", which is a test fixture specific to one build and is not
-- shipped; where those situations should come from is an open decision (tasks/todo.md), and neither
-- M5e exit criterion needs it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Diagnostics = {}

-- What an entry DOES, as one comparable value. Two entries are candidates for shadowing only when
-- they produce the same thing: an entry that casts Exorcism cannot make one that uses trinket 13
-- unreachable however its conditions read.
local function actionOf(entry)
  if entry.spell ~= nil then return "spell:" .. tostring(entry.spell) end
  if entry.item ~= nil then return "item:" .. tostring(entry.item) end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

-- Deep value equality, with functions compared by identity.
--
-- A `custom` condition holds a closure, and two closures that do the same thing are not equal and
-- must not be treated as equal: claiming a line is unreachable because of a function nobody can read
-- is exactly the false claim this file exists to avoid making.
local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for key, value in pairs(a) do
    if not same(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

-- Is every condition of `outer` also a condition of `inner`?
--
-- Set containment on the TOP-LEVEL list only, which is what makes it sound: a `when` list is an
-- implicit `all` (Core/Schema.compileList), so if every test in A also appears in B then B passing
-- means A passing. Nothing is inferred about the CONTENT of a condition -- `{"resource","MANA",
-- minPct=40}` does not subsume `minPct=60` here, even though it does in truth. Under-reporting is
-- the safe direction: a missed warning costs nothing, a wrong one tells someone to delete a line
-- that works.
local function subsumes(outer, inner)
  for _, cond in ipairs(outer or {}) do
    local found = false
    for _, other in ipairs(inner or {}) do
      if same(cond, other) then found = true; break end
    end
    if not found then return false end
  end
  return true
end

-- Diagnostics.shadowed(build) -> { { index, by, action, alwaysOn }, ... }
--
-- An entry an earlier one ALWAYS shadows, so it can never be the suggestion (F1: the first entry
-- that passes is the answer). Reported only when it is certain:
--   * both produce the same action, so every eligibility test other than the conditions -- known,
--     usable, off cooldown -- gives the same answer for both, and
--   * the earlier entry's conditions are a subset of the later one's, so it passes whenever the
--     later one does.
-- The commonest editing mistake is the empty-set case: an unconditional line above a conditional
-- one for the same spell, which kills the conditional one outright. `alwaysOn` names that case so
-- the sentence can be the direct one ("nothing gates line 2, so line 7 can never fire").
--
-- Disabled entries neither shadow nor are reported: they are not in the rotation at all
-- (Schema.compile skips them), so saying a switched-off line is unreachable is noise.
function Diagnostics.shadowed(build)
  local out = {}
  local entries = (build and build.entries) or {}
  for j = 2, #entries do
    local later = entries[j]
    if type(later) == "table" and not later.disabled then
      local action = actionOf(later)
      for i = 1, j - 1 do
        local earlier = entries[i]
        if action ~= nil and type(earlier) == "table" and not earlier.disabled
           and actionOf(earlier) == action and subsumes(earlier.when, later.when) then
          out[#out + 1] = {
            index = j, by = i, action = action,
            alwaysOn = #(earlier.when or {}) == 0,
          }
          break -- the FIRST line that kills it is the one to name; the rest are the same news
        end
      end
    end
  end
  return out
end

-- Diagnostics.unknown(build, ctx) -> { { index, kind, key, source }, ... }
--
-- Keys the class data no longer carries. This is what a fork looks like after the pack it was taken
-- from moves on: the fork lives in SavedVariables and outlives any release, so an ability the data
-- renamed leaves a line naming something that no longer exists. `Schema.validate` refuses the whole
-- build for it -- correctly -- and the display then says only "failed to compile", which does not
-- tell anyone WHICH line to fix.
--
-- The kinds checked are Schema's own `KEY_SOURCE`, read from Schema rather than copied: a second
-- copy would go on answering correctly right until a key-taking condition type was added, and then
-- quietly stop checking the new one. `entry.spell` is checked too -- it is a key with no condition.
function Diagnostics.unknown(build, ctx)
  local out = {}
  ctx = ctx or {}
  local sources = ns.__schemaKeySource or {}

  local function check(index, kind, key, source)
    local pack = ctx[source]
    -- A ctx table that was not supplied at all is not checked, exactly as Schema does it: the
    -- staged specs pass only `spells`, and reporting every set as missing there would be wrong.
    if pack and type(key) == "string" and pack[key] == nil then
      out[#out + 1] = { index = index, kind = kind, key = key, source = source }
    end
  end

  local function walk(index, when)
    for _, cond in ipairs(when or {}) do
      if type(cond) == "table" then
        local kind = cond[1]
        if kind == "all" or kind == "any" or kind == "not" then
          local nested = {}
          for i = 2, #cond do nested[#nested + 1] = cond[i] end
          walk(index, nested)
        else
          local source = sources[kind]
          -- `enchant` keeps its key at position 3; everything else at 2.
          if source then check(index, kind, cond[2], source) end
        end
      end
    end
  end

  for i, entry in ipairs((build and build.entries) or {}) do
    if type(entry) == "table" then
      if entry.spell ~= nil then check(i, "spell", entry.spell, "spells") end
      walk(i, entry.when)
    end
  end
  return out
end

-- Diagnostics.deadSeal(build) -> { { index, key }, ... }
--
-- A `seal`/`seal_linger` condition naming a seal no ENABLED line of this build ever casts. Nothing
-- else in the addon's model puts a seal on the character -- it is the rotation's own earlier lines
-- or nothing -- so a condition naming one no line casts can never become true as the build stands,
-- however the character or the moment changes. That is the editor's RED state (D87, 2026-09-07
-- owner ruling): "a logic error the player should fix", the example given being exactly this --
-- a condition on Seal of Righteousness after the line that cast it was changed to something else.
--
-- Structural, like `Diagnostics.unknown` above: decidable from the build alone, so it is never wrong
-- about a situation nobody thought to sample. A disabled line neither casts nor is checked -- it is
-- not in the rotation at all (Schema.compile skips it), so it can supply no seal and raise no dead
-- condition of its own.
function Diagnostics.deadSeal(build)
  local out = {}
  local entries = (build and build.entries) or {}
  local cast = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and not entry.disabled and entry.spell then cast[entry.spell] = true end
  end

  local function walk(index, when)
    for _, cond in ipairs(when or {}) do
      if type(cond) == "table" then
        local kind = cond[1]
        if kind == "all" or kind == "any" or kind == "not" then
          local nested = {}
          for i = 2, #cond do nested[#nested + 1] = cond[i] end
          walk(index, nested)
        elseif kind == "seal" or kind == "seal_linger" then
          local key = cond[2]
          if type(key) == "string" and not cast[key] then
            out[#out + 1] = { index = index, key = key }
          end
        end
      end
    end
  end

  for i, entry in ipairs(entries) do
    if type(entry) == "table" and not entry.disabled then walk(i, entry.when) end
  end
  return out
end

-- Diagnostics.compare(mine, theirs) -> { onlyMine, onlyTheirs, changed, moved }
--
-- How one rotation differs from another, row by row (F35: "the template-updated diff names changed
-- rows"). Used for a fork against the template it came from, once a release has moved the template
-- on -- ADR-0010 forbids an automatic rebase, so the whole value is in being able to READ what is
-- different and decide.
--
-- The honest scope, stated because the obvious reading is wrong: this compares your rotation with
-- the template AS IT IS NOW. It is not "what changed since you forked" -- `derivedAt` records which
-- VERSION you forked, never its contents, so that question has no answer here and must not be
-- implied by the wording.
--
-- Rows are matched on action plus the author's label, in order, each match consumed. A build
-- legitimately holds several lines for one spell (Exodin has three Judgements), and matching on the
-- action alone would pair the wrong two and then report both as changed.
local function rowKey(entry)
  return tostring(actionOf(entry)) .. "\0" .. tostring(entry.label or "")
end

-- Rows carry the entry's OWN fields rather than the `action` string, which is an identity used
-- inside this file: a caller that had to parse "spell:EXORCISM" back apart would be undoing an
-- encoding it never needed to see, and would get it wrong the day an action gains a third kind.
local function row(index, entry, theirIndex)
  return { index = index, theirIndex = theirIndex,
           spell = entry.spell, item = entry.item, label = entry.label }
end

function Diagnostics.compare(mine, theirs)
  local ours = (mine and mine.entries) or {}
  local parent = (theirs and theirs.entries) or {}

  local pool = {}
  for i, entry in ipairs(parent) do
    if type(entry) == "table" then
      local key = rowKey(entry)
      pool[key] = pool[key] or {}
      table.insert(pool[key], { index = i, entry = entry })
    end
  end

  local result = { onlyMine = {}, onlyTheirs = {}, changed = {}, moved = {} }
  local matched = {}

  for i, entry in ipairs(ours) do
    if type(entry) == "table" then
      local candidates = pool[rowKey(entry)]
      local hit = candidates and table.remove(candidates, 1)
      if not hit then
        result.onlyMine[#result.onlyMine + 1] = row(i, entry)
      else
        matched[hit.index] = true
        if not same(entry.when, hit.entry.when) then
          result.changed[#result.changed + 1] = row(i, entry, hit.index)
        end
        -- Position is the rotation (F1), so a row that merely moved is a real difference and a
        -- separate one: it can be the only thing a release changed.
        if i ~= hit.index then
          result.moved[#result.moved + 1] = row(i, entry, hit.index)
        end
      end
    end
  end

  for i, entry in ipairs(parent) do
    if type(entry) == "table" and not matched[i] then
      result.onlyTheirs[#result.onlyTheirs + 1] = row(i, entry)
    end
  end
  return result
end

ns.Diagnostics = Diagnostics
return Diagnostics
