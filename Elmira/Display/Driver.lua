-- Elmira/Display/Driver.lua — the update loop from docs/01 §7, finally implemented.
--
--   event -> invalidate()  ->  dirty
--   OnUpdate (<=10 Hz)     ->  if Ticker says run: recompute; if the queue CHANGED: render
--
-- Everything before M3 computed a queue on demand — a slash command, a recorder mark. This is the
-- first thing in the addon that runs continuously, so it is also the first thing that can cost a
-- player framerate. Two throttles, deliberately separate:
--   * Core/Ticker decides whether to RECOMPUTE (rate cap + idle backstop).
--   * Ticker.queuesDiffer decides whether to RENDER. A rotation holds the same top suggestions for
--     seconds at a time, so most recomputes produce an identical queue and re-rendering it would
--     rebuild textures and strings ten times a second for no visible change.
--
-- Frames live here, not in Core (hard rule 3). `tick(now)` takes its time as an argument so the
-- decision path is reachable from a spec, and the OnUpdate handler feeds it `ns.now()` — the same
-- injected clock everything else uses, so Display never grows a second one.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Display = {}
local renderers = {}      -- ordered list of { name, render }
local ticker
local frame
local lastQueue           -- the queue as rendered, for the change test
local lastBuildKey

-- Renderers subscribe rather than the driver naming them: the queue strip, the bar glow and the
-- overlay all want the same queue and must never each run their own loop.
function Display.register(name, render)
  if type(name) ~= "string" or type(render) ~= "function" then return false end
  for _, r in ipairs(renderers) do
    if r.name == name then r.render = render; return true end   -- re-register replaces, no duplicates
  end
  renderers[#renderers + 1] = { name = name, render = render }
  return true
end

function Display.renderers() return renderers end

function Display.invalidate()
  if ticker then ticker:markDirty() end
end

function Display.ticker()
  if not ticker then ticker = ns.Ticker.new() end
  return ticker
end

-- The pack for the player's class, or nil. Guarded because a class with no shipped pack is a normal
-- state (only Paladin ships at M2), not an error.
function Display.currentPack()
  if not (ns.API and ns.Adapter and ns.Adapter.playerClass) then return nil end
  local packs = ns.API.GetProviders("dataPacks")
  local class = ns.Adapter.playerClass()
  return class and packs and packs[class] or nil
end

-- Compiled build + key + why it was chosen. The reason is carried so `/elm debug` can answer "why
-- is it showing this build?" for a choice the user did not make.
function Display.activeBuild()
  local pack = Display.currentPack()
  if not pack then return nil, nil, "no data pack for this class" end
  local profile = ns.db and ns.db.profile
  local key, reason = ns.Profiles.resolve(pack, profile)
  if not key then return nil, nil, reason end
  local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  local compiled, errors = ns.compileBuild(pack.builds[key], ctx)
  if not compiled then
    return nil, key, "build '" .. key .. "' failed to compile (" .. #(errors or {}) .. " problem(s))"
  end
  return compiled, key, reason
end

function Display.computeQueue(depth)
  local compiled, key = Display.activeBuild()
  if not compiled then return nil, key end
  local state = ns.API.GetState()
  return ns.Simulation.queue(compiled, state, depth or 5), key
end

-- One tick. Returns "rendered", "unchanged", or "skipped", which is what makes `/elm debug perf`
-- able to report work avoided rather than merely assert that some was.
function Display.tick(now)
  local t = Display.ticker()
  if not t:shouldRun(now) then return "skipped" end

  local profile = ns.db and ns.db.profile
  local depth = (profile and profile.depth) or 3
  local queue, key = Display.computeQueue(depth)

  -- A build change must repaint even if the queue happens to look the same: the icons may be
  -- identical while the reasons behind them are not.
  local changed = (key ~= lastBuildKey) or ns.Ticker.queuesDiffer(lastQueue, queue)
  if not changed then return "unchanged" end

  lastQueue, lastBuildKey = queue, key
  for _, r in ipairs(renderers) do
    -- One renderer erroring must not take the others down with it, and must not kill the OnUpdate
    -- handler — a dead OnUpdate is a display that silently stops updating, which is this codebase's
    -- characteristic failure shape.
    local ok, err = pcall(r.render, queue, key)
    if not ok then
      ns.log("Elmira: display renderer '%s' errored: %s", r.name, tostring(err))
    end
  end
  return "rendered"
end

function Display.Enable()
  if not frame then
    frame = CreateFrame("Frame", nil, UIParent)   -- plain frame, never a secure template (rule 1)
    -- ns.now(), not GetTime: all time comes from the injected clock (house style), which
    -- is what lets tick() be driven from a spec.
    frame:SetScript("OnUpdate", function()
      Display.tick(ns.now())
    end)
  end
  frame:Show()
  Display.invalidate()
  return true
end

function Display.Disable()
  if frame then frame:Hide() end
  return true
end

function Display.isEnabled()
  return frame ~= nil and frame:IsShown()
end

-- Forces the next tick to recompute AND repaint, regardless of whether the queue changed. Used by
-- anything that alters how the queue is drawn rather than what it contains (scale, depth, a colour).
function Display.refresh()
  lastQueue, lastBuildKey = nil, nil
  Display.invalidate()
end

function Display.stats()
  local s = Display.ticker():stats()
  s.renderers = #renderers
  s.build = lastBuildKey
  return s
end

ns.Display = Display
return Display
