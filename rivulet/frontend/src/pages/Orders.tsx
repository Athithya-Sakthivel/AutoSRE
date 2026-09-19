import { useEffect, useState } from "react";

interface StoredOrder {
  eventId: string;
  sku: string;
  quantity: number;
  timestamp: number;
}

const STORAGE_KEY = "rivulet.recent_orders";

function isStoredOrder(value: unknown): value is StoredOrder {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const record = value as Record<string, unknown>;

  return (
    typeof record.eventId === "string" &&
    record.eventId.length > 0 &&
    typeof record.sku === "string" &&
    record.sku.length > 0 &&
    typeof record.quantity === "number" &&
    Number.isInteger(record.quantity) &&
    record.quantity > 0 &&
    typeof record.timestamp === "number" &&
    Number.isFinite(record.timestamp)
  );
}

function readOrders(): StoredOrder[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);

    if (!raw) {
      return [];
    }

    const parsed: unknown = JSON.parse(raw);

    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed.filter(isStoredOrder).slice(0, 50);
  } catch {
    return [];
  }
}

export function OrdersPage() {
  const [orders, setOrders] = useState<StoredOrder[]>(readOrders);

  useEffect(() => {
    const refresh = (): void => {
      setOrders(readOrders());
    };

    const handleStorage = (event: StorageEvent): void => {
      if (event.key === STORAGE_KEY || event.key === null) {
        refresh();
      }
    };

    window.addEventListener("storage", handleStorage);

    refresh();

    return () => {
      window.removeEventListener("storage", handleStorage);
    };
  }, []);

  const handleClear = (): void => {
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      // Persistence is optional; the in-memory state can still
      // be cleared even if browser storage is unavailable.
    }

    setOrders([]);
  };

  return (
    <div className="page-container">
      <div className="page-header">
        <div className="page-header-row">
          <div>
            <h2 className="page-title">Recent Orders</h2>

            <p className="page-subtitle">
              Client-side history of checkout submissions. The browser stores
              accepted event IDs and does not claim asynchronous processing
              completion.
            </p>
          </div>

          {orders.length > 0 && (
            <button
              type="button"
              className="button button-ghost"
              onClick={handleClear}
            >
              Clear History
            </button>
          )}
        </div>
      </div>

      {orders.length === 0 ? (
        <div className="card">
          <div className="card-body">
            <div className="empty-state empty-state-large">
              <div className="empty-icon-large" aria-hidden="true">
                □
              </div>

              <h3 className="empty-title">No recent orders</h3>

              <p className="empty-text">
                Submit a checkout from the Checkout page to populate this
                history.
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="card">
          <div className="card-header">
            <h3 className="card-title">Order History</h3>

            <span className="card-badge">{orders.length}</span>
          </div>

          <div className="card-body card-body-nopad">
            <div className="table-wrapper">
              <table className="orders-table">
                <thead>
                  <tr>
                    <th scope="col">Time</th>
                    <th scope="col">SKU</th>
                    <th scope="col">Qty</th>
                    <th scope="col">Event ID</th>
                    <th scope="col">State</th>
                  </tr>
                </thead>

                <tbody>
                  {orders.map((order) => (
                    <tr key={order.eventId}>
                      <td className="cell-time">
                        {formatDateTime(order.timestamp)}
                      </td>

                      <td>
                        <code className="cell-sku">{order.sku}</code>
                      </td>

                      <td className="cell-qty">{order.quantity}</td>

                      <td>
                        <code className="cell-event-id">{order.eventId}</code>
                      </td>

                      <td>
                        <span className="status-badge status-submitted">
                          Accepted
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function formatDateTime(timestamp: number): string {
  return new Date(timestamp).toLocaleString();
}
