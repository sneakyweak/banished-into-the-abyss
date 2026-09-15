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
  abyssal_prowess  bigint not null default 0,     -- prestige currency, earned via Banishment (see perform_banishment)
  class            text not null default 'warrior' check (class in ('warrior','archer','magi','striker')),
  depth            int not null default 0,         -- prestige tier ("how deep")
  hp               int not null default 10,         -- current hp (solo combat)
  max_hp           int not null default 10,
  attack           int not null default 1,
  defense          int not null default 5,
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

-- rename the old "shards" column to "abyssal_prowess" (same values, clearer
-- name now that it's the currency driving Banishment's retention tiers).
-- Guarded so this is a no-op both on a project that's already been renamed
-- and on a brand new project (whose CREATE TABLE above already names the
-- column abyssal_prowess directly).
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'shards'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'abyssal_prowess'
  ) then
    alter table profiles rename column shards to abyssal_prowess;
  end if;
end $$;
alter table profiles add column if not exists abyssal_prowess bigint not null default 0;

-- Combat Stats panel — Power/Defense already existed as attack/defense;
-- these four are new. Gear-driven, so they sit at these defaults until an
-- items/relics system that grants them exists.
alter table profiles add column if not exists attack_speed numeric not null default 1.0;
alter table profiles add column if not exists crit numeric not null default 0;
alter table profiles add column if not exists multi_strike numeric not null default 0;
alter table profiles add column if not exists speed int not null default 1;

-- base stat rebalance: Power (attack) 10 -> 1, Crit 5% -> 0%, Speed 10 -> 1
-- (a deliberate difficulty change). Same "add column if not exists is a
-- no-op on an already-deployed table" trap as hp above — the column
-- defaults above only take effect for a table created fresh by this file,
-- so the actual default has to be changed explicitly for a project that's
-- already deployed.
alter table profiles alter column attack set default 1;
alter table profiles alter column crit set default 0;
alter table profiles alter column speed set default 1;

-- retroactively apply the new baseline to any EXISTING character still at
-- the old untouched defaults. Guarded per-column (not all three at once)
-- so a character that's, say, banished and picked up bonus attack but
-- never touched crit/speed still gets those two reset. Never touches a
-- stat that's already moved off its old default (e.g. attack raised via
-- Banishment retention); safe to re-run since those rows no longer match
-- after the first pass.
update profiles set attack = 1 where attack = 10;
update profiles set crit = 0 where crit = 5;
update profiles set speed = 1 where speed = 10;

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

-- solo enemies: a small standalone catalog for testing the combat panel
-- (separate from guild_bosses, which are per-guild and idle-fed). A player
-- fights one enemy at a time; player_combat tracks that enemy's current hp.
create table if not exists enemies (
  key          text primary key,
  name         text not null,
  max_hp       int not null,
  attack       int not null default 1,
  defense      int not null default 0,  -- mitigates the player's damage per swing (see strike_enemy)
  xp_reward    int not null default 0,
  gold_reward  int not null default 0
);
alter table enemies add column if not exists defense int not null default 0;
-- "level" (added for the previous rounds-scale-with-enemy-level design,
-- since superseded by attack_speed-driven round counts + elite/champion
-- tiers below) never shipped past one iteration — drop it if a project ran
-- that version of this file.
alter table enemies drop column if exists level;

create table if not exists player_combat (
  profile_id     uuid primary key references profiles(id) on delete cascade,
  enemy_key      text not null references enemies(key),
  enemy_hp       int not null,
  enemy_tier     text not null default 'normal' check (enemy_tier in ('normal', 'elite', 'champion')),
  updated_at     timestamptz not null default now(),
  last_strike_at timestamptz -- null until the player's first real strike; kept
                              -- separate from updated_at so spawning/respawning
                              -- an enemy never itself looks like a recent strike
);
alter table player_combat add column if not exists enemy_tier text not null default 'normal'
  check (enemy_tier in ('normal', 'elite', 'champion'));

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
-- 3. New-user signup -> profile row
--    Client passes the chosen username in auth signUp's options.data.username.
--    Players never enter an email: the client (web/js/app.js) derives one
--    from the username ("name@banished-abyss.invalid") so Supabase's normal
--    email/password auth can be used under the hood. This REQUIRES turning
--    off "Confirm email" in Authentication -> Settings, since no
--    confirmation link could ever reach a .invalid address.
-- ----------------------------------------------------------------------------

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen_class text;
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
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ----------------------------------------------------------------------------
-- 4. Idle tick resolution
--    Called by the client whenever it's convenient (page load, every few
--    minutes while open, etc). Grants XP/gold for elapsed real time since
--    last_tick_at, capped so offline time can't be farmed indefinitely, then
--    feeds a slice of that XP to the player's guild boss as passive damage.
--    Tune the constants marked TUNE once you have something playable.
-- ----------------------------------------------------------------------------

