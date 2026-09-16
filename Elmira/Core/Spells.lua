-- Elmira/Core/Spells.lua — the Spells registry (R2, D53). Every rotation and condition that names a
-- spell will eventually draw from this list; R2 only builds the list itself and the guards around
-- editing it (the on-screen cue controls a per-spell page will carry are R4).
--
-- PURE (hard rule 3): no WoW API. Every function here takes already-RESOLVED `{id, name}` data --
-- the three ways of producing one (spellbook enumeration, id -> name, name -> id) live in
-- Adapters/Vanilla.lua behind capability flags, the way R1c's `chatMessageGroups` does.
--
-- NOTE FOR THE REVIEWER (hard rule 2): rule 2 ("no spell/item id from memory") governs the SHIPPED
-- data files under Elmira/Classes/, which is why every id there carries a `-- src:` Wowhead
-- comment. A registry entry here is resolved by THIS CLIENT, on THIS PLAYER's machine, at runtime --
-- it was never anyone's memory to begin with, and it carries no `-- src:` line BY DESIGN (owner's
-- decision, artifact section 5, R2 spec). Its absence here is not rule 2 being skipped.
--
-- `key` is a STABLE SLUG, and rotations/conditions name an entry by key, never by raw id (hard rule
-- 4). An automatically registered ("pack") entry keeps the PACK'S OWN spell key verbatim -- that key
-- is already what a build's `entry.spell` or a condition's `keySource="spells"` argument names, so
-- inventing a second key for the same spell would make the "still referenced" guard below blind to
-- it. A manually added entry (by id, by name, from the spellbook) has no pack key to borrow, so it
-- gets a slug of its resolved NAME instead.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Spells = {}

-- The live per-character table, or nil before AceDB has handed one over. Exposed rather than kept
-- private: Options/Spells.lua and Options/Rotation.lua both need the SAME table (one registry, read
-- from two screens), and a second reader re-deriving "where is it" would drift from this the first
-- time either one changed how `ns.db` is reached.
function Spells.store()
  local db = ns.db
  return db and db.char and db.char.spells
end

-- "Divine Storm" -> "DIVINE_STORM", collision-safe against whatever the table already holds
-- (including pack keys, which do not go through this function but still occupy the namespace).
local function slug(name, taken)
  local base = tostring(name or ""):upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if base == "" then base = "SPELL" end
  if #base > 32 then base = base:sub(1, 32):gsub("_+$", "") end
  if not (taken and taken[base]) then return base end
  local n = 2
  while taken[base .. "_" .. n] do n = n + 1 end
  return base .. "_" .. n
end

-- The key of an existing entry carrying this id, or nil.
local function keyById(s, id)
  for key, entry in pairs(s or {}) do
    if entry.id == id then return key end
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

-- "Exorcism" / "EXORCISM (Rank 5)" -> "exorcism": case-insensitive, and a rank suffix (which
-- Adapter.spellNameByID/spellIDByName never append on this client, but a hand-typed or pasted name
-- might carry one) does not make two spellings of one ability read as two different spells.
local function normalizeName(name)
  local n = tostring(name or ""):lower()
  n = n:gsub("%s*%(rank%s*%d+%)%s*$", "")
  return n
end

-- The key of an existing entry whose NAME matches (AT7-D1), or nil. The second half of the dedup:
-- an ability is a NAME, not a rank (owner, 2026-09-11) -- a different rank of a spell already on
-- this list, added by id or picked from the spellbook, must land on that same row.
local function keyByName(s, name)
  local target = normalizeName(name)
  if target == "" then return nil end
  for key, entry in pairs(s or {}) do
    if normalizeName(entry.name) == target then return key end
  end
  return nil -- mutants: equivalent the last statement of a function; Lua returns nil either way
end

-- Spells.merged(pack) -> ctx.spells
--
-- R2b (D75/D76): every consumer that builds a compile/validate ctx (`Core/UserBuilds.ctxFor`,
-- `Display.packContext`, `Vanilla.attachPack`) used to hand `Schema.validate`/`Vanilla.newState`
-- the pack's OWN spell table alone, so a spell a player added by id/name/spellbook validated and
-- resolved nowhere -- the registry and the engine never met. This is the one merge every one of
-- those call sites now shares: this character's registry (`Spells.store()`) UNDER the pack's own
-- table, PACK WINNING on a key collision -- shipped data is the authority (hard rule 2) and a
-- client-resolved entry must never shadow it. Per-character by construction: `Spells.store()`
-- always reads `ns.db.char.spells`, never another character's.
--
-- Returns the SAME table object for a given `pack` every time, refilled rather than replaced.
-- `Core/Slash.compileBuild` and `Display.packContext` both decide "is this ctx still the one I
-- compiled against" by comparing `ctx.spells` for IDENTITY (docs/01 §7's per-frame memo pattern) --
-- a fresh table on every call would make every one of those caches miss on every tick, recompiling
-- the active build ten times a second instead of once. `pack.spells` itself is still read FRESH on
-- every call (never cached here), so a pack whose own table is hot-swapped is still picked up.
--
-- PF2: a pack-less class (no shipped data pack) calls this with `pack == nil` on every tick. `nil`
-- cannot be a weak-table key, and a fresh `{}` substituted per call would key `mergedSpells` on a
-- brand-new table every time -- the cache could never hit, breaking the very identity contract this
-- comment promises, and every consumer above would recompile on every tick instead of once. `NIL_PACK`
-- is the one substitute for every nil call, so `Spells.merged(nil)` gets the SAME cache slot -- and
-- therefore the same returned table -- as any other pack would. `spells = {}` on the sentinel itself
-- matters too: without it, `pack.spells` below is nil for every pack-less call and `pack.spells or
-- {}` allocates a fresh throwaway table on every tick -- a smaller version of the very bug this
-- sentinel exists to fix. A real pack's own `.spells` table is always truthy, so this never affected it.
local NIL_PACK = { spells = {} }
local mergedSpells = setmetatable({}, { __mode = "k" })

