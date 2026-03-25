package cmdinternal

import (
	"strings"
	"testing"
)

func TestDialClient_InvalidAddress(t *testing.T) {
	_, err := DialClient("invalid-host:0", "default")
	if err == nil {
		t.Fatal("expected error for unreachable address, got nil")
	}
	if !strings.Contains(err.Error(), "unable to connect to Temporal") {
		t.Fatalf("unexpected error message: %v", err)
	}
}
