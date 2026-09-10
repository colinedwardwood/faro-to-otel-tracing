# Demo Script

A live-demo runbook for the guide in `README.md`. Each step: one line of context, then the action. Do the setup section before anyone's watching.

The arc: get a boring, working app up first and prove there's nothing to see. Tear it down. Instrument it. Bring it back up and watch the same click produce a trace. The contrast is the whole demo — don't skip straight to the instrumented version.

## Setup (before the room fills up)

- Grafana Cloud, logged in, in a browser tab: Frontend Observability app + a Connections → OpenTelemetry (OTLP) page, both open.
- **Action:** have your four Grafana Cloud values (Faro collector URL, OTLP endpoint, instance ID, API token) copied into a notes doc — you'll paste them in later, never type them live.

## 1. Start from the untouched app

Why: we're not building a toy — this is the actual, unmodified SvelteKit RealWorld app.

**Action:**
```bash
git clone https://github.com/sveltejs/realworld.git conduit && cd conduit
```

## 2. Give it a database — still nothing observability-flavored

Why: this part is just "make it self-hostable," ordinary backend work. No Faro, no OpenTelemetry, no Alloy yet — on purpose.

### 2.1 Swap the adapter

Why: `adapter-vercel` doesn't self-host in Docker.

**Action:**
```bash
pnpm remove @sveltejs/adapter-vercel
pnpm add -D @sveltejs/adapter-node
```

### 2.2 Install the database driver

**Action:**
```bash
pnpm add pg bcryptjs
mkdir -p src/lib/server db
```

### 2.3 Point svelte.config.js at the new adapter

**Action:** replace `svelte.config.js` with:
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

### 2.4 Wire up the connection pool

**Action:** create `src/lib/server/db.js`:
```js
import pg from 'pg';
import { DATABASE_URL } from '$env/static/private';

const { Pool } = pg;

export const pool = new Pool({ connectionString: DATABASE_URL });
```

### 2.5 Swap the data layer

Why: same four exports (`get`/`post`/`put`/`del`), same shapes — now backed by Postgres instead of a hosted demo API. Every route keeps working unmodified.

**Action:** back it up, then replace `src/lib/api.js` — full content is in [README §1.5](README.md#15-the-actual-swap-srclibapijs); copy-paste it:
```bash
cp src/lib/api.js src/lib/api.js.orig
# paste the block from README §1.5 into src/lib/api.js
```

### 2.6 Add the schema

**Action:** create `db/init.sql` — full content is in [README §1.3](README.md#13-the-schema); copy-paste it.

### 2.7 Containerize it

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

### 2.8 Compose it — just the app and Postgres

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
    env_file: .env
    ports:
      - "3000:3000"

volumes:
  pgdata:
```

### 2.9 Set the baseline environment

**Action:** create `.env`:
```bash
POSTGRES_USER=conduit
POSTGRES_PASSWORD=conduit
POSTGRES_DB=conduit
DATABASE_URL=postgresql://conduit:conduit@postgres:5432/conduit?sslmode=disable
PORT=3000
ORIGIN=http://localhost:3000
```

## 3. Bring it up — and prove there's nothing to see

Why: this beat is the entire setup for the rest of the demo. A normal, working app, backed by a real database, with zero visibility into what it's doing.

**Action:**
```bash
docker compose up --build
```
Open `http://localhost:3000`, register an account, write a comment. It works. Ask the room: *"so — where would you even look, if this were slow?"* Let that sit for a second.

**Action:** tear it down.
```bash
docker compose down
```

## 4. Now instrument it

Why: same app, same database — we're adding visibility, not rebuilding anything.

### 4.1 Install Faro and OpenTelemetry

**Action:**
```bash
pnpm add @opentelemetry/api @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/resources @opentelemetry/semantic-conventions \
  @grafana/faro-web-sdk @grafana/faro-web-tracing
mkdir -p alloy
```

### 4.2 Turn on SvelteKit's native tracing

Why: this flag makes SvelteKit wrap its own internals — routing, `load`, actions — in spans automatically.

**Action:** update `svelte.config.js`'s `kit` block:
```js
kit: {
  adapter: adapter(),
  experimental: {
    instrumentation: { server: true },
    tracing: { server: true }
  }
}
```

### 4.3 Start OpenTelemetry before anything else loads

Why: auto-instrumentation patches modules (`http`, `pg`) the first time they're imported — it has to run first.

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

### 4.4 Initialize Faro

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

**Action:** create `src/hooks.client.js`:
```js
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro.js';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'local');
}
```

### 4.5 Configure the collector

Why: receives OTLP from the backend, scrapes Postgres, forwards both to Grafana Cloud, authenticated.

**Action:** create `alloy/config.alloy` — full content is in [README §2.4](README.md#24-collector-grafana-alloy); copy-paste it.

### 4.6 Add Alloy to the compose file

**Action:** add to `docker-compose.yml`'s `app` service and add an `alloy` service:
```yaml
  app:
    # ...unchanged...
    depends_on:
      postgres:
        condition: service_healthy
      alloy:
        condition: service_started

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
```

### 4.7 Add the rest of the environment

**Action:** append to `.env`:
```bash
PUBLIC_APP_ENV=live-demo
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317
PUBLIC_FARO_COLLECTOR_URL=<from Setup>
GRAFANA_CLOUD_OTLP_ENDPOINT=<from Setup>
GRAFANA_CLOUD_INSTANCE_ID=<from Setup>
GRAFANA_CLOUD_API_TOKEN=<from Setup>
```

## 5. Bring it back up

**Action:**
```bash
docker compose up --build
```

## 6. Make the same click again

Why: same request as step 3 — this time we're going to go find it.

**Action:** open `http://localhost:3000`, register a (new) account, post a comment.

## 7. Open the trace in Grafana Cloud

Why: this is the payoff — one trace, browser to SQL.

**Action:** Explore → Tempo → search `service.name` = `conduit-backend` → open the most recent trace.

## 8. Point at the two things that matter

Why: this is the actual argument of the whole demo — say it out loud while you point.

**Action:** click the **root span** (that's the browser, not the server) and scroll to the **leaf `pg.query` span** — read its SQL text aloud.

## 9. Show the other kind of signal

Why: one trace tells you about one request; metrics tell you about the database's overall health — different question, same pipeline.

**Action:** Explore → Metrics → query `pg_stat_database_numbackends`.

## 10. (Optional) Show the RUM side

Why: closes the loop back to "a real user, in a real browser."

**Action:** open Frontend Observability → find the session from step 6 → open it.

## 11. Land it

Why: give them the one sentence to remember.

**Action:** say it plainly — *"Same app, same click. The only thing that changed between step 3 and step 7 is that we can now see it."* Then stop talking.

## If something breaks on stage

- App won't load → check `docker compose ps`, all services should say healthy/running.
- No trace shows up → check `docker compose logs alloy` for `401` (bad token) — see README Troubleshooting.
- Nothing in Frontend Observability → `PUBLIC_FARO_COLLECTOR_URL` typo is the usual cause.

Full explanations and the one-shot version of all of Step 2 + Step 4 (`scripts/instrument.sh`) live in [`README.md`](README.md).
