# Changelog

All notable changes to Unc's Tavern are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/StillScrub/Uncs_Tavern/releases/tag/v0.1.0
