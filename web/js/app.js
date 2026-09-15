// Banished Into The Abyss — client (v0 scaffold)
// Plain JS, no build step. Talks to Supabase via the JS client loaded in index.html.

const sb = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

const state = {
  user: null,
  profile: null,
  selectedClass: null, // 'warrior' | 'archer' | 'magi' | 'striker' — chosen on the auth screen before signup
  selectedBanishClass: null, // same 4 options, chosen in the banish overlay before re-banishing (defaults to the character's current class each time the overlay opens)
  guild: null,        // { id, name, tag, ... }
  myRole: null,       // this player's role in state.guild: 'leader' | 'officer' | 'member' | null
  members: [],
  pack: [],            // current enemy pack: [{ enemy_key, name, tier, hp, max_hp, attack, defense, xp, gold }, ...]
  affixNames: [],      // display names of this pack's active affixes (enemy-side modifiers)
  debuffNames: [],     // display names of this pack's active debuffs (player-side, self-imposed)
  // Running totals for this browser session (resets on page load — not
  // persisted server-side). Extensible: add more fields here (crits landed,
  // status effects applied/received, etc.) as those get tracked, and add a
  // matching line to renderBattleStats() below.
  battleStats: { damageDealt: 0, damageTaken: 0, kills: 0, deaths: 0, idleXp: 0, idleGold: 0 },
  activeTab: "global", // 'global' | 'guild' | 'whispers'
  chatChannelSub: null,
  whisperSub: null,
  tickTimer: null,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// New-version popup
//    Shown once per browser, only when this page's window.APP_VERSION
//    (index.html) differs from the version that browser last saw — never on
//    a brand-new visitor's very first load. Runs immediately at script load,
//    independent of auth state, since it's a site-wide announcement rather
//    than anything tied to a character. Lists that build's window.PATCH_NOTES
//    and counts down to an automatic page refresh (the page is already
//    running the new code by the time this shows — the refresh is just a
//    flourish, not a functional requirement — so dismissing the popup
//    cancels the countdown instead of forcing it).
//
//    That initial check only fires once, at page load — a tab left open
//    across a deploy never re-runs it, so it would never learn about a new
//    build on its own. pollForNewVersion() (below, started at the bottom of
//    this section) covers that case by periodically re-fetching the live
//    index.html and comparing versions, so the popup can still show up
//    without anyone hitting refresh first.
// ---------------------------------------------------------------------------

const SEEN_VERSION_KEY = "bita_seen_version";
const NEW_VERSION_REFRESH_SECONDS = 120; // 2 minutes — long enough to actually read the patch notes before it forces a refresh
let newVersionCountdownTimer = null;
let newVersionDeadline = null; // wall-clock ms timestamp; set while the countdown is active

function checkNewVersion() {
  const current = window.APP_VERSION;
  if (!current) return;
  try {
    const seen = localStorage.getItem(SEEN_VERSION_KEY);
    if (seen !== null && seen !== current) {
      showNewVersionPopup();
    }
    localStorage.setItem(SEEN_VERSION_KEY, current);
  } catch (e) {
    // localStorage unavailable (private mode, blocked storage, etc.) — skip silently
  }
}

function showNewVersionPopup() {
  const notes = Array.isArray(window.PATCH_NOTES) ? window.PATCH_NOTES : [];
  const list = $("patch-notes-list");
  if (list) {
    list.innerHTML = "";
    notes.forEach((note) => {
      const li = document.createElement("li");
      li.textContent = note;
      list.appendChild(li);
    });
  }
  $("new-version-overlay")?.classList.remove("hidden");
  startNewVersionCountdown();
}

// Wall-clock-deadline based (NOT a decrementing tick counter) — a
// background tab's setInterval gets throttled and can fire a burst of
// catch-up ticks all at once when the tab becomes visible again, which is
// what made the old tick-counting version "close way too soon" (a chunk of
// the countdown silently elapsed off-screen). Comparing against a fixed
// Date.now() deadline means the displayed time is always accurate no
// matter how irregularly the interval actually fires.
function startNewVersionCountdown() {
  newVersionDeadline = Date.now() + NEW_VERSION_REFRESH_SECONDS * 1000;
  const label = $("new-version-countdown");
  const render = () => {
    if (!label || newVersionDeadline == null) return;
    const remaining = Math.max(0, Math.round((newVersionDeadline - Date.now()) / 1000));
    const mins = Math.floor(remaining / 60);
    const secs = remaining % 60;
    const timeStr = `${mins}:${String(secs).padStart(2, "0")}`;
    label.textContent = `There's a new patch — please refresh. Auto-refreshing in ${timeStr}...`;
  };
  render();
  clearInterval(newVersionCountdownTimer);
  newVersionCountdownTimer = setInterval(() => {
    render();
    maybeReloadForNewVersion();
  }, 1000);
}

// Only actually reloads once the deadline has passed AND the tab is
// visible — so a reload can never happen (or appear to happen) while
// nobody's looking at it. Also called from visibilitychange so a deadline
// that passed while the tab was hidden triggers the reload the instant
// someone tabs back in, rather than waiting on a throttled interval tick.
function maybeReloadForNewVersion() {
  if (newVersionDeadline == null) return;
  if (Date.now() < newVersionDeadline) return;
  if (document.visibilityState !== "visible") return;
  clearInterval(newVersionCountdownTimer);
  newVersionCountdownTimer = null;
  location.reload();
}

function stopNewVersionCountdown() {
  clearInterval(newVersionCountdownTimer);
  newVersionCountdownTimer = null;
  newVersionDeadline = null;
  const label = $("new-version-countdown");
  if (label) label.textContent = "";
}

// checkNewVersion() above only catches a version bump at the moment the
// page itself loads — a tab left open through a deploy is still running the
// OLD script, with the OLD window.APP_VERSION baked in, so it can never
// notice on its own. This periodically re-fetches the live index.html
// (bypassing the cache) and compares the APP_VERSION baked into THAT
// against what this tab is running; a mismatch means a new build has gone
// out while this tab was open, so it shows the same popup (with that
// build's real patch notes) even though nobody hit refresh.
const VERSION_POLL_INTERVAL_MS = 60_000;

function parsePatchNotes(html) {
  const match = html.match(/window\.PATCH_NOTES\s*=\s*(\[[\s\S]*?\])\s*;/);
  if (!match) return [];
  try {
    // PATCH_NOTES is written as a plain JS array literal (double-quoted
    // strings, an allowed trailing comma) — strip the trailing comma so
    // JSON.parse (safer than eval'ing fetched text) accepts it.
    return JSON.parse(match[1].replace(/,(\s*\])/, "$1"));
  } catch (e) {
    return [];
  }
}

