local helper = require("tests.helper")

-- Elmira/Options/Rotation.lua — the Rotation section (ADR-0015 §1-2), the addon's front door.
--
-- Same mechanism as options_spec: the section is plain data and closures, so a spec calls
-- `Rotation.group()` and drives a row directly with no AceConfig, no AceGUI and no frame. The parts
-- that will need a real widget (the Builder) deliberately hold no logic yet.
--
-- The thing this file is really guarding is the pair of `and`-truncation bugs luacheck caught while
-- it was being written: `local _, key = cond and f()` adjusts f() to ONE value, so the second
-- return silently arrives as nil. Both would have rendered as "no rotation is active" — a panel
-- that looks fine and says nothing true, which is this project's characteristic failure.
describe("Options/Rotation (the Rotation section)", function()
  local Rotation, ns, realUserBuilds

  -- `catalogUpdated` is deliberately the REAL one: it is the function Core/UserBuilds uses to stamp
  -- `derivedAt`, so the stale-parent banner has to ask it the same question. Faking it here would
  -- let the two drift into a banner that silently stops appearing, which is the drift the shared
  -- definition exists to prevent. Only `find`/`list` are fakes.
  local function installUserBuilds(t)
    t.catalogUpdated = t.catalogUpdated or realUserBuilds.catalogUpdated
    ns.UserBuilds = t
    return t
  end

  local CATALOG = {
    { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
      updated = "2026-08-01", recommended = true },
    { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
      updated = "2026-07-01", experimental = true },
  }

  local function installPack()
    ns.Display.currentPack = function()
      return { class = "PALADIN", catalog = { PALADIN = CATALOG },
               builds = { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} } }
    end
  end

  -- The wizard is the one place that knows an entry is only offerable when the pack ships the build
  -- it names, so the section reuses it rather than re-deriving. Faked here at that seam.
  local function installWizard(rows)
    ns.Wizard = { choices = function() return rows end }
  end

  before_each(function()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    -- The real signature is compiled, key, reason -- and the key SURVIVES a compile failure, which
    -- is the defect the "selected but broken" tests below pin.
    ns.Display = { activeBuild = function() return {}, "PALADIN_EXODIN", nil end,
                   currentPack = function() return nil end }
    realUserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
    ns.UserBuilds = nil -- each test opts in through installUserBuilds
    Rotation = helper.load("Elmira/Options/Rotation.lua")
  end)

  describe("group()", function()
    it("is one tabbed section holding Rotations, Builder and Share, in that order", function()
      local g = Rotation.group()
      assert.equal("group", g.type)
      assert.equal("tab", g.childGroups)
      assert.equal("Rotation", g.name)
      -- Order 0: the front door sorts above the display settings, not at the bottom where
      -- Import/Export used to live.
      assert.equal(0, g.order)
      assert.equal(1, g.args.rotations.order)
      assert.equal(2, g.args.builder.order)
      assert.equal(3, g.args.share.order)
    end)

    -- An empty Builder tab, or one that looks interactive and is not, is the failure this codebase
    -- keeps producing. It has to say it is not ready and what to do instead.
    it("says the Builder is not here yet, and what to do meanwhile", function()
      local row = Rotation.group().args.builder.args.soon
      assert.equal("description", row.type)
      assert.equal(1, row.order)
      assert.equal("full", row.width)
      assert.equal("medium", row.fontSize)
      assert.is_truthy(row.name:find("next step", 1, true))
      assert.is_truthy(row.name:find("Share", 1, true))
    end)
  end)

  -- The Share tab owns the widget; Options.lua still owns the state. The tab must read THROUGH the
  -- accessors, not hold a second copy — `Options.exchangeText` had no caller outside the suite
  -- until this tab, which in this repo is a bug report rather than a spare function.
  describe("Share tab", function()
    local function box() return Rotation.group().args.share.args end

    it("shows what Options put in the box, and its note", function()
      ns.Options = { exchangeText = function() return "ELM1:abc" end,
                     exchangeNote = function() return "Imported as USER_X." end,
                     importText = function() end }
      assert.equal("ELM1:abc", box().text.get())
      assert.equal("Imported as USER_X.", box().note.name())
    end)

    it("routes a pasted string to Options.importText", function()
      local got
      ns.Options = { exchangeText = function() return "" end,
                     exchangeNote = function() return "" end,
                     importText = function(str) got = str end }
      box().text.set(nil, "ELM1:pasted")
      assert.equal("ELM1:pasted", got)
    end)

    it("describes itself: one multiline input naming the string format", function()
      ns.Options = { exchangeText = function() return "" end,
                     exchangeNote = function() return "" end, importText = function() end }
      assert.equal("input", box().text.type)
      assert.equal(8, box().text.multiline)
      assert.equal("Build string", box().text.name)
      assert.is_truthy(box().text.desc:find("ELM1:", 1, true))
      assert.equal("description", box().note.type)
      assert.equal(2, box().note.order)
    end)

    -- Options.lua loads after this file in the TOC, so the accessors are reached lazily. Reading
    -- them at load time would leave the box permanently empty with nothing to show for it.
    it("renders without Options loaded rather than erroring", function()
      ns.Options = nil
      assert.equal("", box().text.get())
      assert.equal("", box().note.name())
      box().text.set(nil, "ELM1:ignored")
    end)
  end)

  describe("statusLines()", function()
    it("says so plainly when nothing is active", function()
      ns.Display.activeBuild = function() return nil, nil end
      assert.same({ "No rotation is active yet." }, Rotation.statusLines())
    end)

    -- The truncation bug: `local _, key = cond and Display.activeBuild()` reads the SECOND return,
    -- which an `and` expression discards. It rendered as "No rotation is active yet." forever.
    it("names the running rotation, reading activeBuild's second return", function()
      installPack()
      local lines = Rotation.statusLines()
      assert.equal("Running: Exodin", lines[1])
    end)

    it("names the template a fork came from", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork",
                        { name = "My Exodin", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-08-01" } end }
      local lines = Rotation.statusLines()
      assert.equal("Running: My Exodin", lines[1])
      assert.equal("Yours, forked from Exodin.", lines[2])
      assert.is_nil(lines[3])
    end)

    -- Display.activeBuild returns `nil, key, reason` when the build fails to compile: the key
    -- survives, the rotation does not. Reading the key alone printed "Running: Exodin" while
    -- nothing was queued -- the panel's headline stating a falsehood.
    it("says a selected build could not be loaded, rather than calling it Running", function()
      installPack()
      ns.Display.activeBuild = function()
        return nil, "PALADIN_EXODIN", "build 'PALADIN_EXODIN' failed to compile (2 problem(s))"
      end
      local lines = Rotation.statusLines()
      assert.equal(1, #lines)
      assert.is_nil(lines[1]:find("Running", 1, true))
      assert.is_truthy(lines[1]:find("Exodin", 1, true))
      assert.is_truthy(lines[1]:find("could not be loaded", 1, true))
      assert.is_truthy(lines[1]:find("failed to compile", 1, true))
    end)

    it("still names the build when the failure carries no reason", function()
      installPack()
      ns.Display.activeBuild = function() return nil, "PALADIN_EXODIN", nil end
      assert.is_truthy(Rotation.statusLines()[1]:find("Exodin", 1, true))
    end)

    -- ADR-0010: a template updated by a release since the fork was taken is offered as a diff,
    -- never rebased. Saying it happened is the half that is useful on its own.
    it("reports a parent that has been updated since the fork", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork",
                        { name = "My Exodin", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-07-01" } end }
      local lines = Rotation.statusLines()
      assert.is_truthy(lines[3]:find("has been updated since you forked it", 1, true))
      assert.is_truthy(lines[3]:find("2026-08-01", 1, true))
    end)

    -- Partial-module guard, the same asymmetry as forkRows' `list` check: a UserBuilds that can
    -- answer `find` but not `catalogUpdated` must lose the staleness line, not the whole panel.
    it("drops the staleness line rather than erroring when catalogUpdated is missing", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      ns.UserBuilds = { find = function() return {}, "fork",
                        { name = "Mine", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-01-01" } end }
      local lines = Rotation.statusLines()
      assert.equal("Yours, forked from Exodin.", lines[2])
      assert.is_nil(lines[3])
    end)

    it("says nothing about a parent when the fork is not derived from one", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork", { name = "Scratch" } end }
      local lines = Rotation.statusLines()
      assert.equal("Yours, not derived from a template.", lines[2])
      -- Stops there: the parent lines below it would name a template that does not exist.
      assert.is_nil(lines[3])
    end)

    -- The lookup is class-scoped: db.global is shared across characters, so a fork only belongs to
    -- this one because find() is handed the pack. Dropping the pack silently widens that.
    it("hands the class pack to the fork lookup", function()
      installPack()
      -- Every call, not the last: displayName() does its own lookup with its own pack, so asserting
      -- on a single captured value passes even when statusLines hands over nothing.
      local classes = {}
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function(pk)
        classes[#classes + 1] = (pk and pk.class) or "<no pack>"
        return {}, "fork", {}
      end }
      Rotation.statusLines()
      assert.is_true(#classes > 0, "the fork lookup was never reached")
      for _, class in ipairs(classes) do assert.equal("PALADIN", class) end
    end)

    it("renders the status block as one description row per line", function()
      installPack()
      local args = Rotation.group().args.rotations.args.status.args
      assert.equal("description", args.line1.type)
      assert.equal(1, args.line1.order)
      assert.equal("full", args.line1.width)
      assert.equal("medium", args.line1.fontSize)
      assert.equal("Running: Exodin", args.line1.name)
      assert.is_nil(args.line2)
    end)

    it("renders one row per line when there are several", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ list = function() return {} end,
                        find = function() return {}, "fork",
                        { name = "Mine", derivedFrom = "PALADIN_EXODIN" } end }
      local args = Rotation.group().args.rotations.args.status.args
      assert.equal(2, args.line2.order)
      assert.equal("Yours, forked from Exodin.", args.line2.name)
    end)
  end)

  describe("templateRows()", function()
    it("is empty, not an error, before a class pack is loaded", function()
      assert.same({}, Rotation.templateRows())
    end)

    it("marks the running template active and leaves the others alone", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local rows = Rotation.templateRows()
      assert.is_true(rows[1].active)
      assert.is_false(rows[2].active)
    end)

    -- The catalog is read-only and shipped-only (ADR-0005, hard rule 7). A template row carrying a
    -- set/get would be an edit surface on it.
    it("renders templates as read-only rows", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
                       updated = "2026-08-01", fits = true } }
      local row = Rotation.group().args.rotations.args.templates.args.t1
      assert.equal("description", row.type)
      assert.is_nil(row.set)
      assert.is_truthy(row.name:find("Exodin", 1, true))
      assert.is_truthy(row.name:find("2026-08-01", 1, true))
    end)

    -- The row model carries `active`; the marker is what the player actually sees. Testing only the
    -- model leaves the render free to mark every row the same.
    it("marks the running template's row and leaves the others unmarked", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local args = Rotation.group().args.rotations.args.templates.args
      assert.is_truthy(args.t1.name:find(">>", 1, true))
      assert.is_nil(args.t2.name:find(">>", 1, true))
      assert.is_truthy(args.t2.name:find("--", 1, true))
    end)

    it("says on the row when a template needs gear or runes you do not have", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false } }
      local row = Rotation.group().args.rotations.args.templates.args.t1
      assert.is_truthy(row.name:find("needs gear or runes", 1, true))
    end)

    -- Wizard.choices reaches the catalog and Detect; an error there must not take the whole panel
    -- down with it, or one bad catalog entry means no settings window at all.
    it("renders an empty list rather than propagating a wizard error", function()
      installPack()
      ns.Wizard = { choices = function() error("bad catalog entry") end }
      assert.same({}, Rotation.templateRows())
    end)

    it("tags a row with its difficulty and marks an experimental one", function()
      installPack()
      installWizard{ { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
                       experimental = true, fits = true } }
      local name = Rotation.group().args.rotations.args.templates.args.t1.name
      assert.is_truthy(name:find("hard", 1, true))
      assert.is_truthy(name:find("experimental", 1, true))
    end)

    it("says templates cannot be edited, and names the way to get a copy", function()
      installPack()
      installWizard{}
      local note = Rotation.group().args.rotations.args.note
      assert.equal("description", note.type)
      assert.equal(3, note.order)
      assert.equal("full", note.width)
      assert.is_truthy(note.name:find("read-only", 1, true))
      assert.is_truthy(note.name:find("Customize", 1, true))
    end)

    it("says so when the class ships no templates", function()
      installPack()
      installWizard{}
      assert.is_truthy(Rotation.group().args.rotations.args.templates.args.none.name
        :find("No templates ship", 1, true))
    end)
  end)

  describe("forkRows()", function()
    it("says so when you have made none", function()
      installPack()
      assert.is_truthy(Rotation.group().args.rotations.args.mine.args.none.name
        :find("not made a rotation of your own", 1, true))
    end)

    -- The other truncation bug: `local _, _, fork = ns.UserBuilds and find(...)` discarded the fork
    -- record, so every row rendered as "not from a template".
    it("lists each fork with the template it came from", function()
      installPack()
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function() return {}, "fork",
               { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" } end,
      }
      local rows = Rotation.forkRows()
      assert.equal(1, #rows)
      assert.equal("My Exodin", rows[1].name)
      assert.equal("PALADIN_EXODIN", rows[1].derivedFrom)
      assert.is_truthy(Rotation.group().args.rotations.args.mine.args.f1.name
        :find("from Exodin", 1, true))
    end)

    it("carries the key and marks the running fork active", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local rows = Rotation.forkRows()
      assert.equal("USER_MINE", rows[1].build)
      assert.is_true(rows[1].active)
      assert.equal("USER_OTHER", rows[2].build)
      assert.is_false(rows[2].active)
    end)

    it("marks the running fork's row and leaves the others unmarked", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local args = Rotation.group().args.rotations.args.mine.args
      assert.is_truthy(args.f1.name:find(">>", 1, true))
      assert.is_nil(args.f2.name:find(">>", 1, true))
      assert.is_truthy(args.f2.name:find("--", 1, true))
    end)

    -- Same widening the statusLines test guards: db.global is shared across characters, so the
    -- pack is what keeps a mage out of a paladin's forks.
    it("hands the class pack to every fork lookup", function()
      installPack()
      local classes = {}
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function(pk)
          classes[#classes + 1] = (pk and pk.class) or "<no pack>"
          return {}, "fork", { name = "Mine" }
        end,
      }
      Rotation.forkRows()
      assert.is_true(#classes > 0, "the fork lookup was never reached")
      for _, class in ipairs(classes) do assert.equal("PALADIN", class) end
    end)

    it("renders without erroring when UserBuilds is loaded but has no list yet", function()
      installPack()
      installUserBuilds{ find = function() return nil end }
      assert.same({}, Rotation.forkRows())
    end)

    it("scopes the fork list to this class's pack", function()
      installPack()
      local gotClass
      installUserBuilds{ list = function(pk) gotClass = pk and pk.class; return {} end,
                        find = function() return nil end }
      Rotation.forkRows()
      assert.equal("PALADIN", gotClass)
    end)

    it("labels a fork that came from no template, as a read-only row", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                        find = function() return {}, "fork", { name = "Scratch" } end }
      local row = Rotation.group().args.rotations.args.mine.args.f1
      assert.equal("description", row.type)
      assert.equal(1, row.order)
      assert.equal("full", row.width)
      assert.is_nil(row.set)
      assert.is_truthy(row.name:find("not from a template", 1, true))
    end)
  end)

  describe("displayName()", function()
    it("prefers the catalog's playstyle name over the raw key", function()
      installPack()
      assert.equal("Exodin", Rotation.displayName("PALADIN_EXODIN"))
    end)

    it("falls back to the key, because a blank row is worse than an ugly one", function()
      installPack()
      assert.equal("PALADIN_UNKNOWN", Rotation.displayName("PALADIN_UNKNOWN"))
    end)

    it("answers for a non-string rather than erroring", function()
      assert.equal("?", Rotation.displayName(nil))
    end)
  end)
end)
