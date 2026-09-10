#!/usr/bin/env bash
set -euo pipefail

# Run from the root of a freshly cloned https://github.com/sveltejs/realworld
# checkout. Swaps the adapter, adds Faro + OpenTelemetry instrumentation,
# replaces the data layer with a local Postgres-backed implementation, and
# drops in the Docker/Alloy/Grafana Cloud plumbing described in this repo's
# README. It never touches src/routes/ or any .svelte file.

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
