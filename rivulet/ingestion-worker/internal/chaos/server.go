package chaos

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	leakedConnectionCount    = 10
	connectionAcquireTimeout = 2 * time.Second
	cpuSpinWorkers           = 4
)

type cpuRun struct {
	stop chan struct{}
	wg   sync.WaitGroup
}

type Server struct {
	httpServer     *http.Server
	pool           *pgxpool.Pool
	cancelConsumer context.CancelFunc

	mu          sync.Mutex
	leakedConns []*pgxpool.Conn
	cpuRun      *cpuRun
	cpuSink     atomic.Uint64
}

// NewServer creates the internal fault-injection HTTP server.
//
// The address must not be exposed through a Kubernetes Service or Ingress.
// Network exposure is a deployment concern and is not enforced by this type.
func NewServer(addr string, pool *pgxpool.Pool, cancelConsumer context.CancelFunc) *Server {
	s := &Server{
		pool:           pool,
		cancelConsumer: cancelConsumer,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /__chaos/leak-db", s.handleLeakDB)
	mux.HandleFunc("POST /__chaos/cpu-spin", s.handleCPUSpin)
	mux.HandleFunc("POST /__chaos/pause-consumer", s.handlePauseConsumer)
	mux.HandleFunc("POST /__chaos/reset", s.handleReset)
	mux.HandleFunc("GET /healthz", s.handleHealthz)

	s.httpServer = &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	return s
}

// Start begins serving in a background goroutine.
func (s *Server) Start() {
	go func() {
		slog.Info("internal HTTP server starting", "addr", s.httpServer.Addr)

		if err := s.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error(
				"internal HTTP server failed",
				"addr", s.httpServer.Addr,
				"error", err,
			)
		}
	}()
}

// Shutdown stops the HTTP server and then removes any injected faults.
func (s *Server) Shutdown(ctx context.Context) error {
	err := s.httpServer.Shutdown(ctx)
	s.resetState()
	return err
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) handleLeakDB(w http.ResponseWriter, r *http.Request) {
	if s.pool == nil {
		writeJSON(
			w,
			http.StatusInternalServerError,
			map[string]string{"error": "pool not configured"},
		)
		return
	}

	// Serialize acquisition and reset so a reset cannot release the tracked
	// connections while an acquisition request is still modifying state.
	s.mu.Lock()
	defer s.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), connectionAcquireTimeout)
	defer cancel()

	acquired := 0
	var acquireErr error

	for i := 0; i < leakedConnectionCount; i++ {
		conn, err := s.pool.Acquire(ctx)
		if err != nil {
			acquireErr = err
			break
		}

		s.leakedConns = append(s.leakedConns, conn)
		acquired++
	}

	// A partial acquisition is still a valid fault injection. Return the
	// number successfully retained so the harness can observe what happened.
	if acquired == 0 {
		payload := map[string]any{
			"error":     "failed to acquire a connection",
			"requested": leakedConnectionCount,
		}
		if acquireErr != nil {
			payload["cause"] = acquireErr.Error()
		}

		writeJSON(w, http.StatusServiceUnavailable, payload)
		return
	}

	payload := map[string]any{
		"status":       "leaked",
		"requested":    leakedConnectionCount,
		"acquired":     acquired,
		"total_leaked": len(s.leakedConns),
	}

	if acquireErr != nil {
		payload["cause"] = acquireErr.Error()
	}

	writeJSON(w, http.StatusOK, payload)
}

func (s *Server) handleCPUSpin(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()

	if s.cpuRun != nil {
		s.mu.Unlock()
		writeJSON(
			w,
			http.StatusOK,
			map[string]string{"status": "already running"},
		)
		return
	}

	run := &cpuRun{
		stop: make(chan struct{}),
	}
	run.wg.Add(cpuSpinWorkers)

	s.cpuRun = run
	s.mu.Unlock()

	// Pass the captured run object rather than reading s.cpuRun after the
	// mutex is released. This prevents reset/restart races.
	for i := 0; i < cpuSpinWorkers; i++ {
		go s.runCPUSpinner(run)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "started",
		"workers": cpuSpinWorkers,
	})
}

func (s *Server) runCPUSpinner(run *cpuRun) {
	defer run.wg.Done()

	for {
		select {
		case <-run.stop:
			return
		default:
			// The atomic write prevents the compiler from reducing this to a
			// side-effect-free local loop while providing race-free shared work.
			s.cpuSink.Add(1)
		}
	}
}

func (s *Server) handlePauseConsumer(w http.ResponseWriter, r *http.Request) {
	if s.cancelConsumer == nil {
		writeJSON(
			w,
			http.StatusOK,
			map[string]string{"status": "no consumer cancel func provided"},
		)
		return
	}

	s.cancelConsumer()
	writeJSON(
		w,
		http.StatusOK,
		map[string]string{"status": "consumer context cancelled"},
	)
}

func (s *Server) handleReset(w http.ResponseWriter, r *http.Request) {
	s.resetState()
	writeJSON(
		w,
		http.StatusOK,
		map[string]string{"status": "reset complete"},
	)
}

func (s *Server) resetState() {
	s.mu.Lock()

	leaked := s.leakedConns
	s.leakedConns = nil

	run := s.cpuRun
	s.cpuRun = nil

	s.mu.Unlock()

	for _, conn := range leaked {
		if conn != nil {
			conn.Release()
		}
	}

	if run != nil {
		close(run.stop)
		run.wg.Wait()
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
