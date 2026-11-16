//go:build !darwin

package renderer

import "context"

func lookupMAC(context.Context, string) string { return "" }
