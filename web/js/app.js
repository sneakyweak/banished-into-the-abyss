// Banished Into The Abyss — client (v0 scaffold)
// Plain JS, no build step. Talks to Supabase via the JS client loaded in index.html.

const sb = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

const state = {
  user: null,
  profile: null,
  selectedClass: null, // 'warrior' | 'archer' | 'magi' | 'striker' — chosen on the auth screen before signup
  guild: null,        // { id, name, tag, ... }
  myRole: null,       // this player's role in state.guild: 'leader' | 'officer' | 'member' | null
  members: [],
  enemy: null,         // { enemy_key, enemy_hp, name, max_hp, attack, xp_reward, gold_reward }
  activeTab: "global", // 'global' | 'guild' | 'whispers'
  chatChannelSub: null,
  whisperSub: null,
  tickTimer: null,
};

const $ = (id) => document.getElementById(id);

const TICK_INTERVAL_MS = 8_000; // how often idle progress checks in automatically

// drains the action-bar-style tick tracker over TICK_INTERVAL_MS using a
// plain CSS transition, rather than driving it frame-by-frame from JS.
// Uses a double rAF (rather than an offsetWidth read) to force the browser
// to paint the "full, no transition" state before starting the animated
// "empty" state — the more reliable way to force that split across browsers.
function resetTickBar() {
  const fill = $("tick-bar-fill");
  if (!fill) return;
  fill.style.transition = "none";
  fill.style.width = "100%";
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      fill.style.transition = `width ${TICK_INTERVAL_MS}ms linear`;
      fill.style.width = "0%";
    });
  });
}

// ---------------------------------------------------------------------------
// Auth
//
// Supabase Auth is built around email (or phone) as the login identifier —
// there's no "just a username" mode. Rather than roll our own password
// storage (a much bigger security surface for a hobby project), we keep
// Supabase's normal, secure email/password auth under the hood, but derive
// a fake, non-deliverable email from the username so players never see or
// type one. This only works if "Confirm email" is turned OFF in your
// Supabase project (Authentication -> Settings) — see README.md §1 — since
// no confirmation link could ever reach these addresses.
// ---------------------------------------------------------------------------

const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/;
const CLASS_PORTRAITS = {
  warrior: "img/class-warrior-avatar.jpg",
  archer: "img/class-archer-avatar.jpg",
  magi: "img/class-magi-avatar.jpg",
  striker: "img/class-striker-avatar.jpg",
};

document.querySelectorAll(".class-card").forEach((card) => {
  card.addEventListener("click", () => {
    document.querySelectorAll(".class-card").forEach((c) => c.classList.remove("selected"));
    card.classList.add("selected");
    state.selectedClass = card.dataset.class;
  });
});

// deterministic: the same username always maps to the same address, so
// sign-in never has to look anything up first. The .invalid TLD is reserved
// by IANA specifically for addresses that are guaranteed not to resolve.
function usernameToFakeEmail(username) {
  return `${username.toLowerCase()}@banished-abyss.invalid`;
}

$("btn-signup").addEventListener("click", async () => {
  const username = $("auth-username").value.trim();
  const password = $("auth-password").value;
  if (!USERNAME_RE.test(username)) {
    return showAuthError("Pick a character name: 3-20 chars, letters/numbers/_ only.");
  }
  if (!state.selectedClass) {
    return showAuthError("Choose a class above before signing up.");
  }
  const { error } = await sb.auth.signUp({
    email: usernameToFakeEmail(username),
    password,
    options: { data: { username, class: state.selectedClass } },
  });
  if (error) {
    // Supabase's generic "already registered" message talks about email —
    // translate it back into username terms for players.
    if (/already registered|already exists/i.test(error.message)) {
      return showAuthError("That character name is taken.");
    }
    return showAuthError(error.message);
  }
  showAuthError("Account created — click Sign In.");
});