async function pollForNewVersion() {
  try {
    // { cache: "no-store" } only bypasses THIS BROWSER's own HTTP cache —
    // it does nothing about Cloudflare's edge cache sitting in front of the
    // Worker, which can happily keep serving a stale index.html from cache
    // for a while after a deploy even on a "no-store" request. A refresh
    // still worked because enough time had usually passed for that edge
    // cache to expire by then. A cache-busting query string sidesteps this
    // entirely — it's a URL Cloudflare (and the browser) has never cached,
    // so this always reaches the real, current file.
    const res = await fetch(`/index.html?_=${Date.now()}`, {
      cache: "no-store",
      headers: { "Cache-Control": "no-cache", Pragma: "no-cache" },
    });
    if (!res.ok) return;
    const html = await res.text();
    const verMatch = html.match(/window\.APP_VERSION\s*=\s*"([^"]+)"/);
    if (!verMatch) return;
    const liveVersion = verMatch[1];
    if (liveVersion === window.APP_VERSION) return; // still current, nothing to do

    window.APP_VERSION = liveVersion;
    window.PATCH_NOTES = parsePatchNotes(html);
    try {
      localStorage.setItem(SEEN_VERSION_KEY, liveVersion);
    } catch (e) {
      // localStorage unavailable — the popup still shows, it just might
      // show again on a future load in this browser
    }
    showNewVersionPopup();
  } catch (e) {
    // offline / request hiccup — just try again next interval
  }
}

