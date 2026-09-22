/**
 * HTTP API client for AutoSRE backend.
 * All types imported from ./types — no duplicate definitions.
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
// API Error
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
// Core fetch wrapper with retry logic
// ---------------------------------------------------------------------------

interface ApiRequestInit extends Omit<RequestInit, "body"> {
  body?: unknown;
  timeoutMs?: number;
}

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

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

export async function apiFetch<T>(
  url: string,
  init: ApiRequestInit = {},
): Promise<T> {
  const {
    timeoutMs = 30000,
    headers: initHeaders,
    body,
    signal: callerSignal,
    ...rest
  } = init;

  const headers = new Headers(initHeaders);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }

  let serializedBody: BodyInit | undefined;
  if (body !== undefined) {
    headers.set("Content-Type", "application/json");
    serializedBody = JSON.stringify(body);
  }

  const method = (rest.method ?? "GET").toUpperCase();
  const retryableMethod =
    method === "GET" || method === "HEAD" || method === "OPTIONS";

  const maxAttempts = 3;
  const maxNetworkRetries = 1;
  const maxServerRetries = 2;

  let networkRetries = 0;
  let serverRetries = 0;
  let lastError: unknown;

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (callerSignal?.aborted) {
      throw (
        callerSignal.reason ?? new DOMException("Request aborted", "AbortError")
      );
    }

    const attemptController = new AbortController();
    let didTimeout = false;

    const timeoutId = setTimeout(() => {
      didTimeout = true;
      attemptController.abort();
    }, timeoutMs);

    let callerAbortHandler: (() => void) | undefined;

    if (callerSignal) {
      callerAbortHandler = () => {
        attemptController.abort(callerSignal.reason);
      };
      callerSignal.addEventListener("abort", callerAbortHandler, {
        once: true,
      });
    }

    try {
      const response = await fetch(url, {
        ...rest,
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
          serverRetries < maxServerRetries &&
          attempt < maxAttempts - 1
        ) {
          serverRetries += 1;
          lastError = apiError;
          await new Promise((resolve) =>
            setTimeout(resolve, 500 * Math.pow(2, attempt)),
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
        throw (
          callerSignal.reason ??
          new DOMException("Request aborted", "AbortError")
        );
      }

      if (isAbortError(error)) {
        throw error;
      }

      if (
        retryableMethod &&
        networkRetries < maxNetworkRetries &&
        attempt < maxAttempts - 1
      ) {
        networkRetries += 1;
        lastError = error;
        await new Promise((resolve) =>
          setTimeout(resolve, 500 * Math.pow(2, attempt)),
        );
        continue;
      }

      throw error;
    } finally {
      clearTimeout(timeoutId);
      if (callerSignal && callerAbortHandler) {
        callerSignal.removeEventListener("abort", callerAbortHandler);
      }
    }
  }

  throw lastError ?? new Error(`Request failed: ${url}`);
}

// ---------------------------------------------------------------------------
// Typed API endpoints
// ---------------------------------------------------------------------------

export const incidentsApi = {
  list: (signal?: AbortSignal) =>
    apiFetch<IncidentListResponse>("/incidents", { signal }),

  get: (incidentId: string, signal?: AbortSignal) =>
    apiFetch<Incident>(`/incidents/${encodeURIComponent(incidentId)}/report`, {
      signal,
    }),

  approve: (
    incidentId: string,
    request: ApprovalRequest,
    signal?: AbortSignal,
  ) =>
    apiFetch<ApprovalResponse>(
      `/incidents/${encodeURIComponent(incidentId)}/approve`,
      { method: "POST", body: request, signal },
    ),
};

export const metricsApi = {
  summary: (signal?: AbortSignal) =>
    apiFetch<MetricsSummary>("/metrics/summary", { signal }),

  timeseries: (range: MetricTimeRange, signal?: AbortSignal) =>
    apiFetch<MetricsTimeseriesResponse>(
      `/metrics/timeseries?range=${encodeURIComponent(range)}`,
      { signal },
    ),

  topExpensive: (limit = 5, signal?: AbortSignal) => {
    const safeLimit = Number.isFinite(limit)
      ? Math.min(100, Math.max(1, Math.trunc(limit)))
      : 5;

    return apiFetch<ExpensiveIncident[]>(
      `/metrics/top-expensive?limit=${encodeURIComponent(String(safeLimit))}`,
      { signal },
    );
  },
};

export const healthApi = {
  check: (signal?: AbortSignal) =>
    apiFetch<HealthResponse>("/healthz", { signal }),
};
