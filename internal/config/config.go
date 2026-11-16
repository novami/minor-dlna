// Package config loads and persists the server configuration.
package config

import (
	"crypto/rand"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type LibraryType string

const (
	Movies LibraryType = "movies"
	Shows  LibraryType = "shows"
	Videos LibraryType = "videos"
	Photos LibraryType = "photos"
	Music  LibraryType = "music"
)

type Library struct {
	Name  string      `yaml:"name"`
	Type  LibraryType `yaml:"type"`
	Paths []string    `yaml:"paths"`
}

type Config struct {
	Name       string    `yaml:"name"`
	UUID       string    `yaml:"uuid"`
	Port       int       `yaml:"port"`
	Interfaces []string  `yaml:"interfaces"`
	Allow      []string  `yaml:"allow"`
	Libraries  []Library `yaml:"libraries"`
	Transcode  Transcode `yaml:"transcode"`
	Updates    Updates   `yaml:"updates"`

	allow []netip.Prefix
}

type Transcode struct {
	FFmpeg      string `yaml:"ffmpeg"`       // empty = PATH / Homebrew
	HWAccel     string `yaml:"hwaccel"`      // videotoolbox | none
	MaxSessions int    `yaml:"max_sessions"` // concurrent ffmpeg processes
	DTS         *bool  `yaml:"dts"`          // TV decodes DTS (differs by LG model line)
}

type Updates struct {
	Auto    *bool  `yaml:"auto"`    // install new versions automatically (default true)
	Channel string `yaml:"channel"` // stable | prerelease
}

// AutoEnabled defaults to true.
func (u Updates) AutoEnabled() bool { return u.Auto == nil || *u.Auto }

// DTSEnabled defaults to true.
func (t Transcode) DTSEnabled() bool { return t.DTS == nil || *t.DTS }

// DefaultDir returns the per-user data directory.
func DefaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return filepath.Join(home, "Library", "Application Support", "MinorDLNA")
}

func defaults() *Config {
	return &Config{
		Name:      "MinorDLNA",
		Port:      8200,
		Allow:     []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"},
		Transcode: Transcode{HWAccel: "videotoolbox", MaxSessions: 2},
	}
}

// Load reads the config file. A missing file is created with defaults.
// A missing UUID is generated and written back, so the TV sees a stable device.
func Load(path string) (*Config, error) {
	cfg := defaults()
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := yaml.Unmarshal(data, cfg); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	if cfg.UUID == "" || data == nil {
		if cfg.UUID == "" {
			cfg.UUID = newUUID()
		}
		if err := cfg.Save(path); err != nil {
			return nil, err
		}
	}
	return cfg, cfg.validate()
}

func (c *Config) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Validate checks and normalizes the configuration.
func (c *Config) Validate() error { return c.validate() }

func (c *Config) validate() error {
	if c.Port <= 0 || c.Port > 65535 {
		return fmt.Errorf("invalid port %d", c.Port)
	}
	switch c.Transcode.HWAccel {
	case "videotoolbox", "none":
	case "":
		c.Transcode.HWAccel = "videotoolbox"
	default:
		return fmt.Errorf("transcode.hwaccel: unknown value %q (videotoolbox, none)", c.Transcode.HWAccel)
	}
	if c.Transcode.MaxSessions <= 0 {
		c.Transcode.MaxSessions = 2
	}
	c.Transcode.FFmpeg = ExpandHome(c.Transcode.FFmpeg)
	switch c.Updates.Channel {
	case "":
		c.Updates.Channel = "stable"
	case "stable", "prerelease":
	default:
		return fmt.Errorf("updates.channel: unknown value %q (stable, prerelease)", c.Updates.Channel)
	}
	c.allow = c.allow[:0]
	for _, a := range c.Allow {
		p, err := netip.ParsePrefix(a)
		if err != nil {
			return fmt.Errorf("allow %q: %w", a, err)
		}
		c.allow = append(c.allow, p)
	}
	seen := map[string]bool{}
	for i := range c.Libraries {
		l := &c.Libraries[i]
		l.Name = strings.TrimSpace(l.Name)
		if l.Name == "" {
			return fmt.Errorf("library %d: name is empty", i+1)
		}
		if seen[l.Name] {
			return fmt.Errorf("library name %q is used twice", l.Name)
		}
		seen[l.Name] = true
		if len(l.Paths) == 0 {
			return fmt.Errorf("library %q: no folder", l.Name)
		}
		switch l.Type {
		case Movies, Shows, Videos, Photos, Music:
		default:
			return fmt.Errorf("library %q: unknown type %q", l.Name, l.Type)
		}
		for j, p := range l.Paths {
			l.Paths[j] = ExpandHome(p)
		}
	}
	return nil
}

// Allowed reports whether a client address may access the server. Empty allow list permits all.
func (c *Config) Allowed(addr netip.Addr) bool {
	if len(c.allow) == 0 {
		return true
	}
	addr = addr.Unmap()
	for _, p := range c.allow {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

func ExpandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
	}
	return p
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
