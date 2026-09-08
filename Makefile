LUA         ?= lua5.1
WOW_ADDONS  ?= /mnt/d/Blizzard/World of Warcraft/_classic_era_/Interface/AddOns
BUILDS_DIR  ?= /mnt/d/Addon-Testing/Elmira/builds
REPORTS_DIR ?= /mnt/d/Addon-Testing/Elmira/reports
# The packager's move-folders step (.pkgmeta) collapses the checkout's Elmira/ core folder onto
# .release/Elmira directly — confirmed empirically via a full dry run, not assumed. The release zip
# lands at this same top level. Since ADR-0014 that is the only folder shipped; ADDONS still globs
# so the deploy prune below keeps working against whatever a user has installed.

PKGDIR      := .release
ADDONS      := $(notdir $(wildcard Elmira*))

.PHONY: test lint mutants mutants-deep coverage selftest package libs deploy deploy-package release-zip collect

test:
	busted --lua=$(LUA) tests/spec

# The two gates that answer "is this line actually tested?", which `test` alone cannot.
#
# mutants  deletes each changed line and requires the suite to go red. A line that survives is not
#          protected by any test -- this project's characteristic defect (a function with a spec and
#          no call site) is invisible to everything else, including review. See tools/mutants.sh.
#          Scoped to the diff by default so it runs in seconds; ALL=1 sweeps the whole tree.
#          This IS the gate: deletion-only, 0 survivors required.
# mutants-deep  same, plus a SUBSTITUTION pass (a line stays present with a different value of the
#          same shape) that catches a value bug deletion masks by crashing downstream instead of
#          failing an assertion. OPT-IN and NOT the gate: on this tree it currently reports ~100
#          survivors, almost all AceConfig `name`/`desc` strings nobody intends to assert word for
#          word. Consult it; do not wire it into CI or the definition of done.
# coverage per-file, and treats a file NO spec loads as 0% rather than omitting it the way luacov
#          does. Exemptions are declared with a reason in tools/coverage-exempt.txt.
mutants:
	@./tools/mutants.sh

mutants-deep:
	@DEEP=1 ./tools/mutants.sh

coverage:
	@./tools/coverage.sh

# Tests for the gates themselves. tools/mutants.sh decides whether every other check here is trusted,
# and it has already shipped three defects that made it pass VACUOUSLY (a renamed spec, a dangling
# index entry, a missing luacov). Nothing else in the repo covers tools/.
selftest:
	@./tools/selftest.sh

lint:
	luacheck . --no-color
	@# Armed against Elmira/Classes/ (shipped class data since M4b) AND Elmira_*/ (integration
	@# modules, plus any future in-repo pack). Note it also fires on the `local function UNVERIFIED`
	@# scaffold and on prose mentioning the marker, which is why both are stripped on restore.
	@#
	@# The directory check is not defensive noise: before M4b this line scanned Elmira_*/ only, and
	@# the class data moving to Elmira/Classes/ would have left it grepping folders that contain no
	@# ids at all -- passing green forever while guarding nothing. A gate that can silently stop
	@# covering its target has to fail when its target is missing.
	@test -d Elmira/Classes || (echo "ERROR: Elmira/Classes/ is missing; the UNVERIFIED gate is scanning nothing" && exit 1)
	@# ONE path, no glob. `Elmira_*/` used to be listed here too; ADR-0014 retired every folder it
	@# matched, and an unmatched glob makes grep exit 2 (a FILE error, not "no match") -- which `!`
	@# then turns into success. The gate passed green while scanning nothing, exactly the failure the
	@# comment above warns about, in the same line that warns about it.
	@! grep -rn "UNVERIFIED(" Elmira/Classes/ || (echo "ERROR: unverified IDs remain" && exit 1)

# -d skips uploading (this is always a local dry run); no -z, so a zip IS produced (that flag means
# "skip zip creation", the opposite of what its letter suggests) — release-zip depends on it existing.
package:
	curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh | bash -s -- -d

