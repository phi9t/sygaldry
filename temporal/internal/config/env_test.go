package config

import (
	"testing"
)

func TestEnvOrInt(t *testing.T) {
	t.Run("returns zero and false when unset", func(t *testing.T) {
		n, ok, err := EnvOrInt("TEST_ENVORINT_UNSET_KEY")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if ok {
			t.Errorf("got ok=true, want false")
		}
		if n != 0 {
			t.Errorf("got %d, want 0", n)
		}
	})

	t.Run("returns parsed int when set", func(t *testing.T) {
		t.Setenv("TEST_ENVORINT_KEY", "42")
		n, ok, err := EnvOrInt("TEST_ENVORINT_KEY")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !ok {
			t.Errorf("got ok=false, want true")
		}
		if n != 42 {
			t.Errorf("got %d, want 42", n)
		}
	})

	t.Run("returns error on invalid int", func(t *testing.T) {
		t.Setenv("TEST_ENVORINT_BAD", "notanint")
		_, _, err := EnvOrInt("TEST_ENVORINT_BAD")
		if err == nil {
			t.Error("expected error, got nil")
		}
	})
}

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
