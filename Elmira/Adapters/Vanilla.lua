-- Elmira/Adapters/Vanilla.lua — Classic Era / SoD implementation of the State contract.
--
-- This and Collector.lua are the only files under Elmira/ permitted to name a WoW global (hard rule
-- 3, enforced by .luacheckrc). Core sees only the table newState() returns.
--
-- Members are defined with COLON syntax because Core calls them that way (`state:cooldown(key)` in
-- Engine.lua and Schema.lua). Under dot syntax the state table itself arrives as the spell key and
-- every lookup silently misses — docs/01 §2 now states this explicitly.
--
-- Every accessor takes a SYMBOLIC KEY ("EXORCISM"), never a numeric id: Core must not know ids
-- (hard rule 4). Resolution to an id happens here, against the registered data pack.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Vanilla = {}

-- Readings at or below this are the global cooldown, not a spell's own. GetSpellCooldown returns the
-- GCD for ANY spell while the GCD runs (docs/07 §9.10), so caching one records 1.5 s as Exorcism's
-- cooldown forever. 1.6 leaves headroom for the 1.5 s GCD without swallowing a real short cooldown.
local GCD_CEILING = 1.6

local INVSLOT_SHOULDER = 3
-- The TEN slots Season of Discovery lets you engrave: helm, chest, belt, legs, boots, wrist, gloves,
-- both rings, cloak. Owner-confirmed and client-swept 2026-09-03. This list shipped as
-- { 1, 5, 6, 7, 8, 9, 10 }, which made every ring and CLOAK rune invisible: `rune` gates on
-- RUNE_RIGHTEOUS_VENGEANCE (all Ret), RUNE_SHIELD_OF_RIGHTEOUSNESS (Prot) and RUNE_SHOCK_AND_AWE
-- (Shockadin) could never be true, and the wizard told you to engrave runes you were wearing.
-- M2's in-game pass reported "all 7 runes match" -- seven, the exact number it was able to see.
--
-- Do NOT read `rune.equipmentSlot` back to learn which slot answered: the client does not set it to
-- the slot you queried. Observed live, querying 12 returned equipmentSlot=11 and querying 15
-- returned equipmentSlot=16. The queried slot is the truth.
local RUNE_SLOTS = { 1, 5, 6, 7, 8, 9, 10, 11, 12, 15 }

-- docs/07 §9.5: IsEngravingEnabled() is a real, independent call. Deriving both flags from
-- `C_Engraving ~= nil` made them incapable of ever disagreeing, which is what the M0 stub did.
function Vanilla.capabilities()
  local hasEngravingAPI = C_Engraving ~= nil
  local engravingOn = hasEngravingAPI
    and C_Engraving.IsEngravingEnabled ~= nil
    and C_Engraving.IsEngravingEnabled() == true
  return {
    runes = hasEngravingAPI,   -- can we ASK about runes?
    engraving = engravingOn,   -- is engraving actually enabled for this character?
    setAPI = false,
    -- Follows the library's REAL presence, not a hardcoded answer. A capability that cannot vary is
    -- not a capability -- `runes`/`engraving` were derived from one expression until docs/07 §9.5
    -- showed they genuinely disagree, and this flag was `false` in a file that shipped the wrapper.
    swing = ns.Swing ~= nil and ns.Swing.available() == true,
    -- Whether the client will report PER-ADDON memory. Classic Era does; a client that does not
    -- must make `/elm debug perf` say so rather than quietly fall back to the whole-heap number.
    addonMemory = (UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)) ~= nil,
    inspect = false,
    nameplates = false,
    -- D25/D49: does this client have the FrameXML helper that answers "does this chat window show
    -- System messages?" Display/Announcers picks the windows to print in with it, and falls back --
    -- to the frame's own method, then to the raw `messageTypeList`, then to DEFAULT_CHAT_FRAME --
    -- when it is missing, which on this install it always is: grepping every installed addon for
    -- the name returns zero hits. Declared here because that is where a non-universal global is
    -- allowed to be named at all, and so `/elm debug state` can say which tier a client is on.
    chatMessageGroups = ChatFrame_ContainsMessageGroup ~= nil,
    seal = true,               -- paladin seal accessor; class-gated at M5 when other classes land
    -- R2 (D53/D54c): can this client turn a spell NAME back into an id at all? True on Classic Era,
    -- where GetSpellInfo still accepts a string; declared as its own flag because the retail
    -- replacement does not (see Adapters/Interface.lua's comment on this flag).
    spellNameLookup = GetSpellInfo ~= nil,
    -- AT4-D2: can we ask whether another addon is loaded? The texture library offers WeakAuras'
    -- and PowerAuras' files by PATH (never a copy of one) only on a character that has WeakAuras
    -- running, and this is the one call that can tell. Both spellings, for the same reason
    -- addonMemory above takes both: Classic Era still has the bare global and retail moved it.
    addonLoaded = (IsAddOnLoaded or (C_AddOns and C_AddOns.IsAddOnLoaded)) ~= nil,
  }
end

-- Vanilla.addonLoaded(name) -> is that addon loaded right now (AT4-D2)
--
-- LOADED, not merely installed: an addon disabled for this character, or one still waiting on
-- demand, cannot have handed its files to the client, and a picker offering them would draw a grid
-- of empty cells. false on a client with neither call, which is what the capability flag above
-- declares -- never nil, so a caller can use the answer as a plain condition.
function Vanilla.addonLoaded(name)
  if type(name) ~= "string" or name == "" then return false end
  local loaded = IsAddOnLoaded or (C_AddOns and C_AddOns.IsAddOnLoaded)
  if not loaded then return false end
  -- `1` as well as `true`: this call is one of the ones that returned a number for most of the
  -- client's life, and a boolean-only test would read every installed addon as absent on a build
  -- that still answers the old way.
  local answer = loaded(name)
  return answer == true or answer == 1
end

function Vanilla.detect()
  local build, revision, date, tocversion = GetBuildInfo()
  return {
    project = WOW_PROJECT_ID,
    isClassic = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC,
    build = build, revision = revision, date = date, interface = tocversion,
  }
end

function Vanilla.addonVersion()
  local version
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    version = C_AddOns.GetAddOnMetadata(ADDON, "Version")
  elseif GetAddOnMetadata then
    version = GetAddOnMetadata(ADDON, "Version")
  end
  return version or "dev"
end

-- Memory used by the Elmira addon family, in KB, or nil when the client will not say.
--
-- `/elm debug perf` asks "is Elmira expensive". `collectgarbage("count")` cannot answer that -- it
-- reports the whole client's Lua heap, every addon included, so a 300 MB reading says nothing about
-- us. This is the number that does. Summed across the family rather than the core addon alone,
-- because the class pack and the integration modules are Elmira's cost too.
--
-- nil, never 0, when the API is absent: "we could not tell" and "it is free" must not look alike.
function Vanilla.addonMemoryKB()
  local update = UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)
  local usage = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage)
  local count = C_AddOns and C_AddOns.GetNumAddOns
  local info = C_AddOns and C_AddOns.GetAddOnInfo
  if not (update and usage and count and info) then return nil end
  -- The figures are a snapshot the client refreshes only on request, so without this every reading
  -- after the first would be the same stale number.
  update()
  local total = 0
  for i = 1, count() do
    local name = info(i)
    if name and name:sub(1, 6) == "Elmira" then total = total + (usage(i) or 0) end
  end
  return total
