package config

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
)

const DefaultConfigPath = "/etc/proxmox-agent/config.json"

// Config holds security settings for the agent
type Config struct {
	// AllowedIPs is a list of IPs or CIDRs allowed to access the agent
	// e.g. ["10.0.0.1", "192.168.1.0/24"]
	AllowedIPs []string `json:"allowed_ips"`

	// AllowedScriptPrefixes is a list of URL prefixes that scripts must match
	// e.g. ["https://raw.githubusercontent.com/gofiber/"]
	AllowedScriptPrefixes []string `json:"allowed_script_prefixes"`

	// AutoDisable stops and disables the agent after successful provision
	AutoDisable bool `json:"auto_disable"`

	// parsed CIDRs for fast matching
	parsedNets []*net.IPNet
	parsedIPs  []net.IP
}

// Load reads config from a JSON file. Returns default (allow-all) config if file doesn't exist.
func Load(path string) (*Config, error) {
	if path == "" {
		path = DefaultConfigPath
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// No config file = no restrictions (backward compatible)
			return &Config{}, nil
		}
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	// Parse IPs and CIDRs
	for _, entry := range cfg.AllowedIPs {
		if strings.Contains(entry, "/") {
			_, cidr, err := net.ParseCIDR(entry)
			if err != nil {
				return nil, fmt.Errorf("invalid CIDR %q: %w", entry, err)
			}
			cfg.parsedNets = append(cfg.parsedNets, cidr)
		} else {
			ip := net.ParseIP(entry)
			if ip == nil {
				return nil, fmt.Errorf("invalid IP %q", entry)
			}
			cfg.parsedIPs = append(cfg.parsedIPs, ip)
		}
	}

	return &cfg, nil
}

// IsIPAllowed checks if the given IP is in the allowlist.
// Returns true if no allowlist is configured (empty = allow all).
func (c *Config) IsIPAllowed(remoteAddr string) bool {
	// No allowlist configured = allow all
	if len(c.AllowedIPs) == 0 {
		return true
	}

	// Extract IP from host:port
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr // might be IP without port
	}

	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}

	// Check exact IP match
	for _, allowed := range c.parsedIPs {
		if allowed.Equal(ip) {
			return true
		}
	}

	// Check CIDR match
	for _, cidr := range c.parsedNets {
		if cidr.Contains(ip) {
			return true
		}
	}

	return false
}

// IsScriptURLAllowed checks if the script URL starts with an allowed prefix.
// Returns true if no allowlist is configured (empty = allow all).
func (c *Config) IsScriptURLAllowed(scriptURL string) bool {
	// No allowlist configured = allow all
	if len(c.AllowedScriptPrefixes) == 0 {
		return true
	}

	for _, prefix := range c.AllowedScriptPrefixes {
		if strings.HasPrefix(scriptURL, prefix) {
			return true
		}
	}

	return false
}
