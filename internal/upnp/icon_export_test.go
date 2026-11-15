package upnp

import (
	"os"
	"testing"
)

// TestExportIcon writes a preview PNG when ICON_OUT is set.
func TestExportIcon(t *testing.T) {
	out := os.Getenv("ICON_OUT")
	if out == "" {
		t.Skip("set ICON_OUT to export")
	}
	if err := os.WriteFile(out, renderIcon(512), 0o644); err != nil {
		t.Fatal(err)
	}
}
