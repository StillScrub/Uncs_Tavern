# Unc's Tavern — project rules

Guild addon for **<Unc of Azeroth>** (Alliance PvP guild) on **World of Warcraft: Forever**.
Read SPEC.md for features. This file is how to build them.

## Folder layout
- Project root (this folder): `D:\Claude AI\App\Projects\Uncs_Tavern` — docs, notes, git.
- Addon code lives ONLY in the `Uncs_Tavern\` subfolder. Project docs stay at the root.
- `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\Uncs_Tavern` is a junction pointing at `Uncs_Tavern\`. Never edit through the AddOns path; edit here and the game sees it.
- The addon folder name and .toc name must match: `Uncs_Tavern\Uncs_Tavern.toc`.

## Platform facts
- WoW: Forever runs on the Midnight-era retail client. Use the modern retail API (C_* namespaces), not Classic APIs.
- TOC interface number: `## Interface: 16001`.
- The combat log is closed to addons. Never use COMBAT_LOG_EVENT_UNFILTERED.
- Some APIs may behave differently than retail. When unsure whether a function exists or works in Forever, say so and propose a quick in-game test instead of guessing.
- Addons cannot reach the internet or write files except SavedVariables (written on /reload or logout).

## Hard rules
- Lightweight: event-driven only. No OnUpdate loops or polling timers unless there is no alternative; if a timer is needed, use C_Timer with a long interval and explain why.
- Never block, hook or interfere with protected actions (selling, mailing, combat). The addon fills things in; the player always presses the final button (Send, Sell, Post).
- Throttle all addon messages (guild channel, prefix `UNCST`). Keep messages small; version every message format.
- No hardcoded guild name in logic — the guild is detected at runtime, so the addon works for any guild.
- Look native: use Blizzard frame templates, fonts, colors and textures referenced by path. Don't ship copies of game art.
- Don't touch other addons or anything outside this project folder.

## Addon structure (inside Uncs_Tavern\)
- `Uncs_Tavern.toc` — load order
- `Core.lua` — namespace, events, saved variables, slash command `/tavern`
- `Comm.lua` — guild addon messaging + sync (merge by timestamp)
- `UI\MainFrame.lua` — window + bottom tabs (Roster, Wishlist, Settings); each tab is a module
- `Modules\Roster.lua`, `Modules\Wishlist.lua`, `Modules\Mail.lua`, `Modules\Alerts.lua`, `Modules\LevelUp.lua`, `Modules\PvPStats.lua`
- `Media\` — icon (.tga)
- New features = new file in `Modules\` registering a tab or hooks. Don't edit other modules to add one.

## SavedVariables
- `UncsTavernDB` (account-wide): wishlist, roster cache, settings.
- `UncsTavernCharDB` (per character): character settings.
- Include a `dbVersion` and migrate on load.

## Workflow
- Plan before each feature; keep changes small and testable.
- After each change, tell me exactly what to test in-game (`/reload`, what to click, what I should see).
- I'll paste BugSack errors; fix the root cause, not the symptom.
- Commit with git after each working feature with a clear message.

## Releases
To release: update CHANGELOG.md and the .toc version, commit, tag vX.Y.Z, push the commit and the tag. When I say 'release vX.Y.Z', do all of this.
