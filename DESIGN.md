# Banished Into The Abyss — Design Doc v0.1

Idle PBBG. Text/UI presentation (no game art needed). Hard player ceiling ~400. Hosted free on Netlify (frontend) + Supabase (Postgres, Auth, Realtime). Tick-based combat and guild bosses — nothing requires players to be online at the same moment.

## 1. Premise & tone

You were cast out — banished into the Abyss, a bottomless, layered pit that gets stranger and more hostile the deeper you go. There's no returning to the surface; the only way out is down. Each layer ("Depth") is harder than the last, and going deep enough to survive it at all requires periodically giving up your current strength to descend further empowered — a prestige loop that *is* the descent narrative, not just a number reset bolted onto a theme.

## 2. Core loop

1. **Idle progression.** Characters passively train/explore in the background. Progress is computed lazily: every time the client talks to the server (page load, action, periodic poll), the server calculates elapsed real time since `last_tick_at` and grants XP/gold/resources for that window, capped at a max offline duration (e.g. 24–72h) so idle gains don't become infinite AFK exploits. This avoids needing a always-on background worker — important since it's the one design choice that keeps the game fully alive on free-tier hosting (see §6).
2. **Active actions.** Logged-in players can spend actions/energy on: training a stat, delving into the current Depth for loot and boss-damage contributions, crafting, or trading.
3. **Depths (prestige).** When a character's power crosses the threshold for their current Depth, they can **Descend**: stats reset to a baseline, but the character keeps a permanent per-Depth multiplier and unlocks a new tier of gear/enemies/currency. This is the "infinite slow scaling" mechanic — each Depth's numbers restart small but the multiplier curve from prior Depths means depth 20 plays entirely differently from depth 1, without the raw numbers ever needing to overflow into absurd territory. Depth number is a visible status symbol (leaderboards, chat name tags).
4. **Endgame.** The exciting part isn't "the biggest number" — it's what unlocks at depth milestones: new guild-boss tiers, cosmetic chat titles/tags, rare crafting recipes, and eventually **Abyssal Rifts** — timed, high-difficulty solo or guild content that only very deep characters can enter, with unique rewards that feed back into guild bosses (see §4). Endgame players are never "done"; they're gated by Depth-gated content, not by a stat treadmill.

## 3. Characters & economy

- One character per account (simplifies balance and abuse surface for a 400-player game).
- Two currencies: **Gold** (everyday, earned constantly, spent on gear/consumables) and **Abyssal Shards** (rare, earned from guild bosses and deep Depths, spent on prestige-tier upgrades). Two currencies keep the early economy from being trivialized by late-game income.
- Items live in a simple `items` catalog (key, name, rarity, type) with per-player `inventory` rows. Text-only presentation means items just need good names/flavor text, no art pipeline.

## 4. Guilds & guild bosses

- Guilds: name + tag, leader/officer/member roles, guild chat channel, member cap (recommend 20–30 given the 400-player ceiling — enough for ~15-20 guilds to exist).
- **Guild bosses**: each guild has a rotating boss with a shared HP pool. Members contribute damage passively (a slice of their idle-tick output is auto-applied to the active boss) and can also spend actions to strike it directly for bigger, capped hits. All damage is server-validated (see §6) so nobody can fabricate a hit.
- Defeating a boss distributes loot/Shards weighted by each member's contribution share, logs a "last hit" and "top damage" callout in guild chat, and starts a cooldown before the next (harder) boss spawns. Boss tier scales with the guild's average Depth, so a guild of shallow characters and a guild of deep ones both have a boss that's meaningfully hard for them — this is what keeps guild bosses relevant forever instead of being trivialized once players outscale them.
- Because boss HP/respawn state is just rows with timestamps, it's evaluated lazily on read exactly like idle ticks — no cron required to keep a boss "alive."

## 5. Social systems

- **Global chat** — one shared channel, Supabase Realtime broadcast, rate-limited server-side (e.g. 1 message / 2s per user) to keep it usable at up to a few hundred concurrent chatters.
- **Guild chat** — same mechanism, scoped to guild members only via RLS.
- **Whispers (`/w name message`)** — private 1:1 messages, delivered over the same Realtime channel the recipient is already subscribed to (their own user-id channel), so no polling needed.
- **`/send name item|gold amount`** — transfers items or gold between two players. This is the highest-abuse-risk feature in a small free game (multi-accounting, scam funneling), so it never touches the table directly from the client: it goes through a single server-side function that checks balance, logs every transfer (sender, recipient, what, when) to an immutable `item_transfers` table, and enforces a small per-transfer and per-day cap plus a short cooldown. That log is also what makes it possible to investigate a dispute after the fact.
- Both chat and `/send` are implemented as slash commands parsed client-side and dispatched to the same small set of server functions — no separate "trade UI" needed for v0.

## 6. Why this stays free at ~400 players

- **Netlify Free**: 300 credits/month (deploys ≈15 credits each, bandwidth ≈20 credits/GB, ~10k requests ≈2 credits). A static text-UI frontend for a few hundred users comfortably fits; the main thing to watch is bandwidth if chat volume gets heavy, which is a reason to keep payloads small (plain JSON, no big assets).
- **Supabase Free**: 500MB database, 1GB file storage, 50,000 monthly active users, 5GB egress, 500,000 Edge Function invocations, and — the one that matters most here — **200 concurrent Realtime connections**. At a 400-player *cap*, not every player is online simultaneously, but if the game ever gets popular enough to regularly have 200+ concurrent browser tabs open, that's the first free-tier wall you'll hit — and the natural place to start paying (Supabase Pro), not a reason to avoid this stack now.
- **The one real gotcha**: Supabase free projects **pause after 7 days with no activity**. A cron-driven world (bosses ticking down on a timer even with nobody around) would silently stop. That's exactly why §2 and §4 use lazy, read-time computation instead of a background scheduler — the game state only needs to be *correct whenever someone next looks*, not continuously animated in the background. As a belt-and-suspenders measure, a free external pinger (e.g. a GitHub Actions cron hitting a health-check endpoint weekly) keeps the project from ever pausing at all.

## 7. Data model (implemented in `supabase/schema.sql`)

`profiles`, `guilds`, `guild_members`, `guild_bosses`, `guild_boss_damage_log`, `items`, `inventory`, `chat_messages`, `whispers`, `item_transfers`. Mutating actions (idle tick resolution, boss attacks, sends, chat/whisper posts) go through `SECURITY DEFINER` Postgres functions rather than raw table writes, so all game rules are enforced in one place regardless of client.

## 8. Open design questions for later passes

- Exact XP/gold curve constants and Depth thresholds (needs a balancing pass once there's something playable to test against).
- Whether guilds need a shared bank in addition to `/send`.
- PvP: not in scope for v0 — flagged here so it's a deliberate future decision, not an oversight.
- Moderation: with live chat at this scale, a lightweight mute/ban table and a couple of admin-only RPCs are worth adding before public launch.
