// Package macos wraps the few system integrations the app needs, mostly through built-in command-line tools.
package macos

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const agentLabel = "cz.minordlna"

// ErrCancelled is returned when the user closes the folder dialog.
var ErrCancelled = errors.New("cancelled")

// OpenURL opens a URL in the default browser.
func OpenURL(url string) error { return exec.Command("/usr/bin/open", url).Run() }

// ComputerName returns the user-visible name of the Mac.
func ComputerName() string {
	out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output()
	if err != nil {
		h, _ := os.Hostname()
		return strings.TrimSuffix(h, ".local")
	}
	return strings.TrimSpace(string(out))
}

// AppBundle returns the .app path if the executable runs from one.
func AppBundle() (string, bool) {
	exe, err := os.Executable()
	if err != nil {
		return "", false
	}
	if i := strings.Index(exe, ".app/Contents/MacOS/"); i >= 0 {
		return exe[:i+4], true
	}
	return "", false
}

func agentPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", agentLabel+".plist")
}

// AutostartEnabled reports whether the login item is installed.
func AutostartEnabled() bool {
	_, err := os.Stat(agentPath())
	return err == nil
}

// SetAutostart installs or removes a LaunchAgent that starts the server at login.
// A normal quit stays quit; only a crash is restarted.
func SetAutostart(enabled bool) error {
	path := agentPath()
	if !enabled {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return err
	}
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%s</string>
	<key>ProgramArguments</key>
	<array><string>%s</string><string>-background</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
`, agentLabel, xmlEscape(exe))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(plist), 0o644)
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// LogDir returns ~/Library/Logs/MinorDLNA.
func LogDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Logs", "MinorDLNA")
}
