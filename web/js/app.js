// Banished Into The Abyss — client (v0 scaffold)
// Plain JS, no build step. Talks to Supabase via the JS client loaded in index.html.

const sb = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

const state = {
  user: null,
  profile: null,
  selectedClass: null, // 'warrior' | 'archer' | 'magi' | 'striker' — chosen on the auth screen before signup
  guild: null,        // { id, name, tag, ... }
  members: [],
  boss: null,
  enemy: null,         // { enemy_key, enemy_hp, name, max_hp, attack, xp_reward, gold_reward }
  activeTab: "global", // 'global' | 'guild' | 'whispers'
  chatChannelSub: null,
  whisperSub: null,
  bossSub: null,
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
  if (state.bossSub) sb.removeChannel(state.bossSub);
  state.user = null;
  state.profile = null;
  state.guild = null;
  state.selectedClass = null;
  document.querySelectorAll(".class-card").forEach((c) => c.classList.remove("selected"));
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
  $("avatar-label").textContent = className;
  $("battle-player-portrait").src = portraitSrc;
  $("battle-player-portrait").alt = className;

  $("stat-depth").textContent = p.depth;
  $("stat-level").textContent = p.level;
  $("stat-xp").textContent = p.xp;
  $("stat-gold").textContent = p.gold;
  $("stat-shards").textContent = p.shards;
  $("stat-attack").textContent = p.attack;
  $("stat-actions").textContent = p.actions;
  $("stat-max-actions").textContent = p.max_actions;

  const hpPct = Math.max(0, Math.min(100, (p.hp / p.max_hp) * 100));
  $("player-hp-fill").style.width = hpPct + "%";
  $("player-hp-text").textContent = `${p.hp} / ${p.max_hp} HP`;
}

// ---------------------------------------------------------------------------
// Solo enemy combat (Test Rat) — drives the Current Battle panel's player
// vs. enemy display independently of guilds/guild bosses.
// ---------------------------------------------------------------------------

const TEST_ENEMY_KEY = "test_rat";

async function loadEnemy() {
  const { data, error } = await sb.rpc("get_or_spawn_player_enemy", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) return console.error(error);
  const pc = Array.isArray(data) ? data[0] : data; // single-row RPC shape varies by PostgREST version
  const { data: def, error: defErr } = await sb.from("enemies").select("*").eq("key", pc.enemy_key).single();
  if (defErr) return console.error(defErr);
  state.enemy = { ...def, enemy_hp: pc.enemy_hp };
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

$("btn-strike-enemy").addEventListener("click", async () => {
  const { data, error } = await sb.rpc("strike_enemy", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) return alert(error.message);
  const row = data?.[0];
  if (row && state.enemy) {
    state.enemy.enemy_hp = row.enemy_hp;
    state.enemy.max_hp = row.enemy_max_hp;
    renderEnemy();
    $("tick-log").textContent = row.enemy_defeated
      ? `You slew the ${state.enemy.name}! +${row.xp_gained} xp, +${row.gold_gained} gold.`
      : `You struck the ${state.enemy.name} for ${row.damage_dealt} damage.`;
  }
  await loadProfile(); // picks up updated hp/xp/gold
});

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
  await loadProfile();
  if (row && (row.xp_gained > 0 || row.gold_gained > 0)) {
    $("tick-log").textContent =
      `+${row.xp_gained} xp, +${row.gold_gained} gold` +
      (row.boss_damage > 0 ? `, dealt ${row.boss_damage} idle damage to the guild boss` : "");
  }
  if (state.guild) refreshBoss();
}

$("btn-refresh-actions").addEventListener("click", async () => {
  const { error } = await sb.rpc("refresh_actions");
  if (error) return alert(error.message);
  await loadProfile();
});

// ---------------------------------------------------------------------------
// Guild
// ---------------------------------------------------------------------------

