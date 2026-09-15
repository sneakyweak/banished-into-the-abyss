-- ============================================================================
-- Banished Into The Abyss — Supabase schema (v0)
-- Run this once in the Supabase SQL editor on a fresh project.
-- Idempotent-ish: safe to re-run on a project that only ever ran this file.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Extensions
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. Tables
-- ----------------------------------------------------------------------------

create table if not exists profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  username         text not null unique check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  level            int not null default 1,
  xp               bigint not null default 0,
  gold             bigint not null default 0,
  class            text not null default 'warrior' check (class in ('warrior','archer','magi','striker')),
  depth            int not null default 0,         -- prestige tier ("how deep") == total Banishments performed; displayed to players as "Banishments"
  hp               int not null default 10,         -- current hp (solo combat)
  max_hp           int not null default 10,
  attack           int not null default 1,
  defense          int not null default 1,
  actions          int not null default 3000,       -- spendable action points
  max_actions      int not null default 3000,
  last_tick_at     timestamptz not null default now(),
  last_boss_strike_at timestamptz not null default '1970-01-01',
  last_active_at   timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
-- belt-and-suspenders: the auth-email trick below already prevents
-- case-variant duplicates ("Steve" vs "steve") since both map to the same
-- fake email, but this guards any future signup path that doesn't.
create unique index if not exists idx_profiles_username_ci on profiles (lower(username));

-- for a project that already ran this file before "actions" existed:
-- adds the columns (and backfills existing characters to 3000) harmlessly
-- if they're already there.
alter table profiles add column if not exists actions int not null default 3000;
alter table profiles add column if not exists max_actions int not null default 3000;
alter table profiles add column if not exists hp int not null default 10;
alter table profiles add column if not exists class text not null default 'warrior'
  check (class in ('warrior','archer','magi','striker'));

-- starting health dropped from 100 to 10 (a deliberate difficulty change,
-- not a per-player choice). "create table if not exists" above only sets
-- the default for a table that doesn't exist yet — on a project that's
-- already deployed, the columns still default to 100 for every NEW signup
-- until the column default itself is changed here.
alter table profiles alter column hp set default 10;
alter table profiles alter column max_hp set default 10;

-- retroactively apply the new baseline to any EXISTING character still at
-- the old untouched max_hp default — gated on max_hp alone (not also
-- hp = 100) since a character mid-fight or otherwise not at full hp would
-- never have matched an hp = 100 check and would've been silently skipped.
-- Full-heals to the new baseline, which is the point of a baseline reset.
-- Never touches a character that's already progressed past 100 max hp via
-- Banishment retention; safe to re-run since those rows no longer match
-- after the first pass.
update profiles set hp = 10, max_hp = 10 where max_hp = 100;

-- Abyssal Prowess (formerly "shards" in an even older version) is removed:
-- Banishment retention is now tied directly to Depth (how many times
-- you've already banished) instead of a separate currency you had to bank
-- up first -- see perform_banishment() further down. Drops the column on
-- any project that still has it from before; a no-op on a fresh project
-- (whose CREATE TABLE above never creates it in the first place).
alter table profiles drop column if exists shards;
alter table profiles drop column if exists abyssal_prowess;

-- Combat Stats panel — Power/Defense already existed as attack/defense;
-- these four are new. Gear-driven, so they sit at these defaults until an
-- items/relics system that grants them exists.
alter table profiles add column if not exists attack_speed numeric not null default 1.0;
alter table profiles add column if not exists crit numeric not null default 0;
alter table profiles add column if not exists multi_strike numeric not null default 0;
alter table profiles add column if not exists speed int not null default 1;
-- Crit Damage: the bonus % damage a crit deals on top of a normal hit, same
-- "raw percentage" column shape as Crit itself (profiles.crit) rather than a
-- multiplier -- reads naturally as "Crit Damage: 100%" next to "Crit Chance:
-- 0%". Default 100 preserves compute_damage()'s original hardcoded 2x crit
-- multiplier exactly (1 + 100/100 = 2x), so shipping this stat doesn't
-- silently change existing crit damage until it's actually itemized via gear.
alter table profiles add column if not exists crit_damage numeric not null default 100;

-- base stat rebalance: Power (attack) 10 -> 1, Crit 5% -> 0%, Speed 10 -> 1,
-- Defense 5 -> 1 (a deliberate difficulty change). Same "add column if not
-- exists is a no-op on an already-deployed table" trap as hp above — the
-- column defaults above only take effect for a table created fresh by this
-- file, so the actual default has to be changed explicitly for a project
-- that's already deployed.
alter table profiles alter column attack set default 1;
alter table profiles alter column crit set default 0;
alter table profiles alter column speed set default 1;
alter table profiles alter column defense set default 1;

-- retroactively apply the new baseline to any EXISTING character still at
-- the old untouched defaults. Guarded per-column (not all four at once) so
-- a character that's, say, banished and picked up bonus attack/defense but
-- never touched crit/speed still gets those two reset. Never touches a
-- stat that's already moved off its old default (e.g. attack/defense
-- raised via Banishment retention); safe to re-run since those rows no
-- longer match after the first pass.
update profiles set attack = 1 where attack = 10;
update profiles set crit = 0 where crit = 5;
update profiles set speed = 1 where speed = 10;
update profiles set defense = 1 where defense = 5;

-- early-game rebalance: Power 1 -> 8, Defense 1 -> 6, HP 10 -> 30 (a
-- deliberate difficulty EASING, the opposite direction from the rebalance
-- right above). Reason: class_defs' percent bonuses (see its seed data
-- further down) are applied to these numbers at combat-resolution time in
-- compute_damage(), which only rounds once at the very end -- against a
-- base as small as attack=1/defense=1, a +5% bonus (1.05) rounds right back
-- to the unmodified value most of the time, so the bonus was invisible in
-- practice until a character had banished several times. These new
-- baselines are large enough for a +5-20% class bonus to actually move the
-- rounded output from level 1 onward, while staying small relative to
-- where Banishment retention and (eventually) gear can take them -- still
-- "starts small", just not so small the class bonuses round away to
-- nothing. perform_banishment()'s base_attack/base_defense/base_max_hp
-- constants are kept in sync with these by hand -- see the TUNE comments
-- there.
alter table profiles alter column attack set default 8;
alter table profiles alter column defense set default 6;
alter table profiles alter column hp set default 30;
alter table profiles alter column max_hp set default 30;

-- retroactively apply to any EXISTING character still sitting at the prior
-- baseline (attack=1/defense=1/max_hp=10) -- same "gated on the old default
-- alone" pattern as every earlier baseline change above; never touches a
-- character who's already progressed past that baseline via Banishment
-- retention.
update profiles set attack = 8 where attack = 1;
update profiles set defense = 6 where defense = 1;
update profiles set hp = 30, max_hp = 30 where max_hp = 10;

-- Difficulty selections (the fields below Refresh Actions). These are
-- player preferences, not per-fight state — they persist across fights and
-- only take effect on the NEXT spawned pack (see set_encounter_settings /
-- get_or_spawn_pack below). "depth" (above) IS the player's banishment
-- count.
alter table profiles add column if not exists sel_pack_size int not null default 1 check (sel_pack_size between 1 and 5);
alter table profiles add column if not exists sel_affix_count int not null default 0 check (sel_affix_count between 0 and 5);
alter table profiles add column if not exists sel_debuff_count int not null default 0 check (sel_debuff_count between 0 and 4);

-- Removed: sel_banishment_bracket, the old "which bracket am I choosing to
-- fight at" dial, separate from and pushable above the player's own actual
-- Banishment count. There's only one Banishments number in the game now --
-- see enemy_effective_stats()'s depth_mult, which scales enemy difficulty
-- (and proportionally, their xp/gold reward) directly off profiles.depth
-- automatically, no selection needed. A no-op on a project that's already
-- dropped it.
alter table profiles drop column if exists sel_banishment_bracket;

-- The inline checks just above only ever apply on a fresh deploy (the
-- column already existing makes "add column if not exists" a no-op, checks
-- included) -- on a project that's been running a while, the OLD 1-5/0-5/
-- 0-4 bounds silently stay in force at the table level forever unless
-- explicitly replaced here, no matter what set_encounter_settings()'s own
-- validation says. That's exactly what happened this round: pack size's
-- real cap moved to 30 (see set_encounter_settings), and affix/debuff
-- counts have validated dynamically against however big affix_defs/
-- debuff_defs actually are since the dropdowns-to-number-inputs change --
-- but the table itself was still silently capping every one of these at
-- their ORIGINAL launch-day catalog size (5 affixes, 4 debuffs) the whole
-- time, just invisibly, because the catalog hadn't grown past that yet to
-- expose it. Now that it has (11 affixes, 9 debuffs), the stale constraint
-- would reject a perfectly legal value the RPC just approved. Pack size
-- keeps a real table-level ceiling (it's a fixed design cap, not
-- catalog-driven — see set_encounter_settings' comment on why 30, not
-- unbounded); affix/debuff counts drop their upper bound entirely at the
-- table level since only set_encounter_settings' live catalog count can
-- ever know the real one.
alter table profiles drop constraint if exists profiles_sel_pack_size_check;
alter table profiles add constraint profiles_sel_pack_size_check check (sel_pack_size between 1 and 30);
alter table profiles drop constraint if exists profiles_sel_affix_count_check;
alter table profiles add constraint profiles_sel_affix_count_check check (sel_affix_count >= 0);
alter table profiles drop constraint if exists profiles_sel_debuff_count_check;
alter table profiles add constraint profiles_sel_debuff_count_check check (sel_debuff_count >= 0);

create table if not exists guilds (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(name) between 3 and 30),
  tag         text not null unique check (tag ~ '^[A-Za-z0-9]{2,5}$'),
  leader_id   uuid not null references profiles(id) on delete cascade,
  member_cap  int not null default 25,
  created_at  timestamptz not null default now()
);

create table if not exists guild_members (
  guild_id    uuid not null references guilds(id) on delete cascade,
  profile_id  uuid not null unique references profiles(id) on delete cascade, -- one guild per player
  role        text not null default 'member' check (role in ('leader','officer','member')),
  joined_at   timestamptz not null default now(),
  primary key (guild_id, profile_id)
);
create index if not exists idx_guild_members_guild on guild_members(guild_id);

-- Guild applications (player -> guild) and invites (guild -> player) share
-- this one table, distinguished by "type". A player can have at most one
-- pending request of a given type against a given guild at a time (see the
-- partial unique index below) — this does NOT stop a player from having
-- pending requests against several different guilds simultaneously, or an
-- application and an invite to the same guild at once (respond_to_* just
-- resolves whichever fires first and the request functions decline to
-- create a duplicate on top of an existing pending one).
create table if not exists guild_requests (
  id          uuid primary key default gen_random_uuid(),
  guild_id    uuid not null references guilds(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  type        text not null check (type in ('application','invite')),
  status      text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at  timestamptz not null default now()
);
create index if not exists idx_guild_requests_guild on guild_requests(guild_id, status);
create index if not exists idx_guild_requests_profile on guild_requests(profile_id, status);
create unique index if not exists idx_guild_requests_pending_unique
  on guild_requests (guild_id, profile_id, type) where status = 'pending';

create table if not exists guild_bosses (
  id             uuid primary key default gen_random_uuid(),
  guild_id       uuid not null references guilds(id) on delete cascade,
  tier           int not null default 1,
  name           text not null,
  max_hp         bigint not null,
  current_hp     bigint not null,
  spawned_at     timestamptz not null default now(),
  defeated_at    timestamptz,
  next_spawn_at  timestamptz
);
create index if not exists idx_guild_bosses_guild on guild_bosses(guild_id, spawned_at desc);

create table if not exists guild_boss_damage_log (
  id          bigint generated always as identity primary key,
  boss_id     uuid not null references guild_bosses(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  damage      bigint not null check (damage > 0),
  source      text not null default 'idle' check (source in ('idle','strike')),
  created_at  timestamptz not null default now()
);
create index if not exists idx_boss_damage_boss on guild_boss_damage_log(boss_id);
create index if not exists idx_boss_damage_profile on guild_boss_damage_log(profile_id);

create table if not exists items (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique,
  name         text not null,
  description  text,
  rarity       text not null default 'common' check (rarity in ('common','uncommon','rare','epic','legendary')),
  item_type    text not null default 'misc',
  base_value   int not null default 0
);

create table if not exists inventory (
  profile_id  uuid not null references profiles(id) on delete cascade,
  item_id     uuid not null references items(id) on delete cascade,
  quantity    int not null default 0 check (quantity >= 0),
  primary key (profile_id, item_id)
);

-- solo enemies: the mob catalog for the single ongoing "Current Battle"
-- (separate from guild_bosses, which are per-guild and idle-fed). A player
-- fights a PACK of 1-30 of these at once (see player_combat.pack and
-- strike_enemy below); this table still defines one enemy TYPE's base
-- stats, which get multiplied up per-spawn (tier, banishment bracket,
-- 0.85-1.25 spawn variance) rather than needing a row per difficulty.
-- roll_pack() picks WHICH enemy fills each pack slot at random (gated by
-- min_depth -- see below), so there's no enemy-select UI and no separate
-- "zones" to progress through: it's one continuous fight that both gets
-- harder (via the existing depth/tier/variance scaling) and pulls from a
-- wider mob roster as the player's Banishment depth grows.
create table if not exists enemies (
  key          text primary key,
  name         text not null,
  max_hp       int not null,
  attack       int not null default 1,
  defense      int not null default 0,  -- mitigates the player's damage per swing (see strike_enemy)
  xp_reward    int not null default 0,
  gold_reward  int not null default 0,
  speed        int not null default 1,  -- decides pack-vs-player initiative each round, see strike_enemy
  min_depth    int not null default 0  -- lowest profiles.depth (Banishment count) this can spawn at, see roll_pack
);
alter table enemies add column if not exists defense int not null default 0;
alter table enemies add column if not exists speed int not null default 1;
-- Pure content-gating, not a power lever -- base stats across the roster
-- sit in the same rough band on purpose (see the seed data's comment
-- below), so min_depth only ever decides WHICH mobs can turn up, never how
-- hard the fight actually is. Difficulty is entirely tier/depth_mult/
-- variance (enemy_effective_stats), same as always.
alter table enemies add column if not exists min_depth int not null default 0;
-- "level" (added for the previous rounds-scale-with-enemy-level design,
-- since superseded by attack_speed-driven round counts + elite/champion
-- tiers below) never shipped past one iteration — drop it if a project ran
-- that version of this file.
alter table enemies drop column if exists level;

-- One row per player: the pack they're currently fighting. "pack" is a
-- jsonb array of 1-30 enemy-state objects (see roll_pack()):
--   [{ "enemy_key", "name", "tier", "hp", "max_hp", "attack", "defense",
--      "xp", "gold" }, ...]
-- affix_keys/debuff_keys are the specific affixes/debuffs rolled for THIS
-- pack (snapshotted at spawn time from the player's sel_* choices on
-- profiles, so they stay fixed for the pack's lifetime even if the player
-- changes the dropdowns mid-fight — see set_encounter_settings, which
-- forces a respawn instead of mutating a live pack).
--
-- enemy_key/enemy_hp/enemy_tier are the ORIGINAL single-enemy columns from
-- before pack combat existed. They're kept (nullable now, unused by new
-- code) rather than dropped, purely so this file never fails re-running
-- against a database that still has old rows referencing them.
create table if not exists player_combat (
  profile_id     uuid primary key references profiles(id) on delete cascade,
  enemy_key      text references enemies(key),
  enemy_hp       int,
  enemy_tier     text default 'normal' check (enemy_tier in ('normal', 'elite', 'champion')),
  updated_at     timestamptz not null default now(),
  last_strike_at timestamptz -- null until the player's first real strike; kept
                              -- separate from updated_at so spawning/respawning
                              -- an enemy never itself looks like a recent strike
);
alter table player_combat add column if not exists enemy_tier text default 'normal'
  check (enemy_tier in ('normal', 'elite', 'champion'));
alter table player_combat alter column enemy_key drop not null;
alter table player_combat alter column enemy_hp drop not null;
alter table player_combat alter column enemy_tier drop not null;
alter table player_combat add column if not exists pack jsonb not null default '[]'::jsonb;
alter table player_combat add column if not exists affix_keys jsonb not null default '[]'::jsonb;
alter table player_combat add column if not exists debuff_keys jsonb not null default '[]'::jsonb;
alter table player_combat add column if not exists bracket_used int not null default 0;
alter table player_combat add column if not exists enemy_key_used text;
-- Obsolete now that roll_pack() picks a random enemy PER PACK MEMBER
-- instead of one enemy for the whole pack (see get_or_spawn_pack()) --
-- "which single enemy is this pack" stopped being a meaningful question,
-- and each member's own 'enemy_key' inside the pack jsonb array already
-- carries this info per-member anyway. Dropped, not just abandoned, since
-- nothing reads it anymore (a project that never had this column is a
-- no-op here).
alter table player_combat drop column if exists enemy_key_used;

-- "Daily Totals" (see bump_daily_stats() below): unlike the old client-only
-- session totals (which reset on every page reload and were never visible
-- across devices/tabs), these live here so they're server-truth, shared by
-- every surface reading this player's data, and reset once per calendar
-- day instead of once per page load. Lazily reset (see bump_daily_stats)
-- rather than cron-rolled at midnight, same "correct whenever someone next
-- looks" philosophy as idle ticks and guild bosses — see DESIGN.md §6.
alter table player_combat add column if not exists daily_dmg_dealt int not null default 0;
alter table player_combat add column if not exists daily_dmg_taken int not null default 0;
alter table player_combat add column if not exists daily_kills int not null default 0;
alter table player_combat add column if not exists daily_deaths int not null default 0;
alter table player_combat add column if not exists daily_idle_xp int not null default 0;
alter table player_combat add column if not exists daily_idle_gold int not null default 0;
alter table player_combat add column if not exists daily_reset_at date not null default current_date;

-- Lazily resets player_combat's daily_* counters to 0 the first time
-- they're touched after midnight (server/UTC date, not the player's local
-- timezone — a TUNE spot if per-player timezones ever matter), then adds
-- the given deltas and returns the resulting snapshot. Called from both
-- strike_enemy() (dmg dealt/taken, kills, deaths) and perform_idle_tick()
-- (idle xp/gold) so "Daily Totals" always reflects whichever kind of tick
-- the player just did, not just combat. Upserts a player_combat row first
-- since perform_idle_tick can fire before a brand-new player has ever
-- spawned a pack (which is otherwise what creates that row).
create or replace function bump_daily_stats(
  p_dmg_dealt int default 0,
  p_dmg_taken int default 0,
  p_kills int default 0,
  p_deaths int default 0,
  p_idle_xp int default 0,
  p_idle_gold int default 0
)
returns table (
  daily_dmg_dealt int,
  daily_dmg_taken int,
  daily_kills int,
  daily_deaths int,
  daily_idle_xp int,
  daily_idle_gold int,
  daily_reset_at date
)
language plpgsql
security definer
set search_path = public
as $$
declare
  cur_reset_at date;
