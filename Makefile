LUA         ?= lua5.1
WOW_ADDONS  ?= /mnt/d/Blizzard/World of Warcraft/_classic_era_/Interface/AddOns
BUILDS_DIR  ?= /mnt/d/Addon-Testing/Elmira/builds
REPORTS_DIR ?= /mnt/d/Addon-Testing/Elmira/reports
# The packager's move-folders step (.pkgmeta) collapses the checkout's Elmira/ core folder onto
# .release/Elmira directly, as a sibling of .release/Elmira_Paladin, .release/Elmira_ElvUI, etc —
# confirmed empirically via a full dry run, not assumed. The release zip lands at this same
# top level.
PKGDIR      := .release
ADDONS      := $(notdir $(wildcard Elmira*))

.PHONY: test lint package libs deploy deploy-package release-zip collect

test:
	busted --lua=$(LUA) tests/spec

lint:
	luacheck . --no-color
	@# Armed against Elmira_*/ (data packs and builds). Currently matches nothing because
	@# Elmira_Paladin/Data/ is staged in the private workspace pending id verification at M2 — see
	@# docs/staging/README.md. Exercised live once that data is restored.
	@! grep -rn "UNVERIFIED(" Elmira_*/ 2>/dev/null || (echo "ERROR: unverified IDs remain" && exit 1)

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

# Copies the versioned release zip to a local builds folder for manual install on a second PC.
release-zip: package
	@mkdir -p "$(BUILDS_DIR)"
	@cp $(PKGDIR)/*.zip "$(BUILDS_DIR)/"
	@echo "Copied to $(BUILDS_DIR)"

# Pulls per-date reports (e.g. BugSack.lua, ElmiraDB.lua) off a second PC's shared folder into a
# local, gitignored working copy for analysis.
collect:
	@[ -n "$(DATE)" ] || (echo "Usage: make collect DATE=<yyyy-mm-dd>" && exit 1)
	@mkdir -p "collected/$(DATE)"
	@cp -r "$(REPORTS_DIR)/$(DATE)/." "collected/$(DATE)/"
	@echo "Collected into collected/$(DATE)/"
