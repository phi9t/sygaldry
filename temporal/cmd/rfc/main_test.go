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
