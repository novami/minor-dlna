package icon

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
	render := App
	if os.Getenv("ICON_TEMPLATE") != "" {
		render = Template
	}
	if err := os.WriteFile(out, render(size), 0o644); err != nil {
		t.Fatal(err)
	}
}
