# Unc's Tavern — spec

A guild hub addon for any guild on World of Warcraft: Forever. The guild is read at runtime, never hardcoded, and no text, default or behavior is specific to one guild.

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
- Views (buttons top right): **My history** (the above, private) · **Guild log** · **Officer log** (only for ranks allowed to see it).
- **Guild log:** deliveries and moderator actions, worked out locally from data every client already has (the helper's own claim and the receiver's own confirmation), so no "log entry" message exists that anyone could forge. Status: **Confirmed** (claim and confirmation agree) · **Unconfirmed** (only one side: a confirmation without a claim, or a claim that lapsed/whose request closed with nothing confirmed) · **Mismatch** in red (confirmed quantity differs from the claim). Moderator actions: "Removed by moderator", "Cleared X's claim". Last 200 entries, kept 30 days (guild leader adjustable 7-90). A COD check comes with the mailbox panel (COD mail is broken on the server).
- **Officer log:** moderator actions with their optional reason, plus every Mismatch; a new mismatch is printed once to officers. Reasons travel only over the OFFICER addon channel and as whispers to online members whose rank (from your own roster) may see the officer log; never on GUILD. Clients keep officer data only if their own rank may see it.
- History is kept per guild (max 500 entries per character).

## 4. Alerts
- **Item tooltips:** extra lines on wanted items (item and rule requests) — "Wanted by <name>: N more · price"; your own requests show as "On your wishlist: N more". Up to 4 lines, then "+N more".
- **Popup on opening a vendor, auction house or mailbox:** "N items in your bags are on the guild wishlist", listing up to 6 (item ×count -> requester · price), with Show me (opens the Wishlist tab) / Ignore forever (turns the popup off; back on in Settings); the X just closes it. Only guildmates' requests, only unbound items, capped at what's still unclaimed. Our own non-modal frame at the top of the screen; never blocks selling. Shows **once per login**, the first time one of those windows opens with something to fill. The sell warning and the COD warning each have their own switch.
- **Sell warning:** selling an item a guildmate asked for gives a red on-screen + chat message pointing to the vendor's Buyback tab. Detected afterwards from the buyback list; the sale is never stopped.
- **Minimap button:** red badge with the number of guildmates' requests created since you last opened the Wishlist tab (per character).