checkNewVersion();
setInterval(pollForNewVersion, VERSION_POLL_INTERVAL_MS);

// Browsers heavily throttle setInterval in a BACKGROUND tab — exactly the
// state this tab is in while someone tabs away to run the deploy commands
// — so the interval above can sit stalled well past 60s the whole time
// nobody's looking. visibilitychange fires immediately (it isn't subject
// to that throttling) the moment the tab is switched back to, which is
// precisely the moment someone would actually be checking for the popup,
// so poll right then too instead of waiting on the throttled interval.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    pollForNewVersion();
    maybeReloadForNewVersion();
  }
});

$("btn-close-new-version-overlay").addEventListener("click", () => {
  $("new-version-overlay").classList.add("hidden");
  stopNewVersionCountdown();
});
$("btn-refresh-now-version").addEventListener("click", () => location.reload());
$("new-version-overlay").addEventListener("click", (e) => {
  if (e.target.id === "new-version-overlay") {
    $("new-version-overlay").classList.add("hidden");
    stopNewVersionCountdown();
  }
});

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
// Mirrors class_defs.mods in schema.sql exactly (see that seed data's
// comment for the design rationale) -- kept in sync by hand, same as the
// class-bonus text already hardcoded on the class-select cards in
// index.html. Used only to DISPLAY each class's real combat-time bonus on
// the Combat Stats panel below; the actual damage math always reads the
// live values from class_defs server-side, this is never sent anywhere.
const CLASS_MODS = {
  warrior: { hp_pct: 5, attack_pct: 5, defense_pct: 5 },
  archer: { attack_pct: 10, defense_pct: -5, crit_chance_flat: 10 },
  magi: { attack_pct: 5, defense_pct: -20, crit_chance_flat: 10, multi_strike_flat: 10 },
  striker: { defense_pct: -10, crit_chance_flat: 20, multi_strike_flat: 20 },
};

