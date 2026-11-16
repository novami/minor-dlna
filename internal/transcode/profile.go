// Package transcode decides how a client can play a file and streams converted media through ffmpeg.
package transcode

import (
	"slices"
	"strings"
	"sync"
	"time"
)

// Profile describes what a client plays natively. A nil set means "anything".
type Profile struct {
	Name        string
	Containers  set
	VideoCodecs set
	AudioCodecs set
	// Video10Bit reports support for 10-bit H.264 (HEVC/VP9/AV1 10-bit are covered by the codec itself).
	Video10BitH264 bool
}

type set map[string]bool

func newSet(items ...string) set {
	s := set{}
	for _, i := range items {
		s[i] = true
	}
	return s
}

func (s set) has(v string) bool { return s == nil || s[v] }

func (s set) with(items ...string) set {
	out := clone(s)
	for _, i := range items {
		out[i] = true
	}
	return out
}

func clone(s set) set {
	out := set{}
	for k := range s {
		out[k] = true
	}
	return out
}

// Generic plays everything as-is; desktop players handle almost any format.
var Generic = Profile{Name: "generic"}

// Codec sets shared by TV profiles (ffprobe names; containers are the first component, see normalizeContainer).
var (
	pcm        = []string{"pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_u8"}
	baseAudio  = newSet("aac", "ac3", "eac3", "mp3", "mp2", "flac").with(pcm...)
	baseVideo  = newSet("h264", "hevc", "mpeg2video", "mpeg4")
	baseFormat = newSet("matroska", "mov", "mpegts", "avi", "mpeg", "flac", "mp3", "wav", "aac")
)

// brand is a TV family with its formats and the markers that identify it in a User-Agent or device description.
type brand struct {
	id, label string
	markers   []string
	formats   set
	video     set
	audio     set
}

// Brands in detection order: Roku first (Roku TVs carry another maker's name too), then specific makers,
// then platforms used by many makers.
var brands = []brand{
	{"roku", "Roku TV (TCL, Hisense…)", []string{"roku"},
		newSet("matroska", "mov", "mpegts", "flac", "mp3", "wav", "aac"), newSet("h264", "hevc", "vp9", "mpeg2video"), baseAudio},
	{"lg", "LG (webOS)", []string{"lge", "webos", "lg-", "lg ", "lg electronics"},
		baseFormat.with("ogg"), baseVideo.with("vp9", "av1", "vc1"), baseAudio.with("vorbis", "opus")},
	{"samsung", "Samsung (Tizen)", []string{"samsung", "sec_hhp", "tizen"},
		baseFormat.with("ogg", "asf"), baseVideo.with("vp9", "av1", "vc1", "wmv3"), baseAudio.with("vorbis", "opus", "wmav2")},
	{"sony", "Sony Bravia", []string{"bravia", "sony"},
		baseFormat.with("ogg"), baseVideo.with("vp9"), baseAudio.with("vorbis", "opus")},
	{"panasonic", "Panasonic Viera", []string{"panasonic", "viera"},
		baseFormat, baseVideo.with("vp9"), baseAudio},
	{"hisense", "Hisense (VIDAA)", []string{"hisense", "vidaa"},
		baseFormat, baseVideo.with("vp9"), baseAudio},
	// Android/Google TV: Sony, TCL, Philips, Xiaomi, Nvidia Shield… AVI and MPEG-4 Part 2 vary by player app.
	{"android", "Android TV / Google TV (TCL, Philips, Xiaomi…)", []string{"android", "google", "tcl", "philips", "xiaomi", "mibox", "shield", "chromecast", "exoplayer", "dalvik"},
		newSet("matroska", "mov", "mpegts", "mpeg", "flac", "mp3", "wav", "ogg", "aac"), newSet("h264", "hevc", "vp9", "mpeg2video"), baseAudio.with("vorbis", "opus")},
	// Other TVs (Toshiba, Grundig, Sharp, Metz, Vestel…): conservative formats every recent TV plays.
	{"tv", "Jiná televize (bezpečné formáty)", []string{"toshiba", "grundig", "sharp", "metz", "vestel", "jvc", "telefunken", "thomson", "finlux", "loewe", "dlnadoc"},
		newSet("matroska", "mov", "mpegts", "mpeg", "mp3", "flac", "wav", "aac"), newSet("h264", "hevc", "mpeg2video"), newSet("aac", "ac3", "eac3", "mp3", "mp2", "flac").with(pcm...)},
}

// ProfileOption is a selectable profile for the settings page.
type ProfileOption struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// Options lists the profiles a user can assign to a device.
func Options() []ProfileOption {
	var out []ProfileOption
	for _, id := range []string{"lg", "samsung", "sony", "panasonic", "hisense", "android", "roku", "tv"} {
		for _, b := range brands {
			if b.id == id {
				out = append(out, ProfileOption{b.id, b.label})
			}
		}
	}
	return append(out, ProfileOption{Generic.Name, "Počítač / přehrávač (vše bez převodu)"})
}