## 5. Mailbox "Guild Requests" panel (planned for v0.5.0, agreed 2026-11-18, not started)
**What players get:** at the mailbox, a **Guild Requests** panel lists open guild requests you can fill from your own bags. Click one, then **Fill Send Mail**: Blizzard's Send Mail form gets the recipient, the subject `Unc's Tavern: <Item> ×N` and the items attached from your bags (stacks split to the exact amount). You check it and press Blizzard's **Send** yourself. When the mail actually goes out, your claim updates automatically ("I'm sending N"); the requester's addon confirms on receipt, so the Guild log can show Confirmed.

**Design:**
- **A panel docked to the right edge of the mail window, not a new mailbox tab** (with a small button to open/close it). Adding a tab means writing into Blizzard's mail-window tab system, which risks tainting Blizzard's own actions; a docked panel is our own frame.
- **We never send.** Fill acts only on the player's click; Send and anything that sends stay Blizzard's.
- **No COD while COD mail is broken on the server** ("Internal mail database error", even without addons). The panel shows "Gift" or the requester's price as text only. The existing switch (`PAY_DISABLED` in Wishlist.lua, which also greys out the Wishlist form's **Pay up to**) turns on the COD pre-fill when the server is fixed: quantity × the requester's price, clearly shown.
- Event-driven only (mailbox and bag events, no timers). New file `Modules\Mail.lua`; existing modules get small hooks only.

**The list:** other players' open requests (never your own) where your bags hold the item, or for rule requests any bag item that fits the rule. Columns: item and requester, **needs** (quantity minus received), **you have**, payment (Gift / price). Sorted by what you can fill completely. If you already claimed it, it shows your claim and Fill uses that amount.

**Step 1 is an in-game probe**, because Forever blocked guild chat from a plain button click and might block attaching too: `/tavern mailprobe` (Send Mail tab open) tests filling recipient and subject, splitting a stack and attaching 1 item, and clearing the attachment. It never sends. If attaching is blocked, the fallback fills recipient and subject and shows "attach N × Item" with the item highlighted in your bags, for the player to drag in.

**Build steps (one commit each, with in-game test steps):**
1. `/tavern mailprobe` → test in game.
2. The panel and list (read-only).
3. Fill Send Mail: recipient, subject, attachments (or the fallback).
4. Auto-claim when the mail is sent, plus the Guild log tie-in.
5. `/tavern securitytest` additions, taint check (guild invite and Blizzard's mail still work), then SPEC, README and CHANGELOG.

**Deferred:** the COD mismatch check in the Guild log ("paid more than the price"); it needs working COD mail, like the COD pre-fill.

## 6. Level-up post
- On level-up (after combat), a popup offers to post to guild chat: `[Unc's Tavern] <Name> reached level <N>!` The player clicks **Post** — WoW: Forever only lets addons post to chat on a click.
- On by default; can be turned off in Settings.
- A guild's own Discord tools may parse this line, so keep the format exactly stable.
- Only players with the addon post their own level-ups.

## 7. Settings tab
- Laid out like the game's Options window: a category list on the left in groups, the chosen category's page on the right (big title, divider, **Defaults** button that resets that page after asking), rows with the setting's name on the left and its control (checkbox, < dropdown > arrows, button) in a column; descriptions show in a tooltip on hover, rows highlight on hover. Blizzard's own art (atlases, dropdown template) when the client has it, plain fallbacks otherwise.
- Categories: **Unc's Tavern** group: General (level-up posts), Alerts (tooltip lines, wishlist reminder popup, sell warning, COD warning), Minimap (minimap button, new request badge). **Guild** group: Sharing (page title "Sharing with <guild>", see 8; the category switches are indented under the master switch), Permissions (see 9). Modules add categories with `RegisterCategory`.
- Requests and claims of players no longer in the guild (left or kicked) are hidden everywhere (lists, tooltips, popup) as soon as the roster shows it; they come back if the player rejoins.
- Our dialogs (claim, got, delete, level-up) are our own frames, never Blizzard's shared StaticPopup, so the game's own popups (guild invite, send money) are untouched.

## 8. Security & sharing
Full rules: "Security rules (always apply)" in CLAUDE.md. In short:
- **Opt-in per guild:** first login in a guild asks "Enable Unc's Tavern sharing for <guild>?". Until Enable, nothing is sent or accepted (the roster still works). Settings: master switch, Wishlist / PvP stats / Helped-History switches with what each shares, request expiry, **Delete this guild's data**.
- **Trust:** the sender name (set by the server) is trusted; message content never is. Messages are accepted only on the GUILD channel (officer data: only OFFICER or WHISPER, never GUILD), protocol 2, from members on our own cached roster (unknown sender: one roster refresh, then dropped), within a per-sender rate limit (burst 60, then 1/s). Every field is validated; text is stripped of escape codes; item names and links are always built locally from the item ID.
- **Ownership:** requests only from their requester, claims only from their claimer, PvP stats only about the sender, Helped only from the receiver's confirmation. No relaying.
- **Money and items:** the addon never sends mail, takes mail, pays COD, trades or sells. A guildmate's mail whose COD is above quantity x your wishlist price gets a red warning; Blizzard's COD confirmation is untouched.
- Saved data is validated on load. Data is stored per guild (name + realm); leaving or changing guild hides the old data and stops syncing.
- `/tavern securitytest` (after `/tavern debug on`): feeds forged messages to the receive path in a sandbox, sends nothing, prints PASS/FAIL.

## 9. Rank permissions and moderation
- Settings > Guild > **Permissions**: one row per guild rank with **Moderate requests** and **See officer log**, plus **Keep guild log entries** (7/14/30/60/90 days). Only the guild leader can change them; everyone else sees what is in force. The guild leader can always do both. Default: guild leader only.
- The config is sent as `K|t|mod|log|days|ranks` (timestamped; rank bit masks; checksum of the rank names) and accepted **only from rank 0 on your own roster**; the leader re-sends it when a guildmate logs in or presses Sync. If the guild's ranks change (rename, add, remove), everything falls back to guild leader only until the leader changes a box.
- **Moderators** (ranks allowed to moderate) right-click a Wishlist row: **Remove <name>'s request** / **Clear <name>'s claim (N)**, each asking first with an optional reason (60 characters, officer log only). Messages `MD` / `MC` on GUILD; every client checks the moderator's rank from its own roster before applying. The owner's (or claimer's) own client then marks it removed and announces that like any own edit. Moderators re-announce their own actions for 14 days when a guildmate logs in. Every action shows in the Guild log.
- `/tavern probe`: what this client supports (rank list, context menu, OFFICER addon channel).

## 10. Ledger keepers (planned)
Lets trusted members pass on other players' requests, so you don't have to be online at the same time as the owner. Everything is off by default and opt-in at both ends, behind a red "use at your own risk" warning that has to be ticked by hand.
- **Leader:** on the Permissions page, a **Keep the ledger** box per rank (same leader-only, rank-0-checked config as the other permissions).
- **Owner:** "Let ledger keepers pass on my requests and claims." Consent travels on the owner's own messages; keepers store and pass on only consenting owners' data, received directly from them.
- **Receiver:** "Accept requests passed on by ledger keepers." Off: relayed data is ignored as today.
- **Safeguards:** relayed rows show "via <Keeper>" in grey until the owner's own message confirms them; the owner's own data always wins; an owner who sees a keeper pass on a changed version of their data gets a warning and an officer-log entry. Never relayed: Helped/History confirmations, moderator actions, rank permissions, bags, gold, mail, alts.
- **Risk (shown in the warning):** a keeper running a modified copy could alter or invent requests and claims for players who opted in. It can't move gold or items (the player still presses Blizzard's buttons; the COD warning still applies).
- **Later, maybe:** signed records (each player signs their own data; receivers keep the key first seen directly from that player), which would let receivers detect a keeper's changes. Needs public-key crypto in plain Lua, so it's a separate decision.
- Not planned inside the addon: a website. Addons can't reach the internet; that would need a companion program on every PC (possible later as a separate companion project).

## Out of scope
- Gear upgrade detection (dropped).
- Info/events board, RSVPs, Notes tab and any Discord integration inside the addon (guilds can handle Discord with their own tools, outside the game).
- Officer actions (promote, demote, remove) and anything that drives Blizzard's guild window.
- Announcing level-ups for members without the addon (maybe later).
