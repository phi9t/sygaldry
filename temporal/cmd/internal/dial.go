package cmdinternal

import (
	"fmt"

	"go.temporal.io/sdk/client"
)

// DialClient creates a Temporal client and wraps any error with context.
func DialClient(hostPort, namespace string) (client.Client, error) {
	c, err := client.Dial(client.Options{HostPort: hostPort, Namespace: namespace})
	if err != nil {
		return nil, fmt.Errorf("unable to connect to Temporal at %s: %w", hostPort, err)
	}
	return c, nil
}
