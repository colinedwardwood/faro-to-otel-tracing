> **This is a modified fork**, vendored into [colinedwardwood/faro-to-otel-tracing](../README.md) as the demo environment for a Grafana Faro/OpenTelemetry/Alloy observability guide. Everything under `src/routes/` and the UI are untouched from upstream. The one change: `src/lib/api.js` no longer calls the public hosted demo API — it's backed by a local Postgres database instead (see `src/lib/server/db.js`, `db/init.sql`), and the adapter is `@sveltejs/adapter-node` instead of `@sveltejs/adapter-vercel` so it can self-host in Docker. The original file is kept alongside it as `src/lib/api.js.orig` if you want to diff the two. **Start here, not this file:** [`../README.md`](../README.md) and [`../DEMO.md`](../DEMO.md).
>
> Original upstream: [sveltejs/realworld](https://github.com/sveltejs/realworld), MIT licensed — see `LICENSE`.

---

# ![RealWorld Example App](logo.png)

> ### [Svelte](https://github.com/sveltejs/svelte) codebase containing real world examples (CRUD, auth, advanced patterns, etc) that adheres to the [RealWorld](https://github.com/gothinkster/realworld) spec and API.

### [Demo](https://realworld.svelte.dev)&nbsp;&nbsp;&nbsp;&nbsp;[RealWorld](https://github.com/gothinkster/realworld)

This codebase was created to demonstrate a fully fledged fullstack application built with SvelteKit including CRUD operations, authentication, routing, pagination, and more.

For more information on how to this works with other frontends/backends, head over to the [RealWorld](https://github.com/gothinkster/realworld) repo.

## Running locally

```sh
pnpm install
pnpm run dev
```

To build and start in prod mode:

```sh
pnpm run build
pnpm run preview
```