// Scoped to #class-grid specifically (the auth-screen picker) so it never
// picks up the near-identical .class-card markup inside the banish overlay
// (#banish-class-grid, wired separately below) — the two pickers track
// independent selections (state.selectedClass vs state.selectedBanishClass).
document.querySelectorAll("#class-grid .class-card").forEach((card) => {
  card.addEventListener("click", () => {
    document.querySelectorAll("#class-grid .class-card").forEach((c) => c.classList.remove("selected"));
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
  // Security question/answer are both optional, but only meaningful as a
  // pair — sent along only when the player filled in both (handle_new_user
  // in schema.sql does the same "both or neither" check server-side, so
  // this is just to avoid a confusing half-set state client-side too).
  const secQuestion = $("auth-security-question").value.trim();
  const secAnswer = $("auth-security-answer").value.trim();
  const signupData = { username, class: state.selectedClass };
  if (secQuestion && secAnswer) {
    signupData.security_question = secQuestion;
    signupData.security_answer = secAnswer;
  }
  const { error } = await sb.auth.signUp({
    email: usernameToFakeEmail(username),
    password,
    options: { data: signupData },
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

// ---------------------------------------------------------------------------
// Forgot password — self-service reset via the optional security question
// set at signup. No email on file (see usernameToFakeEmail above), so this
// is the only recovery path a player has; get_security_question() and
// reset_password_with_security_answer() (schema.sql) are both callable
// while signed out. Two-step overlay: look up the question by username,
// then answer it + pick a new password.
// ---------------------------------------------------------------------------

function resetForgotOverlay() {
  $("forgot-step-username").classList.remove("hidden");
  $("forgot-step-answer").classList.add("hidden");
  $("forgot-username").value = "";
  $("forgot-answer").value = "";
  $("forgot-new-password").value = "";
  $("forgot-new-password2").value = "";
  $("forgot-error").textContent = "";
  $("forgot-success").textContent = "";
  $("forgot-success").classList.add("hidden");
}

$("btn-forgot-password").addEventListener("click", () => {
  resetForgotOverlay();
  $("forgot-password-overlay").classList.remove("hidden");
});
$("btn-close-forgot-overlay").addEventListener("click", () => {
  $("forgot-password-overlay").classList.add("hidden");
});
$("forgot-password-overlay").addEventListener("click", (e) => {
  if (e.target.id === "forgot-password-overlay") $("forgot-password-overlay").classList.add("hidden");
});

$("btn-forgot-lookup").addEventListener("click", async () => {
  const username = $("forgot-username").value.trim();
  $("forgot-error").textContent = "";
  if (!username) return ($("forgot-error").textContent = "Enter your character name.");

  const { data, error } = await sb.rpc("get_security_question", { p_username: username });
  if (error) return ($("forgot-error").textContent = error.message);
  if (!data) {
    return ($("forgot-error").textContent =
      "No security question is set for that character — recovery isn't available for it.");
  }
  $("forgot-question-text").textContent = data;
  $("forgot-step-username").classList.add("hidden");
  $("forgot-step-answer").classList.remove("hidden");
});

$("btn-forgot-reset").addEventListener("click", async () => {
  const username = $("forgot-username").value.trim();
  const answer = $("forgot-answer").value;
  const newPassword = $("forgot-new-password").value;
  const newPassword2 = $("forgot-new-password2").value;
  $("forgot-error").textContent = "";

  if (!answer) return ($("forgot-error").textContent = "Enter your answer.");
  if (newPassword.length < 6) return ($("forgot-error").textContent = "New password must be at least 6 characters.");
  if (newPassword !== newPassword2) return ($("forgot-error").textContent = "Passwords don't match.");

  const { data, error } = await sb.rpc("reset_password_with_security_answer", {
    p_username: username,
    p_answer: answer,
    p_new_password: newPassword,
  });
  if (error) return ($("forgot-error").textContent = error.message);
  if (!data) return ($("forgot-error").textContent = "Incorrect answer.");

  $("forgot-step-answer").classList.add("hidden");
  $("forgot-success").textContent = "Password updated — you can sign in with your new password now.";
  $("forgot-success").classList.remove("hidden");
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
  await loadPack();
  renderBattleStats();
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
  document.querySelectorAll("#class-grid .class-card").forEach((c) => c.classList.remove("selected"));
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

// "1 (+5%)" / "1 (-20%)" / "1" (no annotation when the class has no mod
// for this stat) -- keeps the base number itself an honest, unmodified
// value (what gear will actually move later) while still surfacing the
// class's effect right next to it.
function formatStatWithClassPct(base, pct) {
  if (!pct) return String(base);
  return `${base} (${pct > 0 ? "+" : ""}${pct}%)`;
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
  // Same portrait, small, next to the player's name in Current Battle --
  // mirrors the enemy pack's placeholder art slot so the two sides line up
  // (see .battle-mob-slot in style.css) instead of the enemy's icon+name
  // sitting lower than the player's name with nothing above it.
  $("battle-player-icon").src = portraitSrc;
  $("battle-player-icon").alt = className;
  // Cache the real class so the inline script next to the img tag (see
  // index.html) can set the correct portrait immediately on the NEXT page
  // load, before this profile fetch even starts — that's what stops the
  // portrait flashing the warrior image first and then swapping.
  try {
    localStorage.setItem(LAST_CLASS_KEY, p.class);
  } catch (e) {
    // localStorage unavailable — worst case the flash comes back, harmless
  }

  $("stat-depth").textContent = p.depth;
  $("stat-level").textContent = p.level;
  $("stat-xp").textContent = p.xp;
  $("stat-gold").textContent = p.gold;
  $("stat-prowess").textContent = p.abyssal_prowess;
  $("stat-actions").textContent = p.actions; // shown on the Refresh Actions button now — just the remaining count, no /max

  // Power/Defense/Crit/Multi Strike all get a permanent, always-on bonus
  // from the player's class (see CLASS_MODS above / class_defs in
  // schema.sql) that strike_enemy() applies during every fight but never
  // writes back to these raw profiles columns -- so showing p.attack etc.
  // alone silently hid the class entirely from this panel. Power/Defense
  // keep the base number (gear will actually move that number later) with
  // the class's live percent bonus alongside it; Crit/Multi Strike show
  // the resolved total directly since there's no other source for them yet.
  const classMods = CLASS_MODS[p.class] || {};
  $("stat-power").textContent = formatStatWithClassPct(p.attack, classMods.attack_pct);
  $("stat-defense").textContent = formatStatWithClassPct(p.defense, classMods.defense_pct);
  $("stat-attack-speed").textContent = p.attack_speed;
  $("stat-crit").textContent = `${p.crit + (classMods.crit_chance_flat || 0)}%`;
  $("stat-multi-strike").textContent = `${p.multi_strike + (classMods.multi_strike_flat || 0)}%`;
  $("stat-speed").textContent = p.speed;

  const hpPct = Math.max(0, Math.min(100, (p.hp / p.max_hp) * 100));
  $("player-hp-fill").style.width = hpPct + "%";
  $("player-hp-text").textContent = `${p.hp} / ${p.max_hp} HP`;

  renderEncounterSettings();
}

const LAST_CLASS_KEY = "bita_last_class";

// The 4 difficulty-bracket dropdowns below Refresh Actions. Ranges are
// fixed except Number of Banishments, which depends on the player's own
// Depth (profiles.depth == banishment count) — it goes up to Depth + 3, so
// a player can voluntarily push a few brackets above their own progress
// for better rewards at a real risk of losing (see set_encounter_settings
// in schema.sql, which enforces this same cap server-side).
function renderEncounterSettings() {
  const p = state.profile;
  if (!p) return;
  populateSelect($("sel-affix-count"), 0, 5, p.sel_affix_count);
  populateSelect($("sel-pack-size"), 1, 5, p.sel_pack_size);
  populateSelect($("sel-debuff-count"), 0, 4, p.sel_debuff_count);
  populateSelect($("sel-banishment-bracket"), 0, p.depth + 3, p.sel_banishment_bracket);
}

// Rebuilds a <select>'s options only when the wanted range actually
// changed (e.g. Depth just increased from a banishment) — rebuilding on
// every profile refresh would reset the dropdown's open/focus state for no
// reason on the far more common case where nothing changed.
function populateSelect(select, min, max, selectedValue) {
  if (!select) return;
  const wanted = [];
  for (let v = min; v <= max; v++) wanted.push(String(v));
  const current = Array.from(select.options).map((o) => o.value);
  if (current.join(",") !== wanted.join(",")) {
    select.innerHTML = "";
    wanted.forEach((v) => {
      const opt = document.createElement("option");
      opt.value = v;
      opt.textContent = v;
      select.appendChild(opt);
    });
  }
  select.value = String(selectedValue);
}

// Applies whatever the 4 dropdowns currently say via set_encounter_settings
// (validated server-side too — see schema.sql), then reloads the profile
// (in case the bracket cap needs re-checking) and spawns a fresh pack under
// the new settings. A rejected change (e.g. a stale bracket cap after this
// tab sat open through a banishment elsewhere) snaps the dropdowns back to
// the last known-good server state instead of leaving them showing
// something that didn't actually take effect.
async function applyEncounterSettings() {
  const p_pack_size = parseInt($("sel-pack-size").value, 10);
  const p_affix_count = parseInt($("sel-affix-count").value, 10);
  const p_debuff_count = parseInt($("sel-debuff-count").value, 10);
  const p_banishment_bracket = parseInt($("sel-banishment-bracket").value, 10);

  const { error } = await sb.rpc("set_encounter_settings", {
    p_pack_size,
    p_affix_count,
    p_debuff_count,
    p_banishment_bracket,
  });
  if (error) {
    alert(error.message);
    renderEncounterSettings();
    return;
  }
  await loadProfile();
  await loadPack();
}

["sel-affix-count", "sel-pack-size", "sel-debuff-count", "sel-banishment-bracket"].forEach((id) => {
  $(id)?.addEventListener("change", applyEncounterSettings);
});

// ---------------------------------------------------------------------------
// Pack combat (Test Rat) — drives the Current Battle panel's player vs.
// enemy-pack display independently of guilds. The player fights 1-5
// enemies at once (see the encounter-settings dropdowns above); each has
// its own mini card with a name, hp bar, and a placeholder art slot.
// ---------------------------------------------------------------------------

const TEST_ENEMY_KEY = "test_rat";

async function loadPack() {
  const { data, error } = await sb.rpc("get_or_spawn_pack", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) return console.error(error);
  const row = Array.isArray(data) ? data[0] : data; // single-row RPC shape varies by PostgREST version
  state.pack = Array.isArray(row.pack) ? row.pack : [];
  state.affixNames = Array.isArray(row.affix_names) ? row.affix_names : [];
  state.debuffNames = Array.isArray(row.debuff_names) ? row.debuff_names : [];
  renderPack(state.pack);
  renderActiveModifiers();
}

// Renders the whole pack side of the arena as one card per member — a name,
// hp bar, and a placeholder art slot (swap for a real <img> per enemy_key
// once mob art exists; nothing else here needs to change for that).
// Built with textContent/DOM nodes rather than innerHTML+template strings
// since enemy names, while server-controlled today, shouldn't need an
// escaping audit later just because this function got reused for something
// less trusted.
function renderPack(pack) {
  const container = $("battle-pack");
  if (!container) return;
  container.innerHTML = "";
  pack.forEach((enemy) => {
    const hp = Math.max(0, enemy.hp);
    const card = document.createElement("div");
    card.className = "battle-side battle-enemy pack-member" + (hp <= 0 ? " pack-member-dead" : "");

    const slot = document.createElement("div");
    slot.className = "battle-mob-slot pack-mob-slot";
    const icon = document.createElement("span");
    icon.className = "battle-mob-placeholder-icon";
    icon.textContent = "?";
    slot.appendChild(icon);
    card.appendChild(slot);

    const name = document.createElement("div");
    name.className = "battle-name";
    name.textContent = enemy.name || "—";
    card.appendChild(name);

    const hpBar = document.createElement("div");
    hpBar.className = "hp-bar";
    const hpFill = document.createElement("div");
    hpFill.className = "hp-fill";
    const pct = Math.max(0, Math.min(100, (hp / enemy.max_hp) * 100));
    hpFill.style.width = pct + "%";
    hpBar.appendChild(hpFill);
    card.appendChild(hpBar);

    const hpText = document.createElement("div");
    hpText.className = "battle-hp-text";
    hpText.textContent = `${hp} / ${enemy.max_hp} HP`;
    card.appendChild(hpText);

    container.appendChild(card);
  });
}

// Small note above the battle summary listing this pack's active affixes
// (enemy-side, from Number of Affixes) and debuffs (player-side and
// self-imposed, from Player Debuffs) by name, so it's clear WHY a fight
// suddenly got harder or easier after changing a dropdown.
function renderActiveModifiers() {
  const el = $("active-modifiers");
  if (!el) return;
  const parts = [];
  if (state.affixNames.length) parts.push(`Affixes: ${state.affixNames.join(", ")}`);
  if (state.debuffNames.length) parts.push(`Debuffs: ${state.debuffNames.join(", ")}`);
  el.textContent = parts.join("  •  ");
}

function renderBattlePlayerHp(playerHp, playerMaxHp) {
  const pPct = Math.max(0, Math.min(100, (playerHp / playerMaxHp) * 100));
  $("player-hp-fill").style.width = pPct + "%";
  $("player-hp-text").textContent = `${playerHp} / ${playerMaxHp} HP`;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Renders state.battleStats (running session totals) under the per-tick
// summary line. Idle xp/gold (passive, time-based — see perform_idle_tick
// in schema.sql) are tracked and shown here SEPARATELY from combat, never
// concatenated onto a combat result message — that concatenation used to
// make a death read as if it had been rewarded, when the reward shown was
// actually unrelated passive idle income (combat itself only ever grants
// xp/gold on a win — see strike_enemy). Add a new field to state.battleStats
// and a matching " • Label: value" clause here whenever a new stat/status
// gets tracked.
function renderBattleStats() {
  const s = state.battleStats;
  const el = $("battle-stats-summary");
  if (!el) return;
  el.textContent =
    `Session totals — Dmg dealt: ${s.damageDealt} • Dmg taken: ${s.damageTaken}` +
    ` • Kills: ${s.kills} • Deaths: ${s.deaths} • Idle: +${s.idleXp} xp, +${s.idleGold} gold`;
}

// Fired automatically once per idle tick (see doTick() below) instead of
// from a button. Costs a flat 1 action no matter what — but each call
// resolves one or more whole PACKS (rounds driven by the player's Attack
// Speed stat — see strike_enemy in schema.sql), rolling real
// crit/multi-strike/defense math each round against every still-alive
// member of the current pack. Every pack always runs until someone dies —
// fully cleared, or the player does — rather than stopping partway through
// undecided; either respawns a fresh pack instantly under the same
// selections, so row.final_pack always reflects where the fight ended up.
// XP/GOLD ARE WIN-ONLY: row.xp_gained/gold_gained are only ever nonzero
// when kills > 0 — a pack wipe (deaths > 0) always reports 0 for both,
// enforced server-side in strike_enemy. out_of_actions is only ever true
// when the action pool was already empty before this call started (the
// flat cost means a fight in progress is never cut short by actions
// running out mid-way). Returns a short message for the tick log, or null
// if there's nothing worth reporting (on cooldown, 0 rounds run).
//
// row.rounds_log carries one entry per round actually fought (the whole
// pack's hp right after that round's blows, before any clear/death
// respawn) — without this, the panel only ever showed the state AFTER
// everything had already resolved, which is nearly always a fresh/
// full-looking pack, so it looked like nobody was taking any damage. This
// plays that log back with a short delay per round before settling on the
// true final state, capped well under the 8s tick interval so it always
// finishes before the next tick.
async function autoStrikeEnemy() {
  const { data, error } = await sb.rpc("strike_enemy", { p_enemy_key: TEST_ENEMY_KEY });
  if (error) {
    console.error(error);
    return null;
  }
  const row = data?.[0];
  if (!row) return null;

  const log = Array.isArray(row.rounds_log) ? row.rounds_log : [];

  // Tally running session totals (see state.battleStats). damage_dealt,
  // kills and deaths come straight from the server; damage taken isn't its
  // own return column, so it's summed here from this call's rounds_log
  // (every enemy hit landed this call, whether or not it played back).
  const damageTakenThisCall = log.reduce((sum, entry) => {
    const hits = Array.isArray(entry.hits) ? entry.hits : [];
    return sum + hits.filter((h) => h.source === "enemy").reduce((s, h) => s + (h.dmg || 0), 0);
  }, 0);
  state.battleStats.damageDealt += row.damage_dealt || 0;
  state.battleStats.damageTaken += damageTakenThisCall;
  state.battleStats.kills += row.kills || 0;
  state.battleStats.deaths += row.deaths || 0;
  renderBattleStats();

  if (log.length > 0) {
    // most rounds get a quick beat; a kill/death gets a longer one so the
    // outcome actually registers. Worst case (every round an event, on the
    // largest possible log) still lands well under the tick interval.
    const roundDelayMs = log.length > 15 ? 120 : 200;
    const eventDelayMs = log.length > 15 ? 200 : 350;
    for (const entry of log) {
      renderBattlePlayerHp(entry.player_hp, entry.player_max_hp);
      renderPack(Array.isArray(entry.pack) ? entry.pack : []);
      await sleep(entry.event ? eventDelayMs : roundDelayMs);
    }
  }

  // settle on the true final state regardless of whether anything animated
  // (covers the 0-round cooldown / out-of-actions case too)
  state.pack = Array.isArray(row.final_pack) ? row.final_pack : [];
  state.affixNames = Array.isArray(row.affix_names) ? row.affix_names : [];
  state.debuffNames = Array.isArray(row.debuff_names) ? row.debuff_names : [];
  renderBattlePlayerHp(row.player_hp, row.player_max_hp);
  renderPack(state.pack);
  renderActiveModifiers();

  if (row.rounds_fought === 0) {
    return row.out_of_actions ? "Out of actions — click Refresh Actions to keep fighting." : null;
  }

  const roundsText = `${row.rounds_fought} round${row.rounds_fought === 1 ? "" : "s"}`;
  const outcomes = [];
  if (row.kills > 0) {
    outcomes.push(row.kills === 1 ? "cleared the pack" : `cleared the pack x${row.kills}`);
  }
  if (row.deaths > 0) {
    outcomes.push(row.deaths === 1 ? "were struck down" : `were struck down x${row.deaths}`);
  }

  let msg;
  if (outcomes.length) {
    msg = `You ${outcomes.join(" and ")} over ${roundsText}!`;
    if (row.xp_gained > 0 || row.gold_gained > 0) msg += ` +${row.xp_gained} xp, +${row.gold_gained} gold.`;
  } else {
    msg = `You dealt ${row.damage_dealt} damage over ${roundsText}.`;
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

  // one auto-strike against the current pack per tick — costs 1 action,
  // stops gracefully once the pool is empty (see autoStrikeEnemy above)
  const strikeMsg = await autoStrikeEnemy();

  await loadProfile();

  // Passive idle income (time-based, unrelated to combat) is tracked in
  // the session-totals line, not concatenated onto the combat message —
  // see the comment on renderBattleStats for why that used to be
  // confusing. tick-log shows ONLY the actual combat outcome.
  if (row && (row.xp_gained > 0 || row.gold_gained > 0)) {
    state.battleStats.idleXp += row.xp_gained || 0;
    state.battleStats.idleGold += row.gold_gained || 0;
    renderBattleStats();
  }
  if (strikeMsg) $("tick-log").textContent = strikeMsg;
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

// Banish-overlay class picker — separate markup/selection from the
// auth-screen one (#class-grid / state.selectedClass) so picking a class
// here never touches signup state and vice versa. Defaults to the
// character's CURRENT class each time the overlay opens (see
// renderBanishOverlay below), not to null, so "confirm without touching
// anything" keeps the same class rather than erroring or picking randomly.
document.querySelectorAll("#banish-class-grid .class-card").forEach((card) => {
  card.addEventListener("click", () => {
    document.querySelectorAll("#banish-class-grid .class-card").forEach((c) => c.classList.remove("selected"));
    card.classList.add("selected");
    state.selectedBanishClass = card.dataset.class;
  });
});

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

  state.selectedBanishClass = p.class;
  document.querySelectorAll("#banish-class-grid .class-card").forEach((c) => {
    c.classList.toggle("selected", c.dataset.class === p.class);
  });
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
  const { error } = await sb.rpc("perform_banishment", { p_new_class: state.selectedBanishClass });
  if (error) {
    $("banish-error").textContent = error.message;
    return;
  }
  $("banish-overlay").classList.add("hidden");
  await loadProfile();
  await loadInventory();
  await loadPack();
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
