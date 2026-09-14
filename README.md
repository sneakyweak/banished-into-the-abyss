# Banished Into The Abyss — v0 scaffold

A text/UI idle PBBG scaffold: static frontend (deploy to any static host — Cloudflare Pages, Netlify, or GitHub Pages all work, see §3) + Supabase (Postgres, Auth, Realtime) for everything else. No server to run yourself, no build step, free at the ~400-player scale this is designed for. Full design rationale is in `DESIGN.md` (also saved in the claude.ai Project).

## What's here

```
DESIGN.md            game design doc
netlify.toml          Netlify config (publishes web/, no build step)
supabase/schema.sql   full DB schema, RLS policies, and game-logic functions
web/                  the site itself (plain HTML/CSS/JS, no framework)
  index.html
  css/style.css
  js/config.js         <- put your Supabase URL + anon key here
  js/app.js             all client logic: auth, idle tick, chat, whispers, /send, guilds, boss fights
```

## 1. Create the Supabase project

1. Go to supabase.com and create a free project (pick a region close to where most players will be).
2. In the SQL editor, paste the entire contents of `supabase/schema.sql` and run it. This creates every table, RLS policy, and the game-logic functions (idle tick, guild bosses, chat, whispers, `/send`).
3. In **Authentication -> Settings**, turn **off** "Confirm email". This is required, not optional: players sign up with just a character name and password (see below), and the "email" behind the scenes is a fake, non-deliverable address, so a confirmation link could never reach anyone.
4. In **Project Settings -> API**, copy the **Project URL** and the **anon public key**.

### How the no-email login works

Players only ever see a character name and password — there's no email field anywhere in the UI. Under the hood, Supabase Auth still wants an email or phone as the login identifier (there's no pure "username" mode), so the client (`web/js/app.js`) derives a fake one from the username, e.g. `steve@banished-abyss.invalid` — `.invalid` is a TLD reserved by IANA specifically for addresses guaranteed not to exist. Sign-in reconstructs the same address from the typed username, so no lookup is needed first. This keeps Supabase's actual password hashing/session handling (don't roll your own for something people's accounts depend on) while hiding the email plumbing entirely from players.

The one real tradeoff: there's no working "forgot password" email flow, since these addresses go nowhere. At ~400 players this is usually fine to handle manually — in the Supabase dashboard under **Authentication -> Users**, you can find a player by their fake email (`username@banished-abyss.invalid`) and set a new password for them directly. If that becomes too frequent a request once the game grows, a self-serve reset (e.g. a security question, or a real-email-as-opt-in for recovery only) is a reasonable follow-up, not a v0 requirement.

## 2. Wire up the frontend

Open `web/js/config.js` and paste in those two values:

```js
window.SUPABASE_URL = "https://xxxxx.supabase.co";
window.SUPABASE_ANON_KEY = "eyJ....";
```

The anon key is meant to be public — it only grants whatever your RLS policies and functions allow, which is why `schema.sql` is careful about that.

You can now open `web/index.html` directly in a browser to test locally (or run any static file server, e.g. `npx serve web`).

## 3. Deploy the frontend

**Recommended: Cloudflare Pages.** Unlike Netlify and Vercel, its free tier has no monthly credit budget to run out of — unlimited bandwidth and requests, 500 builds/month, at $0 indefinitely. It also pairs naturally with Cloudflare Registrar if you go that route for the domain (one dashboard for DNS, hosting, and the domain).

1. Go to the Cloudflare dashboard -> **Workers & Pages** -> **Create** -> **Pages** -> **Upload assets**.
2. Name the project (e.g. `banished-into-the-abyss`) and drag in the `web/` folder's contents (not the parent folder — upload `index.html`, `css/`, `js/` directly).
3. Cloudflare gives you a `*.pages.dev` URL immediately. Every time you change files in `web/`, go back to the project and upload a new version the same way.
4. Once you're iterating a lot, connect the project to a GitHub repo instead (push `web/`) for auto-deploys on every push — same idea as Netlify's git integration, just without the credit meter.

**Alternatives**, if you'd rather not use Cloudflare:
- **GitHub Pages** — also fully free with no credit system (soft 100GB/month bandwidth cap, which a text-based game won't come close to), but the repo publishing the Pages site has to be public on the free plan.
- **Netlify** — still fine once your credits reset next billing cycle, or on a paid plan; the site (`banished-into-the-abyss`) and `netlify.toml` are already set up and ready to go whenever you want to use it again.

The frontend has zero framework/build dependencies either way — it's the same static files regardless of host.

## 4. Point your domain at it

Pick any registrar **except IONOS** — Cloudflare Registrar, Porkbun, and Namecheap are all reputable, don't upsell aggressively, and are cheap. Cloudflare Registrar sells at wholesale cost (no markup) and is the most convenient if you're already using Cloudflare Pages (same dashboard, DNS auto-configured); Porkbun and Namecheap are also solid and slightly more traditional, and work fine pointed at any host via CNAME/A records from that host's domain settings.

## 5. Keep the free Supabase project from pausing

Supabase free projects pause after 7 days with **zero** activity. Since idle progress is computed lazily (see `DESIGN.md` §6), the game itself doesn't need a background job — but if literally nobody visits for a week, the project pauses and the site stops working until someone visits the Supabase dashboard to resume it. Cheapest fix: a free scheduled GitHub Action (or a free uptime pinger like UptimeRobot) that hits your Supabase project's REST URL once every few days keeps it warm indefinitely. Not required to launch — just something to set up before you stop checking on the project yourself.

## 6. Balance the numbers

Every constant that needs real playtesting to tune (XP/gold rates, boss HP scaling, cooldowns, send caps) is marked `-- TUNE` in `supabase/schema.sql`. Nothing here is meant to be final — it's calibrated to "plausible enough to test with," not balanced.

## Known v0 gaps (see DESIGN.md §8)

- No moderation tools (mute/ban) yet — worth adding before a public link goes out.
- No guild bank, no PvP, no crafting recipes yet — all deliberately deferred, not forgotten.
- Level/XP curve and Depth thresholds are placeholders.
