import { useEffect, useState, useRef } from "react";

// ----- Types (mirrors agent/state.py) -----

type AlertStatus =
  | "new"
  | "rate_limited"
  | "triaged"
  | "investigating"
  | "root_caused"
  | "fix_generated"
  | "awaiting_human"
  | "approved"
  | "rejected"
  | "executing"
  | "waiting_for_deploy"
  | "verifying"
  | "resolved"
  | "escalated"
  | "aborted"
  | "error";

type Severity = "debug" | "info" | "warning" | "error" | "critical";

interface TraceRecord {
  timestamp?: string;
  message?: string;
  severity?: string;
  exception_type?: string;
}

interface LogRecord {
  timestamp?: string;
  message?: string;
  severity?: string;
}

interface CodeSnippet {
  file_path?: string;
  line_start?: number;
  line_end?: number;
  content?: string;
}

interface ProposedAction {
  tool_name?: string;
  args?: Record<string, string>;
  rationale?: string;
}

interface SREState {
  thread_id?: string;
  service_name?: string;
  status?: AlertStatus;
  severity?: Severity;
  alert?: Record<string, unknown>;
  trace_records?: TraceRecord[];
  log_records?: LogRecord[];
  code_snippet?: CodeSnippet;
  proposed_action?: ProposedAction;
  fix_confidence?: number;
  human_decision?: string;
  notes?: string[];
  error_resolved?: boolean;
  last_error_message?: string;
  updated_at?: string;
}

// ----- WebSocket Hook -----

function useWebSocket(threadId: string | null) {
  const [state, setState] = useState<SREState | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    if (!threadId) return;
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const wsUrl = `${protocol}//${window.location.host}/ws/${threadId}`;
    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => console.log("WS open");
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === "state") {
          setState(msg.state as SREState);
        } else if (msg.type === "error") {
          console.error("WS error:", msg.payload);
        }
      } catch (err) {
        console.error("Failed to parse WS message", err);
      }
    };
    ws.onerror = (err) => console.error("WebSocket error", err);
    ws.onclose = () => console.log("WS closed");

    return () => {
      ws.close();
    };
  }, [threadId]);

  return state;
}

// ----- Main App Component -----

export default function App() {
  const [apiKey, setApiKey] = useState("");
  const [threadId, setThreadId] = useState<string | null>(null);
  const state = useWebSocket(threadId);

  const authHeaders = {
    "Content-Type": "application/json",
    ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
  };

  const startAlert = async () => {
    const res = await fetch("/alert", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        name: "Manual test",
        severity: "warning",
        description: "Triggered from frontend",
      }),
    });
    if (!res.ok) {
      alert("Failed to create alert: " + (await res.text()));
      return;
    }
    const data = await res.json();
    setThreadId(data.thread_id);
  };

  const makeDecision = async (decision: "approved" | "rejected") => {
    if (!threadId) return;
    await fetch(`/decision/${threadId}`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ decision }),
    });
  };

  return (
    <div style={{ padding: "2rem", fontFamily: "sans-serif" }}>
      <h1>agent‑brain</h1>

      {!threadId ? (
        <div>
          <label>
            API Key:{" "}
            <input
              type="text"
              value={apiKey}
              onChange={(e) => setApiKey(e.target.value)}
              placeholder="Enter shared API key"
              style={{ width: "300px" }}
            />
          </label>
          <button onClick={startAlert} style={{ marginLeft: "1rem" }}>
            Start Incident
          </button>
        </div>
      ) : (
        <div>
          <p>Thread: {threadId}</p>
          <button onClick={() => setThreadId(null)}>Reset</button>
          {state ? (
            <div style={{ marginTop: "1rem" }}>
              <StatusBadge status={state.status} />
              <pre
                style={{
                  background: "#f5f5f5",
                  padding: "1rem",
                  maxHeight: "500px",
                  overflow: "auto",
                }}
              >
                {JSON.stringify(state, null, 2)}
              </pre>

              {state.trace_records && state.trace_records.length > 0 && (
                <div>
                  <h3>Traces</h3>
                  {state.trace_records.map((t, i) => (
                    <div
                      key={i}
                      style={{
                        border: "1px solid #ccc",
                        margin: "0.5rem 0",
                        padding: "0.5rem",
                      }}
                    >
                      <strong>{t.severity}</strong> {t.message}
                    </div>
                  ))}
                </div>
              )}

              {state.log_records && state.log_records.length > 0 && (
                <div>
                  <h3>Logs</h3>
                  {state.log_records.map((l, i) => (
                    <div
                      key={i}
                      style={{
                        border: "1px solid #ccc",
                        margin: "0.5rem 0",
                        padding: "0.5rem",
                      }}
                    >
                      {l.message}
                    </div>
                  ))}
                </div>
              )}

              {state.code_snippet?.content && (
                <div>
                  <h3>Code Snippet ({state.code_snippet.file_path})</h3>
                  <pre style={{ background: "#eee", padding: "0.5rem" }}>
                    {state.code_snippet.content}
                  </pre>
                </div>
              )}

              {state.status === "awaiting_human" && state.proposed_action && (
                <div style={{ marginTop: "1rem" }}>
                  <h3>Proposed Action</h3>
                  <div>
                    <strong>Tool:</strong> {state.proposed_action.tool_name}
                  </div>
                  <div>
                    <strong>Arguments:</strong>{" "}
                    {JSON.stringify(state.proposed_action.args)}
                  </div>
                  <div>
                    <strong>Rationale:</strong> {state.proposed_action.rationale}
                  </div>
                  <div>
                    Confidence: {(state.fix_confidence ?? 0) * 100}%
                  </div>
                  <button onClick={() => makeDecision("approved")}>
                    Approve
                  </button>
                  <button onClick={() => makeDecision("rejected")}>
                    Reject
                  </button>
                </div>
              )}

              {state.status === "resolved" && (
                <div>✅ Incident resolved</div>
              )}
              {state.status === "error" && (
                <div style={{ color: "red" }}>
                  Error: {state.last_error_message}
                </div>
              )}
            </div>
          ) : (
            <p>Waiting for workflow state...</p>
          )}
        </div>
      )}
    </div>
  );
}

// ----- Inline status badge -----
function StatusBadge({ status }: { status?: string }) {
  const colorMap: Record<string, string> = {
    new: "blue",
    triaged: "purple",
    investigating: "orange",
    root_caused: "indigo",
    fix_generated: "teal",
    awaiting_human: "goldenrod",
    approved: "green",
    rejected: "red",
    executing: "cyan",
    resolved: "green",
    error: "red",
  };
  return (
    <span
      style={{
        display: "inline-block",
        padding: "0.25rem 0.75rem",
        borderRadius: "999px",
        backgroundColor: colorMap[status ?? ""] || "#ccc",
        color: "white",
        fontWeight: "bold",
        marginBottom: "1rem",
      }}
    >
      {status ?? "unknown"}
    </span>
  );
}