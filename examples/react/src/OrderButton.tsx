/**
 * Example component: custom events, logs, and measurements via Faro.
 * Fetch calls are traced automatically by TracingInstrumentation and
 * carry `traceparent` to the backend, linking browser + server spans.
 */
import { useState } from "react";
import { faro } from "./telemetry";

export function OrderButton() {
  const [status, setStatus] = useState<string>();

  async function createOrder() {
    const started = performance.now();
    faro.api.pushEvent("order_submit_clicked", { source: "checkout" });

    try {
      const res = await fetch("/api/orders", { method: "POST" });
      if (!res.ok) throw new Error(`order failed: ${res.status}`);

      const body = await res.json();
      setStatus(`created ($${body.amount})`);
      faro.api.pushMeasurement({
        type: "order_flow",
        values: { duration_ms: performance.now() - started },
      });
    } catch (err) {
      setStatus("failed");
      faro.api.pushError(err as Error); // stack trace + session context to Loki
    }
  }

  return (
    <button onClick={createOrder}>
      Create order {status && `— ${status}`}
    </button>
  );
}
