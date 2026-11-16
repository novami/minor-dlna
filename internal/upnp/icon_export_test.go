package upnp

import (
	"os"
	"strconv"
	"testing"
)

// TestExportIcon writes a preview PNG when ICON_OUT is set.
func TestExportIcon(t *testing.T) {
	out := os.Getenv("ICON_OUT")
	if out == "" {
		t.Skip("set ICON_OUT to export")
	}
	size := 512
	if v, err := strconv.Atoi(os.Getenv("ICON_SIZE")); err == nil {
		size = v
	}
	if err := os.WriteFile(out, renderIcon(size), 0o644); err != nil {
		t.Fatal(err)
	}
}