// ByName returns a profile by its id. dts adds DTS audio for TVs that decode it (differs by model line).
func ByName(id string, dts bool) (Profile, bool) {
	if id == Generic.Name {
		return Generic, true
	}
	for _, b := range brands {
		if b.id == id {
			audio := clone(b.audio)
			if dts {
				audio["dts"] = true
			}
			return Profile{Name: b.id, Containers: b.formats, VideoCodecs: b.video, AudioCodecs: audio}, true
		}
	}
	return Profile{}, false
}

// LGWebOS22 is LG webOS 22+ (2022 and newer TVs).
func LGWebOS22(dts bool) Profile {
	p, _ := ByName("lg", dts)
	return p
}

// DetectID picks a profile id from identification text: User-Agent, X-AV-Client-Info, renderer manufacturer and model.
func DetectID(ident string) string {
	s := strings.ToLower(ident)
	for _, b := range brands {
		for _, m := range b.markers {
			if strings.Contains(s, m) {
				return b.id
			}
		}
	}
	return Generic.Name
}

// Detect picks a profile from identification text (see DetectID).
func Detect(ident string, dts bool) Profile {
	p, _ := ByName(DetectID(ident), dts)
	return p
}

// normalizeContainer maps ffprobe format_name lists ("mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm") to one key.
func normalizeContainer(formatName string) string {
	first, _, _ := strings.Cut(formatName, ",")
	return first
}

// Client is a device that browsed the server or was found as a renderer, keyed by IP.
type Client struct {
	IP       string    `json:"ip"`
	Name     string    `json:"name"`
	Ident    string    `json:"ident"`
	Detected string    `json:"detected"`
	Profile  string    `json:"profile"` // manual choice, "" = automatic
	Seen     time.Time `json:"seen"`
}

// Resolver picks the profile for each client: a manual choice by IP, otherwise detection from
// everything known about that IP (the User-Agent of a TV's browser often names no brand, but its
// renderer description does).
type Resolver struct {
	DTS bool

	mu        sync.Mutex
	overrides map[string]string
	clients   map[string]*Client
}

func NewResolver(dts bool, overrides map[string]string) *Resolver {
	r := &Resolver{DTS: dts, overrides: map[string]string{}, clients: map[string]*Client{}}
	for ip, id := range overrides {
		if _, ok := ByName(id, false); ok {
			r.overrides[ip] = id
		}
	}
	return r
}

// Observe records identification text and a display name for ip.
func (r *Resolver) Observe(ip, name, ident string) {
	if r == nil || ip == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.clients[ip]
	if c == nil {
		if len(r.clients) >= 200 { // bounded: drop the oldest
			var oldest *Client
			for _, o := range r.clients {
				if oldest == nil || o.Seen.Before(oldest.Seen) {
					oldest = o
				}
			}
			delete(r.clients, oldest.IP)
		}
		c = &Client{IP: ip}
		r.clients[ip] = c
	}
	c.Seen = time.Now()
	if name != "" {
		c.Name = name
	}
	if ident = strings.TrimSpace(ident); ident != "" && !strings.Contains(c.Ident, ident) && len(c.Ident) < 1024 {
		c.Ident = strings.TrimSpace(c.Ident + " | " + ident)
		c.Ident = strings.TrimPrefix(c.Ident, "| ")
	}
}

// For records ident for ip and returns the profile to use.
func (r *Resolver) For(ip, ident string) Profile {
	if r == nil {
		return Detect(ident, false)
	}
	r.Observe(ip, "", ident)
	r.mu.Lock()
	id, ok := r.overrides[ip]
	if !ok {
		all := ident
		if c := r.clients[ip]; c != nil {
			all = c.Ident + " " + c.Name
		}
		id = DetectID(all)
	}
	r.mu.Unlock()
	p, _ := ByName(id, r.DTS)
	return p
}

// Set assigns a profile to ip; "" returns it to automatic detection.
func (r *Resolver) Set(ip, id string) bool {
	if id != "" {
		if _, ok := ByName(id, false); !ok {
			return false
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if id == "" {
		delete(r.overrides, ip)
	} else {
		r.overrides[ip] = id
	}
	return true
}

// Overrides returns a copy of the manual choices (for saving).
func (r *Resolver) Overrides() map[string]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]string, len(r.overrides))
	for k, v := range r.overrides {
		out[k] = v
	}
	return out
}

// Clients lists known devices, including manual choices for devices not seen since start.
func (r *Resolver) Clients() []Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []Client
	for ip, c := range r.clients {
		cc := *c
		cc.Detected = DetectID(c.Ident + " " + c.Name)
		cc.Profile = r.overrides[ip]
		out = append(out, cc)
	}
	for ip, id := range r.overrides {
		if r.clients[ip] == nil {
			out = append(out, Client{IP: ip, Profile: id, Detected: Generic.Name})
		}
	}
	slices.SortFunc(out, func(a, b Client) int { return strings.Compare(a.IP, b.IP) })
	return out
}