$("btn-signin").addEventListener("click", async () => {
  const username = $("auth-username").value.trim();
  const password = $("auth-password").value;
  if (!username) return showAuthError("Enter your character name.");
  const { error } = await sb.auth.signInWithPassword({
    email: usernameToFakeEmail(username),
    password,
  });
  if (error) return showAuthError("Wrong name or password.");
});

$("btn-signout").addEventListener("click", async () => {
  await sb.auth.signOut();
});

function showAuthError(msg) {
  $("auth-error").textContent = msg;
}

sb.auth.onAuthStateChange((_event, session) => {
  if (session?.user) {
    enterGame(session.user);
  } else {
    leaveGame();
  }
});

// ---------------------------------------------------------------------------
// Entering / leaving the game screen
// ---------------------------------------------------------------------------

async function enterGame(user) {
  state.user = user;
  $("auth-screen").classList.add("hidden");
  $("game-screen").classList.remove("hidden");

  $("btn-signout").classList.remove("hidden");

  await loadProfile();
  await loadGuildMembership();
  await loadInventory();
  await loadEnemy();
  await loadChatHistory("global");
  subscribeChat("global");
  subscribeWhispers();
  await doTick(); // resolve any offline progress immediately
  resetTickBar();

  clearInterval(state.tickTimer);
  state.tickTimer = setInterval(async () => {
    await doTick();
    resetTickBar();
  }, TICK_INTERVAL_MS);
}

function leaveGame() {
  clearInterval(state.tickTimer);
  if (state.chatChannelSub) sb.removeChannel(state.chatChannelSub);
  if (state.whisperSub) sb.removeChannel(state.whisperSub);
  state.user = null;
  state.profile = null;
  state.guild = null;
  state.selectedClass = null;
  document.querySelectorAll(".class-card").forEach((c) => c.classList.remove("selected"));
  $("btn-signout").classList.add("hidden");
  $("game-screen").classList.add("hidden");
  $("auth-screen").classList.remove("hidden");
}

// ---------------------------------------------------------------------------
// Profile + idle tick
// ---------------------------------------------------------------------------

async function loadProfile() {
  const { data, error } = await sb.from("profiles").select("*").eq("id", state.user.id).single();
  if (error) return console.error(error);
  state.profile = data;
  renderProfile();
}

function renderProfile() {
  const p = state.profile;
  if (!p) return;
  $("who").textContent = p.username;
  $("char-name").textContent = p.username;
  $("battle-player-name").textContent = p.username;
  $("battle-player-level").textContent = p.level;

  const portraitSrc = CLASS_PORTRAITS[p.class] || CLASS_PORTRAITS.warrior;
  const className = p.class ? p.class.charAt(0).toUpperCase() + p.class.slice(1) : "Wanderer";
  $("avatar-portrait").src = portraitSrc;
  $("avatar-portrait").alt = className;
  $("battle-player-portrait").src = portraitSrc;
  $("battle-player-portrait").alt = className;

  $("stat-depth").textContent = p.depth;
  $("stat-level").textContent = p.level;
  $("stat-xp").textContent = p.xp;
  $("stat-gold").textContent = p.gold;
  $("stat-prowess").textContent = p.abyssal_prowess;
  $("stat-actions").textContent = p.actions;
  $("stat-max-actions").textContent = p.max_actions;

  $("stat-power").textContent = p.attack;
  $("stat-defense").textContent = p.defense;
  $("stat-attack-speed").textContent = p.attack_speed;
  $("stat-crit").textContent = `${p.crit}%`;
  $("stat-multi-strike").textContent = `${p.multi_strike}%`;
  $("stat-speed").textContent = p.speed;

  const hpPct = Math.max(0, Math.min(100, (p.hp / p.max_hp) * 100));
  $("player-hp-fill").style.width = hpPct + "%";
  $("player-hp-text").textContent = `${p.hp} / ${p.max_hp} HP`;
}

