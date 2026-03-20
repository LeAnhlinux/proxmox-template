package config

import (
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

const (
	// RemoteFetchInterval is how often to re-fetch the remote IP list
	RemoteFetchInterval = 5 * time.Minute
	// RemoteFetchTimeout is the HTTP timeout for fetching remote IPs
	RemoteFetchTimeout = 10 * time.Second
)

// RemoteIPFetcher periodically fetches allowed IPs from a remote URL
type RemoteIPFetcher struct {
	url    string
	cfg    *Config
	stopCh chan struct{}
}

// NewRemoteIPFetcher creates a fetcher that updates the config's IP list from a URL.
// It fetches immediately on creation, then every RemoteFetchInterval.
func NewRemoteIPFetcher(cfg *Config, url string) *RemoteIPFetcher {
	f := &RemoteIPFetcher{
		url:    url,
		cfg:    cfg,
		stopCh: make(chan struct{}),
	}

	// Fetch immediately on startup
	f.fetch()

	// Start background refresh
	go f.loop()

	return f
}

// Stop stops the background fetcher
func (f *RemoteIPFetcher) Stop() {
	close(f.stopCh)
}

func (f *RemoteIPFetcher) loop() {
	ticker := time.NewTicker(RemoteFetchInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			f.fetch()
		case <-f.stopCh:
			return
		}
	}
}

func (f *RemoteIPFetcher) fetch() {
	client := &http.Client{Timeout: RemoteFetchTimeout}
	resp, err := client.Get(f.url)
	if err != nil {
		log.Printf("[config] Failed to fetch remote IPs from %s: %v", f.url, err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("[config] Remote IP fetch returned status %d from %s", resp.StatusCode, f.url)
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("[config] Failed to read remote IP response: %v", err)
		return
	}

	// Parse IPs from text (one per line, # comments, blank lines ignored)
	remoteIPs := parseIPList(string(body))
	if len(remoteIPs) == 0 {
		log.Printf("[config] Remote IP list is empty, keeping current config")
		return
	}

	// Merge remote IPs into config (local + remote, deduplicated)
	f.cfg.mu.Lock()
	defer f.cfg.mu.Unlock()

	f.cfg.mergeRemoteIPs(remoteIPs)
	log.Printf("[config] Updated allowed IPs from remote: %v (total: %d)", remoteIPs, len(f.cfg.AllowedIPs))
}

// parseIPList parses a text file with one IP/CIDR per line
func parseIPList(text string) []string {
	var ips []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		ips = append(ips, line)
	}
	return ips
}

// mergeRemoteIPs replaces remote IPs in the config, keeping local IPs intact
func (c *Config) mergeRemoteIPs(remoteIPs []string) {
	// Build new combined list: local IPs + remote IPs (deduplicated)
	seen := make(map[string]bool)
	var combined []string

	// Keep local IPs first
	for _, ip := range c.localIPs {
		if !seen[ip] {
			seen[ip] = true
			combined = append(combined, ip)
		}
	}

	// Add remote IPs
	for _, ip := range remoteIPs {
		if !seen[ip] {
			seen[ip] = true
			combined = append(combined, ip)
		}
	}

	c.AllowedIPs = combined

	// Re-parse all IPs/CIDRs
	c.parsedIPs = nil
	c.parsedNets = nil
	for _, entry := range c.AllowedIPs {
		if strings.Contains(entry, "/") {
			_, cidr, err := net.ParseCIDR(entry)
			if err != nil {
				log.Printf("[config] Invalid CIDR from remote: %q", entry)
				continue
			}
			c.parsedNets = append(c.parsedNets, cidr)
		} else {
			ip := net.ParseIP(entry)
			if ip == nil {
				log.Printf("[config] Invalid IP from remote: %q", entry)
				continue
			}
			c.parsedIPs = append(c.parsedIPs, ip)
		}
	}
}
