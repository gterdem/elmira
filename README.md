# Elmira

**Your next cast, in order.** Elmira is an open-source rotation helper for World of Warcraft Classic,
built first for Season of Discovery and designed to port to Classic Era and future Classic+.

It shows your next abilities as a queue of glowing icons and lights up the matching button on your action
bar — and it reads your character before it advises you. Set bonuses, engraved runes, shoulder souls, weapon
type and level are detected in game, so the rotation you see fits the gear you have, not the gear a guide assumes.

> **Elmira never casts for you.** Addons cannot cast from the secure combat UI, and Elmira does not try.
> It is a visual guide: suggestions, glows, and post-fight feedback.

## Status
Pre-release — under active development. First target: level-60 Paladin (Exodin, Wrath-like, Shockadin,
Protection; seal twisting experimental) plus a Mage build to prove the engine is class-agnostic.

## Features (v1.0 scope)
- Queue of 1–5 upcoming actions with cooldown sweeps and keybind hints
- Glow on the queue icon and on your action bar (ElvUI, default bars; more bar addons later)
- Optional peripheral cues, off by default: opt individual spells or events into a screen-edge
  flare or sound, for the moments you're watching the boss and not the UI
- First-run setup wizard: detects your class, spec, weapon, runes and gear; offers current playstyles
- Gear-aware builds: bonuses from set pieces *and* shoulder souls switch rotation lines on automatically
- Gear advisor: which shoulder soul, runes and weapon type fit the build you're playing
- Readiness checks (seal, aura, Righteous Fury, judgement…), configurable and snoozable
- In-game structured build editor with live condition preview; import/export strings
- Rotation modes (Single / Cleave / AoE), consumables, time-to-die awareness, latency lead
- Fight tracker with history; suggestions module and WoWSims integration on the roadmap

## Modules
Elmira ships as a family — install the package and only the relevant parts load:
`Elmira` (core, including all class data), `Elmira_ElvUI`, `Elmira_ItemRack`, `Elmira_WoWSims`, `Elmira_Insights`.

## Install
Via the CurseForge app (recommended) or download the release zip and extract into `Interface/AddOns`.
Type `/elm` in game for help, `/elm setup` to run the wizard again.

## Development
- Lua 5.1, Ace3. Headless tests: `make test` (busted). Lint: `make lint`.
- Packaging: BigWigs packager via GitHub Actions on version tags.
- Contributions welcome — class data is pure data; see `Elmira/Classes/Paladin.lua` for the shape.

## FAQ
**Can it press the buttons for me?** No — by design and by Blizzard's API. Requests for automation are declined.
**Does it need ElvUI?** No. ElvUI is optional; default bars are supported.
**Does it fetch rotations from the internet?** No. Builds ship with the addon and are refreshed with releases.

## License
MIT — see `LICENSE`. Author: Valermus.
