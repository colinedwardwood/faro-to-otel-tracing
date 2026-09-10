# Demo Script

A live-demo runbook for the guide in `README.md`. Each step: one line of context, then the action. Do the setup section before anyone's watching.

The arc: get the pre-built app up and prove there's nothing to see. Tear it down. Instrument it. Bring it back up and watch the same click produce a trace. The contrast is the whole demo — don't skip straight to the instrumented version.

Every terminal command from Step 2 onward runs from **`faro-to-otel-tracing/app/`** — the directory Step 1's `cd` lands you in. It never changes for the rest of this script; each step still says so explicitly below so you can jump in mid-demo without re-deriving it.

## Setup (before the room fills up)

- Grafana Cloud, logged in, in a browser tab: Frontend Observability app + a Connections → OpenTelemetry (OTLP) page, both open.
- **Action:** have your four Grafana Cloud values (Faro collector URL, OTLP endpoint, instance ID, API token) copied into a notes doc — you'll paste them in later, never type them live.

## 1. Clone this repo

Why: the Postgres wiring is already done, checked in at `app/` — see [README's "The demo environment"](README.md#the-demo-environment) for what changed from upstream and why. That part is background, not something to build live.

**Action:**
```bash
git clone https://github.com/colinedwardwood/faro-to-otel-tracing.git
cd faro-to-otel-tracing/app
```

## 2. Start it

Why: this is the pre-instrumented baseline — a real, working, Postgres-backed app, checked into the repo exactly as is.

**Action** (from `faro-to-otel-tracing/app/`):
```bash
cp .env.example .env
docker compose up --build
```

## 3. Prove there's nothing to see

Why: this beat is the entire setup for the rest of the demo.

**Action:** open `http://localhost:3000`, register an account, write a comment. It works. Ask the room: *"so — where would you even look, if this were slow?"* Let that sit for a second.

**Action** (from `faro-to-otel-tracing/app/`): tear it down.
```bash
docker compose down
```

## 4. Instrument it

Why: same app, same database — we're adding visibility, not rebuilding anything. Faro (the browser half) fully first, then OpenTelemetry (the server half), then the collector that ties them together — each one is a complete, working unit before the next starts.

### 4.1 Install Faro

**Action** (from `faro-to-otel-tracing/app/`):
```bash
pnpm add @grafana/faro-web-sdk @grafana/faro-web-tracing
```

### 4.2 Initialize Faro

Why: this is the browser half — RUM, web vitals, and (since frontend and backend share an origin here) trace continuity for free.

**Action** (from `faro-to-otel-tracing/app/`): create `src/lib/faro.js`:
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

**If someone asks why this doesn't match the snippet Grafana Cloud gave them:** it's the same instrumentation, wrapped — a function + a guard so Vite's dev-mode hot-reload can't double-initialize it, and `url`/`environment` as arguments instead of hardcoded so a live collector URL never ends up committed to a public repo. Full breakdown: [README](README.md#frontend-grafana-faro-web-sdk).

### 4.3 Load Faro on boot

Why: `hooks.client.js` runs once when the app boots in the browser — the earliest hook there is.

**Action** (from `faro-to-otel-tracing/app/`): create `src/hooks.client.js`:
```js
import { browser } from '$app/environment';
import { env } from '$env/dynamic/public';
import { initFaro } from '$lib/faro.js';

if (browser) {
  initFaro(env.PUBLIC_FARO_COLLECTOR_URL, env.PUBLIC_APP_ENV ?? 'local');
}
```

That's Faro done. Next, OpenTelemetry — the server half.

### 4.4 Install OpenTelemetry

**Action** (from `faro-to-otel-tracing/app/`):
```bash
pnpm add @opentelemetry/api @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/resources @opentelemetry/semantic-conventions
```

### 4.5 Turn on SvelteKit's native tracing

Why: this flag makes SvelteKit wrap its own internals — routing, `load`, actions — in spans automatically.

**Action** (from `faro-to-otel-tracing/app/`): replace `svelte.config.js` — the only change from what's already there is the `experimental` block:
```js
import adapter from '@sveltejs/adapter-node';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	compilerOptions: {
		runes: true
	},
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

### 4.6 Start OpenTelemetry before anything else loads

Why: auto-instrumentation patches modules (`http`, `pg`) the first time they're imported — it has to run first.

**Action** (from `faro-to-otel-tracing/app/`): create `src/instrumentation.server.js`:
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

That's OpenTelemetry done. Last piece: the collector both of them ship to.

### 4.7 Configure the collector

Why: receives OTLP from the backend, scrapes Postgres, forwards both to Grafana Cloud, authenticated.

**Action** (from `faro-to-otel-tracing/app/`):
```bash
mkdir -p alloy
```
Then create `alloy/config.alloy` — full content is in [README's "Collector: Grafana Alloy"](README.md#collector-grafana-alloy); copy-paste it.

### 4.8 Add Alloy to the compose file

**Action** (from `faro-to-otel-tracing/app/`): add to `docker-compose.yml`'s `app` service and add an `alloy` service — full content is in [README's "Bring the alloy service into docker-compose"](README.md#bring-the-alloy-service-into-docker-compose); copy-paste it.

### 4.9 Add the rest of the environment

**Action** (from `faro-to-otel-tracing/app/`): append to `.env`:
```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317
PUBLIC_APP_ENV=live-demo
PUBLIC_FARO_COLLECTOR_URL=<from Setup>
GRAFANA_CLOUD_OTLP_ENDPOINT=<from Setup>
GRAFANA_CLOUD_INSTANCE_ID=<from Setup>
GRAFANA_CLOUD_API_TOKEN=<from Setup>
```

## 5. Bring it back up

**Action** (from `faro-to-otel-tracing/app/`):
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

## The one-command version of Step 4

If you're re-running this and don't need to teach the file-by-file version, `scripts/instrument.sh` does all of 4.1–4.9 in one pass, run from `faro-to-otel-tracing/app/`. See [README's "Do it with one command instead"](README.md#do-it-with-one-command-instead).

## If something breaks on stage

- App won't load → check `docker compose ps`, all services should say healthy/running.
- No trace shows up → check `docker compose logs alloy` for `401` (bad token) — see README Troubleshooting.
- Nothing in Frontend Observability → `PUBLIC_FARO_COLLECTOR_URL` typo is the usual cause.

Full explanations live in [`README.md`](README.md).
