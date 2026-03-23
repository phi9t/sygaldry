package activities

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMultiEngineDefaultEngines(t *testing.T) {
	input := MultiEngineAgentTaskInput{}
	engines := input.Engines
	if len(engines) != 0 {
		t.Errorf("input.Engines should be empty by default, got %v", engines)
	}
	// Verify DefaultExecEngines has expected entries
	expected := []AgentTaskEngine{
		AgentEngineCursor,
		AgentEngineGemini,
		AgentEngineOpenCode,
		AgentEngineCodex,
	}
	if len(DefaultExecEngines) != len(expected) {
		t.Fatalf("DefaultExecEngines len=%d, want %d", len(DefaultExecEngines), len(expected))
	}
	for i, e := range expected {
		if DefaultExecEngines[i] != e {
			t.Errorf("DefaultExecEngines[%d]=%s, want %s", i, DefaultExecEngines[i], e)
		}
	}
}

func TestDetectQuotaPattern(t *testing.T) {
	tests := []struct {
		text    string
		wantHit bool
	}{
		{"out of credits for this month", true},
		{"quota exceeded on model", true},
		{"rate limit reached", true},
		{"payment required", true},
		{"unauthorized: invalid key", true},
		{"billing issue detected", true},
		{"context length exceeded", true},
		{"compilation failed: syntax error", false},
		{"", false},
	}
	for _, tt := range tests {
		got := detectQuotaPattern(tt.text)
		if (got != "") != tt.wantHit {
			t.Errorf("detectQuotaPattern(%q) = %q, wantHit=%v", tt.text, got, tt.wantHit)
		}
	}
}

func TestCalcBackoff(t *testing.T) {
	// Verify backoff doubles each round: base * 2^round
	base := 30
	for _, tc := range []struct{ round, want int }{{0, 30}, {1, 60}, {2, 120}, {3, 240}} {
		got := base * (1 << uint(tc.round))
		if got != tc.want {
			t.Errorf("backoff round %d: got %d, want %d", tc.round, got, tc.want)
		}
	}
}

func TestMultiEngineAgentTaskEchoSuccess(t *testing.T) {
	input := MultiEngineAgentTaskInput{
		Name:    "test-echo",
		Engines: []AgentTaskEngine{AgentEngineEcho},
		Prompt:  "hello multi-engine",
	}
	result, err := MultiEngineAgentTask(context.Background(), input)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("expected exit 0, got %d", result.ExitCode)
	}
	if !strings.Contains(result.Stdout, "hello multi-engine") {
		t.Errorf("expected prompt in stdout, got: %q", result.Stdout)
	}
}

func TestMultiEngineAgentTaskAllFail(t *testing.T) {
	// Use a fake binary that always exits 1
	dir := t.TempDir()
	fakePath := filepath.Join(dir, "cursor")
	if err := os.WriteFile(fakePath, []byte("#!/usr/bin/env sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldPath := os.Getenv("PATH")
	_ = os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath)
	t.Cleanup(func() { _ = os.Setenv("PATH", oldPath) })

	input := MultiEngineAgentTaskInput{
		Name:      "test-all-fail",
		Engines:   []AgentTaskEngine{AgentEngineCursor},
		Prompt:    "hello",
		MaxRounds: 1,
	}
	_, err := MultiEngineAgentTask(context.Background(), input)
	if err == nil {
		t.Fatal("expected error when all engines fail")
	}
	if !strings.Contains(err.Error(), "all engines failed") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestMultiEngineAgentTaskFirstSucceeds(t *testing.T) {
	// Echo engine (first) succeeds; others never tried
	input := MultiEngineAgentTaskInput{
		Name: "test-first-success",
		Engines: []AgentTaskEngine{
			AgentEngineEcho,
			AgentEngineCursor, // would fail if reached
		},
		Prompt:    "first wins",
		MaxRounds: 1,
	}
	result, err := MultiEngineAgentTask(context.Background(), input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("expected exit 0, got %d", result.ExitCode)
	}
}