// ---------------------------------------------------------------------------
// Solo enemy combat (Test Rat) — drives the Current Battle panel's player
// vs. enemy display independently of guilds.
// ---------------------------------------------------------------------------

const TEST_ENEMY_KEY = "test_rat";

async function loadEnemy() {
  const { data, error } = await sb.rpc("get_or_spawn_player_enemy", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) return console.error(error);
  const pc = Array.isArray(data) ? data[0] : data; // single-row RPC shape varies by PostgREST version
  // get_or_spawn_player_enemy already returns tier-adjusted display name +
  // max hp (Elite/Champion prefix and scaled stats) — no separate `enemies`
  // table read needed.
  state.enemy = { name: pc.display_name, tier: pc.tier, enemy_hp: pc.enemy_hp, max_hp: pc.enemy_max_hp };
  renderEnemy();
}

function renderEnemy() {
  const en = state.enemy;
  if (!en) return;
  $("enemy-name").textContent = en.name;
  const pct = Math.max(0, Math.min(100, (en.enemy_hp / en.max_hp) * 100));
  $("enemy-hp-fill").style.width = pct + "%";
  $("enemy-hp-text").textContent = `${en.enemy_hp} / ${en.max_hp} HP`;
}

// Fired automatically once per idle tick (see doTick() below) instead of
// from a button. Costs a flat 1 action no matter what — but each call
// resolves a whole fight in one go (rounds driven by the player's Attack
// Speed stat, capped at 100 server-side, see strike_enemy in schema.sql)
// rather than a single swing, rolling real crit/multi-strike/defense math
// each round. A kill mid-fight respawns instantly into a freshly-rolled
// tier (normal/Elite/Champion), so the enemy name/hp can change over the
// course of one call — row.enemy_name/enemy_hp/enemy_max_hp always reflect
// where the fight ended up. out_of_actions is only ever true when the
// action pool was already empty before this call started (the flat cost
// means a fight in progress is never cut short by actions running out
// mid-way). Returns a short message for the tick log, or null if there's
// nothing worth reporting (on cooldown, 0 rounds run).
async function autoStrikeEnemy() {
  const { data, error } = await sb.rpc("strike_enemy", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) {
    console.error(error);
    return null;
  }
  const row = data?.[0];
  if (!row) return null;

  if (state.enemy) {
    state.enemy.name = row.enemy_name;
    state.enemy.enemy_hp = row.enemy_hp;
    state.enemy.max_hp = row.enemy_max_hp;
    renderEnemy();
  }

  if (row.rounds_fought === 0) {
    return row.out_of_actions ? "Out of actions — click Refresh Actions to keep fighting." : null;
  }

  const enemyName = row.enemy_name || "the enemy";
  const roundsText = `${row.rounds_fought} round${row.rounds_fought === 1 ? "" : "s"}`;
  let msg;
  if (row.kills > 0) {
    const killsText = row.kills === 1 ? `slew ${enemyName}` : `slew ${enemyName} x${row.kills}`;
    msg = `You ${killsText} over ${roundsText}! +${row.xp_gained} xp, +${row.gold_gained} gold.`;
  } else {
    msg = `You struck ${enemyName} ${roundsText} for ${row.damage_dealt} damage.`;
  }
  if (row.out_of_actions) msg += " Out of actions.";
  return msg;
}

async function loadInventory() {
  const { data, error } = await sb
    .from("inventory")
    .select("quantity, items(key, name, description, rarity)")
    .eq("profile_id", state.user.id)
    .gt("quantity", 0)
    .order("quantity", { ascending: false });
  if (error) return console.error(error);
  renderInventory(data || []);
}

