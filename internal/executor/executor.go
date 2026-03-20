package executor

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/LeAnhlinux/proxmox-template/internal/reporter"
)

type TaskStatus string

const (
	TaskIdle    TaskStatus = "idle"
	TaskRunning TaskStatus = "running"
)

type Task struct {
	ScriptURL   string            `json:"script_url"`
	Domain      string            `json:"domain,omitempty"`      // domain name for the VM (e.g. app.gofiber.vn)
	CallbackURL string            `json:"callback_url,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	Timeout     int               `json:"timeout,omitempty"` // seconds, default 3600
}

type TaskResult struct {
	Script   string          `json:"script"`
	Status   reporter.Status `json:"status"`
	Output   string          `json:"output"`
	Error    string          `json:"error,omitempty"`
	Duration string          `json:"duration"`
}

type Executor struct {
	rep    *reporter.Reporter
	mu     sync.Mutex
	status TaskStatus
	workDir string
}

func New(rep *reporter.Reporter) *Executor {
	workDir := "/opt/proxmox-agent/scripts"
	os.MkdirAll(workDir, 0755)

	return &Executor{
		rep:     rep,
		status:  TaskIdle,
		workDir: workDir,
	}
}

func (e *Executor) Status() TaskStatus {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.status
}

func (e *Executor) Run(task Task) (*TaskResult, error) {
	e.mu.Lock()
	if e.status == TaskRunning {
		e.mu.Unlock()
		return nil, fmt.Errorf("another task is already running")
	}
	e.status = TaskRunning
	e.mu.Unlock()

	defer func() {
		e.mu.Lock()
		e.status = TaskIdle
		e.mu.Unlock()
	}()

	start := time.Now()
	hostname, _ := os.Hostname()

	// Report started
	e.rep.Info("Task started: %s (domain=%s)", task.ScriptURL, task.Domain)
	e.rep.Callback(task.CallbackURL, reporter.CallbackPayload{
		Hostname:  hostname,
		Domain:    task.Domain,
		Script:    task.ScriptURL,
		Status:    reporter.StatusStarted,
		StartedAt: start.Format(time.RFC3339),
	})

	// Download script
	scriptPath, err := e.downloadScript(task.ScriptURL)
	if err != nil {
		errMsg := fmt.Sprintf("download failed: %v", err)
		e.rep.Error(errMsg)
		result := &TaskResult{
			Script:   task.ScriptURL,
			Status:   reporter.StatusFailed,
			Error:    errMsg,
			Duration: time.Since(start).String(),
		}
		e.rep.Callback(task.CallbackURL, reporter.CallbackPayload{
			Hostname:  hostname,
			Domain:    task.Domain,
			Script:    task.ScriptURL,
			Status:    reporter.StatusFailed,
			Error:     errMsg,
			StartedAt: start.Format(time.RFC3339),
			EndedAt:   time.Now().Format(time.RFC3339),
			Duration:  time.Since(start).String(),
		})
		return result, nil
	}

	// Execute script
	timeout := task.Timeout
	if timeout <= 0 {
		timeout = 3600 // default 1 hour
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/bash", scriptPath)
	cmd.Dir = e.workDir

	// Set environment variables
	cmd.Env = append(os.Environ(),
		"DEBIAN_FRONTEND=noninteractive",
		"LC_ALL=C",
		"LANG=en_US.UTF-8",
	)
	// Inject domain as env var so scripts can use $DOMAIN
	if task.Domain != "" {
		cmd.Env = append(cmd.Env, fmt.Sprintf("DOMAIN=%s", task.Domain))
	}
	for k, v := range task.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	// Capture combined output
	output, execErr := cmd.CombinedOutput()

	duration := time.Since(start)
	status := reporter.StatusSuccess
	errMsg := ""

	if execErr != nil {
		status = reporter.StatusFailed
		errMsg = execErr.Error()
		e.rep.Error("Script failed: %s - %v", task.ScriptURL, execErr)
	} else {
		e.rep.Info("Script completed: %s (took %s)", task.ScriptURL, duration)
	}

	// Save log locally
	scriptName := filepath.Base(task.ScriptURL)
	e.rep.SaveScriptLog(scriptName, output)

	// Callback
	e.rep.Callback(task.CallbackURL, reporter.CallbackPayload{
		Hostname:  hostname,
		Domain:    task.Domain,
		Script:    task.ScriptURL,
		Status:    status,
		Output:    truncateOutput(string(output), 10000),
		Error:     errMsg,
		StartedAt: start.Format(time.RFC3339),
		EndedAt:   time.Now().Format(time.RFC3339),
		Duration:  duration.String(),
	})

	return &TaskResult{
		Script:   task.ScriptURL,
		Status:   status,
		Output:   string(output),
		Error:    errMsg,
		Duration: duration.String(),
	}, nil
}

func (e *Executor) downloadScript(url string) (string, error) {
	e.rep.Info("Downloading script: %s", url)

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("http get: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("http status %d", resp.StatusCode)
	}

	// Save to work dir
	scriptName := filepath.Base(url)
	if scriptName == "" || scriptName == "." {
		scriptName = "provision.sh"
	}
	scriptPath := filepath.Join(e.workDir, scriptName)

	f, err := os.OpenFile(scriptPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
	if err != nil {
		return "", fmt.Errorf("create file: %w", err)
	}
	defer f.Close()

	if _, err := io.Copy(f, resp.Body); err != nil {
		return "", fmt.Errorf("write file: %w", err)
	}

	e.rep.Info("Script saved: %s", scriptPath)
	return scriptPath, nil
}

func truncateOutput(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[len(s)-maxLen:]
}