create or replace function perform_idle_tick()
returns table (xp_gained bigint, gold_gained bigint, new_level int, boss_damage bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
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
begin
  select * into p from profiles where id = auth.uid();
  if not found then
    raise exception 'no profile for current user';
  end if;

  elapsed_seconds := least(extract(epoch from (now() - p.last_tick_at))::bigint, max_offline_seconds);
  if elapsed_seconds <= 0 then
    return query select 0::bigint, 0::bigint, p.level, 0::bigint;
    return;
  end if;

  depth_multiplier := 1 + (p.depth * 0.5); -- TUNE: each Depth is +50% base income
  gained_xp := floor(elapsed_seconds * xp_per_second * depth_multiplier);
  gained_gold := floor(elapsed_seconds * gold_per_second * depth_multiplier);

  lvl := greatest(1, floor(sqrt((p.xp + gained_xp) / 100.0))::int); -- TUNE: level curve

  update profiles
    set xp = xp + gained_xp,
        gold = gold + gained_gold,
        level = lvl,
        last_tick_at = now(),
        last_active_at = now()
    where id = p.id;

  -- guild bosses are disabled for now — no idle damage is fed to them.
  return query select gained_xp, gained_gold, lvl, dmg;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4b. Action points
--    Every character starts at 3000/3000. Nothing spends them yet (no
--    action cost is wired into any RPC below) — this is just the pool and
--    the manual "refresh" the player clicks to top back up to max_actions.
--    There's deliberately no cooldown on refresh_actions() yet: since
--    nothing costs actions right now, refreshing has no effect to limit.
--    Once training/delving/crafting (see DESIGN.md) actually spend from
--    this pool, refresh should probably get gated (a cooldown, a real-time
--    regen rate, or a gold cost) or the pool stops meaning anything.
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
-- 4c. Solo enemy combat (test rat)
--    A minimal player-vs-mob loop to drive the Current Battle panel outside
--    of guild bosses: one enemy at a time, tracked in player_combat.
--    get_or_spawn_player_enemy() creates/respawns the fight; strike_enemy()
--    is called automatically once per client idle-tick (every 8s, see
--    app.js doTick()) rather than from a manual button.
--
--    Action cost is flat: one fight-tick = 1 action, full stop — however
--    many rounds that fight takes doesn't change the cost. What DOES scale
--    with rounds is how much punishment a single action buys you: each
--    fight resolves a whole round-robin exchange (up to 100 rounds, hard
--    capped so one DB call can't run unbounded work), and how many rounds
--    run is driven by the player's Attack Speed stat — attack_speed 1.0
--    (the default) resolves 10 rounds; a faster attacker gets more swings
--    for the same action. Every round rolls real combat math off the
--    Combat Stats panel: Power vs. the enemy's Defense for base damage,
--    Crit for a double-damage chance, Multi Strike for a chance at a
--    second swing in the same round, and the enemy's (tier-scaled) Attack
--    vs. the player's Defense for the counter-hit. Speed isn't wired into
--    combat yet — noted as a TUNE spot alongside the rest of these numbers
--    once this gets playtested.
--
--    Elite/Champion tiers: every time an enemy spawns or respawns
--    (including mid-fight, when a kill immediately queues up the next
--    encounter within the same round-robin) roll_enemy_tier() picks
--    normal/elite/champion at 85%/10%/5%, and enemy_effective_stats()
--    scales that enemy's stats and rewards by 1x/1.25x/1.5x accordingly —
--    tougher, and worth more xp/gold, so drops from a lucky Champion spawn
--    actually feel different. This is entirely separate from
--    perform_idle_tick()'s passive xp/gold, which is time-based and keeps
--    accruing offline regardless of actions — only this auto-strike loop
--    is action-gated (and, per the above, at a flat 1 action regardless of
--    how the fight goes).
--
--    Every individual battle (one player vs. one spawned enemy) always
--    runs to a real conclusion — someone dies — rather than being cut off
--    partway through by the tick's round budget. That budget (rounds_to_run
--    below, driven by Attack Speed) decides how many NEW battles get
--    started this tick, but once a battle is underway it's always allowed
--    to finish, so the round count can run a little over budget for the
--    last one. A hard, unconditional ceiling (rounds_hard_cap) still
--    bounds the absolute worst case so this function can never hang — in
--    practice, with damage always flooring at 1 and both sides' hp finite,
--    real fights finish long before that ceiling matters. A player "death"
--    (hp hits 0) ends that battle exactly like a kill does — tallied,
--    reported to the client as a real event, and the encounter respawns
--    fresh — but still carries no other penalty (no xp/gold/item loss, full
--    heal after) — a TUNE spot once that becomes a real feature.
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

-- shared by get_or_spawn_player_enemy() and strike_enemy() so the
-- elite/champion multiplier math lives in exactly one place. Not itself
-- exposed as a player action, but callable like any function (it's
-- read-only/stable, so that's harmless).
create or replace function enemy_effective_stats(p_enemy_key text, p_tier text)
returns table (
  display_name text,
  eff_max_hp int,
  eff_attack int,
  eff_defense int,
  eff_xp int,
  eff_gold int
)
language plpgsql
stable
set search_path = public
as $$
declare
  e enemies%rowtype;
  mult numeric;
  prefix text;
begin
  select * into e from enemies where key = p_enemy_key;
  if not found then raise exception 'no such enemy'; end if;

  mult := case p_tier when 'champion' then 1.5 when 'elite' then 1.25 else 1.0 end; -- TUNE
  prefix := case p_tier when 'champion' then 'Champion ' when 'elite' then 'Elite ' else '' end;

  return query select
    prefix || e.name,
    ceil(e.max_hp * mult)::int,
    ceil(e.attack * mult)::int,
    ceil(e.defense * mult)::int,
    ceil(e.xp_reward * mult)::int,
    ceil(e.gold_reward * mult)::int;
end;
$$;

-- Postgres can't CREATE OR REPLACE a function onto a different return
-- signature — a project that already ran an earlier version of this file
-- (before display_name/tier existed below, or before that, player_combat)
-- needs the old one dropped first, or this whole statement fails with
-- "cannot change return type of existing function". Safe no-op on a
-- project that's never defined it.
drop function if exists get_or_spawn_player_enemy(text);

create or replace function get_or_spawn_player_enemy(p_enemy_key text default 'test_rat')
returns table (
  enemy_key text,
  display_name text,
  tier text,
  enemy_hp int,
  enemy_max_hp int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  pc player_combat%rowtype;
  stats record;
  new_tier text;
begin
  if not exists (select 1 from enemies where key = p_enemy_key) then
    raise exception 'no such enemy';
  end if;

  select * into pc from player_combat where profile_id = auth.uid();

  if not found then
    new_tier := roll_enemy_tier();
    select * into stats from enemy_effective_stats(p_enemy_key, new_tier);
    insert into player_combat (profile_id, enemy_key, enemy_hp, enemy_tier)
      values (auth.uid(), p_enemy_key, stats.eff_max_hp, new_tier)
      returning * into pc;
  elsif pc.enemy_key <> p_enemy_key or pc.enemy_hp <= 0 then
    new_tier := roll_enemy_tier();
    select * into stats from enemy_effective_stats(p_enemy_key, new_tier);
    update player_combat
      set enemy_key = p_enemy_key, enemy_hp = stats.eff_max_hp, enemy_tier = new_tier, updated_at = now()
      where profile_id = auth.uid()
      returning * into pc;
  else
    select * into stats from enemy_effective_stats(pc.enemy_key, pc.enemy_tier);
  end if;

  return query select pc.enemy_key, stats.display_name, pc.enemy_tier, pc.enemy_hp, stats.eff_max_hp;
end;
$$;

-- same reasoning as the drop above this signature has changed more than
-- once now (single-swing -> level-driven rounds -> this).
drop function if exists strike_enemy(text);

create or replace function strike_enemy(p_enemy_key text default 'test_rat')
returns table (
  rounds_fought int,
  damage_dealt int,
  kills int,
  deaths int,
  enemy_hp int,
  enemy_max_hp int,
  enemy_name text,
  player_hp int,
  player_max_hp int,
  xp_gained int,
  gold_gained int,
  actions_left int,
  out_of_actions boolean,
  rounds_log jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  pc player_combat%rowtype;
  stats record;
  cooldown interval := interval '1 second'; -- TUNE: just enough to stop double-fires
  action_cost int := 1;        -- flat per fight-tick, regardless of how many rounds it takes
  base_rounds int := 10;       -- TUNE: new-battle budget at attack_speed = 1.0 (the default)
  rounds_soft_budget int;      -- once crossed, no NEW battle starts — but the current one still finishes
  rounds_hard_cap int := 25;   -- absolute ceiling across the whole call so this can never hang
  rounds_run int := 0;
  hit_dmg int;
  was_crit boolean;
  cur_enemy_hp int;
  cur_enemy_max_hp int;
  cur_tier text;
  cur_enemy_name text;
  cur_player_hp int;
  cur_actions int;
  total_damage int := 0;
  total_kills int := 0;
  total_deaths int := 0;
  total_xp int := 0;
  total_gold int := 0;
  -- one entry per round actually fought, in order, so the client can play
  -- combat back round-by-round instead of only ever seeing the state after
  -- everything (including any kill/death respawn) has already resolved —
  -- that end-state snapshot is what made the hp bars look like they were
  -- never taking damage. Each entry reflects hp right after that round's
  -- blows, BEFORE any kill/death respawn resets things for the next battle.
  -- "hits" carries every individual blow landed THIS round (source,
  -- damage, crit, multi_strike) so the client can render real combat text
  -- ("you hit for 5, crit!") instead of just an end-of-fight summary.
  round_log jsonb := '[]'::jsonb;
  round_hits jsonb;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  if not exists (select 1 from enemies where key = p_enemy_key) then
    raise exception 'no such enemy';
  end if;

  perform get_or_spawn_player_enemy(p_enemy_key); -- ensures a fight (and tier) exists
  select * into pc from player_combat where profile_id = auth.uid();
  select * into stats from enemy_effective_stats(pc.enemy_key, pc.enemy_tier);

  -- this now fires automatically every idle tick (unattended), so both the
  -- "out of actions" and "on cooldown" cases return a quiet no-op row
  -- instead of raising — an exception every 8s would just spam the client.
  if p.actions < action_cost then
    return query select 0, 0, 0, 0, pc.enemy_hp, stats.eff_max_hp, stats.display_name, p.hp, p.max_hp, 0, 0, p.actions, true, '[]'::jsonb;
    return;
  end if;

  if pc.last_strike_at is not null and pc.last_strike_at + cooldown > now() then
    return query select 0, 0, 0, 0, pc.enemy_hp, stats.eff_max_hp, stats.display_name, p.hp, p.max_hp, 0, 0, p.actions, false, '[]'::jsonb;
    return;
  end if;

  rounds_soft_budget := greatest(1, round(base_rounds * p.attack_speed)::int);

  cur_tier := pc.enemy_tier;
  cur_enemy_hp := pc.enemy_hp;
  cur_enemy_max_hp := stats.eff_max_hp;
  cur_enemy_name := stats.display_name;
  cur_player_hp := p.hp;
  cur_actions := p.actions - action_cost; -- spent once, up front, no matter how the fight goes

  -- outer loop: one iteration per BATTLE. Only starts a new battle while
  -- under the soft budget; once a battle starts, the inner loop always
  -- runs it to a real resolution (a kill or a death), never breaking off
  -- partway through just because the budget ran out mid-fight.
  <<battles>>
  loop
    exit battles when rounds_run >= rounds_soft_budget or rounds_run >= rounds_hard_cap;

    <<exchanges>>
    loop
      exit battles when rounds_run >= rounds_hard_cap; -- absolute safety valve, even mid-battle
      rounds_run := rounds_run + 1;
      round_hits := '[]'::jsonb;

      -- player's swing: Power vs. the enemy's (tier-scaled) Defense, with a
      -- Crit chance to double it
      hit_dmg := greatest(1, p.attack - stats.eff_defense);
      was_crit := random() < (p.crit / 100.0);
      if was_crit then hit_dmg := hit_dmg * 2; end if;
      cur_enemy_hp := greatest(0, cur_enemy_hp - hit_dmg);
      total_damage := total_damage + hit_dmg;
      round_hits := round_hits || jsonb_build_array(jsonb_build_object(
        'source', 'player', 'dmg', hit_dmg, 'crit', was_crit, 'multi_strike', false
      ));

      -- Multi Strike: a chance of a second swing landing in the same round
      if cur_enemy_hp > 0 and random() < (p.multi_strike / 100.0) then
        hit_dmg := greatest(1, p.attack - stats.eff_defense);
        was_crit := random() < (p.crit / 100.0);
        if was_crit then hit_dmg := hit_dmg * 2; end if;
        cur_enemy_hp := greatest(0, cur_enemy_hp - hit_dmg);
        total_damage := total_damage + hit_dmg;
        round_hits := round_hits || jsonb_build_array(jsonb_build_object(
          'source', 'player', 'dmg', hit_dmg, 'crit', was_crit, 'multi_strike', true
        ));
      end if;

      if cur_enemy_hp <= 0 then
        -- battle resolved: the enemy died. The player's hp CARRIES OVER
        -- (no free heal on a kill) — a kill fully resolves within the same
        -- RPC call as the rest of the fight, so healing to full here made
        -- the player's hp bar snap back to full on almost every tick and
        -- never visibly drain. Only an actual death (below) resets it.
        -- Log this round against the enemy that was actually just fought
        -- (name/max hp before it gets replaced by the next spawn below).
        round_log := round_log || jsonb_build_array(jsonb_build_object(
          'hits', round_hits,
          'enemy_hp', 0, 'enemy_max_hp', cur_enemy_max_hp, 'enemy_name', cur_enemy_name,
          'player_hp', cur_player_hp, 'player_max_hp', p.max_hp, 'event', 'kill',
          'xp_gained', stats.eff_xp, 'gold_gained', stats.eff_gold
        ));

        total_kills := total_kills + 1;
        total_xp := total_xp + stats.eff_xp;
        total_gold := total_gold + stats.eff_gold;

        cur_tier := roll_enemy_tier();
        select * into stats from enemy_effective_stats(p_enemy_key, cur_tier);
        cur_enemy_hp := stats.eff_max_hp;
        cur_enemy_max_hp := stats.eff_max_hp;
        cur_enemy_name := stats.display_name;
        exit exchanges; -- back to the battles loop to decide whether to start another
      end if;

      -- enemy's counter-swing: its (tier-scaled) Attack vs. the player's Defense
      hit_dmg := greatest(1, stats.eff_attack - p.defense);
      cur_player_hp := greatest(0, cur_player_hp - hit_dmg);
      round_hits := round_hits || jsonb_build_array(jsonb_build_object(
        'source', 'enemy', 'dmg', hit_dmg, 'crit', false, 'multi_strike', false
      ));
      if cur_player_hp <= 0 then
        -- battle resolved: the player died — still no real penalty (TUNE),
        -- but it's a tracked, reported outcome now, not a silent reset
        round_log := round_log || jsonb_build_array(jsonb_build_object(
          'hits', round_hits,
          'enemy_hp', cur_enemy_hp, 'enemy_max_hp', cur_enemy_max_hp, 'enemy_name', cur_enemy_name,
          'player_hp', 0, 'player_max_hp', p.max_hp, 'event', 'death'
        ));

        total_deaths := total_deaths + 1;
        cur_player_hp := p.max_hp;

        cur_tier := roll_enemy_tier(); -- a fresh foe for the next battle
        select * into stats from enemy_effective_stats(p_enemy_key, cur_tier);
        cur_enemy_hp := stats.eff_max_hp;
        cur_enemy_max_hp := stats.eff_max_hp;
        cur_enemy_name := stats.display_name;
        exit exchanges;
      end if;

      -- an ordinary round: both sides still standing, both hp values carry
      -- straight into the next round with no respawn involved.
      round_log := round_log || jsonb_build_array(jsonb_build_object(
        'hits', round_hits,
        'enemy_hp', cur_enemy_hp, 'enemy_max_hp', cur_enemy_max_hp, 'enemy_name', cur_enemy_name,
        'player_hp', cur_player_hp, 'player_max_hp', p.max_hp, 'event', null
      ));
    end loop exchanges;
  end loop battles;

  update profiles
    set hp = cur_player_hp,
        xp = xp + total_xp,
        gold = gold + total_gold,
        actions = cur_actions
    where id = p.id;

  update player_combat
    set enemy_hp = cur_enemy_hp, enemy_tier = cur_tier, updated_at = now(), last_strike_at = now()
    where profile_id = auth.uid();

  return query select rounds_run, total_damage, total_kills, total_deaths, cur_enemy_hp, cur_enemy_max_hp,
    cur_enemy_name, cur_player_hp, p.max_hp, total_xp, total_gold, cur_actions, false, round_log;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4d. Banishment (prestige)
--    At level 100+ a player may sacrifice their character to the Abyss:
--    level/xp/gold reset and inventory/current-fight state are wiped, but
--    they keep Abyssal Prowess (a permanent meta-currency, +1 Depth per
--    banishment) plus a slice of their current attack/defense/max_hp,
--    sized by how much Abyssal Prowess they'd already banked BEFORE this
--    banishment. Every constant below is a first-pass number — TUNE once
--    this is actually playtested.
-- ----------------------------------------------------------------------------

create table if not exists banishments (
  id              bigint generated always as identity primary key,
  profile_id      uuid not null references profiles(id) on delete cascade,
  level_reached   int not null,
  prowess_gained  bigint not null,
  retained_pct    numeric not null,   -- stored as a percent, e.g. 0.25, 0.5, 0.75, 100
  created_at      timestamptz not null default now()
);
create index if not exists idx_banishments_profile on banishments(profile_id, created_at desc);

alter table banishments enable row level security;
drop policy if exists "banishment history is publicly readable" on banishments;
create policy "banishment history is publicly readable" on banishments for select using (true);

create or replace function perform_banishment()
returns profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  retain_pct numeric;      -- fraction, e.g. 0.0025 for 0.25%
  display_pct numeric;     -- same tier, as the percent number shown to players
  prowess_gain bigint;
  base_attack int := 1;    -- TUNE: matches profiles.attack's default for a fresh character
  base_defense int := 5;   -- TUNE: matches profiles.defense's default
  base_max_hp int := 10;   -- TUNE: matches profiles.max_hp's default
  new_attack int;
  new_defense int;
  new_max_hp int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  if p.level < 100 then
    raise exception 'you must reach level 100 before you can banish your character';
  end if;

  -- retention tier is based on Abyssal Prowess already banked from PAST
  -- banishments, not this one — the more you've banished before, the more
  -- of this run carries into the next.
  if p.abyssal_prowess >= 1001 then
    retain_pct := 1.0;      display_pct := 100;
  elsif p.abyssal_prowess >= 501 then
    retain_pct := 0.0075;   display_pct := 0.75;
  elsif p.abyssal_prowess >= 100 then
    retain_pct := 0.005;    display_pct := 0.50;
  else
    retain_pct := 0.0025;   display_pct := 0.25;
  end if;

  -- TUNE: prowess earned per banishment — simple level-based formula for now
  prowess_gain := greatest(1, floor(p.level / 10.0));

  new_attack  := greatest(base_attack,  base_attack  + floor((p.attack  - base_attack)  * retain_pct));
  new_defense := greatest(base_defense, base_defense + floor((p.defense - base_defense) * retain_pct));
  new_max_hp  := greatest(base_max_hp,  base_max_hp  + floor((p.max_hp  - base_max_hp)  * retain_pct));

  insert into banishments (profile_id, level_reached, prowess_gained, retained_pct)
  values (p.id, p.level, prowess_gain, display_pct);

  update profiles set
    level           = 1,
    xp              = 0,
    gold            = 0,
    depth           = depth + 1,             -- each banishment pushes you one Depth deeper
    abyssal_prowess = abyssal_prowess + prowess_gain,
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

-- a weak, always-available test enemy so the Current Battle panel has
-- something to fight before real mob content exists
insert into enemies (key, name, max_hp, attack, defense, xp_reward, gold_reward) values
  ('test_rat', 'Test Rat', 20, 2, 0, 5, 2)
on conflict (key) do nothing;