begin
  insert into player_combat (profile_id) values (auth.uid())
    on conflict (profile_id) do nothing;

  select pc.daily_reset_at into cur_reset_at
    from player_combat pc where profile_id = auth.uid() for update;

  if cur_reset_at is distinct from current_date then
    update player_combat set
      daily_dmg_dealt = 0, daily_dmg_taken = 0, daily_kills = 0, daily_deaths = 0,
      daily_idle_xp = 0, daily_idle_gold = 0, daily_reset_at = current_date
    where profile_id = auth.uid();
  end if;

  return query
    update player_combat set
      daily_dmg_dealt = player_combat.daily_dmg_dealt + p_dmg_dealt,
      daily_dmg_taken = player_combat.daily_dmg_taken + p_dmg_taken,
      daily_kills = player_combat.daily_kills + p_kills,
      daily_deaths = player_combat.daily_deaths + p_deaths,
      daily_idle_xp = player_combat.daily_idle_xp + p_idle_xp,
      daily_idle_gold = player_combat.daily_idle_gold + p_idle_gold
    where profile_id = auth.uid()
    returning player_combat.daily_dmg_dealt, player_combat.daily_dmg_taken, player_combat.daily_kills,
              player_combat.daily_deaths, player_combat.daily_idle_xp, player_combat.daily_idle_gold,
              player_combat.daily_reset_at;
end;
$$;

-- ----------------------------------------------------------------------------
-- Affixes (enemy-side) and debuffs (player-side): named modifier bundles a
-- fight can roll on top of base stats. Both share the same modifier key
-- vocabulary that compute_damage() understands (attack_pct, attack_flat,
-- defense_pct, damage_pct, damage_reduction_pct, crit_chance_flat, plus
-- hp_pct applied separately at spawn time since hp isn't part of a single
-- damage roll) — adding a new one later, or a gear affix down the line, is
-- just another row with a mods bundle built from that same vocabulary;
-- nothing about compute_damage or the combat loop has to change for it.
-- ----------------------------------------------------------------------------

create table if not exists affix_defs (
  key          text primary key,
  name         text not null,
  description  text not null,
  mods         jsonb not null default '{}'::jsonb
);

create table if not exists debuff_defs (
  key          text primary key,
  name         text not null,
  description  text not null,
  mods         jsonb not null default '{}'::jsonb
);

-- Per-class starting bonuses (see §"Starting class bonuses" seed data near
-- the bottom of this file for the actual numbers/rationale). Same
-- key/name/description/mods shape as affix_defs/debuff_defs on purpose —
-- these are just another modifier-bundle source merged into player_mods in
-- strike_enemy() below, keyed off profiles.class instead of an active
-- affix/debuff roll.
create table if not exists class_defs (
  key          text primary key,
  name         text not null,
  description  text not null,
  mods         jsonb not null default '{}'::jsonb
);

create table if not exists chat_messages (
  id          bigint generated always as identity primary key,
  channel     text not null,          -- 'global' or 'guild:<guild-uuid>'
  sender_id   uuid not null references profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index if not exists idx_chat_channel_time on chat_messages(channel, created_at desc);

create table if not exists whispers (
  id            bigint generated always as identity primary key,
  sender_id     uuid not null references profiles(id) on delete cascade,
  recipient_id  uuid not null references profiles(id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 500),
  created_at    timestamptz not null default now(),
  read_at       timestamptz
);
create index if not exists idx_whispers_recipient on whispers(recipient_id, created_at desc);

create table if not exists item_transfers (
  id             bigint generated always as identity primary key,
  sender_id      uuid not null references profiles(id) on delete cascade,
  recipient_id   uuid not null references profiles(id) on delete cascade,
  item_id        uuid references items(id),
  quantity       int,
  gold_amount    bigint,
  created_at     timestamptz not null default now(),
  check (
    (item_id is not null and quantity is not null and gold_amount is null)
    or
    (item_id is null and quantity is null and gold_amount is not null)
  )
);
create index if not exists idx_transfers_sender_time on item_transfers(sender_id, created_at desc);

-- for a project that already ran this file before these referenced
-- "on delete cascade": without it, deleting a profile that ever led a guild
-- or sent/received a /send transfer fails with a foreign key violation —
-- Supabase's Auth admin surfaces that as the unhelpful "Database error
-- deleting user". Re-pointing the constraints at ON DELETE CASCADE fixes
-- deletion for both old and new projects; safe to re-run.
alter table guilds drop constraint if exists guilds_leader_id_fkey;
alter table guilds add constraint guilds_leader_id_fkey
  foreign key (leader_id) references profiles(id) on delete cascade;

alter table item_transfers drop constraint if exists item_transfers_sender_id_fkey;
alter table item_transfers add constraint item_transfers_sender_id_fkey
  foreign key (sender_id) references profiles(id) on delete cascade;

alter table item_transfers drop constraint if exists item_transfers_recipient_id_fkey;
alter table item_transfers add constraint item_transfers_recipient_id_fkey
  foreign key (recipient_id) references profiles(id) on delete cascade;

-- ----------------------------------------------------------------------------
-- 2. Row Level Security
--    Everything a player is allowed to READ is broadly public (this is a
--    small shared-world game — usernames, guild rosters, chat, leaderboards
--    are all meant to be visible). Every WRITE goes through a
--    SECURITY DEFINER function below instead of a table policy, so game
--    rules (caps, cooldowns, validation) live in one place. That's why you
--    won't see INSERT/UPDATE policies for normal users on most tables.
-- ----------------------------------------------------------------------------

alter table profiles enable row level security;
alter table guilds enable row level security;
alter table guild_members enable row level security;
alter table guild_bosses enable row level security;
alter table guild_boss_damage_log enable row level security;
alter table guild_requests enable row level security;
alter table items enable row level security;
alter table inventory enable row level security;
alter table enemies enable row level security;
alter table player_combat enable row level security;
alter table chat_messages enable row level security;
alter table whispers enable row level security;
alter table item_transfers enable row level security;

-- each policy is dropped first so this whole file can be re-run safely
-- (unlike create table/index/function, "create policy" has no
-- "if not exists" / "or replace" form in Postgres)

drop policy if exists "profiles are publicly readable" on profiles;
create policy "profiles are publicly readable" on profiles for select using (true);

drop policy if exists "guilds are publicly readable" on guilds;
create policy "guilds are publicly readable" on guilds for select using (true);

drop policy if exists "guild rosters are publicly readable" on guild_members;
create policy "guild rosters are publicly readable" on guild_members for select using (true);

drop policy if exists "guild bosses are publicly readable" on guild_bosses;
create policy "guild bosses are publicly readable" on guild_bosses for select using (true);

drop policy if exists "boss damage log is publicly readable" on guild_boss_damage_log;
create policy "boss damage log is publicly readable" on guild_boss_damage_log for select using (true);

-- guild_requests is NOT public — visible only to the requester themselves,
-- or to the leader/officer of the guild the request is against (so they can
-- see incoming applications/manage outgoing invites in the Recruitment
-- panel). All writes go through the SECURITY DEFINER functions below.
drop policy if exists "guild requests are visible to the requester or guild management" on guild_requests;
create policy "guild requests are visible to the requester or guild management" on guild_requests
  for select using (
    profile_id = auth.uid()
    or exists (
      select 1 from guild_members gm
      where gm.guild_id = guild_requests.guild_id
        and gm.profile_id = auth.uid()
        and gm.role in ('leader', 'officer')
    )
  );

drop policy if exists "item catalog is publicly readable" on items;
create policy "item catalog is publicly readable" on items for select using (true);

drop policy if exists "players see only their own inventory" on inventory;
create policy "players see only their own inventory" on inventory
  for select using (profile_id = auth.uid());

drop policy if exists "enemy catalog is publicly readable" on enemies;
create policy "enemy catalog is publicly readable" on enemies for select using (true);

drop policy if exists "players see only their own combat state" on player_combat;
create policy "players see only their own combat state" on player_combat
  for select using (profile_id = auth.uid());

alter table affix_defs enable row level security;
drop policy if exists "affix catalog is publicly readable" on affix_defs;
create policy "affix catalog is publicly readable" on affix_defs for select using (true);

alter table debuff_defs enable row level security;
drop policy if exists "debuff catalog is publicly readable" on debuff_defs;
create policy "debuff catalog is publicly readable" on debuff_defs for select using (true);

alter table class_defs enable row level security;
drop policy if exists "class catalog is publicly readable" on class_defs;
create policy "class catalog is publicly readable" on class_defs for select using (true);

drop policy if exists "global chat is publicly readable" on chat_messages;
create policy "global chat is publicly readable" on chat_messages
  for select using (
    channel = 'global'
    or exists (
      select 1 from guild_members gm
      where gm.profile_id = auth.uid()
        and channel = 'guild:' || gm.guild_id::text
    )
  );

drop policy if exists "whispers are readable by sender or recipient" on whispers;
create policy "whispers are readable by sender or recipient" on whispers
  for select using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists "transfers are readable by sender or recipient" on item_transfers;
create policy "transfers are readable by sender or recipient" on item_transfers
  for select using (sender_id = auth.uid() or recipient_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 2a. Password recovery (security question) storage
--    Players never give an email (see §3 below), so Supabase's normal
--    "email a reset link" flow is unusable here — this is the only
--    self-service password recovery this game has. Deliberately its own
--    table, NOT columns on profiles: profiles has a public-read RLS policy
--    ("profiles are publicly readable" above), and RLS can't restrict
--    individual columns — a security-answer hash living on profiles would
--    be readable by anyone, hash and all, which defeats the point. This
--    table instead has RLS enabled with ZERO policies, so nothing (not
--    even a logged-in player reading their own row) can select, insert, or
--    update it directly — the only access is through the two
--    SECURITY DEFINER functions below, which run as the table owner and
--    bypass RLS entirely. The explicit revoke below is belt-and-suspenders
--    on top of that, undoing Supabase's own default privilege grants (new
--    tables are auto-granted select/insert/update/delete for anon and
--    authenticated unless revoked) so this table has no path in at all
--    except through those two functions.
-- ----------------------------------------------------------------------------

create table if not exists account_recovery (
  profile_id       uuid primary key references profiles(id) on delete cascade,
  question         text not null check (char_length(question) between 1 and 200),
  answer_hash      text not null,
  failed_attempts  int not null default 0,
  locked_until     timestamptz,
  updated_at       timestamptz not null default now()
);

alter table account_recovery enable row level security;
-- (no policies on purpose — see comment above)
revoke all on account_recovery from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. New-user signup -> profile row
--    Client passes the chosen username in auth signUp's options.data.username.
--    Players never enter an email: the client (web/js/app.js) derives one
--    from the username ("name@banished-abyss.invalid") so Supabase's normal
--    email/password auth can be used under the hood. This REQUIRES turning
--    off "Confirm email" in Authentication -> Settings, since no
--    confirmation link could ever reach a .invalid address.
--
--    The client can also optionally send security_question/security_answer
--    in the same options.data payload (both or neither — see
--    web/js/app.js's signup handler). When present, the answer is hashed
--    with pgcrypto's bcrypt (crypt()/gen_salt('bf')) before it's ever
--    written anywhere — see §2a above for why the raw pair never touches
--    profiles.
-- ----------------------------------------------------------------------------

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
-- "extensions" (not just "public") because Supabase installs pgcrypto
-- there by default, not into public -- crypt()/gen_salt() below are
-- unqualified, so without extensions on the search_path this trigger
-- throws "function crypt(text, text) does not exist" on every signup that
-- sets a security question, which GoTrue surfaces to the client as the
-- generic "Database error saving new user".
set search_path = public, extensions
as $$
declare
  chosen_class text;
  sec_question text;
  sec_answer text;
begin
  chosen_class := new.raw_user_meta_data->>'class';
  if chosen_class is null or chosen_class not in ('warrior','archer','magi','striker') then
    chosen_class := 'warrior'; -- defensive fallback; the client always sends a valid choice
  end if;

  insert into public.profiles (id, username, class)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', 'wanderer_' || substr(new.id::text, 1, 8)),
    chosen_class
  );

  sec_question := nullif(trim(new.raw_user_meta_data->>'security_question'), '');
  sec_answer := nullif(trim(new.raw_user_meta_data->>'security_answer'), '');
  if sec_question is not null and sec_answer is not null then
    insert into public.account_recovery (profile_id, question, answer_hash)
    values (new.id, sec_question, crypt(lower(sec_answer), gen_salt('bf')));
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ----------------------------------------------------------------------------
-- 3a. Password recovery RPCs
--    Both are called while SIGNED OUT (no auth.uid()), so both take the
--    username explicitly rather than relying on the session — that's what
--    makes this "recovery" rather than a normal authenticated settings
--    change. Answers are matched case-insensitively (lower()'d on both
--    write and read) so "Blue"/"blue"/"BLUE" all work, same spirit as
--    username's case-insensitive uniqueness elsewhere in this file.
--
--    Brute-force guard: 5 wrong answers locks that character's recovery
--    for 15 minutes (both TUNE). This only ever throttles guessing the
--    ANSWER for an account that already has a question set — it's not a
--    login rate limit and doesn't touch auth.users, so it can't be used to
--    lock a player out of signing in normally.
--
--    Both functions return/raise the same generic wording regardless of
--    *why* they failed (no such username, no question set, wrong answer)
--    so a failed attempt can't be used to probe which usernames exist or
--    which have recovery configured.
-- ----------------------------------------------------------------------------

create or replace function get_security_question(p_username text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  result text;
begin
  select ar.question into result
  from account_recovery ar
  join profiles p on p.id = ar.profile_id
  where lower(p.username) = lower(p_username);
  return result; -- null if no such username, or that username has no question set
end;
$$;

create or replace function reset_password_with_security_answer(
  p_username text, p_answer text, p_new_password text
)
returns boolean
language plpgsql
security definer
-- see handle_new_user()'s comment above on why this needs "extensions" too
set search_path = public, extensions
as $$
declare
  target_id uuid;
  rec account_recovery%rowtype;
  max_attempts int := 5;      -- TUNE
  lockout interval := interval '15 minutes'; -- TUNE
  generic_error text := 'incorrect character name or answer';
begin
  if p_new_password is null or char_length(p_new_password) < 6 then
    raise exception 'new password must be at least 6 characters';
  end if;

  select p.id into target_id from profiles p where lower(p.username) = lower(p_username);
  if target_id is null then
    raise exception '%', generic_error;
  end if;

  select * into rec from account_recovery where profile_id = target_id for update;
  if not found then
    raise exception '%', generic_error;
  end if;

  if rec.locked_until is not null and rec.locked_until > now() then
    raise exception 'too many attempts — try again after %', to_char(rec.locked_until, 'HH12:MI AM');
  end if;

  if rec.answer_hash <> crypt(lower(trim(p_answer)), rec.answer_hash) then
    -- RETURN false here rather than raise an exception: an exception
    -- unwinds to the caller's savepoint and would silently roll back the
    -- failed_attempts bump below along with it (Postgres undoes
    -- everything since the savepoint, not just the statement that
    -- raised) — so the lockout counter would never actually persist.
    -- Returning false instead lets this UPDATE commit as part of the
    -- function's normal (non-erroring) completion. The client already
    -- treats a false return as "incorrect answer" (see web/js/app.js),
    -- so the player sees the same generic message either way.
    update account_recovery
      set failed_attempts = failed_attempts + 1,
          locked_until = case when failed_attempts + 1 >= max_attempts then now() + lockout else locked_until end,
          updated_at = now()
      where profile_id = target_id;
    return false;
  end if;

  -- correct answer: set the new password directly on auth.users the same
  -- way Supabase Auth (GoTrue) itself does — encrypted_password is a plain
  -- bcrypt hash, and pgcrypto's crypt()/gen_salt('bf') produces the exact
  -- same format. This function runs as the table owner (security definer),
  -- which is what makes writing to the auth schema possible at all here.
  update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')),
        updated_at = now()
    where id = target_id;

  update account_recovery
    set failed_attempts = 0, locked_until = null, updated_at = now()
    where profile_id = target_id;

  -- force re-login everywhere: a stolen/guessed answer shouldn't just get
  -- a new password while leaving the real owner's (or an attacker's)
  -- existing sessions alive. Guarded on the table existing since the local
  -- test rig's auth stub doesn't have it — real Supabase always does.
  if to_regclass('auth.sessions') is not null then
    delete from auth.sessions where user_id = target_id;
  end if;

  return true;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Idle tick resolution
--    Called by the client whenever it's convenient (page load, every few
--    minutes while open, etc). Grants XP/gold for elapsed real time since
--    last_tick_at, capped so offline time can't be farmed indefinitely, then
--    feeds a slice of that XP to the player's guild boss as passive damage.
--    Tune the constants marked TUNE once you have something playable.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 4b. Action points
--    Every character starts at 3000/3000. Spent by strike_enemy() (1 per
--    fight-tick while online) and, since perform_idle_tick() grew offline
--    combat simulation above, by offline catch-up too -- both draw from the
--    same profiles.actions pool. refresh_actions() below is the manual
--    "refresh" the player clicks to top back up to max_actions. There's
--    deliberately no cooldown on refresh_actions(): actions themselves are
--    the throttle (a full pool still only buys so many fight-ticks), so
--    gating the refresh button on top wouldn't add a real limit, just
--    friction.
-- ----------------------------------------------------------------------------