function renderInventory(rows) {
  const ul = $("inventory-list");
  ul.innerHTML = "";
  if (!rows.length) {
    const li = document.createElement("li");
    li.className = "log";
    li.textContent = "Empty.";
    ul.appendChild(li);
    return;
  }
  rows.forEach((row) => {
    const item = row.items;
    if (!item) return;
    const li = document.createElement("li");
    li.title = item.description || "";
    const name = document.createElement("span");
    name.className = `rarity-${item.rarity}`;
    name.textContent = item.name;
    const qty = document.createElement("span");
    qty.className = "item-qty";
    qty.textContent = `x${row.quantity}`;
    li.appendChild(name);
    li.appendChild(qty);
    ul.appendChild(li);
  });
}

async function doTick() {
  const { data, error } = await sb.rpc("perform_idle_tick");
  if (error) return console.error(error);
  const row = data?.[0];

  // one auto-strike against the current enemy per tick — costs 1 action,
  // stops gracefully once the pool is empty (see autoStrikeEnemy above)
  const strikeMsg = await autoStrikeEnemy();

  await loadProfile();

  const parts = [];
  if (row && (row.xp_gained > 0 || row.gold_gained > 0)) {
    parts.push(`+${row.xp_gained} xp, +${row.gold_gained} gold`);
  }
  if (strikeMsg) parts.push(strikeMsg);
  if (parts.length) $("tick-log").textContent = parts.join("  •  ");
}

$("btn-refresh-actions").addEventListener("click", async () => {
  const { error } = await sb.rpc("refresh_actions");
  if (error) return alert(error.message);
  await loadProfile();
});

// ---------------------------------------------------------------------------
// Guild
//    Guild management (create/apply/invite/leave, members, recruitment)
//    lives in an overlay instead of on the main page — opened from the
//    "Guild" nav pill. Guild bosses are disabled for now.
// ---------------------------------------------------------------------------

$("nav-guild-btn").addEventListener("click", () => {
  $("guild-overlay").classList.remove("hidden");
});
$("btn-close-guild-overlay").addEventListener("click", () => {
  $("guild-overlay").classList.add("hidden");
});
$("guild-overlay").addEventListener("click", (e) => {
  if (e.target.id === "guild-overlay") $("guild-overlay").classList.add("hidden"); // click on backdrop closes it
});

// ---------------------------------------------------------------------------
// Banishment (prestige) — sacrifice the character at level 100+ for
// Abyssal Prowess plus a slice of current stats carried into the next run.
// The retention tiers below are cosmetic display only; the real numbers are
// computed and enforced server-side in perform_banishment() (schema.sql).
// ---------------------------------------------------------------------------

function retentionPctForProwess(prowess) {
  if (prowess >= 1001) return 100;
  if (prowess >= 501) return 0.75;
  if (prowess >= 100) return 0.5;
  return 0.25;
}

function renderBanishOverlay() {
  const p = state.profile;
  if (!p) return;
  $("banish-level").textContent = p.level;
  $("banish-prowess").textContent = p.abyssal_prowess;
  $("banish-pct").textContent = `${retentionPctForProwess(p.abyssal_prowess)}%`;
  const eligible = p.level >= 100;
  $("btn-perform-banish").disabled = !eligible;
  $("banish-lock-note").classList.toggle("hidden", eligible);
  $("banish-error").textContent = "";
}

$("nav-banish-btn").addEventListener("click", () => {
  renderBanishOverlay();
  $("banish-overlay").classList.remove("hidden");
});
$("btn-close-banish-overlay").addEventListener("click", () => {
  $("banish-overlay").classList.add("hidden");
});
$("banish-overlay").addEventListener("click", (e) => {
  if (e.target.id === "banish-overlay") $("banish-overlay").classList.add("hidden");
});

$("btn-perform-banish").addEventListener("click", async () => {
  if (!confirm("Sacrifice your character to the Abyss? This cannot be undone.")) return;
  const { error } = await sb.rpc("perform_banishment");
  if (error) {
    $("banish-error").textContent = error.message;
    return;
  }
  $("banish-overlay").classList.add("hidden");
  await loadProfile();
  await loadInventory();
  await loadEnemy();
});

