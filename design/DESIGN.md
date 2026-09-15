# Banished Into The Abyss — Design Doc v0.1

Idle PBBG. Text/UI presentation (no game art needed). Hard player ceiling ~400. Hosted free on Netlify (frontend) + Supabase (Postgres, Auth, Realtime). Tick-based combat and guild bosses — nothing requires players to be online at the same moment.

## 1. Premise & tone

You were cast out — banished into the Abyss, a bottomless, layered pit that gets stranger and more hostile the deeper you go. There's no returning to the surface; the only way out is down. Each layer ("Depth") is harder than the last, and going deep enough to survive it at all requires periodically giving up your current strength to descend further empowered — a prestige loop that *is* the descent narrative, not just a number reset bolted onto a theme.

## 2. Core loop

1. **Idle progression.** Characters passively train/explore in the background. Progress is computed lazily: every time the client talks to the server (page load, action, periodic poll), the server calculates elapsed real time since `last_tick_at` and grants XP/gold/resources for that window, capped at a max offline duration (e.g. 24–72h) so idle gains don't become infinite AFK exploits. This avoids needing a always-on background worker — important since it's the one design choice that keeps the game fully alive on free-tier hosting (see §6). `perform_idle_tick()` (the function that runs this catch-up) also now *simulates real combat* for the elapsed window, not just passive income: it spends actions and fights the player's current pack at the same one-action-per-8-seconds cadence as online play, sharing its exact per-action combat resolution with §4b's online strike via a common `resolve_combat_action()` core, so offline kills/deaths/xp/gold and pack state come out identically to what would have happened had the tab stayed open. Capped by both the same offline-duration cap above and the player's actual action pool (an empty pool means no offline fighting, same as running dry online). This closed a real gap: before it existed, `profiles.actions` only ever ticked down while a browser tab was open and polling, so time spent offline drained nothing and fought nothing.
2. **Active actions.** Logged-in players can spend actions/energy on: training a stat, delving into the current Depth for loot and boss-damage contributions, crafting, or trading. Implemented so far: each idle tick also auto-spends 1 action to strike the player's current solo enemy (see §4b); once actions hit 0 the auto-strike pauses gracefully (no error) until the player clicks Refresh Actions — idle XP/gold income is unaffected either way. The same action pool is now also spent by offline catch-up (point 1 above), so a full pool can be run down by either being online and idling, or simply being away.
3. **Banishment (prestige).** At level 100, a character can be Banished — sacrificed to the Abyss in exchange for +1 Depth (displayed to players as "Banishments"), carrying forward a slice of their current attack/defense/max HP sized by how many times they'd already Banished before this one (see §3 for the exact tiers). This is the "infinite slow scaling" mechanic: each life restarts small at level 1, but the compounding Banishment-count-driven retention plus the Depth-driven idle income multiplier (§7) mean a character on their 5th banishment plays entirely differently from a first-timer, without any single life's raw numbers ever needing to overflow into absurd territory. Depth ("Banishments") is a visible status symbol (leaderboards, chat name tags). (There used to be a separate Abyssal Prowess currency driving this instead of Depth directly — removed; Depth already *was* the banishment count, so routing retention through a second number that just tracked Depth 1:1 was pure indirection.)
4. **Endgame.** The exciting part isn't "the biggest number" — it's what unlocks at Depth/Banishment milestones: new guild-boss tiers, cosmetic chat titles/tags, rare crafting recipes, and eventually **Abyssal Rifts** — timed, high-difficulty solo or guild content that only very deep characters can enter, with unique rewards that feed back into guild bosses (see §5). Endgame players are never "done"; they're gated by Depth-gated content, not by a stat treadmill.

## 3. Characters & economy

