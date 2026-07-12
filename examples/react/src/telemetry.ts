/**
 * Frontend telemetry via Grafana Faro — errors, web vitals, logs, user
 * sessions, and distributed traces from the browser.
 *
 * Import this file once, before rendering the app (e.g. first line of
 * main.tsx): `import "./telemetry";`
 */
import {
  getWebInstrumentations,
  initializeFaro,
  type Faro,
} from "@grafana/faro-web-sdk";
import { TracingInstrumentation } from "@grafana/faro-web-tracing";

export const faro: Faro = initializeFaro({
  // Alloy's faro.receiver endpoint (see config/alloy/config.alloy)
  url: import.meta.env.VITE_FARO_URL ?? "http://localhost:12347/collect",

  app: {
    name: "react-app",
    version: "1.0.0",
    environment: import.meta.env.MODE,
  },

  instrumentations: [
    // Errors, console, web vitals, session tracking
    ...getWebInstrumentations({ captureConsole: true }),

    // OpenTelemetry tracing: auto-instruments fetch/XHR and propagates
    // W3C traceparent so browser spans join backend traces.
    new TracingInstrumentation({
      instrumentationOptions: {
        // Only attach trace headers to your own APIs, never third parties.
        propagateTraceHeaderCorsUrls: [/localhost:\d+/, /api\.example\.com/],
      },
    }),
  ],

  // Drop noisy events before they leave the browser.
  ignoreErrors: [/ResizeObserver loop/, /Script error\./],

  // Trim what you send: 100% of errors, sampled sessions.
  sessionTracking: {
    enabled: true,
    samplingRate: 1, // lower (e.g. 0.1) for high-traffic production apps
  },
});