async function loadGuildMembership() {
  const { data: membership } = await sb
    .from("guild_members")
    .select("guild_id, role")
    .eq("profile_id", state.user.id)
    .maybeSingle();

  if (!membership) {
    state.guild = null;
    state.myRole = null;
    $("no-guild").classList.remove("hidden");
    $("in-guild").classList.add("hidden");
    $("guild-settings").classList.add("hidden");
    await loadGuildList();
    await loadMyRequests();
    return;
  }

  state.myRole = membership.role;
  const { data: guild } = await sb.from("guilds").select("*").eq("id", membership.guild_id).single();
  state.guild = guild;
  $("no-guild").classList.add("hidden");
  $("in-guild").classList.remove("hidden");
  $("guild-heading").textContent = `${guild.name} [${guild.tag}]`;

  await loadMembers();
  await loadGuildRecruitment();
  subscribeChat("guild"); // re-subscribe once we know the guild id (channel name depends on it)
}

async function loadGuildList() {
  const { data } = await sb.from("guilds").select("id, name, tag, member_cap").order("created_at", { ascending: false }).limit(50);
  const box = $("guild-list");
  box.innerHTML = "";
  (data || []).forEach((g) => {
    const row = document.createElement("div");
    row.textContent = `${g.name} [${g.tag}] `;
    const btn = document.createElement("button");
    btn.textContent = "Apply";
    btn.onclick = () => applyToGuild(g.id);
    row.appendChild(btn);
    box.appendChild(row);
  });
}
$("btn-refresh-guilds").addEventListener("click", () => {
  loadGuildList();
  loadMyRequests();
});

$("btn-create-guild").addEventListener("click", async () => {
  const name = $("guild-name").value.trim();
  const tag = $("guild-tag").value.trim();
  const { error } = await sb.rpc("create_guild", { p_name: name, p_tag: tag });
  if (error) return alert(error.message);
  await loadGuildMembership();
});

async function applyToGuild(guildId) {
  const { error } = await sb.rpc("apply_to_guild", { p_guild_id: guildId });
  if (error) return alert(error.message);
  await loadMyRequests();
}

// ---------------------------------------------------------------------------
// Guild requests — applications (player -> guild) and invites (guild ->
// player). Both sides get rendered from the same guild_requests table:
// "Your Invites"/"Your Applications" when you're not in a guild, and the
// Recruitment panel (leader/officer only) when you are.
// ---------------------------------------------------------------------------

function emptyLi() {
  const li = document.createElement("li");
  li.className = "log";
  li.textContent = "None.";
  return li;
}

function buildRequestLi(labelText, buttons) {
  const li = document.createElement("li");
  const label = document.createElement("span");
  label.textContent = labelText;
  li.appendChild(label);
  const btnBox = document.createElement("span");
  buttons.forEach(([text, onClick]) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn-ghost";
    btn.textContent = text;
    btn.addEventListener("click", onClick);
    btnBox.appendChild(btn);
  });
  li.appendChild(btnBox);
  return li;
}

