-- tests/spec/toc_spec.lua — TOC load-order invariants. Verified in game on 2026-09-01: `## LoadWith:`
-- does NOT set the LoadOnDemand flag on Classic Era 1.15.9 (IsAddOnLoadOnDemand returned false), but
-- it DOES hoist the module to load with its trigger addon, ahead of `## Dependencies: Elmira`. The
-- module's file scope then read a nil `Elmira` global and registered nothing, silently. Nothing else
-- in the suite can catch that — it is a property of the .toc files, not of any Lua module.

-- ADR-0014: Elmira ships as ONE addon folder. The bar providers and the ItemRack integration are
-- inside core, gated at runtime on the target addon being present rather than by a TOC dependency.
-- This block used to check that each companion folder declared `## Dependencies: Elmira`; the
-- invariant it now guards is stronger and catches the failure that actually happened twice -- a
-- retired folder left behind, still declaring itself, still registering, silently overriding core.
local function moduleFolders()
  local pipe = assert(io.popen("ls -d Elmira_*/ 2>/dev/null"), "cannot enumerate module folders")
  local found = {}
  for dir in pipe:lines() do found[#found + 1] = (dir:gsub("/$", "")) end
  pipe:close()
  return found
end

describe("one addon folder (ADR-0014)", function()
  it("ships no companion addon folders", function()
    assert.same({}, moduleFolders())
  end)

  it("packages exactly one folder", function()
    local f = assert(io.open(".pkgmeta", "r"))
    local pkgmeta = f:read("*a")
    f:close()
    local moves = {}
    for line in pkgmeta:gmatch("[^\r\n]+") do
      local src, dst = line:match("^%s+(Elmira[%w_/]*):%s*(Elmira[%w_]*)%s*$")
      if src and dst then moves[#moves + 1] = dst end
    end
    assert.same({ "Elmira" }, moves)
  end)
end)

describe("core TOC", function()
  local function tocBody()
    local f = assert(io.open("Elmira/Elmira_Vanilla.toc", "r"), "missing core TOC")
    local s = f:read("*a"); f:close()
    return s
  end

  local function sourceFiles()
    -- Display/ and Options/ are included deliberately: this spec's whole point is that a file the
    -- suite can dofile but the game never loads looks identical from here. That applies to a
    -- renderer just as much as to a Core module.
    -- Classes/ and Setup/ are in this list for the same reason: a Classes/Mage.lua added to the
    -- repo but not to the TOC registers nothing, in a way no other spec can see (the suite loads it
    -- by path and it works perfectly). That is the M0 LoadWith bug's exact shape.
    local pipe = assert(io.popen(
      "ls Elmira/Core/*.lua Elmira/Adapters/*.lua Elmira/Display/*.lua Elmira/Options/*.lua " ..
      "Elmira/Setup/*.lua Elmira/Classes/*.lua 2>/dev/null"))
    local found = {}
    for path in pipe:lines() do found[#found + 1] = path end
    pipe:close()
    assert.is_true(#found >= 6, "expected to discover Core/ and Adapters/ sources, found " .. #found)
    return found
  end

  it("lists every Core and Adapters source file", function()
    local body = tocBody()
    for _, path in ipairs(sourceFiles()) do
      -- TOC paths use backslashes: Elmira/Core/Engine.lua -> Core\Engine.lua
      local entry = path:gsub("^Elmira/", ""):gsub("/", "\\")
      assert.is_not_nil(body:match(entry:gsub("([%.%-\\])", "%%%1")),
        entry .. " is missing from Elmira_Vanilla.toc; it would never load in game")
    end
  end)

  -- Adapters/LibOwner.lua snapshots LibStub.minors as it was BEFORE our libraries loaded, which is
  -- the only moment that snapshot exists. Listed after embeds.xml it would record our own copies as
  -- somebody else's and `/elm debug libs` would confidently report that Elmira owns nothing — a
  -- diagnostic that answers the opposite of the truth while looking perfectly healthy. Nothing in
  -- the Lua can catch this: it is a property of the TOC's line order.
  it("loads Adapters/LibOwner.lua before embeds.xml, or the library probe measures nothing", function()
    -- Comment lines stripped first: the comment explaining the ordering names embeds.xml itself, so
    -- searching the raw body finds the explanation rather than the entry and the test passes on a
    -- TOC with the two lines the wrong way round.
    local entries = {}
    for line in tocBody():gmatch("[^\r\n]+") do
      if not line:match("^%s*#") then entries[#entries + 1] = line end
    end
    local body = table.concat(entries, "\n")
    local probeAt = body:find("Adapters\\LibOwner%.lua")
    local embedsAt = body:find("embeds%.xml")
    assert.is_not_nil(probeAt, "Adapters\\LibOwner.lua missing from the TOC")
    assert.is_not_nil(embedsAt, "embeds.xml missing from the TOC")
    assert.is_true(probeAt < embedsAt,
      "Adapters\\LibOwner.lua must be listed before embeds.xml")
  end)

  it("loads Core/Init.lua last, since it publishes the Elmira global", function()
    local body = tocBody()
    local initAt = body:find("Core\\Init%.lua")
    assert.is_not_nil(initAt, "Core\\Init.lua missing from the TOC")
    for _, path in ipairs(sourceFiles()) do
      local entry = path:gsub("^Elmira/", ""):gsub("/", "\\")
      if entry ~= "Core\\Init.lua" then
        local at = body:find(entry:gsub("([%.%-\\])", "%%%1"))
        assert.is_true(at < initAt, entry .. " must load before Core\\Init.lua")
      end
    end
  end)
end)

-- Custom `## X-` TOC keys are metadata nothing validates: the client accepts any of them, the
-- packager ignores the ones it does not know, and a key with a typo -- or one whose reader was
-- deleted -- is indistinguishable from a working one. That is a silent no-op with a config file
-- for a body, and this repo has shipped that shape before, so every shipped key must be either
-- read by our own Lua or a key we deliberately publish for someone else to read.
describe("custom TOC keys", function()
  -- Keys consumed OUTSIDE our Lua. Each needs a reason, because "add it to the allowlist" is the
  -- easy way to defeat this test.
  local EXTERNAL = {
    ["X-License"]          = "CurseForge project metadata",
    ["X-Category"]         = "CurseForge project metadata",
    ["X-Curse-Project-ID"] = "release.sh's upload_curseforge(); without it the upload silently no-ops",
  }

  local function tocFiles()
    local pipe = assert(io.popen("ls Elmira*/*.toc 2>/dev/null"), "cannot enumerate TOC files")
    local found = {}
    for path in pipe:lines() do found[#found + 1] = path end
    pipe:close()
    assert.is_true(#found > 0, "no TOC files found; this test would pass vacuously")
    return found
  end

  local function luaSources()
    local pipe = assert(io.popen("find Elmira* -name '*.lua' -not -path '*/Libs/*' 2>/dev/null"))
    local text = {}
    for path in pipe:lines() do
      local f = io.open(path, "r")
      if f then text[#text + 1] = f:read("*a"); f:close() end
    end
    pipe:close()
    return table.concat(text, "\n")
  end

  it("gives every shipped X- key either a reader in our Lua or a documented external consumer", function()
    local sources = luaSources()
    local orphans = {}
    for _, path in ipairs(tocFiles()) do
      local f = assert(io.open(path, "r"))
      local body = f:read("*a"); f:close()
      for key in body:gmatch("##%s*(X%-[%w%-]+)%s*:") do
        if not EXTERNAL[key] and not sources:find(key, 1, true) then
          orphans[#orphans + 1] = path .. ": " .. key
        end
      end
    end
    table.sort(orphans)
    assert.same({}, orphans,
      "a TOC key nothing reads is inert; add the reader, drop the key, or document it in EXTERNAL")
  end)
end)
