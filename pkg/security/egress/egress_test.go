package egress

import "testing"

func TestParseRejectsPlainHTTPByDefault(t *testing.T) {
	if _, err := Parse("http://example.com/api", true); err == nil {
		t.Fatalf("expected plaintext http to be rejected")
	}
}

func TestParseAllowsPlainHTTPWhenInsecureAllowed(t *testing.T) {
	t.Setenv(EnvAllowInsecure, "true")
	if _, err := Parse("http://example.com/api", true); err != nil {
		t.Fatalf("expected plaintext http to be allowed, got %v", err)
	}
}

func TestParseRejectsCloudMetadataEndpoint(t *testing.T) {
	for _, target := range []string{
		"http://169.254.169.254/latest/meta-data/",
		"http://[fe80::1]/",
		"http://metadata.google.internal/",
	} {
		if _, err := Parse(target, false); err == nil {
			t.Fatalf("expected metadata target %q to be rejected", target)
		}
	}
}

func TestParseRejectsUnsupportedScheme(t *testing.T) {
	if _, err := Parse("file:///etc/passwd", false); err == nil {
		t.Fatalf("expected unsupported scheme to be rejected")
	}
}

func TestParseAppliesHostAllowlist(t *testing.T) {
	t.Setenv(EnvHostAllowlist, "goodrain.com, internal.example")
	if _, err := Parse("https://app.goodrain.com/path", true); err != nil {
		t.Fatalf("expected allowlisted host to pass, got %v", err)
	}
	if _, err := Parse("https://evil.example.net/path", true); err == nil {
		t.Fatalf("expected host outside allowlist to be rejected")
	}
}

func TestParseBlocksPrivateTargetsWhenEnabled(t *testing.T) {
	t.Setenv(EnvBlockPrivate, "true")
	if _, err := Parse("https://10.0.0.1/path", true); err == nil {
		t.Fatalf("expected private target to be rejected")
	}
}

func TestParseAllowsPrivateTargetsByDefault(t *testing.T) {
	if _, err := Parse("https://10.0.0.1/path", true); err != nil {
		t.Fatalf("expected in-cluster target to pass by default, got %v", err)
	}
}
