package main

import (
	"reflect"
	"testing"

	"temporal-orchestration/internal/workflows"
)

func TestMergeStringMaps(t *testing.T) {
	tests := []struct {
		name     string
		base     map[string]string
		override map[string]string
		want     map[string]string
	}{
		{
			name:     "nil base",
			base:     nil,
			override: map[string]string{"a": "1"},
			want:     map[string]string{"a": "1"},
		},
		{
			name:     "nil override",
			base:     map[string]string{"a": "1"},
			override: nil,
			want:     map[string]string{"a": "1"},
		},
		{
			name:     "both non-nil with conflict",
			base:     map[string]string{"a": "1", "b": "2"},
			override: map[string]string{"b": "3", "c": "4"},
			want:     map[string]string{"a": "1", "b": "3", "c": "4"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeStringMaps(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("mergeStringMaps() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestMergeRetrySpec(t *testing.T) {
	tests := []struct {
		name     string
		base     *workflows.RetrySpec
		override *workflows.RetrySpec
		want     *workflows.RetrySpec
	}{
		{
			name: "nil base",
			base: nil,
			override: &workflows.RetrySpec{
				MaxAttempts:            3,
				InitialIntervalSeconds: 1,
			},
			want: &workflows.RetrySpec{
				MaxAttempts:            3,
				InitialIntervalSeconds: 1,
			},
		},
		{
			name: "step overrides global",
			base: &workflows.RetrySpec{
				MaxAttempts:            1,
				InitialIntervalSeconds: 2,
				BackoffCoefficient:     1.5,
				MaximumIntervalSeconds: 10,
			},
			override: &workflows.RetrySpec{
				MaxAttempts:            3,
				InitialIntervalSeconds: 5,
				BackoffCoefficient:     2.0,
				MaximumIntervalSeconds: 60,
			},
			want: &workflows.RetrySpec{
				MaxAttempts:            3,
				InitialIntervalSeconds: 5,
				BackoffCoefficient:     2.0,
				MaximumIntervalSeconds: 60,
			},
		},
		{
			name: "nil override fields inherited from base",
			base: &workflows.RetrySpec{
				MaxAttempts:            1,
				InitialIntervalSeconds: 2,
				BackoffCoefficient:     1.5,
				MaximumIntervalSeconds: 10,
			},
			override: &workflows.RetrySpec{},
			want: &workflows.RetrySpec{
				MaxAttempts:            1,
				InitialIntervalSeconds: 2,
				BackoffCoefficient:     1.5,
				MaximumIntervalSeconds: 10,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeRetrySpec(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("mergeRetrySpec() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestMergeDownloadSpec(t *testing.T) {
	tests := []struct {
		name     string
		base     *workflows.DownloadSpec
		override *workflows.DownloadSpec
		want     *workflows.DownloadSpec
	}{
		{
			name: "nil base",
			base: nil,
			override: &workflows.DownloadSpec{
				URL: "http://example.com",
			},
			want: &workflows.DownloadSpec{
				URL: "http://example.com",
			},
		},
		{
			name: "override fields",
			base: &workflows.DownloadSpec{
				URL:    "http://base.com",
				Output: "base.bin",
				Sha256: "base-sha",
			},
			override: &workflows.DownloadSpec{
				URL:    "http://override.com",
				Output: "override.bin",
				Sha256: "override-sha",
			},
			want: &workflows.DownloadSpec{
				URL:    "http://override.com",
				Output: "override.bin",
				Sha256: "override-sha",
			},
		},
		{
			name: "base fields preserved when override empty",
			base: &workflows.DownloadSpec{
				URL:    "http://base.com",
				Output: "base.bin",
				Sha256: "base-sha",
			},
			override: &workflows.DownloadSpec{},
			want: &workflows.DownloadSpec{
				URL:    "http://base.com",
				Output: "base.bin",
				Sha256: "base-sha",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeDownloadSpec(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("mergeDownloadSpec() = %v, want %v", got, tt.want)
			}
		})
	}
}
