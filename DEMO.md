# Demo Script

A live-demo runbook for the guide in `README.md`. Each step: one line of context, then the action. Do the setup section before anyone's watching.

## Setup (before the room fills up)

- Grafana Cloud, logged in, in a browser tab: Frontend Observability app + a Connections → OpenTelemetry (OTLP) page, both open.
- **Action:** have your four Grafana Cloud values (Faro collector URL, OTLP endpoint, instance ID, API token) copied into a notes doc — you'll paste them into `.env`, never type them live.

## 1. Start from the untouched app

Why: we're not building a toy — this is the actual, unmodified SvelteKit RealWorld app.

**Action:**
```bash
git clone https://github.com/sveltejs/realworld.git conduit && cd conduit
```

## 2. Instrument it, file by file

Why: this is the actual teaching content — everything else in this script is just clicking around afterward. Twelve small steps, each one file.

### 2.1 Swap the adapter

Why: `adapter-vercel` doesn't self-host in Docker, and doesn't support the instrumentation hook we need next.

**Action:**
```bash
pnpm remove @sveltejs/adapter-vercel
pnpm add -D @sveltejs/adapter-node
```

### 2.2 Install everything else

Why: Faro for the browser, OpenTelemetry for the server, `pg`/`bcryptjs` for the new data layer.

**Action:**
```bash
pnpm add pg bcryptjs \
  @opentelemetry/api @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc @opentelemetry/resources @opentelemetry/semantic-conventions \
  @grafana/faro-web-sdk @grafana/faro-web-tracing
mkdir -p src/lib/server db alloy
```

### 2.3 Turn on SvelteKit's native tracing

Why: this flag makes SvelteKit wrap its own internals — routing, `load`, actions — in spans automatically.

**Action:** replace `svelte.config.js` with:
```js
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
```

### 2.4 Start OpenTelemetry before anything else loads

Why: auto-instrumentation patches modules (`http`, `pg`) the first time they're imported — it has to run first, or those patches never apply.

**Action:** create `src/instrumentation.server.js`:
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
      '@opentelemetry/instrumentation-fs': { enabled: false }
    })
  ]
});

sdk.start();
```

### 2.5 Initialize Faro

Why: this is the browser half — RUM, web vitals, and (since frontend and backend share an origin here) trace continuity for free.

**Action:** create `src/lib/faro.js`:
```js
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
```

### 2.6 Load it on app start

Why: `hooks.client.js` runs once when the app boots in the browser — the earliest hook there is.

**Action:** create `src/hooks.client.js`:
```js
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro.js';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'local');
}
```

### 2.7 Wire up the database connection

Why: one shared connection pool for the whole app.

**Action:** create `src/lib/server/db.js`:
```js
import pg from 'pg';
import { DATABASE_URL } from '$env/static/private';

const { Pool } = pg;

export const pool = new Pool({ connectionString: DATABASE_URL });
```

### 2.8 Swap the data layer

Why: this is the actual point of the demo — same four exports (`get`/`post`/`put`/`del`), same response shapes, now backed by Postgres instead of a hosted demo API. Every route in `src/routes/` keeps working unmodified.

**Action:** back it up, then replace `src/lib/api.js` — full content is in [README §1.5](README.md#15-the-actual-swap-srclibapijs); too long to retype live, so copy-paste it:
```bash
cp src/lib/api.js src/lib/api.js.orig
# paste the block from README §1.5 into src/lib/api.js
```

### 2.9 Add the schema

Why: users, articles, tags, comments, favorites, follows — everything the routes touch.

**Action:** create `db/init.sql`:
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

### 2.10 Containerize it

Why: multi-stage, pnpm-aware. `ENV CI=true` matters — pnpm's own prune refuses to run non-interactively without it.

**Action:** create `Dockerfile`:
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
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
```

### 2.11 Wire the stack together

Why: Postgres, the app, and the collector, coming up as one unit.

**Action:** create `docker-compose.yml`:
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
```

### 2.12 Configure the collector

Why: receives OTLP from the backend, scrapes Postgres, forwards both to Grafana Cloud, authenticated.

**Action:** create `alloy/config.alloy` — full content is in [README §2.4](README.md#24-collector-grafana-alloy); copy-paste it, then create `.env.example` from [README's env var table](README.md#environment-variables) too.

## 3. Drop in your credentials

Why: the one step nothing above should do for you.

**Action:** `cp .env.example .env`, then paste in the four values from Setup.

## 4. Boot it

**Action:**
```bash
docker compose up --build
```

## 5. Make the click that starts the story

Why: this is the request we're about to go trace end-to-end.

**Action:** open `http://localhost:3000`, register an account, and post a comment on an article.

## 6. Open the trace in Grafana Cloud

Why: this is the payoff — one trace, browser to SQL.

**Action:** Explore → Tempo → search `service.name` = `conduit-backend` → open the most recent trace.

## 7. Point at the two things that matter

Why: this is the actual argument of the whole demo — say it out loud while you point.

**Action:** click the **root span** (that's the browser, not the server) and scroll to the **leaf `pg.query` span** — read its SQL text aloud.

## 8. Show the other kind of signal

Why: one trace tells you about one request; metrics tell you about the database's overall health — different question, same pipeline.

**Action:** Explore → Metrics → query `pg_stat_database_numbackends`.

## 9. (Optional) Show the RUM side

Why: closes the loop back to "a real user, in a real browser."

**Action:** open Frontend Observability → find the session from step 5 → open it.

## 10. Land it

Why: give them the one sentence to remember.

**Action:** say it plainly — *"Same trace ID, three different tiers, zero manual span-wrapping."* Then stop talking.

## If something breaks on stage

- App won't load → check `docker compose ps`, all three should say healthy/running.
- No trace shows up → check `docker compose logs alloy` for `401` (bad token) — see README Troubleshooting.
- Nothing in Frontend Observability → `PUBLIC_FARO_COLLECTOR_URL` typo is the usual cause.

Full explanations and the one-shot version of all of Step 2 (`scripts/instrument.sh`) live in [`README.md`](README.md).
