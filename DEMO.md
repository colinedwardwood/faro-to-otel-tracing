# Demo Script

A live-demo runbook for the guide in `README.md`. Each step: one line of context, then the action. Do the setup section before anyone's watching.

## Setup (before the room fills up)

- Grafana Cloud, logged in, in a browser tab: Frontend Observability app + a Connections → OpenTelemetry (OTLP) page, both open.
- **Action:** pre-fill a real `.env` from `.env.example` and keep it in an editor tab — never type credentials live.

## 1. Start from the untouched app

Why: we're not building a toy — this is the actual, unmodified SvelteKit RealWorld app.

**Action:**
```bash
git clone https://github.com/sveltejs/realworld.git conduit && cd conduit
```

## 2. Instrument it in one shot

Why: everything Part 2 of the guide explains — Postgres data layer, Faro, OpenTelemetry, Alloy — applied by one script, so the demo is about the *why*, not typing.

**Action:**
```bash
curl -fsSL https://raw.githubusercontent.com/colinedwardwood/faro-to-otel-tracing/main/scripts/instrument.sh | bash
```

## 3. Drop in your credentials

Why: this is the one step a script should never do for you.

**Action:** paste your pre-filled `.env` into the project root (or `cp .env.example .env` and fill it live if you want to show *where* each value comes from).

## 4. Boot the stack

Why: Postgres, the app, and Alloy all come up together.

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

Full explanations, all code, and the complete script live in [`README.md`](README.md).