function Spells.merged(pack)
  pack = pack or NIL_PACK
  local out = mergedSpells[pack]
  if not out then out = {}; mergedSpells[pack] = out end
  for k in pairs(out) do out[k] = nil end
  for key, entry in pairs(Spells.store() or {}) do out[key] = entry end
  for key, entry in pairs(pack.spells or {}) do out[key] = entry end -- pack wins: applied last
  return out
end

-- Spells.registerPack(s, key, id, name) -> key
--
-- The automatic path (D55): idempotent, and never overwrites an entry that is already there under
-- this key -- a manually added entry that happens to share a pack's key (a hand-edited
-- SavedVariables file, never something this addon writes on its own) keeps the player's own naming
-- rather than being silently relabelled "pack" on the next sync.
function Spells.registerPack(s, key, id, name)
  if not (s and type(key) == "string" and key ~= "") then return nil end
  if s[key] then return key end
  s[key] = { key = key, id = id, name = name, source = "pack" }
  return key
end

-- Spells.add(s, resolved, resolve) -> key | nil, reason
--
-- resolved = { id =, name =, source = "id"|"name"|"spellbook" }. D54's "an entry that already
-- exists is not duplicated; adding it again selects its page" is the id-dedup above: adding the same
-- spell twice, from two different rows, returns the SAME key both times rather than a second entry.
--
-- AT7-D1: a NAME match dedupes too. An ability is a name, not a rank (owner, 2026-09-11) -- a rank
-- of a spell already registered under a DIFFERENT id (typed by id, or picked from the spellbook)
-- selects that same row instead of slugging a fresh "..._2" entry, which is how "HOLY_LIGHT_2" could
-- otherwise be born from nothing but a rank. `resolve` is `Adapter.spellIDByName`, wired in by the
-- caller so this file stays pure (hard rule 3): it is the ARBITER of which of the two ids is the
-- higher rank, since Classic ids do not promise to rise with rank. Never moves a PACK entry's id --
-- a shipped pack ships the max rank on purpose (hard rule 2) -- and with no resolver at all the
-- match still dedupes; the stored id simply stays put until something (AT7-D2's `refreshRanks`)
-- says otherwise.
function Spells.add(s, resolved, resolve)
  if not s then return nil, "no character data yet" end
  if type(resolved) ~= "table" or type(resolved.id) ~= "number" or resolved.id <= 0
      or type(resolved.name) ~= "string" or resolved.name == "" then
    return nil, "not found"
  end
  local already = keyById(s, resolved.id)
  if already then return already end
  local byName = keyByName(s, resolved.name)
  if byName then
    local entry = s[byName]
    if entry.source ~= "pack" and entry.id ~= resolved.id and type(resolve) == "function" then
      local highest = resolve(entry.name)
      if highest == resolved.id then entry.id = resolved.id end
    end
    return byName
  end
  local key = slug(resolved.name, s)
  s[key] = { key = key, id = resolved.id, name = resolved.name, source = resolved.source or "id" }
  return key
end

-- Spells.refreshRanks(s, resolve) -> how many entries changed
--
-- AT7-D2: the spellbook, not any add path, is the standing authority on which rank an ability IS.
-- Called from Core/Init's SPELLS_CHANGED handler (chained onto the handler already registered there
-- -- Ace registries replace, never add), through `resolve = Adapter.spellIDByName` so this file never
-- names a WoW global itself (hard rule 3).
--
-- Skips every `source == "pack"` entry: a shipped pack ships the max-rank id on purpose (hard rule
-- 2), and a level-20 alt who has only learned rank 3 of it must not downgrade that id -- the pack
-- entry already resolves correctly the moment the character catches up (Adapters/Vanilla.knownById).
function Spells.refreshRanks(s, resolve)
  local changed = 0
  if not (s and type(resolve) == "function") then return changed end
  for _, entry in pairs(s) do
    if entry.source ~= "pack" then
      local id = resolve(entry.name)
      if type(id) == "number" and id > 0 and id ~= entry.id then
        entry.id = id
        changed = changed + 1
      end
    end
  end
  return changed
