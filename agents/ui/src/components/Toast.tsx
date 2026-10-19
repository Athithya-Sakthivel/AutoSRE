/**
 * Reusable toast notification with auto-dismiss and manual dismissal.
 *
 * Ownership model:
 *   - The parent controls mounting (render conditionally).
 *   - This component owns the dismissal timer and entrance animation.
 *   - Callers must NOT add their own setTimeout for dismissal.
 *
 * Positioning: fixed bottom-right, above all page content (z-50).
 * Accessibility: role="alert" + aria-atomic for screen reader announcement.
 * Motion: entrance fade only; respects prefers-reduced-motion.
 */

import { useEffect, useRef, useState } from "react";
import type { ReactElement } from "react";

export type ToastType = "success" | "error" | "info";

interface ToastProps {
  type: ToastType;
  message: string;
  /** Auto-dismiss delay. 0 = persistent until manually dismissed. */
  durationMs?: number;
  onDismiss?: () => void;
}

const TOAST_STYLES: Record<ToastType, string> = {
  success:
    "border-status-resolved/30 bg-status-resolved/10 text-status-resolved",
  error: "border-status-failed/30 bg-status-failed/10 text-status-failed",
  info: "border-status-running/30 bg-status-running/10 text-status-running",
};

const TOAST_ICONS: Record<ToastType, string> = {
  success: "✓",
  error: "✗",
  info: "ℹ",
};

function normalizeDuration(value: number): number {
  if (!Number.isFinite(value) || value < 0) {
    return 3000;
  }
  return value;
}

export function Toast({
  type,
  message,
  durationMs = 3000,
  onDismiss,
}: ToastProps): ReactElement {
  const [entered, setEntered] = useState(false);

  // Keep the latest callback without restarting the dismissal timer
  // when the parent re-renders with a new function identity.
  const dismissRef = useRef(onDismiss);

  useEffect(() => {
    dismissRef.current = onDismiss;
  }, [onDismiss]);

  // Entrance fade. Cancel the frame on unmount to avoid setState after unmount.
  useEffect(() => {
    const frame = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(frame);
  }, []);

  const duration = normalizeDuration(durationMs);

  // One timer per message. Changing the message restarts the full duration.
  useEffect(() => {
    if (duration === 0) {
      return;
    }

    const timer = window.setTimeout(() => {
      dismissRef.current?.();
    }, duration);

    return () => window.clearTimeout(timer);
  }, [duration, message]);

  return (
    <div
      role="alert"
      aria-atomic="true"
      className={`fixed bottom-6 right-6 z-50 flex w-full max-w-sm items-start gap-3 rounded-lg border p-4 shadow-xl transition-opacity duration-200 motion-reduce:transition-none ${
        entered ? "opacity-100" : "opacity-0"
      } ${TOAST_STYLES[type]}`}
    >
      <span aria-hidden="true" className="text-base leading-none">
        {TOAST_ICONS[type]}
      </span>

      <p className="min-w-0 flex-1 break-words text-xs font-medium leading-relaxed">
        {message}
      </p>

      <button
        type="button"
        onClick={() => onDismiss?.()}
        aria-label="Dismiss notification"
        className="shrink-0 opacity-60 transition-opacity hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current"
      >
        ×
      </button>
    </div>
  );
}
