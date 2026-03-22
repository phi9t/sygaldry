package main

import (
	"testing"

	"temporal-orchestration/internal/config"
)

func TestEnvOr(t *testing.T) {
	t.Setenv("TEST_ENVOR_KEY", "hello")
	if got := config.EnvOr("TEST_ENVOR_KEY", "default"); got != "hello" {
		t.Errorf("expected %q, got %q", "hello", got)
	}

	t.Setenv("TEST_ENVOR_KEY", "")
	if got := config.EnvOr("TEST_ENVOR_KEY", "default"); got != "default" {
		t.Errorf("expected fallback %q for empty value, got %q", "default", got)
	}

	if got := config.EnvOr("TEST_ENVOR_UNSET_XYZ", "fallback"); got != "fallback" {
		t.Errorf("expected fallback %q for unset key, got %q", "fallback", got)
	}
}

func TestPrintRFCOutput_JSON(t *testing.T) {
	type payload struct{ Value string }
	if err := printRFCOutput("json", payload{Value: "test"}); err != nil {
		t.Fatalf("json mode returned error: %v", err)
	}
}

func TestPrintRFCOutput_YAML(t *testing.T) {
	type payload struct{ Value string }
	if err := printRFCOutput("yaml", payload{Value: "test"}); err != nil {
		t.Fatalf("yaml mode returned error: %v", err)
	}
}

func TestPrintRFCOutput_UnsupportedFormat(t *testing.T) {
	if err := printRFCOutput("xml", nil); err == nil {
		t.Error("expected error for unsupported format")
	}
}

func TestRunMissingRFC(t *testing.T) {
	// run() should return an error immediately when -rfc is not provided
	// (no Temporal connection required).
	if err := run([]string{}); err == nil {
		t.Error("run() with no args should return error for missing -rfc flag")
	}
}
