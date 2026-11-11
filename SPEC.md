# Unc's Tavern — v1 spec

A guild hub for <Unc of Azeroth>. Small, Blizzard-native window opened from a minimap button or `/tavern`.
Tabs along the bottom: **Roster · Wishlist · Settings**. Visual reference: the mockup canvas (Roster, Wishlist, Mailbox, Alerts screens).

## 1. Roster (home tab)
- Every guild member from the guild roster: name (class-colored), level, class, online status + zone (or "Offline Xh").
- PvP columns: **Kills, Deaths, K/D**. Members without the addon show "—".
- Click a column header to sort. "Show offline" checkbox, name search box.
- Footer: how many members have the addon installed.

## 2. PvP stats (feeds the roster)
- Each player's addon tracks their own PvP kills and deaths and shares them over guild addon messages.
- **Step 0 — test first:** build a tiny test command (`/tavern pvptest`) that prints what Forever exposes:
  1. Character statistics (honorable kills, deaths from other players) via GetStatistic, if available.
  2. Honorable kill counters / PvP kill events.
  3. Death recap info about who killed the player.
  Choose the approach based on the results. If deaths can't be separated from PvE deaths, ship kills only and hide Deaths and K/D.

## 3. Wishlist tab
- **Add a request:** shift-click an item from bags into the item slot, or type in a search box (searches a built-in list of common mats/leveling items plus any item the client has cached). Fields: quantity, note, payment.
- **Payment:** Gift, or "Pay up to X per item" (gold/silver/copper).
- **Rule requests (simple):** armor type + minimum required level + minimum of one stat (e.g. Cloth, 26+, 4+ Intellect).
- **List:** item (quality-colored), progress (8 / 20), requester (class-colored), payment, claim status. Filters: All / Mats / Gear / Mine.
- **Claim:** "I'm sending N" marks it so others don't double-send.
- **Auto-complete:** when the requester receives the items (mail/bags), the count goes down; done requests are removed.
- Requests sync across the guild; online members pass them along so requests spread while the requester is offline.

## 4. Alerts
- **Bag tooltip:** extra lines on wanted items — "Wanted by <name>: N more · price".
- **Popup on opening a vendor, auction house or mailbox:** "N items in your bags are on the guild wishlist" with Show me / Not now. Never blocks selling.
- **Minimap button:** click opens the window, right-click opens settings, badge when new requests arrive.

## 5. Mailbox "Guild Requests" tab
- New tab next to Inbox / Send Mail.
- Lists only requests the player can fill from their bags.
- Picking one shows a draft: recipient, subject ("Unc's Tavern: Item ×N"), items attached, COD pre-filled as quantity × requester's price (or Gift). Everything is editable.
- "Fill Send Mail" fills the real Send Mail form. The player presses Send.

## 6. Level-up post
- On level-up, post to guild chat: `[Unc's Tavern] <Name> reached level <N>!`
- On by default; can be turned off in Settings.
- This line is parsed by the guild's Discord bot (via the in-game guild chat <-> Discord link), so keep the format exactly stable.
- v1: only players with the addon post their own level-ups.

## 7. Settings tab
- Toggles: level-up posts, vendor/AH/mail popup, tooltip lines, minimap button.

## Out of scope for v1
- Gear upgrade detection (dropped).
- Announcing level-ups for members without the addon (maybe later).

## Later (separate project)
- Discord bot (runs on a NAS): read `[Unc's Tavern]` lines from the bridged guild chat channel and update the daily leaderboard in the Tavern Bulletin channel.