async function loadMyRequests() {
  const { data } = await sb
    .from("guild_requests")
    .select("id, type, status, guild_id, guilds(name, tag)")
    .eq("profile_id", state.user.id)
    .eq("status", "pending");

  const invites = (data || []).filter((r) => r.type === "invite");
  const applications = (data || []).filter((r) => r.type === "application");

  const invUl = $("my-invites-list");
  invUl.innerHTML = "";
  if (!invites.length) invUl.appendChild(emptyLi());
  invites.forEach((r) => {
    invUl.appendChild(
      buildRequestLi(`${r.guilds.name} [${r.guilds.tag}]`, [
        [
          "Accept",
          async () => {
            const { error } = await sb.rpc("respond_to_invite", { p_request_id: r.id, p_accept: true });
            if (error) return alert(error.message);
            await loadGuildMembership();
          },
        ],
        [
          "Decline",
          async () => {
            const { error } = await sb.rpc("respond_to_invite", { p_request_id: r.id, p_accept: false });
            if (error) return alert(error.message);
            await loadMyRequests();
          },
        ],
      ])
    );
  });

  const appUl = $("my-applications-list");
  appUl.innerHTML = "";
  if (!applications.length) appUl.appendChild(emptyLi());
  applications.forEach((r) => {
    appUl.appendChild(
      buildRequestLi(`${r.guilds.name} [${r.guilds.tag}] — pending`, [
        [
          "Cancel",
          async () => {
            const { error } = await sb.rpc("cancel_guild_request", { p_request_id: r.id });
            if (error) return alert(error.message);
            await loadMyRequests();
          },
        ],
      ])
    );
  });
}

async function loadGuildRecruitment() {
  if (!state.guild) return;
  const canManage = state.myRole === "leader" || state.myRole === "officer";
  $("guild-recruitment").classList.toggle("hidden", !canManage);
  if (!canManage) return;

  const { data } = await sb
    .from("guild_requests")
    .select("id, type, status, profile_id, profiles(username, level)")
    .eq("guild_id", state.guild.id)
    .eq("status", "pending");

  const applications = (data || []).filter((r) => r.type === "application");
  const invites = (data || []).filter((r) => r.type === "invite");

  const appUl = $("pending-applications-list");
  appUl.innerHTML = "";
  if (!applications.length) appUl.appendChild(emptyLi());
  applications.forEach((r) => {
    appUl.appendChild(
      buildRequestLi(`${r.profiles.username} — Lv${r.profiles.level}`, [
        [
          "Accept",
          async () => {
            const { error } = await sb.rpc("respond_to_application", { p_request_id: r.id, p_accept: true });
            if (error) return alert(error.message);
            await loadMembers();
            await loadGuildRecruitment();
          },
        ],
        [
          "Decline",
          async () => {
            const { error } = await sb.rpc("respond_to_application", { p_request_id: r.id, p_accept: false });
            if (error) return alert(error.message);
            await loadGuildRecruitment();
          },
        ],
      ])
    );
  });

  const invUl = $("pending-invites-list");
  invUl.innerHTML = "";
  if (!invites.length) invUl.appendChild(emptyLi());
  invites.forEach((r) => {
    invUl.appendChild(
      buildRequestLi(`${r.profiles.username} — pending`, [
        [
          "Revoke",
          async () => {
            const { error } = await sb.rpc("cancel_guild_request", { p_request_id: r.id });
            if (error) return alert(error.message);
            await loadGuildRecruitment();
          },
        ],
      ])
    );
  });
}

$("btn-send-invite").addEventListener("click", async () => {
  const username = $("invite-username").value.trim();
  $("invite-error").textContent = "";
  if (!username) return;
  const { error } = await sb.rpc("invite_to_guild", { p_username: username });
  if (error) {
    $("invite-error").textContent = error.message;
    return;
  }
  $("invite-username").value = "";
  await loadGuildRecruitment();
});

$("btn-leave-guild").addEventListener("click", async () => {
  if (!confirm("Leave your guild?")) return;
  const { error } = await sb.rpc("leave_guild");
  if (error) return alert(error.message);
  await loadGuildMembership();
});

// ---------------------------------------------------------------------------
// Guild settings — leader-only: assign officer/member ranks, hand off
// leadership, or disband. The leader can't leave via the normal Leave
// button (server-side guard in leave_guild() rejects it too) since a guild
// always needs exactly one leader; they have to transfer it here first.
// ---------------------------------------------------------------------------

$("btn-guild-settings").addEventListener("click", () => {
  $("guild-settings").classList.toggle("hidden");
});

