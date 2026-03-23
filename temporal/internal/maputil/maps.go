package maputil

// MergeStringMaps returns a new map containing all keys from base, with keys
// from override taking precedence.
func MergeStringMaps(base, override map[string]string) map[string]string {
	result := make(map[string]string, len(base)+len(override))
	for k, v := range base {
		result[k] = v
	}
	for k, v := range override {
		result[k] = v
	}
	return result
}