- One character per account (simplifies balance and abuse surface for a 400-player game).
- One currency: **Gold** — everyday, earned constantly, spent on gear/consumables. (There used to be a second currency, Abyssal Prowess, earned only by Banishing; it's been removed — see the Banishment retention tiers below, which now read directly off Depth instead.)
- **Death penalty** (implemented in `strike_enemy()`): currently 0% gold and 0% xp lost on death — no economic cost to dying at all. This used to be 25%/10%, back when it was the counterweight to how freely Number of Enemies Spawned / Number of Affixes / Player Debuffs could be pushed (those knobs have no ceiling and reward proportionally harder fights, so without a real cost for losing there'd be no reason not to max every one of them and grind through deaths for free). It was zeroed out deliberately once automatic Banishment-depth scaling (see §2.3/`enemy_effective_stats()`) started covering that same "don't overreach for free" role on its own — every fight gets harder forever regardless of what the player picks, so losing already has a natural ceiling without also needing an economic tax. The mechanism (win-only rewards, a full heal, a tracked 'death' event) is untouched — only the two percentages moved to 0. TUNE back up if playtesting says 0 feels too safe.
- **Banishment retention tiers** (implemented in `perform_banishment()`, gated to level 100+): the tier is set by how many times the character has *already* Banished (`profiles.depth`, displayed as "Banishments") before this banishment.

  | Banishments already reached | % of (attack / defense / max HP above base) retained |
  |---|---|
  | 0 – 9 | 0.25% |
  | 10 – 49 | 0.50% |
  | 50 – 99 | 0.75% |
  | 100+ | 100% (full retention) |

  (These are a straight /10 rescale of the old Abyssal-Prowess tiers — 100/501/1001 — since Prowess was always earned at a flat `floor(level/10)` = 10 per banishment given the level-100 minimum, so it tracked Depth 1:1. Same pacing/milestones as before, just one fewer currency to track.)

  Each banishment grants +1 Depth; level/xp/gold reset to 1/0/0, inventory and the current solo fight are cleared, and HP/actions come back full. All constants are marked `-- TUNE` in `schema.sql` — first-pass numbers, not balanced yet.

  **Important, and true today even before itemization exists:** the attack/defense/max HP that retention reads are `profiles`' own base columns — a character's *own* permanent growth, currently untouched by anything except Banishment retention itself (there's no gear or per-level stat growth yet, so these columns sit at their fresh-character default the whole way to level 100, and retention has nothing above base to carry forward — banishing today changes Depth only, not combat power). This is deliberate and must stay true once gear exists: gear must **never** mutate these columns directly. Gear stats have to apply the same way `class_defs`' class bonuses already do — a separate, combat-time-only modifier bundle (see `strike_enemy()`'s `player_mods` in `schema.sql`), invisible to `perform_banishment()`. If gear were instead baked into `profiles.attack/defense/max_hp`, equipping strong gear right before banishing would let a player permanently bank power they never actually earned on the character itself — gear is meant to stay swappable/losable, never something Banishment can launder into permanent retention.
- Items live in a simple `items` catalog (key, name, rarity, type) with per-player `inventory` rows. Text-only presentation means items just need good names/flavor text, no art pipeline.

## 3a. Stats

All six standard stats are now wired into `strike_enemy()` in `schema.sql` — Speed was the last one, added along with pack combat's initiative/evasion mechanics (see below). The special/relic-only stats remain a design pass only, recorded here so the design isn't lost, not yet implemented in the RPCs — they need a real items/relics system first.

**Standard stats** (every character has these; gear/training raise them):
- Power
- Defense
- Attack Speed
- Crit
- Multi Strike
- Speed — decides which side (player or the current pack) swings first each round, compared against the pack's average Speed among currently-alive members and recomputed every round (ties go to the player); also grants **Evasion**, a flat chance to dodge an enemy hit entirely, at 1 Speed = 1% Evasion, hard-capped at 50%. Both are implemented directly in `strike_enemy()`/`pack_counterattack()`, not via the general `compute_damage()` modifier vocabulary, the same way Multi Strike and Attack Speed already weren't — see `evasion_flat`/`speed_pct` in the class-bonus comment there for how a future class bonus, gear roll, or affix could add to either.

**Special stats** (relic-only — never trained, only found rolled on relic-tier items):

| Stat | Rate | Cap | Effect |
|---|---|---|---|
| Dodge | 1% per roll | 25% | Fully dodges an attack |
| Block | 1% per roll | 25% | Halves incoming damage |
| Parry | 1% per roll | 25% | Deflects 25% of the incoming damage |
| Riposte | 1% per roll | 25% | Returns 25% of the incoming damage |
| Abyssal Touch | 1% per roll | none | Adds abyssal damage |
| Thorns | flat, 5 per roll | none | Deals flat thorns damage back on being hit |
| Bristle Back | up to 5% per roll | none | Multiplier on Thorns damage |
| Life Steal | 1% per roll | 50% | Heals the player for a % of damage dealt |
| Bleed | 1% per roll | 25% | Target bleeds for a % of damage over time |

Note the overlap with Speed's new core-stat Evasion above: relic-only Dodge (1%/roll, cap 25%) is a separate, additive source of the same "fully avoid this hit" outcome, not a duplicate to reconcile away — a character could eventually stack Speed-derived Evasion and relic-rolled Dodge on top of each other. Whether they should share one roll-check or stay two separate ones is a TUNE decision for whenever itemization actually gets built.

More relic-only stats to come. Implementing these for real needs an items/relics system (rollable affixes, a relic slot on `profiles` or an equipped-items table) that doesn't exist yet — next step once this is prioritized is designing that itemization layer, then rewriting `strike_enemy()`'s damage math around the full standard-stat formula plus relic-stat rolls. Per §3 above, that itemization layer must be built as a modifier bundle (gear key → stat bonuses, merged into `player_mods` at combat time), not as writes to `profiles`' base stat columns.

## 4. Guilds & guild bosses

- Guilds: name + tag, leader/officer/member roles, guild chat channel, member cap (recommend 20–30 given the 400-player ceiling — enough for ~15-20 guilds to exist).
- **Guild bosses**: each guild has a rotating boss with a shared HP pool. Members contribute damage passively (a slice of their idle-tick output is auto-applied to the active boss) — implemented as the sole damage source now; a manual strike button was removed in favor of pure idle-tick feeding. All damage is server-validated (see §6) so nobody can fabricate a hit.
- Defeating a boss distributes loot weighted by each member's contribution share, logs a "last hit" and "top damage" callout in guild chat, and starts a cooldown before the next (harder) boss spawns. Boss tier scales with the guild's average Depth, so a guild of shallow characters and a guild of deep ones both have a boss that's meaningfully hard for them — this is what keeps guild bosses relevant forever instead of being trivialized once players outscale them.
- Because boss HP/respawn state is just rows with timestamps, it's evaluated lazily on read exactly like idle ticks — no cron required to keep a boss "alive."

## 4b. Solo combat (one continuous fight, no zones)

A standalone player-vs-mob loop (`enemies`, `player_combat`, `strike_enemy()`) drives the "Current Battle" panel independently of guild bosses. There is deliberately no zone/dungeon-select screen and never will be one: it's a single ongoing encounter that scales forever (see the Banishment depth-scaling in `enemy_effective_stats()`) and pulls from a growing mob roster instead of gating progress behind discrete areas the player has to leave and re-enter. Each idle tick auto-strikes the current pack (1 action per strike); a kill or a death respawns a fresh pack immediately, so there's always a fight in progress.

The one-action-worth-of-fighting logic (initiative, swings, Multi Strike, kill heal, pack-clear/death handling, affix/debuff reroll on respawn) lives in a shared core, `resolve_combat_action()`, rather than inside `strike_enemy()` itself. `strike_enemy()` is now a thin wrapper around it (one DB read, one call, one DB write) used while the player is online; `perform_idle_tick()` (§2.1) calls the same core in a tight in-memory loop to simulate whatever fighting would have happened while the player was offline, so the two paths can never drift apart in behavior.

The `enemies` table holds the mob roster (8 as of this pass — Abyssal Rat, Rift Skitterling, Gloomfen Leech, Void Moth, Marrow Hound, Ironshell Grub, Whispering Husk, Umbral Wraith), each just a set of base stats/flavor. `roll_pack()` picks a random eligible enemy **per pack member**, not once for the whole pack, so a single fight can mix species rather than always being a uniform pack of one kind. Eligibility is gated by `enemies.min_depth` (the player's current Banishment count) — this is a pure variety/content gate, deciding which mobs *can* show up as the player goes deeper, never a power gate; all real difficulty still comes from the existing tier/depth/variance multiplier in `enemy_effective_stats()`, applied uniformly no matter which mob got picked. This is what makes "stay in one fight until endgame" actually work: the fight never needs to hand off to a harder one, it just keeps getting harder in place and slowly reveals stranger things the deeper the player's account has gone.

Adding more mobs later is just adding rows — no combat-loop changes needed, same as an affix or debuff.

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

`profiles`, `guilds`, `guild_members`, `guild_bosses`, `guild_boss_damage_log`, `items`, `inventory`, `enemies`, `player_combat`, `banishments`, `chat_messages`, `whispers`, `item_transfers`. Mutating actions (idle tick resolution, boss attacks, solo strikes, banishment, sends, chat/whisper posts) go through `SECURITY DEFINER` Postgres functions rather than raw table writes, so all game rules are enforced in one place regardless of client.

## 8. Open design questions for later passes

- Exact XP/gold curve constants, Depth thresholds, and Banishment tier/gain numbers (needs a balancing pass once there's something playable to test against).
- The full stat system in §3a needs an itemization/relic layer designed before it can replace the current placeholder attack/defense combat math — and per §3, that layer must be a `player_mods`-style modifier bundle, never a write to `profiles`' base stat columns, so Banishment retention can never accidentally bank gear power.
- Whether guilds need a shared bank in addition to `/send`.
- PvP: not in scope for v0 — flagged here so it's a deliberate future decision, not an oversight.
- Moderation: with live chat at this scale, a lightweight mute/ban table and a couple of admin-only RPCs are worth adding before public launch.