$("btn-disband-guild").addEventListener("click", async () => {
  if (!confirm("Disband your guild? This permanently deletes it for every member and cannot be undone.")) return;
  const { error } = await sb.rpc("disband_guild");
  if (error) return alert(error.message);
  $("guild-settings").classList.add("hidden");
  await loadGuildMembership();
});

async function loadMembers() {
  if (!state.guild) return;
  const { data } = await sb
    .from("guild_members")
    .select("role, profile_id, profiles(username, level, depth)")
    .eq("guild_id", state.guild.id);
  state.members = data || [];
  renderMembers();
}

function renderMembers() {
  const ul = $("member-list");
  ul.innerHTML = "";
  state.members.forEach((m) => {
    const li = document.createElement("li");
    li.className = `role-${m.role}`;
    li.textContent = `${m.profiles.username} — Lv${m.profiles.level}, Depth ${m.profiles.depth} (${m.role})`;
    ul.appendChild(li);
  });

  const isLeader = state.myRole === "leader";
  $("btn-guild-settings").classList.toggle("hidden", !isLeader);
  $("btn-leave-guild").classList.toggle("hidden", isLeader);
  $("leader-leave-note").classList.toggle("hidden", !isLeader);
  if (!isLeader) $("guild-settings").classList.add("hidden");

  renderRankEditor();
}

function renderRankEditor() {
  const ul = $("rank-editor-list");
  ul.innerHTML = "";
  if (state.myRole !== "leader") return;

  state.members
    .filter((m) => m.role !== "leader")
    .forEach((m) => {
      const li = document.createElement("li");

      const label = document.createElement("span");
      label.className = "rank-name";
      label.textContent = `${m.profiles.username} (${m.role})`;

      const select = document.createElement("select");
      [["member", "Member"], ["officer", "Officer"]].forEach(([value, text]) => {
        const opt = document.createElement("option");
        opt.value = value;
        opt.textContent = text;
        if (value === m.role) opt.selected = true;
        select.appendChild(opt);
      });
      select.addEventListener("change", async () => {
        const { error } = await sb.rpc("set_member_rank", { p_profile_id: m.profile_id, p_role: select.value });
        if (error) {
          alert(error.message);
          select.value = m.role;
          return;
        }
        await loadMembers();
      });

      const makeLeaderBtn = document.createElement("button");
      makeLeaderBtn.type = "button";
      makeLeaderBtn.className = "btn-ghost btn-make-leader";
      makeLeaderBtn.textContent = "Make Leader";
      makeLeaderBtn.addEventListener("click", async () => {
        if (!confirm(`Hand off guild leadership to ${m.profiles.username}? You'll become an officer.`)) return;
        const { error } = await sb.rpc("transfer_leadership", { p_new_leader_id: m.profile_id });
        if (error) return alert(error.message);
        await loadGuildMembership();
      });

      li.appendChild(label);
      li.appendChild(select);
      li.appendChild(makeLeaderBtn);
      ul.appendChild(li);
    });
}

// ---------------------------------------------------------------------------
// Chat, whispers, /send — all routed through one input box
// ---------------------------------------------------------------------------

document.querySelectorAll(".chat-tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".chat-tab").forEach((t) => t.classList.remove("active"));
    tab.classList.add("active");
    state.activeTab = tab.dataset.channel;
    if (state.activeTab === "global") loadChatHistory("global");
    if (state.activeTab === "guild" && state.guild) loadChatHistory(`guild:${state.guild.id}`);
    if (state.activeTab === "whispers") loadWhisperHistory();
  });
});

function currentChannelName() {
  if (state.activeTab === "guild" && state.guild) return `guild:${state.guild.id}`;
  return "global";
}

async function loadChatHistory(channel) {
  const { data } = await sb
    .from("chat_messages")
    .select("id, body, created_at, profiles(username)")
    .eq("channel", channel)
    .order("created_at", { ascending: false })
    .limit(50);
  const log = $("chat-log");
  log.innerHTML = "";
  (data || []).reverse().forEach((m) => appendChatLine(m.profiles?.username || "???", m.body));
}

