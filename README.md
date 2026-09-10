# Full-Stack Tracing for the SvelteKit RealWorld App, with Faro, OpenTelemetry, and Alloy

Most "observability" setups stop at the server. You get a nice trace for your API handler, maybe a span or two around the database call, and then... nothing. The click that actually kicked the whole thing off, sitting in the browser, is invisible. When someone reports "the app was slow for me around 2pm," you're stuck guessing whether the problem was their network, a slow render, a chunky bundle, or an actual backend issue.

This guide wires up the other half, using the [SvelteKit RealWorld example app](https://github.com/sveltejs/realworld) as the test subject rather than a toy app built just for this post. By the end you'll have a single trace that starts at a click in the browser, runs through a SvelteKit server action, and ends at the exact Postgres query it triggered — all connected by one trace ID, all visible in one waterfall in Grafana Cloud.

The stack:

- **App** — the official [sveltejs/realworld](https://github.com/sveltejs/realworld) app (a Medium-style blogging clone called "Conduit"), UI and routes untouched.
- **Database** — Postgres. The stock app doesn't have one (more on that below) — we give it one.
- **Frontend instrumentation** — [Grafana Faro Web SDK](https://github.com/grafana/faro-web-sdk) for RUM, Web Vitals, error capture, and browser-side tracing.
- **Backend instrumentation** — SvelteKit's native OpenTelemetry integration (2.31+), no manual span-wrapping required.
- **Collector** — [Grafana Alloy](https://grafana.com/docs/alloy/latest/), receiving OTLP traces from the backend and scraping Postgres metrics.
- **Backend-for-the-backend** — Grafana Cloud. No local Tempo/Loki/Mimir containers to run and forget about; both Alloy and the Faro SDK ship straight to your Cloud stack.

## An honest heads-up about the starting point

If you go look at `sveltejs/realworld` right now, you'll notice it doesn't have a database, or a backend, in any real sense. Its `+page.server.js` load functions call a public hosted demo API (`api.realworld.show`) over the internet, and it ships with `@sveltejs/adapter-vercel`. That's a perfectly reasonable choice for a frontend showcase — it's not the point of that project to run its own datastore.

It is, however, the whole point of this guide. So Step 1 below is: keep every route, every `.svelte` component, every bit of UI exactly as scaffolded, and swap out the one file that talks to the outside world — `src/lib/api.js` — for a version that talks to a Postgres database sitting right next to it. Same four exported functions (`get`, `post`, `put`, `del`), same signatures, same return shapes. Nothing importing that module has to change.

## Architecture

```mermaid
flowchart LR
    subgraph Browser
        UI[Conduit UI<br/>+ Faro Web SDK]
    end

    subgraph "Node container"
        SK[SvelteKit server<br/>+ OTel SDK]
    end

    subgraph "Postgres container"
        PG[(Postgres)]
    end

    subgraph "Alloy container"
        OR[otelcol.receiver.otlp]
        PE[prometheus.exporter.postgres]
    end

    Cloud[("Grafana Cloud<br/>Tempo · Mimir · Frontend Observability")]

    UI -- "fetch / form POST<br/>traceparent header" --> SK
    UI -- "RUM, web vitals,<br/>errors, browser spans" --> Cloud
    SK -- "OTLP traces<br/>(same trace ID)" --> OR
    SK -- "pg query spans" --> OR
    PE -. "scrapes stats" .-> PG
    OR -- "OTLP, basic auth" --> Cloud
    PE -- "remote_write, basic auth" --> Cloud
```

Two things worth pointing at directly:

- The browser talks to **two** places: your own app (form posts, fetches) and Grafana Cloud directly (Faro's RUM payload). It does not go through Alloy — the Faro collector endpoint is designed to be called straight from client-side JS, the same way you'd embed an analytics snippet.
- Alloy's job shrinks to what actually needs a server-side component: receiving OTLP from your Node process (which needs a stable internal endpoint) and scraping Postgres (which the browser obviously can't do itself).

The arrow that makes this a *connected* trace rather than three separate dashboards is the top one — the `traceparent` header riding along on the browser's own request to your server. That's covered in detail in [Connecting frontend and backend traces](#3-connecting-frontend-and-backend-traces).

## Prerequisites

- Node.js 20+ and [pnpm](https://pnpm.io/) (the app's own package manager)
- Docker and Docker Compose
- A [Grafana Cloud](https://grafana.com/products/cloud/) account — the free tier covers everything here
- About 30-45 minutes

## Environment variables

Every credential and endpoint this stack needs lives in one `.env` file, loaded by Docker Compose and (for Alloy) read at startup via `sys.env(...)`. Nothing is hardcoded into `config.alloy` or committed to the repo.

| Variable | Used by | Where it comes from |
|---|---|---|
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | Postgres, app, Alloy | You choose these — they're local-only credentials |
| `DATABASE_URL` | App, Alloy's Postgres exporter | Built from the three vars above, pointed at the `postgres` service |
| `PORT` | App | Whatever port you want the app to listen on inside the container |
| `ORIGIN` | App | The public URL you load the app from — `adapter-node` checks incoming form POSTs against this for CSRF protection |
| `PUBLIC_APP_ENV` | App, Faro, Alloy | Free-text tag (`local`, `staging`, `production`, …) that shows up as the `environment` attribute on Faro data and as `deployment.environment` on everything passing through Alloy |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | App | Alloy's OTLP address on the internal Docker network — `http://alloy:4317` |
| `PUBLIC_FARO_COLLECTOR_URL` | Frontend (Faro SDK) | **Grafana Cloud → Frontend Observability → your app → "Web SDK Configuration"**. Safe to ship in client JS — it identifies which app to attribute events to, it's not a secret. |
| `GRAFANA_CLOUD_OTLP_ENDPOINT` | Alloy | **Grafana Cloud → your stack → Connections → Add new connection → OpenTelemetry (OTLP)** |
| `GRAFANA_CLOUD_INSTANCE_ID` | Alloy | Same OTLP connection page — used as the Basic Auth username |
| `GRAFANA_CLOUD_API_TOKEN` | Alloy | An [Access Policy Token](https://grafana.com/docs/grafana-cloud/account-management/authentication-and-permissions/access-policies/) with `metrics:write` and `traces:write` scopes, created from **Cloud Portal → Access Policies**. This one's a real secret — it stays server-side in Alloy and never ships to the browser. |

`.env.example` (copy to `.env` and fill in the Grafana Cloud values):

```bash
# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------
POSTGRES_USER=conduit
POSTGRES_PASSWORD=conduit
POSTGRES_DB=conduit
DATABASE_URL=postgresql://conduit:conduit@postgres:5432/conduit?sslmode=disable

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
PORT=3000
ORIGIN=http://localhost:3000
PUBLIC_APP_ENV=local
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317

# ---------------------------------------------------------------------------
# Grafana Cloud — Frontend Observability (Faro)
# Cloud Portal -> Frontend Observability -> your app -> Web SDK Configuration
# ---------------------------------------------------------------------------
PUBLIC_FARO_COLLECTOR_URL=https://faro-collector-prod-us-central-0.grafana.net/collect/00000000000000000000000000000000

# ---------------------------------------------------------------------------
# Grafana Cloud — OTLP gateway (traces + Postgres metrics, via Alloy)
# Cloud Portal -> your stack -> Connections -> OpenTelemetry (OTLP)
# ---------------------------------------------------------------------------
GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-us-central-0.grafana.net/otlp
GRAFANA_CLOUD_INSTANCE_ID=000000
GRAFANA_CLOUD_API_TOKEN=glc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Both the exact endpoint hostnames (`otlp-gateway-prod-us-central-0`, `faro-collector-prod-us-central-0`) are region-specific — copy the real ones from your own stack's pages rather than trusting the placeholders above.

---

## Phase 1 — Give the app a real database

### 1.1 Clone it

```bash
git clone https://github.com/sveltejs/realworld.git conduit
cd conduit
pnpm install
```

Run `pnpm run dev` once just to confirm it boots and talks to the public demo API before you start changing anything — cheap sanity check.

### 1.2 Swap the adapter

`adapter-vercel` is built for Vercel's edge/serverless runtime. We're self-hosting in Docker, and — just as importantly — SvelteKit's instrumentation hook (Phase 2) relies on `adapter-node`'s generated entrypoint to auto-load it. Swap it:

```bash
pnpm remove @sveltejs/adapter-vercel
pnpm add -D @sveltejs/adapter-node
```

`svelte.config.js`:

```js
import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter()
  }
};

export default config;
```

(We'll add the `experimental` block in Phase 2 — no reason to touch it twice.)

### 1.3 The schema

`db/init.sql` — covers users, articles, tags, comments, favorites, and follows, which is everything the app's routes actually call:

```sql
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    username      TEXT UNIQUE NOT NULL,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    bio           TEXT NOT NULL DEFAULT '',
    image         TEXT
);

CREATE TABLE IF NOT EXISTS articles (
    id          SERIAL PRIMARY KEY,
    slug        TEXT UNIQUE NOT NULL,
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT '',
    author_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tags (
    name TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS article_tags (
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    tag_name   TEXT NOT NULL REFERENCES tags(name) ON DELETE CASCADE,
    PRIMARY KEY (article_id, tag_name)
);

CREATE TABLE IF NOT EXISTS favorites (
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, article_id)
);

CREATE TABLE IF NOT EXISTS follows (
    follower_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followed_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (follower_id, followed_id)
);

CREATE TABLE IF NOT EXISTS comments (
    id         SERIAL PRIMARY KEY,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    author_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

No seed data — register a real account through the app's own `/register` page once it's running, which exercises the exact write path we care about anyway.

### 1.4 The connection pool

`src/lib/server/db.js`:

```js
import pg from 'pg';
import { DATABASE_URL } from '$env/static/private';

const { Pool } = pg;

// One pool for the process. adapter-node runs SvelteKit as a single
// long-lived Node server, so this module-level singleton is created once,
// not per-request.
export const pool = new Pool({ connectionString: DATABASE_URL });
```

### 1.5 The actual swap: `src/lib/api.js`

This is the one file we're replacing outright. Back up the original first — you'll want it as a reference:

```bash
mv src/lib/api.js src/lib/api.js.orig
```

Every route in the app calls exactly four functions from this module — `get`, `post`, `put`, `del` — and expects the same JSON shapes back that the real Conduit API returns (`{ articles, articlesCount }`, `{ article }`, `{ user }`, `{ errors }`, and so on). As long as the replacement honors that contract, nothing else in `src/routes/` needs to know the data used to come from `api.realworld.show` and now comes from Postgres three feet away.

```js
import bcrypt from 'bcryptjs';
import { error } from '@sveltejs/kit';
import { pool } from './server/db.js';

// --- auth token helpers -----------------------------------------------
// The app already base64-encodes whatever `user.token` we hand back into a
// cookie (see src/hooks.server.js) and returns it to us on every subsequent
// call. It doesn't need to be a cryptographically real JWT for this to
// work — it just needs to be something we can turn back into a user id.
// Don't ship this token scheme anywhere that matters.
function encodeToken(userId) {
  return Buffer.from(`uid:${userId}`).toString('base64');
}

function decodeToken(token) {
  if (!token) return null;
  try {
    const match = Buffer.from(token, 'base64').toString('utf8').match(/^uid:(\d+)$/);
    return match ? Number(match[1]) : null;
  } catch {
    return null;
  }
}

function toUserJson(row) {
  return {
    email: row.email,
    username: row.username,
    bio: row.bio ?? '',
    image: row.image,
    token: encodeToken(row.id)
  };
}

function slugify(title) {
  const base = title.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
  return `${base}-${Math.random().toString(36).slice(2, 8)}`;
}

function mapArticleRow(row) {
  return {
    slug: row.slug,
    title: row.title,
    description: row.description,
    body: row.body,
    tagList: row.tag_list ?? [],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    favorited: row.favorited,
    favoritesCount: Number(row.favorites_count),
    author: {
      username: row.author_username,
      bio: row.author_bio ?? '',
      image: row.author_image,
      following: row.following
    }
  };
}

// --- articles -----------------------------------------------------------

async function listArticles({ tag, author, favorited, feedFor, limit, offset }, currentUserId) {
  const params = [currentUserId ?? null];
  const conditions = [];

  if (feedFor && !currentUserId) error(401);

  if (tag) {
    params.push(tag);
    conditions.push(`a.id IN (SELECT article_id FROM article_tags WHERE tag_name = $${params.length})`);
  }
  if (author) {
    params.push(author);
    conditions.push(`u.username = $${params.length}`);
  }
  if (favorited) {
    params.push(favorited);
    conditions.push(`a.id IN (
      SELECT f.article_id FROM favorites f JOIN users fu ON fu.id = f.user_id
      WHERE fu.username = $${params.length}
    )`);
  }
  if (feedFor) {
    params.push(feedFor);
    conditions.push(`a.author_id IN (SELECT followed_id FROM follows WHERE follower_id = $${params.length})`);
  }

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $1) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $1 AND followed_id = a.author_id) AS following,
      count(*) OVER() AS full_count
    FROM articles a
    JOIN users u ON u.id = a.author_id
    ${where}
    ORDER BY a.created_at DESC
    LIMIT $${limitIdx} OFFSET $${offsetIdx}
    `,
    params
  );

  return {
    articles: rows.map(mapArticleRow),
    articlesCount: rows.length ? Number(rows[0].full_count) : 0
  };
}

async function getArticleBySlug(slug, currentUserId) {
  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $2) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = a.author_id) AS following
    FROM articles a
    JOIN users u ON u.id = a.author_id
    WHERE a.slug = $1
    `,
    [slug, currentUserId ?? null]
  );

  if (!rows.length) error(404, 'Article not found');
  return mapArticleRow(rows[0]);
}

async function createArticle(userId, { title, description, body, tagList = [] }) {
  const slug = slugify(title);

  const { rows } = await pool.query(
    `INSERT INTO articles (slug, title, description, body, author_id) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
    [slug, title, description, body, userId]
  );
  const articleId = rows[0].id;

  for (const name of tagList) {
    await pool.query(`INSERT INTO tags (name) VALUES ($1) ON CONFLICT DO NOTHING`, [name]);
    await pool.query(
      `INSERT INTO article_tags (article_id, tag_name) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [articleId, name]
    );
  }

  return getArticleBySlug(slug, userId);
}

async function updateArticle(slug, { title, description, body }, currentUserId) {
  // Kept intentionally simple — this updates the article's own fields but not
  // its tagList. Extend it the same way createArticle handles tags if you need that.
  await pool.query(
    `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),
      body = COALESCE($4, body), updated_at = now() WHERE slug = $1`,
    [slug, title || null, description || null, body || null]
  );
  return getArticleBySlug(slug, currentUserId);
}

async function deleteArticle(slug) {
  await pool.query(`DELETE FROM articles WHERE slug = $1`, [slug]);
}

async function setFavorite(slug, userId, favorited) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  if (favorited) {
    await pool.query(`INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      userId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`, [userId, rows[0].id]);
  }

  return getArticleBySlug(slug, userId);
}

async function listTags() {
  const { rows } = await pool.query(`SELECT name FROM tags ORDER BY name`);
  return rows.map((r) => r.name);
}

// --- comments -------------------------------------------------------------

async function listComments(slug) {
  const { rows } = await pool.query(
    `SELECT c.id, c.body, c.created_at, c.updated_at,
            u.username AS author_username, u.bio AS author_bio, u.image AS author_image
     FROM comments c JOIN articles a ON a.id = c.article_id JOIN users u ON u.id = c.author_id
     WHERE a.slug = $1 ORDER BY c.created_at ASC`,
    [slug]
  );

  return rows.map((r) => ({
    id: r.id,
    body: r.body,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    author: { username: r.author_username, bio: r.author_bio ?? '', image: r.author_image }
  }));
}

async function addComment(slug, userId, body) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  const { rows: inserted } = await pool.query(
    `INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at`,
    [rows[0].id, userId, body]
  );
  const { rows: authorRows } = await pool.query(`SELECT username, bio, image FROM users WHERE id = $1`, [userId]);

  const c = inserted[0];
  return { id: c.id, body: c.body, createdAt: c.created_at, updatedAt: c.updated_at, author: authorRows[0] };
}

async function deleteComment(id) {
  await pool.query(`DELETE FROM comments WHERE id = $1`, [id]);
}

// --- profiles / follows -----------------------------------------------------

async function getProfile(username, currentUserId) {
  const { rows } = await pool.query(
    `SELECT u.username, u.bio, u.image,
            EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = u.id) AS following
     FROM users u WHERE u.username = $1`,
    [username, currentUserId ?? null]
  );
  if (!rows.length) error(404, 'User not found');
  return rows[0];
}

async function setFollow(username, followerId, follow) {
  const { rows } = await pool.query(`SELECT id FROM users WHERE username = $1`, [username]);
  if (!rows.length) error(404, 'User not found');

  if (follow) {
    await pool.query(`INSERT INTO follows (follower_id, followed_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      followerId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM follows WHERE follower_id = $1 AND followed_id = $2`, [followerId, rows[0].id]);
  }

  return getProfile(username, followerId);
}

// --- users ------------------------------------------------------------------

async function login(email, password) {
  const { rows } = await pool.query(`SELECT * FROM users WHERE email = $1`, [email]);
  if (!rows.length || !(await bcrypt.compare(password, rows[0].password_hash))) {
    return { errors: { 'email or password': ['is invalid'] } };
  }
  return { user: toUserJson(rows[0]) };
}

async function register(username, email, password) {
  try {
    const password_hash = await bcrypt.hash(password, 10);
    const { rows } = await pool.query(
      `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING *`,
      [username, email, password_hash]
    );
    return { user: toUserJson(rows[0]) };
  } catch (err) {
    if (err.code === '23505') return { errors: { 'username or email': ['is already taken'] } };
    throw err;
  }
}

async function updateUser(userId, { username, email, password, image, bio }) {
  const password_hash = password ? await bcrypt.hash(password, 10) : null;
  const { rows } = await pool.query(
    `UPDATE users SET username = COALESCE($2, username), email = COALESCE($3, email),
      password_hash = COALESCE($4, password_hash), image = COALESCE($5, image), bio = COALESCE($6, bio)
     WHERE id = $1 RETURNING *`,
    [userId, username || null, email || null, password_hash, image || null, bio || null]
  );
  return { user: toUserJson(rows[0]) };
}

// --- the router ---------------------------------------------------------
// Everything above is the "database" half. Everything below just maps the
// same (method, path) pairs the app already calls onto those functions —
// this is the part that keeps the four exports below a drop-in replacement.

async function send({ method, path, data, token }) {
  const [route, query = ''] = path.split('?');
  const params = new URLSearchParams(query);
  const segments = route.split('/').filter(Boolean);
  const currentUserId = decodeToken(token);

  if (method === 'GET' && route === 'tags') {
    return { tags: await listTags() };
  }

  if (method === 'GET' && (route === 'articles' || route === 'articles/feed')) {
    return listArticles(
      {
        limit: Number(params.get('limit') ?? 20),
        offset: Number(params.get('offset') ?? 0),
        tag: params.get('tag') || undefined,
        author: params.get('author') || undefined,
        favorited: params.get('favorited') || undefined,
        feedFor: route === 'articles/feed' ? currentUserId : undefined
      },
      currentUserId
    );
  }

  if (method === 'POST' && route === 'articles') {
    if (!currentUserId) error(401);
    return { article: await createArticle(currentUserId, data.article) };
  }

  if (segments[0] === 'articles' && segments.length === 2) {
    const slug = segments[1];
    if (method === 'GET') return { article: await getArticleBySlug(slug, currentUserId) };
    if (method === 'PUT') {
      if (!currentUserId) error(401);
      return { article: await updateArticle(slug, data.article, currentUserId) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteArticle(slug);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'comments') {
    const slug = segments[1];
    if (method === 'GET') return { comments: await listComments(slug) };
    if (method === 'POST') {
      if (!currentUserId) error(401);
      return { comment: await addComment(slug, currentUserId, data.comment.body) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteComment(segments[3]);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'favorite') {
    if (!currentUserId) error(401);
    return { article: await setFavorite(segments[1], currentUserId, method === 'POST') };
  }

  if (segments[0] === 'profiles' && segments.length === 2) {
    return { profile: await getProfile(segments[1], currentUserId) };
  }

  if (segments[0] === 'profiles' && segments[2] === 'follow') {
    if (!currentUserId) error(401);
    return { profile: await setFollow(segments[1], currentUserId, method === 'POST') };
  }

  if (method === 'POST' && route === 'users/login') {
    return login(data.user.email, data.user.password);
  }

  if (method === 'POST' && route === 'users') {
    return register(data.user.username, data.user.email, data.user.password);
  }

  if (method === 'PUT' && route === 'user') {
    if (!currentUserId) error(401);
    return updateUser(currentUserId, data.user);
  }

  error(404, `no local handler for ${method} ${route}`);
}

export function get(path, token) {
  return send({ method: 'GET', path, token });
}
export function del(path, token) {
  return send({ method: 'DELETE', path, token });
}
export function post(path, data, token) {
  return send({ method: 'POST', path, data, token });
}
export function put(path, data, token) {
  return send({ method: 'PUT', path, data, token });
}
```

Install what it needs:

```bash
pnpm add pg bcryptjs
```

### 1.6 Dockerfile

The repo uses pnpm, so the multi-stage build does too:

```dockerfile
# ---- build ----
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
# pnpm's own prune refuses to run non-interactively otherwise ("no TTY")
ENV CI=true

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm run build
RUN pnpm prune --prod

# ---- runtime ----
FROM node:22-alpine AS runtime
WORKDIR /app
RUN corepack enable
ENV NODE_ENV=production

COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

EXPOSE 3000
CMD ["node", "build"]
```

### 1.7 docker-compose (baseline — just app + Postgres)

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    build: .
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    ports:
      - "3000:3000"

volumes:
  pgdata:
```

Copy `.env.example` to `.env`, fill in at least the Postgres block (skip the Grafana Cloud values for now — nothing reads them yet), then:

```bash
docker compose up --build
```

Visit `http://localhost:3000`, register an account, write an article, favorite something, follow a profile. Confirm it all persists across a restart. That's Phase 1 — the real RealWorld app, running against a database you actually control, with zero visibility into what it's doing. Let's fix that part.

---

## Phase 2 — Instrument everything

### 2.1 Frontend: Grafana Faro Web SDK

Grafana Cloud → **Frontend Observability** → your app → **Configure** walks you through this exact setup, and it's worth following its snippet almost verbatim rather than inventing your own shape — that page is also where `PUBLIC_FARO_COLLECTOR_URL` comes from.

**Choose your package type and install Faro.** The Cloud UI gives you the `npm` form; here's the `pnpm` equivalent since that's what this app uses:

```bash
pnpm add @grafana/faro-web-sdk @grafana/faro-web-tracing
```

**Session settings.** The Cloud UI also lets you set a session **Sampling Rate** (default 100%, i.e. every session tracked) and toggle **Persistent sessions** (sticky sessions that survive closing the tab, default off). Leave both at their defaults for this guide — they map to a `sessionTracking: { samplingRate, persistent }` block on `initializeFaro` that you only need to add if you actually change them from the defaults shown in the UI.

**Add Faro to your application.** The UI's own snippet — which we're matching structurally — looks like this:

```js
import { getWebInstrumentations, initializeFaro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

initializeFaro({
  url: 'https://faro-collector-prod-us-central-0.grafana.net/collect/<your-app-key>',
  app: {
    name: 'temp',
    version: '1.0.0',
    environment: 'production'
  },
  instrumentations: [
    // Mandatory, omits default instrumentations otherwise.
    ...getWebInstrumentations(),

    // Tracing package to get end-to-end visibility for HTTP requests.
    new TracingInstrumentation()
  ]
});
```

We're wrapping that in a small module so it survives Vite's dev-mode HMR without double-initializing, and so the collector URL and environment name come from our own env vars rather than being hardcoded. `src/lib/faro.js`:

```js
import { getWebInstrumentations, initializeFaro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

let faro;

export function initFaro(collectorUrl, environment) {
  if (faro) return faro; // guard against HMR re-init in dev

  faro = initializeFaro({
    url: collectorUrl,
    app: {
      name: 'conduit-frontend',
      version: '1.0.0',
      environment
    },
    instrumentations: [
      // Mandatory, omits default instrumentations otherwise.
      ...getWebInstrumentations(),

      // Tracing package to get end-to-end visibility for HTTP requests.
      new TracingInstrumentation()
    ]
  });

  return faro;
}
```

`src/hooks.client.js` (new file — the app doesn't have one yet):

```js
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro.js';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'local');
}
```

`PUBLIC_FARO_COLLECTOR_URL` points straight at the collector URL from that Configure page — see the [environment variables table](#environment-variables) above. We're reading it via `$env/dynamic/public` rather than `$env/static/public` specifically so the same built Docker image works against different collector URLs without a rebuild — static public vars get baked into the client bundle at build time, dynamic ones are read from the container's environment at request time.

Notice the `TracingInstrumentation()` above is bare, with no options — that's not a simplification on our part, it's exactly what the Cloud UI's own snippet gives you. Whether that's enough for full continuity depends on one thing, covered next.

### 2.2 Backend: SvelteKit's native OpenTelemetry support

SvelteKit 2.31 added a first-class OpenTelemetry integration: an instrumentation hook (conceptually the same idea as Next.js's `instrumentation.ts`) plus automatic spans around routing, `load` functions, and form actions — no more hand-wrapping `handle` in `hooks.server.js` and hoping you caught every code path.

Turn it on in `svelte.config.js`:

```js
import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    experimental: {
      // load src/instrumentation.server.js before any application code runs
      instrumentation: { server: true },
      // wrap SvelteKit's own internals (handle, load, actions) in spans
      tracing: { server: true }
    }
  }
};

export default config;
```

Install the OTel SDK pieces:

```bash
pnpm add @opentelemetry/api @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/resources @opentelemetry/semantic-conventions
```

`src/instrumentation.server.js`:

```js
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: 'conduit-backend',
    [ATTR_SERVICE_VERSION]: '1.0.0'
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4317'
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // noisy and rarely worth the cardinality in a demo like this
      '@opentelemetry/instrumentation-fs': { enabled: false }
    })
  ]
});

sdk.start();
```

Ordering matters more here than it looks like it should. `getNodeAutoInstrumentations()` works by monkey-patching modules (`http`, `pg`, …) the first time they're `require`'d. If your app imports `pg` before this SDK starts, the patch never applies and you silently get no database spans. The `instrumentation.server` flag exists specifically to solve that — it tells the build produced by `adapter-node` to `--import` this file before your app's own entrypoint, so plain `node build` in the Dockerfile's `CMD` picks it up automatically, no extra flags needed.

This is also why you get Postgres query spans for free, without instrumenting `pool.query(...)` calls by hand: `@opentelemetry/instrumentation-pg` ships inside `auto-instrumentations-node`, and because our `pg` import in `db.js` is a totally ordinary one, it gets patched right along with everything else. Every query in the `api.js` we wrote in Phase 1 now produces a real child span with the SQL text attached — actual per-query tracing, not to be confused with the Postgres *metrics* Alloy scrapes below, which is a different, complementary layer (connection counts, cache hit ratio — the stuff a single trace can't tell you).

### 2.3 Connecting frontend and backend traces

This is the mechanism that turns two separate instrumentation efforts into one observability story, so it's worth being explicit about it rather than just asserting "it works."

1. The browser submits the login form (or any `fetch` call fires). Faro's `TracingInstrumentation` intercepts it and starts a client-side span.
2. Because the request target (`http://localhost:3000/...`) is the **same origin** the page itself was loaded from, the underlying instrumentation attaches a [W3C `traceparent` header](https://www.w3.org/TR/trace-context/) automatically — no extra config required. It looks something like `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`, encoding the trace ID, the parent span ID, and sampling flags.
3. The request lands on the SvelteKit server. The `http` instrumentation inside `getNodeAutoInstrumentations()` reads that header off the incoming request and, instead of minting a new trace, continues the existing one — the first server-side span becomes a *child* of the browser's span, not a sibling.
4. Every span created after that in the same request — SvelteKit's own `tracing.server` spans around the action, the `pg` instrumentation's query span — inherits that same trace context via `AsyncLocalStorage`, which is how OpenTelemetry's Node context manager propagates state through async calls.
5. The browser ships its span to Grafana Cloud's Faro collector directly; the server ships its spans to Alloy, which forwards them to Grafana Cloud's OTLP gateway. Both land in the same Tempo instance. Tempo doesn't care which door a span came in through — it just assembles anything sharing a trace ID into one waterfall.

Net effect: open a trace in Grafana and the root span is a literal click, with the `INSERT INTO comments` (or whatever the action was) sitting a few levels down as a leaf. I checked this directly rather than taking it on faith — sending a request with a hand-crafted `traceparent` header and inspecting the resulting spans showed every one of them, including the `pg` query spans, carrying that exact trace ID, with the root span's parent marked `isRemote: true`.

The one thing that *would* break this: if your frontend and backend aren't actually on the same origin — a separate `api.yourapp.com` host, or a static frontend on a CDN calling back to a different origin server. Browsers only let JS attach arbitrary headers to a cross-origin request if that's been explicitly opted into, so `@grafana/faro-web-tracing` requires you to allow-list it: `new TracingInstrumentation({ instrumentationOptions: { propagateTraceHeaderCorsUrls: [/api\.yourapp\.com/] } })`. Conduit's frontend and backend are served from the same SvelteKit process on the same origin, which is exactly why the Cloud UI's default snippet — the bare `TracingInstrumentation()` from [2.1](#21-frontend-grafana-faro-web-sdk) — is already enough here. If a trace ever shows up split into a frontend-only piece and a backend-only piece instead of one merged waterfall, a same-origin mismatch (wrong port, `www.` vs. bare domain, http vs. https) is the first thing to check, and a genuinely cross-origin setup missing `propagateTraceHeaderCorsUrls` is the second.

### 2.4 Collector: Grafana Alloy

Alloy has two jobs left, now that Faro reports straight to Grafana Cloud:

1. Accept OTLP traces from the SvelteKit backend.
2. Scrape Postgres for database-level metrics, using `prometheus.exporter.postgres` — an embedded exporter, no separate `postgres_exporter` container.

...then forward both to Grafana Cloud, authenticated.

Rather than hand-rolling a minimal pipeline, `alloy/config.alloy` below follows the shape Grafana Cloud's own "Configure Alloy" onboarding page suggests for a generic OTLP source — resource detection and a couple of attribute-cleanup passes included, not just a bare receiver-to-exporter pipe. It's more boilerplate than the smallest thing that could work, but it's boilerplate you'd otherwise end up writing yourself the first time you actually looked at what lands in Tempo:

```alloy
otelcol.receiver.otlp "default" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.receiver.otlp/

  // configures the default grpc endpoint "0.0.0.0:4317"
  grpc { }
  // configures the default http/protobuf endpoint "0.0.0.0:4318"
  http { }

  output {
    metrics = [otelcol.processor.resourcedetection.default.input]
    logs    = [otelcol.processor.resourcedetection.default.input]
    traces  = [otelcol.processor.resourcedetection.default.input]
  }
}

// Postgres metrics feed into the exact same enrichment pipeline as
// whatever the backend sends over OTLP above — one otelcol.receiver.prometheus
// bridges the prometheus.* scrape into it.
prometheus.exporter.postgres "conduit_db" {
  data_source_names = [sys.env("DATABASE_URL")]
}

prometheus.scrape "conduit_db" {
  targets         = prometheus.exporter.postgres.conduit_db.targets
  scrape_interval = "15s"
  forward_to      = [otelcol.receiver.prometheus.postgres.receiver]
}

otelcol.receiver.prometheus "postgres" {
  output {
    metrics = [otelcol.processor.resourcedetection.default.input]
  }
}

otelcol.processor.resourcedetection "default" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.processor.resourcedetection/
  detectors = ["env", "system"]

  system {
    hostname_sources = ["os"]

    resource_attributes {
      host.id   { enabled = true }
      host.name { enabled = true }
    }
  }

  output {
    metrics = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
    logs    = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
    traces  = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
  }
}

otelcol.processor.transform "drop_unneeded_resource_attributes" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.processor.transform/
  error_mode = "ignore"

  trace_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  metric_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  log_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  output {
    metrics = [otelcol.processor.transform.add_resource_attributes_as_metric_attributes.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.transform "add_resource_attributes_as_metric_attributes" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.processor.transform/
  error_mode = "ignore"

  metric_statements {
    context    = "datapoint"
    statements = [
      "set(attributes[\"deployment.environment\"], resource.attributes[\"deployment.environment\"])",
      "set(attributes[\"service.version\"], resource.attributes[\"service.version\"])",
    ]
  }

  output {
    metrics = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.processor.batch/
  output {
    metrics = [otelcol.exporter.otlphttp.grafana_cloud.input]
    logs    = [otelcol.exporter.otlphttp.grafana_cloud.input]
    traces  = [otelcol.exporter.otlphttp.grafana_cloud.input]
  }
}

otelcol.exporter.otlphttp "grafana_cloud" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.exporter.otlphttp/
  client {
    endpoint = sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")
    auth     = otelcol.auth.basic.grafana_cloud.handler
  }
}

otelcol.auth.basic "grafana_cloud" {
  // https://grafana.com/docs/alloy/latest/reference/components/otelcol.auth.basic/
  username = sys.env("GRAFANA_CLOUD_INSTANCE_ID")
  password = sys.env("GRAFANA_CLOUD_API_TOKEN")
}
```

A few things worth being explicit about, since most of this differs from what you'd write starting from a blank file:

- **`otelcol.receiver.prometheus`** is still the bridge component that lets a `prometheus.scrape` target's output flow into an otelcol pipeline — same role it played before, just renamed to `"postgres"` here since it now sits alongside the receiver for the backend's own OTLP traffic rather than being the only thing in the file.
- **`resourcedetection`** stamps every span, metric, and log with attributes about *where Alloy itself is running* — container/host identity, mainly — which is a genuinely useful thing to have on data whether or not you asked for it, hence why the Cloud UI defaults to including it rather than leaving it as a manual add-on.
- **The two `transform` processors exist for a very specific reason**: `getNodeAutoInstrumentations()` on the Node side (and `resourcedetection`'s own `system` detector) attach a pile of process/OS resource attributes — PID, executable path, OS description, and so on — that are mostly noise once you're looking at a dashboard rather than a single trace. The first `transform` deletes them. The second exists because Prometheus/Mimir metrics don't have a concept of "resource" attributes the way traces and logs do — only per-series labels — so `deployment.environment` and `service.version` have to be explicitly copied from the resource onto every metric *datapoint* or they're silently dropped rather than becoming queryable labels.
- **`otelcol.auth.basic`** turns your instance ID and API token into the Basic Auth header Grafana Cloud's OTLP gateway expects, and it's attached to the *exporter*, not the receiver — Alloy itself doesn't require auth from your own app, only Grafana Cloud does. Grafana Cloud's own generated snippet for this hardcodes both values directly into `config.alloy` (`username = "477393"`, `password = "your-grafana-token"` — literally your API token, in plaintext, in a file you're one `git add .` away from committing). We're reading both from `sys.env(...)` instead, same as everywhere else in this guide, specifically so that never happens.
- **The exporter is `otelcol.exporter.otlphttp`, not `otelcol.exporter.otlp`.** Grafana Cloud's OTLP gateway only accepts OTLP over HTTP — the endpoint URL even has an HTTP path on it (`/otlp`). The plain `otelcol.exporter.otlp` component defaults to gRPC, and pointing it at this endpoint fails with a gRPC resolver error (`no children to pick from`) rather than anything that obviously says "wrong protocol." I hit exactly this running the stack against a real Grafana Cloud account while writing this guide — if you see that error, this is almost certainly why.

One more thing worth calling out: the Postgres user in `DATABASE_URL` is the same one the app itself uses, for simplicity. Past a local demo, give the exporter its own read-only role instead — `GRANT pg_monitor TO exporter_user;` is enough for the stats views it needs, and there's no reason to hand it your application credentials.

The `add_resource_attributes_as_metric_attributes` processor above only does something useful if a `deployment.environment` resource attribute actually exists on the data flowing through it — our Node backend's own resource (in `instrumentation.server.js`) only sets `service.name` and `service.version`. Rather than touch the app for this, we set it once, centrally, on the collector: the `alloy` service in `docker-compose.yml` gets `OTEL_RESOURCE_ATTRIBUTES: deployment.environment=${PUBLIC_APP_ENV}`, which is the standard OpenTelemetry environment variable every "env" resource detector — this one included — already knows to read.

### 2.5 Full docker-compose

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    build: .
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      alloy:
        condition: service_started
    env_file: .env
    ports:
      - "3000:3000"

  alloy:
    image: grafana/alloy:latest
    restart: unless-stopped
    env_file: .env
    environment:
      # picked up by config.alloy's resourcedetection "env" detector and
      # stamped onto every span/metric/log passing through Alloy
      OTEL_RESOURCE_ATTRIBUTES: deployment.environment=${PUBLIC_APP_ENV}
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    ports:
      - "12345:12345" # Alloy's own UI — a live graph of the pipeline above, worth a look
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  pgdata:
```

Fill in the full `.env` — Postgres block plus both Grafana Cloud sections this time — and run it:

```bash
docker compose up --build
```

### 2.6 See it in Grafana Cloud

- App: `http://localhost:3000`. Register, log in, write an article, add a comment.
- Alloy's UI: `http://localhost:12345` — renders the component graph from `config.alloy` visually, which makes wiring mistakes obvious the first time through.
- In your Grafana Cloud stack:
  - **Frontend Observability** — RUM sessions, Web Vitals, and the browser-side event stream for `conduit-frontend` shows up here within a few seconds of using the app.
  - **Explore → Tempo** — search by service name `conduit-frontend` or `conduit-backend`, open a trace from a comment submission. The root span should be the browser click, with the SvelteKit action and the `INSERT INTO comments` query nested underneath it.
  - **Explore → Metrics (Mimir)** — query `pg_up` or browse `pg_stat_*` to confirm the Postgres scrape is landing.

---

## Do it with one command instead

Everything in Phase 1.2–1.5 and all of Phase 2 is mechanical — the same files, every time, regardless of which checkout you're doing this to. `scripts/instrument.sh` in this repo applies all of it to a freshly cloned `sveltejs/realworld` checkout in one pass: swaps the adapter, writes `db/init.sql`, `src/lib/server/db.js`, the Postgres-backed `src/lib/api.js`, `src/instrumentation.server.js`, `src/hooks.client.js`, `src/lib/faro.js`, the `Dockerfile`, `docker-compose.yml`, `alloy/config.alloy`, and a `.env.example` — installing every package along the way.

```bash
git clone https://github.com/sveltejs/realworld.git conduit
cd conduit
curl -fsSL https://raw.githubusercontent.com/colinedwardwood/faro-to-otel-tracing/main/scripts/instrument.sh | bash
cp .env.example .env   # then fill in your Grafana Cloud values
docker compose up --build
```

Or clone this repo and run it locally instead of piping from `curl`, if you'd rather read it first (recommended — see below).

It does *not* create a Grafana Cloud account or generate credentials for you — that step is still on you, since it's tied to your own account. Full script: [`scripts/instrument.sh`](scripts/instrument.sh).

<details>
<summary>Full script contents</summary>

```bash
#!/usr/bin/env bash
set -euo pipefail

# Run from the root of a freshly cloned https://github.com/sveltejs/realworld
# checkout. Swaps the adapter, adds Faro + OpenTelemetry instrumentation,
# replaces the data layer with a local Postgres-backed implementation, and
# drops in the Docker/Alloy/Grafana Cloud plumbing from the README this
# script ships alongside. It never touches src/routes/ or any .svelte file.

if [ ! -f "src/lib/api.js" ]; then
  echo "error: src/lib/api.js not found — run this from the root of a sveltejs/realworld checkout" >&2
  exit 1
fi

echo "==> Swapping adapter-vercel for adapter-node"
pnpm remove @sveltejs/adapter-vercel 2>/dev/null || true
pnpm add -D @sveltejs/adapter-node

echo "==> Installing runtime + instrumentation dependencies"
pnpm add pg bcryptjs \
  @opentelemetry/api @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc @opentelemetry/resources @opentelemetry/semantic-conventions \
  @grafana/faro-web-sdk @grafana/faro-web-tracing

mkdir -p src/lib/server db alloy

echo "==> svelte.config.js"
cat > svelte.config.js <<'EOF'
import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    experimental: {
      instrumentation: { server: true },
      tracing: { server: true }
    }
  }
};

export default config;
EOF

echo "==> src/instrumentation.server.js"
cat > src/instrumentation.server.js <<'EOF'
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: 'conduit-backend',
    [ATTR_SERVICE_VERSION]: '1.0.0'
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4317'
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false }
    })
  ]
});

sdk.start();
EOF

echo "==> src/hooks.client.js"
cat > src/hooks.client.js <<'EOF'
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro.js';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'local');
}
EOF

echo "==> src/lib/faro.js"
cat > src/lib/faro.js <<'EOF'
import { getWebInstrumentations, initializeFaro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

let faro;

export function initFaro(collectorUrl, environment) {
  if (faro) return faro;

  faro = initializeFaro({
    url: collectorUrl,
    app: {
      name: 'conduit-frontend',
      version: '1.0.0',
      environment
    },
    instrumentations: [
      // Mandatory, omits default instrumentations otherwise.
      ...getWebInstrumentations(),

      // Tracing package to get end-to-end visibility for HTTP requests.
      new TracingInstrumentation()
    ]
  });

  return faro;
}
EOF

echo "==> src/lib/server/db.js"
cat > src/lib/server/db.js <<'EOF'
import pg from 'pg';
import { DATABASE_URL } from '$env/static/private';

const { Pool } = pg;

export const pool = new Pool({ connectionString: DATABASE_URL });
EOF

echo "==> src/lib/api.js (backing up the original to src/lib/api.js.orig)"
if [ ! -f src/lib/api.js.orig ]; then
  cp src/lib/api.js src/lib/api.js.orig
fi
cat > src/lib/api.js <<'EOF'
import bcrypt from 'bcryptjs';
import { error } from '@sveltejs/kit';
import { pool } from './server/db.js';

function encodeToken(userId) {
  return Buffer.from(`uid:${userId}`).toString('base64');
}

function decodeToken(token) {
  if (!token) return null;
  try {
    const match = Buffer.from(token, 'base64').toString('utf8').match(/^uid:(\d+)$/);
    return match ? Number(match[1]) : null;
  } catch {
    return null;
  }
}

function toUserJson(row) {
  return {
    email: row.email,
    username: row.username,
    bio: row.bio ?? '',
    image: row.image,
    token: encodeToken(row.id)
  };
}

function slugify(title) {
  const base = title.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
  return `${base}-${Math.random().toString(36).slice(2, 8)}`;
}

function mapArticleRow(row) {
  return {
    slug: row.slug,
    title: row.title,
    description: row.description,
    body: row.body,
    tagList: row.tag_list ?? [],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    favorited: row.favorited,
    favoritesCount: Number(row.favorites_count),
    author: {
      username: row.author_username,
      bio: row.author_bio ?? '',
      image: row.author_image,
      following: row.following
    }
  };
}

async function listArticles({ tag, author, favorited, feedFor, limit, offset }, currentUserId) {
  const params = [currentUserId ?? null];
  const conditions = [];

  if (feedFor && !currentUserId) error(401);

  if (tag) {
    params.push(tag);
    conditions.push(`a.id IN (SELECT article_id FROM article_tags WHERE tag_name = $${params.length})`);
  }
  if (author) {
    params.push(author);
    conditions.push(`u.username = $${params.length}`);
  }
  if (favorited) {
    params.push(favorited);
    conditions.push(`a.id IN (
      SELECT f.article_id FROM favorites f JOIN users fu ON fu.id = f.user_id
      WHERE fu.username = $${params.length}
    )`);
  }
  if (feedFor) {
    params.push(feedFor);
    conditions.push(`a.author_id IN (SELECT followed_id FROM follows WHERE follower_id = $${params.length})`);
  }

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $1) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $1 AND followed_id = a.author_id) AS following,
      count(*) OVER() AS full_count
    FROM articles a
    JOIN users u ON u.id = a.author_id
    ${where}
    ORDER BY a.created_at DESC
    LIMIT $${limitIdx} OFFSET $${offsetIdx}
    `,
    params
  );

  return {
    articles: rows.map(mapArticleRow),
    articlesCount: rows.length ? Number(rows[0].full_count) : 0
  };
}

async function getArticleBySlug(slug, currentUserId) {
  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $2) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = a.author_id) AS following
    FROM articles a
    JOIN users u ON u.id = a.author_id
    WHERE a.slug = $1
    `,
    [slug, currentUserId ?? null]
  );

  if (!rows.length) error(404, 'Article not found');
  return mapArticleRow(rows[0]);
}

async function createArticle(userId, { title, description, body, tagList = [] }) {
  const slug = slugify(title);

  const { rows } = await pool.query(
    `INSERT INTO articles (slug, title, description, body, author_id) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
    [slug, title, description, body, userId]
  );
  const articleId = rows[0].id;

  for (const name of tagList) {
    await pool.query(`INSERT INTO tags (name) VALUES ($1) ON CONFLICT DO NOTHING`, [name]);
    await pool.query(
      `INSERT INTO article_tags (article_id, tag_name) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [articleId, name]
    );
  }

  return getArticleBySlug(slug, userId);
}

async function updateArticle(slug, { title, description, body }, currentUserId) {
  await pool.query(
    `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),
      body = COALESCE($4, body), updated_at = now() WHERE slug = $1`,
    [slug, title || null, description || null, body || null]
  );
  return getArticleBySlug(slug, currentUserId);
}

async function deleteArticle(slug) {
  await pool.query(`DELETE FROM articles WHERE slug = $1`, [slug]);
}

async function setFavorite(slug, userId, favorited) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  if (favorited) {
    await pool.query(`INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      userId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`, [userId, rows[0].id]);
  }

  return getArticleBySlug(slug, userId);
}

async function listTags() {
  const { rows } = await pool.query(`SELECT name FROM tags ORDER BY name`);
  return rows.map((r) => r.name);
}

async function listComments(slug) {
  const { rows } = await pool.query(
    `SELECT c.id, c.body, c.created_at, c.updated_at,
            u.username AS author_username, u.bio AS author_bio, u.image AS author_image
     FROM comments c JOIN articles a ON a.id = c.article_id JOIN users u ON u.id = c.author_id
     WHERE a.slug = $1 ORDER BY c.created_at ASC`,
    [slug]
  );

  return rows.map((r) => ({
    id: r.id,
    body: r.body,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    author: { username: r.author_username, bio: r.author_bio ?? '', image: r.author_image }
  }));
}

async function addComment(slug, userId, body) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  const { rows: inserted } = await pool.query(
    `INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at`,
    [rows[0].id, userId, body]
  );
  const { rows: authorRows } = await pool.query(`SELECT username, bio, image FROM users WHERE id = $1`, [userId]);

  const c = inserted[0];
  return { id: c.id, body: c.body, createdAt: c.created_at, updatedAt: c.updated_at, author: authorRows[0] };
}

async function deleteComment(id) {
  await pool.query(`DELETE FROM comments WHERE id = $1`, [id]);
}

async function getProfile(username, currentUserId) {
  const { rows } = await pool.query(
    `SELECT u.username, u.bio, u.image,
            EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = u.id) AS following
     FROM users u WHERE u.username = $1`,
    [username, currentUserId ?? null]
  );
  if (!rows.length) error(404, 'User not found');
  return rows[0];
}

async function setFollow(username, followerId, follow) {
  const { rows } = await pool.query(`SELECT id FROM users WHERE username = $1`, [username]);
  if (!rows.length) error(404, 'User not found');

  if (follow) {
    await pool.query(`INSERT INTO follows (follower_id, followed_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      followerId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM follows WHERE follower_id = $1 AND followed_id = $2`, [followerId, rows[0].id]);
  }

  return getProfile(username, followerId);
}

async function login(email, password) {
  const { rows } = await pool.query(`SELECT * FROM users WHERE email = $1`, [email]);
  if (!rows.length || !(await bcrypt.compare(password, rows[0].password_hash))) {
    return { errors: { 'email or password': ['is invalid'] } };
  }
  return { user: toUserJson(rows[0]) };
}

async function register(username, email, password) {
  try {
    const password_hash = await bcrypt.hash(password, 10);
    const { rows } = await pool.query(
      `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING *`,
      [username, email, password_hash]
    );
    return { user: toUserJson(rows[0]) };
  } catch (err) {
    if (err.code === '23505') return { errors: { 'username or email': ['is already taken'] } };
    throw err;
  }
}

async function updateUser(userId, { username, email, password, image, bio }) {
  const password_hash = password ? await bcrypt.hash(password, 10) : null;
  const { rows } = await pool.query(
    `UPDATE users SET username = COALESCE($2, username), email = COALESCE($3, email),
      password_hash = COALESCE($4, password_hash), image = COALESCE($5, image), bio = COALESCE($6, bio)
     WHERE id = $1 RETURNING *`,
    [userId, username || null, email || null, password_hash, image || null, bio || null]
  );
  return { user: toUserJson(rows[0]) };
}

async function send({ method, path, data, token }) {
  const [route, query = ''] = path.split('?');
  const params = new URLSearchParams(query);
  const segments = route.split('/').filter(Boolean);
  const currentUserId = decodeToken(token);

  if (method === 'GET' && route === 'tags') {
    return { tags: await listTags() };
  }

  if (method === 'GET' && (route === 'articles' || route === 'articles/feed')) {
    return listArticles(
      {
        limit: Number(params.get('limit') ?? 20),
        offset: Number(params.get('offset') ?? 0),
        tag: params.get('tag') || undefined,
        author: params.get('author') || undefined,
        favorited: params.get('favorited') || undefined,
        feedFor: route === 'articles/feed' ? currentUserId : undefined
      },
      currentUserId
    );
  }

  if (method === 'POST' && route === 'articles') {
    if (!currentUserId) error(401);
    return { article: await createArticle(currentUserId, data.article) };
  }

  if (segments[0] === 'articles' && segments.length === 2) {
    const slug = segments[1];
    if (method === 'GET') return { article: await getArticleBySlug(slug, currentUserId) };
    if (method === 'PUT') {
      if (!currentUserId) error(401);
      return { article: await updateArticle(slug, data.article, currentUserId) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteArticle(slug);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'comments') {
    const slug = segments[1];
    if (method === 'GET') return { comments: await listComments(slug) };
    if (method === 'POST') {
      if (!currentUserId) error(401);
      return { comment: await addComment(slug, currentUserId, data.comment.body) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteComment(segments[3]);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'favorite') {
    if (!currentUserId) error(401);
    return { article: await setFavorite(segments[1], currentUserId, method === 'POST') };
  }

  if (segments[0] === 'profiles' && segments.length === 2) {
    return { profile: await getProfile(segments[1], currentUserId) };
  }

  if (segments[0] === 'profiles' && segments[2] === 'follow') {
    if (!currentUserId) error(401);
    return { profile: await setFollow(segments[1], currentUserId, method === 'POST') };
  }

  if (method === 'POST' && route === 'users/login') {
    return login(data.user.email, data.user.password);
  }

  if (method === 'POST' && route === 'users') {
    return register(data.user.username, data.user.email, data.user.password);
  }

  if (method === 'PUT' && route === 'user') {
    if (!currentUserId) error(401);
    return updateUser(currentUserId, data.user);
  }

  error(404, `no local handler for ${method} ${route}`);
}

export function get(path, token) {
  return send({ method: 'GET', path, token });
}
export function del(path, token) {
  return send({ method: 'DELETE', path, token });
}
export function post(path, data, token) {
  return send({ method: 'POST', path, data, token });
}
export function put(path, data, token) {
  return send({ method: 'PUT', path, data, token });
}
EOF

echo "==> db/init.sql"
cat > db/init.sql <<'EOF'
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    username      TEXT UNIQUE NOT NULL,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    bio           TEXT NOT NULL DEFAULT '',
    image         TEXT
);

CREATE TABLE IF NOT EXISTS articles (
    id          SERIAL PRIMARY KEY,
    slug        TEXT UNIQUE NOT NULL,
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT '',
    author_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tags (
    name TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS article_tags (
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    tag_name   TEXT NOT NULL REFERENCES tags(name) ON DELETE CASCADE,
    PRIMARY KEY (article_id, tag_name)
);

CREATE TABLE IF NOT EXISTS favorites (
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, article_id)
);

CREATE TABLE IF NOT EXISTS follows (
    follower_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followed_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (follower_id, followed_id)
);

CREATE TABLE IF NOT EXISTS comments (
    id         SERIAL PRIMARY KEY,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    author_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
EOF

echo "==> Dockerfile"
cat > Dockerfile <<'EOF'
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
# pnpm's own prune refuses to run non-interactively otherwise ("no TTY")
ENV CI=true

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm run build
RUN pnpm prune --prod

FROM node:22-alpine AS runtime
WORKDIR /app
RUN corepack enable
ENV NODE_ENV=production

COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

EXPOSE 3000
CMD ["node", "build"]
EOF

echo "==> docker-compose.yml"
cat > docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    build: .
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      alloy:
        condition: service_started
    env_file: .env
    ports:
      - "3000:3000"

  alloy:
    image: grafana/alloy:latest
    restart: unless-stopped
    env_file: .env
    environment:
      OTEL_RESOURCE_ATTRIBUTES: deployment.environment=${PUBLIC_APP_ENV}
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    ports:
      - "12345:12345"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  pgdata:
EOF

echo "==> alloy/config.alloy"
cat > alloy/config.alloy <<'EOF'
otelcol.receiver.otlp "default" {
  grpc { }
  http { }

  output {
    metrics = [otelcol.processor.resourcedetection.default.input]
    logs    = [otelcol.processor.resourcedetection.default.input]
    traces  = [otelcol.processor.resourcedetection.default.input]
  }
}

prometheus.exporter.postgres "conduit_db" {
  data_source_names = [sys.env("DATABASE_URL")]
}

prometheus.scrape "conduit_db" {
  targets         = prometheus.exporter.postgres.conduit_db.targets
  scrape_interval = "15s"
  forward_to      = [otelcol.receiver.prometheus.postgres.receiver]
}

otelcol.receiver.prometheus "postgres" {
  output {
    metrics = [otelcol.processor.resourcedetection.default.input]
  }
}

otelcol.processor.resourcedetection "default" {
  detectors = ["env", "system"]

  system {
    hostname_sources = ["os"]

    resource_attributes {
      host.id   { enabled = true }
      host.name { enabled = true }
    }
  }

  output {
    metrics = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
    logs    = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
    traces  = [otelcol.processor.transform.drop_unneeded_resource_attributes.input]
  }
}

otelcol.processor.transform "drop_unneeded_resource_attributes" {
  error_mode = "ignore"

  trace_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  metric_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  log_statements {
    context    = "resource"
    statements = [
      "delete_key(attributes, \"k8s.pod.start_time\")",
      "delete_key(attributes, \"os.description\")",
      "delete_key(attributes, \"os.type\")",
      "delete_key(attributes, \"process.command_args\")",
      "delete_key(attributes, \"process.executable.path\")",
      "delete_key(attributes, \"process.pid\")",
      "delete_key(attributes, \"process.runtime.description\")",
      "delete_key(attributes, \"process.runtime.name\")",
      "delete_key(attributes, \"process.runtime.version\")",
    ]
  }

  output {
    metrics = [otelcol.processor.transform.add_resource_attributes_as_metric_attributes.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.transform "add_resource_attributes_as_metric_attributes" {
  error_mode = "ignore"

  metric_statements {
    context    = "datapoint"
    statements = [
      "set(attributes[\"deployment.environment\"], resource.attributes[\"deployment.environment\"])",
      "set(attributes[\"service.version\"], resource.attributes[\"service.version\"])",
    ]
  }

  output {
    metrics = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.otlphttp.grafana_cloud.input]
    logs    = [otelcol.exporter.otlphttp.grafana_cloud.input]
    traces  = [otelcol.exporter.otlphttp.grafana_cloud.input]
  }
}

otelcol.auth.basic "grafana_cloud" {
  username = sys.env("GRAFANA_CLOUD_INSTANCE_ID")
  password = sys.env("GRAFANA_CLOUD_API_TOKEN")
}

// Grafana Cloud's OTLP gateway only speaks OTLP/HTTP, not gRPC — the plain
// otelcol.exporter.otlp component defaults to gRPC and fails against this
// endpoint with a "no children to pick from" resolver error.
otelcol.exporter.otlphttp "grafana_cloud" {
  client {
    endpoint = sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")
    auth     = otelcol.auth.basic.grafana_cloud.handler
  }
}
EOF

echo "==> .env.example"
cat > .env.example <<'EOF'
POSTGRES_USER=conduit
POSTGRES_PASSWORD=conduit
POSTGRES_DB=conduit
DATABASE_URL=postgresql://conduit:conduit@postgres:5432/conduit?sslmode=disable

PORT=3000
ORIGIN=http://localhost:3000
PUBLIC_APP_ENV=local
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317

# Cloud Portal -> Frontend Observability -> your app -> Web SDK Configuration
PUBLIC_FARO_COLLECTOR_URL=https://faro-collector-prod-us-central-0.grafana.net/collect/00000000000000000000000000000000

# Cloud Portal -> your stack -> Connections -> OpenTelemetry (OTLP)
GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-us-central-0.grafana.net/otlp
GRAFANA_CLOUD_INSTANCE_ID=000000
GRAFANA_CLOUD_API_TOKEN=glc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF

echo
echo "Done. Next steps:"
echo "  cp .env.example .env   # then fill in your Grafana Cloud values"
echo "  docker compose up --build"
```

</details>

---

## Troubleshooting

- **Frontend and backend traces show up separately in Tempo, never merged.** For this app, that almost always means the browser request wasn't actually same-origin — a mismatched port or `http` vs. `https` is enough to break it. If you've split the frontend and backend onto genuinely different origins, you additionally need `propagateTraceHeaderCorsUrls` set on `TracingInstrumentation` to match the backend's real origin (see [2.3](#23-connecting-frontend-and-backend-traces)).
- **No spans from the backend at all.** Confirm both `experimental.instrumentation.server` and `experimental.tracing.server` are set in `svelte.config.js`, and that you rebuilt the image afterward — this is a build-time flag, not a runtime one.
- **Form posts fail with a 403.** SvelteKit's CSRF check validates the request's origin against `ORIGIN`. Missing or wrong value in `.env` is almost always the cause.
- **Nothing shows up in Frontend Observability.** Double-check `PUBLIC_FARO_COLLECTOR_URL` was copied exactly (including the trailing app key) and that it actually reached the client bundle — it has to be prefixed `PUBLIC_` and present in the app container's environment at request time.
- **Alloy logs `401 Unauthorized` talking to the OTLP gateway.** Wrong instance ID, wrong token, or a token missing the `traces:write`/`metrics:write` scopes. Regenerate it from Cloud Portal → Access Policies rather than guessing at the scope names.
- **Alloy logs `Exporting failed... rpc error: code = Unavailable desc = no children to pick from`.** This is a gRPC resolver error, and it means the exporter is configured for gRPC against an endpoint that only speaks HTTP. Make sure `config.alloy` uses `otelcol.exporter.otlphttp`, not `otelcol.exporter.otlp` — see the callout in [2.4](#24-collector-grafana-alloy).
- **Docker build fails on `pnpm prune --prod` with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`.** pnpm refuses to prune non-interactively without being told it's a CI environment. `ENV CI=true` before the prune step in the Dockerfile fixes it — it's already in the version above, but easy to lose if you're customizing the build stage.
- **Postgres metrics never show up.** Confirm `DATABASE_URL` resolves inside the Docker network (`postgres`, not `localhost`) and that the user in it can read `pg_stat_*` views.
- **Alloy logs `failed to get host ID... empty "host.id"` on startup.** Harmless — `resourcedetection`'s `host.id` detector wants `/etc/machine-id`, which plain Docker containers don't have. It's a warning, not an error, and everything still exports fine; ignore it unless you've deliberately bind-mounted the host's machine-id in.

## Where to go from here

- Turn on Faro's [session replay](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/session-replay/) integration and pivot straight from a replay to the backend trace it produced.
- Add exemplars so Mimir panels link directly into the Tempo trace that produced a given data point — Alloy is already shipping both, so it's mostly a Grafana dashboard config change.
- Fill in the tag-update gap in `updateArticle` and the rest of the RealWorld spec's edge cases if you want this to be a genuinely complete backend rather than a tracing demo with a database attached.
