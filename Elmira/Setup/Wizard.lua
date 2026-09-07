-- Elmira/Setup/Wizard.lua — what this character is, and the two nudges to set up a rotation
-- (docs/01 §5b, PRD F12). R1 (2026-09-07): the AceGUI wizard WINDOW is gone. Choosing a playstyle
-- is now the Rotations tree (Options/Rotation.lua); this file keeps everything that tree and the
-- two nudges need: detection, the catalog-version re-offer, and the first-run popup.
--
--   * The DETECTION logic is pure and lives in `Wizard.detection()` / `Wizard.choices()`, which
--     specs drive directly.
--   * `Wizard.shouldOffer()` answers ONE question now: has the catalog moved on since this
--     character last looked? That is a `status` line, nothing more (D39).
--   * `Wizard.maybeShowFirstRun()` is the OTHER nudge, for a character with no rotation chosen at
--     all: a small StaticPopup (a real frame, never AceConfig -- D37) offering to open the
--     Rotations tree. It is a Setup/Wizard question, not an Options/Rotation one, because it asks
--     nothing about the tree's own table shape, only `profile.activeBuild` and `char
--     .firstRunDismissed` -- so Options never has to be loaded for it to fire.
--   * No failure here may take the display down. `Core/Init.lua` calls both entry points inside a
--     pcall, and every one of them returns false rather than erroring.
--
-- `db.char.setupDone` records the catalog version the user last saw, not a boolean: a new phase
-- refreshes the catalog, and someone set up against the old one should be offered the new list once
-- (docs/01 §5b "wizard re-offers once after a catalog bump").
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Wizard = {}
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

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
-- silently disable the re-offer for everybody.
function Wizard.catalogVersion(p)
  p = p or pack()
  return (p and tonumber(p.catalogVersion)) or 0
end

-- ---------------------------------------------------------------------------------------------
-- Detection (pure — this is what the specs drive)
-- ---------------------------------------------------------------------------------------------

-- What we think this character is. Read by the Rotations tree's root page (Options/Rotation.lua,
-- D32) and by the first-run popup.
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

-- EVERY playstyle in the class's catalog, in the order docs/01 §5b specifies — recommended first,
-- then by `updated` descending. Each carries its own requirement check, so a renderer can colour a
-- card without knowing anything about requirements.
--
-- `available` says whether there is anything to run: the catalog's own flag AND a build file that
-- has actually shipped under that key. It is a flag on the row rather than a filter here because
-- the Rotations tree SHOWS an unavailable playstyle, muted, on a page that says why (D30/D48) — a
-- name that silently never appears is a question the addon never gets the chance to answer.
function Wizard.rows(detection)
  local p = pack()
  local out = {}
  detection = detection or Wizard.detection()

  for _, entry in ipairs(catalogEntries(p)) do
    local checks = ns.Detect and ns.Detect.check(detection, entry.requires, p) or {}
    local runnable = entry.available and p.builds and p.builds[entry.build] ~= nil
    out[#out + 1] = {
      build = entry.build,
      available = runnable == true,
      playstyle = entry.playstyle or entry.build,
      difficulty = entry.difficulty,
      summary = entry.summary,
      notes = entry.notes,
      source = entry.source,
      updated = entry.updated,
      phase = entry.phase,
      experimental = entry.experimental,
      recommended = entry.recommended,
      checks = checks,
      runesToEngrave = Wizard.runesToEngrave(checks),
      -- Three states again: fits / does not fit / could not tell. A yellow row is not a red one,
      -- and neither of them stops the user picking it — `requires` is advisory (hard rule 8).
      fits = not (ns.Detect and ns.Detect.hasFailures(checks)),
    }
  end

  table.sort(out, function(a, b)
    if a.recommended ~= b.recommended then return a.recommended == true end
    return tostring(a.updated) > tostring(b.updated)
  end)
  return out
end

-- The playstyles that can actually be OFFERED — `Wizard.rows` without the ones there is nothing to
-- run for. An entry whose build has not shipped yet would resolve to nil and leave the user with a
-- configured playstyle and no rotation (data_sourcing_spec pins this), so every caller that means
-- "pick one of these for me" asks this and not `rows`.
function Wizard.choices(detection)
  local out = {}
  for _, row in ipairs(Wizard.rows(detection)) do
    if row.available then out[#out + 1] = row end
  end
  return out
end

-- ---------------------------------------------------------------------------------------------
-- The once-per-catalog-version re-offer (login line only; the "never set up" case is the popup)
-- ---------------------------------------------------------------------------------------------

-- Should Elmira say something unprompted about setup? R1: ONLY when the catalog has moved on since
-- this character last looked. "Never set up at all" moved to the first-run popup
-- (`Wizard.maybeShowFirstRun`, at the bottom of this file), which asks `profile.activeBuild` directly
-- and needs no catalog version — a class with no catalog at all still deserves the nudge to build
-- their own rotation, and this question could never have answered that one anyway.
function Wizard.shouldOffer()
  local char = charDB()
  if not char then return false end
  local seen = tonumber(char.setupDone) or 0
  local version = Wizard.catalogVersion()
  if version > seen then return true, "the catalog has been updated since you set this up" end
  return false
end

-- Called from login. Prints one line; opens no window. F37: routed as a `status` announcement so a
-- player who moved chat away from status messages still finds it in the Log.
function Wizard.OfferOnLogin()
  local offer = Wizard.shouldOffer()
  if not offer then return false end
  local text = L["New playstyles have arrived since you chose yours."]
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
-- D37: the first-run popup
-- ---------------------------------------------------------------------------------------------

-- Shown at most once per login (this flag, not `char.firstRunDismissed`, is what stops a second
-- copy stacking if combat ends more than once before the player answers it).
local offeredThisLogin = false -- mutants: equivalent deletion only makes it a global; luacheck catches that

-- Exposed so a spec can put it back without reloading the whole file between cases.
function Wizard.resetFirstRunOffer()
  offeredThisLogin = false
end

-- "Choose a playstyle" is the STATIC label the dialog is registered with (StaticPopup needs one to
-- know it has three buttons at all); `maybeShowFirstRun` renames it to "Build a rotation" for a
-- class with no catalog, on the FRAME `StaticPopup_Show` hands back -- the standard way any addon
-- retitles a StaticPopup button after showing it, since the dialog table itself is static data.
local function registerFirstRunPopup()
  if not _G.StaticPopupDialogs then return end
  if _G.StaticPopupDialogs.ELMIRA_FIRST_RUN then return end
  _G.StaticPopupDialogs.ELMIRA_FIRST_RUN = {
    text = "%s",
    button1 = L["Choose a playstyle"], button2 = L["Not now"], button3 = L["Don't ask again"],
    timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function()
      if ns.Options then ns.Options.Open("rotation") end
    end,
    -- button2 ("Not now"): asks again next login, so there is nothing to write here.
    OnAlt = function()
      local char = charDB()
      if char then char.firstRunDismissed = true end
    end,
  }
end
registerFirstRunPopup()

local function detectionLine(detection)
  local class = (detection and detection.class) or "?"
  local level = (detection and detection.level) or "?"
  local weapon = (detection and detection.weapon and detection.weapon.type) or L["unknown"]
  return string.format(L["Level %s %s, holding a %s. Pick how you want to play:"],
    tostring(level), tostring(class), tostring(weapon))
end

-- Should the popup appear right now? Three checks, every one of which has to hold: a rotation is
-- already running, or the player already said stop, or the whole class has no data pack and the
-- popup would have nothing to say -- none of these is "not yet", they are all "never mind".
local function wantsFirstRun()
  local prof, char = profile(), charDB()
  if not (prof and char) then return false end
  if prof.activeBuild then return false end
  if char.firstRunDismissed then return false end
  return true
end

-- Called from Core/Init.lua: once, 2s after PLAYER_ENTERING_WORLD, and again from OnCombatEnd in
-- case the first call landed mid-fight. Never while `InCombatLockdown()` -- a popup demanding a
-- click is not something to discover mid-pull, and Init's own OnCombatEnd hook is what re-asks the
-- moment combat actually ends, so nothing else needs to retry it. Also emits the D39 first-login
-- Status line alongside the popup, so someone who alt-tabs past it still finds the same news in
-- chat and the Log.
function Wizard.maybeShowFirstRun()
  if offeredThisLogin then return false end
  if _G.InCombatLockdown and _G.InCombatLockdown() then return false end
  if not wantsFirstRun() then return false end
  offeredThisLogin = true

  local detection = Wizard.detection()
  -- "Is there a playstyle this player could actually pick?", which since D48 is a different
  -- question from "does the class have a catalog": the Rotations tree now lists entries with no
  -- rotation behind them too, muted, so a catalog can be non-empty and still offer nothing to
  -- choose. `Wizard.choices` is the filtered list, and this is the caller it is filtered for.
  local hasCatalog = #Wizard.choices(detection) > 0
  local className = (detection and detection.class) or L["your class"]

  local text -- mutants: equivalent deletion only makes it a global; luacheck catches that
  local choose -- mutants: equivalent deletion only makes it a global; luacheck catches that
  if hasCatalog then
    text = string.format(L["%s\n\n%s\n%s"], L["Elmira"],
      L["Elmira is not set up yet. Choose a playstyle to get a rotation on screen."],
      detectionLine(detection))
    choose = L["Choose a playstyle"]
  else
    text = string.format(L["%s\n\n%s"], L["Elmira"],
      string.format(L["No playstyles for %s yet. You can build your own from your spellbook."], className))
    choose = L["Build a rotation"]
  end

  if ns.Announce then
    ns.Announce.emit("status", L["Elmira is not set up yet. Open Rotations to pick a playstyle."])
  end

  if not (_G.StaticPopup_Show and _G.StaticPopupDialogs and _G.StaticPopupDialogs.ELMIRA_FIRST_RUN) then
    return false
  end
  local shown = StaticPopup_Show("ELMIRA_FIRST_RUN", text)
  if shown and shown.button1 and shown.button1.SetText then shown.button1:SetText(choose) end
  return true
end

ns.Wizard = Wizard
return Wizard
