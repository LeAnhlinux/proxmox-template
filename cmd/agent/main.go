package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/LeAnhlinux/proxmox-template/internal/config"
	"github.com/LeAnhlinux/proxmox-template/internal/executor"
	"github.com/LeAnhlinux/proxmox-template/internal/reporter"
	"github.com/LeAnhlinux/proxmox-template/internal/server"
)

var (
	version = "dev"
	commit  = "none"
)

func main() {
	port := flag.Int("port", 8080, "HTTP server port")
	logDir := flag.String("log-dir", "/var/log/proxmox-agent", "Log directory")
	configPath := flag.String("config", config.DefaultConfigPath, "Path to config file")
	showVersion := flag.Bool("version", false, "Show version")
	flag.Parse()

	if *showVersion {
		log.Printf("proxmox-agent %s (%s)\n", version, commit)
		os.Exit(0)
	}

	// Setup logger
	rep, err := reporter.New(*logDir)
	if err != nil {
		log.Fatalf("Failed to init reporter: %v", err)
	}
	defer rep.Close()

	rep.Info("proxmox-agent %s starting on port %d", version, *port)

	// Load config
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Setup executor
	exec := executor.New(rep)

	// Setup HTTP server
	srv := server.New(exec, rep, cfg, *port)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		if err := srv.Start(); err != nil {
			log.Fatalf("Server error: %v", err)
		}
	}()

	rep.Info("proxmox-agent ready, waiting for provision commands...")

	<-quit
	rep.Info("Shutting down...")
	srv.Stop()
}
