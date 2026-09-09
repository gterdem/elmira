-- Elmira/Core/Visibility.lua — should the strip be on screen right now?
--
-- PURE (hard rule 3): takes booleans, returns a decision. Display/Driver reads the live state and
-- calls in; nothing here touches the WoW API, so every mode is reachable from a spec.
--
-- This existed nowhere until an owner asked "is the bar glow supposed to happen in combat or
-- always?" and the honest answer was "always, and nobody decided that". The PRD specifies what the
-- queue frame contains (F5) and what the bar glow does (F6) and says nothing about when either is
-- visible, so the addon glowed a player's action bar while they stood in a city. A rotation display
-- that is always on is a defensible choice; being always on because no one wrote the rule down is
-- not, which is why the decision is a named setting rather than a constant.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Visibility = {}

-- Order is the order the options dropdown offers them, loosest first.
Visibility.MODES = { "always", "combat_or_target", "combat" }
Visibility.DEFAULT = "combat_or_target"

-- Why not "combat" as the default: the opener is the cast that most needs advice, and a strip that
-- appears only once you are already fighting has missed it. Having a target is the earliest honest
-- signal that a fight is about to happen.
--
-- PE9-D6: the signal is `targetAttackable`, not "a target exists". Every city has a bank, an
-- auctioneer and a flight master, and clicking any of them used to pop a rotation strip up -- the
-- mode is called "or when you have a target" and means "or when you have something to fight".
-- The two REASON strings are unchanged: Options/Options.lua's HIDDEN_BECAUSE table is keyed by
-- them, so they are an interface, not prose.
function Visibility.shouldShow(mode, ctx)
  ctx = ctx or {}
  if mode == "always" then return true, "always" end
  if ctx.inCombat then return true, "in combat" end
  if mode == "combat" then return false, "out of combat" end
  -- An unrecognised mode falls through to the default rather than hiding: a profile written by a
  -- newer version must never leave someone with a blank screen and no way to find out why.
  if ctx.targetAttackable then return true, "target selected" end
  return false, "out of combat, no target"
end

function Visibility.isMode(mode)
  for _, m in ipairs(Visibility.MODES) do
    if m == mode then return true end
  end
  return false
end

ns.Visibility = Visibility
return Visibility
