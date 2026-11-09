// Package egress validates outbound network targets before the process sends
// data outside its own cluster.
//
// Always rejected: link-local addresses (including the 169.254.169.254 cloud
// metadata endpoint), unspecified and multicast targets. Loopback, private and
// ULA ranges stay reachable by default because in-cluster repositories are a
// supported deployment; set RBD_EGRESS_BLOCK_PRIVATE=true to reject them too.
package egress

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
)

const (
	// EnvAllowInsecure allows plaintext http targets.
	EnvAllowInsecure = "RBD_EGRESS_ALLOW_INSECURE"
	// EnvHostAllowlist is a comma separated list of allowed host suffixes.
	EnvHostAllowlist = "RBD_EGRESS_HOST_ALLOWLIST"
	// EnvBlockPrivate rejects RFC1918 / ULA / private targets.
	EnvBlockPrivate = "RBD_EGRESS_BLOCK_PRIVATE"
)

var metadataHostnames = map[string]struct{}{
	"metadata":                   {},
	"metadata.google.internal":   {},
	"metadata.azure.internal":    {},
	"instance-data":              {},
	"instance-data.ec2.internal": {},
}

// Parse validates an outbound URL and returns it. When requireHTTPS is true,
// plaintext http targets are rejected unless EnvAllowInsecure is enabled.
func Parse(rawURL string, requireHTTPS bool) (*url.URL, error) {
	if strings.TrimSpace(rawURL) == "" {
		return nil, fmt.Errorf("egress: empty target url")
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("egress: invalid target url: %w", err)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "https":
	case "http":
		if requireHTTPS && !AllowInsecure() {
			return nil, fmt.Errorf("egress: plaintext http target rejected: %s", parsed.Host)
		}
	default:
		return nil, fmt.Errorf("egress: unsupported scheme %q", parsed.Scheme)
	}
	host := parsed.Hostname()
	if host == "" {
		return nil, fmt.Errorf("egress: target url missing host")
	}
	if err := validateHost(host); err != nil {
		return nil, err
	}
	if !HostAllowed(host) {
		return nil, fmt.Errorf("egress: host %q is not in %s", host, EnvHostAllowlist)
	}
	return parsed, nil
}

// AllowInsecure reports whether plaintext http targets were explicitly allowed.
func AllowInsecure() bool {
	return parseBool(os.Getenv(EnvAllowInsecure))
}

// HostAllowlist returns the configured allowed host suffixes.
func HostAllowlist() []string {
	raw := strings.TrimSpace(os.Getenv(EnvHostAllowlist))
	if raw == "" {
		return nil
	}
	var hosts []string
	for _, item := range strings.Split(raw, ",") {
		item = strings.ToLower(strings.TrimSpace(item))
		if item != "" {
			hosts = append(hosts, item)
		}
	}
	return hosts
}

// HostAllowed reports whether the host matches the configured allowlist. An
// empty allowlist allows every host, so the check stays backwards compatible.
func HostAllowed(host string) bool {
	allowed := HostAllowlist()
	if len(allowed) == 0 {
		return true
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	for _, candidate := range allowed {
		if host == candidate || strings.HasSuffix(host, "."+candidate) {
			return true
		}
	}
	return false
}

func validateHost(host string) error {
	trimmed := strings.Trim(host, "[]")
	if _, ok := metadataHostnames[strings.ToLower(strings.TrimSuffix(trimmed, "."))]; ok {
		return fmt.Errorf("egress: metadata endpoint %q rejected", trimmed)
	}
	if ip := net.ParseIP(trimmed); ip != nil {
		return validateIP(ip)
	}
	// Resolve names so that a hostname pointing at a loopback or metadata
	// address is rejected too. Unresolvable names are left to the request.
	addrs, err := net.LookupIP(trimmed)
	if err != nil {
		return nil
	}
	for _, ip := range addrs {
		if err := validateIP(ip); err != nil {
			return err
		}
	}
	return nil
}

func validateIP(ip net.IP) error {
	switch {
	case ip.IsUnspecified():
		return fmt.Errorf("egress: unspecified target %s rejected", ip)
	case ip.IsLinkLocalUnicast(), ip.IsLinkLocalMulticast():
		return fmt.Errorf("egress: link-local target %s rejected", ip)
	case ip.IsMulticast():
		return fmt.Errorf("egress: multicast target %s rejected", ip)
	}
	if parseBool(os.Getenv(EnvBlockPrivate)) && (ip.IsLoopback() || ip.IsPrivate()) {
		return fmt.Errorf("egress: non-public target %s rejected by %s", ip, EnvBlockPrivate)
	}
	return nil
}

func parseBool(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "1", "yes", "on":
		return true
	default:
		return false
	}
}
