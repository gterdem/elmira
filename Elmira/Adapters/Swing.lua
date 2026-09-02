-- Elmira/Adapters/Swing.lua — auto-attack timing, from LibClassicSwingTimerAPI.
--
-- Adapters/ owns every WoW API call and every third-party library read (hard rule 3). Core asks the
-- State for `swingRemaining()`; this file is where that number comes from, and it is the only place
-- in the addon that knows a swing library exists at all.
--
-- Why a library rather than our own combat-log timer (ADR-0008): swing timing on Classic is a pile
-- of special cases — parry haste, ranged vs melee, off-hand desync, the swing that resets when you
-- change weapons mid-fight — and getting it subtly wrong produces a rotation that is *almost* right,
-- which is worse than one that is visibly broken.
--
-- The library is a PULL api, verified against the vendored copy (v31): `lib:SwingTimerInfo(hand)`
-- returns `speed, expirationTime, lastSwing` for the player, in GetTime() units. It also fires
-- CallbackHandler events (`UNIT_SWING_TIMER_UPDATE` and friends, signature
-- `(event, unitId, speed, expiration, hand)`), which we deliberately do NOT subscribe to: a pull
-- inside the display tick cannot go stale, cannot double-register, and cannot leave a cached number
-- behind when the library stops updating.
--
-- Absence is a normal state, not an error. Without the library `available()` is false, the `swing`
-- capability is false, `remaining()` answers nil, and every `swing` condition reads false — a build
-- that needs one is simply never reachable. The one thing this file must never do is answer a
-- confident number it does not have: a wrong swing time moves the entire rotation.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Swing = {}

-- Fetched through LibStub on every call rather than captured at file scope: this file can load
-- before the packager's Libs/ on some load orders, and a nil captured once would make the capability
-- permanently false for the whole session — the M0 LoadWith failure in a different costume.
local LIB = "LibClassicSwingTimerAPI"
local HAND = "mainhand"

local function lib()
  return LibStub and LibStub(LIB, true) or nil
end

function Swing.available()
  return lib() ~= nil
end

-- speed, expiration, lastSwing — or nil when the library cannot answer. Every read is wrapped: this
-- runs inside the display loop, and a library that changes its return shape must degrade to "no
-- swing data" rather than erroring ten times a second.
local function info()
  local L = lib()
  if not (L and L.SwingTimerInfo) then return nil end
  local ok, speed, expires, last = pcall(L.SwingTimerInfo, L, HAND)
  if not ok then return nil end
  return tonumber(speed), tonumber(expires), tonumber(last)
end

-- Seconds until the next main-hand swing lands, or nil when unknown. `nil` is a real answer and
-- docs/02 says so: before the first swing of a fight there is nothing to report, and a rotation must
-- read that as "no swing information", never as "the swing is due now".
--
-- Two things make a number wrong rather than merely absent, and both return nil:
--   * no speed — the library has never seen this character attack;
--   * an expiry more than a full swing period in the past — the library stops updating out of
--     combat, so a stale expiry would otherwise clamp to 0 and read as "swing is due NOW", which is
--     the single most damaging wrong answer this function can give.
--
-- `latency` is subtracted so the suggestion arrives in time to be acted on: the number a player
-- needs is "when should I press", not "when does the server swing".
function Swing.remaining(now, latency)
  if type(now) ~= "number" then return nil end
  local speed, expires = info()
  if not (speed and speed > 0 and expires) then return nil end
  if expires < now - speed then return nil end          -- stale: out of combat, or never updated
  local left = expires - now - ((tonumber(latency) or 0) / 1000)
  if left < 0 then return 0 end
  return left
end

function Swing.speed()
  local speed = info()
  return speed
end

-- For `/elm debug swing`. Names the three states that are indistinguishable from the outside and
-- would otherwise all present as "the swing timer does not work": no library at all, a library that
-- has never seen a swing, and a live reading that is simply stale because you are standing still.
function Swing.describe(now, latency)
  local speed, expires, last = info()
  local remaining = Swing.remaining(now, latency)
  local why
  if not Swing.available() then
    why = "library not loaded"
  elseif not speed then
    why = "no swing observed yet — attack something"
  elseif remaining == nil then
    why = "reading is stale (out of combat)"
  end
  return {
    library = LIB,
    available = Swing.available(),
    speed = speed,
    expires = expires,
    lastSwing = last,
    remaining = remaining,
    why = why,
  }
end

ns.Swing = Swing
return Swing
