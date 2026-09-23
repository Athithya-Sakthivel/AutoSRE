/**
 * HTTP API client for the AutoSRE backend.
 *
 * Endpoints mirror src/autosre/api/routes.py:
 *   GET  /incidents
 *   GET  /incidents/{id}/report
 *   POST /incidents/{id}/approve
 *   GET  /metrics/summary
 *   GET  /metrics/timeseries?range=...
 *   GET  /metrics/top-expensive?limit=...
 *   GET  /healthz
 *
 * GET requests retry once on 5xx. Mutations never retry.
 * TanStack Query may provide an AbortSignal; it is propagated to fetch and
 * also cancels the retry backoff when the query becomes obsolete.
 */

import type {
  ApprovalRequest,
  ApprovalResponse,
  ExpensiveIncident,
  HealthResponse,
  Incident,
  IncidentListResponse,
  MetricsSummary,
  MetricsTimeseriesResponse,
  MetricTimeRange,
} from "./types";

// ---------------------------------------------------------------------------
// ApiError
// ---------------------------------------------------------------------------

export class ApiError extends Error {
  public readonly status: number;
  public readonly statusText: string;
  public readonly body: unknown;
  public readonly url: string;

  constructor(status: number, statusText: string, body: unknown, url: string) {
    super(`API ${status}${statusText ? ` ${statusText}` : ""}: ${url}`);
    this.name = "ApiError";
    this.status = status;
    this.statusText = statusText;
    this.body = body;
    this.url = url;
  }

  get isNotFound(): boolean {
    return this.status === 404;
  }

  get isServerError(): boolean {
    return this.status >= 500;
  }
}

// ---------------------------------------------------------------------------
// Core fetch wrapper
// ---------------------------------------------------------------------------

export interface ApiRequestInit extends Omit<RequestInit, "body"> {
  body?: unknown;
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 30_000;
const RETRY_BACKOFF_MS = 500;
const DEFAULT_TOP_EXPENSIVE_LIMIT = 5;
const MAX_TOP_EXPENSIVE_LIMIT = 100;

async function parseResponseBody(response: Response): Promise<unknown> {
  if (response.status === 204 || response.status === 205) {
    return undefined;
  }
  const text = await response.text();
  if (text.length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

function normalizeTimeout(timeoutMs: number): number {
  if (!Number.isFinite(timeoutMs)) {
    return DEFAULT_TIMEOUT_MS;
  }
  return Math.max(0, Math.trunc(timeoutMs));
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function getAbortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("Request aborted", "AbortError");
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) {
    return Promise.resolve();
  }

  return new Promise<void>((resolve, reject) => {
    const handleAbort = (): void => {
      clearTimeout(timeoutId);
      signal?.removeEventListener("abort", handleAbort);
      reject(
        signal
          ? getAbortReason(signal)
          : new DOMException("Request aborted", "AbortError"),
      );
    };

    const timeoutId = setTimeout(() => {
      signal?.removeEventListener("abort", handleAbort);
      resolve();
    }, ms);

    if (signal) {
      if (signal.aborted) {
        handleAbort();
        return;
      }
      signal.addEventListener("abort", handleAbort, { once: true });
    }
  });
}

function normalizeTopExpensiveLimit(limit: number): number {
  if (!Number.isFinite(limit)) {
    return DEFAULT_TOP_EXPENSIVE_LIMIT;
  }
  return Math.min(MAX_TOP_EXPENSIVE_LIMIT, Math.max(1, Math.trunc(limit)));
}

export async function apiFetch<T>(
  url: string,
  init: ApiRequestInit = {},
): Promise<T> {
  const {
    timeoutMs = DEFAULT_TIMEOUT_MS,
    headers: initHeaders,
    body,
    signal: callerSignal,
    ...requestInit
  } = init;

  const headers = new Headers(initHeaders);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }

  let serializedBody: BodyInit | undefined;
  if (body !== undefined) {
    if (!headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }
    serializedBody = JSON.stringify(body);
  }

  const method = (requestInit.method ?? "GET").toUpperCase();
  const retryableMethod = method === "GET";
  const maxAttempts = retryableMethod ? 2 : 1;
  const normalizedTimeoutMs = normalizeTimeout(timeoutMs);

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (callerSignal?.aborted) {
      throw getAbortReason(callerSignal);
    }

    const attemptController = new AbortController();
    let didTimeout = false;

    const timeoutId = setTimeout(() => {
      didTimeout = true;
      attemptController.abort();
    }, normalizedTimeoutMs);

    let callerAbortHandler: (() => void) | undefined;
    if (callerSignal) {
      callerAbortHandler = (): void => {
        attemptController.abort(callerSignal.reason);
      };
      callerSignal.addEventListener("abort", callerAbortHandler, {
        once: true,
      });
    }

    try {
      const response = await fetch(url, {
        ...requestInit,
        headers,
        body: serializedBody,
        signal: attemptController.signal,
      });

      if (!response.ok) {
        const parsedBody = await parseResponseBody(response);
        const apiError = new ApiError(
          response.status,
          response.statusText,
          parsedBody,
          url,
        );

        if (
          retryableMethod &&
          response.status >= 500 &&
          attempt < maxAttempts - 1
        ) {
          await sleep(
            RETRY_BACKOFF_MS * 2 ** attempt,
            callerSignal ?? undefined,
          );
          continue;
        }

        throw apiError;
      }

      return (await parseResponseBody(response)) as T;
    } catch (error: unknown) {
      if (error instanceof ApiError) {
        throw error;
      }
      if (didTimeout) {
        throw new ApiError(0, "Timeout", null, url);
      }
      if (callerSignal?.aborted) {
        throw getAbortReason(callerSignal);
      }
      if (isAbortError(error)) {
        throw error;
      }
      throw error;
    } finally {
      clearTimeout(timeoutId);
      if (callerSignal && callerAbortHandler) {
        callerSignal.removeEventListener("abort", callerAbortHandler);
      }
    }
  }

