package main

import (
	"testing"
)

func TestEnvOr(t *testing.T) {
	t.Setenv("TEST_ENVOR_KEY", "hello")
	if got := envOr("TEST_ENVOR_KEY", "default"); got != "hello" {
		t.Errorf("expected %q, got %q", "hello", got)
	}

	t.Setenv("TEST_ENVOR_KEY", "")
	if got := envOr("TEST_ENVOR_KEY", "default"); got != "default" {
		t.Errorf("expected fallback %q for empty value, got %q", "default", got)
	}

	if got := envOr("TEST_ENVOR_UNSET_XYZ", "fallback"); got != "fallback" {
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
