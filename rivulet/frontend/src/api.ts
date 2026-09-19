import { SpanStatusCode, trace } from "@opentelemetry/api";

const tracer = trace.getTracer("rivulet.frontend.api");

export interface CheckoutResponse {
  eventId: string;
}

export interface InventoryResponse {
  sku: string;
  quantity: number;
}

export interface ApiError {
  error: string;
}

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null;
}

function readErrorMessage(payload: unknown, response: Response): string {
  if (isRecord(payload)) {
    const error = payload.error;

    if (typeof error === "string" && error.trim()) {
      return error.trim();
    }

    const message = payload.message;

    if (typeof message === "string" && message.trim()) {
      return message.trim();
    }
  }

  return response.statusText || `HTTP ${response.status}`;
}

async function readJson(response: Response): Promise<unknown> {
  const body = await response.text();

  if (!body.trim()) {
    return null;
  }

  try {
    return JSON.parse(body) as unknown;
  } catch {
    return null;
  }
}

function isCheckoutResponse(value: unknown): value is CheckoutResponse {
  return (
    isRecord(value) &&
    typeof value.eventId === "string" &&
    value.eventId.trim().length > 0
  );
}

function isInventoryResponse(value: unknown): value is InventoryResponse {
  return (
    isRecord(value) &&
    typeof value.sku === "string" &&
    value.sku.trim().length > 0 &&
    typeof value.quantity === "number" &&
    Number.isFinite(value.quantity) &&
    value.quantity >= 0
  );
}

class RivuletApi {
  private readonly baseUrl = "";

  private generateRequestId(): string {
    return crypto.randomUUID();
  }

  async checkout(
    userId: string,
    sku: string,
    quantity: number,
    requestId?: string,
    signal?: AbortSignal,
  ): Promise<CheckoutResponse> {
    const normalizedUserId = userId.trim();
    const normalizedSku = sku.trim();
    const effectiveRequestId = requestId?.trim() || this.generateRequestId();

    if (!normalizedUserId) {
      throw new Error("User ID is required");
    }

    if (!normalizedSku) {
      throw new Error("SKU is required");
    }

    if (!Number.isInteger(quantity) || quantity <= 0) {
      throw new Error("Quantity must be a positive integer");
    }

    return tracer.startActiveSpan(
      "checkout_request",
      {
        attributes: {
          "user.id": normalizedUserId,
          "order.sku": normalizedSku,
          "order.quantity": quantity,
          "request.id": effectiveRequestId,
        },
      },
      async (span) => {
        try {
          const response = await fetch(
            `${this.baseUrl}/orders/${encodeURIComponent(
              normalizedUserId,
            )}/checkout`,
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                Accept: "application/json",
                "X-Request-ID": effectiveRequestId,
              },
              body: JSON.stringify({
                sku: normalizedSku,
                quantity,
              }),
              signal,
            },
          );

          const payload = await readJson(response);

          span.setAttribute("http.response.status_code", response.status);

          if (!response.ok) {
            const message = readErrorMessage(payload, response);

            span.setStatus({
              code: SpanStatusCode.ERROR,
              message,
            });

            throw new Error(message);
          }

          if (!isCheckoutResponse(payload)) {
            const message = "Backend returned an invalid checkout response";

            span.setStatus({
              code: SpanStatusCode.ERROR,
              message,
            });

            throw new Error(message);
          }

          span.setAttribute("event.id", payload.eventId);
          span.setStatus({ code: SpanStatusCode.OK });

          return payload;
        } catch (error) {
          if (error instanceof Error) {
            span.recordException(error);
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: error.message,
            });
          } else {
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: "Unknown checkout error",
            });
          }

          throw error;
        } finally {
          span.end();
        }
      },
    );
  }

  async getInventory(
    sku: string,
    signal?: AbortSignal,
  ): Promise<InventoryResponse | null> {
    const normalizedSku = sku.trim();

    if (!normalizedSku) {
      throw new Error("SKU is required");
    }

    return tracer.startActiveSpan(
      "get_inventory",
      {
        attributes: {
          "inventory.sku": normalizedSku,
        },
      },
      async (span) => {
        try {
          const response = await fetch(
            `${this.baseUrl}/inventory/${encodeURIComponent(normalizedSku)}`,
            {
              method: "GET",
              headers: {
                Accept: "application/json",
              },
              signal,
            },
          );

          span.setAttribute("http.response.status_code", response.status);

          if (response.status === 404) {
            span.setStatus({ code: SpanStatusCode.OK });
            return null;
          }

          const payload = await readJson(response);

          if (!response.ok) {
            const message = readErrorMessage(payload, response);

            span.setStatus({
              code: SpanStatusCode.ERROR,
              message,
            });

            throw new Error(message);
          }

          if (!isInventoryResponse(payload)) {
            const message = "Backend returned an invalid inventory response";

            span.setStatus({
              code: SpanStatusCode.ERROR,
              message,
            });

            throw new Error(message);
          }

          span.setAttribute("inventory.quantity", payload.quantity);
          span.setStatus({ code: SpanStatusCode.OK });

          return payload;
        } catch (error) {
          if (error instanceof Error) {
            span.recordException(error);
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: error.message,
            });
          } else {
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: "Unknown inventory error",
            });
          }

          throw error;
        } finally {
          span.end();
        }
      },
    );
  }

  async checkBackendHealth(signal?: AbortSignal): Promise<boolean> {
    try {
      const response = await fetch(`${this.baseUrl}/readyz`, {
        method: "GET",
        headers: {
          Accept: "application/json",
        },
        cache: "no-store",
        signal,
      });

      return response.ok;
    } catch {
      return false;
    }
  }
}

export const api = new RivuletApi();