async function loadWhisperHistory() {
  const { data } = await sb
    .from("whispers")
    .select("id, body, created_at, sender_id, recipient_id, sender:sender_id(username), recipient:recipient_id(username)")
    .order("created_at", { ascending: false })
    .limit(50);
  const log = $("chat-log");
  log.innerHTML = "";
  (data || []).reverse().forEach((w) => {
    const mine = w.sender_id === state.user.id;
    const label = mine ? `to ${w.recipient.username}` : `from ${w.sender.username}`;
    appendChatLine(label, w.body, "whisper");
  });
}

function subscribeChat(kind) {
  if (state.chatChannelSub) sb.removeChannel(state.chatChannelSub);
  const channelName = kind === "guild" && state.guild ? `guild:${state.guild.id}` : "global";
  state.chatChannelSub = sb
    .channel(`chat:${channelName}`)
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "chat_messages", filter: `channel=eq.${channelName}` },
      async (payload) => {
        if (currentChannelName() !== channelName) return;
        const { data: sender } = await sb.from("profiles").select("username").eq("id", payload.new.sender_id).single();
        appendChatLine(sender?.username || "???", payload.new.body);
      }
    )
    .subscribe();
}

function subscribeWhispers() {
  state.whisperSub = sb
    .channel(`whispers:${state.user.id}`)
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "whispers", filter: `recipient_id=eq.${state.user.id}` },
      async (payload) => {
        const { data: sender } = await sb.from("profiles").select("username").eq("id", payload.new.sender_id).single();
        if (state.activeTab === "whispers") {
          appendChatLine(`from ${sender?.username}`, payload.new.body, "whisper");
        } else {
          appendChatLine("system", `Whisper from ${sender?.username} — check the Whispers tab.`, "system");
        }
      }
    )
    .subscribe();
}

function appendChatLine(who, body, cls) {
  const log = $("chat-log");
  const line = document.createElement("div");
  line.className = "msg" + (cls ? ` ${cls}` : "");
  const whoSpan = document.createElement("span");
  whoSpan.className = "who";
  whoSpan.textContent = who + ": ";
  line.appendChild(whoSpan);
  line.appendChild(document.createTextNode(body));
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("chat-input");
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  $("chat-error").textContent = "";

  try {
    if (text.startsWith("/w ")) {
      const [, name, ...rest] = text.split(" ");
      const body = rest.join(" ");
      if (!name || !body) throw new Error("usage: /w name message");
      const { error } = await sb.rpc("send_whisper", { p_recipient_username: name, p_body: body });
      if (error) throw error;
      appendChatLine(`to ${name}`, body, "whisper");
    } else if (text.startsWith("/send ")) {
      const parts = text.split(" ");
      // /send name gold 10   OR   /send name item_key 3
      const [, name, thing, amountStr] = parts;
      const amount = parseInt(amountStr, 10);
      if (!name || !thing || !amount || amount <= 0) {
        throw new Error("usage: /send name gold 10  |  /send name item_key 3");
      }
      if (thing === "gold") {
        const { error } = await sb.rpc("send_gold", { p_recipient_username: name, p_amount: amount });
        if (error) throw error;
      } else {
        const { error } = await sb.rpc("send_item", { p_recipient_username: name, p_item_key: thing, p_quantity: amount });
        if (error) throw error;
      }
      appendChatLine("system", `Sent ${amount} ${thing} to ${name}.`, "system");
      await loadProfile();
      await loadInventory();
    } else {
      const channel = currentChannelName();
      const { error } = await sb.rpc("post_chat_message", { p_channel: channel, p_body: text });
      if (error) throw error;
      // no local append here — the realtime subscription will echo it back
    }
  } catch (err) {
    $("chat-error").textContent = err.message || String(err);
  }
});