  throw new Error(`Request failed: ${url}`);
}

// ---------------------------------------------------------------------------
// Typed API endpoints
// ---------------------------------------------------------------------------

export const incidentsApi = {
  list: (signal?: AbortSignal): Promise<IncidentListResponse> =>
    apiFetch<IncidentListResponse>("/incidents", { signal }),

  get: (incidentId: string, signal?: AbortSignal): Promise<Incident> =>
    apiFetch<Incident>(`/incidents/${encodeURIComponent(incidentId)}/report`, {
      signal,
    }),

  approve: (
    incidentId: string,
    request: ApprovalRequest,
    signal?: AbortSignal,
  ): Promise<ApprovalResponse> =>
    apiFetch<ApprovalResponse>(
      `/incidents/${encodeURIComponent(incidentId)}/approve`,
      { method: "POST", body: request, signal },
    ),
};

export const metricsApi = {
  summary: (signal?: AbortSignal): Promise<MetricsSummary> =>
    apiFetch<MetricsSummary>("/metrics/summary", { signal }),

  timeseries: (
    range: MetricTimeRange,
    signal?: AbortSignal,
  ): Promise<MetricsTimeseriesResponse> => {
    const searchParams = new URLSearchParams({ range });
    return apiFetch<MetricsTimeseriesResponse>(
      `/metrics/timeseries?${searchParams.toString()}`,
      { signal },
    );
  },

  topExpensive: (
    limit = DEFAULT_TOP_EXPENSIVE_LIMIT,
    signal?: AbortSignal,
  ): Promise<ExpensiveIncident[]> => {
    const safeLimit = normalizeTopExpensiveLimit(limit);
    const searchParams = new URLSearchParams({ limit: String(safeLimit) });
    return apiFetch<ExpensiveIncident[]>(
      `/metrics/top-expensive?${searchParams.toString()}`,
      { signal },
    );
  },
};

export const healthApi = {
  check: (signal?: AbortSignal): Promise<HealthResponse> =>
    apiFetch<HealthResponse>("/healthz", { signal }),
};
