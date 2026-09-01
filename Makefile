LUA         ?= lua5.1
WOW_ADDONS  ?= /mnt/d/Blizzard/World of Warcraft/_classic_era_/Interface/AddOns
BUILDS_DIR  ?= /mnt/d/Addon-Testing/Elmira/builds
REPORTS_DIR ?= /mnt/d/Addon-Testing/Elmira/reports
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

package:
	curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh | bash -s -- -d -z

# Populates Elmira/Libs/ (gitignored) from a packager dry-run, for the dev-tree edit/reload loop.
# Probes both candidate paths since .pkgmeta's move-folders behaviour for a self-named move
# (Elmira/Elmira: Elmira) was unverified until the first `make package` dry run confirmed it.
libs: package
	@rm -rf Elmira/Libs
	@if [ -d "$(PKGDIR)/Elmira/Libs" ]; then \
		cp -r "$(PKGDIR)/Elmira/Libs" Elmira/Libs; \
	elif [ -d "$(PKGDIR)/Elmira/Elmira/Libs" ]; then \
		cp -r "$(PKGDIR)/Elmira/Elmira/Libs" Elmira/Libs; \
	else \
		echo "ERROR: no Libs/ found under $(PKGDIR)/Elmira — inspect the packager output" && exit 1; \
	fi
	@echo "Elmira/Libs/ populated from $(PKGDIR)."

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
