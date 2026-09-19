import { useEffect, useRef, useState } from "react";
import { api, type InventoryResponse } from "../api";

const COMMON_SKUS = ["LAPTOP-PRO-16", "WIRELESS-MOUSE", "TEST-SKU-E2E"];

export function InventoryPage() {
  const [sku, setSku] = useState("LAPTOP-PRO-16");
  const [queriedSku, setQueriedSku] = useState("");
  const [result, setResult] = useState<InventoryResponse | null>(null);
  const [notFound, setNotFound] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const controllerRef = useRef<AbortController | null>(null);

  useEffect(() => {
    return () => {
      controllerRef.current?.abort();
    };
  }, []);

  const handleLookup = async (skuToLookup?: string): Promise<void> => {
    const targetSku = (skuToLookup ?? sku).trim();

    if (!targetSku) {
      return;
    }

    controllerRef.current?.abort();

    const controller = new AbortController();
    controllerRef.current = controller;

    setLoading(true);
    setError(null);
    setNotFound(false);
    setResult(null);
    setQueriedSku(targetSku);

    try {
      const response = await api.getInventory(targetSku, controller.signal);

      if (controller.signal.aborted) {
        return;
      }

      if (response) {
        setResult(response);
        return;
      }

      setNotFound(true);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") {
        return;
      }

      setError(
        error instanceof Error ? error.message : "Inventory lookup failed",
      );
    } finally {
      if (!controller.signal.aborted) {
        setLoading(false);
      }
    }
  };

  return (
    <div className="page-container">
      <div className="page-header">
        <h2 className="page-title">Inventory Lookup</h2>

        <p className="page-subtitle">
          Query the current stock level. This is a read-only lookup;
          authoritative inventory mutation remains on the order-processing path.
        </p>
      </div>

      <div className="card">
        <div className="card-body">
          <form
            className="inventory-form"
            onSubmit={(event) => {
              event.preventDefault();
              void handleLookup();
            }}
          >
            <div className="form-field">
              <label className="form-label" htmlFor="sku-input">
                SKU
              </label>

              <input
                id="sku-input"
                type="text"
                className="form-input"
                value={sku}
                onChange={(event) => setSku(event.target.value)}
                placeholder="Enter SKU..."
                autoComplete="off"
                spellCheck={false}
              />
            </div>

            <div className="preset-skus">
              <span className="preset-label">Quick select</span>

              {COMMON_SKUS.map((presetSku) => (
                <button
                  key={presetSku}
                  type="button"
                  className="preset-button"
                  disabled={loading}
                  onClick={() => {
                    setSku(presetSku);
                    void handleLookup(presetSku);
                  }}
                >
                  {presetSku}
                </button>
              ))}
            </div>

            <button
              type="submit"
              className="button button-primary"
              disabled={loading || !sku.trim()}
              aria-busy={loading}
            >
              {loading ? "Looking up..." : "Check Inventory"}
            </button>
          </form>
        </div>
      </div>

      {error && (
        <div className="alert alert-error" role="alert">
          <span className="alert-icon" aria-hidden="true">
            !
          </span>
          <span>{error}</span>
        </div>
      )}

      {notFound && (
        <div className="alert alert-warning" role="status">
          <span className="alert-icon" aria-hidden="true">
            ?
          </span>
          <span>
            SKU <code>{queriedSku}</code> was not found.
          </span>
        </div>
      )}

      {result && (
        <div className="card inventory-result">
          <div className="card-body">
            <div className="inventory-display">
              <div className="inventory-sku">{result.sku}</div>

              <div className="inventory-quantity">
                <span className="quantity-value">{result.quantity}</span>
                <span className="quantity-label">units in stock</span>
              </div>

              <div className="inventory-status">
                {result.quantity > 10 ? (
                  <span className="status-badge status-good">Well stocked</span>
                ) : result.quantity > 0 ? (
                  <span className="status-badge status-low">Low stock</span>
                ) : (
                  <span className="status-badge status-out">Out of stock</span>
                )}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