create or replace function refresh_actions()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  new_actions int;
begin
  update profiles
    set actions = max_actions
    where id = auth.uid()
    returning actions into new_actions;

  if not found then
    raise exception 'no profile for current user';
  end if;

  return new_actions;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4c. Pack combat
--    The player fights a PACK of 1-30 enemies at once (player-selected via
--    the difficulty fields / set_encounter_settings), tracked in
--    player_combat.pack. get_or_spawn_pack() creates/respawns the pack;
--    strike_enemy() is called automatically once per client idle-tick
--    (every 8s, see app.js doTick()) rather than from a manual button.
--
--    Action cost is flat: one fight-tick = 1 action, full stop — however
--    many rounds that takes doesn't change the cost. What DOES scale with
--    rounds is how much punishment a single action buys you: each fight
--    resolves a whole round-robin exchange (hard capped so one DB call
--    can't run unbounded work), and how many rounds run is driven by the
--    player's Attack Speed stat — attack_speed 1.0 (the default) resolves
--    10 rounds; a faster attacker gets more swings for the same action.
--
--    DAMAGE FORMULA (see compute_damage() below): attack and defense are
--    combined via a scale-invariant mitigation ratio — defense/(defense +
--    attack) — instead of flat subtraction. That ratio only depends on the
--    two combatants' relative power, never their absolute size, so raw
--    stats can climb indefinitely (via Banishment retention, gear, and
--    later prestige systems) without damage ever exploding into absurd
--    numbers OR collapsing to the 1-damage floor — which is what "scale
--    slowly forever without number bloat" requires. Modifiers (from
--    affixes, debuffs, and eventually gear) are named percentage/flat
--    bundles merged via sum_mods() and read by compute_damage() through a
--    small fixed vocabulary of keys (attack_pct, attack_flat, defense_pct,
--    damage_pct, damage_reduction_pct, crit_chance_flat, plus hp_pct
--    applied separately at spawn) — adding a new affix or gear stat later
--    is just another row with a mods bundle from that vocabulary; nothing
--    about the combat loop itself has to change.
--
--    BANISHMENT SCALING: enemy power also scales automatically with the
--    player's own Banishment count (profiles.depth — there's no separate
--    "bracket" dial to choose anymore, just the one real Banishments
--    number), a flat +5% per Banishment (depth_mult in
--    enemy_effective_stats(), TUNE) applied on top of tier/variance. Linear
--    rather than the old dial's sqrt ramp, and deliberately gentle since
--    it's no longer an opt-in risk a player can decline — every fight gets
--    slightly harder, forever, the more you've Banished, matching xp/gold
--    reward scaling right alongside it (enemy_effective_stats() applies the
--    same multiplier to eff_xp/eff_gold as it does to eff_attack/eff_hp).
--    Number of Enemy Affixes, Number of Enemies Spawned, and Player
--    Debuffs are the remaining player-chosen knobs that make a fight
--    harder in their own way (see strike_enemy) and feed
--    selection_reward_mult(), so choosing to stack any of those is
--    rewarded proportionally to how much harder it actually made the
--    fight — not a flat bonus. Every enemy spawn additionally rolls its
--    own 0.85-1.25x power variance (roll_pack), independent of all of the
--    above.
--
--    Elite/Champion tiers: every enemy spawn rolls normal/elite/champion at
--    85%/10%/5% via roll_enemy_tier() on top of all the above scaling —
--    tougher, and worth more xp/gold, so a lucky Champion spawn actually
--    feels different. This is entirely separate from perform_idle_tick()'s
--    passive xp/gold, which is time-based and keeps accruing offline
--    regardless of actions — only this auto-strike loop is action-gated.
--
--    SPEED (initiative + evasion): the one standard stat from DESIGN.md
--    §3a that wasn't wired into combat until now. Every round, whichever
--    side has the higher effective Speed swings FIRST that round — the
--    player's own (Speed stat + speed_pct mods) vs. the pack's average
--    Speed among currently-alive members, recomputed every round since a
--    thinning pack's average can shift as its faster/slower members die.
--    Ties go to the player. Separately, Speed also grants the player a
--    flat, hard-capped-at-25% evasion chance (1 Speed = 1 percentage point
--    + evasion_flat mods) checked per incoming enemy hit, in
--    pack_counterattack() — a dodge skips the damage roll entirely rather
--    than rolling and zeroing it, so it stays distinguishable in the log.
--    Enemies never get evasion or an initiative stat of their own beyond
--    their rolled Speed value (used only for the pack's side of the
--    initiative comparison) — this is a player-facing stat for now.
--
--    WIN/LOSS: xp and gold are only ever granted when a pack is fully
--    cleared (event = 'kill') — never on a player death. Every individual
--    enemy killed (not just the one that empties the pack) also heals the
--    player 25% of their (fight-effective) max HP, applied the instant
--    that kill lands, whether it's the player's primary swing or a Multi
--    Strike bonus swing. A death fully heals the player and respawns a
--    fresh pack (same selections), same as before, but grants nothing.
--
--    Every individual pack (one player vs. 1-30 spawned enemies) always
--    runs to a real conclusion — a clear or a player death — rather than
--    being cut off partway through by the tick's round budget. That budget
--    decides how many NEW packs get started this tick, but once a pack is
--    underway it's always allowed to finish, so the round count can run a
--    little over budget for the last one. A hard, unconditional ceiling
--    (rounds_hard_cap) still bounds the absolute worst case so this
--    function can never hang.
-- ----------------------------------------------------------------------------

-- exactly 5% champion, 10% elite, 85% normal — a single random() draw
-- compared against both thresholds, NOT two independent draws (which would
-- skew the real odds: elite would land ~14% instead of 10%).
create or replace function roll_enemy_tier()
returns text
language plpgsql
as $$
declare
  v numeric := random();
begin
  if v < 0.05 then
    return 'champion';
  elsif v < 0.15 then
    return 'elite';
  else
    return 'normal';
  end if;
end;
$$;

-- shared by roll_pack() and get_or_spawn_pack() so the tier/bracket/variance
-- multiplier math lives in exactly one place. Not itself exposed as a
-- player action, but callable like any function (it's read-only/stable, so
-- that's harmless).
--
-- Postgres can't CREATE OR REPLACE a function onto a different parameter
-- list — a project that already ran an earlier version of this file needs
-- the old 2-arg version dropped first, or this fails with "cannot change
-- name of input parameter" / ambiguity between the two signatures. Safe
-- no-op on a project that's never defined it.
drop function if exists enemy_effective_stats(text, text);
-- same reasoning, this time for the current 4-arg signature: adding
-- eff_speed below changes the RETURNS TABLE column list, which CREATE OR
-- REPLACE can't do in place.
drop function if exists enemy_effective_stats(text, text, int, numeric);

create or replace function enemy_effective_stats(
  p_enemy_key text,
  p_tier text,
  p_bracket int default 0,      -- profiles.depth at spawn time (how many times the player has Banished)
  p_variance numeric default 1.0 -- per-spawn power roll, see roll_pack (0.85-1.25)
)
returns table (
  display_name text,
  eff_max_hp int,
  eff_attack int,
  eff_defense int,
  eff_xp int,
  eff_gold int,
  eff_speed int
)
language plpgsql
stable
set search_path = public
as $$
declare
  e enemies%rowtype;
  tier_mult numeric;
  depth_mult numeric;
  total_mult numeric;
  prefix text;
begin
  select * into e from enemies where key = p_enemy_key;
  if not found then raise exception 'no such enemy'; end if;

  tier_mult := case p_tier when 'champion' then 1.5 when 'elite' then 1.25 else 1.0 end; -- TUNE

  -- Flat, linear ramp: +5% per Banishment, forever, no diminishing or
  -- accelerating curve. This used to be a sqrt ramp over a player-chosen
  -- "how far above my own progress do I dare push it" dial (an opt-in
  -- risk); now that it's automatic and unconditional (every Banishment
  -- makes every fight harder, whether the player wants that or not that
  -- run), a gentle flat rate fits the game's "infinite slow scaling"
  -- design far better than either the old sqrt curve or a compounding
  -- (exponential) one — 5% per Banishment reaches +100% (double) around
  -- Banishment 20 and keeps climbing at the same steady pace forever
  -- after, rather than the runaway growth a compounding rate would hit by
  -- then. Same multiplier applies to eff_xp/eff_gold below, so reward
  -- keeps pace with difficulty automatically. TUNE the 0.05 coefficient
  -- once playtested.
  depth_mult := 1 + greatest(0, p_bracket) * 0.05;

  total_mult := tier_mult * depth_mult * greatest(0.01, p_variance);
  prefix := case p_tier when 'champion' then 'Champion ' when 'elite' then 'Elite ' else '' end;

  return query select
    prefix || e.name,
    greatest(1, ceil(e.max_hp * total_mult))::int,
    greatest(1, ceil(e.attack * total_mult))::int,
    greatest(0, ceil(e.defense * total_mult))::int,
    greatest(0, ceil(e.xp_reward * total_mult))::int,
    greatest(0, ceil(e.gold_reward * total_mult))::int,
    greatest(1, ceil(e.speed * total_mult))::int;
end;
$$;

-- ----------------------------------------------------------------------------
-- Combat math primitives — shared by every damage roll in the game (player
-- hitting an enemy, an enemy hitting the player), so the formula and the
-- modifier-stacking rules live in exactly one place. See the 4c banner
-- comment above for the design rationale.
-- ----------------------------------------------------------------------------

-- Reads one named value out of a modifier bundle, e.g. mod_val(mods,
-- 'attack_pct'). default_val (usually 0) is what a bundle that simply
-- doesn't mention that key resolves to — this is what lets new modifier
-- keys get added later without touching every existing bundle.
create or replace function mod_val(mods jsonb, key text, default_val numeric default 0)
returns numeric
language sql
immutable
as $$
  select coalesce((mods->>key)::numeric, default_val);
$$;

-- Merges any number of modifier bundles (e.g. one per active affix or
-- debuff) into one, summing matching keys — two +15% attack affixes give
-- +30%, not two separate entries. Takes a jsonb ARRAY of bundle objects,
-- e.g. '[{"attack_pct":15},{"attack_pct":15,"defense_pct":-10}]'.
create or replace function sum_mods(bundles jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(b.key, b.total), '{}'::jsonb)
  from (
    select each.key, sum(each.value::numeric) as total
    from jsonb_array_elements(coalesce(bundles, '[]'::jsonb)) as bundle
    cross join lateral jsonb_each_text(bundle) as each(key, value)
    group by each.key
  ) b;
$$;

-- The single damage-roll formula for the whole game. p_atk_mods applies to
-- the attacker (attack_pct/attack_flat/damage_pct/crit_chance_flat),
-- p_def_mods to the defender (defense_pct/damage_reduction_pct) — pass
-- '{}'::jsonb for either side with nothing active.
--
-- Mitigation is defense/(defense+attack): a RATIO of the two combatants'
-- own (modified) stats, not a fixed subtraction or an externally-tuned
-- constant. That's what makes it scale-invariant — the same formula stays
-- balanced whether both stats are in the single digits or the millions,
-- which is the whole trick for "infinite slow scaling without number
-- bloat". Damage always floors at 1 so a fight can never literally stall.
-- adding p_crit_damage below changes this function's argument signature, not
-- just its body -- CREATE OR REPLACE can't "replace" that in place (it would
-- instead create a second overload alongside the old 5-arg one, and any
-- existing 5-arg call site would then be ambiguous between the two), so the
-- old signature has to be dropped explicitly first.
drop function if exists compute_damage(numeric, numeric, numeric, jsonb, jsonb);

create or replace function compute_damage(
  p_attack numeric,
  p_crit_chance numeric,    -- base crit %, before crit_chance_flat mods
  p_defense numeric,
  p_atk_mods jsonb default '{}'::jsonb,
  p_def_mods jsonb default '{}'::jsonb,
  p_crit_damage numeric default 100  -- base bonus crit dmg %, before crit_damage_flat mods
)
returns table (dmg int, was_crit boolean)
language plpgsql
as $$
declare
  eff_attack numeric;
  eff_defense numeric;
  mitigation numeric;
  eff_dmg numeric;
  crit boolean;
  crit_mult numeric;
begin
  eff_attack := greatest(0,
    p_attack * (1 + mod_val(p_atk_mods, 'attack_pct') / 100.0) + mod_val(p_atk_mods, 'attack_flat')
  );
  eff_defense := greatest(0, p_defense * (1 + mod_val(p_def_mods, 'defense_pct') / 100.0));

  mitigation := coalesce(eff_defense / nullif(eff_defense + eff_attack, 0), 0);

  eff_dmg := eff_attack * (1 - mitigation)
    * (1 + mod_val(p_atk_mods, 'damage_pct') / 100.0 - mod_val(p_def_mods, 'damage_reduction_pct') / 100.0);

  crit := random() * 100 < greatest(0, p_crit_chance + mod_val(p_atk_mods, 'crit_chance_flat'));
  if crit then
    -- crit_mult is a total multiplier (1.0 = no bonus); floored at 1.0 so a
    -- crit can never deal LESS than a normal hit even if crit_damage_flat
    -- mods somehow drove the bonus negative.
    crit_mult := 1 + greatest(0, p_crit_damage + mod_val(p_atk_mods, 'crit_damage_flat')) / 100.0;
    eff_dmg := eff_dmg * crit_mult;
  end if;

  return query select greatest(1, round(eff_dmg)::int), crit;
