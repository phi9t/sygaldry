package config

import (
	"fmt"
	"os"
	"strconv"
)

const (
	DefaultAddress   = "localhost:7233"
	DefaultNamespace = "default"
	DefaultTaskQueue = "orchestration"
)

func EnvOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func EnvOrInt(key string) (int, bool, error) {
	v := os.Getenv(key)
	if v == "" {
		return 0, false, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, false, fmt.Errorf("%s: %w", key, err)
	}
	return n, true, nil
}
