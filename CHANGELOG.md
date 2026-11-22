# Changelog

All notable changes to Unc's Tavern are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-11-23

### Added
- **PvP tab** with five views: **Nearby** (enemy players in view right now), **Enemies** (everyone you've met, with your kills and deaths against each), **Ignored**, **Kill on Sight** and **Leaderboard**. The enemy list is local: only you see it.
- **Nearby window:** a small movable list of enemy players in view. Click a name to target them, double-click to put a skull over their nameplate (only you see it), right-click for options.
- **Guild Kill on Sight list.** Add enemies from the Nearby window, the PvP tab, the right-click menu of an enemy's portrait, the death screen, a key binding or `/tavern kos [reason]`, with a reason (presets or your own) or without. Entries last 30 days unless renewed, up to 25 per player, and only you can change or remove yours.
- Kill on Sight extras (Settings > PvP): a warning and sound when one is nearby, a skull over their nameplate, a line on their tooltip, an optional warning about enemies from guilds with several players on the list, and an offer to add someone who kills you repeatedly (1 to 5 kills within a time you choose).
- **Moderators** (the ranks allowed under Settings > Permissions) can take an enemy off the guild list; it shows in the Guild log. The guild leader can also require **moderator approval** for entries from other ranks.
- **Import your Spy Kill on Sight list** into the guild list (Settings > PvP or `/tavern kosimport`). Spy's own list is only read, never changed.
- **Sightings:** when you spot someone on the Kill on Sight list, guildmates see where ("seen in <zone> by <you>"), and the player who added them gets a bigger alert.
- **Nemesis alert:** a warning when the enemy who has killed you the most shows up. Local only.
- **Weekly PvP leaderboard:** this week's open-world kills, deaths, K/D and best kill streak for everyone sharing PvP stats, reset with the game's weekly reset. The week's leader gets a crown on the guild roster, the most kills a trophy and the best streak a flame, and the top of the board shows the guild's all-time best week for kills and for streak.
- **Quality of life** (Settings > Quality of life): a small reminder when Well Rested is missing, low on stacks or about to run out, and when you have no Well Fed buff that gives bonus experience. At login, on leaving a rest area and when a buff drops; never in combat; nothing at level 60. `/tavern qol` shows them on demand.
- **Sleeping bag warning:** a character that has carried a sleeping bag gets a warning that stays on screen while it isn't in their bags (left in the bank, for example), until it's back or you click Ignore.

### Fixed
- Guild data from other players could disappear after logging in, with the "Enable sharing" question showing again, when the game reported an empty realm name. Data is now kept under the realm's ID, and anything saved under the old name is recovered automatically.
- The "Enable sharing" popup could cut off its text at the bottom.
- A stray line of text could show over the title of some lists.

## [0.5.0] - 2026-11-20

### Added
- **Mailbox: Guild Requests panel.** Docked to the right of the mail window, it lists guildmates' open requests you can fill from your bags. **Fill Send Mail** puts in the recipient, subject and exact amount (splitting stacks for you); you press Send yourself. **Fill anyway** when others claimed the rest, **Clear** empties the form.
- Sent mail to a guildmate with open requests is marked as on its way (your claim) automatically, whether you used Fill or not. Requests your mail fully covers are greyed out until they arrive, and rows show who else is already sending.
- With Syndicator (comes with Baganator) installed, the panel also shows bank and other-character counts, and requests you could fill after fetching items.
- Added a little something for those who reach level 60.

### Changed
- The "items in your bags are on the guild wishlist" popup now shows only at vendors and the auction house; at the mailbox, the Guild Requests panel shows them instead.
- Guild log: delivering more than you claimed now counts as **Confirmed** instead of Mismatch.

### Fixed
- Raising a claim on a request you had already partly delivered could be refused ("Only N still unclaimed").

## [0.4.2] - 2026-11-19

### Added
- **Key binding:** Options > Keybindings > AddOns > Unc's Tavern > "Open / close Unc's Tavern" (no key set by default; e.g. Shift-J).
- **Duels** on the guild tab: separate **Won** and **Lost** columns (lifetime), each sortable.
- Hovering a member shows their battleground honorable kills and duels.
- `/tavern pvpstatprobe` (developer check): lists the game's PvP statistics.

### Changed
- Guild tab headers have a second row: **Open World PvP** over Kills, Deaths, K/D and Dishon. (dishonorable kills), and **Duels** over Won and Lost.
- **Kills** now counts open-world honorable kills only; battleground kills are left out (shown on hover). Members on older versions still show all their kills until they update.
- **Helped** moved from a column to the member tooltip; it is still tracked and shared as before.
- New, centered mug icon that fits inside the portrait ring.

### Fixed
- Dishonorable deaths were missed when the killer was no longer on screen at the moment of death. The killer's level is now remembered from any time you saw them in the last 5 minutes (target, mouseover, focus or nameplate).
- The portrait icon no longer shows outside the gold ring.

## [0.4.1] - 2026-11-17

### Changed
- All wording is guild-neutral: the README, the docs and the level-up setting's Discord note work for any guild (the note now only applies if your guild mirrors guild chat to Discord).
- README shows real screenshots of every tab.

## [0.4.0] - 2026-11-17

### Security
- **Opt-in sharing per guild:** the first login in each guild asks "Enable Unc's Tavern sharing for <guild>?". Until you click Enable, nothing is sent or accepted. Settings has separate switches for Wishlist, PvP stats and Helped/History, a list of exactly what each shares, how long others' requests are kept (7/14/30/60 days unseen) and **Delete this guild's data**.
- **No relaying:** players only send their own requests and claims; a request is accepted only from its requester and a claim only from its claimer. Owners re-announce their requests when they or a guildmate log in. Other players' requests expire after 14 days without hearing from them.
- **Helped** now counts only receiver-confirmed deliveries (at most 3 per guildmate pair per day); the self-reported Helped count is gone.
- Every incoming message is checked: guild channel only, senders must be on your guild roster, per-sender rate limit, all fields range-checked, escape codes (links, colors, textures) stripped from received text. Saved data is checked on load.
- **COD warning** when a guildmate's mail asks more than your wishlist price for its items.
- PvP stats are labelled "self-reported" and range-checked.
- History is kept per guild; nothing from one guild is shown in another.
- New message format (protocol 2): versions before 0.4.0 can't sync with this one, so everyone in the guild needs to update.
- `/tavern securitytest` (developer check, after `/tavern debug on`).
- **Rank permissions:** the guild leader picks which ranks may moderate requests and see the officer log (Settings > Guild > Permissions). Accepted only from the guild leader by your own roster; falls back to guild leader only if the guild's ranks change. Moderator actions and officer data are checked against your own roster too; officer data never goes on the guild channel.
- SECURITY.md and a "Privacy & Safety" section in the README. The release workflow's checkout action is pinned to a commit.

### Changed
- Quantity is now 1-1000 per request (was 9999), required level for rules 1-60.
- The wishlist popup at vendors, the auction house and the mailbox shows once per login, with **Show me** / **Ignore forever**. The sell warning has its own setting.
- The COD warning has its own setting.
- **Pay up to** in the Wishlist form is greyed out for now, with a note: COD mail fails on the WoW: Forever server ("Internal mail database error", even with no addons). New requests are Gift until the server is fixed.
- Settings tab redone like the game's Options window: a category list on the left (General, Alerts, Minimap, Sharing), the page on the right with a Defaults button, the game's checkboxes and dropdown, descriptions in hover tooltips.
- New addon icon (window portrait, minimap button and the AddOns list).

### Added
- **Moderators** can remove any request and clear any claim (right-click a Wishlist row), with an optional reason for the officer log. Every action shows in the Guild log.
- **Guild log** in the History tab (replaces "Show all completed guild requests"): deliveries marked Confirmed / Unconfirmed / Mismatch, and moderator actions. Last 200 entries, 30 days (guild leader adjustable).
- **Officer log** for allowed ranks: moderator actions with reasons and every mismatch, sent only over the officer channel or by whisper to allowed members.
- `/tavern probe` shows what your client supports for permissions and the officer log.

### Fixed
- After using Claim or Got, the guild window's "Add member" box only accepted numbers, and other Blizzard popups could be blocked. The addon no longer uses Blizzard's shared popups at all; it has its own dialog.
- Requests and claims of players who left or were kicked from the guild are hidden at once, so nobody mails items to them.
- PvP: a Lua error on every party kill ("secret string value") on the Midnight client.
- Level-up: clicking **Post** did nothing (the game blocked the send) after the switch to our own dialog. Post is now a secure button that runs `/g …` like your own macro.
- History: long names in the From / To columns were cut off ("Fumble..."). The name and date columns now size themselves to the longest entry; the Item column takes the rest and grows when you widen the window.

## [0.3.0] - 2026-11-14

### Added
- **Wishlist item search:** type an item name (or ID) and pick it from the list: common mats and leveling items, items seen in your bags, and items already on the wishlist.
- **Rule requests:** ask for any gear that fits (armor type, slot, minimum required level, one stat with a minimum, optionally a second stat). Always for one item. They sync to the guild, can be claimed, and items from the mailbox that fit count toward them.
- **History tab:** your own items received and items sent through the wishlist, plus an optional view of all completed guild requests.
- **Helped** column on the guild tab: how many times each member delivered wishlist items to a guildmate.
- **Alerts:** item tooltips show who in the guild wants that item ("Wanted by <name>: N more"); a popup at vendors, the auction house and the mailbox lists bag items that fill guildmates' requests; selling such an item to a vendor warns you and points to the Buyback tab; a badge on the minimap button counts new requests until you open the Wishlist tab. Each can be turned off in Settings.

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

[Unreleased]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/StillScrub/Uncs_Tavern/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StillScrub/Uncs_Tavern/releases/tag/v0.1.0
