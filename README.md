# Full-Stack Tracing for SvelteKit + Postgres, with Faro, OpenTelemetry, and Alloy

Most "observability" setups stop at the server. You get a nice trace for your API handler, maybe a span or two around the database call, and then... nothing. The click that actually kicked the whole thing off, sitting in the browser, is invisible. When someone reports "the app was slow for me around 2pm," you're stuck guessing whether the problem was their network, a slow render, a chunky bundle, or an actual backend issue.

This guide wires up the other half. By the end you'll have a single trace that starts at a button click in the browser, runs through a SvelteKit server action, and ends at the exact Postgres query it triggered — all connected by the same trace ID, all visible in one waterfall in Grafana.

The stack:

- **Frontend** — [Grafana Faro Web SDK](https://github.com/grafana/faro-web-sdk) for RUM, Web Vitals, error capture, and browser-side tracing.
- **Backend** — SvelteKit's native OpenTelemetry integration (2.31+), no manual span-wrapping required.
- **Collector** — [Grafana Alloy](https://grafana.com/docs/alloy/latest/), acting as the single ingestion point for both OTLP traces from the backend and Faro payloads from the browser, plus a Postgres metrics scraper.
- **Backend-for-the-backend** — a local `grafana/otel-lgtm` image (Tempo + Loki + Prometheus + Grafana in one container) so you can see all of this without signing up for anything.

Everything below assumes you're running this locally with Docker. Swap the LGTM container for Grafana Cloud endpoints whenever you're ready — the Alloy config barely changes.

## Architecture

```mermaid
flowchart LR
    subgraph Browser
        UI[SvelteKit UI<br/>+ Faro Web SDK]
    end

    subgraph "Node container"
        SK[SvelteKit server<br/>+ OTel SDK]
    end

    subgraph "Postgres container"
        PG[(Postgres)]
    end

    subgraph "Alloy container"
        FR[faro.receiver]
        OR[otelcol.receiver.otlp]
        PE[prometheus.exporter.postgres]
    end

    subgraph "grafana/otel-lgtm"
        Tempo[(Tempo)]
        Loki[(Loki)]
        Prom[(Prometheus)]
        Graf[Grafana]
    end

    UI -- "fetch/form POST\ntraceparent header" --> SK
    UI -- "RUM events, web vitals,\nerrors, browser spans" --> FR
    SK -- "OTLP traces\n(same trace ID)" --> OR
    SK -- "pg query spans" --> OR
    PE -. "scrapes\nstats" .-> PG

    FR --> Tempo
    OR --> Tempo
    PE --> Prom
    Tempo --> Graf
    Loki --> Graf
    Prom --> Graf
```

The part that makes this actually useful, rather than three disconnected dashboards, is the horizontal arrow at the top: the browser sends a `traceparent` header on its request to the server, and the server continues that trace instead of starting a new one. That's the whole trick, and it's the part most tutorials skip. More on that in [Phase 2](#23-the-part-that-actually-matters-connecting-frontend-and-backend-traces).

## Prerequisites

- Node.js 20+
- Docker and Docker Compose
- A terminal and about 30 minutes

## Repo layout

By the end of this guide you'll have something like:

```
todo-app/
├── src/
│   ├── hooks.client.ts
│   ├── instrumentation.server.ts
│   ├── lib/
│   │   ├── faro.ts
│   │   └── server/
│   │       └── db.ts
│   └── routes/
│       ├── +page.server.ts
│       └── +page.svelte
├── db/
│   └── init.sql
├── alloy/
│   └── config.alloy
├── Dockerfile
├── docker-compose.yml
├── svelte.config.js
└── package.json
```

---

## Phase 1 — Ship the boring version first

Before adding any observability, get a working app up. Trying to instrument something that doesn't run yet is a bad time for everyone.

### 1.1 Scaffold the app

```bash
npx sv create todo-app
```

Pick **Skeleton project**, **TypeScript**, and whichever extras you like (I skip most of them for this demo). Then:

```bash
cd todo-app
npm install
npm install @sveltejs/adapter-node pg
npm install -D @types/pg
```

Swap the adapter in `svelte.config.js`:

```js
import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter()
  }
};

export default config;
```

We're using `adapter-node` specifically (not `adapter-auto` or a serverless target) because SvelteKit's OpenTelemetry hook and Node's `--import` machinery both need a long-running Node process to attach to. This won't work the same way on the edge or in a Lambda.

### 1.2 The database

Nothing fancy — a `todos` table and a healthcheck so the app container doesn't race the database on startup.

`db/init.sql`:

```sql
CREATE TABLE IF NOT EXISTS todos (
    id         SERIAL PRIMARY KEY,
    title      TEXT NOT NULL,
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`src/lib/server/db.ts`:

```ts
import { Pool } from 'pg';
import { DATABASE_URL } from '$env/static/private';

// A single shared pool for the process. SvelteKit runs as one long-lived
// Node server with adapter-node, so this is safe to keep as a module-level
// singleton — it isn't recreated per-request.
export const db = new Pool({
  connectionString: DATABASE_URL
});
```

### 1.3 The feature: a todo form

`src/routes/+page.server.ts`:

```ts
import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { db } from '$lib/server/db';

export const load: PageServerLoad = async () => {
  const { rows } = await db.query(
    'SELECT id, title, done, created_at FROM todos ORDER BY created_at DESC'
  );
  return { todos: rows };
};

export const actions: Actions = {
  default: async ({ request }) => {
    const data = await request.formData();
    const title = data.get('title');

    if (typeof title !== 'string' || title.trim().length === 0) {
      return fail(400, { error: 'Give it a title.' });
    }

    await db.query('INSERT INTO todos (title) VALUES ($1)', [title.trim()]);

    return { success: true };
  }
};
```

`src/routes/+page.svelte`:

```svelte
<script lang="ts">
  import { enhance } from '$app/forms';
  import type { ActionData, PageData } from './$types';

  export let data: PageData;
  export let form: ActionData;
</script>

<h1>Todos</h1>

<form method="POST" use:enhance>
  <input name="title" placeholder="What needs doing?" required />
  <button type="submit">Add</button>
</form>

{#if form?.error}
  <p style="color: crimson">{form.error}</p>
{/if}

<ul>
  {#each data.todos as todo (todo.id)}
    <li>{todo.title}</li>
  {/each}
</ul>
```

Nothing here is observability-related yet — it's a boring CRUD form, on purpose.

### 1.4 Dockerfile

A standard multi-stage build: install and build with dev dependencies, then ship a slim runtime image with only what's needed to run `node build`.

```dockerfile
# ---- build ----
FROM node:22-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build
RUN npm prune --omit=dev

# ---- runtime ----
FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production
COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

EXPOSE 3000
CMD ["node", "build"]
```

### 1.5 docker-compose (baseline)

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: todo
      POSTGRES_PASSWORD: todo
      POSTGRES_DB: tododb
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U todo -d tododb"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    build: .
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://todo:todo@postgres:5432/tododb
      PORT: 3000
      # adapter-node needs to know its own public origin to validate form
      # submissions — without this, POSTs fail an origin check and you'll
      # spend twenty minutes wondering why your action never runs.
      ORIGIN: http://localhost:3000
    ports:
      - "3000:3000"

volumes:
  pgdata:
```

### 1.6 Run it

```bash
docker compose up --build
```

Visit `http://localhost:3000`, add a todo, confirm it persists across a refresh. That's Phase 1 — a working app with zero visibility into what it's doing. Let's fix that.

---

## Phase 2 — Instrument everything

### 2.1 Frontend: Grafana Faro Web SDK

Faro is Grafana's browser SDK — it captures Real User Monitoring data (page loads, resource timing, Web Vitals), unhandled exceptions and console errors, user interactions, and — the part we care about most here — browser-originated traces.

```bash
npm install @grafana/faro-web-sdk @grafana/faro-web-tracing
```

`src/lib/faro.ts`:

```ts
import { initializeFaro, getWebInstrumentations } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

let faro: ReturnType<typeof initializeFaro> | undefined;

export function initFaro(collectorUrl: string, environment: string) {
  // Vite's dev server HMR can re-run this module; guard against
  // double-initialization or you'll get duplicate instrumentation.
  if (faro) return faro;

  faro = initializeFaro({
    url: collectorUrl,
    app: {
      name: 'todo-frontend',
      version: '1.0.0',
      environment
    },
    instrumentations: [
      // errors, web vitals, console capture, session tracking, view changes
      ...getWebInstrumentations(),

      // this is the one that generates browser spans and propagates
      // trace context onto outgoing requests
      new TracingInstrumentation({
        instrumentationOptions: {
          // Faro will NOT attach a traceparent header to a request unless
          // the target URL matches this list. This is a deliberate safety
          // default — you don't want to leak internal trace IDs to every
          // third-party script tag your app happens to load.
          propagateTraceHeaderCorsUrls: [/^http:\/\/localhost:3000\/.*/]
        }
      })
    ]
  });

  return faro;
}
```

Wire it up in `src/hooks.client.ts`, which runs once when the app boots in the browser:

```ts
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'development');
}
```

Note the use of `$env/dynamic/public` rather than `$env/static/public`. Static env vars get baked into the client bundle at build time, which means changing the collector URL means rebuilding the image. Dynamic public vars are read from `process.env` at request time on the server and injected into the page, so the same built container image works whether the collector lives at `localhost:12347` in your compose file or behind a real domain in staging.

### 2.2 Backend: SvelteKit's native OpenTelemetry support

Up through 2.30, instrumenting a SvelteKit server meant wrapping `handle` in `hooks.server.ts` by hand and hoping you caught every code path. SvelteKit 2.31 added first-class OpenTelemetry support: an instrumentation hook (conceptually the same idea as Next.js's `instrumentation.ts`) plus automatic spans around routing, `load` functions, form actions, and remote functions.

Turn it on in `svelte.config.js`:

```js
import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    experimental: {
      // load src/instrumentation.server.ts before any application code runs
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
npm install @opentelemetry/api @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/resources @opentelemetry/semantic-conventions
```

`src/instrumentation.server.ts`:

```ts
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from '@opentelemetry/semantic-conventions';

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: 'todo-backend',
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

The ordering here matters more than it looks like it should. `getNodeAutoInstrumentations()` works by monkey-patching modules (`http`, `pg`, and so on) the first time they're `require`'d. If your app imports `pg` before this SDK has started, the patch never applies and you silently get no database spans. The `instrumentation.server` flag exists specifically to solve this: it tells the Node build produced by `adapter-node` to `--import` this file before your app's own entrypoint, so `node build` picks it up automatically — no extra flags needed on the `CMD` line in the Dockerfile.

This also means you get Postgres query spans for free. `@opentelemetry/instrumentation-pg` is bundled inside `auto-instrumentations-node`, and because our `pg.Pool` in `db.ts` is a totally ordinary import, it gets patched along with everything else. Every `db.query(...)` call now produces a child span with the SQL statement, giving you actual per-query tracing — not to be confused with the Postgres *metrics* Alloy scrapes in [2.4](#24-database--collector-grafana-alloy), which is a different, complementary layer (connection counts, cache hit ratio, replication lag — things a single trace can't tell you).

### 2.3 The part that actually matters: connecting frontend and backend traces

This is the bit that turns two separate instrumentation efforts into one observability story, so it's worth being explicit about the mechanism rather than just saying "it works."

1. When the todo form submits (or any `fetch` call fires), Faro's `TracingInstrumentation` intercepts it and starts a client-side span.
2. Because the request URL (`http://localhost:3000/...`) matches `propagateTraceHeaderCorsUrls`, Faro attaches a [W3C `traceparent` header](https://www.w3.org/TR/trace-context/) to the outgoing request — something like `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`. That string encodes the trace ID, the parent span ID, and sampling flags.
3. The request lands on the SvelteKit server. The `http` instrumentation from `getNodeAutoInstrumentations()` reads that header off the incoming request. Instead of minting a new trace, OpenTelemetry's context propagation continues the existing one — the first server span becomes a *child* of the browser's span, not a sibling.
4. Every span created after that point in the same request — SvelteKit's own `tracing.server` spans around the action, the `pg` instrumentation's query span — inherits that same trace context via `AsyncLocalStorage`, because that's how OpenTelemetry's Node context manager propagates state through async calls.
5. Both the browser and the server ship their spans to Alloy — the browser via the Faro receiver, the server via OTLP — and Alloy forwards both into the same Tempo instance. Tempo doesn't care which door a span came in through; it just assembles anything sharing a trace ID into one waterfall.

The net effect: open a trace in Grafana and the root span is a literal button click, with the `INSERT INTO todos` query sitting three levels down as a leaf. That's the full-stack view this guide is named after.

One gotcha worth flagging up front: `propagateTraceHeaderCorsUrls` defaults to empty. If you skip it, Faro still generates browser spans, but never attaches the header, and your backend traces will always start fresh with no parent. If a Tempo trace search shows disconnected frontend-only and backend-only traces instead of one merged trace, this regex not matching your actual origin is almost always why.

### 2.4 Database & Collector: Grafana Alloy

Alloy is the collector sitting in the middle of all of this. It needs to do three unrelated jobs, and it's worth being clear about why the same binary is doing all three rather than reaching for three separate tools:

1. Accept OTLP traces from the SvelteKit backend.
2. Run an HTTP endpoint that the *browser* can POST Faro payloads to directly (RUM events, exceptions, and the browser spans from 2.3).
3. Scrape Postgres for database-level metrics, using `prometheus.exporter.postgres` — an embedded exporter, no separate `postgres_exporter` container needed.

`alloy/config.alloy`:

```alloy
// ------------------------------------------------------------------
// 1. OTLP traces from the SvelteKit backend
// ------------------------------------------------------------------
otelcol.receiver.otlp "backend" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

// ------------------------------------------------------------------
// 2. Faro receiver — the browser SDK talks to this directly
// ------------------------------------------------------------------
faro.receiver "frontend" {
  server {
    listen_address       = "0.0.0.0"
    listen_port          = 12347
    cors_allowed_origins = ["http://localhost:3000"]
  }

  output {
    traces = [otelcol.processor.batch.default.input]
    logs   = [otelcol.processor.batch.default.input]
  }
}

// ------------------------------------------------------------------
// 3. Postgres metrics
// ------------------------------------------------------------------
prometheus.exporter.postgres "todo_db" {
  data_source_names = ["postgresql://todo:todo@postgres:5432/tododb?sslmode=disable"]
}

prometheus.scrape "todo_db" {
  targets         = prometheus.exporter.postgres.todo_db.targets
  scrape_interval = "15s"
  forward_to      = [otelcol.receiver.prometheus.default.receiver]
}

// bridges classic Prometheus-shaped metrics into the OTel pipeline so
// everything can leave through one exporter below
otelcol.receiver.prometheus "default" {
  output {
    metrics = [otelcol.processor.batch.default.input]
  }
}

// ------------------------------------------------------------------
// 4. Batch and ship everything downstream
// ------------------------------------------------------------------
otelcol.processor.batch "default" {
  output {
    traces  = [otelcol.exporter.otlp.lgtm.input]
    logs    = [otelcol.exporter.otlp.lgtm.input]
    metrics = [otelcol.exporter.otlp.lgtm.input]
  }
}

otelcol.exporter.otlp "lgtm" {
  client {
    endpoint = "lgtm:4317"
    tls {
      insecure = true
    }
  }
}
```

A couple of things worth calling out:

- `otelcol.receiver.prometheus` is the bridge component that lets a `prometheus.scrape` target's output flow into an otelcol pipeline. Without it you'd need a second export path (a `prometheus.remote_write` block pointed straight at Prometheus) just for the Postgres metrics, which works fine too — this just keeps everything going out through a single OTLP exporter.
- The Postgres user in `data_source_names` is the same `todo`/`todo` app user for simplicity. In anything beyond a local demo, give the exporter its own read-only role — `GRANT pg_monitor TO exporter_user;` is enough for the stats views it needs, and there's no reason to hand it your application credentials.
- `faro.receiver` is still a newer, evolving component in Alloy, which is why the compose command below passes `--stability.level=experimental` — Alloy refuses to load configs referencing non-stable components unless you explicitly opt in.

### 2.5 Wire it into docker-compose

The full stack: Postgres, the app, Alloy, and `grafana/otel-lgtm` as a zero-config Tempo/Loki/Prometheus/Grafana bundle for local viewing.

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: todo
      POSTGRES_PASSWORD: todo
      POSTGRES_DB: tododb
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U todo -d tododb"]
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
    environment:
      DATABASE_URL: postgresql://todo:todo@postgres:5432/tododb
      PORT: 3000
      ORIGIN: http://localhost:3000
      # backend -> collector, over the internal docker network
      OTEL_EXPORTER_OTLP_ENDPOINT: http://alloy:4317
      # browser -> collector, so this has to be the *published* host port,
      # not the internal service name — the browser can't resolve "alloy"
      PUBLIC_FARO_COLLECTOR_URL: http://localhost:12347/collect
      PUBLIC_APP_ENV: docker-compose
    ports:
      - "3000:3000"

  alloy:
    image: grafana/alloy:latest
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --stability.level=experimental
      - /etc/alloy/config.alloy
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
    ports:
      - "12345:12345" # Alloy's UI — a live graph of the pipeline above, handy for debugging
      - "4317:4317"   # OTLP gRPC in
      - "4318:4318"   # OTLP HTTP in
      - "12347:12347" # Faro receiver — must be reachable from the browser
    depends_on:
      - lgtm

  lgtm:
    image: grafana/otel-lgtm:latest
    restart: unless-stopped
    ports:
      - "3001:3000" # Grafana UI — 3000 is already taken by the app

volumes:
  pgdata:
```

Run it:

```bash
docker compose up --build
```

### 2.6 See it all in Grafana

- App: `http://localhost:3000` — add a few todos to generate some traffic.
- Grafana: `http://localhost:3001` — `otel-lgtm` ships with anonymous admin access enabled, so no login screen, no default password to remember.
- Alloy's own UI: `http://localhost:12345` — worth a look the first time, it renders the component graph from `config.alloy` visually, which makes wiring mistakes obvious.

In Grafana:

1. **Explore → Tempo**, search by service name `todo-frontend` or `todo-backend`. Open a trace from a todo submission — you should see the browser span as the root, with the SvelteKit action and the `INSERT` query nested underneath it.
2. **Explore → Prometheus**, query `pg_up` or browse the `pg_stat_*` metrics — confirms the `prometheus.exporter.postgres` scrape is working.
3. Faro also ships session and page-view data as logs — check **Explore → Loki** filtered to `service_name="todo-frontend"` for the RUM-style event stream (page loads, Web Vitals, console errors).

---

## Troubleshooting

- **Frontend and backend traces show up separately in Tempo, never merged.** Almost always `propagateTraceHeaderCorsUrls` not matching your app's actual origin — check for a trailing slash mismatch or a scheme/port typo (see [2.3](#23-the-part-that-actually-matters-connecting-frontend-and-backend-traces)).
- **No spans from the backend at all.** Double check both `experimental.instrumentation.server` and `experimental.tracing.server` are set in `svelte.config.js`, and that you rebuilt the image afterward — this is a build-time flag, not a runtime one.
- **POST requests to the todo form fail with a 403.** SvelteKit's CSRF protection checks the request's origin against `ORIGIN`. If you forgot to set it in the `app` service's environment, add it.
- **Browser console shows CORS errors hitting `:12347`.** Add your app's exact origin to `cors_allowed_origins` in the `faro.receiver` block.
- **Alloy exits immediately on startup.** Usually a missing `--stability.level` flag — `faro.receiver` isn't marked generally-available yet.
- **Postgres metrics never show up.** Confirm the exporter's connection string resolves inside the Docker network (`postgres`, not `localhost`) and that the user has permission to read `pg_stat_*` views.

## Where to go from here

- Point `OTEL_EXPORTER_OTLP_ENDPOINT` and the Faro collector URL at Grafana Cloud instead of the local `lgtm` container — the app and Alloy config don't otherwise change.
- Add `faro.api.pushEvent(...)` calls around key user actions for custom RUM events, not just the automatic ones.
- Turn on Faro's [session replay](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/session-replay/) integration and pivot straight from a replay to the backend trace it produced.
- Add exemplars so your Prometheus panels link directly into the Tempo trace that produced a given data point — Alloy is already shipping both, so this is mostly a Grafana dashboard config change.
