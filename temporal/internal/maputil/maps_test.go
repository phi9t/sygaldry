package maputil

import (
	"testing"
)

func TestMergeStringMaps(t *testing.T) {
	base := map[string]string{"a": "1", "b": "2"}
	override := map[string]string{"b": "overridden", "c": "3"}
	result := MergeStringMaps(base, override)
	if result["a"] != "1" {
		t.Errorf("expected a=1, got %s", result["a"])
	}
	if result["b"] != "overridden" {
		t.Errorf("expected b=overridden, got %s", result["b"])
	}
	if result["c"] != "3" {
		t.Errorf("expected c=3, got %s", result["c"])
	}
	if len(result) != 3 {
		t.Errorf("expected 3 keys, got %d", len(result))
	}
}

func TestMergeStringMapsEmptyBase(t *testing.T) {
	result := MergeStringMaps(nil, map[string]string{"x": "y"})
	if result["x"] != "y" {
		t.Errorf("expected x=y, got %s", result["x"])
	}
}

func TestMergeStringMapsEmptyOverride(t *testing.T) {
	result := MergeStringMaps(map[string]string{"x": "y"}, nil)
	if result["x"] != "y" {
		t.Errorf("expected x=y, got %s", result["x"])
	}
}
