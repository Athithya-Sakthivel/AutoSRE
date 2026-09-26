/**
 * HTTP API client for the AutoSRE backend.
 *
 * Endpoint contract syncs with src/autosre/api/routes.py.
 *
 * Approval flow:
 *   1. POST /api/sign-approval       -> { signature, body }
 *   2. POST /incidents/{id}/approve  -> HMAC-signed body forwarded verbatim
 *
 * The signature covers the exact bytes returned in `body`; the client must
 * forward those bytes without re-serializing, otherwise HMAC verification
 * on the server fails.
 */

import type {
  ApprovalRequest,
  ApprovalResponse,
  ExpensiveIncident,
  HealthResponse,
  IncidentListResponse,
  IncidentReport,
  MetricsSummary,
  MetricsTimeseriesResponse,
  MetricTimeRange,
  ReadyResponse,
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
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_TIMEOUT_MS = 30_000;
const RETRY_BACKOFF_MS = 500;
const SIGN_APPROVAL_PATH = "/api/sign-approval";

// ---------------------------------------------------------------------------
// Core fetch wrapper
// ---------------------------------------------------------------------------

interface ApiRequestInit extends Omit<RequestInit, "body"> {
  /** Serialized as JSON. Mutually exclusive with rawBody. */
  body?: unknown;
  /** Sent verbatim; use when the caller needs byte-exact control (HMAC). */
  rawBody?: string;
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

function sleep(ms: number, signal?: AbortSignal | null): Promise<void> {
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

export async function apiFetch<T>(
  url: string,
  init: ApiRequestInit = {},
): Promise<T> {
  const {
    timeoutMs = DEFAULT_TIMEOUT_MS,
    headers: initHeaders,
    body,
    rawBody,
    signal: callerSignal,
    ...requestInit
  } = init;

  if (body !== undefined && rawBody !== undefined) {
    throw new TypeError("apiFetch: body and rawBody are mutually exclusive");
  }

  const headers = new Headers(initHeaders);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }

  let serializedBody: BodyInit | undefined;
  if (rawBody !== undefined) {
    // Verbatim: caller is responsible for Content-Type (e.g. HMAC-signed payload).
    serializedBody = rawBody;
  } else if (body !== undefined) {
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
          await sleep(RETRY_BACKOFF_MS * 2 ** attempt, callerSignal);
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
// Health & readiness
// ---------------------------------------------------------------------------

export const healthApi = {
  /** Liveness check. Returns 200 if the process is alive. */
  check: (signal?: AbortSignal | null): Promise<HealthResponse> =>
    apiFetch<HealthResponse>("/healthz", { signal: signal ?? undefined }),

  /** Readiness check. Returns 200 only when all backing services respond. */
  readiness: (signal?: AbortSignal | null): Promise<ReadyResponse> =>
    apiFetch<ReadyResponse>("/readyz", { signal: signal ?? undefined }),

  /**
   * Bootstrap gate for the UI. Polls /readyz until the backend reports
   * "ready" or the timeout elapses.
   */
  ready: async (
    options: { timeoutMs?: number; pollIntervalMs?: number } = {},
  ): Promise<void> => {
    const timeoutMs = options.timeoutMs ?? 30_000;
    const pollIntervalMs = options.pollIntervalMs ?? 1_000;

    const deadline = Date.now() + timeoutMs;
    let lastError: unknown = null;

    while (Date.now() < deadline) {
      try {
        const response = await fetch("/readyz", {
          headers: { Accept: "application/json" },
        });

        if (response.ok) {
          try {
            const body = (await response.json()) as ReadyResponse;
            if (body.status === "ready") {
              return;
            }
            lastError = new Error(
              `Backend not ready: ${JSON.stringify(body.checks)}`,
            );
          } catch {
            lastError = new Error("Backend returned invalid /readyz body");
          }
        } else {
          lastError = new ApiError(
            response.status,
            response.statusText,
            null,
            "/readyz",
          );
        }
      } catch (error) {
        if (isAbortError(error)) {
          throw error;
        }
        lastError = error instanceof Error ? error : new Error(String(error));
      }

      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        break;
      }

      await new Promise((resolve) =>
        setTimeout(resolve, Math.min(pollIntervalMs, remaining)),
      );
    }

    const reason =
      lastError instanceof Error ? lastError.message : "Unknown error";
    throw new Error(
      `Backend did not become ready within ${timeoutMs}ms: ${reason}`,
    );
  },
};

// ---------------------------------------------------------------------------
// Incidents
// ---------------------------------------------------------------------------

interface SignedApprovalPayload {
  signature: string;
  body: string;
}

export const incidentsApi = {
  /**
   * List incidents, optionally filtered by status.
   *
   * `status=awaiting_approval` is a derived status computed by the backend
   * from `requires_human_approval && approval_granted === null`.
   */
  list: (
    params: { status?: string; limit?: number } = {},
    signal?: AbortSignal | null,
  ): Promise<IncidentListResponse> => {
    const searchParams = new URLSearchParams();
    if (params.status) {
      searchParams.set("status", params.status);
    }
    if (params.limit) {
      searchParams.set("limit", String(params.limit));
    }
    const query = searchParams.toString();
    return apiFetch<IncidentListResponse>(
      `/incidents${query ? `?${query}` : ""}`,
      { signal: signal ?? undefined },
    );
  },

  /** Fetch the full incident report (hypotheses, actions, metrics). */
  get: (
    incidentId: string,
    signal?: AbortSignal | null,
  ): Promise<IncidentReport> =>
    apiFetch<IncidentReport>(
      `/incidents/${encodeURIComponent(incidentId)}/report`,
      { signal: signal ?? undefined },
    ),

  /**
   * Approve or reject an incident.
   *
   * Two-step flow because the approval route is HMAC-protected and the
   * browser cannot compute HMAC-SHA256 without exposing the shared secret:
   *   1. Request a signature from the same-origin /api/sign-approval route.
   *   2. POST the returned body verbatim with the returned signature header.
   */
  approve: async (
    incidentId: string,
    request: ApprovalRequest,
    signal?: AbortSignal | null,
  ): Promise<ApprovalResponse> => {
    const signed = await apiFetch<SignedApprovalPayload>(SIGN_APPROVAL_PATH, {
      method: "POST",
      body: request,
      signal: signal ?? undefined,
    });

    if (
      typeof signed?.signature !== "string" ||
      typeof signed?.body !== "string"
    ) {
      throw new ApiError(
        500,
        "InvalidSignResponse",
        signed,
        SIGN_APPROVAL_PATH,
      );
    }

    return apiFetch<ApprovalResponse>(
      `/incidents/${encodeURIComponent(incidentId)}/approve`,
      {
        method: "POST",
        rawBody: signed.body,
        headers: {
          "Content-Type": "application/json",
          "X-Webhook-Signature": signed.signature,
        },
        signal: signal ?? undefined,
      },
    );
  },
};

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

export const metricsApi = {
  /** Aggregate KPIs across all incidents. */
  summary: (signal?: AbortSignal | null): Promise<MetricsSummary> =>
    apiFetch<MetricsSummary>("/metrics/summary", {
      signal: signal ?? undefined,
    }),

  /** Time-bucketed metrics for the requested range. */
  timeseries: (
    range: MetricTimeRange,
    signal?: AbortSignal | null,
  ): Promise<MetricsTimeseriesResponse> => {
    const searchParams = new URLSearchParams({ range });
    return apiFetch<MetricsTimeseriesResponse>(
      `/metrics/timeseries?${searchParams.toString()}`,
      { signal: signal ?? undefined },
    );
  },

  /** Top N most expensive incidents. */
  topExpensive: (
    limit = 5,
    signal?: AbortSignal | null,
  ): Promise<ExpensiveIncident[]> => {
    const searchParams = new URLSearchParams({ limit: String(limit) });
    return apiFetch<ExpensiveIncident[]>(
      `/metrics/top-expensive?${searchParams.toString()}`,
      { signal: signal ?? undefined },
    );
  },
};
