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
