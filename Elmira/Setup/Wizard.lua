-- Elmira/Setup/Wizard.lua — the four-step first-run setup (docs/01 §5b, PRD F12).
--
-- The first AceGUI window in the addon, and the one thing in this milestone that cannot be verified
-- headlessly: nobody sees it until it is in front of the owner. Everything here is therefore built
-- to fail small.
--
--   * The step LOGIC is pure and lives in `Wizard.choices()` / `Wizard.summary()` / `Wizard.apply()`,
--     which specs drive directly. Only `Wizard.Open()` touches AceGUI: a thin renderer over that.
--   * No wizard failure may take the display down. `Core/Init.lua` calls `Wizard.OfferOnLogin()`
--     inside a pcall, and every entry point returns false rather than erroring.
--   * It never decides anything on its own. It proposes; the user picks; `apply()` writes. A wizard
--     that silently configured a character would be indistinguishable from the addon guessing.
--
-- `db.char.setupDone` records the catalog version the user last saw, not a boolean: a new phase
-- refreshes the catalog, and someone set up against the old one should be offered the new list once
-- (docs/01 §5b "wizard re-offers once after a catalog bump").
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Wizard = {}
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local frame                     -- the live AceGUI window, if one is open

local function profile() return ns.db and ns.db.profile end
local function charDB() return ns.db and ns.db.char end

local function pack()
  return ns.Display and ns.Display.currentPack() or nil
end

local function catalogEntries(p)
  if not (p and type(p.catalog) == "table" and type(p.class) == "string") then return {} end
  return p.catalog[p.class] or {}
end

-- Catalog version, used for the re-offer. Absent means an unversioned pack, which is treated as
-- version 0 rather than as "never offer again" — a pack that forgets to declare one must not
-- silently disable the wizard for everybody.
function Wizard.catalogVersion(p)
  p = p or pack()
  return (p and tonumber(p.catalogVersion)) or 0
end

-- ---------------------------------------------------------------------------------------------
-- Step data (pure — this is what the specs drive)
-- ---------------------------------------------------------------------------------------------

-- Step 1: what we think this character is.
function Wizard.detection()
  local p = pack()
  if not (ns.Detect and ns.API) then return nil end
  return ns.Detect.gather(ns.API.GetState(), ns.Adapter, p)
end

