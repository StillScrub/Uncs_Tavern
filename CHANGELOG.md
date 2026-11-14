# Changelog

All notable changes to Unc's Tavern are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Wishlist item search:** type an item name (or ID) and pick it from the list: common mats and leveling items, items seen in your bags, and items already on the wishlist.
- **Rule requests:** ask for any gear that fits (armor type, slot, minimum required level, one stat with a minimum, optionally a second stat). Always for one item. They sync to the guild, can be claimed, and items from the mailbox that fit count toward them.
- **History tab:** your own items received and items sent through the wishlist, plus an optional view of all completed guild requests.
- **Helped** column on the guild tab: how many times each member delivered wishlist items to a guildmate.

### Changed
- List columns now follow the window size: Item, Note, Zone and Rank grow, other columns stay sized to their content (Requester fits full two-part names).

### Removed
- The farming warning and its setting ("Most killed by" stays).

### Fixed
- PvP stats of your other characters on the same account now show on the roster (your own numbers are saved account-wide, since those characters are never online together).
- PvP stats are now sent again when a guildmate logs in or presses Sync, so whoever logs in later still sees everyone's numbers.

## [0.2.0] - 2026-11-14

### Added
- **PvP stats** on the guild tab, shared over guild sync: Kills (lifetime honorable kills, incl. assists), Deaths (deaths to players: lifetime when the game tracks it, otherwise since install), K/D and a Dishonorable column (kills on players too low level to give honor; not part of K/D). Hover a member for killing blows on players, dishonorable deaths (killed by someone you were grey to, when their level was visible) and "Most killed by".
- **Farming warning:** chat warning when the same player kills you 3 times within 30 minutes (Settings toggle).
- `/tavern pvpdebug` shows your PvP numbers, their sources and the last kill/death signal.

### Removed
- `/tavern pvptest` (replaced by `/tavern pvpdebug`).

### Changed
- Unc's Tavern now swaps with the Guild & Communities window (J): click the Unc's Tavern icon inside the window's portrait (top-left) and the guild window is replaced by the Unc's Tavern window in the same spot; the icon in its corner swaps back.
- The first tab is now labelled with your guild's name (read live); tabs are [Guild name] · Wishlist · Settings.
- `/tavern` and the minimap button swap with the guild window when it's open, otherwise open or close Unc's Tavern where the guild window last was.
- The window opens on the guild tab, can be dragged and resized, and has a button next to the X that resets it to the guild window's size and position. The icon is hidden when you have no guild.
- Guild tab: class icons next to names, new Rank column (sorts guild master first), Class column dropped (the icon and tooltip show it); footer reads "X of Y online · Z using Unc's Tavern"; hovering a member shows level, class, rank and public note; the Discord note moved out of the footer (it's in Settings and the level-up popup); roster refreshes are throttled to one every 2 seconds.

## [0.1.0] - 2026-11-14

First release.

### Added
- Main window (`/tavern`) with Roster, Wishlist and Settings tabs along the bottom, custom tavern icon, Escape to close.
- **Roster tab:** guild members with class-colored names, level, class, zone or time offline; sortable columns, name search, "Show offline" (saved per character); member/online/addon-user counts; Sync button. PvP columns are placeholders for now.
- **Guild sync:** versioned, throttled addon messages on the guild channel (prefix `UNCST`); addon users discover each other on login; `/tavern sync` shows who runs the addon.
- **Wishlist tab:** add requests by dragging an item into the slot, with quantity, note and payment (Gift or price per item); list with progress, requester, payment and note; All/Mats/Gear/Mine filters and "Hide mine"; Clear button.
- **Wishlist sync:** requests spread live and catch up on login or via the Sync button; online members pass requests along; your own requests can't be overwritten by others; removals use tombstones so stale copies can't bring them back. `/tavern wishlist` shows sync status.
- **Claims:** "I'm sending N" on other players' requests, shown in a Claimed column and the row tooltip; claims lapse after 72 hours.
- **Auto-complete:** items taken from the mailbox count toward your requests (only once they land in your bags); Got button for manual corrections; finished requests disappear for everyone.
- **Level-up post:** a popup offers to post `[Unc's Tavern] <Name> reached level <N>!` to guild chat with one click, after combat ends. Includes a note about linking Battle.net to Discord.
- **Minimap button:** left-click toggles the window, right-click opens Settings, drag to move.
- **Settings tab** with toggles for level-up posts and the minimap button.
- `/tavern pvptest` diagnostic for what PvP data WoW: Forever exposes.

### Fixed
- Characters' two-part names (e.g. "First Second") are used everywhere instead of only the first name.
- Wishlist uses drag only: shift-click opened the bag's split-stack box, which grabbed keyboard input.
- Level-up posts now go through: WoW: Forever blocks addon chat that isn't triggered by a click.

[Unreleased]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StillScrub/Uncs_Tavern/releases/tag/v0.1.0
