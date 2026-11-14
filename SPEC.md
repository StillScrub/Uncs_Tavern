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
- Each player's addon tracks their own PvP stats and shares them over guild addon messages (`2|P|...`, throttled: ~15 s after login, at most once a minute after changes, soon after Sync or a new addon user), only when PvP sharing is on. **Self-reported:** accepted only about the sender, every number a whole number 0–10,000,000, the killer name cleaned; shown as "self-reported". Event-driven only; no combat log.
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
- Requests and claims sync across the guild, **owner-only** (no relaying): each player sends only their own requests and claims, live and when they or a guildmate log in/press Sync. You see a request once its owner has been online at the same time as you. Other players' requests expire after 14 days without hearing from them (Settings: 7/14/30/60).
- Limits: quantity 1–1000, price 0–9999 gold, required level 1–60, note 60 characters (escape codes stripped), 25 open requests per player.

## 3b. History tab
- Your own deliveries, only visible to you, worked out from the requests' "received from" (filled only when the requester takes items from the mailbox): **Items received** = senders on your requests; **Items sent** = other players' requests that list you. Marking your own request received by hand never counts. Copied per character so they outlive purged requests.
- **Helped** = how many guildmates' requests you delivered to, counted only from the **receiver's confirmation**: the "received from" that the requester's own client books when taking the items from the mailbox, sent only by the requester. Never from the helper's claim, never yourself, at most 3 per receiver-helper pair per day. Each client keeps a ledger of confirmations it has seen (account-wide, per guild), so players who install later see the last 14 days plus everything after.
- PvP stats are sent at login, after changes, and in answer to any guildmate's login/Sync hello. Your own numbers are also saved in the account-wide store, so your other characters on the same account see them; that is local only and never sent.
- Checkbox **Show all completed guild requests** (off by default, not saved): every fulfilled request this client knows, with who sent what. (Phase B replaces it with a Guild log.)
- History is kept per guild (max 500 entries per character).

## 4. Alerts
- **Item tooltips:** extra lines on wanted items (item and rule requests) — "Wanted by <name>: N more · price"; your own requests show as "On your wishlist: N more". Up to 4 lines, then "+N more".
- **Popup on opening a vendor, auction house or mailbox:** "N items in your bags are on the guild wishlist", listing up to 6 (item ×count -> requester · price), with Show me (opens the Wishlist tab) / Not now. Only guildmates' requests, only unbound items, capped at what's still unclaimed. Our own non-modal frame at the top of the screen; never blocks selling. Shows every time one of those windows opens.
- **Sell warning:** selling an item a guildmate asked for gives a red on-screen + chat message pointing to the vendor's Buyback tab. Detected afterwards from the buyback list; the sale is never stopped.
- **Minimap button:** red badge with the number of guildmates' requests created since you last opened the Wishlist tab (per character).

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
- Left: level-up posts, tooltip lines, vendor/AH/mail popup (+ sell and COD warnings), minimap badge, minimap button.
- Right: sharing with this guild (see 8).

## 8. Security & sharing
Full rules: "Security rules (always apply)" in CLAUDE.md. In short:
- **Opt-in per guild:** first login in a guild asks "Enable Unc's Tavern sharing for <guild>?". Until Enable, nothing is sent or accepted (the roster still works). Settings: master switch, Wishlist / PvP stats / Helped-History switches with what each shares, request expiry, **Delete this guild's data**.
- **Trust:** the sender name (set by the server) is trusted; message content never is. Messages are accepted only on the GUILD channel, protocol 2, from members on our own cached roster (unknown sender: one roster refresh, then dropped), within a per-sender rate limit (burst 60, then 1/s). Every field is validated; text is stripped of escape codes; item names and links are always built locally from the item ID.
- **Ownership:** requests only from their requester, claims only from their claimer, PvP stats only about the sender, Helped only from the receiver's confirmation. No relaying.
- **Money and items:** the addon never sends mail, takes mail, pays COD, trades or sells. A guildmate's mail whose COD is above quantity x your wishlist price gets a red warning; Blizzard's COD confirmation is untouched.
- Saved data is validated on load. Data is stored per guild (name + realm); leaving or changing guild hides the old data and stops syncing.
- `/tavern securitytest` (after `/tavern debug on`): feeds forged messages to the receive path in a sandbox, sends nothing, prints PASS/FAIL.

## Out of scope
- Gear upgrade detection (dropped).
- Info/events board, RSVPs, Notes tab and any Discord integration inside the addon (Discord is handled separately, outside the game).
- Officer actions (promote, demote, remove) and anything that drives Blizzard's guild window.
- Announcing level-ups for members without the addon (maybe later).