end

-- The calendar date, for provenance stamps (a fork's `importedAt`, ADR-0010). Core never reads the
-- clock; `date` is the client's global.
function Vanilla.today()
  return date and date("%Y-%m-%d") or nil
end

-- Is the player typing into something right now?
--
-- An adapter EXTRA, not a State contract member: no condition in docs/02 reads it and adding one
-- would mean editing the contract, the null state and interface_spec for something only the
-- options panel wants. It is here rather than in Options/ because it names a WoW global, and
-- Adapters/ is the only place that may (hard rule 3).
--
-- Why anything needs it: EVERY AceConfig `set` rebuilds the whole panel, and an AceGUI EditBox
-- commits only on Enter -- so a rebuild that arrives while someone is halfway through typing "90"
-- into a condition value discards what they typed, with no error and nothing to look at. The
-- Builder's live refresh asks this before it repaints.
--
-- Presence-checked rather than assumed. `GetCurrentKeyBoardFocus` is a FrameXML global, not a
-- documented C API, and a client without it must degrade to "not typing" (the panel refreshes a
-- little too eagerly) rather than erroring out of the render loop.
function Vanilla.typing()
  if not GetCurrentKeyBoardFocus then return false end
  return GetCurrentKeyBoardFocus() ~= nil
end

function Vanilla.playerClass()
  local _, class = UnitClass("player")
  return class
end

-- Talent points per tree, for Setup/Detect's spec heuristic. An adapter EXTRA, deliberately not a
-- State contract member: no condition in docs/02 reads talents, and adding one would mean editing
-- the contract, its doc, the null state and interface_spec for something only the wizard wants.
--
-- The call shape is the one docs/07 §9.8 recorded from the live client, not the one the API docs
-- describe: GetTalentTabInfo does NOT return the name first. Position 1 is a numeric tab id
-- (382 Holy / 383 Prot / 381 Ret for paladins) and points spent are at position 5. Collector.lua
-- learned this the hard way; naming the first return `first` here keeps the mistake un-repeatable.
function Vanilla.talents()
  if not GetTalentTabInfo then return nil end
  local tabs, total, top, topPoints = {}, 0, nil, -1
  for i = 1, 3 do
    local ok, first, _, _, _, points = pcall(GetTalentTabInfo, i)
    -- A tab the client cannot describe means the whole reading is unusable. Without this the loop
    -- built three tabs of zero points and reported "tree 1, 0 points spent" — a confident answer
    -- that a level-1 character is Holy, which is worse than admitting we do not know.
    if not ok or first == nil then return nil end
    points = tonumber(points) or 0
    tabs[i] = { id = first, points = points }
    total = total + points
    if points > topPoints then top, topPoints = i, points end
  end
  -- `top` is the tree with the most points — a heuristic, and named as one. A 31/0/20 paladin is
  -- "Holy" by this measure and plays as a Shockadin hybrid; the wizard offers, it never decides.
  return { tabs = tabs, total = total, top = top, topPoints = topPoints }
end

-- Which of the pack's spells this character actually knows. An adapter EXTRA for the same reason
-- talents are one: no condition in docs/02 asks it, only the wizard's requirement check does.
--
-- `known` is NOT `usable`. The State's `usable()` answers "can I cast this right now", which is
-- false when out of mana or out of range — a fine answer for the engine and a terrible one for
-- "do you have this ability", which is what a requirement means.
function Vanilla.knownSpells(spells)
  if not (IsPlayerSpell and type(spells) == "table") then return nil end
  local out = {}
  for key, record in pairs(spells) do
    local id = type(record) == "table" and record.id
    if type(id) == "number" and id > 0 then
      -- A failed call leaves the key ABSENT, not false. Folding it to false would say "you do not
      -- know this" on the strength of a call that did not answer — the same conflation this whole
      -- record exists to avoid, just at per-key granularity instead of per-table.
      local answer = Vanilla.knownById(id)
      if answer ~= nil then out[key] = answer end
    end
  end
  return out
end

-- Loads an EXTERNAL class pack -- a separate addon claiming this class with `## X-Elmira-Class`.
-- Shipped classes come from Elmira/Classes/<Class>.lua and never take this path (ADR-0011 §3 keeps
-- the scan anyway: it is the whole third-party extension route).
--
-- Returns `loaded, reason, name`. The reason is LoadAddOn's own failure token when an addon claims
-- the class and fails to load, and the distinct "no-pack" when nothing claims it at all. Those are
-- different problems -- one is a broken install, the other is the normal case for eight of nine
-- classes -- and returning only `false` for both is what made them one log line.
function Vanilla.loadClassPack(class)
  if not (class and C_AddOns and C_AddOns.GetNumAddOns) then return false, "no-scan" end
  for i = 1, C_AddOns.GetNumAddOns() do
    local name = C_AddOns.GetAddOnInfo(i)
    if C_AddOns.GetAddOnMetadata(name, "X-Elmira-Class") == class then
      local loaded, reason = C_AddOns.LoadAddOn(name)
      return loaded, reason, name
    end
  end
  return false, "no-pack"
end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------

local function idOf(spells, key)
  local record = spells and spells[key]
  if type(record) ~= "table" then return nil end
  local id = record.id
  -- A 0 is not an id, it is a placeholder. Treating it as one produces a lookup that can never
  -- match and never errors, so reject it here rather than passing it to the client.
  if type(id) ~= "number" or id <= 0 then return nil end
  return id
end

local scanTooltip
local SCAN_NAME = "ElmiraStateScanTooltip"

local function tooltipLines(slot)
  if not CreateFrame then return {} end
  if not scanTooltip then
    scanTooltip = CreateFrame("GameTooltip", SCAN_NAME, nil, "GameTooltipTemplate")
    if scanTooltip.SetOwner and UIParent then scanTooltip:SetOwner(UIParent, "ANCHOR_NONE") end
  end
  scanTooltip:ClearLines()
  scanTooltip:SetInventoryItem("player", slot)
  -- BOTH columns. A weapon tooltip puts "132 - 199 Damage" on the left and "Speed 2.10" on the
  -- RIGHT of the same line, so a left-only scan silently never finds the speed — which is why the
  -- first fix for base weapon speed did nothing in game and quietly fell back to the hasted value.
  local lines = {}
  for i = 1, scanTooltip:NumLines() do
    local left = _G[SCAN_NAME .. "TextLeft" .. i]
    local leftText = left and left:GetText()
    if leftText and leftText ~= "" then lines[#lines + 1] = leftText end
    local right = _G[SCAN_NAME .. "TextRight" .. i]
    local rightText = right and right:GetText()
    if rightText and rightText ~= "" then lines[#lines + 1] = rightText end
  end
  return lines
end

-- Base weapon speed from the item tooltip. Classic exposes it nowhere else: GetItemInfo returns the
-- equip location but no speed, and UnitAttackSpeed is already hasted. Falls back to nil (not to a
-- plausible-looking number) when the line is absent, so the caller can tell "unknown" from "2.10".
local function baseWeaponSpeed(slot)
  for _, line in ipairs(tooltipLines(slot)) do
    local speed = line:match("[Ss]peed%s+([%d%.]+)")
    if speed then return tonumber(speed) end
  end
  return nil
end

-- Builds a fresh State over a data pack. Returning a new table rather than mutating a singleton
-- keeps specs independent and means a profile/class switch cannot leave stale cached ids behind.
-- The spell NAMES in the player's spellbook, rank-free, cached until something changes them.
--
-- Cached because `S:known` is asked once per palette row and once per gated entry, and the scan
-- walks the whole book. Invalidated from Core/Init on SPELLS_CHANGED, which is already watched --
-- and which fires when a RANK is learned, the case this exists for.
local spellbookCache = nil -- mutants: equivalent deletion only makes it a global

-- The booktype the scan asks for. Named rather than inlined because it is the one value in this
-- fix that no headless test can prove: a wrong constant reads an empty book, `known` falls back to
-- the id alone, and the rank defect returns silently.
--
-- VERIFIED on the live 1.15 client, 2026-09-05:
--   /dump GetSpellBookItemName(1, "spell")  ->  [1]="Attack", [2]="", [3]=6603
-- Three returns: name, rank subtext, spellID. The rank subtext is empty here, which matches
-- docs/07 §9.6 -- which is why the NAME is what this file matches on and the id is not enough.
local BOOKTYPE = "spell"

-- A spell listed but not yet learnable (a higher rank the trainer will sell you) must not count as
-- known, or the palette ungreys abilities you cannot cast. Guarded: on a client with no
-- GetSpellBookItemInfo the filter is simply absent, which is the behaviour before this existed.
local function futureSpell(index)
  -- No guard on the function existing: the pcall answers for a missing one by failing, which is
  -- the same "no filter" outcome.
  local ok, kind = pcall(GetSpellBookItemInfo, index, BOOKTYPE)
  return ok and kind == "FUTURESPELL"
end

-- What the last scan found, for `/elm debug alloc`: a book the client would not read whole is
-- re-scanned for every unknown spell on every frame, and nothing else in the diagnostics can see
-- that happening.
local lastScan = { stoppedAt = 0, partial = false, count = 0 }

local function spellbookNames()
  if spellbookCache ~= nil then return spellbookCache end
  -- No guard on GetSpellBookItemName existing: the pcall below answers for a missing function by
  -- failing on the first index, which is the same "read nothing" case as an unreadable book.
  -- `names` is allocated on the first name the client gives, not before: a client that answers
  -- nothing is asked again on every call (see the end of this function), and on the render loop
  -- that must not cost a table per ask.
  local names, i, partial = nil, 1, false
  while true do
    local ok, name = pcall(GetSpellBookItemName, i, BOOKTYPE)
    -- A THROW is not the end of the book, and neither is a blank name. Telling the two apart is
    -- what stops a scan that died at index 40 from being cached as the whole spellbook: everything
    -- past 40 would then read "not learned" until the next SPELLS_CHANGED or a /reload.
    if not ok then partial = true break end
    if not name or name == "" then break end
    names = names or {}
    if not futureSpell(i) then names[name] = true end
    i = i + 1
    -- A spellbook cannot be this long. Without a bound, a client that answers a name for every
    -- index would hang the login rather than degrade.
    if i > 1024 then partial = true break end
  end
  lastScan.stoppedAt, lastScan.partial, lastScan.count = i, partial, i - 1
  -- Nothing read at all is "the client would not answer", not "an empty spellbook".
  if i == 1 then return nil end
  -- Usable right now, but never latched: the next call tries again for the part that was missed.
  if partial then return names end
  spellbookCache = names
  return names
end

-- R2 (D53/D54a): the Spells page's "From spellbook" picker needs an ID beside every name, which
-- `spellbookNames()` throws away on purpose (it only ever answers "known?"). A SEPARATE scan rather
-- than teaching that one to keep ids: caching this list under the same whole-book rule would trade
-- a `known()` slowdown for a `/elm config` one every time either function's cache is cleared, for no
-- shared benefit -- the Spells page is opened rarely, never from the render loop.
--
-- Not cached at all: a page that lists what the client already knows can afford to ask again.
function Vanilla.spellbookEntries()
  local out, i = {}, 1
  while true do
    local ok, name, _, id = pcall(GetSpellBookItemName, i, BOOKTYPE)
    if not ok or not name or name == "" then break end
    if not futureSpell(i) and type(id) == "number" and id > 0 then
      out[#out + 1] = { id = id, name = name }
    end
    i = i + 1
    if i > 1024 then break end -- same bound as spellbookNames(), same reason
  end
  return out
end

-- R2 (D53/D54b): "By ID" shows what the id resolves to before storing it, so a typo reads as
-- "not found" rather than silently registering the wrong spell.
function Vanilla.spellNameByID(id)
  if type(id) ~= "number" or id <= 0 or not GetSpellInfo then return nil end
  local ok, name = pcall(GetSpellInfo, id)
  if not ok or not name or name == "" then return nil end
  return name
end

-- R2 (D53/D54c, capability `spellNameLookup`): "By name" resolves ONLY a name this client's own
-- cache already holds -- GetSpellInfo answers nil for anything it has never seen, which is exactly
-- the "this character has not seen it" boundary the add row is required to respect. The exact-match
-- check on the returned name (not just "did it answer at all") is what stops a near-miss
-- ("exorcism") from silently registering under the text the player actually typed.
function Vanilla.spellIDByName(name)
  if type(name) ~= "string" or name == "" or not GetSpellInfo then return nil end
  local ok, resolvedName, _, _, _, _, _, id = pcall(GetSpellInfo, name)
  if not ok or resolvedName ~= name or type(id) ~= "number" or id <= 0 then return nil end
  return id
end

-- How many times the held answers have been dropped this session. Every character-change event
-- costs a spellbook re-scan (a table of every name you know) on the next ask, so a client firing
-- one of those events every frame would look, from `/elm debug memory`, exactly like a cache that
-- does not work.
local forgets = 0

-- One line for `/elm debug alloc`.
function Vanilla.spellbookStatus()
  local status = "spellbook: not read yet"
  if spellbookCache ~= nil then
    status = string.format("spellbook: cached, %d entries read", lastScan.count)
  elseif lastScan.partial then
    status = string.format("spellbook: NOT cached -- the client stopped answering at index %d, so every"
      .. " unknown spell re-scans %d entries per frame", lastScan.stoppedAt, lastScan.count)
  elseif lastScan.stoppedAt > 0 then
    status = "spellbook: NOT cached -- the client answered nothing"
  end
  return string.format("%s; character-change forgets this session: %d", status, forgets)
end

-- "Do you know this spell", rank-free, for ANY caller that has an id.
--
-- Exists so `S:known`, `Vanilla.knownSpells` and the `/elm debug` dump cannot answer the same
-- question differently. They did: the state contract got the rank fix and the other two kept asking
-- IsPlayerSpell about a max-rank id, so the Rotations tab's "needs gear or runes you do not have"
-- tag and the dump the player sends you would both still be wrong.
--
-- Returns true / false / nil, and nil means "neither source answered" -- never "no".
-- `known` per id, held for exactly as long as the spellbook scan behind it: both are cleared by
-- `forgetSpellbook`, which Core/Init calls on SPELLS_CHANGED, PLAYER_LEVEL_UP and RUNE_UPDATED --
-- every event that can change the answer. Nothing else can.
--
-- Worth caching rather than merely deduplicating per frame: measured on the live client, the queue
-- asked this 270 times per recompute for about thirty distinct spells, and the answer had not
-- changed since login. `false` and `nil` are DIFFERENT answers here ("not known" vs "the client
-- would not say"), so a plain table cannot hold both -- NOT_ANSWERED is what keeps the second one
-- cacheable instead of re-asking a client that is not answering, forty times a second.
local NOT_ANSWERED = {}
local knownCache = {} -- mutants: equivalent deletion only makes it a global

-- Answers that hold until the CHARACTER changes -- a rune, a rank, a level, a piece of gear -- and
-- that cost a client-built table or a tooltip scan to produce. Keyed by id or by slot, never by a
-- pack's symbolic key, so one copy serves every state. Emptied by `forgetSpellbook`, which
-- Core/Init calls on every event that can move one of them, and by `newState`, because a new pack
-- may give the same shoulders a different soul name.
local costAmount, costKind = {}, {}   -- [spellID] = amount; [spellID] = power kind, or false
local runeAt = {}                     -- [abilitySpellID] = true / false
local enchantAt = {}                  -- [slot] = soul key, or false
local weaponAt = {}                   -- [slot] = { type=, itemID=, speed=, hastedSpeed= }, or false

local function clear(t)
  for k in pairs(t) do t[k] = nil end
end

local function forgetCharacter()
  clear(costAmount); clear(costKind); clear(runeAt); clear(enchantAt); clear(weaponAt)
end

function Vanilla.knownById(id)
  if type(id) ~= "number" then return nil end

  local held = knownCache[id]
  if held ~= nil then
    if held == NOT_ANSWERED then return nil end
    return held
  end

  local answered = false
  if IsPlayerSpell then
    local ok, known = pcall(IsPlayerSpell, id)
    if ok then
      -- Cached unconditionally: a plain yes from IsPlayerSpell owes nothing to the spellbook scan,
      -- so a truncated book cannot make it wrong.
      if known == true then knownCache[id] = true; return true end
      answered = true
    end
  end

  -- Ranks: the client reports whichever rank the player owns, the pack ships one id (the max rank),
  -- and names have no rank. Display/BarGlow.lua says the same thing about bar buttons.
  local names = spellbookNames()
  local name
  if names and GetSpellInfo then
    local ok, resolved = pcall(GetSpellInfo, id)
    if ok then name = resolved end
  end

  -- Everything below this line is derived from the spellbook, so it may only be cached when the
  -- book was read WHOLE. `spellbookNames` deliberately refuses to cache a scan that died partway
  -- (a client that gave up at index 40 is not a player who knows nothing past 40), and caching the
  -- derived answer would reintroduce that defect one level up: every spell past the failure would
  -- read "not known" until the next SPELLS_CHANGED or a /reload, silently. `spellbookCache` being
  -- non-nil IS the "the book was complete" flag -- see spellbookNames.
  --
  -- "The client would not say" is a real answer and a different one from "no", so it is cached too
  -- -- but only under the same whole-book rule, or a client still starting up would have its
  -- silence frozen in for the rest of the session. Plain branches rather than a `remember` closure:
  -- an uncacheable miss is re-asked on every render-loop tick, and a closure per ask was measurable.
  local answer = NOT_ANSWERED
  if name then answer = names[name] == true
  elseif answered then answer = false end
  if spellbookCache ~= nil then knownCache[id] = answer end
  if answer == NOT_ANSWERED then return nil end
  return answer
end

-- Called from Core/Init when spells change. The upvalue starts nil, so a fresh session has no
-- book to forget and nothing calls this at load.
function Vanilla.forgetSpellbook()
  forgets = forgets + 1
  spellbookCache = nil
  -- Both, always. `knownCache` is derived from the book; clearing one without the other leaves the
  -- derived answer outliving the source it came from, which is a rune engraved and a rotation that
  -- goes on ignoring it until /reload.
  knownCache = {}
  -- And everything else held until the character changes: the events that reach here (a spell
  -- learned, a level, a rune, a piece of gear) are the same ones that move a cost, a rune, a soul or
  -- a weapon, so one forget covers all of them.
  forgetCharacter()
  return true
end

function Vanilla.newState(spells, sets, souls, bonusDefs, sealLingerWindow)
  spells, sets, souls = spells or {}, sets or {}, souls or {}
  -- A new pack is a new set of soul names for the same shoulders; nothing held about the previous
  -- one may answer for it.
  forgetCharacter()

  local S = {}
  -- Observed cooldown durations, keyed by spell key. Never seeded from a shipped value and never
  -- from GetSpellBaseCooldown: that returned 15000 in every gear state while the real cooldown was
  -- 6 s (docs/07 §9.1), so there is no safe static seed and "unknown" must stay unknown.
  local observed = {}

  local function resolve(key) return idOf(spells, key) end

  -- ONE READ PER FRAME, shared by every question asked in it.
  --
  -- Generalised from the aura scan below to every read the client cannot change between two frames.
  -- Measured on the live client 2026-09-05: one queue recompute made 764 client calls -- 315
  -- GetSpellCooldown, 270 IsPlayerSpell, 114 GetInventoryItemID -- to answer questions about
  -- roughly thirty distinct spells and one set of equipped gear, because the queue looks five casts
  -- ahead across every entry and nothing remembered the previous answer. That was 80-91% of the
  -- addon's entire memory footprint (`/elm debug memory`: `simulate`, ~25 KB per recompute).
  --
  -- The memo is STAMPED, not rebuilt. The first version of this cache allocated fresh tables on
  -- every new frame and let the old ones go to the collector, and at four recomputes a second that
  -- was most of what the render loop allocated: measured headlessly with a moving clock, the loop
  -- cost ~21 KB per recompute, and the client agreed (32 KB, `/elm debug memory` round 3). These
  -- tables live for the life of the state; each entry remembers the frame it was read in, and a
  -- stale stamp means "read it again". After the first frame, a steady rotation writes into slots
  -- that already exist and allocates nothing.
  --
  -- `GetTime()` is stamped once per frame by the client, which makes it exactly the right key:
  -- none of these answers can change without a frame boundary.
  local function frame() return GetTime and GetTime() or 0 end

  -- The client's cooldown reading for an id, once per frame. Both `cooldown` (how much is LEFT) and
  -- `baseCooldown` (how long one LASTS) come from this single call: they used to make one
  -- GetSpellCooldown each, so every spell was asked twice per evaluation and five times over by the
  -- lookahead. nil is normalised to 0 because every caller already treats the two the same way.
  local cdStart, cdDuration, cdStamp = {}, {}, {}
  local function cooldownRead(id)
    local stamp = frame()
    if cdStamp[id] ~= stamp then
      local s, d = GetSpellCooldown(id)
      cdStart[id], cdDuration[id], cdStamp[id] = s or 0, d or 0, stamp
    end
    return cdStart[id], cdDuration[id]
  end

  -- Range and mana move within a fight but not within a frame, and the lookahead asks about the
  -- same spell once per simulated slot.
  --
  -- PE9-D2: `IsUsableSpell` answers `usable, noMana`, and the second value was thrown away here.
  -- The two failures it separates look identical through the first return and must not be drawn
  -- the same way: out of MANA is a fact about you that will not change by itself, out of RANGE is
  -- one that changes as you take two steps. The strip dims on the resource case only; a range
  -- reading would strobe the icon of every melee player running at a target.
  local usableAt, usableNoResource, usableStamp = {}, {}, {}
  local function usableRead(id)
    local stamp = frame()
    if usableStamp[id] ~= stamp then
      local ok, noResource = IsUsableSpell(id)
      usableAt[id], usableNoResource[id], usableStamp[id] = ok == true, noResource == true, stamp
    end
    return usableAt[id], usableNoResource[id]
  end

  -- Gear cannot change mid-frame either, and `setCount` walked all nineteen slots once PER SET --
  -- six sets, 114 reads, for nineteen answers.
  local equippedAt, equippedStamp = {}, {}
  local function equippedRead(slot)
    local stamp = frame()
    if equippedStamp[slot] ~= stamp then
      equippedAt[slot], equippedStamp[slot] = GetInventoryItemID("player", slot) or false, stamp
    end
    return equippedAt[slot] or nil
  end


  function S:now() return GetTime() end

  -- THE hot path, and not the one anyone would guess. Both of these walk the WHOLE spell table
  -- looking for something showing a GCD-length cooldown, and out of combat nothing is, so both run
  -- to completion every time. Core/Simulation asks for them once per simulated slot, so a
  -- five-deep lookahead ran the scan ten times: measured on the shipped pack, 264 of the queue's
  -- 764 client calls per recompute were these two, not the rotation's own conditions.
  --
  -- Three things fix that, and all three are needed. The scan reads through `cooldownRead` and
  -- `knownById` so the calls it does make are the cached ones; the ANSWER is then memoised for the
  -- frame, because the global cooldown is one fact about the character rather than a per-spell one;
  -- and the two share a single pass, since they were walking the same table looking at the same
  -- reading and disagreeing only about which half of it to return.
  local gcdStamp, gcdRemaining, gcdLength = nil, 0, nil
  local function gcdScan()
    local stamp = frame()
    if gcdStamp == stamp then return gcdRemaining, gcdLength end
    gcdStamp, gcdRemaining, gcdLength = stamp, 0, nil
    for key in pairs(spells) do
      local id = resolve(key)
      if id and Vanilla.knownById(id) == true then
        local start, duration = cooldownRead(id)
        if duration > 0 and duration <= GCD_CEILING then
          local remaining = (start + duration) - GetTime()
          gcdRemaining = remaining > 0 and remaining or 0
          gcdLength = duration
          break
        end
      end
    end
    return gcdRemaining, gcdLength
  end

  -- The GCD is whatever GetSpellCooldown reports for a spell that has no cooldown of its own —
  -- which is the same behaviour that makes baseCooldown dangerous, used deliberately here.
  function S:gcd()
    local remaining = gcdScan()
    return remaining
  end

  -- How long a global cooldown LASTS, as opposed to how much of one is left. Read from whatever
  -- spell is currently showing a GCD-length cooldown; falls back to the 1.5s base when nothing is,
  -- which is the common case out of combat. Melee GCDs are not haste-reduced on this client.
  function S:gcdDuration()
    local _, duration = gcdScan()
    return duration or 1.5
  end

  function S:cooldown(key)
    local id = resolve(key)
    if not id then return 0 end
    local start, duration = cooldownRead(id)
    -- A GCD reading is not this spell's cooldown. Reporting it would make every spell look
    -- unavailable for 1.5 s after any cast. `cooldownRead` normalises "no cooldown" to 0, which
    -- this same test answers for -- there is no separate zero case to check.
    if duration <= GCD_CEILING then return 0 end
    observed[key] = duration
    local remaining = (start + duration) - GetTime()
    return remaining > 0 and remaining or 0
  end

  -- Observe-and-cache. Only a reading taken while the spell is genuinely on cooldown counts.
  function S:baseCooldown(key)
    local id = resolve(key)
    if not id then return 0 end
    local _, duration = cooldownRead(id)
    if duration > GCD_CEILING then observed[key] = duration end
    return observed[key] or 0
  end

  -- Second return is PURELY additive (PE9-D2): the first keeps meaning exactly what it always has,
  -- so every Core caller (Engine's cast filter, Slash's diagnostics, Rotation's status line) is
  -- untouched -- all of them read it in single-value position.
  function S:usable(key)
    local id = resolve(key)
    if not id then return false, false end
    return usableRead(id)
  end

  function S:castTime(key)
    local id = resolve(key)
    if not id then return 0 end
    local _, _, _, ms = GetSpellInfo(id)
    if not ms then return 0 end
    return ms / 1000
  end

  -- Reflects runes on the live client (345 -> 69 measured, docs/07 §9.3), which is why no static
  -- cost table is consulted here. Returns a LIST of cost tables, not a number -- a fresh one on
  -- every call, allocated by the client and charged to us. Held until the character changes
  -- (`forgetCharacter`): a rune, a rank, a level, a set bonus or a talent (Benediction halves a
  -- seal's cost) can move a spell's cost, and each of those arrives as an event Core/Init forwards
  -- here -- the talent one is CHARACTER_POINTS_CHANGED. Nothing that happens between two of them can.
  function S:powerCost(key)
    local id = resolve(key)
    if not id or not GetSpellPowerCost then return 0, nil end
    local amount = costAmount[id]
    if amount == nil then
      local costs = GetSpellPowerCost(id)
      local first = type(costs) == "table" and costs[1] or nil
      amount = first and first.cost or 0
      costAmount[id] = amount
      costKind[id] = first and (first.name or "MANA") or false
    end
    return amount, costKind[id] or nil
  end

  -- One scan of a unit's auras per FRAME, shared by every lookup on it.
  --
  -- This was the addon's single largest cost. Each lookup walked 1..40 and called `UnitAura` TWICE
  -- per index -- the second only to read the spellID, which the first call already returns as its
  -- tenth value -- so a single `buff` condition cost up to 80 calls, each returning a dozen values
  -- including strings. A build with a dozen aura-gated lines, evaluated across five simulated
  -- slots, ran that thousands of times per recompute: the client attributed ~27 MB of garbage to
  -- Elmira per minute standing still in a city, and the addon topped the memory list at 73 MB
  -- before collection (owner's report, 2026-09-05).
  --
  -- `GetTime()` is stamped once per frame by the client, which makes it exactly the right cache
  -- key: auras cannot change without a frame boundary, and the whole of one queue recompute
  -- therefore shares one scan. The simulation's virtual clock never reaches here -- it delegates
  -- `buff` to the real state, which is about NOW by definition.
  --
  -- One record per aura id, kept for the life of the state and stamped with the frame it was last
  -- seen in: an aura that has dropped simply carries an old stamp. The first version of this scan
  -- allocated a table per aura per frame, which with fifteen buffs up in a city was 4 KB per
  -- recompute -- a fifth of everything the loop allocated.
  local auraCache = {}   -- [unit][filter] = { stamp = <frame>, byID = { [spellID] = record } }

  local function auraScan(unit, filter)
    local stamp = frame()
    local byUnit = auraCache[unit]
    if not byUnit then
      byUnit = {}
      auraCache[unit] = byUnit
    end
    local held = byUnit[filter]
    if not held then
      held = { stamp = nil, byID = {} }
      byUnit[filter] = held
    end
    local byID = held.byID
    if held.stamp == stamp then return byID, stamp end

    for i = 1, 40 do
      local name, _, count, _, duration, expires, source, _, _, spellID = UnitAura(unit, i, filter)
      -- The first empty index is the end of the list: the client packs them.
      if not name then break end
      if spellID then
        local rec = byID[spellID]
        if not rec then
          rec = {}
          byID[spellID] = rec
        end
        -- First writer wins, so a longer-lived duplicate cannot be masked by a later stack.
        if rec.stamp ~= stamp then
          rec.stamp, rec.count, rec.duration, rec.expires, rec.source = stamp, count, duration, expires, source
        end
      end
    end
    held.stamp = stamp
    return byID, stamp
  end

  local function findAura(unit, key, filter, mineOnly)
    local id = resolve(key)
    if not id then return nil end
    local byID, stamp = auraScan(unit, filter)
    local aura = byID[id]
    if not (aura and aura.stamp == stamp) then return nil end
    if mineOnly and aura.source ~= "player" then return nil end
    local remaining = aura.expires and (aura.expires - GetTime()) or 0
    local count = aura.count
    return (count and count > 0) and count or 1, remaining > 0 and remaining or 0, aura.duration
  end

  function S:buff(key) return findAura("player", key, "HELPFUL") end
  function S:debuff(key, mine) return findAura("target", key, "HARMFUL", mine == true) end

  -- COMBO_POINTS, added at R2 (D59) for the pack-less rogue this pass exists to serve: with no data
  -- pack there is no spell key to gate on, so "5 combo points" has to be expressible as a plain
  -- power condition instead.
  --
  -- VERIFIED against the live install, 2026-09-07, at
  -- /mnt/d/Blizzard/World of Warcraft/_classic_era_/Interface/AddOns/ -- not written from memory:
  --   * Current value: `GetComboPoints(unit, unit .. '-target')`, the classic-only global (retail
  --     reads combo points through plain `UnitPower`/`Enum.PowerType.ComboPoints` instead — the two
  --     branch on `not oUF.isRetail` right next to each other). Three independent, unrelated addons
  --     on THIS client all read it the same way with no capability check anywhere around it:
  --     ElvUI_Libraries/Game/Shared/oUF/elements/classpower.lua:306, WeakAuras/Prototypes.lua:3858,
  --     PallyPower/Libs/LibClassicDurations/core.lua:341/351. That is what makes it universal enough
  --     to need no flag here, the same as MANA/RAGE/ENERGY below.
  --   * Max value: the FrameXML global `MAX_COMBO_POINTS`, not `UnitPowerMax(unit,
  --     Enum.PowerType.ComboPoints)`. ElvUI reads the global directly and unconditionally in three
  --     places (e.g. ElvUI/Game/Shared/Modules/Nameplates/Elements/ClassPower.lua:10,
  --     `local MAX_COMBO_POINTS = MAX_COMBO_POINTS`) — a client-shipped constant, never toggled, so
  --     there is nothing to gate. UnitPowerMax is the UNSAFE path here: WeakAuras guards its own use
  --     of it with `math.max(1, UnitPowerMax(unit, Enum.PowerType.ComboPoints))`
  --     (WeakAuras/Prototypes.lua:3859) precisely because it can read 0 on this client — exactly the
  --     "max comes back 0" failure this function must not reproduce, so it never calls UnitPowerMax
  --     for this kind at all.
  function S:power(kind)
    if kind == "COMBO_POINTS" then
      local current = GetComboPoints and GetComboPoints("player", "target") or 0
      local max = MAX_COMBO_POINTS
      if type(max) ~= "number" or max <= 0 then max = 5 end
      return current or 0, max
    end
    local index = 0
    if Enum and Enum.PowerType then
      if kind == "RAGE" then index = Enum.PowerType.Rage
      elseif kind == "ENERGY" then index = Enum.PowerType.Energy
      else index = Enum.PowerType.Mana end
    end
    return UnitPower("player", index) or 0, UnitPowerMax("player", index) or 0
  end

  function S:targetType() return UnitCreatureType("target") end
  function S:targetExists() return UnitExists("target") == true end

  -- PE9-D6. "Do you have a target" and "do you have something to fight" are different questions,
  -- and Core/Visibility was asking the first while meaning the second -- so clicking a bank NPC in
  -- Ironforge popped the rotation strip up. UnitCanAttack answers the second, and answers false
  -- for no target at all, so it subsumes targetExists here rather than needing both.
  --
  -- No capability flag: UnitCanAttack has been in the client since 1.12 and is present on every
  -- flavour this addon can run on. `targetExists` stays on the contract because it is a genuinely
  -- different question -- the Rotation panel's context line reports it as "target: yes/no".
  function S:targetAttackable() return UnitCanAttack("player", "target") == true end

  function S:targetHPPct()
    if not UnitExists("target") then return nil end
    local max = UnitHealthMax("target")
    if not max or max <= 0 then return nil end
    return (UnitHealth("target") / max) * 100
  end

  -- UnitAffectingCombat, NOT InCombatLockdown. The latter reports whether the UI is in protected-
  -- function lockdown — related, but not the same question, and it is not yet set at the instant
  -- PLAYER_REGEN_DISABLED fires. Every mark in the first two recordings reported combat=false,
  -- including the ones taken at combat start (docs/07 §9.16). Lockdown remains the right check
  -- before touching a secure frame; it is the wrong answer for "is the player fighting".
  function S:inCombat()
    if UnitAffectingCombat then return UnitAffectingCombat("player") == true end
    return InCombatLockdown() == true
  end
  function S:moving() return (GetUnitSpeed("player") or 0) > 0 end

  -- Takes a SLOT and returns a table, matching Schema.lua's `C.weapon`: it calls state:weapon(slot)
  -- with 16 for 2H/1H and 17 for Shield, then reads `w.type` and `w.speed`.
  --
  -- `speed` is the BASE item speed, parsed from the item tooltip's "Speed 2.10" line — NOT
  -- UnitAttackSpeed, which is haste-modified. The two genuinely diverge: Truthbearer (229749, the
  -- Exodin weapon) is a 2.10 speed 2H carrying a chance-on-hit that grants +30% attack speed for 8 s,
  -- so UnitAttackSpeed reads ~1.6 while the proc is up. A build gating on a speed range would flip
  -- its answer mid-fight on a proc. UnitAttackSpeed is kept as `hastedSpeed` for callers that
  -- genuinely want it (M3b's swing timer), so the two can never be confused for one another.
  --
  -- Held per slot until the character changes: the item, its type and its base speed cannot move
  -- without a PLAYER_EQUIPMENT_CHANGED, and reading them meant a tooltip scan per question, per
  -- simulated slot. `hastedSpeed` is the one live number and is refreshed on every read.
  function S:weapon(slot)
    slot = slot or 16
    local held = weaponAt[slot]
    if held == nil then
      held = false
      local id = GetInventoryItemID("player", slot)
      if id then
        local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(id)
        local kind
        if equipLoc == "INVTYPE_2HWEAPON" then kind = "2H"
        elseif equipLoc == "INVTYPE_SHIELD" then kind = "Shield"
        elseif equipLoc then kind = "1H" end
        if kind then held = { type = kind, itemID = id, speed = baseWeaponSpeed(slot) } end
      end
      weaponAt[slot] = held
    end
    if not held then return nil end
    local main, off = UnitAttackSpeed("player")
    local hasted = (slot == 17 and off) or main
    held.hastedSpeed = hasted
    if not held.speed then held.speed = hasted end
    return held
  end

  -- Built once per set, not once per call: `sets` is fixed for the life of this state, so the
  -- lookup table was being thrown away and rebuilt several times a second for a list that never
  -- changed.
  local wantedItems = {}
  local function itemsIn(setKey, set)
    local wanted = wantedItems[setKey]
    if not wanted then
      wanted = {}
      for _, itemID in ipairs(set.items) do wanted[itemID] = true end
      -- Sets are immutable, so deleting the store below only rebuilds an identical table: the
      -- allocation differs and no behaviour can see it.
      wantedItems[setKey] = wanted
    end
    return wanted
  end

  function S:setCount(setKey)
    local set = sets[setKey]
    if not set or not set.items then return 0 end
    local wanted = itemsIn(setKey, set)
    local count = 0
    for slot = 1, 19 do
      local equipped = equippedRead(slot)
      if equipped and wanted[equipped] then count = count + 1 end
    end
    return count
  end

  -- Souls come from the shoulder TOOLTIP, not the item link — the link's enchant field is empty even
  -- when a soul is equipped (docs/07 §9.10, confirmed again by the first dump). Matching is on the
  -- short localized name, which makes this enUS-only in v1: a known, recorded limitation.
  --
  -- Held until the character changes, like the weapon: a soul is on the shoulders, and the
  -- shoulders cannot change without an equipment event. Before this every `bonus` with a soul
  -- source rebuilt the tooltip once per evaluation, per simulated slot.
  local function soulOn(slot)
    for _, line in ipairs(tooltipLines(slot)) do
      for key, soul in pairs(souls) do
        if type(soul) == "table" and soul.short and line == soul.short then return key end
      end
    end
    return nil
  end

  function S:enchant(slot)
    if slot ~= INVSLOT_SHOULDER then return nil end
    local held = enchantAt[slot]
    if held == nil then
      held = soulOn(slot) or false
      enchantAt[slot] = held
    end
    return held or nil
  end

  local function wearingSoul(soulKey)
    return S:enchant(INVSLOT_SHOULDER) == soulKey
  end

  -- A bonus is "enough set pieces OR a soul that grants it" (docs/01 §5a) — a build never cares
  -- which. Two schemas are in play and both are honoured: the shipped data carries a `Bonuses`
  -- table (`from = {{set=,pieces=},{soul=}}`, the shape tests/fake_state.lua walks), while docs/01 §5
  -- and the gear-matrix fixtures put a `bonus` key on each set threshold. Supporting only one would
  -- make the other resolve to false silently.
  function S:bonus(bonusKey)
    local def = bonusDefs and bonusDefs[bonusKey]
    if def and def.from then
      for _, src in ipairs(def.from) do
        if src.set and src.pieces and S:setCount(src.set) >= src.pieces then return true end
        if src.soul and wearingSoul(src.soul) then return true end
      end
    end

    -- No `or {}` fallbacks in these loops: each one allocated an empty table per set (or soul)
    -- without the field, on every evaluation, in the render loop.
    for setKey, set in pairs(sets) do
      local bonuses = set.bonuses
      if bonuses then
        for threshold, bonus in pairs(bonuses) do
          if bonus.bonus == bonusKey and S:setCount(setKey) >= threshold then return true end
        end
      end
    end

    for soulKey, soul in pairs(souls) do
      local grants = type(soul) == "table" and soul.grants
      if grants then
        for _, granted in ipairs(grants) do
          if granted == bonusKey and wearingSoul(soulKey) then return true end
        end
      end
    end

    return false
  end

  function S:itemCooldown(slot)
    local start, duration = GetInventoryItemCooldown("player", slot)
    if not duration or duration <= 0 then return 0 end
    local remaining = (start + duration) - GetTime()
    return remaining > 0 and remaining or 0
  end

  function S:itemUsable(slot)
    local id = GetInventoryItemID("player", slot)
    if not id then return false end
    return IsUsableItem(id) == true
  end

  -- Which seal is currently up, as a symbolic key. Class-specific, so it is guarded by the `seal`
  -- capability flag (docs/01 §2).
  local function activeSeal()
    for key, record in pairs(spells) do
      if type(record) == "table" and record.seal then
        if findAura("player", key, "HELPFUL") then return key end
      end
    end
    return nil
  end

  -- Remembers the seal that was active last time anyone looked, and when it stopped being active, so
  -- `sealLinger()` can name the OUTGOING seal. Updated from both accessors, because a twist build
  -- reads `seal` on essentially every tick and there is no separate event that means "a seal was
  -- replaced" — UNIT_AURA fires for everything.
  --
  -- Resolution is therefore bounded by how often the state is read (the display ticks at 10 Hz).
  -- That is finer than any plausible linger window, but it is a real limit and not a hidden one:
  -- a build that never evaluates a seal condition gets a memo that only updates when it asks.
  local sealMemo = { key = nil, previous = nil, changedAt = nil }

  local function pollSeal(now)
    local current = activeSeal()
    if current ~= sealMemo.key then
      -- Only a REPLACEMENT lingers. A seal falling off with nothing taking its place is an expiry,
      -- and docs/02 is explicit that expiry is not a twist.
      sealMemo.previous = (sealMemo.key ~= nil and current ~= nil) and sealMemo.key or nil
      sealMemo.changedAt = sealMemo.previous and now or nil
      sealMemo.key = current
    end
    return sealMemo
  end

  function S:seal()
    return pollSeal(GetTime()).key
  end

  function S:level() return UnitLevel("player") or 0 end

  -- Is the spell in the spellbook at all? Deliberately NOT `usable`, which is IsUsableSpell and
  -- reads false when you are merely out of mana. Returns nil rather than false when the client
  -- will not answer, so "cannot tell" stays distinguishable from "not learned".
  --
  -- RANKS. Classic gives every rank of an ability its own spell id, and the data pack ships exactly
  -- one -- the max rank. `IsPlayerSpell(415073)` is therefore FALSE for a paladin who has Exorcism
  -- at rank 5, and the Builder greyed learned abilities as "not learned yet". Display/BarGlow.lua
  -- learned this same lesson for bar buttons and says it plainly: names have no rank. So the id is
  -- asked first, and the spellbook -- which lists whatever rank you actually own -- answers second.
  function S:known(spellKey)
    return Vanilla.knownById(resolve(spellKey))
  end

  -- Matches the ABILITY ids the client reports in learnedAbilitySpellIDs. Storing a teach-spell id
  -- here compares false against every slot and reports "not engraved" for a rune the player is
  -- wearing, with no error anywhere — the bug that shipped (docs/07 §9.12).
  --
  -- Held until the character changes. GetRuneForEquipmentSlot builds a fresh table per call, ten
  -- calls per question, and a `rune` gate is asked once per simulated slot -- for an answer that
  -- moves only on RUNE_UPDATED or an equipment swap, both of which Core/Init forwards here.
  local function engraved(id)
    for _, slot in ipairs(RUNE_SLOTS) do
      local rune = C_Engraving.GetRuneForEquipmentSlot(slot)
      local learned = rune and rune.learnedAbilitySpellIDs
      if learned then
        for _, ability in ipairs(learned) do
          if ability == id then return true end
        end
      end
    end
    return false
  end

  function S:rune(runeKey)
    if not (C_Engraving and C_Engraving.GetRuneForEquipmentSlot) then return false end
    local id = resolve(runeKey)
    if not id then return false end
    local held = runeAt[id]
    if held == nil then
      held = engraved(id)
      runeAt[id] = held
    end
    return held
  end

  -- Seconds to the next main-hand swing, latency-compensated, or nil when unknown. All the judgement
  -- about what "unknown" means lives in Adapters/Swing.lua; this is the seam Core sees.
  function S:swingRemaining()
    if not ns.Swing then return nil end
    return ns.Swing.remaining(GetTime(), S:latency())
  end

  -- docs/02: the OUTGOING seal, while it can still proc — not the active one, and never a seal that
  -- merely expired. The window length is a flavor constant the DATA PACK supplies with a `-- src:`
  -- line; with no sourced value there is no window, so this answers nil and every `seal_linger`
  -- condition reads false. That is deliberate: a guessed timing constant would silently mis-time
  -- every twist, and hard rule 2's reasoning applies to server-side timings as much as to ids.
  function S:sealLinger()
    local window = tonumber(sealLingerWindow)
    if not (window and window > 0) then return nil end
    local memo = pollSeal(GetTime())
    if not (memo.previous and memo.changedAt) then return nil end
    if GetTime() - memo.changedAt > window then return nil end
    return memo.previous
  end

  function S:ttd() return nil end
  function S:enemies() return 1 end
  function S:mode() return "Single" end

  -- Round-trip to the world server, in ms. Used as the reaction lead on swing timing: the player
  -- needs to know when to PRESS, which is earlier than when the server swings. GetNetStats is
  -- refreshed by the client every ~30s, so this is cheap to call per read.
  function S:latency()
    if not GetNetStats then return 0 end
    local ok, _, _, _, world = pcall(GetNetStats)
    return (ok and tonumber(world)) or 0
  end

  return S
end

-- Rebuilt whenever the registered pack changes; Core reaches it through Elmira.API.GetState().
--
-- R2b (D76): `idOf` above resolves a symbolic key against whichever `spells` table this State
-- closed over, and that used to be `pack.spells` alone -- so a spell registered by id, by name or
-- from the spellbook (Core/Spells.lua) validated and compiled, but `state:cooldown/usable/known`
-- could never find its id, because the table this State actually reads from had never heard of it.
-- `Spells.merged` is the SAME table `Core/UserBuilds.ctxFor` and `Display.packContext` build the
-- compile ctx from (pack wins on a key collision), so a registry key resolves here exactly the way
-- a pack key does -- one merge, shared, rather than a second copy that could disagree with it. It
-- also stays LIVE: `Spells.merged` mutates one table per pack rather than replacing it, and this
-- State's `spells` upvalue is that same object, so a spell added after login is visible the next
-- time anything (the render loop's `packContext`, most often) asks for a merge -- no re-attach
-- needed. This is pure data assembly, still no WoW API call of its own (hard rule 3).
function Vanilla.attachPack(pack)
  pack = pack or {}
  local spells = ns.Spells and ns.Spells.merged and ns.Spells.merged(pack) or pack.spells
  -- `sealLingerWindow` is optional and usually absent: it is a sourced server-side timing constant,
  -- and a pack that has not sourced one leaves seal twisting inert rather than mis-timed.
  Vanilla.state = Vanilla.newState(spells, pack.sets, pack.souls, pack.bonuses,
                                   pack.sealLingerWindow)
  return Vanilla.state
end

function Vanilla.describe()
  local d = Vanilla.detect()
  return {
    project = d.project,
    version = string.format("%s/%s", d.build or "?", d.revision or "?"),
    interface = d.interface,
    caps = Vanilla.capabilities(),
    state = Vanilla.state and "live" or "null (no data pack)",
  }
end

Vanilla.GCD_CEILING = GCD_CEILING
Vanilla.state = ns.Interface and ns.Interface.newNullState() or nil
ns.Adapter = Vanilla
return Vanilla
