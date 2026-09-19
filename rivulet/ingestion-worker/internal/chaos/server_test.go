package chaos

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestServerHealthz(t *testing.T) {
	s := NewServer(":0", nil, nil)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}

	if got := w.Body.String(); got != "ok" {
		t.Fatalf("body = %q, want %q", got, "ok")
	}
}

func TestServerHealthzRejectsNonGET(t *testing.T) {
	s := NewServer(":0", nil, nil)

	req := httptest.NewRequest(http.MethodPost, "/healthz", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusMethodNotAllowed)
	}
}

func TestServerPauseConsumer(t *testing.T) {
	var calls atomic.Int32

	cancel := func() {
		calls.Add(1)
	}

	s := NewServer(":0", nil, cancel)

	req := httptest.NewRequest(http.MethodPost, "/__chaos/pause-consumer", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}

	if got := calls.Load(); got != 1 {
		t.Fatalf("cancel calls = %d, want 1", got)
	}
}

func TestServerPauseConsumerWithoutCancelFunc(t *testing.T) {
	s := NewServer(":0", nil, nil)

	req := httptest.NewRequest(http.MethodPost, "/__chaos/pause-consumer", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
}

func TestServerCPUSpinAndReset(t *testing.T) {
	s := NewServer(":0", nil, nil)
	t.Cleanup(s.resetState)

	req := httptest.NewRequest(http.MethodPost, "/__chaos/cpu-spin", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}

	var payload map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if got := payload["status"]; got != "started" {
		t.Fatalf("status payload = %v, want started", got)
	}

	s.mu.Lock()
	run := s.cpuRun
	s.mu.Unlock()

	if run == nil {
		t.Fatal("cpu run is nil after start")
	}

	req = httptest.NewRequest(http.MethodPost, "/__chaos/reset", nil)
	w = httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("reset status = %d, want %d", w.Code, http.StatusOK)
	}

	s.mu.Lock()
	remaining := s.cpuRun
	s.mu.Unlock()

	if remaining != nil {
		t.Fatal("cpu run still active after reset")
	}
}

func TestServerLeakDBWithoutPool(t *testing.T) {
	s := NewServer(":0", nil, nil)

	req := httptest.NewRequest(http.MethodPost, "/__chaos/leak-db", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}

func TestServerMethodNotAllowed(t *testing.T) {
	s := NewServer(":0", nil, nil)

	endpoints := []string{
		"/__chaos/leak-db",
		"/__chaos/cpu-spin",
		"/__chaos/pause-consumer",
		"/__chaos/reset",
	}

	for _, endpoint := range endpoints {
		t.Run(endpoint, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, endpoint, nil)
			w := httptest.NewRecorder()

			s.httpServer.Handler.ServeHTTP(w, req)

			if w.Code != http.StatusMethodNotAllowed {
				t.Fatalf(
					"status = %d, want %d",
					w.Code,
					http.StatusMethodNotAllowed,
				)
			}
		})
	}
}

func TestServerShutdownResetsState(t *testing.T) {
	s := NewServer(":0", nil, nil)

	req := httptest.NewRequest(http.MethodPost, "/__chaos/cpu-spin", nil)
	w := httptest.NewRecorder()

	s.httpServer.Handler.ServeHTTP(w, req)

	if err := s.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cpuRun != nil {
		t.Fatal("cpu run still active after shutdown")
	}

	if s.leakedConns != nil {
		t.Fatal("leaked connections still tracked after shutdown")
	}
}
