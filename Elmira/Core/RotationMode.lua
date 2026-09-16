-- Elmira/Core/RotationMode.lua — the manual override on top of the nameplate count (M5a-i-D2).
--
-- PURE (hard rule 3): no WoW API, no frames. `Adapters/Vanilla.lua`'s `S:enemies()`/`S:mode()` read
-- `RotationMode.get()` the same way they read any other shared `ns.*` module (`ns.Spells`, `ns.Swing`);
-- this file owns the STORAGE and the CYCLE ORDER, never the client.
--
-- Lives in `db.char`, per M5a-i-D2, and is reset to "Auto" every PLAYER_ENTERING_WORLD (Core/Init.lua) --
-- login and /reload both -- so a forced mode never silently outlives the session that set it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent every spec loads via helper.load, which always supplies ns

local RotationMode = {}

-- Cycle order for the keybinding (Bindings.xml) and the values `/elm mode` and the `mode` condition
-- accept. "Auto" lets the adapter derive Single/Cleave/AoE from the nameplate count; the other three
-- FORCE that answer regardless of what is actually engaged -- for drilling one line on a dummy, or
-- fighting something the nameplate count cannot see.
RotationMode.MODES = { "Auto", "Single", "Cleave", "AoE" }
RotationMode.DEFAULT = "Auto"

function RotationMode.isMode(mode)
  for _, m in ipairs(RotationMode.MODES) do
    if m == mode then return true end
  end
  return false
end

-- Auto -> Single -> Cleave -> AoE -> Auto. Anything else (nil, or a value an older release stored
-- that this one no longer recognises) wraps to the front of the list, same reasoning as
-- Visibility.shouldShow's own fallback: a stored value from a stranger version must never wedge the
-- keybinding instead of just starting the cycle over.
function RotationMode.next(current)
  for i, m in ipairs(RotationMode.MODES) do
    if m == current then return RotationMode.MODES[(i % #RotationMode.MODES) + 1] end
  end
  return RotationMode.DEFAULT
end

-- The stored mode, or DEFAULT for anything unset or unrecognised -- never nil, so a caller can use
-- the answer directly.
function RotationMode.get()
  local stored = ns.db and ns.db.char and ns.db.char.rotationMode
  if RotationMode.isMode(stored) then return stored end
  return RotationMode.DEFAULT
end

-- Writes the forced mode into db.char and marks the queue stale, so the very next render (and the
-- next `enemies`/`mode` condition it evaluates) sees it. false, with nothing changed, for a value
-- that is not one of MODES or before the database exists -- a bad string at `/elm mode` must not
-- silently wedge the stored value.
function RotationMode.set(mode)
  if not RotationMode.isMode(mode) then return false end
  if not (ns.db and ns.db.char) then return false end
  ns.db.char.rotationMode = mode
  if ns.Display then ns.Display.invalidate() end
  return true
end

ns.RotationMode = RotationMode
return RotationMode
