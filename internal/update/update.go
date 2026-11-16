// Package update installs new versions of the app from GitHub Releases.
//
// A release carries MinorDLNA-<version>-macos.zip, checksums.txt and checksums.txt.sig.
// The signature (Ed25519, key embedded below) covers checksums.txt, which covers the zip,
// so a tampered release or a compromised download is rejected before anything is replaced.
package update

import (
	"archive/zip"
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// PublicKey verifies release signatures. The private key lives only in the release pipeline's secrets.
const PublicKey = "Hz0MB/1WowAdMO3+gb14qztCqTHYy0KKzeKVrC5RuGE="

const (
	repo        = "novami/minor-dlna"
	maxDownload = 300 << 20
)

var (
	ErrNoUpdate     = errors.New("no update available")
	ErrNotInstalled = errors.New("updates work only for the installed app")
)

type Release struct {
	Version   string    `json:"version"`
	Notes     string    `json:"notes"`
	URL       string    `json:"url"`
	Published time.Time `json:"published"`

	zipURL, sumsURL, sigURL, zipName string
}

type Client struct {
	HTTP      *http.Client
	API       string // GitHub API base, overridable in tests
	PublicKey string
}

func NewClient() *Client {
	return &Client{HTTP: &http.Client{Timeout: 10 * time.Minute}, API: "https://api.github.com", PublicKey: PublicKey}
}

type ghRelease struct {
	TagName     string    `json:"tag_name"`
	Body        string    `json:"body"`
	HTMLURL     string    `json:"html_url"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt time.Time `json:"published_at"`
	Assets      []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

// Latest returns the newest release above current, or ErrNoUpdate.
func (c *Client) Latest(ctx context.Context, current string, prerelease bool) (*Release, error) {
	var releases []ghRelease
	if err := c.getJSON(ctx, c.API+"/repos/"+repo+"/releases?per_page=20", &releases); err != nil {
		return nil, err
	}
	var best *Release
	for _, r := range releases {
		if r.Draft || (r.Prerelease && !prerelease) || !IsVersion(r.TagName) {
			continue
		}
		if best != nil && Compare(r.TagName, best.Version) <= 0 {
			continue
		}
		rel := &Release{Version: r.TagName, Notes: r.Body, URL: r.HTMLURL, Published: r.PublishedAt}
		for _, a := range r.Assets {
			switch {
			case a.Name == "checksums.txt":
				rel.sumsURL = a.URL
			case a.Name == "checksums.txt.sig":
				rel.sigURL = a.URL
			case strings.HasSuffix(a.Name, "-macos.zip"):
				rel.zipURL, rel.zipName = a.URL, a.Name
			}
		}
		if rel.zipURL != "" && rel.sumsURL != "" && rel.sigURL != "" {
			best = rel
		}
	}
	base, ok := Base(current)
	if best == nil || !ok || Compare(best.Version, base) <= 0 {
		return nil, ErrNoUpdate
	}
	return best, nil
}

// Install downloads, verifies and unpacks the release next to the running app bundle,
// swaps the bundles and returns the path of the new executable. The old bundle is kept as <app>.prev.
func (c *Client) Install(ctx context.Context, rel *Release, appPath string) (string, error) {
	if appPath == "" {
		return "", ErrNotInstalled
	}
	parent := filepath.Dir(appPath)
	work, err := os.MkdirTemp(parent, ".minordlna-update-")
	if err != nil {
		return "", fmt.Errorf("no write access to %s: %w", parent, err)
	}
	defer os.RemoveAll(work)

	sums, err := c.download(ctx, rel.sumsURL, 1<<20)
	if err != nil {
		return "", err
	}
	sig, err := c.download(ctx, rel.sigURL, 4<<10)
	if err != nil {
		return "", err
	}
	if err := Verify(c.PublicKey, sums, sig); err != nil {
		return "", err
	}
	want, ok := checksumFor(sums, rel.zipName)
	if !ok {
		return "", fmt.Errorf("checksums.txt has no entry for %s", rel.zipName)
	}
	zipPath := filepath.Join(work, "app.zip")
	if err := c.downloadFile(ctx, rel.zipURL, zipPath, want); err != nil {
		return "", err
	}
	unpacked := filepath.Join(work, "unpacked")
	if err := unzip(zipPath, unpacked); err != nil {
		return "", err
	}
	newApp := filepath.Join(unpacked, "MinorDLNA.app")
	exe := filepath.Join(newApp, "Contents", "MacOS", "minordlna")
	// The new binary must at least start and report the expected version before we swap.
	vctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(vctx, exe, "-version").Output()
	if err != nil || strings.TrimSpace(string(out)) != rel.Version {
		return "", fmt.Errorf("downloaded app failed its self-check (%q): %v", strings.TrimSpace(string(out)), err)
	}

	prev := appPath + ".prev"
	_ = os.RemoveAll(prev)
	if err := os.Rename(appPath, prev); err != nil {
		return "", fmt.Errorf("cannot move current app: %w", err)
	}
	if err := os.Rename(newApp, appPath); err != nil {
		_ = os.Rename(prev, appPath)
		return "", fmt.Errorf("cannot install new app: %w", err)
	}
	return filepath.Join(appPath, "Contents", "MacOS", "minordlna"), nil
}

// Rollback restores <app>.prev, used when the new version fails to start.
func Rollback(appPath string) (string, error) {
	prev := appPath + ".prev"
	if _, err := os.Stat(prev); err != nil {
		return "", err
	}
	broken := appPath + ".failed"
	_ = os.RemoveAll(broken)
	if err := os.Rename(appPath, broken); err != nil {
		return "", err
	}
	if err := os.Rename(prev, appPath); err != nil {
		return "", err
	}
	return filepath.Join(appPath, "Contents", "MacOS", "minordlna"), nil
}

// Cleanup removes the previous bundle after the new version started fine.
func Cleanup(appPath string) {
	_ = os.RemoveAll(appPath + ".prev")
	_ = os.RemoveAll(appPath + ".failed")
}

// Verify checks a base64 Ed25519 signature of data.
func Verify(publicKey string, data, sigB64 []byte) error {
	pub, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return errors.New("invalid public key")
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sigB64)))
	if err != nil || !ed25519.Verify(pub, data, sig) {
		return errors.New("release signature is invalid")
	}
	return nil
}

// checksumFor finds "<sha256>  <name>" (shasum format) in checksums.txt.
func checksumFor(sums []byte, name string) (string, bool) {
	sc := bufio.NewScanner(strings.NewReader(string(sums)))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name && len(f[0]) == 64 {
			return strings.ToLower(f[0]), true
		}
	}
	return "", false
}

func (c *Client) getJSON(ctx context.Context, url string, v any) error {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "MinorDLNA-updater")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub responded %s", resp.Status)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(v)
}

func (c *Client) open(ctx context.Context, url string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "MinorDLNA-updater")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("download failed: %s", resp.Status)
	}
	return resp, nil
}

func (c *Client) download(ctx context.Context, url string, limit int64) ([]byte, error) {
	resp, err := c.open(ctx, url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

func (c *Client) downloadFile(ctx context.Context, url, dst, wantSHA string) error {
	resp, err := c.open(ctx, url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, maxDownload+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if n > maxDownload {
		return errors.New("download is too large")
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != wantSHA {
		return errors.New("checksum of the download does not match")
	}
	return nil
}

// unzip extracts only MinorDLNA.app/..., rejecting paths that escape the target (zip slip) and symlinks.
func unzip(src, dst string) error {
	r, err := zip.OpenReader(src)
	if err != nil {
		return err
	}
	defer r.Close()
	for _, f := range r.File {
		name := filepath.Clean(f.Name)
		// AppleDouble metadata files would break the bundle's code signature.
		if strings.HasPrefix(filepath.Base(name), "._") {
			continue
		}
		if !filepath.IsLocal(name) || !(name == "MinorDLNA.app" || strings.HasPrefix(name, "MinorDLNA.app"+string(filepath.Separator))) {
			if strings.HasPrefix(name, "__MACOSX") {
				continue
			}
			return fmt.Errorf("unexpected file in archive: %s", f.Name)
		}
		target := filepath.Join(dst, name)
		mode := f.Mode()
		switch {
		case mode.IsDir():
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		case mode&os.ModeSymlink != 0:
			return fmt.Errorf("symlinks are not allowed: %s", f.Name)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := extract(f, target, mode.Perm()|0o600); err != nil {
			return err
		}
	}
	if _, err := os.Stat(filepath.Join(dst, "MinorDLNA.app", "Contents", "MacOS", "minordlna")); err != nil {
		return errors.New("archive does not contain the app")
	}
	return nil
}

func extract(f *zip.File, target string, perm os.FileMode) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, io.LimitReader(rc, maxDownload)); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// Base returns the release a build comes from: "v0.1.1-9-g22cac2e-dirty" from git describe is a
// local build on top of v0.1.1, so any release newer than v0.1.1 replaces it.
func Base(s string) (string, bool) {
	if m := reDescribe.FindStringSubmatch(s); m != nil {
		s = m[1]
	}
	return s, IsVersion(s)
}

var reDescribe = regexp.MustCompile(`^(v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)(?:\.\d+)?)?)(?:-\d+-g[0-9a-f]+)?(?:-dirty)?$`)

// IsVersion reports whether s looks like v1.2.3 or v1.2.3-rc.1.
func IsVersion(s string) bool {
	_, ok := parse(s)
	return ok
}

// Compare orders versions; a pre-release sorts before its release.
func Compare(a, b string) int {
	va, _ := parse(a)
	vb, _ := parse(b)
	for i := range 3 {
		if va.n[i] != vb.n[i] {
			if va.n[i] < vb.n[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case va.pre == vb.pre:
		return 0
	case va.pre == "":
		return 1
	case vb.pre == "":
		return -1
	}
	return strings.Compare(va.pre, vb.pre)
}

type semver struct {
	n   [3]int
	pre string
}

func parse(s string) (semver, bool) {
	var v semver
	s, ok := strings.CutPrefix(s, "v")
	if !ok {
		return v, false
	}
	core, pre, _ := strings.Cut(s, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return v, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return v, false
		}
		v.n[i] = n
	}
	// Only release pre-tags count; "v0.1.0-3-gabc123-dirty" from git describe is a local build.
	if pre != "" && !rePre.MatchString(pre) {
		return v, false
	}
	v.pre = pre
	return v, true
}

var rePre = regexp.MustCompile(`^(alpha|beta|rc)(\.\d+)?$`)
