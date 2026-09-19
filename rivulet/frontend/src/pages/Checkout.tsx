import { useState } from "react";
import { api, type CheckoutResponse } from "../api";
import { CheckoutForm } from "../components/CheckoutForm";

interface CheckoutResult {
  eventId: string;
  sku: string;
  quantity: number;
  timestamp: number;
}

const STORAGE_KEY = "rivulet.recent_orders";
const SESSION_RESULT_LIMIT = 10;
const STORAGE_RESULT_LIMIT = 50;

const PRESET_SKUS = [
  { sku: "LAPTOP-PRO-16", name: 'Laptop Pro 16"', price: 1999 },
  { sku: "WIRELESS-MOUSE", name: "Wireless Mouse", price: 49 },
  { sku: "TEST-SKU-E2E", name: "Test SKU (E2E)", price: 0 },
];

function isCheckoutResult(value: unknown): value is CheckoutResult {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" &&
    record.eventId.length > 0 &&
    typeof record.sku === "string" &&
    typeof record.quantity === "number" &&
    Number.isInteger(record.quantity) &&
    record.quantity > 0 &&
    typeof record.timestamp === "number" &&
    Number.isFinite(record.timestamp)
  );
}

function readRecentOrders(): CheckoutResult[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isCheckoutResult).slice(0, STORAGE_RESULT_LIMIT);
  } catch {
    return [];
  }
}

function writeRecentOrder(result: CheckoutResult): void {
  try {
    const existing = readRecentOrders();
    const next = [
      result,
      ...existing.filter((o) => o.eventId !== result.eventId),
    ].slice(0, STORAGE_RESULT_LIMIT);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // localStorage is optional; never fail a successful checkout
  }
}

export function CheckoutPage() {
  const [results, setResults] = useState<CheckoutResult[]>(() =>
    readRecentOrders().slice(0, SESSION_RESULT_LIMIT),
  );
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleCheckout = async (
    userId: string,
    sku: string,
    quantity: number,
    requestId: string,
  ): Promise<CheckoutResponse> => {
    setLoading(true);
    setError(null);

    try {
      const response = await api.checkout(userId, sku, quantity, requestId);
      const result: CheckoutResult = {
        eventId: response.eventId,
        sku,
        quantity,
        timestamp: Date.now(),
      };

      setResults((prev) =>
        [result, ...prev]
          .filter(
            (item, i, arr) =>
              arr.findIndex((c) => c.eventId === item.eventId) === i,
          )
          .slice(0, SESSION_RESULT_LIMIT),
      );
      writeRecentOrder(result);
      return response;
    } catch (err) {
      setError(err instanceof Error ? err.message : "Checkout failed");
      throw err;
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="page-container">
      <div className="page-header">
        <h2 className="page-title">New Order</h2>
        <p className="page-subtitle">
          Submit a checkout request to the Java Gateway. The gateway publishes
          the accepted order for asynchronous processing by the Go worker.
        </p>
      </div>

      <div className="page-grid">
        <section className="card">
          <div className="card-header">
            <h3 className="card-title">Checkout Form</h3>
          </div>
          <div className="card-body">
            <CheckoutForm
              presetSkus={PRESET_SKUS}
              onSubmit={handleCheckout}
              loading={loading}
              error={error}
            />
          </div>
        </section>

        <section className="card">
          <div className="card-header">
            <h3 className="card-title">Recent Submissions</h3>
            <span className="card-badge">{results.length}</span>
          </div>
          <div className="card-body">
            {results.length === 0 ? (
              <div className="empty-state">
                <div className="empty-icon" aria-hidden="true">
                  □
                </div>
                <p className="empty-text">No orders submitted yet</p>
              </div>
            ) : (
              <ul className="result-list">
                {results.map((result) => (
                  <li key={result.eventId} className="result-item">
                    <div className="result-main">
                      <div className="result-sku">{result.sku}</div>
                      <div className="result-meta">
                        Qty: {result.quantity} · {formatTime(result.timestamp)}
                      </div>
                    </div>
                    <code className="result-event-id">{result.eventId}</code>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

function formatTime(timestamp: number): string {
  return new Date(timestamp).toLocaleTimeString();
}