# Populates Elmira/Libs/ (gitignored) from a packager dry-run, for the dev-tree edit/reload loop.
libs: package
	@rm -rf Elmira/Libs
	@[ -d "$(PKGDIR)/Elmira/Libs" ] || (echo "ERROR: $(PKGDIR)/Elmira/Libs missing — inspect the packager output" && exit 1)
	@cp -r "$(PKGDIR)/Elmira/Libs" Elmira/Libs
	@echo "Elmira/Libs/ populated from $(PKGDIR)/Elmira/Libs."

# Day-to-day /reload loop: copies the DEV TREE (not the packaged output) into the live AddOns
# folder. Requires `make libs` at least once, or embeds.xml references libraries that don't exist
# and the client reports "Couldn't open Elmira\Libs\..." on every one.
deploy:
	@[ -d Elmira/Libs ] || (echo "ERROR: Elmira/Libs missing — run 'make libs' first" && exit 1)
	@# Prune Elmira* folders the repo no longer ships BEFORE copying. Without this, retiring a folder
	@# leaves the old copy installed and running: Elmira_Paladin (retired at M4b) still declares
	@# `## X-Elmira-Class: PALADIN`, so core's scan finds it, loads it, and its RegisterDataPack call
	@# runs AFTER the built-in one and silently OVERRIDES the shipped data with a stale copy. The
	@# addon looks fine and serves pre-migration rotations. Only ever touches Elmira* names.
	@for installed in "$(WOW_ADDONS)"/Elmira*; do \
		[ -e "$$installed" ] || continue; \
		name="$$(basename "$$installed")"; \
		case " $(ADDONS) " in \
			*" $$name "*) ;; \
			*) echo "  pruning stale $$name (no longer in the repo)"; rm -rf "$$installed" ;; \
		esac; \
	done
	@for addon in $(ADDONS); do \
		rm -rf "$(WOW_ADDONS)/$$addon"; \
		cp -r "$$addon" "$(WOW_ADDONS)/$$addon"; \
	done
	@echo "Deployed dev tree: $(ADDONS)"

# Milestone-acceptance / pre-release: deploys the PACKAGED output, so what's tested matches what
# CurseForge users receive.
deploy-package: package
	@for addon in $(ADDONS); do \
		rm -rf "$(WOW_ADDONS)/$$addon"; \
		cp -r "$(PKGDIR)/$$addon" "$(WOW_ADDONS)/$$addon"; \
	done
	@echo "Deployed packaged tree: $(ADDONS)"

# Stages the release zip in a local builds folder for manual install on a second PC.
#
# Exactly ONE zip is left there. This used to `cp $(PKGDIR)/*.zip`, which copies every build the
# packager dir has ever accumulated -- five of them, all named alike -- so the folder you install
# from offered a choice between one current build and four stale ones. A stale zip was nearly
# installed once; on 2026-09-05 the same glob put four back. Older ones move to superseded/ rather
# than being deleted, because "which build produced this bug report" is a question worth answering.
release-zip: package
	@mkdir -p "$(BUILDS_DIR)/superseded"
	@zip="$$(ls -t $(PKGDIR)/*.zip 2>/dev/null | head -1)"; \
	 [ -n "$$zip" ] || (echo "ERROR: no zip in $(PKGDIR) -- inspect the packager output" && exit 1); \
	 for old in "$(BUILDS_DIR)"/*.zip; do \
	   if [ -e "$$old" ] && [ "$$(basename "$$old")" != "$$(basename "$$zip")" ]; then \
	     echo "  retiring $$(basename "$$old")"; \
	     mv "$$old" "$(BUILDS_DIR)/superseded/"; \
	   fi; \
	 done; \
	 cp "$$zip" "$(BUILDS_DIR)/"; \
	 echo "Staged $$(basename "$$zip") in $(BUILDS_DIR) -- one zip, as intended."

# Pulls per-date reports (e.g. BugSack.lua, ElmiraDB.lua) off a second PC's shared folder into a
# local, gitignored working copy for analysis.
collect:
	@[ -n "$(DATE)" ] || (echo "Usage: make collect DATE=<yyyy-mm-dd>" && exit 1)
	@mkdir -p "collected/$(DATE)"
	@cp -r "$(REPORTS_DIR)/$(DATE)/." "collected/$(DATE)/"
	@echo "Collected into collected/$(DATE)/"
