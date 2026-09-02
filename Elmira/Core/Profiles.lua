-- Elmira/Core/Profiles.lua — which build should be active?
--
-- PURE (hard rule 3): takes a data pack and a profile table, returns a build key. No WoW API.
--
-- M4 grows this into the documented rule list (class, talents, weapon, set counts, ItemRack override
-- — docs/01 §3). M3 needs only the part without which nothing can be displayed at all: *some* build,
-- chosen predictably. Written here rather than inlined into the display so M4 extends one resolver
-- instead of discovering a second one hiding behind the queue.
--
-- Order matters and is deliberate:
--   1. what the user pinned — an explicit choice outranks every heuristic, always
--   2. the catalog's recommended entry, if it is available
--   3. the first available catalog entry
--   4. any build in the pack, sorted, so a pack with no catalog still shows something
-- Sorting at step 4 is not cosmetic: `pairs()` order is undefined, so without it a pack with two
-- builds would pick a different one between reloads and look like a bug in the engine.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Profiles = {}

-- Catalog entries are per class: pack.catalog[CLASS] is an ordered list (docs/02 "Catalog entry").
local function catalogFor(pack)
  if type(pack.catalog) ~= "table" then return nil end
  if type(pack.class) == "string" and type(pack.catalog[pack.class]) == "table" then
    return pack.catalog[pack.class]
  end
  return nil
end

local function buildExists(pack, key)
  return type(key) == "string" and type(pack.builds) == "table" and pack.builds[key] ~= nil
end

-- Returns buildKey, reason. `reason` names which rule fired, so `/elm debug` can explain a choice
-- the user did not make — "why is it showing Exodin?" is otherwise unanswerable.
-- M4 rule 2: a loadout label from an override source (ItemRack, docs/08). The label is the ONLY
-- thing an override source supplies — gear-derived facts come from the debounced equipment path,
-- never from inside the override callback, because that hook fires before the new gear is in the
-- slots (docs/01 §3, docs/08). The label-to-build mapping is per USER, not shipped: "Shockadin" is
-- one person's set name, and a catalog that guessed at set names would be wrong for everyone else.
local function fromOverride(pack, profile, label)
  if type(label) ~= "string" or label == "" then return nil end
  local map = profile and profile.overrides
  local key = type(map) == "table" and map[label] or nil
  if key and buildExists(pack, key) then
    return key, "ItemRack set '" .. label .. "'"
  end
  return nil
end

-- M4 rule 3: the best catalog entry this character can actually play.
--
-- `fits` is injected rather than imported: the requirement check lives in Setup/Detect.lua, and Core
-- depending on Setup would invert the layering. It answers true / false / nil, and nil ("could not
-- tell") must never disqualify an entry — an unreadable tooltip is not a reason to refuse someone a
-- build. That is hard rule 8's reasoning: `requires` is advisory and never changes evaluation.
local function fromDetection(pack, fits)
  if type(fits) ~= "function" then return nil end
  local catalog = catalogFor(pack)
  if not catalog then return nil end

  local best, bestReason
  for _, entry in ipairs(catalog) do
    if entry.available and buildExists(pack, entry.build) then
      local ok = fits(entry)
      if ok ~= false then
        if entry.recommended then
          return entry.build, "fits this character (recommended)"
        elseif not best then
          best, bestReason = entry.build, "fits this character"
        end
      end
    end
  end
  return best, bestReason
end

-- `ctx` is optional and additive: { override = <loadout label>, fits = <function(entry)> }. A caller
-- that passes nothing gets exactly the M3 behaviour, which is why every M3-era call site and spec is
-- unaffected by M4's rules landing.
function Profiles.resolve(pack, profile, ctx)
  if type(pack) ~= "table" or type(pack.builds) ~= "table" then return nil, "no data pack" end
  ctx = ctx or {}

  -- 1. Explicit user choice. `false` is the DB's "unset" sentinel, not a key.
  local pinned = profile and profile.activeBuild
  if pinned and pinned ~= false then
    if buildExists(pack, pinned) then return pinned, "pinned" end
    -- A pinned key that no longer resolves means the pack changed under the user (a build was
    -- renamed, or a class pack was downgraded). Fall through rather than showing nothing, but say so.
    return Profiles.fallback(pack, "pinned build '" .. tostring(pinned) .. "' is not in this pack")
  end

  -- 2. What the player's loadout addon says they are wearing.
  local byOverride, overrideReason = fromOverride(pack, profile, ctx.override)
  if byOverride then return byOverride, overrideReason end

  -- 3. What this character can actually play.
  local byDetection, detectionReason = fromDetection(pack, ctx.fits)
  if byDetection then return byDetection, detectionReason end

  return Profiles.fallback(pack, nil)
end

function Profiles.fallback(pack, note)
  local catalog = catalogFor(pack)
  if catalog then
    for _, entry in ipairs(catalog) do
      if entry.available and entry.recommended and buildExists(pack, entry.build) then
        return entry.build, note or "catalog recommended"
      end
    end
    for _, entry in ipairs(catalog) do
      if entry.available and buildExists(pack, entry.build) then
        return entry.build, note or "first available in catalog"
      end
    end
  end

  local keys = {}
  for key in pairs(pack.builds) do keys[#keys + 1] = key end
  table.sort(keys)
  if keys[1] then return keys[1], note or "only build in pack" end
  return nil, note or "pack has no builds"
end

ns.Profiles = Profiles
return Profiles
