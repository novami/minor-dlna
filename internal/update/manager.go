package update

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
)

const (
	checkEvery = 24 * time.Hour
	retryBusy  = 10 * time.Minute
	firstCheck = time.Minute
)

// Manager runs automatic updates and serves the state for the settings page.
type Manager struct {
	Client     *Client
	Current    string
	AppPath    string       // running .app bundle, empty for development builds
	Auto       func() bool  // automatic installs enabled
	Prerelease bool         // include pre-releases
	Busy       func() bool  // a stream is playing: postpone installing
	Installed  func(string) // called with the new executable; the caller restarts into it

	mu        sync.Mutex
	latest    *Release
	lastCheck time.Time
	status    string // idle, checking, installing, error
	errMsg    string
}

type State struct {
	Current     string    `json:"current"`
	Latest      *Release  `json:"latest,omitempty"`
	LastCheck   time.Time `json:"last_check"`
	Status      string    `json:"status"`
	Error       string    `json:"error,omitempty"`
	Installable bool      `json:"installable"`
}

func (m *Manager) State() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	status := m.status
	if status == "" {
		status = "idle"
	}
	return State{Current: m.Current, Latest: m.latest, LastCheck: m.lastCheck, Status: status, Error: m.errMsg,
		Installable: m.AppPath != "" && IsVersion(m.Current)}
}

// Check asks GitHub for a newer release.
func (m *Manager) Check(ctx context.Context) (*Release, error) {
	m.setStatus("checking", "")
	rel, err := m.Client.Latest(ctx, m.Current, m.Prerelease)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.lastCheck = time.Now()
	switch {
	case errors.Is(err, ErrNoUpdate):
		m.latest, m.status, m.errMsg = nil, "idle", ""
		return nil, nil
	case err != nil:
		m.status, m.errMsg = "error", "Kontrola aktualizací selhala: "+err.Error()
		return nil, err
	}
	m.latest, m.status, m.errMsg = rel, "idle", ""
	return rel, nil
}

// Install installs the release found by the last check and hands over to the new version.
func (m *Manager) Install(ctx context.Context) error {
	m.mu.Lock()
	rel := m.latest
	m.mu.Unlock()
	if rel == nil {
		return ErrNoUpdate
	}
	if m.AppPath == "" || !IsVersion(m.Current) {
		return ErrNotInstalled
	}
	m.setStatus("installing", "")
	slog.Info("installing update", "from", m.Current, "to", rel.Version)
	exe, err := m.Client.Install(ctx, rel, m.AppPath)
	if err != nil {
		m.setStatus("error", "Instalace aktualizace selhala: "+err.Error())
		slog.Error("update failed", "err", err)
		return err
	}
	slog.Info("update installed, restarting", "version", rel.Version)
	if m.Installed != nil {
		m.Installed(exe)
	}
	return nil
}

func (m *Manager) setStatus(status, msg string) {
	m.mu.Lock()
	m.status, m.errMsg = status, msg
	m.mu.Unlock()
}

// Run checks daily and installs automatically when enabled and nothing is playing.
func (m *Manager) Run(ctx context.Context) {
	if m.AppPath == "" || !IsVersion(m.Current) {
		return // development build: manual checks only show what is available
	}
	timer := time.NewTimer(firstCheck)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		next := checkEvery
		if m.Auto() {
			if rel, err := m.Check(ctx); err == nil && rel != nil {
				if m.Busy != nil && m.Busy() {
					slog.Info("update postponed, playback in progress", "version", rel.Version)
					next = retryBusy
				} else if err := m.Install(ctx); err == nil {
					return
				}
			}
		}
		timer.Reset(next)
	}
}
