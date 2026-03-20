package reporter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

type Status string

const (
	StatusStarted   Status = "started"
	StatusRunning   Status = "running"
	StatusSuccess   Status = "success"
	StatusFailed    Status = "failed"
)

// CallbackPayload is sent back to the control API
type CallbackPayload struct {
	VMID      string `json:"vm_id"`
	Hostname  string `json:"hostname"`
	Domain    string `json:"domain,omitempty"`
	IP        string `json:"ip,omitempty"`
	Script    string `json:"script"`
	Status    Status `json:"status"`
	Output    string `json:"output,omitempty"`
	Error     string `json:"error,omitempty"`
	StartedAt string `json:"started_at"`
	EndedAt   string `json:"ended_at,omitempty"`
	Duration  string `json:"duration,omitempty"`
}

type Reporter struct {
	logFile *os.File
	logger  *log.Logger
	logDir  string
}

func New(logDir string) (*Reporter, error) {
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return nil, fmt.Errorf("create log dir: %w", err)
	}

	logPath := filepath.Join(logDir, "agent.log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, fmt.Errorf("open log file: %w", err)
	}

	logger := log.New(f, "", log.LstdFlags)

	// Also log to stdout for systemd journal
	log.SetFlags(log.LstdFlags)

	return &Reporter{
		logFile: f,
		logger:  logger,
		logDir:  logDir,
	}, nil
}

func (r *Reporter) Close() {
	r.logFile.Close()
}

func (r *Reporter) Info(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	r.logger.Println("[INFO]", msg)
	log.Println("[INFO]", msg)
}

func (r *Reporter) Error(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	r.logger.Println("[ERROR]", msg)
	log.Println("[ERROR]", msg)
}

// SaveScriptLog saves stdout/stderr of a script execution
func (r *Reporter) SaveScriptLog(scriptName string, output []byte) {
	logPath := filepath.Join(r.logDir, fmt.Sprintf("script-%s-%s.log",
		scriptName, time.Now().Format("20060102-150405")))
	os.WriteFile(logPath, output, 0644)
}

// Callback sends status to the control API
func (r *Reporter) Callback(callbackURL string, payload CallbackPayload) error {
	if callbackURL == "" {
		r.Info("No callback URL, skipping remote report")
		return nil
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal callback: %w", err)
	}

	r.Info("Sending callback to %s: status=%s", callbackURL, payload.Status)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(callbackURL, "application/json", bytes.NewReader(data))
	if err != nil {
		r.Error("Callback failed: %v", err)
		return fmt.Errorf("callback request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		r.Error("Callback returned status %d", resp.StatusCode)
		return fmt.Errorf("callback status: %d", resp.StatusCode)
	}

	r.Info("Callback success: %d", resp.StatusCode)
	return nil
}
