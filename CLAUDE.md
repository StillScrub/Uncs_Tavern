# Unc's Tavern — project rules

Guild addon for **any guild** on **World of Warcraft: Forever**, published on GitHub and CurseForge.
Read SPEC.md for features. This file is how to build them.
- Keep everything guild-neutral: code, in-game text, defaults, README, SPEC, CHANGELOG and release notes never name a specific guild, realm, faction, Discord server or real player. The player's own guild name is read at runtime. ("Unc's Tavern" is the addon's name and stays.) Screenshots may show the author's guild.

## Folder layout
- Project root (this folder, `<project root>`): docs, notes, git. Its parent folder may hold other, separate projects; don't touch them from here.
- Addon code lives ONLY in the `Uncs_Tavern\` subfolder. Project docs stay at the root.
- `<WoW folder>\_forever_\Interface\AddOns\Uncs_Tavern` is a junction pointing at `<project root>\Uncs_Tavern\`. Never edit through the AddOns path; edit here and the game sees it.
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

## Security rules (always apply)
This addon is published for any guild. Each guild's data stays inside that guild, sharing is opt-in, and a modified copy of the addon must not be able to scam, impersonate or harm anyone.

### Trust model
- The sender name in CHAT_MSG_ADDON is set by the server: trust it. Message CONTENT is never trusted, because any guild member could run a modified copy.
- Ranks are ALWAYS read from our own guild roster (rankIndex), looked up by the sender's Name-Realm. Never trust a rank, role or permission written in a message. If the sender isn't in the cached roster, request a roster update, re-check once, then drop the message.
- Our own SavedVariables are validated on load too.

### Guild scope
- Sync over the "GUILD" addon channel. "OFFICER" and WHISPER are only for officer data.
- Ignore messages from anyone not in the current guild roster.
- Store synced data per guild (guild name + realm). Never show or send one guild's data to another. On leaving or changing guild, stop syncing and hide the old data. Settings: "Delete this guild's data".

### Opt-in
- First login in each guild: "Enable Unc's Tavern sharing for <guild>?" Until the player says yes, send nothing and accept nothing (the roster view still works locally).
- Separate toggles for: wishlist sync, PvP stat sharing, Helped/History sharing. Settings lists exactly what is shared.
- The level-up post stays click-to-post.

### Ownership
- No relaying: never re-broadcast another player's data. Clients cache only what they received directly from the owner. Owners re-announce their open requests when they come online. Cached requests expire after 14 days without seeing the owner (adjustable).
- Requests are created, edited or deleted only by their owner (sender == requester), or by a moderator.
- Claims are made or removed only by the claimer (or a moderator). The 72-hour lapse stays.
- PvP stats are accepted only from a player about themselves.
- Helped column: counted only from the RECEIVER's confirmation, sent by the receiver's own client. Never from the helper's own claim. Cap per day per pair.
- Alts: alt grouping and alt stats are local only. Never broadcast which characters share an account.
- Log or history entries are accepted only about the sender themselves.

### Input validation
- Versioned message formats. Drop unknown or malformed messages silently.
- Validate types, lengths and ranges: quantity 1–1000, price 0–a sane cap, item IDs resolve via C_Item, rule fields only from fixed allowed lists, levels 1–60.
- Item links: accept only item IDs and rebuild name, quality and link locally. Never display names or links sent by others.
- Strip UI escape codes (|c |r |H |h |T |A |K etc.) from all received text. Escape "%" before string.format. Cap note length (60 characters).
- Never loadstring or RunScript any data.
- Per-sender rate limits. Max 25 active requests per player. Caps on stored entries and History size.
- PvP stats labelled "self-reported". Reject negative or impossible values.

### Money, mail and items
- Never send or take mail, pay COD, trade, sell or move gold or items automatically. Only pre-fill. The player presses the Blizzard button. This includes the mailbox "Guild Requests" panel.
- Pre-filled COD = quantity × requester's price, clearly shown.
- Warn when a guildie's mail has COD above my own request's price. Never hide Blizzard's COD confirmation.
- Auto-complete and trade counting stay local. Never broadcast bag contents, gold, or mail not tied to a request.

### Code and release hygiene
- No obfuscated or minified code. No external libraries without approval (pinned if used).
- GitHub Actions pinned to versions or SHAs. The release zip contains only the addon folder. No secrets in the repo.

### Release checklist (before every release and every new sync feature)
- Can a modified client forge or alter another player's data, claim, Helped count, rank or permissions? → must be no.
- Can received data crash, lag, flood or inject links, textures or formatting? → must be no.
- Does anything move gold or items without the player pressing a Blizzard button? → must be no.
- Does any data leave the guild, reach non-officers when it's officer-only, or reveal alt ownership? → must be no.

## Addon structure (inside Uncs_Tavern\)
- `Uncs_Tavern.toc` — load order
- `Core.lua` — namespace, events, saved variables, slash command `/tavern`
- `Comm.lua` — guild addon messaging + sync (merge by timestamp)
- `UI\MainFrame.lua` — the Unc's Tavern window, swapped with the guild window (J) via the portrait icon; bottom tabs ([Guild name], Wishlist, Settings); each tab is a module
- `UI\Columns.lua` — column widths that follow the window size (shared by lists)
- `Modules\Roster.lua`, `Modules\Wishlist.lua`, `Modules\History.lua`, `Modules\Mail.lua`, `Modules\Alerts.lua`, `Modules\LevelUp.lua`, `Modules\PvPStats.lua`
- `Media\` — icon (.tga)
- New features = new file in `Modules\` registering a tab or hooks. Don't edit other modules to add one.

## Guild window integration
- J opens Blizzard's Guild & Communities window as normal. Our icon sits inside its portrait (top-left), with the window's own ring art drawn over it so it looks built in.
- Clicking it swaps windows: the guild window closes (HideUIPanel) and our own standalone window opens at the same top-left (at the guild window's size, at least its large width, unless the player resized ours). Our window has the same icon in its portrait; clicking it closes ours and reopens the guild window (ShowUIPanel) at our window's top-left. Only one is open at a time, and it opens on the guild tab.
- Our window can be dragged, resized (grip bottom-right) and reset to the guild window's size/position (button next to the X).
- That swap is the only thing we do to Blizzard's UI: our button parented to CommunitiesFrame, HideUIPanel/ShowUIPanel(CommunitiesFrame) on the player's click, placing its top-left where ours was, and HookScript OnShow. Never call or hook any other Blizzard function, and never resize, maximize, minimize or switch Blizzard's window, its frames or its tabs. (Blizzard templates and helper functions used on OUR OWN frames are fine.)
- /tavern and the minimap button: guild window open -> swap to ours; ours open -> close it; neither -> open ours where the guild window last was. They never open Blizzard's window on their own.
- Swapping works in combat too (none of these frames are protected).
- If the player has no guild, hide the portrait icon.
- After every UI phase, check that inviting someone to the guild still works in Blizzard's view (taint check).

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