end;
$$;

-- Applies an hp_pct modifier (from affixes, e.g. "Resilient: +50% enemy hp")
-- uniformly across every member of a freshly-rolled pack. Kept separate
-- from roll_pack() so respawning a cleared pack mid-strike_enemy() doesn't
-- need to re-roll or re-look-up which affixes are active — the caller
-- already has that mod value on hand.
create or replace function apply_hp_mod(p_pack jsonb, p_hp_pct numeric)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(
    e || jsonb_build_object(
      'hp', greatest(1, round((e->>'hp')::numeric * (1 + p_hp_pct / 100.0)))::int,
      'max_hp', greatest(1, round((e->>'max_hp')::numeric * (1 + p_hp_pct / 100.0)))::int
    )
  ), '[]'::jsonb)
  from jsonb_array_elements(p_pack) e;
$$;

-- Rolls a fresh pack of p_size enemies (tier + bracket + the 0.85-1.25x
-- per-spawn power variance) — hp_pct affix scaling is applied afterward by
-- the caller via apply_hp_mod, not here, so this stays affix-agnostic.
-- Postgres can't CREATE OR REPLACE a function onto a different parameter
-- list -- a project that already ran an earlier version of this file needs
-- the old 3-arg (enemy_key, size, bracket) signature dropped first. Safe
-- no-op on a project that's never defined it.
drop function if exists roll_pack(text, int, int);

create or replace function roll_pack(p_size int, p_bracket int)
returns jsonb
language plpgsql
as $$
declare
  result jsonb := '[]'::jsonb;
  i int;
  tier text;
  variance numeric;
  stats record;
  member_enemy_key text;
begin
  for i in 1..greatest(1, p_size) loop
    -- A fresh, independent roll PER PACK MEMBER, not once for the whole
    -- pack -- this is what makes a single fight mix species instead of
    -- always spawning a uniform pack of one kind. min_depth gates which
    -- enemies are even eligible at the player's current Banishment depth;
    -- among those, every eligible enemy is equally likely (no rarity
    -- weighting yet -- TUNE if some should feel rarer than others later).
    select key into member_enemy_key from enemies
      where min_depth <= p_bracket order by random() limit 1;
    -- Defensive fallback: should never actually fire (test_rat's min_depth
    -- 0 row always qualifies), but guarantees this can never come back null
    -- if the enemies table is ever misconfigured mid-tune.
    if member_enemy_key is null then
      member_enemy_key := 'test_rat';
    end if;

    tier := roll_enemy_tier();
    variance := 0.85 + random() * 0.40; -- TUNE: spawn power range
    select * into stats from enemy_effective_stats(member_enemy_key, tier, p_bracket, variance);
    result := result || jsonb_build_array(jsonb_build_object(
      'enemy_key', member_enemy_key,
      'name', stats.display_name,
      'tier', tier,
      'hp', stats.eff_max_hp,
      'max_hp', stats.eff_max_hp,
      'attack', stats.eff_attack,
      'defense', stats.eff_defense,
      'xp', stats.eff_xp,
      'gold', stats.eff_gold,
      'speed', stats.eff_speed
    ));
  end loop;
  return result;
end;
$$;

-- Resolves every still-alive pack member's counter-swing against the player
-- in one pass, rolling the player's Speed-derived evasion chance (see
-- cur_player_evasion_pct in strike_enemy) per hit before compute_damage
-- ever runs — a dodge skips the damage roll entirely rather than rolling it
-- and zeroing it out, so a dodge and a 0-damage hit stay distinguishable in
-- the log ('dodged' vs 'dmg':0). Returns the total hp delta (always <= 0)
-- rather than mutating anything itself, so the caller decides when/whether
-- to clamp at 0 and check for a death — this is what strike_enemy calls
-- from BOTH initiative orderings (enemies-first when out-sped, or the
-- original player-then-pack order otherwise) instead of that ~20-line loop
-- needing to be written out twice.
create or replace function pack_counterattack(
  p_pack jsonb,
  p_player_defense numeric,
  p_enemy_mods jsonb,
  p_player_mods jsonb,
  p_evasion_pct numeric
)
returns table (new_player_hp_delta int, hits jsonb)
language plpgsql
as $$
declare
  member jsonb;
  i int;
  hit record;
  total_delta int := 0;
  round_hits jsonb := '[]'::jsonb;
begin
  for i in 0 .. jsonb_array_length(p_pack) - 1 loop
    member := p_pack -> i;
    if (member->>'hp')::int > 0 then
      if random() * 100 < greatest(0, p_evasion_pct) then
        round_hits := round_hits || jsonb_build_array(jsonb_build_object(
          'source', 'enemy', 'source_slot', i, 'dmg', 0, 'crit', false, 'dodged', true
        ));
      else
        select * into hit from compute_damage((member->>'attack')::numeric, 0, p_player_defense, p_enemy_mods, p_player_mods);
        total_delta := total_delta - hit.dmg;
        round_hits := round_hits || jsonb_build_array(jsonb_build_object(
          'source', 'enemy', 'source_slot', i, 'dmg', hit.dmg, 'crit', hit.was_crit, 'dodged', false
        ));
      end if;
    end if;
  end loop;
  return query select total_delta, round_hits;
end;
$$;

-- Postgres can't CREATE OR REPLACE a function with a shorter parameter list
-- — a project that already ran the old 4-arg (with p_bracket) version needs
-- it dropped first. Safe no-op on a project that's never defined it.
drop function if exists selection_reward_mult(int, int, int, int);

-- How much extra a cleared pack is worth for having been made harder via
-- the selection fields — additive per knob, so the bonus is always
-- proportional to how much harder that knob actually made the fight (pack
-- size = more incoming hits per round, affixes = tougher/harder-hitting
-- enemies, debuffs = a weaker player). TUNE each coefficient once
-- playtested. No longer includes a Banishment-bracket term — Banishment
-- difficulty scaling is automatic now (see enemy_effective_stats'
-- depth_mult), not a player choice, so it doesn't get an opt-in reward
-- bonus on top; its reward already scales via eff_xp/eff_gold directly.
create or replace function selection_reward_mult(p_pack_size int, p_affix_count int, p_debuff_count int)
returns numeric
language sql
immutable
as $$
  select 1
    + (greatest(0, p_pack_size - 1) * 0.12)
    + (p_affix_count * 0.15)
    + (p_debuff_count * 0.20);
$$;

-- Postgres can't CREATE OR REPLACE a function onto a different return
-- signature — a project that already ran an earlier version of this file
-- needs the old one dropped first. Safe no-op on a project that's never
-- defined it.
drop function if exists get_or_spawn_player_enemy(text);

-- (Re)spawns the player's pack if there isn't one yet, or the current one
-- has been fully cleared already (every member's hp <= 0 — strike_enemy
-- normally leaves a live pack behind after any clear/death, so in practice
-- this only really fires for a brand-new player or right after
-- set_encounter_settings deliberately clears the row; a mid-fight
-- clear/death respawn is handled entirely inside strike_enemy() itself,
-- which rolls its own fresh affix/debuff set the same way this function
-- does — see new_affix_keys/new_debuff_keys there — so this function never
-- even runs for that far more common case). Rolls a fresh set of
-- affixes/debuffs from the player's current sel_* choices and snapshots
-- them onto player_combat so they stay fixed for this pack's lifetime.
-- bracket_used (both here and on player_combat itself) now records the
-- player's Banishment count (profiles.depth) at spawn time rather than a
-- player-chosen bracket -- kept under its original column/field name to
-- avoid an unnecessary migration, but it's purely informational now
-- (enemy_effective_stats reads depth fresh off profiles every time it's
-- actually needed, not from this snapshot).
--
-- No longer takes an enemy key: there's exactly one ongoing fight, and
-- WHICH mobs turn up in it is now rolled per pack member inside roll_pack()
-- itself (see there) rather than chosen by the caller, so a "the player
-- switched enemies" reason to respawn no longer exists -- the respawn guard
-- below is back down to just "no pack yet, or it's fully cleared."
--
-- Postgres can't CREATE OR REPLACE a function onto a different parameter
-- list -- a project that already ran the old 1-arg (p_enemy_key) version
-- needs it dropped first. Safe no-op on a project that's never defined it.
drop function if exists get_or_spawn_pack(text);

create or replace function get_or_spawn_pack()
returns table (
  pack jsonb,
  affix_keys jsonb,
  affix_names jsonb,
  debuff_keys jsonb,
  debuff_names jsonb,
  bracket_used int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  pc player_combat%rowtype;
  new_pack jsonb;
  new_affix_keys jsonb;
  new_debuff_keys jsonb;
  hp_pct numeric;
begin
  select * into p from profiles where id = auth.uid();
  if not found then raise exception 'no profile'; end if;

  select * into pc from player_combat where profile_id = auth.uid();

  if not found
     or not exists (select 1 from jsonb_array_elements(pc.pack) e where (e->>'hp')::int > 0)
  then
    select coalesce(jsonb_agg(key), '[]'::jsonb) into new_affix_keys
      from (select key from affix_defs order by random() limit greatest(0, p.sel_affix_count)) s;
    select coalesce(jsonb_agg(key), '[]'::jsonb) into new_debuff_keys
      from (select key from debuff_defs order by random() limit greatest(0, p.sel_debuff_count)) s;

    select coalesce(sum(mod_val(mods, 'hp_pct')), 0) into hp_pct
      from affix_defs where key in (select jsonb_array_elements_text(new_affix_keys));

    new_pack := apply_hp_mod(roll_pack(p.sel_pack_size, p.depth), hp_pct);

    insert into player_combat (profile_id, pack, affix_keys, debuff_keys, bracket_used, updated_at)
      values (auth.uid(), new_pack, new_affix_keys, new_debuff_keys, p.depth, now())
    on conflict (profile_id) do update set
      pack = excluded.pack,
      affix_keys = excluded.affix_keys,
      debuff_keys = excluded.debuff_keys,
      bracket_used = excluded.bracket_used,
      updated_at = now()
    returning * into pc;
  end if;

  return query select
    pc.pack,
    pc.affix_keys,
    (select coalesce(jsonb_agg(name), '[]'::jsonb) from affix_defs where key in (select jsonb_array_elements_text(pc.affix_keys))),
    pc.debuff_keys,
    (select coalesce(jsonb_agg(name), '[]'::jsonb) from debuff_defs where key in (select jsonb_array_elements_text(pc.debuff_keys))),
    pc.bracket_used;
end;
$$;

-- Postgres can't CREATE OR REPLACE a function with a shorter parameter list
-- — a project that already ran the old 4-arg (with p_banishment_bracket)
-- version needs it dropped first. Safe no-op on a project that's never
-- defined it.
drop function if exists set_encounter_settings(int, int, int, int);

-- Validates and applies the player's difficulty selections. Always clears
-- the in-progress pack so the NEXT strike spawns fresh under the new
-- settings, rather than a live pack silently drifting out of sync with what
-- the fields now say. No Banishment-bracket param anymore -- that
-- difficulty knob is gone; see enemy_effective_stats()'s depth_mult for how
-- Banishment count now scales difficulty automatically instead.
create or replace function set_encounter_settings(
  p_pack_size int,
  p_affix_count int,
  p_debuff_count int
)
returns profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  max_affix_count int;
  max_debuff_count int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  -- caps read live from the catalog tables rather than a hardcoded number,
  -- so "how many affixes/debuffs can I stack" always tracks however many
  -- actually exist in the game -- no code change needed here the next time
  -- affix_defs/debuff_defs grows a row.
  select count(*) into max_affix_count from affix_defs;
  select count(*) into max_debuff_count from debuff_defs;

  -- Raised from the original 1-5 cap, but deliberately NOT fully uncapped
  -- like affix/debuff/bracket above: pack size drives a real per-enemy cost
  -- on both ends (roll_pack()'s loop does a DB lookup per member, and the
  -- client renders one card per member), so an unbounded value here is a
  -- genuine performance/DoS risk in a way those three never were. 30 is
  -- comfortably above anything a real fight needs while staying cheap.
  if p_pack_size not between 1 and 30 then
    raise exception 'pack size must be between 1 and 30';
  end if;
  if p_affix_count not between 0 and max_affix_count then
    raise exception 'affix count must be between 0 and %', max_affix_count;
  end if;
  if p_debuff_count not between 0 and max_debuff_count then
    raise exception 'debuff count must be between 0 and %', max_debuff_count;
  end if;

  update profiles set
    sel_pack_size = p_pack_size,
    sel_affix_count = p_affix_count,
    sel_debuff_count = p_debuff_count
  where id = p.id
  returning * into p;

  delete from player_combat where profile_id = p.id;

  return p;
end;
$$;

-- Shared combat core, extracted from what used to be strike_enemy()'s whole
-- body so the exact same one-action-worth-of-fighting logic can run from two
-- places: strike_enemy() itself (one call, while the player is online and
-- actively polling) and perform_idle_tick()'s offline-catch-up loop below
-- (many calls in a row, simulating actions spent while the player was away).
-- Pure in the sense that matters here: it never touches the database itself
-- (no reads/writes to profiles/player_combat) and never calls auth.uid() --
-- everything it needs comes in as arguments, and everything it produces
-- comes back in the returned row. That's what lets a caller run it N times
-- in a tight loop with only the running totals kept in memory, then persist
-- once at the end, instead of one DB round-trip per action.
drop type if exists combat_action_result cascade;
create type combat_action_result as (
  cur_pack jsonb,
  new_affix_keys jsonb,
  new_debuff_keys jsonb,
  cur_player_hp int,
  cur_player_max_hp int,
  rounds_run int,
  damage_dealt int,
  damage_taken int,
  kills int,
  deaths int,
  xp_gained int,
  gold_gained int,
  xp_lost int,
  gold_lost int,
  round_log jsonb
);

-- p is the player's profiles row (read-only here -- its gold/xp/hp columns
-- are NOT what's mutated; p_cur_player_hp is the actual "current hp" input,
-- and gold/xp deltas come back via the returned xp_gained/gold_gained/
-- xp_lost/gold_lost for the caller to apply). p_build_log lets a caller
-- skip round-by-round jsonb log construction (strike_enemy() wants it for
-- client playback; perform_idle_tick()'s offline loop, which can run this
-- hundreds of times in one call, does not).
create or replace function resolve_combat_action(
  p profiles,
  p_cur_pack jsonb,
  p_cur_player_hp int,
  p_affix_keys jsonb,
  p_debuff_keys jsonb,
  p_build_log boolean default true
)
returns combat_action_result
language plpgsql
as $$
declare
  res combat_action_result;
  base_rounds int := 10;       -- TUNE: new-pack budget at attack_speed = 1.0 (the default)
  rounds_soft_budget int;      -- once crossed, no NEW pack starts — but the current one still finishes
  rounds_hard_cap int := 25;   -- absolute ceiling across the whole call so this can never hang
  rounds_run int := 0;
  cur_pack jsonb;
  cur_player_hp int;
  cur_player_max_hp int;
  total_damage int := 0;
  total_damage_taken int := 0;
  total_kills int := 0;
  total_deaths int := 0;
  total_xp int := 0;
  total_gold int := 0;
  total_xp_lost int := 0;
  total_gold_lost int := 0;
  penalty_gold int;
  penalty_xp int;
  -- one entry per round actually fought, in order, so the client can play
  -- combat back round-by-round instead of only ever seeing the state after
  -- everything (including any clear/death respawn) has already resolved.
  -- Each entry reflects the whole pack's hp right after that round's
  -- blows, BEFORE any clear/death respawn resets things for the next pack.
  -- Only populated when p_build_log is true.
  round_log jsonb := '[]'::jsonb;
  round_hits jsonb;
  debuff_mod_bundles jsonb;
  affix_mod_bundles jsonb;
  class_mods jsonb;    -- this class's permanent bonus bundle (class_defs)
  player_mods jsonb;   -- merged from active debuffs + the player's class bonus
  enemy_mods jsonb;    -- merged from active affixes (applies pack-wide)
  hp_pct numeric;
  reward_mult numeric;
  target_idx int;
  member jsonb;
  hit record;
  any_alive boolean;
  pack_xp int;
  pack_gold int;
  -- Speed (see DESIGN.md §3a — the one standard stat that wasn't wired into
  -- combat until now): decides who swings first each round, and separately
  -- grants the player a flat, capped chance to dodge an enemy hit entirely
  -- (0 damage, not even a graze). Recomputed once per fight (evasion) and
  -- once per round (initiative, since pack_avg_speed shifts as members die).
  cur_player_speed numeric;
  cur_player_evasion_pct numeric;
  pack_avg_speed numeric;
  player_first boolean;
  counter_delta int;
  counter_hits jsonb;
  -- Whatever affixes/debuffs the pack we're CURRENTLY fighting rolled with,
  -- carried forward unchanged by default. Every mid-tick respawn point below
  -- (pack cleared, or either death branch) reassigns these to a brand-new
  -- random draw before rolling the next pack, so a fresh enemy really does
  -- mean fresh modifiers rather than reusing whatever get_or_spawn_pack()
  -- rolled once when this player_combat row was first created. Returned to
  -- the caller either way (unchanged is still a value to persist, just a
  -- no-op one).
  new_affix_keys jsonb;
  new_debuff_keys jsonb;
