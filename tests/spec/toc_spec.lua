-- tests/spec/toc_spec.lua — TOC load-order invariants. Verified in game on 2026-09-01: `## LoadWith:`
-- does NOT set the LoadOnDemand flag on Classic Era 1.15.9 (IsAddOnLoadOnDemand returned false), but
-- it DOES hoist the module to load with its trigger addon, ahead of `## Dependencies: Elmira`. The
-- module's file scope then read a nil `Elmira` global and registered nothing, silently. Nothing else
-- in the suite can catch that — it is a property of the .toc files, not of any Lua module.

-- Discovered, not listed: a future Elmira_Bartender4 must inherit these invariants without anyone
-- remembering to edit this file. EXPECTED guards the discovery itself — a glob that silently found
-- nothing would turn every assertion below into a vacuous pass, which is the same class of silent
-- no-op this spec exists to prevent.
local EXPECTED = 5

local function modules()
  local pipe = assert(io.popen("ls -d Elmira_*/ 2>/dev/null"), "cannot enumerate module folders")
  local found = {}
  for dir in pipe:lines() do
    local name = dir:gsub("/$", "")
    local toc = name .. "/" .. name .. "_Vanilla.toc"
    local f = io.open(toc, "r")
    assert(f, name .. " has no " .. name .. "_Vanilla.toc")
    found[name] = f:read("*a")
    f:close()
  end
  pipe:close()
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  assert.are.equal(EXPECTED, n) -- bump deliberately when a module is added or removed
  return found
end

describe("module TOCs", function()
  it("declares Elmira as a hard dependency of every module", function()
    for name, toc in pairs(modules()) do
      local deps = toc:match("##%s*Dependencies:%s*([^\r\n]*)") or ""
      local found = false
      for entry in deps:gmatch("[^,]+") do
        if entry:match("^%s*(.-)%s*$") == "Elmira" then found = true end
      end
      assert.is_true(found, name .. " must declare `## Dependencies: Elmira` to load after core")
    end
  end)

  it("never uses LoadWith, which loads a module ahead of its own dependencies", function()
    for name, toc in pairs(modules()) do
      assert.is_nil(toc:match("##%s*LoadWith:"),
        name .. " must not use `## LoadWith:` (see docs/08-MODULE-API.md)")
    end
  end)

  it("keeps the class pack load-on-demand so core selects it by class", function()
    assert.is_not_nil(modules()["Elmira_Paladin"]:match("##%s*LoadOnDemand:%s*1"))
  end)
end)
