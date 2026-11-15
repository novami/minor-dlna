// Package library exposes configured folders as a browsable object tree.
//
// Object IDs are opaque to clients and never contain absolute paths:
//
//	"0"              root
//	"L<i>"           library i (for a single-path library also its folder root)
//	"L<i>.<p>:<b64>" entry at relative path <b64> (base64url) under path p of library i
package library

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/dlna"
)

const RootID = "0"

var ErrNotFound = errors.New("no such object")

type Object struct {
	ID         string
	ParentID   string
	Title      string
	IsDir      bool
	ChildCount int // -1 = unknown
	Path       string
	Size       int64
	ModTime    time.Time
	Format     dlna.Format
	MediaPath  string // URL path of the media resource, files only
}

type Tree struct {
	libs []config.Library
}

func New(libs []config.Library) *Tree { return &Tree{libs: libs} }

type ref struct {
	lib  int
	path int // -1 = virtual library container with several paths
	rel  string
}

var enc = base64.RawURLEncoding

func (t *Tree) id(r ref) string {
	if r.rel == "" {
		if r.path < 0 || len(t.libs[r.lib].Paths) == 1 {
			return "L" + strconv.Itoa(r.lib)
		}
		return fmt.Sprintf("L%d.%d:", r.lib, r.path)
	}
	return fmt.Sprintf("L%d.%d:%s", r.lib, r.path, enc.EncodeToString([]byte(r.rel)))
}

func (t *Tree) parse(id string) (ref, error) {
	if !strings.HasPrefix(id, "L") {
		return ref{}, ErrNotFound
	}
	head, b64, hasRel := strings.Cut(id[1:], ":")
	libStr, pathStr, hasPath := strings.Cut(head, ".")
	lib, err := strconv.Atoi(libStr)
	if err != nil || lib < 0 || lib >= len(t.libs) {
		return ref{}, ErrNotFound
	}
	r := ref{lib: lib, path: -1}
	if !hasPath {
		if hasRel {
			return ref{}, ErrNotFound
		}
		if len(t.libs[lib].Paths) == 1 {
			r.path = 0
		}
		return r, nil
	}
	p, err := strconv.Atoi(pathStr)
	if err != nil || p < 0 || p >= len(t.libs[lib].Paths) {
		return ref{}, ErrNotFound
	}
	r.path = p
	raw, err := enc.DecodeString(b64)
	if err != nil {
		return ref{}, ErrNotFound
	}
	r.rel = string(raw)
	if r.rel != "" {
		// Reject traversal outside the library folder.
		if !filepath.IsLocal(r.rel) || filepath.Clean(r.rel) != r.rel {
			return ref{}, ErrNotFound
		}
	}
	return r, nil
}

func (t *Tree) abs(r ref) string {
	return filepath.Join(t.libs[r.lib].Paths[r.path], r.rel)
}

func (t *Tree) parentID(r ref) string {
	if r.path < 0 || (r.rel == "" && len(t.libs[r.lib].Paths) == 1) {
		return RootID
	}
	if r.rel == "" {
		return t.id(ref{lib: r.lib, path: -1})
	}
	dir := filepath.Dir(r.rel)
	if dir == "." {
		dir = ""
	}
	return t.id(ref{lib: r.lib, path: r.path, rel: dir})
}

// Metadata returns a single object.
func (t *Tree) Metadata(id string) (Object, error) {
	if id == RootID {
		return Object{ID: RootID, ParentID: "-1", Title: "MinorDLNA", IsDir: true, ChildCount: len(t.libs)}, nil
	}
	r, err := t.parse(id)
	if err != nil {
		return Object{}, err
	}
	if r.path < 0 {
		l := t.libs[r.lib]
		return Object{ID: t.id(r), ParentID: RootID, Title: l.Name, IsDir: true, ChildCount: len(l.Paths)}, nil
	}
	fi, err := os.Stat(t.abs(r))
	if err != nil {
		return Object{}, ErrNotFound
	}
	o, ok := t.object(r, fi)
	if !ok {
		return Object{}, ErrNotFound
	}
	if o.IsDir {
		if kids, err := t.children(r); err == nil {
			o.ChildCount = len(kids)
		}
	}
	return o, nil
}