begin
  new_affix_keys := p_affix_keys;
  new_debuff_keys := p_debuff_keys;

  select coalesce(jsonb_agg(mods), '[]'::jsonb) into debuff_mod_bundles
    from debuff_defs where key in (select jsonb_array_elements_text(p_debuff_keys));
  select coalesce(jsonb_agg(mods), '[]'::jsonb) into affix_mod_bundles
    from affix_defs where key in (select jsonb_array_elements_text(p_affix_keys));
  select coalesce(mods, '{}'::jsonb) into class_mods from class_defs where key = p.class;
  player_mods := sum_mods(debuff_mod_bundles || jsonb_build_array(coalesce(class_mods, '{}'::jsonb)));
  enemy_mods := sum_mods(affix_mod_bundles);

  -- attack_speed_pct (a class-bonus-only key so far -- see class_defs) is
  -- a percent bonus to the player's raw attack_speed column, applied here
  -- rather than in compute_damage() since attack_speed drives the pack
  -- budget, not a per-hit damage roll.
  rounds_soft_budget := greatest(1, round(base_rounds * p.attack_speed * (1 + mod_val(player_mods, 'attack_speed_pct') / 100.0))::int);
  reward_mult := selection_reward_mult(p.sel_pack_size, p.sel_affix_count, p.sel_debuff_count);

  -- Speed -> initiative (compared per-round against the pack below, since
  -- who's "faster" shifts as members die) and Speed -> evasion (a flat,
  -- capped dodge chance owned by the player alone, same convention as
  -- Crit/Multi Strike: N speed = N% evasion, hard-capped rather than an
  -- asymptotic curve, matching DESIGN.md's relic-stat table style ("1% per
  -- roll, cap 25%") that this is the core-stat sibling of. evasion_flat is
  -- exposed so a future class bonus, gear roll, or affix can grant more of
  -- it the same way multi_strike_flat/crit_chance_flat already do — it
  -- doesn't need to be Speed alone forever, just today.
  cur_player_speed := greatest(1, p.speed * (1 + mod_val(player_mods, 'speed_pct') / 100.0));
  cur_player_evasion_pct := least(25, greatest(0, p.speed + mod_val(player_mods, 'evasion_flat')));

  cur_pack := p_cur_pack;
  -- a self-imposed hp_pct debuff temporarily lowers the player's effective
  -- ceiling for THIS fight only — never written back to profiles.max_hp —
  -- so current hp is clamped down to match if it's currently above that.
  cur_player_max_hp := greatest(1, round(p.max_hp * (1 + mod_val(player_mods, 'hp_pct') / 100.0))::int);
  cur_player_hp := least(p_cur_player_hp, cur_player_max_hp);

  -- ONE fight (one pack) per call, multiple ROUNDS against it this tick —
  -- not one loop per pack. rounds_soft_budget (attack-speed-scaled) caps
  -- how many rounds this tick gets; rounds_hard_cap is just the absolute
  -- safety ceiling. The moment the pack clears OR the player dies, the
  -- loop exits immediately and the call is done — it never starts a
  -- second pack in the same call, even if rounds remain in the budget.
  -- That used to happen (a fast-clearing pack would let the leftover
  -- budget spill into a whole new pack, occasionally killing the player
  -- TWICE in one tick), which read as broken rather than "fast". A pack
  -- left unresolved when the budget runs out simply picks back up next
  -- tick, same hp, right where it left off.
  <<exchanges>>
  loop
    exit exchanges when rounds_run >= rounds_soft_budget or rounds_run >= rounds_hard_cap;
    rounds_run := rounds_run + 1;
    round_hits := '[]'::jsonb;

    -- Initiative: recomputed every round, not once per fight — which side
    -- is "faster" can shift as the pack thins out (a slow tank pack might
    -- out-pace the player early but fall behind once only its quickest
    -- straggler is left). Ties go to the player. Compared against the
    -- ALIVE members' average speed, same reasoning as pack_avg_speed being
    -- recomputed rather than cached from spawn time.
    select coalesce(avg((e->>'speed')::numeric), 1) into pack_avg_speed
      from jsonb_array_elements(cur_pack) e where (e->>'hp')::int > 0;
    player_first := cur_player_speed >= pack_avg_speed;

    if not player_first then
      -- Out-sped: the pack gets this round's first blow in before the
      -- player ever swings — evasion (cur_player_evasion_pct) is the only
      -- thing that can save them from it now.
      select t.new_player_hp_delta, t.hits into counter_delta, counter_hits
        from pack_counterattack(cur_pack, p.defense::numeric, enemy_mods, player_mods, cur_player_evasion_pct) t;
      cur_player_hp := greatest(0, cur_player_hp + counter_delta);
      total_damage_taken := total_damage_taken - counter_delta;
      round_hits := round_hits || counter_hits;

      if cur_player_hp <= 0 then
        -- Death penalty: currently 0% of both gold and xp -- TUNE, set to
        -- 0 deliberately (see the player-first death branch below for the
        -- full history/rationale of what this used to be). Kept as real
        -- variables computed the same way rather than deleting the
        -- mechanism, so re-tuning this back up later is a one-line change,
        -- not rebuilding death handling from scratch. Off p.gold/p.xp as
        -- passed in by the caller -- strike_enemy() passes the player's
        -- true current totals (a death tick never also earns a kill's
        -- reward in the same call); perform_idle_tick()'s offline loop
        -- passes a running total threaded across iterations so a string of
        -- offline deaths, if this ever gets tuned back up, still compounds
        -- correctly instead of every iteration penalizing the same
        -- pre-loop snapshot.
        penalty_gold := floor(p.gold * 0.0);
        penalty_xp := floor(p.xp * 0.0);
        total_gold_lost := total_gold_lost + penalty_gold;
        total_xp_lost := total_xp_lost + penalty_xp;

        if p_build_log then
          round_log := round_log || jsonb_build_array(jsonb_build_object(
            'hits', round_hits, 'pack', cur_pack,
            'player_hp', 0, 'player_max_hp', cur_player_max_hp, 'event', 'death',
            'gold_lost', penalty_gold, 'xp_lost', penalty_xp
          ));
        end if;
        total_deaths := total_deaths + 1;
        cur_player_hp := cur_player_max_hp;
        -- New pack incoming -- reroll affixes/debuffs so it doesn't inherit
        -- whatever this dead pack happened to spawn with (see new_affix_keys/
        -- new_debuff_keys declaration above).
        select coalesce(jsonb_agg(key), '[]'::jsonb) into new_affix_keys
          from (select key from affix_defs order by random() limit greatest(0, p.sel_affix_count)) s;
        select coalesce(jsonb_agg(key), '[]'::jsonb) into new_debuff_keys
          from (select key from debuff_defs order by random() limit greatest(0, p.sel_debuff_count)) s;
        select coalesce(sum(mod_val(mods, 'hp_pct')), 0) into hp_pct
          from affix_defs where key in (select jsonb_array_elements_text(new_affix_keys));
        cur_pack := apply_hp_mod(roll_pack(p.sel_pack_size, p.depth), hp_pct);
        exit exchanges;
      end if;
    end if;

    -- player's primary swing: targets the first still-alive pack member
    select min(idx - 1) into target_idx
      from jsonb_array_elements(cur_pack) with ordinality as t(elem, idx)
      where (elem->>'hp')::int > 0;

    if target_idx is not null then
      member := cur_pack -> target_idx;
      select * into hit from compute_damage(p.attack, p.crit, (member->>'defense')::numeric, player_mods, enemy_mods, p.crit_damage);
      cur_pack := jsonb_set(cur_pack, array[target_idx::text, 'hp'],
        to_jsonb(greatest(0, (member->>'hp')::int - hit.dmg)));
      total_damage := total_damage + hit.dmg;
      round_hits := round_hits || jsonb_build_array(jsonb_build_object(
        'source', 'player', 'target', target_idx, 'dmg', hit.dmg, 'crit', hit.was_crit, 'multi_strike', false
      ));
      -- Kill heal: 25% of this fight's effective max HP, per pack member
      -- killed (target_idx was only ever selected from hp>0 members above,
      -- so pre-swing hp is always >0 here -- a kill is exactly this swing's
      -- damage taking it to <=0). Rewards actually landing kills with a bit
      -- of breathing room, short of the full heal a death gives.
      if (member->>'hp')::int - hit.dmg <= 0 then
        cur_player_hp := least(cur_player_max_hp, cur_player_hp + round(cur_player_max_hp * 0.25)::int);
      end if;

      -- Multi Strike: a bonus swing that CASCADES to the next still-alive
      -- member (re-hitting the same one if it's the last one standing) —
      -- this is what makes the stat directly valuable against a pack,
      -- not just a flat extra hit on a single target.
      if random() < (greatest(0, p.multi_strike + mod_val(player_mods, 'multi_strike_flat')) / 100.0) then
        select min(idx - 1) into target_idx
          from jsonb_array_elements(cur_pack) with ordinality as t(elem, idx)
          where (elem->>'hp')::int > 0;
        if target_idx is not null then
          member := cur_pack -> target_idx;
          select * into hit from compute_damage(p.attack, p.crit, (member->>'defense')::numeric, player_mods, enemy_mods, p.crit_damage);
          cur_pack := jsonb_set(cur_pack, array[target_idx::text, 'hp'],
            to_jsonb(greatest(0, (member->>'hp')::int - hit.dmg)));
          total_damage := total_damage + hit.dmg;
          round_hits := round_hits || jsonb_build_array(jsonb_build_object(
            'source', 'player', 'target', target_idx, 'dmg', hit.dmg, 'crit', hit.was_crit, 'multi_strike', true
          ));
          -- same kill heal as the primary swing above -- multi strike can
          -- land its own separate kill this round.
          if (member->>'hp')::int - hit.dmg <= 0 then
            cur_player_hp := least(cur_player_max_hp, cur_player_hp + round(cur_player_max_hp * 0.25)::int);
          end if;
        end if;
      end if;
    end if;

    any_alive := exists (select 1 from jsonb_array_elements(cur_pack) e where (e->>'hp')::int > 0);

    if not any_alive then
      -- pack cleared: rewards are summed from every member's ORIGINAL
      -- xp/gold (those fields never mutate — only 'hp' does), scaled by
      -- how much harder the player's own selections made this fight.
      select coalesce(sum((e->>'xp')::int), 0), coalesce(sum((e->>'gold')::int), 0)
        into pack_xp, pack_gold from jsonb_array_elements(cur_pack) e;
      pack_xp := round(pack_xp * reward_mult);
      pack_gold := round(pack_gold * reward_mult);

      -- No separate heal here anymore -- the kill that just cleared this
      -- pack already triggered its own 25% kill heal above (every kill
      -- does now, not just the one that empties the pack), so cur_player_hp
      -- already reflects it by the time we log the round below.

      if p_build_log then
        round_log := round_log || jsonb_build_array(jsonb_build_object(
          'hits', round_hits, 'pack', cur_pack,
          'player_hp', cur_player_hp, 'player_max_hp', cur_player_max_hp,
          'event', 'kill', 'xp_gained', pack_xp, 'gold_gained', pack_gold
        ));
      end if;

      total_kills := total_kills + 1;
      total_xp := total_xp + pack_xp;
      total_gold := total_gold + pack_gold;

      -- roll the next pack now so it's ready and waiting, but STOP here —
      -- this tick's fight is over the moment the pack clears, even with
      -- rounds left in the budget. Fighting it is next tick's job.
      -- Reroll affixes/debuffs too (see new_affix_keys/new_debuff_keys
      -- declaration above) -- a genuinely new pack should bring genuinely
      -- new modifiers instead of carrying the just-cleared pack's forward.
      select coalesce(jsonb_agg(key), '[]'::jsonb) into new_affix_keys
        from (select key from affix_defs order by random() limit greatest(0, p.sel_affix_count)) s;
      select coalesce(jsonb_agg(key), '[]'::jsonb) into new_debuff_keys
        from (select key from debuff_defs order by random() limit greatest(0, p.sel_debuff_count)) s;
      select coalesce(sum(mod_val(mods, 'hp_pct')), 0) into hp_pct
        from affix_defs where key in (select jsonb_array_elements_text(new_affix_keys));
      cur_pack := apply_hp_mod(roll_pack(p.sel_pack_size, p.depth), hp_pct);
      exit exchanges;
    end if;

    if player_first then
      -- Not out-sped this round: the pack only swings back AFTER taking
      -- the player's hit above — the original, still-default order. (When
      -- NOT player_first, this already happened at the top of the round,
      -- before the player's swing — see above.)
      select t.new_player_hp_delta, t.hits into counter_delta, counter_hits
        from pack_counterattack(cur_pack, p.defense::numeric, enemy_mods, player_mods, cur_player_evasion_pct) t;
      cur_player_hp := greatest(0, cur_player_hp + counter_delta);
      total_damage_taken := total_damage_taken - counter_delta;
      round_hits := round_hits || counter_hits;

      if cur_player_hp <= 0 then
        -- pack wiped the player — WIN-ONLY REWARDS: nothing is granted
        -- here, only on a clear above. Still a tracked, reported outcome,
        -- not a silent reset. Full heal (to this fight's effective cap)
        -- and a fresh pack, same selections/affixes/debuffs. DEATH PENALTY:
        -- 0% of current gold, 0% of current xp -- TUNE, set to 0
        -- deliberately (this used to be 25%/10%, back when it was the
        -- counterweight making pushing pack size/affixes/debuffs past a
        -- comfortable margin a real risk instead of a free way to farm
        -- harder content until it works; Banishment difficulty scaling
        -- automatically now covers that same "don't overreach for free"
        -- role on its own, so dying no longer costs anything on top of it —
        -- see the mirrored branch above for the same change).
        -- Then STOP — same reasoning as the pack-cleared branch above:
        -- this tick's fight is over the instant the player dies, not a
        -- chance for the leftover budget to kill them again against the
        -- freshly-rolled pack.
        penalty_gold := floor(p.gold * 0.0);
        penalty_xp := floor(p.xp * 0.0);
        total_gold_lost := total_gold_lost + penalty_gold;
        total_xp_lost := total_xp_lost + penalty_xp;

        if p_build_log then
          round_log := round_log || jsonb_build_array(jsonb_build_object(
            'hits', round_hits, 'pack', cur_pack,
            'player_hp', 0, 'player_max_hp', cur_player_max_hp, 'event', 'death',
            'gold_lost', penalty_gold, 'xp_lost', penalty_xp
          ));
        end if;

        total_deaths := total_deaths + 1;
        cur_player_hp := cur_player_max_hp;
        -- New pack incoming -- reroll affixes/debuffs, same as the other
        -- two respawn points above.
        select coalesce(jsonb_agg(key), '[]'::jsonb) into new_affix_keys
          from (select key from affix_defs order by random() limit greatest(0, p.sel_affix_count)) s;
        select coalesce(jsonb_agg(key), '[]'::jsonb) into new_debuff_keys
          from (select key from debuff_defs order by random() limit greatest(0, p.sel_debuff_count)) s;
        select coalesce(sum(mod_val(mods, 'hp_pct')), 0) into hp_pct
          from affix_defs where key in (select jsonb_array_elements_text(new_affix_keys));
        cur_pack := apply_hp_mod(roll_pack(p.sel_pack_size, p.depth), hp_pct);
        exit exchanges;
      end if;
    end if;

    -- an ordinary round: still fighting, everything carries into the next.
    if p_build_log then
      round_log := round_log || jsonb_build_array(jsonb_build_object(
        'hits', round_hits, 'pack', cur_pack,
        'player_hp', cur_player_hp, 'player_max_hp', cur_player_max_hp, 'event', null
      ));
    end if;
  end loop exchanges;

  res.cur_pack := cur_pack;
  res.new_affix_keys := new_affix_keys;
  res.new_debuff_keys := new_debuff_keys;
  res.cur_player_hp := cur_player_hp;
  res.cur_player_max_hp := cur_player_max_hp;
  res.rounds_run := rounds_run;
  res.damage_dealt := total_damage;
  res.damage_taken := total_damage_taken;
  res.kills := total_kills;
  res.deaths := total_deaths;
  res.xp_gained := total_xp;
  res.gold_gained := total_gold;
  res.xp_lost := total_xp_lost;
  res.gold_lost := total_gold_lost;
  res.round_log := round_log;
  return res;
end;
$$;

drop function if exists perform_idle_tick();

-- Offline catch-up: runs once whenever the client reconnects (see doTick()'s
-- isInitial call in app.js), covering everything since last_tick_at. Grants
-- the same passive per-second xp/gold trickle it always has, AND (see
-- resolve_combat_action() above) now simulates real combat for however many
-- actions the elapsed time and the player's action pool allow — the two
-- stack, exactly like while online strike_enemy()'s combat rewards and this
-- function's passive trickle already run independently on the same 8s cadence
-- and simply add up. Before this, actions never ticked down while the tab
-- was closed (nothing but the client-driven strike_enemy() ever spent them),
-- which read as a bug once players noticed the pool never moved overnight.
create or replace function perform_idle_tick()
returns table (
  xp_gained bigint, gold_gained bigint, new_level int, boss_damage bigint,
  daily_dmg_dealt int, daily_dmg_taken int, daily_kills int, daily_deaths int,
  daily_idle_xp int, daily_idle_gold int, daily_reset_at date,
  elapsed_seconds bigint, -- how long since last_tick_at this call actually
                          -- covered (capped at max_offline_seconds) -- lets
                          -- the client tell "just reloaded the page" apart
                          -- from "was away for hours" when deciding whether
                          -- to show a welcome-back summary (see doTick/
                          -- maybeShowWelcomeBackSummary in app.js)
  combat_kills int,      -- this catch-up's own simulated kills/deaths/spend
  combat_deaths int,     -- -- NOT the daily_* whole-day aggregates above,
  actions_spent int       -- just what this one call simulated
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  sim_p profiles%rowtype; -- running copy threaded through the offline-combat
                           -- loop below: only .gold/.xp are kept live (fed by
                           -- each iteration's own combat gains/losses), so a
                           -- string of simulated deaths -- if the death
                           -- penalty is ever tuned back up off 0% -- still
                           -- compounds against real running totals rather
                           -- than every iteration penalizing the same
                           -- pre-loop snapshot. Everything else about it is
                           -- never read by resolve_combat_action() except as
                           -- fixed character-sheet stats (attack/defense/
                           -- class/etc.), which don't change mid-catch-up.
  pc player_combat%rowtype;
  elapsed_seconds bigint;
  max_offline_seconds bigint := 72 * 3600; -- TUNE: cap offline gains at 72h
  xp_per_second numeric := 0.5;            -- TUNE
  gold_per_second numeric := 0.3;          -- TUNE
  depth_multiplier numeric;
  gained_xp bigint;
  gained_gold bigint;
  lvl int;
  dmg bigint := 0; -- guild bosses are disabled for now (see 4c below); kept
                    -- in the return signature so callers don't need to change
  daily record;
  -- Offline combat simulation: one simulated action per seconds_per_action
  -- of real elapsed time, same cadence strike_enemy() runs at while online
  -- (TICK_INTERVAL_MS in app.js) -- so a player who was away fights through
  -- roughly the same pace of action they'd have spent watching the screen.
  seconds_per_action int := 8; -- TUNE: keep in sync with TICK_INTERVAL_MS
  n_actions int;
  combat_pack jsonb;
  combat_hp int;
  combat_affix_keys jsonb;
  combat_debuff_keys jsonb;
  res combat_action_result;
  combat_damage_dealt int := 0;
  combat_damage_taken int := 0;
  combat_kills int := 0;
  combat_deaths int := 0;
  combat_xp int := 0;
  combat_gold int := 0;
  combat_xp_lost int := 0;
  combat_gold_lost int := 0;
  i int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then
    raise exception 'no profile for current user';
  end if;

  elapsed_seconds := least(extract(epoch from (now() - p.last_tick_at))::bigint, max_offline_seconds);
  if elapsed_seconds <= 0 then
    select * into daily from bump_daily_stats(); -- still refreshes/resets the daily snapshot, adds nothing
    return query select 0::bigint, 0::bigint, p.level, 0::bigint,
      daily.daily_dmg_dealt, daily.daily_dmg_taken, daily.daily_kills, daily.daily_deaths,
      daily.daily_idle_xp, daily.daily_idle_gold, daily.daily_reset_at,
      greatest(0, elapsed_seconds), 0, 0, 0;
    return;
  end if;

  depth_multiplier := 1 + (p.depth * 0.5); -- TUNE: each Depth is +50% base income
  gained_xp := floor(elapsed_seconds * xp_per_second * depth_multiplier);
  gained_gold := floor(elapsed_seconds * gold_per_second * depth_multiplier);

  -- How many actions can this catch-up simulate? Capped by BOTH real
  -- elapsed time (at one action per seconds_per_action) AND the player's
  -- actual action pool -- an empty pool means no fighting happens no matter
  -- how long they were away, same as if they'd been online and run dry.
  n_actions := least(p.actions, floor(elapsed_seconds / seconds_per_action)::int);

  sim_p := p;

  if n_actions > 0 then
    perform get_or_spawn_pack(); -- ensures a live pack (and its affixes/debuffs) exists
    select * into pc from player_combat where profile_id = auth.uid();
    combat_pack := pc.pack;
    combat_hp := p.hp;
    combat_affix_keys := pc.affix_keys;
    combat_debuff_keys := pc.debuff_keys;

    -- Run the same per-action combat core strike_enemy() uses, N times in a
    -- row, entirely in memory -- no DB read/write per iteration, just one of
    -- each after the loop. p_build_log := false: nobody's watching this
    -- happen live, so skip building a per-round jsonb log across what could
    -- be hundreds of iterations.
    for i in 1..n_actions loop
      res := resolve_combat_action(sim_p, combat_pack, combat_hp, combat_affix_keys, combat_debuff_keys, false);

      combat_pack := res.cur_pack;
      combat_hp := res.cur_player_hp;
      combat_affix_keys := res.new_affix_keys;
      combat_debuff_keys := res.new_debuff_keys;

      combat_damage_dealt := combat_damage_dealt + res.damage_dealt;
      combat_damage_taken := combat_damage_taken + res.damage_taken;
      combat_kills := combat_kills + res.kills;
      combat_deaths := combat_deaths + res.deaths;
      combat_xp := combat_xp + res.xp_gained;
      combat_gold := combat_gold + res.gold_gained;
      combat_xp_lost := combat_xp_lost + res.xp_lost;
      combat_gold_lost := combat_gold_lost + res.gold_lost;

      sim_p.gold := greatest(0, sim_p.gold + res.gold_gained - res.gold_lost);
      sim_p.xp := greatest(0, sim_p.xp + res.xp_gained - res.xp_lost);
    end loop;
  end if;

  -- greatest(p.level, ...): XP loss (e.g. a death penalty, whether from
  -- strike_enemy() or this function's own offline combat) must never delevel
  -- a character -- level can only ever go up here, never recompute downward
  -- just because xp dropped since the last time this ran.
  lvl := greatest(p.level, 1, floor(sqrt((p.xp + gained_xp + combat_xp - combat_xp_lost) / 100.0))::int); -- TUNE: level curve

  update profiles
    set xp = greatest(0, xp + gained_xp + combat_xp - combat_xp_lost),
        gold = greatest(0, gold + gained_gold + combat_gold - combat_gold_lost),
        level = lvl,
        hp = case when n_actions > 0 then combat_hp else hp end,
        actions = case when n_actions > 0 then p.actions - n_actions else actions end,
        last_tick_at = now(),
        last_active_at = now()
    where id = p.id;

  select * into daily from bump_daily_stats(
    p_dmg_dealt := combat_damage_dealt, p_dmg_taken := combat_damage_taken,
    p_kills := combat_kills, p_deaths := combat_deaths,
    p_idle_xp := gained_xp::int, p_idle_gold := gained_gold::int
  );

  -- only touch player_combat (and its last_strike_at, which strike_enemy()'s
  -- own cooldown check reads) when this catch-up actually fought -- a quick
  -- reload with no real elapsed time should never spuriously reset the
  -- cooldown clock or touch an in-progress pack.
  if n_actions > 0 then
    update player_combat
      set pack = combat_pack, affix_keys = combat_affix_keys, debuff_keys = combat_debuff_keys,
          updated_at = now(), last_strike_at = now()
      where profile_id = auth.uid();
  end if;

  -- guild bosses are disabled for now — no idle damage is fed to them.
  -- xp_gained/gold_gained are the COMBINED total (passive trickle + gross
  -- combat gains, not net of any combat loss -- same "gained" convention
  -- strike_enemy() already uses, where xp_lost/gold_lost are reported
  -- separately rather than pre-subtracted) so the client's existing Welcome
  -- Back summary (maybeShowWelcomeBackSummary in app.js) keeps working
  -- unchanged even though it can now include real combat rewards.
  return query select gained_xp + combat_xp, gained_gold + combat_gold, lvl, dmg,
    daily.daily_dmg_dealt, daily.daily_dmg_taken, daily.daily_kills, daily.daily_deaths,
    daily.daily_idle_xp, daily.daily_idle_gold, daily.daily_reset_at,
    elapsed_seconds, combat_kills, combat_deaths, n_actions;
end;
$$;

-- same reasoning as the drop above this signature has changed more than
-- once now (single-swing -> level-driven rounds -> pack combat -> and now
-- dropping the enemy-key argument entirely, since which mobs spawn is
-- rolled server-side per pack member in roll_pack() rather than chosen by
-- the caller -- the drop below (same "(text)" arg-type signature as the
-- p_enemy_key version) already covers this transition too).
drop function if exists strike_enemy(text);

-- Thin wrapper around resolve_combat_action() (see above): owns the DB I/O
-- (one profiles/player_combat read, one action/cooldown gate, one write of
-- each at the end) and the client-facing return shape; all the actual round-
-- by-round fighting now lives in resolve_combat_action(), shared with
-- perform_idle_tick()'s offline-catch-up loop.
create or replace function strike_enemy()
returns table (
  rounds_fought int,
  damage_dealt int,
  kills int,
  deaths int,
  player_hp int,
  player_max_hp int,
  xp_gained int,
  gold_gained int,
  actions_left int,
  out_of_actions boolean,
  rounds_log jsonb,
  final_pack jsonb,
  affix_names jsonb,
  debuff_names jsonb,
  xp_lost int,
  gold_lost int,
  daily_dmg_dealt int,
  daily_dmg_taken int,
  daily_kills int,
  daily_deaths int,
  daily_idle_xp int,
  daily_idle_gold int,
  daily_reset_at date
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  pc player_combat%rowtype;
  cooldown interval := interval '1 second'; -- TUNE: just enough to stop double-fires
  action_cost int := 1;        -- flat per fight-tick, regardless of how many rounds it takes
  cur_actions int;
  daily record;
  res combat_action_result;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  select * into pc from player_combat where profile_id = auth.uid();

  -- this fires automatically every idle tick (unattended), so both the
  -- "out of actions" and "on cooldown" cases return a quiet no-op row
  -- instead of raising — an exception every 8s would just spam the client.
  if p.actions < action_cost then
    select * into daily from bump_daily_stats(); -- still refreshes/resets the daily snapshot, adds nothing
    return query select 0, 0, 0, 0, p.hp, p.max_hp, 0, 0, p.actions, true,
      '[]'::jsonb, coalesce(pc.pack, '[]'::jsonb), '[]'::jsonb, '[]'::jsonb, 0, 0,
      daily.daily_dmg_dealt, daily.daily_dmg_taken, daily.daily_kills, daily.daily_deaths,
      daily.daily_idle_xp, daily.daily_idle_gold, daily.daily_reset_at;
    return;
  end if;

  if pc.last_strike_at is not null and pc.last_strike_at + cooldown > now() then
    select * into daily from bump_daily_stats();
    return query select 0, 0, 0, 0, p.hp, p.max_hp, 0, 0, p.actions, false,
      '[]'::jsonb, coalesce(pc.pack, '[]'::jsonb), '[]'::jsonb, '[]'::jsonb, 0, 0,
      daily.daily_dmg_dealt, daily.daily_dmg_taken, daily.daily_kills, daily.daily_deaths,
      daily.daily_idle_xp, daily.daily_idle_gold, daily.daily_reset_at;
    return;
  end if;

  perform get_or_spawn_pack(); -- ensures a live pack (and its affixes/debuffs) exists
  select * into pc from player_combat where profile_id = auth.uid();

  cur_actions := p.actions - action_cost; -- spent once, up front, no matter how the fight goes

  res := resolve_combat_action(p, pc.pack, p.hp, pc.affix_keys, pc.debuff_keys, true);

  update profiles
    set hp = res.cur_player_hp,
        xp = greatest(0, xp + res.xp_gained - res.xp_lost),
        gold = greatest(0, gold + res.gold_gained - res.gold_lost),
        actions = cur_actions
    where id = p.id;

  select * into daily from bump_daily_stats(
    p_dmg_dealt := res.damage_dealt, p_dmg_taken := res.damage_taken,
    p_kills := res.kills, p_deaths := res.deaths
  );

  update player_combat
    set pack = res.cur_pack, affix_keys = res.new_affix_keys, debuff_keys = res.new_debuff_keys,
        updated_at = now(), last_strike_at = now()
    where profile_id = auth.uid();

  return query select res.rounds_run, res.damage_dealt, res.kills, res.deaths, res.cur_player_hp, res.cur_player_max_hp,
    res.xp_gained, res.gold_gained, cur_actions, false, res.round_log, res.cur_pack,
    (select coalesce(jsonb_agg(name), '[]'::jsonb) from affix_defs where key in (select jsonb_array_elements_text(res.new_affix_keys))),
    (select coalesce(jsonb_agg(name), '[]'::jsonb) from debuff_defs where key in (select jsonb_array_elements_text(res.new_debuff_keys))),
    res.xp_lost, res.gold_lost,
    daily.daily_dmg_dealt, daily.daily_dmg_taken, daily.daily_kills, daily.daily_deaths,
    daily.daily_idle_xp, daily.daily_idle_gold, daily.daily_reset_at;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4d. Banishment (prestige)
--    At level 100+ a player may sacrifice their character to the Abyss:
--    level/xp/gold reset and inventory/current-fight state are wiped, but
--    they keep +1 Depth (displayed to players as "Banishments" -- see
--    profiles.depth) plus a slice of their current attack/defense/max_hp,
--    sized by how much Depth they'd already reached BEFORE this banishment
--    (i.e. how many times they'd already banished). They also choose their
--    class fresh for the new life
--    (p_new_class) — same 4-option choice as initial signup, and just as
--    consequential, since class_defs' bonus bundle (see its seed data
--    above) applies for the whole next run. Every constant below is a
--    first-pass number — TUNE once this is actually playtested.
--
--    IMPORTANT, for whenever itemization gets built (see DESIGN.md §3a):
--    profiles.attack/defense/max_hp below MUST stay pure "character sheet"
--    numbers — a character's own permanent growth via Banishment retention
--    itself — and gear must NEVER mutate them, no matter how tempting it is
--    to just "+= item bonus" onto the column. Gear stats have to apply the
--    same way class_defs' bonuses already do: a separate modifier bundle
--    read at combat-resolution time (see strike_enemy()'s player_mods),
--    completely invisible to this function. Otherwise equipping strong
--    gear right before banishing would let a player permanently bank power
--    they never really earned on the character itself — gear is supposed
--    to stay swappable/losable, not something Banishment can launder into
--    permanent retention.
-- ----------------------------------------------------------------------------

create table if not exists banishments (
  id              bigint generated always as identity primary key,
  profile_id      uuid not null references profiles(id) on delete cascade,
  level_reached   int not null,
  retained_pct    numeric not null,   -- stored as a percent, e.g. 0.25, 0.5, 0.75, 100
  created_at      timestamptz not null default now()
);
create index if not exists idx_banishments_profile on banishments(profile_id, created_at desc);
-- prowess_gained tracked Abyssal Prowess, which no longer exists -- dropped
-- on any project that still has it from before; a no-op on a fresh project.
alter table banishments drop column if exists prowess_gained;

alter table banishments enable row level security;
drop policy if exists "banishment history is publicly readable" on banishments;
create policy "banishment history is publicly readable" on banishments for select using (true);

create or replace function perform_banishment(p_new_class text default null)
returns profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  retain_pct numeric;      -- fraction, e.g. 0.0025 for 0.25%
  display_pct numeric;     -- same tier, as the percent number shown to players
  base_attack int := 8;    -- TUNE: matches profiles.attack's default for a fresh character
  base_defense int := 6;   -- TUNE: matches profiles.defense's default
  base_max_hp int := 30;   -- TUNE: matches profiles.max_hp's default
  new_attack int;
  new_defense int;
  new_max_hp int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  if p.level < 100 then
    raise exception 'you must reach level 100 before you can banish your character';
  end if;

  -- players choose their class fresh on every banishment (same 4 options
  -- as initial signup). Omitting p_new_class (or passing null) keeps
  -- whatever class they already had, so older callers / a stray retry
  -- without the arg don't accidentally reset it.
  if p_new_class is not null and p_new_class not in ('warrior','archer','magi','striker') then
    raise exception 'invalid class: %', p_new_class;
  end if;

  -- retention tier is based on Depth already reached from PAST banishments
  -- (profiles.depth, before this one increments it) — the more times
  -- you've already banished, the more of this run carries into the next.
  -- These thresholds are a straight /10 rescale of the old Abyssal-Prowess
  -- tiers (100/501/1001), since Prowess used to be earned at a flat +10 per
  -- banishment (floor(level/10) at the required level-100 minimum) — same
  -- milestones and pacing as before, just read directly off Depth instead
  -- of a separate currency you had to bank up first.
  if p.depth >= 100 then
    retain_pct := 1.0;      display_pct := 100;
  elsif p.depth >= 50 then
    retain_pct := 0.0075;   display_pct := 0.75;
  elsif p.depth >= 10 then
    retain_pct := 0.005;    display_pct := 0.50;
  else
    retain_pct := 0.0025;   display_pct := 0.25;
  end if;

  new_attack  := greatest(base_attack,  base_attack  + floor((p.attack  - base_attack)  * retain_pct));
  new_defense := greatest(base_defense, base_defense + floor((p.defense - base_defense) * retain_pct));
  new_max_hp  := greatest(base_max_hp,  base_max_hp  + floor((p.max_hp  - base_max_hp)  * retain_pct));

  insert into banishments (profile_id, level_reached, retained_pct)
  values (p.id, p.level, display_pct);

  update profiles set
    level           = 1,
    xp              = 0,
    gold            = 0,
    depth           = depth + 1,             -- each banishment pushes you one Depth ("Banishments") deeper
    class           = coalesce(p_new_class, class),
    attack          = new_attack,
    defense         = new_defense,
    max_hp          = new_max_hp,
    hp              = new_max_hp,
    actions         = max_actions,
    last_tick_at    = now(),
    last_active_at  = now()
  where id = p.id
  returning * into p;

  delete from inventory where profile_id = p.id;
  delete from player_combat where profile_id = p.id;

  return p;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Guild bosses: spawn-on-read + damage application
-- ----------------------------------------------------------------------------

create or replace function get_or_spawn_active_boss(p_guild_id uuid)
returns guild_bosses
language plpgsql
security definer
set search_path = public
as $$
declare
  boss guild_bosses%rowtype;
  avg_depth numeric;
  next_tier int;
  hp bigint;
begin
  select * into boss
    from guild_bosses
    where guild_id = p_guild_id and defeated_at is null
    order by spawned_at desc
    limit 1;

  if found then
    return boss;
  end if;

  -- no active boss: spawn one if we're past the cooldown of the last defeated boss
  select * into boss
    from guild_bosses
    where guild_id = p_guild_id
    order by spawned_at desc
    limit 1;

  if found and boss.next_spawn_at is not null and boss.next_spawn_at > now() then
    return boss; -- still on cooldown; caller sees defeated_at is not null and current_hp <= 0
  end if;

  select coalesce(avg(pr.depth), 0) into avg_depth
    from guild_members gm join profiles pr on pr.id = gm.profile_id
    where gm.guild_id = p_guild_id;

  next_tier := coalesce(boss.tier, 0) + 1;
  hp := floor(1000 * power(next_tier, 1.5) * (1 + avg_depth * 0.5)); -- TUNE

  insert into guild_bosses (guild_id, tier, name, max_hp, current_hp, spawned_at)
  values (p_guild_id, next_tier, 'Abyssal Horror, Tier ' || next_tier, hp, hp, now())
  returning * into boss;

  return boss;
end;
$$;

create or replace function apply_boss_damage(p_boss_id uuid, p_profile_id uuid, p_damage bigint, p_source text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  boss guild_bosses%rowtype;
begin
  select * into boss from guild_bosses where id = p_boss_id for update;
  if not found or boss.defeated_at is not null then
    return;
  end if;

  insert into guild_boss_damage_log (boss_id, profile_id, damage, source)
  values (p_boss_id, p_profile_id, p_damage, p_source);

  update guild_bosses
    set current_hp = greatest(0, current_hp - p_damage)
    where id = p_boss_id;

  if boss.current_hp - p_damage <= 0 then
    update guild_bosses
      set defeated_at = now(),
          next_spawn_at = now() + interval '30 minutes' -- TUNE: boss respawn cooldown
      where id = p_boss_id;
  end if;
end;
$$;

create or replace function strike_active_boss()
returns table (damage_dealt bigint, boss_defeated boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  my_guild_id uuid;
  boss guild_bosses%rowtype;
  dmg bigint;
  cooldown interval := interval '10 seconds'; -- TUNE
begin
  select * into p from profiles where id = auth.uid();
  if not found then raise exception 'no profile'; end if;

  if p.last_boss_strike_at + cooldown > now() then
    raise exception 'strike is on cooldown';
  end if;

  select gm.guild_id into my_guild_id from guild_members gm where gm.profile_id = p.id;
  if my_guild_id is null then
    raise exception 'you are not in a guild';
  end if;

  boss := get_or_spawn_active_boss(my_guild_id);
  if boss.id is null or boss.defeated_at is not null then
    return query select 0::bigint, false;
    return;
  end if;

  dmg := greatest(1, p.attack * (2 + p.depth)); -- TUNE
  perform apply_boss_damage(boss.id, p.id, dmg, 'strike');
  update profiles set last_boss_strike_at = now() where id = p.id;

  return query select dmg, (dmg >= boss.current_hp);
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Guilds: create / join / leave
-- ----------------------------------------------------------------------------

create or replace function create_guild(p_name text, p_tag text)
returns guilds
language plpgsql
security definer
set search_path = public
as $$
declare
  g guilds%rowtype;
begin
  if exists (select 1 from guild_members where profile_id = auth.uid()) then
    raise exception 'you are already in a guild';
  end if;

  insert into guilds (name, tag, leader_id) values (p_name, p_tag, auth.uid())
  returning * into g;

  insert into guild_members (guild_id, profile_id, role) values (g.id, auth.uid(), 'leader');

  return g;
end;
$$;

-- Replaced by the application/invite flow below — guilds are no longer
-- free-join. Dropped explicitly (not just superseded by CREATE OR REPLACE)
-- since nothing recreates it under this name/signature anymore.
drop function if exists join_guild(uuid);

-- ----------------------------------------------------------------------------
-- 6a2. Guild applications & invites
--    Two-sided: a player applies to a guild (apply_to_guild) or a
--    leader/officer invites a player (invite_to_guild). Either side can be
--    accepted or declined by the other party (respond_to_application /
--    respond_to_invite), and the sender of either can cancel/revoke it
--    (cancel_guild_request). The partial unique index on guild_requests
--    stops a duplicate pending request of the same type/guild/player from
--    piling up; a friendly check here gives a clearer error than the
--    underlying unique-violation would.
-- ----------------------------------------------------------------------------

create or replace function apply_to_guild(p_guild_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  member_count int;
  cap int;
begin
  if exists (select 1 from guild_members where profile_id = auth.uid()) then
    raise exception 'you are already in a guild';
  end if;

  select member_cap into cap from guilds where id = p_guild_id;
  if not found then raise exception 'guild not found'; end if;

  select count(*) into member_count from guild_members where guild_id = p_guild_id;
  if member_count >= cap then
    raise exception 'guild is full';
  end if;

  if exists (
    select 1 from guild_requests
    where guild_id = p_guild_id and profile_id = auth.uid()
      and type = 'application' and status = 'pending'
  ) then
    raise exception 'you already have a pending application to that guild';
  end if;

  insert into guild_requests (guild_id, profile_id, type) values (p_guild_id, auth.uid(), 'application');
end;
$$;

create or replace function invite_to_guild(p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_guild_id uuid;
  my_role text;
  target_id uuid;
  member_count int;
  cap int;
begin
  select gm.guild_id, gm.role into my_guild_id, my_role from guild_members gm where gm.profile_id = auth.uid();
  if my_guild_id is null then raise exception 'you are not in a guild'; end if;
  if my_role not in ('leader', 'officer') then raise exception 'only the guild leader or an officer can send invites'; end if;

  select id into target_id from profiles where lower(username) = lower(p_username);
  if target_id is null then raise exception 'no character with that name'; end if;

  if exists (select 1 from guild_members where profile_id = target_id) then
    raise exception 'that player is already in a guild';
  end if;

  select member_cap into cap from guilds where id = my_guild_id;
  select count(*) into member_count from guild_members where guild_id = my_guild_id;
  if member_count >= cap then
    raise exception 'your guild is full';
  end if;

  if exists (
    select 1 from guild_requests
    where guild_id = my_guild_id and profile_id = target_id
      and type = 'invite' and status = 'pending'
  ) then
    raise exception 'that player already has a pending invite from your guild';
  end if;

  insert into guild_requests (guild_id, profile_id, type) values (my_guild_id, target_id, 'invite');
end;
$$;

-- shared by respond_to_application/respond_to_invite: actually seats the
-- player once a request is accepted, re-checking the guild isn't full and
-- clearing out that player's other now-moot pending requests.
create or replace function accept_guild_request(p_request_id uuid, p_guild_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  member_count int;
  cap int;
begin
  if exists (select 1 from guild_members where profile_id = p_profile_id) then
    raise exception 'that player is already in a guild';
  end if;

  select member_cap into cap from guilds where id = p_guild_id;
  select count(*) into member_count from guild_members where guild_id = p_guild_id;
  if member_count >= cap then
    raise exception 'guild is full';
  end if;

  insert into guild_members (guild_id, profile_id, role) values (p_guild_id, p_profile_id, 'member');

  update guild_requests set status = 'accepted' where id = p_request_id;
  update guild_requests set status = 'cancelled'
    where profile_id = p_profile_id and status = 'pending' and id <> p_request_id;
end;
$$;

create or replace function respond_to_application(p_request_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r guild_requests%rowtype;
  my_role text;
begin
  select * into r from guild_requests where id = p_request_id;
  if not found or r.type <> 'application' or r.status <> 'pending' then
    raise exception 'that application is no longer pending';
  end if;

  select role into my_role from guild_members where guild_id = r.guild_id and profile_id = auth.uid();
  if my_role not in ('leader', 'officer') then
    raise exception 'only the guild leader or an officer can decide applications';
  end if;

  if p_accept then
    perform accept_guild_request(r.id, r.guild_id, r.profile_id);
  else
    update guild_requests set status = 'declined' where id = r.id;
  end if;
end;
$$;

create or replace function respond_to_invite(p_request_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r guild_requests%rowtype;
begin
  select * into r from guild_requests where id = p_request_id;
  if not found or r.type <> 'invite' or r.status <> 'pending' then
    raise exception 'that invite is no longer pending';
  end if;
  if r.profile_id <> auth.uid() then
    raise exception 'that invite is not addressed to you';
  end if;

  if p_accept then
    perform accept_guild_request(r.id, r.guild_id, r.profile_id);
  else
    update guild_requests set status = 'declined' where id = r.id;
  end if;
end;
$$;

create or replace function cancel_guild_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r guild_requests%rowtype;
  my_role text;
begin
  select * into r from guild_requests where id = p_request_id;
  if not found or r.status <> 'pending' then
    raise exception 'that request is no longer pending';
  end if;

  if r.type = 'application' then
    if r.profile_id <> auth.uid() then
      raise exception 'you can only cancel your own applications';
    end if;
  else -- invite
    select role into my_role from guild_members where guild_id = r.guild_id and profile_id = auth.uid();
    if my_role not in ('leader', 'officer') then
      raise exception 'only the guild leader or an officer can revoke an invite';
    end if;
  end if;

  update guild_requests set status = 'cancelled' where id = r.id;
end;
$$;

create or replace function leave_guild()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text;
begin
  select role into my_role from guild_members where profile_id = auth.uid();
  if my_role is null then
    return; -- not in a guild — no-op, matches prior behavior
  end if;
  if my_role = 'leader' then
    raise exception 'transfer leadership to another member before leaving, or disband the guild instead';
  end if;
  delete from guild_members where profile_id = auth.uid();
end;
$$;

-- ----------------------------------------------------------------------------
-- 6b. Guild management: ranks, leadership transfer, disband
--    Leader-only. A guild always has exactly one leader (enforced here, not
--    by a DB constraint): set_member_rank only moves players between
--    'officer'/'member', transfer_leadership is the only way the 'leader'
--    role ever changes hands, and leave_guild (above) refuses to let the
--    leader leave without transferring first — that's what makes the
--    Leave-button-disabled-for-leaders UI in app.js a real guarantee and
--    not just a client-side nicety.
-- ----------------------------------------------------------------------------

create or replace function set_member_rank(p_profile_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_guild_id uuid;
  my_role text;
  target_role text;
begin
  select gm.guild_id, gm.role into my_guild_id, my_role from guild_members gm where gm.profile_id = auth.uid();
  if my_guild_id is null then raise exception 'you are not in a guild'; end if;
  if my_role <> 'leader' then raise exception 'only the guild leader can assign ranks'; end if;

  if p_role not in ('officer', 'member') then
    raise exception 'rank must be officer or member';
  end if;

  select role into target_role from guild_members where guild_id = my_guild_id and profile_id = p_profile_id;
  if target_role is null then raise exception 'that player is not in your guild'; end if;
  if target_role = 'leader' then raise exception 'use transfer_leadership to change the guild leader'; end if;

  update guild_members set role = p_role where guild_id = my_guild_id and profile_id = p_profile_id;
end;
$$;

create or replace function transfer_leadership(p_new_leader_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_guild_id uuid;
  my_role text;
  target_role text;
begin
  select gm.guild_id, gm.role into my_guild_id, my_role from guild_members gm where gm.profile_id = auth.uid();
  if my_guild_id is null then raise exception 'you are not in a guild'; end if;
  if my_role <> 'leader' then raise exception 'only the guild leader can transfer leadership'; end if;
  if p_new_leader_id = auth.uid() then raise exception 'you are already the leader'; end if;

  select role into target_role from guild_members where guild_id = my_guild_id and profile_id = p_new_leader_id;
  if target_role is null then raise exception 'that player is not in your guild'; end if;

  -- outgoing leader steps down to officer rather than plain member — they
  -- just ran the guild, no reason to drop them straight to the bottom rank
  update guild_members set role = 'officer' where guild_id = my_guild_id and profile_id = auth.uid();
  update guild_members set role = 'leader' where guild_id = my_guild_id and profile_id = p_new_leader_id;
  update guilds set leader_id = p_new_leader_id where id = my_guild_id;
end;
$$;

create or replace function disband_guild()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_guild_id uuid;
  my_role text;
begin
  select gm.guild_id, gm.role into my_guild_id, my_role from guild_members gm where gm.profile_id = auth.uid();
  if my_guild_id is null then raise exception 'you are not in a guild'; end if;
  if my_role <> 'leader' then raise exception 'only the guild leader can disband the guild'; end if;

  delete from guilds where id = my_guild_id; -- cascades to guild_members, guild_bosses, guild_boss_damage_log
end;
$$;

-- ----------------------------------------------------------------------------
-- 7. Chat & whispers
-- ----------------------------------------------------------------------------

create or replace function post_chat_message(p_channel text, p_body text)
returns chat_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  msg chat_messages%rowtype;
  last_msg_at timestamptz;
  min_gap interval := interval '2 seconds'; -- TUNE: per-user chat rate limit
begin
  if p_channel <> 'global' then
    if not exists (
      select 1 from guild_members
      where profile_id = auth.uid() and 'guild:' || guild_id::text = p_channel
    ) then
      raise exception 'not a member of that guild channel';
    end if;
  end if;

  select max(created_at) into last_msg_at
    from chat_messages where sender_id = auth.uid() and channel = p_channel;
  if last_msg_at is not null and last_msg_at + min_gap > now() then
    raise exception 'you are sending messages too fast';
  end if;

  insert into chat_messages (channel, sender_id, body) values (p_channel, auth.uid(), p_body)
  returning * into msg;

  return msg;
end;
$$;

create or replace function send_whisper(p_recipient_username text, p_body text)
returns whispers
language plpgsql
security definer
set search_path = public
as $$
declare
  recipient_id uuid;
  w whispers%rowtype;
begin
  select id into recipient_id from profiles where lower(username) = lower(p_recipient_username);
  if not found then raise exception 'no such player'; end if;
  if recipient_id = auth.uid() then raise exception 'cannot whisper yourself'; end if;

  insert into whispers (sender_id, recipient_id, body) values (auth.uid(), recipient_id, p_body)
  returning * into w;

  return w;
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. /send — gold and items, with logging, cooldown and daily caps
-- ----------------------------------------------------------------------------

create or replace function send_gold(p_recipient_username text, p_amount bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  recipient_id uuid;
  sender_gold bigint;
  cooldown interval := interval '5 seconds';   -- TUNE
  daily_cap bigint := 1000000;                 -- TUNE
  sent_today bigint;
  last_transfer_at timestamptz;
begin
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  select id into recipient_id from profiles where lower(username) = lower(p_recipient_username);
  if not found then raise exception 'no such player'; end if;
  if recipient_id = auth.uid() then raise exception 'cannot send to yourself'; end if;

  select max(created_at) into last_transfer_at from item_transfers where sender_id = auth.uid();
  if last_transfer_at is not null and last_transfer_at + cooldown > now() then
    raise exception 'sending too fast, slow down';
  end if;

  select coalesce(sum(gold_amount), 0) into sent_today
    from item_transfers
    where sender_id = auth.uid() and gold_amount is not null and created_at > now() - interval '24 hours';
  if sent_today + p_amount > daily_cap then
    raise exception 'daily send limit reached';
  end if;

  select gold into sender_gold from profiles where id = auth.uid() for update;
  if sender_gold < p_amount then raise exception 'not enough gold'; end if;

  update profiles set gold = gold - p_amount where id = auth.uid();
  update profiles set gold = gold + p_amount where id = recipient_id;

  insert into item_transfers (sender_id, recipient_id, gold_amount) values (auth.uid(), recipient_id, p_amount);
end;
$$;

create or replace function send_item(p_recipient_username text, p_item_key text, p_quantity int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  recipient_id uuid;
  target_item_id uuid;
  have_qty int;
  cooldown interval := interval '5 seconds'; -- TUNE
  last_transfer_at timestamptz;
begin
  if p_quantity <= 0 then raise exception 'quantity must be positive'; end if;

  select id into recipient_id from profiles where lower(username) = lower(p_recipient_username);
  if not found then raise exception 'no such player'; end if;
  if recipient_id = auth.uid() then raise exception 'cannot send to yourself'; end if;

  select id into target_item_id from items where key = p_item_key;
  if not found then raise exception 'no such item'; end if;

  select max(created_at) into last_transfer_at from item_transfers where sender_id = auth.uid();
  if last_transfer_at is not null and last_transfer_at + cooldown > now() then
    raise exception 'sending too fast, slow down';
  end if;

  select quantity into have_qty from inventory where profile_id = auth.uid() and item_id = target_item_id for update;
  if have_qty is null or have_qty < p_quantity then raise exception 'not enough of that item'; end if;

  update inventory set quantity = quantity - p_quantity where profile_id = auth.uid() and item_id = target_item_id;

  insert into inventory (profile_id, item_id, quantity) values (recipient_id, target_item_id, p_quantity)
    on conflict (profile_id, item_id) do update set quantity = inventory.quantity + excluded.quantity;

  insert into item_transfers (sender_id, recipient_id, item_id, quantity)
    values (auth.uid(), recipient_id, target_item_id, p_quantity);
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. Realtime: expose chat, whispers and boss HP to Supabase Realtime
-- ----------------------------------------------------------------------------

-- "alter publication ... add table" errors if the table is already a
-- member, so guard each one (also needed for re-running this file safely)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table chat_messages;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'whispers'
  ) then
    alter publication supabase_realtime add table whispers;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'guild_bosses'
  ) then
    alter publication supabase_realtime add table guild_bosses;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 10. Seed a few starter items so /send has something to test with
-- ----------------------------------------------------------------------------

insert into items (key, name, description, rarity, item_type, base_value) values
  ('rusty_shard',   'Rusty Abyssal Shard Fragment', 'A dull fragment. Barely worth anything, but it''s something.', 'common', 'material', 1),
  ('torchstone',    'Torchstone',                   'Glows faintly even in the deepest dark.', 'uncommon', 'material', 10),
  ('echo_charm',    'Echo Charm',                    'Hums with a voice that isn''t yours.', 'rare', 'trinket', 50)
on conflict (key) do nothing;

-- The mob roster the "Current Battle" panel draws from. Real content now
-- (replacing the single always-on test enemy this used to be) -- roll_pack()
-- picks a random eligible row PER PACK MEMBER (see there), not one enemy
-- for the whole pack, so even a single fight mixes species. Base stats are
-- deliberately kept in the same rough band across the whole roster --
-- min_depth is a variety/flavor gate (what CAN show up), never a power
-- gate (how hard it hits); all real difficulty still comes from tier +
-- depth_mult + spawn variance in enemy_effective_stats(), uniformly, no
-- matter which key got picked. 'test_rat' keeps its original key (existing
-- player_combat rows/history reference it by key inside pack jsonb, not a
-- live FK, but no reason to break it) even though the display name moved
-- on from the dev-placeholder "Test Rat". "on conflict do update" so
-- re-running this file after a numbers/roster tweak actually applies it.
insert into enemies (key, name, max_hp, attack, defense, xp_reward, gold_reward, speed, min_depth) values
  ('test_rat',         'Abyssal Rat',      20, 2, 0, 5, 2, 1, 0),
  ('rift_skitterling', 'Rift Skitterling', 10, 2, 0, 4, 2, 3, 0),
  ('gloomfen_leech',   'Gloomfen Leech',   14, 4, 0, 6, 3, 1, 0),
  ('void_moth',        'Void Moth',        16, 2, 0, 6, 3, 3, 1),
  ('marrow_hound',     'Marrow Hound',     22, 3, 1, 7, 3, 2, 2),
  ('ironshell_grub',   'Ironshell Grub',   34, 1, 3, 6, 2, 1, 2),
  ('whispering_husk',  'Whispering Husk',  28, 2, 2, 7, 3, 1, 4),
  ('umbral_wraith',    'Umbral Wraith',    26, 3, 2, 8, 4, 2, 6)
on conflict (key) do update set
  name = excluded.name, max_hp = excluded.max_hp, attack = excluded.attack,
  defense = excluded.defense, xp_reward = excluded.xp_reward,
  gold_reward = excluded.gold_reward, speed = excluded.speed,
  min_depth = excluded.min_depth;

-- v1-v2 affix/debuff content. All pure stat-mod bundles (see
-- compute_damage's key vocabulary) so adding more later, or moving these to
-- gear, never requires touching the combat loop itself — just another row.
-- "on conflict do update" so re-running this file after a numbers tweak
-- here actually applies it, rather than being silently skipped forever.
--
-- Affixes are enemy-side only (folded into enemy_mods, read as p_atk_mods
-- when an enemy hits the player and as p_def_mods when the player hits an
-- enemy — see strike_enemy()), so they're restricted to the keys
-- compute_damage()/apply_hp_mod() actually read: attack_pct, attack_flat,
-- damage_pct, damage_reduction_pct, defense_pct, crit_chance_flat,
-- crit_damage_flat, hp_pct. multi_strike_flat/attack_speed_pct/evasion_flat/
-- speed_pct are
-- deliberately never used on an affix — strike_enemy() only ever reads
-- those four out of player_mods (see the class-bonus comment below), so on
-- an affix they'd silently do nothing. Values below are tuned against the
-- current early-game baseline
-- (profiles default: attack 8, defense 6, max_hp 30; test_rat base: attack
-- 2, defense 0, max_hp 20) scaled by tier (normal/elite/champion =
-- 1.0/1.25/1.5x) and the chosen Banishment bracket (sqrt ramp) — see
-- enemy_effective_stats(). Single-stat affixes sit at roughly the same
-- weight as the original five; the newer ones layer two smaller stats
-- together instead of one big one, so stacking several affixes at once
-- still feels distinct rather than just "everything +30%" five times over.
insert into affix_defs (key, name, description, mods) values
  ('enraged',        'Enraged',         'Enemies hit significantly harder.',
    '{"attack_pct": 30}'::jsonb),
  ('fortified',       'Fortified',       'Enemies mitigate much more damage.',
    '{"defense_pct": 35}'::jsonb),
  ('vicious',         'Vicious',         'Enemies deal extra damage on every hit.',
    '{"damage_pct": 25}'::jsonb),
  ('resilient',       'Resilient',       'Enemies have much more health.',
    '{"hp_pct": 50}'::jsonb),
  ('deadly',          'Deadly',          'Enemies have a real chance to crit.',
    '{"crit_chance_flat": 20}'::jsonb),
  -- Voidscarred is a flat (not %) attack bump — its own weapon carries a
  -- fixed extra bite regardless of the enemy's scaled attack, so it matters
  -- most at low brackets/tiers and fades toward irrelevant at very high
  -- ones, unlike every %-based affix here which stays proportionally
  -- meaningful forever. Against a fresh player's base defense 6, +3 flat on
  -- a tier-1 test_rat (eff_attack 2) roughly triples its bite.
  ('voidscarred',     'Voidscarred',     'Enemies'' weapons are void-forged, adding a small flat bite to every hit.',
    '{"attack_flat": 3}'::jsonb),
  -- damage_reduction_pct on the enemy side is read as p_def_mods when the
  -- PLAYER attacks, so this cuts into the player's own outgoing damage —
  -- the enemy-side mirror of Fortified's defense_pct, but via the
  -- multiplicative damage_pct/damage_reduction_pct term instead of the
  -- mitigation ratio, so it stacks distinctly with Fortified rather than
  -- just being a second copy of it.
  ('blackened_hide',  'Blackened Hide',  'Enemies shrug off a portion of all damage taken.',
    '{"damage_reduction_pct": 20}'::jsonb),
  ('ravenous',         'Ravenous',        'Enemies crit more often and hit harder when they do.',
    '{"crit_chance_flat": 15, "damage_pct": 10}'::jsonb),
  ('hollow_carapace',  'Hollow Carapace', 'Enemies are tougher and far harder to put down.',
    '{"defense_pct": 25, "hp_pct": 20}'::jsonb),
  ('voidtouched',      'Voidtouched',     'Enemies strike harder and crit more often.',
    '{"attack_pct": 20, "crit_chance_flat": 10}'::jsonb),
  ('maw_of_the_deep',  'Maw of the Deep', 'Enemies have enormous health and a small extra bite.',
    '{"hp_pct": 75, "attack_flat": 4}'::jsonb)
on conflict (key) do update set name = excluded.name, description = excluded.description, mods = excluded.mods;

-- Debuffs are player-side (folded into player_mods, alongside the class
-- bonus), so — unlike affixes — they CAN use multi_strike_flat,
-- attack_speed_pct, evasion_flat, and speed_pct, since strike_enemy() reads
-- all four of those straight out of player_mods (see the class-bonus
-- comment below). Magnitudes are kept in the same range as the original
-- four (roughly -10 to -25) so no single new debuff swings a fight harder
-- than picking one of the originals would.
insert into debuff_defs (key, name, description, mods) values
  ('weakened',        'Weakened',         'Your Power is reduced for this fight.',
    '{"attack_pct": -20}'::jsonb),
  ('exposed',         'Exposed',          'Your Defense is reduced for this fight.',
    '{"defense_pct": -25}'::jsonb),
  ('fragile',         'Fragile',          'Your max HP is reduced for this fight.',
    '{"hp_pct": -20}'::jsonb),
  ('clumsy',          'Clumsy',           'Your Crit chance is reduced for this fight.',
    '{"crit_chance_flat": -10}'::jsonb),
  ('voidbound',        'Voidbound',        'Your Multi Strike is reduced for this fight.',
    '{"multi_strike_flat": -15}'::jsonb),
  ('chilled_blood',    'Chilled Blood',    'Your Attack Speed is reduced for this fight.',
    '{"attack_speed_pct": -15}'::jsonb),
  -- The one debuff that reads damage_reduction_pct as the DEFENDER (the
  -- player): compute_damage() subtracts p_def_mods.damage_reduction_pct, so
  -- a NEGATIVE value here increases the multiplier above 1.0 instead of
  -- reducing it — i.e. this is "take extra damage", the mirror image of
  -- Blackened Hide above, reusing the same key rather than adding a new one.
  ('marked_by_the_deep', 'Marked by the Deep', 'You take extra damage for this fight.',
    '{"damage_reduction_pct": -15}'::jsonb),
  ('sundered_grip',    'Sundered Grip',    'Your damage dealt is reduced for this fight.',
    '{"damage_pct": -15}'::jsonb),
  ('sapped',           'Sapped',           'Your Power and Defense are both reduced for this fight.',
    '{"attack_pct": -10, "defense_pct": -10}'::jsonb)
on conflict (key) do update set name = excluded.name, description = excluded.description, mods = excluded.mods;

-- Starting class bonuses. These are permanent, always-active modifier
-- bundles (same vocabulary compute_damage()/strike_enemy() already read for
-- affixes/debuffs) merged into player_mods on every strike_enemy() call,
-- keyed off profiles.class — NOT applied to the profiles.attack/defense/
-- max_hp/crit/multi_strike columns themselves. Every class shares the same
-- base columns; the bonus only ever shows up in combat math. That's
-- deliberate: applying the bonus at combat-resolution time means it's real
-- immediately (crit/multi-strike/attack-speed bonuses especially, since
-- those start at 0/1.0) and it keeps scaling correctly forever as
-- attack/defense/hp grow from Banishment retention and (eventually) gear,
-- with zero extra plumbing — and it's why the profiles.attack/defense/
-- max_hp baseline just above was raised from 1/1/10 to 8/6/30: large enough
-- that a +5-20% bonus actually shows up in the rounded output from level 1,
-- not just once those columns have grown from later progression.
-- multi_strike_flat is a flat percentage-point add to profiles.multi_strike
-- — Multi Strike's roll happens directly in strike_enemy() rather than
-- inside compute_damage(), so it's read there explicitly rather than via
-- compute_damage's p_atk_mods. attack_speed_pct works the same way, read
-- directly in strike_enemy() to scale the pack round budget. evasion_flat
-- (added on top of the player's raw Speed, both hard-capped at 25%
-- combined) and speed_pct (a % bonus to Speed itself, feeding both
-- evasion and initiative) are the newest two of this "read directly in
-- strike_enemy(), not via compute_damage()" family — see
-- cur_player_evasion_pct/cur_player_speed there.
-- Each class now also carries a permanent drawback (same modifier bundle,
-- just a negative entry alongside the positives) so no class is a strictly
-- free upgrade over the others -- every kit trades something away for its
-- strengths. As gear/Banishment later push the underlying base stats up,
-- each class's flat percentages (positive AND negative) become
-- correspondingly stronger in absolute terms with no extra work, which is
-- the whole point of doing this as a percent modifier rather than a fixed
-- bonus/penalty.
insert into class_defs (key, name, description, mods) values
  ('warrior', 'Warrior', '+5% HP, +5% Defense, +5% Power, -25% Speed',
    '{"hp_pct": 5, "defense_pct": 5, "attack_pct": 5, "speed_pct": -25}'::jsonb),
  ('archer',  'Archer',  '+10% Crit, +10% Power, +5% Attack Speed, -30% Defense',
    '{"crit_chance_flat": 10, "attack_pct": 10, "attack_speed_pct": 5, "defense_pct": -30}'::jsonb),
  ('magi',    'Magi',    '+10% Multi Strike, +10% Crit, +5% Power, +5% HP, -40% Defense',
    '{"multi_strike_flat": 10, "crit_chance_flat": 10, "attack_pct": 5, "hp_pct": 5, "defense_pct": -40}'::jsonb),
  ('striker', 'Striker', '+20% Multi Strike, +20% Crit, +5% Attack Speed, -40% Defense',
    '{"multi_strike_flat": 20, "crit_chance_flat": 20, "attack_speed_pct": 5, "defense_pct": -40}'::jsonb)
on conflict (key) do update set name = excluded.name, description = excluded.description, mods = excluded.mods;
