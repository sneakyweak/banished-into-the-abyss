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
  hp               int not null default 100,        -- current hp (solo combat)
  max_hp           int not null default 100,
  attack           int not null default 10,
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
alter table profiles add column if not exists hp int not null default 100;
alter table profiles add column if not exists class text not null default 'warrior'
  check (class in ('warrior','archer','magi','striker'));

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
  xp_reward    int not null default 0,
  gold_reward  int not null default 0
);

create table if not exists player_combat (
  profile_id     uuid primary key references profiles(id) on delete cascade,
  enemy_key      text not null references enemies(key),
  enemy_hp       int not null,
  updated_at     timestamptz not null default now(),
  last_strike_at timestamptz -- null until the player's first real strike; kept
                              -- separate from updated_at so spawning/respawning
                              -- an enemy never itself looks like a recent strike
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
  my_guild_id uuid;
  boss guild_bosses%rowtype;
  dmg bigint := 0;
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

  -- feed a slice of this tick's XP to the active guild boss, if any
  select gm.guild_id into my_guild_id from guild_members gm where gm.profile_id = p.id;
  if my_guild_id is not null then
    boss := get_or_spawn_active_boss(my_guild_id);
    if boss.id is not null then
      dmg := greatest(0, floor(gained_xp * 0.2)); -- TUNE: idle contribution rate
      if dmg > 0 then
        perform apply_boss_damage(boss.id, p.id, dmg, 'idle');
      end if;
    end if;
  end if;

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
--    app.js doTick()) rather than from a manual button — deal damage, take
--    a counter-hit if the enemy survives, and respawn immediately on
--    defeat so there's always something to fight. Each strike costs 1
--    action; once actions hit 0 it returns out_of_actions instead of
--    striking (no exception, since this fires unattended every tick).
--    This is entirely separate from perform_idle_tick()'s passive xp/gold,
--    which is time-based and keeps accruing offline regardless of actions
--    — only the auto-strike loop is action-gated. No real death penalty
--    yet (hp just resets to max) — a TUNE spot once this becomes a real
--    feature.
-- ----------------------------------------------------------------------------

create or replace function get_or_spawn_player_enemy(p_enemy_key text default 'test_rat')
returns player_combat
language plpgsql
security definer
set search_path = public
as $$
declare
  pc player_combat%rowtype;
  e enemies%rowtype;
begin
  select * into e from enemies where key = p_enemy_key;
  if not found then raise exception 'no such enemy'; end if;

  select * into pc from player_combat where profile_id = auth.uid();

  if not found then
    insert into player_combat (profile_id, enemy_key, enemy_hp)
    values (auth.uid(), p_enemy_key, e.max_hp)
    returning * into pc;
    return pc;
  end if;

  if pc.enemy_key <> p_enemy_key or pc.enemy_hp <= 0 then
    update player_combat
      set enemy_key = p_enemy_key, enemy_hp = e.max_hp, updated_at = now()
      where profile_id = auth.uid()
      returning * into pc;
  end if;

  return pc;
end;
$$;

-- Postgres can't CREATE OR REPLACE a function onto a different return
-- signature — a project that already ran an earlier version of this file
-- (before actions_left/out_of_actions existed below) needs the old one
-- dropped first, or this whole statement fails with "cannot change return
-- type of existing function" and the old, un-action-gated strike_enemy
-- stays live. Safe no-op on a project that's never defined it.
drop function if exists strike_enemy(text);

create or replace function strike_enemy(p_enemy_key text default 'test_rat')
returns table (
  damage_dealt int,
  enemy_defeated boolean,
  enemy_hp int,
  enemy_max_hp int,
  player_hp int,
  player_max_hp int,
  xp_gained int,
  gold_gained int,
  actions_left int,
  out_of_actions boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  p profiles%rowtype;
  e enemies%rowtype;
  pc player_combat%rowtype;
  dmg int;
  defeated boolean := false;
  gained_xp int := 0;
  gained_gold int := 0;
  cooldown interval := interval '1 second'; -- TUNE: just enough to stop double-fires
  action_cost int := 1; -- TUNE: actions spent per strike — one per idle-tick auto-strike
  new_player_hp int;
  new_enemy_hp int;
  new_actions int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile'; end if;

  select * into e from enemies where key = p_enemy_key;
  if not found then raise exception 'no such enemy'; end if;

  pc := get_or_spawn_player_enemy(p_enemy_key);

  -- this now fires automatically every idle tick (unattended), so both the
  -- "out of actions" and "on cooldown" cases return a quiet no-op row
  -- instead of raising — an exception every 8s would just spam the client.
  if p.actions < action_cost then
    return query select 0, false, pc.enemy_hp, e.max_hp, p.hp, p.max_hp, 0, 0, p.actions, true;
    return;
  end if;

  if pc.last_strike_at is not null and pc.last_strike_at + cooldown > now() then
    return query select 0, false, pc.enemy_hp, e.max_hp, p.hp, p.max_hp, 0, 0, p.actions, false;
    return;
  end if;

  dmg := greatest(1, p.attack);
  new_enemy_hp := greatest(0, pc.enemy_hp - dmg);

  if new_enemy_hp <= 0 then
    defeated := true;
    gained_xp := e.xp_reward;
    gained_gold := e.gold_reward;
  end if;

  new_player_hp := p.hp;
  if defeated then
    new_player_hp := p.max_hp; -- full heal: a new fight (the respawned enemy) starts fresh
  else
    new_player_hp := greatest(0, p.hp - e.attack);
    if new_player_hp <= 0 then
      new_player_hp := p.max_hp; -- basic "knocked out, back on your feet" reset — no penalty yet
    end if;
  end if;

  new_actions := p.actions - action_cost;

  update profiles
    set hp = new_player_hp,
        xp = xp + gained_xp,
        gold = gold + gained_gold,
        actions = new_actions
    where id = p.id;

  if defeated then
    -- immediate respawn so there's always something to test against
    update player_combat
      set enemy_hp = e.max_hp, updated_at = now(), last_strike_at = now()
      where profile_id = auth.uid();
    new_enemy_hp := e.max_hp;
  else
    update player_combat
      set enemy_hp = new_enemy_hp, updated_at = now(), last_strike_at = now()
      where profile_id = auth.uid();
  end if;

  return query select dmg, defeated, new_enemy_hp, e.max_hp, new_player_hp, p.max_hp, gained_xp, gained_gold, new_actions, false;
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
  base_attack int := 10;   -- TUNE: matches profiles.attack's default for a fresh character
  base_defense int := 5;   -- TUNE: matches profiles.defense's default
  base_max_hp int := 100;  -- TUNE: matches profiles.max_hp's default
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

create or replace function join_guild(p_guild_id uuid)
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

  insert into guild_members (guild_id, profile_id, role) values (p_guild_id, auth.uid(), 'member');
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
insert into enemies (key, name, max_hp, attack, xp_reward, gold_reward) values
  ('test_rat', 'Test Rat', 20, 2, 5, 2)
on conflict (key) do nothing;
