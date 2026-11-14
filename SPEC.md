# Unc's Tavern — spec

A guild hub addon for World of Warcraft: Forever, built for <Unc of Azeroth> but working for any guild: the guild is read at runtime, never hardcoded.

## 0. Where it lives: the guild window (J)
- Pressing **J** opens Blizzard's normal Guild & Communities window, unchanged.
- Our **icon sits inside the window's portrait** (top-left), under the window's own ring art, so it looks built in.
- Click it: the guild window closes and the **Unc's Tavern window** opens in the same spot with the same size (at least the large guild window's width, since our content doesn't fit the small mode), on the guild tab. Our window has the same icon in its portrait: click it to close ours and reopen the guild window where ours was. Only one is open at a time; pressing J while ours is open closes ours.
- Our window can be dragged and resized (grip, bottom-right). A button next to the X resets it to the guild window's size and position. Once resized, it keeps its size until reset.
- Blizzard's window, its mode (small/large) and its tabs are never changed; we only close and reopen it on the player's click, at our window's position.
- Swapping works in combat too.
- No guild: the icon is hidden.
- `/tavern` and the minimap button: guild window open -> swap to ours; ours open -> close it; neither -> open ours where the guild window last was.
- Guild chat stays in Blizzard's window. There is no chat tab.
- Bottom tabs: **[Guild name, read live] · Wishlist · History · Settings**.
- List columns follow the window size: wide-content columns (item, note, zone, rank) grow; number, payment and name columns stay sized to their content.

## 1. Guild tab (roster)
- Columns: class icon + character name in class color · Level · Zone/Status (zone, or "Offline Xh") · Rank · PvP Kills · PvP Deaths · K/D · Dishonorable (kills; not part of K/D) · Helped (wishlist deliveries).
- Members without the addon show "—" for PvP stats. Hovering a row adds a PvP breakdown (see 2).
- Click a column header to sort. "Show offline" checkbox, name search box.
- Footer: "X of Y online · Z using Unc's Tavern", and a Sync button (our own addon messages only).
- Hovering a row shows the public note.
- Refreshes on GUILD_ROSTER_UPDATE, throttled. No polling. No right-click menu and no Blizzard actions.

## 2. PvP stats (feeds the roster)
- Each player's addon tracks their own PvP stats and shares them over guild addon messages (`1|P|...`, throttled: ~15 s after login, at most once a minute after changes, soon after Sync or a new addon user). Event-driven only; no combat log.
- **Kills** = honorable kills, lifetime (includes assists): the higher of GetPVPLifetimeStats and statistic 588, read on PLAYER_PVP_KILLS_CHANGED.
- **Killing blows on players** (since install): PARTY_KILL by me or my pet on a player GUID.
- **Dishonorable kills** (since install): a killing blow on a player with no honor signal (PLAYER_PVP_KILLS_CHANGED / CHAT_MSG_COMBAT_HONOR_GAIN) within 1.5 s, i.e. the victim was too low level to give honor. Assists without honor can't be seen. Own roster column, not part of K/D.
- **Deaths** = deaths to players: statistic 1501 (lifetime) when the game fills it, otherwise counted since install. On PLAYER_DEAD, wait 4 s (ignores Feign Death), then read the death recap: killing blow from a player or player's pet = PvP death; mobs, environment and duel deaths are ignored.
- **Dishonorable deaths** (since install): a PvP death where I was grey to the killer (classic grey-level rule; skull = always). The recap has no levels, so at PLAYER_DEAD the levels of visible enemy players (target, focus, mouseover, nameplates) are noted and matched to the killer's GUID. Unknown level = not counted.
- **K/D** = Kills / max(Deaths, 1).
- **Killers:** deaths per killer are saved; "Most killed by" is shared and shown in the roster tooltip.
- Roster tooltip: honorable kills, dishonorable kills, killing blows, deaths, dishonorable deaths, most killed by.
- `/tavern pvpdebug` prints every source value and the last kill/death signal for in-game checks.

## 3. Wishlist tab
- **Add a request (Item mode):** drag an item from bags into the item slot (shift-click was dropped: on stacks it opens the split-stack box), or type in the search box: it searches a built-in list of common mats/leveling items (classic-era IDs, names from the client), items seen in your bags, and items already on the wishlist; a number searches by item ID. Fields: quantity, note, payment.
- **Payment:** Gift, or "Pay up to X per item" (gold/silver/copper).
- **Rule requests (Rule mode):** armor type (Cloth/Leather/Mail/Plate) + slot (any or one) + minimum required level (no upper limit) + one stat with a minimum, optionally a second stat (e.g. Cloth, any slot, 26+, 4+ Intellect & 3+ Stamina). Rules are always for one item (no quantity). Matching uses the item's armor type, slot, required level and the game's stat list (GetItemStats). Synced as message type RR so older clients ignore them. Items taken from the mailbox that fit count toward the rule.
- **List:** item (quality-colored), progress (8 / 20), requester (class-colored), payment, note, claims. Filters: All / Mats / Gear / Mine, plus "Hide mine".
- **Claim:** "I'm sending N" marks it so others don't double-send. Claims lapse after 72 hours.
- **Auto-complete:** items the requester takes from the mailbox count toward the request; "Got" corrects counts by hand; done requests are removed.
- Requests sync across the guild; online members pass them along so requests spread while the requester is offline.

## 3b. History tab
- Your own deliveries, only visible to you, worked out from the requests' "received from" (filled only when the requester takes items from the mailbox): **Items received** = senders on your requests; **Items sent** = other players' requests that list you. Marking your own request received by hand never counts. Copied per character so they outlive purged requests.
- **Helped** = how many guildmates' requests you delivered to; shared as `1|WH|<n>` and shown on the roster.
- Shared stats (PvP `P`, Helped `WH`) are sent at login, after changes, and in answer to any guildmate's login/Sync hello, so whoever logs in later still gets everyone's numbers. Your own numbers are also saved in the account-wide store, so your other characters on the same account (never online together) see them.
- Checkbox **Show all completed guild requests** (off by default, not saved): every fulfilled request this client knows (kept 30 days), with who sent what.

## 4. Alerts (planned)
- **Bag tooltip:** extra lines on wanted items — "Wanted by <name>: N more · price".
- **Popup on opening a vendor, auction house or mailbox:** "N items in your bags are on the guild wishlist" with Show me / Not now. Never blocks selling.
- **Minimap button:** badge when new requests arrive.

## 5. Mailbox "Guild Requests" tab (planned)
- New tab next to Inbox / Send Mail.
- Lists only requests the player can fill from their bags.
- Picking one shows a draft: recipient, subject ("Unc's Tavern: Item ×N"), items attached, COD pre-filled as quantity × requester's price (or Gift). Everything is editable.
- "Fill Send Mail" fills the real Send Mail form. The player presses Send.

## 6. Level-up post
- On level-up (after combat), a popup offers to post to guild chat: `[Unc's Tavern] <Name> reached level <N>!` The player clicks **Post** — WoW: Forever only lets addons post to chat on a click.
- On by default; can be turned off in Settings.
- The guild's Discord side may parse this line, so keep the format exactly stable.
- Only players with the addon post their own level-ups.

## 7. Settings tab
- Toggles: level-up posts, minimap button. Planned: vendor/AH/mail popup, tooltip lines.

## Out of scope
- Gear upgrade detection (dropped).
- Info/events board, RSVPs, Notes tab and any Discord integration inside the addon (Discord is handled separately, outside the game).
- Officer actions (promote, demote, remove) and anything that drives Blizzard's guild window.
- Announcing level-ups for members without the addon (maybe later).