-- ADR-0013 §2: the runes a build is written for are a shopping list, not a warning. Collected from
-- the checks so the renderer needs no requirement logic of its own; empty when everything the build
-- asks for is engraved, or when the rune API could not be read (an unknown is not a purchase).
function Wizard.runesToEngrave(checks)
  local out = {}
  for _, check in ipairs(checks or {}) do
    if check.kind == "rune" and check.engrave then out[#out + 1] = check.engrave end
  end
  return out
end

-- Step 2: the playstyles on offer, in the order docs/01 §5b specifies — recommended first, then by
-- `updated` descending. Each carries its own requirement check, so the list can be coloured without
-- the renderer knowing anything about requirements.
--
-- Only `available` entries are offered. An entry whose build has not shipped yet would resolve to
-- nil and leave the user with a configured playstyle and no rotation (data_sourcing_spec pins this).
function Wizard.choices(detection)
  local p = pack()
  local out = {}
  detection = detection or Wizard.detection()

  for _, entry in ipairs(catalogEntries(p)) do
    if entry.available and p.builds and p.builds[entry.build] then
      local checks = ns.Detect and ns.Detect.check(detection, entry.requires, p) or {}
      out[#out + 1] = {
        build = entry.build,
        playstyle = entry.playstyle or entry.build,
        difficulty = entry.difficulty,
        summary = entry.summary,
        source = entry.source,
        updated = entry.updated,
        experimental = entry.experimental,
        recommended = entry.recommended,
        checks = checks,
        runesToEngrave = Wizard.runesToEngrave(checks),
        -- Three states again: fits / does not fit / could not tell. A yellow row is not a red one,
        -- and neither of them stops the user picking it — `requires` is advisory (hard rule 8).
        fits = not (ns.Detect and ns.Detect.hasFailures(checks)),
      }
    end
  end

  table.sort(out, function(a, b)
    if a.recommended ~= b.recommended then return a.recommended == true end
    return tostring(a.updated) > tostring(b.updated)
  end)
  return out
end

-- Step 4: what the user is about to get, including the gear advice for the chosen build. Shown
-- BEFORE anything is written, so "one click configures" does not mean "one click and hope".
function Wizard.summary(buildKey, detection)
  local p = pack()
  detection = detection or Wizard.detection()
  local out = { build = buildKey, advice = nil, checks = {} }
  if not (p and buildKey) then return out end

  for _, entry in ipairs(catalogEntries(p)) do
    if entry.build == buildKey then
      out.playstyle = entry.playstyle
      out.checks = ns.Detect and ns.Detect.check(detection, entry.requires, p) or {}
      out.runesToEngrave = Wizard.runesToEngrave(out.checks)
    end
  end

  local advice = p.advice and p.class and p.advice[p.class] and p.advice[p.class][buildKey]
  if advice and ns.Advisor and ns.API then
    local ctx = { spells = p.spells, sets = p.sets, souls = p.souls, bonuses = p.bonuses }
    out.advice = ns.Advisor.recommend(advice, ns.API.GetState(), ctx, {
      soul = detection and detection.soul,
      weapon = detection and detection.weapon,
      build = buildKey,
    })
  end
  return out
end

-- ---------------------------------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------------------------------

-- Writes the user's choice. Returns ok, message. Deliberately small: it pins a build, records which
-- catalog version was seen, and nothing else. Anchor and scale are already live settings the user
-- adjusted in step 3, so there is nothing to commit for them.
function Wizard.apply(buildKey)
  local p, prof, char = pack(), profile(), charDB()
  if not (prof and char) then return false, "no profile" end
  -- UserBuilds.find, not `p.builds`, because a pinned key may name one of the user's own forks
  -- (ADR-0010) -- Display/Driver.lua has always resolved it that way, and this refusing to was why
  -- Customize could fork a template and then fail to activate the fork it had just made.
  -- `p` must be present before either lookup: UserBuilds.find skips its class check when handed a
  -- nil pack, so without this a class with no data pack would pin another class's fork.
  if not p then return false, "unknown build " .. tostring(buildKey) end
  if not (ns.UserBuilds and ns.UserBuilds.find(p, buildKey)) then
    if not (p.builds and p.builds[buildKey]) then
      return false, "unknown build " .. tostring(buildKey)
    end
  end
  prof.activeBuild = buildKey
  char.setupDone = Wizard.catalogVersion(p)
  if ns.Display then ns.Display.refresh() end
  return true, buildKey
end

-- Should we offer setup unprompted? Only twice in a character's life: never configured, or the
-- catalog moved on since they last looked. Anything more is nagging, and PRD F12 says
-- "non-intrusively".
function Wizard.shouldOffer()
  local char = charDB()
  if not char then return false end
  local seen = tonumber(char.setupDone) or 0
  if seen == 0 then return true, "first run" end
  local version = Wizard.catalogVersion()
  if version > seen then return true, "the catalog has been updated since you set this up" end
  return false
end

-- Called from login. Prints one line; never opens a window on its own, because a window that opens
-- itself over someone's screen the moment they log in is the behaviour people uninstall over.
function Wizard.OfferOnLogin()
  local offer, why = Wizard.shouldOffer()
  if not offer then return false end
  local text = string.format("%s. Type /elm setup to choose a playstyle.", why)
  if ns.Announce then
    ns.Announce.emit("status", text)
  else
    ns.log("Elmira: %s", text)
  end
  local char = charDB()
  -- Mark it seen either way. The prompt is once per catalog version, not once per login.
  if char then char.setupDone = Wizard.catalogVersion() end
  return true
end

-- ---------------------------------------------------------------------------------------------
-- The window (the only part AceGUI touches)
-- ---------------------------------------------------------------------------------------------

local function AceGUI()
  return LibStub and LibStub("AceGUI-3.0", true) or nil
end

-- Colours a requirement check. nil ("could not tell") is deliberately NOT red: telling someone their
-- weapon is wrong because a tooltip scan came back empty sends them to fix something that is fine.
local function checkLine(check)
  local color = ns.Colors.MUTED
  local mark = "?"
  if check.ok == true then color, mark = ns.Colors.OK, "+"
  elseif check.ok == false then color, mark = ns.Colors.WARN, "!" end
  return ns.Colors.wrap(color, mark .. " " .. check.text)
end

-- Everything a choice row says, as coloured text, in order: the summary, one line per requirement
-- check, and -- ADR-0013 §2 -- the rune shopping list once, under the checks. Runes are 1c at the
-- Rune Broker, so this is the one requirement a player can satisfy before the next pull; it is
-- said as an instruction rather than left as a red mark. Pure, so the wording is testable; addChoice
-- only turns each line into a Label, and nothing about the UI toolkit is needed to check what it says.
function Wizard.choiceLines(choice)
  local lines = {}
  if choice.summary then lines[#lines + 1] = choice.summary end
  for _, check in ipairs(choice.checks or {}) do lines[#lines + 1] = checkLine(check) end
  if choice.runesToEngrave and #choice.runesToEngrave > 0 then
    lines[#lines + 1] = ns.Colors.wrap(ns.Colors.BRAND, string.format(
      L["Engrave first: %s. The Rune Broker in every starting zone sells runes for 1c."],
      table.concat(choice.runesToEngrave, ", ")))
  end
  return lines
end

-- One playstyle row. `gui` is injected rather than fetched here so a spec can hand in a recording
-- fake and check what the row actually says and does -- until it could, the "Use this anyway"
-- wording and the OnClick wiring had never been exercised by anything but a person in game.
function Wizard.addChoice(gui, container, choice, onPick)
  local group = gui:Create("InlineGroup")
  group:SetFullWidth(true)
  local title = choice.playstyle
  if choice.recommended then title = title .. "  " .. ns.Colors.wrap(ns.Colors.BRAND, L["recommended"]) end
  if choice.experimental then title = title .. "  " .. ns.Colors.wrap(ns.Colors.WARN, L["experimental"]) end
  group:SetTitle(title)

  for _, text in ipairs(Wizard.choiceLines(choice)) do
    local label = gui:Create("Label")
    label:SetFullWidth(true)
    label:SetText(text)
    group:AddChild(label)
  end

  local button = gui:Create("Button")
  -- The button never says "you cannot" — a failed requirement is a warning, not a gate.
  button:SetText(choice.fits and L["Use this"] or L["Use this anyway"])
  button:SetCallback("OnClick", function() onPick(choice.build) end)
  group:AddChild(button)

  container:AddChild(group)
end

function Wizard.Open()
  local gui = AceGUI()
  if not gui then
    ns.log("Elmira: the setup window needs AceGUI-3.0, which did not load.")
    return false
  end
  if frame then frame:Release(); frame = nil end

  local detection = Wizard.detection()

  frame = gui:Create("Frame")
  frame:SetTitle(L["Elmira setup"])
  frame:SetLayout("Flow")
  frame:SetCallback("OnClose", function(widget) gui:Release(widget); frame = nil end)

  local heading = gui:Create("Label")
  heading:SetFullWidth(true)
  local class = detection and detection.class or "?"
  local level = detection and detection.level or "?"
  local weapon = detection and detection.weapon and detection.weapon.type or L["unknown"]
  heading:SetText(string.format(L["Level %s %s, holding a %s. Pick how you want to play:"],
    tostring(level), tostring(class), tostring(weapon)))
  frame:AddChild(heading)

  local choices = Wizard.choices(detection)
  if #choices == 0 then
    local empty = gui:Create("Label")
    empty:SetFullWidth(true)
    -- Says which of the two reasons it is. "No playstyles" with no explanation is the kind of dead
    -- end that gets reported as "the wizard is broken".
    empty:SetText(pack() and L["No playstyles have shipped for your class yet."]
                          or L["No data pack is loaded for your class."])
    frame:AddChild(empty)
    return true
  end

  for _, choice in ipairs(choices) do
    Wizard.addChoice(gui, frame, choice, function(buildKey)
      local ok, message = Wizard.apply(buildKey)
      if ok then
        ns.log("Elmira: playstyle set to %s. /elm setup to change it.", message)
        if ns.Options then ns.Options.Open() end
      else
        ns.log("Elmira: could not set that playstyle (%s).", tostring(message))
      end
      if frame then frame:Release(); frame = nil end
    end)
  end

  local hint = gui:Create("Label")
  hint:SetFullWidth(true)
  hint:SetText(ns.Colors.wrap(ns.Colors.MUTED,
    L["/elm lock moves the queue. /elm advise lists what to change about your gear."]))
  frame:AddChild(hint)
  return true
end

function Wizard.Close()
  if frame then frame:Release(); frame = nil end
end

function Wizard.isOpen() return frame ~= nil end

ns.Wizard = Wizard
return Wizard
