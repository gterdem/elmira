-- Elmira/Adapters/LibOwner.lua — which shared libraries is ELMIRA's copy of, and what that costs us.
--
-- LibStub serves exactly ONE copy of each library to the whole user interface, and the client bills
-- a function's allocations to the addon whose FILE defined it. So whichever addon's embedded copy
-- wins LibStub pays, in its own memory figure, for every OTHER addon's use of that library: ElvUI's
-- event dispatch through CallbackHandler, WeakAuras' glow animations through LibCustomGlow, the
-- whole UI's timers through AceTimer. Elmira embeds eighteen libraries -- 769 KB of source against
-- 542 KB of our own code -- so "Elmira is using 17 MB" may be a statement about other addons.
--
-- Answering that needs two snapshots of `LibStub.minors`, and only one of them can be taken from a
-- normal file: this module is listed BEFORE `embeds.xml` in the TOC so that `before` is what the
-- client looked like the instant BEFORE our libraries loaded. `Core/Init.lua` seals `after` at the
-- end of our load, which is the same instant for this purpose -- every file between embeds and Init
-- is ours and none of them calls NewLibrary, and no OTHER addon can run until our TOC finishes.
--
-- Adapters, not Core, because this reads a client global (hard rule 3). The comparison itself is
-- pure and takes its snapshots as arguments, so it is testable without a client.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local LibOwner = {}

-- A copy of `LibStub.minors`, or an empty table when LibStub is not loaded yet -- which is the
-- normal answer for the `before` snapshot when Elmira is the first addon to embed it.
function LibOwner.snapshot(stub)
  local out = {}
  if stub == nil then stub = _G.LibStub end
  local minors = stub and stub.minors
  if type(minors) ~= "table" then return out end
  for major, minor in pairs(minors) do out[major] = minor end
  return out
end

-- Taken at file scope, before embeds.xml runs. Anything already here belongs to an addon that
-- loaded ahead of us.
LibOwner.before = LibOwner.snapshot()

-- Sealed once, from Core/Init.lua. Latched because a second call after other addons have loaded
-- would record THEIR libraries as ours, which is the exact inverse of what this measures.
function LibOwner.sealAfterEmbeds(stub)
  if LibOwner.after then return false end
  LibOwner.after = LibOwner.snapshot(stub)
  return true
end

-- PURE. Every major whose minor moved while our embeds were loading -- we either created it or
-- upgraded it, and either way our file is the one LibStub handed to everybody.
--
-- `ours` is a separate question from `installed`: an addon loading after us with a higher minor
-- takes ownership away again, and that is worth reporting rather than hiding, because it is the
-- difference between "this is our bill" and "this was our bill until ElvUI loaded".
function LibOwner.audit(before, after, live)
  before, after, live = before or {}, after or {}, live or {}
  local rows = {}
  for major, minor in pairs(after) do
    if before[major] ~= minor then
      rows[#rows + 1] = {
        name = major,
        minor = minor,
        current = live[major],
        ours = live[major] == minor,
        replacedBy = live[major] ~= minor and live[major] or nil,
      }
    end
  end
  table.sort(rows, function(x, y) return x.name < y.name end)
  return rows
end

-- The audit against the live client. nil + reason when the snapshots were never taken, because a
-- report of "we own nothing" and one of "we never looked" must not read the same.
function LibOwner.report()
  if not LibOwner.after then
    return nil, "the after-embeds snapshot was never sealed (Core/Init.lua did not run)"
  end
  return LibOwner.audit(LibOwner.before, LibOwner.after, LibOwner.snapshot())
end

-- How many of the libraries we installed are still the ones the whole UI is using.
function LibOwner.ownedCount()
  local rows = LibOwner.report()
  if not rows then return nil end
  local n = 0
  for _, row in ipairs(rows) do if row.ours then n = n + 1 end end
  return n
end

ns.LibOwner = LibOwner
return LibOwner
