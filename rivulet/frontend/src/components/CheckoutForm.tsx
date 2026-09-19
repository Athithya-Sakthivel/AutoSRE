import { type FormEvent, useState } from "react";
import type { CheckoutResponse } from "../api";

interface PresetSku {
  sku: string;
  name: string;
  price: number;
}

interface CheckoutFormProps {
  presetSkus: PresetSku[];
  onSubmit: (
    userId: string,
    sku: string,
    quantity: number,
    requestId: string,
  ) => Promise<CheckoutResponse>;
  loading: boolean;
  error: string | null;
}

export function CheckoutForm({
  presetSkus,
  onSubmit,
  loading,
  error,
}: CheckoutFormProps) {
  // Explicit string type to allow free-form input while still
  // initializing with a UUID. crypto.randomUUID() returns a narrow
  // template literal type that doesn't accept arbitrary strings.
  const [userId, setUserId] = useState<string>(() => crypto.randomUUID());
  const [selectedSku, setSelectedSku] = useState(presetSkus[0]?.sku ?? "");
  const [quantity, setQuantity] = useState("1");
  const [requestId, setRequestId] = useState<string | null>(null);
  const [success, setSuccess] = useState<CheckoutResponse | null>(null);

  const handleSubmit = async (
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> => {
    event.preventDefault();
    setSuccess(null);

    const normalizedUserId = userId.trim();
    const normalizedSku = selectedSku.trim();
    const parsedQuantity = Number(quantity);

    if (!normalizedUserId) return;
    if (!normalizedSku) return;
    if (!Number.isInteger(parsedQuantity) || parsedQuantity <= 0) return;

    const effectiveRequestId = requestId ?? crypto.randomUUID();
    setRequestId(effectiveRequestId);

    try {
      const result = await onSubmit(
        normalizedUserId,
        normalizedSku,
        parsedQuantity,
        effectiveRequestId,
      );
      setSuccess(result);
      setRequestId(null);
    } catch {
      // Keep the request ID so retrying the same logical
      // submission remains idempotent.
    }
  };

  const regenerateUserId = (): void => {
    setUserId(crypto.randomUUID());
    setRequestId(null);
    setSuccess(null);
  };

  const handleUserIdChange = (value: string): void => {
    setUserId(value);
    setRequestId(null);
    setSuccess(null);
  };

  const handleSkuChange = (value: string): void => {
    setSelectedSku(value);
    setRequestId(null);
    setSuccess(null);
  };

  const handleQuantityChange = (value: string): void => {
    setQuantity(value);
    setRequestId(null);
    setSuccess(null);
  };

  const parsedQuantity = Number(quantity);
  const quantityValid = Number.isInteger(parsedQuantity) && parsedQuantity > 0;

  return (
    <form
      className="checkout-form"
      onSubmit={(event) => {
        void handleSubmit(event);
      }}
      noValidate
    >
      <div className="form-field">
        <label className="form-label" htmlFor="user-id">
          User ID
        </label>
        <div className="form-row-with-action">
          <input
            id="user-id"
            type="text"
            className="form-input form-input-mono"
            value={userId}
            onChange={(event) => handleUserIdChange(event.target.value)}
            autoComplete="off"
            spellCheck={false}
            required
          />
          <button
            type="button"
            className="button button-icon"
            onClick={regenerateUserId}
            title="Generate new user UUID"
            aria-label="Generate new user UUID"
            disabled={loading}
          >
            ↻
          </button>
        </div>
      </div>

      <div className="form-field">
        <label className="form-label" htmlFor="sku-select">
          Product
        </label>
        <select
          id="sku-select"
          className="form-select"
          value={selectedSku}
          onChange={(event) => handleSkuChange(event.target.value)}
          required
        >
          {presetSkus.map((preset) => (
            <option key={preset.sku} value={preset.sku}>
              {preset.name} — {formatCurrency(preset.price)} ({preset.sku})
            </option>
          ))}
        </select>
      </div>

      <div className="form-field">
        <label className="form-label" htmlFor="quantity">
          Quantity
        </label>
        <input
          id="quantity"
          type="number"
          className="form-input"
          value={quantity}
          onChange={(event) => handleQuantityChange(event.target.value)}
          min={1}
          step={1}
          inputMode="numeric"
          required
          aria-invalid={quantity.length > 0 && !quantityValid}
        />
      </div>

      {requestId && !success && (
        <p className="form-hint">
          Retry-safe request ID: <code>{requestId}</code>
        </p>
      )}

      {error && (
        <div className="alert alert-error" role="alert">
          <span className="alert-icon" aria-hidden="true">
            !
          </span>
          <span>{error}</span>
        </div>
      )}

      {success && (
        <div className="alert alert-success" role="status" aria-live="polite">
          <span className="alert-icon" aria-hidden="true">
            ✓
          </span>
          <div>
            <div className="alert-title">Order Accepted</div>
            <div className="alert-detail">
              Event ID: <code>{success.eventId}</code>
            </div>
          </div>
        </div>
      )}

      <button
        type="submit"
        className="button button-primary button-full"
        disabled={
          loading || !userId.trim() || !selectedSku.trim() || !quantityValid
        }
        aria-busy={loading}
      >
        {loading ? "Submitting..." : "Submit Checkout"}
      </button>
    </form>
  );
}

function formatCurrency(value: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  }).format(value);
}
