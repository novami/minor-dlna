// Package version holds build information injected via -ldflags.
package version

// Version is set at build time: -ldflags "-X github.com/novami/minor-dlna/internal/version.Version=v1.2.3".
var Version = "dev"