end

-- Spells.adopt(s, key, id, name) -> key | nil
--
-- The IMPORT path (AB2-D5). A settings bundle names a key the SENDER's client resolved, and the
-- settings row and the registry entry have to keep that same key or they point at different things
-- -- which is why this is not `Spells.add`: `add` slugs a fresh key out of the name, and an
-- imported "EXORCISM_2" would leave the imported settings attached to nothing.
--
-- Never overwrites an entry that is already there: a shipped pack's key, or the player's own
-- naming, outranks whatever a string says about it. The id and name are the RECEIVER's -- the
-- caller resolves them through the adapter first and does not call this at all when the client
-- cannot (that row stays settings-only and the tree says "not on this character").
function Spells.adopt(s, key, id, name)
  if not (s and type(key) == "string" and key ~= "") then return nil end
  if not (type(id) == "number" and id > 0 and type(name) == "string" and name ~= "") then return nil end
  if s[key] then return key end
  s[key] = { key = key, id = id, name = name, source = "import" }
  return key
end

-- Spells.list(s) -> rows, sorted by NAME so the page reads the same way twice in a row -- `pairs()`
-- carries no order at all, and a list that reshuffled on every open would be unusable.
function Spells.list(s)
  local rows = {}
  for _, entry in pairs(s or {}) do rows[#rows + 1] = entry end
  table.sort(rows, function(a, b)
    if a.name == b.name then return a.key < b.key end
    return a.name < b.name
  end)
  return rows
end

-- Every field `keySource` this file must follow to find a spell key inside a condition. `spells` is
-- every pack spell; `seals`/`runes`/`castables` (Core/Conditions.lua) are all NARROWER views of the
-- SAME pack.spells table, so a condition built against any of the four still names a spell key.
local SPELL_KEY_SOURCES = { spells = true, seals = true, runes = true, castables = true }

-- Walks one stored condition (which may be a nested "all"/"any"/"not" composite) and adds every
-- spell key it names to `out`. A condition is exactly as much a "use" of a spell as a cast line is
-- (D56): a build gating Divine Storm on `{"buff","SOMETHING"}` is still naming a spell, and removing
-- the registry entry under it would leave the condition pointing at nothing that explains itself.
local function collectConditionKeys(when, out)
  if type(when) ~= "table" then return end
  local kind = when[1]
  -- "all"/"any" are composite keywords, never entries in Conditions.FIELDS, so falling past this
  -- branch would only ask Conditions.field("all"/"any") and get nil back -- inert either way.
  if kind == "all" or kind == "any" then
    for i = 2, #when do collectConditionKeys(when[i], out) end
    return -- mutants: equivalent see the comment above this branch
  end
  if kind == "not" then collectConditionKeys(when[2], out); return end
  local field = ns.Conditions and ns.Conditions.field and ns.Conditions.field(kind)
  if field and SPELL_KEY_SOURCES[field.keySource] then
    local key = when[field.keyAt or 2]
    if type(key) == "string" then out[key] = true end
  end
end

-- Spells.referencedKeys(build) -> { [key] = true, ... }
--
-- Every spell key a build actually uses: the direct casts (`entry.spell`) AND every condition that
-- names one. Used both for the "used by" column (D55) and the removal guard (D56) -- one walk, so
-- the two can never disagree about what "in use" means.
function Spells.referencedKeys(build)
  local out = {}
  for _, entry in ipairs((build and build.entries) or {}) do
    if type(entry) == "table" then
      if type(entry.spell) == "string" then out[entry.spell] = true end
      for _, when in ipairs(entry.when or {}) do collectConditionKeys(when, out) end
    end
  end
  return out
end

-- Spells.usedBy(rotations, key) -> sorted list of rotation names
--
-- `rotations` is `[{ name =, keys = <a Spells.referencedKeys() table> }]` -- the caller (Options,
-- which already knows how to enumerate this character's templates and forks) hands over the keysets
-- it computed, so this file stays ignorant of the build/entries format Schema owns.
function Spells.usedBy(rotations, key)
  local names = {}
  for _, r in ipairs(rotations or {}) do
    if r.keys and r.keys[key] then names[#names + 1] = r.name end
  end
  table.sort(names)
  return names
end

-- Spells.remove(s, key, rotations) -> true | false, names
--
-- Guarded (D56). Still referenced by anything: refused, and `names` lists who holds it so the row
-- can say so. Not referenced but automatic ("pack"): still refused -- "only manually added entries
-- with no reference are removable" is the literal rule, because a pack entry is DERIVED (it comes
-- back on its own the moment something references it again) rather than owned, and there is nothing
-- for a delete to mean here that resyncing would not immediately undo.
function Spells.remove(s, key, rotations)
  local entry = s and s[key]
  if not entry then return false, {} end
  local usedBy = Spells.usedBy(rotations, key)
  if #usedBy > 0 then return false, usedBy end
  if entry.source == "pack" then return false, {} end
  s[key] = nil
  return true, {}
end

ns.Spells = Spells
return Spells
