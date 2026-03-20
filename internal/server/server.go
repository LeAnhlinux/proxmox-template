package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/LeAnhlinux/proxmox-template/internal/config"
	"github.com/LeAnhlinux/proxmox-template/internal/executor"
	"github.com/LeAnhlinux/proxmox-template/internal/reporter"
)

type Server struct {
	exec *executor.Executor
	rep  *reporter.Reporter
	cfg  *config.Config
	srv  *http.Server
	port int
}

func New(exec *executor.Executor, rep *reporter.Reporter, cfg *config.Config, port int) *Server {
	s := &Server{
		exec: exec,
		rep:  rep,
		cfg:  cfg,
		port: port,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/status", s.ipFilter(s.handleStatus))
	mux.HandleFunc("/provision", s.ipFilter(s.handleProvision))

	s.srv = &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // no timeout, scripts can run long
	}

	return s
}

func (s *Server) Start() error {
	s.rep.Info("HTTP server listening on :%d", s.port)
	if len(s.cfg.AllowedIPs) > 0 {
		s.rep.Info("IP allowlist enabled: %v", s.cfg.AllowedIPs)
	}
	if len(s.cfg.AllowedScriptPrefixes) > 0 {
		s.rep.Info("Script URL allowlist enabled: %v", s.cfg.AllowedScriptPrefixes)
	}
	if s.cfg.AutoDisable {
		s.rep.Info("Auto-disable enabled: agent will stop after successful provision")
	}
	return s.srv.ListenAndServe()
}

func (s *Server) Stop() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s.srv.Shutdown(ctx)
}

// ipFilter is middleware that rejects requests from non-allowed IPs
func (s *Server) ipFilter(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.cfg.IsIPAllowed(r.RemoteAddr) {
			s.rep.Error("Blocked request from %s to %s", r.RemoteAddr, r.URL.Path)
			writeJSON(w, 403, map[string]string{"error": "forbidden"})
			return
		}
		next(w, r)
	}
}

// GET /health - simple health check (no IP filter, for monitoring tools)
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	writeJSON(w, 200, map[string]interface{}{
		"status":   "ok",
		"hostname": hostname,
		"agent":    "proxmox-agent",
	})
}

// GET /status - current agent status
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]interface{}{
		"task_status": s.exec.Status(),
	})
}

// POST /provision - execute a provisioning script
//
// Request body:
//
//	{
//	  "script_url": "https://git.example.com/raw/scripts/docker.sh",
//	  "domain": "app.gofiber.vn",                             // optional, passed as $DOMAIN to script
//	  "callback_url": "https://api.example.com/vm/callback",  // optional
//	  "env": { "DOCKER_VERSION": "27" },                      // optional
//	  "timeout": 3600                                         // optional, seconds
//	}
//
// Sync mode (default): waits for script to finish, returns result.
// Async mode: add ?async=true query param, returns immediately.
func (s *Server) handleProvision(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]string{"error": "method not allowed"})
		return
	}

	var task executor.Task
	if err := json.NewDecoder(r.Body).Decode(&task); err != nil {
		writeJSON(w, 400, map[string]string{"error": "invalid json: " + err.Error()})
		return
	}

	if task.ScriptURL == "" {
		writeJSON(w, 400, map[string]string{"error": "script_url is required"})
		return
	}

	// Validate script URL against allowlist
	if !s.cfg.IsScriptURLAllowed(task.ScriptURL) {
		s.rep.Error("Blocked script URL: %s (not in allowlist)", task.ScriptURL)
		writeJSON(w, 403, map[string]string{"error": "script_url not allowed"})
		return
	}

	// Check if already running
	if s.exec.Status() == executor.TaskRunning {
		writeJSON(w, 409, map[string]string{"error": "a task is already running"})
		return
	}

	s.rep.Info("Provision request from %s: %s (async=%s)", r.RemoteAddr, task.ScriptURL, r.URL.Query().Get("async"))

	// Async mode
	if r.URL.Query().Get("async") == "true" {
		go func() {
			s.exec.Run(task)
			s.autoDisableIfNeeded()
		}()
		writeJSON(w, 202, map[string]string{
			"message": "provisioning started",
			"script":  task.ScriptURL,
		})
		return
	}

	// Sync mode - wait for completion
	result, err := s.exec.Run(task)
	if err != nil {
		writeJSON(w, 409, map[string]string{"error": err.Error()})
		return
	}

	code := 200
	if result.Status == reporter.StatusFailed {
		code = 500
	}
	writeJSON(w, code, result)

	// Auto-disable after sync provision
	if result.Status == reporter.StatusSuccess {
		go s.autoDisableIfNeeded()
	}
}

// autoDisableIfNeeded stops and disables the agent systemd service after successful provision
func (s *Server) autoDisableIfNeeded() {
	if !s.cfg.AutoDisable {
		return
	}

	s.rep.Info("Auto-disable: stopping and disabling proxmox-agent service...")

	// Small delay to allow response to be sent
	time.Sleep(2 * time.Second)

	// Stop and disable via systemctl
	cmd := "systemctl disable --now proxmox-agent"
	out, err := execCommand("/bin/bash", "-c", cmd)
	if err != nil {
		s.rep.Error("Auto-disable failed: %v (output: %s)", err, string(out))
		return
	}
	s.rep.Info("Auto-disable completed: agent service stopped and disabled")
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}
