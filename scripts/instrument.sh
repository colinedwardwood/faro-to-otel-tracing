#!/usr/bin/env bash
set -euo pipefail

# Run from the root of this repo's app/ directory. Layers Faro (frontend) +
# OpenTelemetry (backend) + Alloy (collector) instrumentation on top of the
# already-Postgres-backed baseline app committed here. It never touches
# src/routes/ or any .svelte file.
#
# This is the one-shot version of README's "Instrument it" walkthrough —
# read that first if you want to understand each piece as it's added.

if [ ! -f "src/lib/server/db.js" ]; then
  echo "error: src/lib/server/db.js not found — run this from this repo's app/ directory" >&2
  exit 1
fi

if [ -f "src/instrumentation.server.js" ]; then
  echo "error: src/instrumentation.server.js already exists — this app looks instrumented already" >&2
  exit 1
fi

echo "==> Installing Faro + OpenTelemetry dependencies"
pnpm add @opentelemetry/api @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc @opentelemetry/resources @opentelemetry/semantic-conventions \
  @grafana/faro-web-sdk @grafana/faro-web-tracing

mkdir -p alloy

echo "==> svelte.config.js (adding the experimental tracing block)"
cat > svelte.config.js <<'EOF'
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

echo "==> docker-compose.yml (adding the alloy service)"
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

echo
echo "Done. .env.example already has placeholders for the 5 observability vars -"
echo "if your .env predates this baseline, diff it against .env.example and add"
echo "whatever's missing. Next steps:"
echo "  edit .env with your real Grafana Cloud values"
echo "  docker compose up --build"
