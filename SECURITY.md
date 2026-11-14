# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   (GitHub private vulnerability reporting).
2. Describe what a modified client or a crafted message can do, and how to reproduce it.

You'll get an answer as soon as possible. Please give a reasonable time to ship a fix
before publishing details.

Examples of what counts as a security problem:
- forging or changing another player's wishlist request, claim, Helped count or PvP stats;
- getting links, textures, colors or formatting from a message shown in someone's UI;
- crashing, freezing or flooding other players' clients with addon messages;
- data reaching players outside the guild, or anything moving gold or items without the
  player pressing the game's own button.

## Supported versions

Only the latest release gets security fixes. Versions before 0.4.0 trust message content
and relay other players' data; please update.

## What the addon shares

Nothing, until the player clicks **Enable** on the "Enable Unc's Tavern sharing for
&lt;guild&gt;?" prompt. After that, only with members of the player's current guild who run
the addon, over the guild addon channel, and only the parts switched on in Settings:

| Setting | What is sent |
|---|---|
| Wishlist | your own requests (item ID or rule, quantity, price, note), your own claims, and how many you received |
| PvP stats | your honorable kills, deaths to players, dishonorable kills and deaths, killing blows, "Most killed by" (self-reported) |
| Helped / History | who delivered items to you (the receiver's confirmation that counts toward their Helped) |

Also sent: a short hello with the addon version, so guildmates know who runs it.

## What the addon never does

- Share bag contents, gold, mail (other than the sender of items that filled your request),
  other guilds' data, or which characters belong to the same account.
- Send or take mail, pay COD, trade, sell or move gold or items. It only fills things in; the
  player presses the game's button.
- Run code from received or saved data (no `loadstring`/`RunScript`).
- Use external libraries.

## How messages are checked

- The sender name is set by the game server and trusted; message content never is.
- Accepted only on the guild channel, in the current message format, from players on the
  receiver's own copy of the guild roster, within a per-sender rate limit.
- A request is accepted only from its requester, a claim only from its claimer, PvP stats
  only about the sender. Nobody relays other players' data.
- Every field is range-checked. Received text has all escape codes removed. Item names and
  links are always built by the receiver's own client from the item ID.
- Saved data is checked the same way when the addon loads.

Developers can run `/tavern debug on` then `/tavern securitytest` in game to feed forged
messages to the addon in a sandbox and see which are rejected (nothing is sent).