// Children returns the direct children of a container.
func (t *Tree) Children(id string) ([]Object, error) {
	if id == RootID {
		out := make([]Object, 0, len(t.libs))
		for i, l := range t.libs {
			out = append(out, Object{ID: t.id(ref{lib: i, path: -1}), ParentID: RootID, Title: l.Name, IsDir: true, ChildCount: -1})
		}
		return out, nil
	}
	r, err := t.parse(id)
	if err != nil {
		return nil, err
	}
	if r.path < 0 {
		out := make([]Object, 0, len(t.libs[r.lib].Paths))
		for p, dir := range t.libs[r.lib].Paths {
			c := ref{lib: r.lib, path: p}
			out = append(out, Object{ID: t.id(c), ParentID: id, Title: filepath.Base(dir), IsDir: true, ChildCount: -1})
		}
		return out, nil
	}
	return t.children(r)
}

func (t *Tree) children(r ref) ([]Object, error) {
	entries, err := os.ReadDir(t.abs(r))
	if err != nil {
		return nil, ErrNotFound
	}
	out := make([]Object, 0, len(entries))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		// Follow symlinks so linked folders and files work.
		if fi.Mode()&os.ModeSymlink != 0 {
			if fi, err = os.Stat(filepath.Join(t.abs(r), e.Name())); err != nil {
				continue
			}
		}
		c := ref{lib: r.lib, path: r.path, rel: filepath.Join(r.rel, e.Name())}
		if o, ok := t.object(c, fi); ok {
			o.ChildCount = -1
			out = append(out, o)
		}
	}
	slices.SortFunc(out, func(a, b Object) int {
		if a.IsDir != b.IsDir {
			if a.IsDir {
				return -1
			}
			return 1
		}
		return NaturalCompare(a.Title, b.Title)
	})
	return out, nil
}

// object builds an Object, returning false for files the library does not show.
func (t *Tree) object(r ref, fi os.FileInfo) (Object, bool) {
	title := fi.Name()
	if r.rel == "" {
		title = t.libs[r.lib].Name
	}
	o := Object{ID: t.id(r), ParentID: t.parentID(r), Title: title, Path: t.abs(r), ModTime: fi.ModTime()}
	if fi.IsDir() {
		o.IsDir = true
		return o, true
	}
	f, ok := dlna.Lookup(fi.Name())
	if !ok || f.Kind != kindFor(t.libs[r.lib].Type) {
		return Object{}, false
	}
	o.Title = strings.TrimSuffix(fi.Name(), filepath.Ext(fi.Name()))
	o.Size = fi.Size()
	o.Format = f
	o.MediaPath = fmt.Sprintf("/media/L%d.%d/%s%s", r.lib, r.path, enc.EncodeToString([]byte(r.rel)), strings.ToLower(filepath.Ext(fi.Name())))
	return o, true
}

// ResolveMedia maps a media URL path (without the /media/ prefix) back to a file.
func (t *Tree) ResolveMedia(p string) (Object, error) {
	head, file, ok := strings.Cut(p, "/")
	if !ok {
		return Object{}, ErrNotFound
	}
	b64 := strings.TrimSuffix(file, filepath.Ext(file))
	o, err := t.Metadata(head + ":" + b64)
	if err != nil || o.IsDir {
		return Object{}, ErrNotFound
	}
	return o, nil
}

func kindFor(lt config.LibraryType) dlna.Kind {
	switch lt {
	case config.Photos:
		return dlna.Image
	case config.Music:
		return dlna.Audio
	default:
		return dlna.Video
	}
}

// NaturalCompare orders strings case-insensitively with numbers compared by value ("Ep 2" < "Ep 10").
func NaturalCompare(a, b string) int {
	a, b = strings.ToLower(a), strings.ToLower(b)
	for a != "" && b != "" {
		da, db := digitPrefix(a), digitPrefix(b)
		if da != "" && db != "" {
			na, nb := strings.TrimLeft(da, "0"), strings.TrimLeft(db, "0")
			if c := len(na) - len(nb); c != 0 {
				return c
			}
			if c := strings.Compare(na, nb); c != 0 {
				return c
			}
			a, b = a[len(da):], b[len(db):]
			continue
		}
		if a[0] != b[0] {
			return int(a[0]) - int(b[0])
		}
		a, b = a[1:], b[1:]
	}
	return len(a) - len(b)
}

func digitPrefix(s string) string {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return s[:i]
}
