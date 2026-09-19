import {
  CompositePropagator,
  W3CBaggagePropagator,
  W3CTraceContextPropagator,
} from "@opentelemetry/core";
import { ZoneContextManager } from "@opentelemetry/context-zone";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { registerInstrumentations } from "@opentelemetry/instrumentation";
import { DocumentLoadInstrumentation } from "@opentelemetry/instrumentation-document-load";
import { FetchInstrumentation } from "@opentelemetry/instrumentation-fetch";
import { UserInteractionInstrumentation } from "@opentelemetry/instrumentation-user-interaction";
import { resourceFromAttributes } from "@opentelemetry/resources";
import {
  BatchSpanProcessor,
  ConsoleSpanExporter,
  SimpleSpanProcessor,
} from "@opentelemetry/sdk-trace-base";
import { WebTracerProvider } from "@opentelemetry/sdk-trace-web";
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from "@opentelemetry/semantic-conventions";

let initialized = false;

function normalizeTraceEndpoint(value: string | undefined): string | undefined {
  const raw = value?.trim();

  if (!raw) {
    return undefined;
  }

  const withoutTrailingSlash = raw.replace(/\/+$/, "");

  if (withoutTrailingSlash.endsWith("/v1/traces")) {
    return withoutTrailingSlash;
  }

  return `${withoutTrailingSlash}/v1/traces`;
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function initTelemetry(): void {
  if (initialized) {
    return;
  }

  initialized = true;

  const endpoint = normalizeTraceEndpoint(
    import.meta.env.VITE_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ||
      import.meta.env.VITE_OTEL_ENDPOINT,
  );

  const spanProcessors = [];

  if (endpoint) {
    const exporter = new OTLPTraceExporter({
      url: endpoint,
    });

    spanProcessors.push(
      new BatchSpanProcessor(exporter, {
        maxQueueSize: 100,
        maxExportBatchSize: 10,
        scheduledDelayMillis: 2000,
        exportTimeoutMillis: 10000,
      }),
    );
  }

  if (import.meta.env.DEV) {
    spanProcessors.push(new SimpleSpanProcessor(new ConsoleSpanExporter()));
  }

  const resource = resourceFromAttributes({
    [ATTR_SERVICE_NAME]: "rivulet-frontend",
    [ATTR_SERVICE_VERSION]: import.meta.env.VITE_GIT_VERSION || "dev",
    "service.namespace": "rivulet",
    "deployment.environment.name":
      import.meta.env.VITE_ENVIRONMENT || import.meta.env.MODE,
  });

  const provider = new WebTracerProvider({
    resource,
    spanProcessors,
  });

  provider.register({
    contextManager: new ZoneContextManager(),
    propagator: new CompositePropagator({
      propagators: [
        new W3CTraceContextPropagator(),
        new W3CBaggagePropagator(),
      ],
    }),
  });

  const exporterIgnorePattern = endpoint
    ? new RegExp(`^${escapeRegex(endpoint)}(?:\\?.*)?$`)
    : undefined;

  registerInstrumentations({
    tracerProvider: provider,
    instrumentations: [
      new FetchInstrumentation({
        clearTimingResources: true,
        ...(exporterIgnorePattern
          ? { ignoreUrls: [exporterIgnorePattern] }
          : {}),
      }),

      new DocumentLoadInstrumentation(),

      new UserInteractionInstrumentation({
        eventNames: ["click", "submit"],
      }),
    ],
  });
}
