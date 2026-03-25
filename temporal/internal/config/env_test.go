package config

import (
	"testing"
)

func TestEnvOr(t *testing.T) {
	t.Run("returns env value when set", func(t *testing.T) {
		t.Setenv("TEST_ENVOR_KEY", "myvalue")
		got := EnvOr("TEST_ENVOR_KEY", "fallback")
		if got != "myvalue" {
			t.Errorf("got %q, want %q", got, "myvalue")
		}
	})

	t.Run("returns fallback when unset", func(t *testing.T) {
		got := EnvOr("TEST_ENVOR_UNSET_KEY", "fallback")
		if got != "fallback" {
			t.Errorf("got %q, want %q", got, "fallback")
		}
	})

	t.Run("returns fallback when empty", func(t *testing.T) {
		t.Setenv("TEST_ENVOR_EMPTY_KEY", "")
		got := EnvOr("TEST_ENVOR_EMPTY_KEY", "fallback")
		if got != "fallback" {
			t.Errorf("got %q, want %q", got, "fallback")
		}
	})
}