async function loadGuildMembership() {
  const { data: membership } = await sb
    .from("guild_members")
    .select("guild_id, role")
    .eq("profile_id", state.user.id)
    .maybeSingle();

  if (!membership) {
    state.guild = null;
    $("no-guild").classList.remove("hidden");
    $("in-guild").classList.add("hidden");
    await loadGuildList();
    return;
  }

  const { data: guild } = await sb.from("guilds").select("*").eq("id", membership.guild_id).single();
  state.guild = guild;
  $("no-guild").classList.add("hidden");
  $("in-guild").classList.remove("hidden");
  $("guild-heading").textContent = `${guild.name} [${guild.tag}]`;

  await loadMembers();
  await refreshBoss();
  subscribeChat("guild"); // re-subscribe once we know the guild id (channel name depends on it)
  subscribeBoss();
}

async function loadGuildList() {
  const { data } = await sb.from("guilds").select("id, name, tag, member_cap").order("created_at", { ascending: false }).limit(50);
  const box = $("guild-list");
  box.innerHTML = "";
  (data || []).forEach((g) => {
    const row = document.createElement("div");
    row.textContent = `${g.name} [${g.tag}] `;
    const btn = document.createElement("button");
    btn.textContent = "Join";
    btn.onclick = () => joinGuild(g.id);
    row.appendChild(btn);
    box.appendChild(row);
  });
}
$("btn-refresh-guilds").addEventListener("click", loadGuildList);

$("btn-create-guild").addEventListener("click", async () => {
  const name = $("guild-name").value.trim();
  const tag = $("guild-tag").value.trim();
  const { error } = await sb.rpc("create_guild", { p_name: name, p_tag: tag });
  if (error) return alert(error.message);
  await loadGuildMembership();
});

async function joinGuild(guildId) {
  const { error } = await sb.rpc("join_guild", { p_guild_id: guildId });
  if (error) return alert(error.message);
  await loadGuildMembership();
}

$("btn-leave-guild").addEventListener("click", async () => {
  if (!confirm("Leave your guild?")) return;
  const { error } = await sb.rpc("leave_guild");
  if (error) return alert(error.message);
  await loadGuildMembership();
});

async function loadMembers() {
  if (!state.guild) return;
  const { data } = await sb
    .from("guild_members")
    .select("role, profile_id, profiles(username, level, depth)")
    .eq("guild_id", state.guild.id);
  state.members = data || [];
  const ul = $("member-list");
  ul.innerHTML = "";
  state.members.forEach((m) => {
    const li = document.createElement("li");
    li.className = `role-${m.role}`;
    li.textContent = `${m.profiles.username} — Lv${m.profiles.level}, Depth ${m.profiles.depth} (${m.role})`;
    ul.appendChild(li);
  });
}

async function refreshBoss() {
  if (!state.guild) return;
  const { data } = await sb
    .from("guild_bosses")
    .select("*")
    .eq("guild_id", state.guild.id)
    .order("spawned_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  state.boss = data;
  renderBoss();
}

function renderBoss() {
  const b = state.boss;
  if (!b) {
    $("boss-name").textContent = "No boss has spawned yet — strike or tick to summon one.";
    $("boss-hp-fill").style.width = "0%";
    $("boss-hp-text").textContent = "";
    return;
  }
  $("boss-name").textContent = b.name + (b.defeated_at ? " (defeated — respawning soon)" : "");
  const pct = Math.max(0, Math.min(100, (b.current_hp / b.max_hp) * 100));
  $("boss-hp-fill").style.width = pct + "%";
  $("boss-hp-text").textContent = `${b.current_hp} / ${b.max_hp} HP`;
}

$("btn-strike").addEventListener("click", async () => {
  const { data, error } = await sb.rpc("strike_active_boss");
  if (error) return alert(error.message);
  const row = data?.[0];
  if (row) {
    $("tick-log").textContent = row.boss_defeated
      ? `You landed the killing blow for ${row.damage_dealt} damage!`
      : `You struck the boss for ${row.damage_dealt} damage.`;
  }
  await refreshBoss();
});

function subscribeBoss() {
  if (state.bossSub) sb.removeChannel(state.bossSub);
  if (!state.guild) return;
  state.bossSub = sb
    .channel(`boss:${state.guild.id}`)
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "guild_bosses", filter: `guild_id=eq.${state.guild.id}` },
      () => refreshBoss()
    )
    .subscribe();
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
