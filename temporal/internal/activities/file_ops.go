package activities

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
)

// ReadJSONFile reads a file from disk and returns its contents as a string.
// It is intended for reading JSON task lists produced by Claude activities.
func ReadJSONFile(ctx context.Context, path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("read_json_file: path is required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read_json_file: %w", err)
	}
	return string(data), nil
}
