package renderer

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/ssdp"
	"github.com/novami/minor-dlna/internal/transcode"
	"github.com/novami/minor-dlna/internal/upnp"
)

var pollEvery = 2 * time.Second // shortened by tests

const (
	saveEvery   = 10 * time.Second
	resumeLead  = 5 * time.Second  // resume a little before the saved position
	wakeTimeout = 60 * time.Second // TV boot until its renderer answers
	maxFailures = 5                // missed polls before the TV counts as off
	endSlack    = 15 * time.Second // this close to the end counts as played through (next episode follows)
)

// Status is what the remote control in the web UI shows.
type Status struct {
	UDN        string `json:"udn"`
	TV         string `json:"tv"`
	ItemID     string `json:"id"`
	Title      string `json:"title"`
	State      string `json:"state"` // STARTING, WAKING, PLAYING, PAUSED_PLAYBACK, TRANSITIONING, STOPPED
	PositionMs int64  `json:"position_ms"`
	DurationMs int64  `json:"duration_ms"`
	Volume     int    `json:"volume"`
	Muted      bool   `json:"muted"`
	CanVolume  bool   `json:"can_volume"`
	Error      string `json:"error,omitempty"`
}

type session struct {
	dev     Device
	item    library.Object
	uri     string
	resume  int64 // position to seek to once playing, 0 = none
	started bool  // the TV reported PLAYING for this item
	saved   time.Time
	cancel  context.CancelFunc
	st      Status
}

// Controller plays library items on one TV at a time and records how far they were watched.
type Controller struct {
	DB         *sql.DB
	Cat        *library.Catalog
	Port       int
	Interfaces []string
	Profiles   *transcode.Resolver
	Transcode  bool
	OnProgress func() // an item finished or stopped with new progress (the TV's library view shows it)

	mu        sync.Mutex
	ctx       context.Context
	online    map[string]Device
	sess      *session
	last      *Status // final state of the ended session, shown for a while so the UI can report it
	lastAt    time.Time
	searching chan struct{}  // closed when the running search ends
	wg        sync.WaitGroup // session goroutines, finished before the database closes
}

// Run searches the network once at start and keeps the controller usable until ctx ends.
func (c *Controller) Run(ctx context.Context) {
	c.mu.Lock()
	c.ctx = ctx
	c.mu.Unlock()
	_, _ = c.Search(ctx)
	<-ctx.Done()
	c.mu.Lock()
	if s := c.sess; s != nil {
		s.cancel()
	}
	c.mu.Unlock()
	c.wg.Wait()
}

// Devices lists every TV seen so far; Online marks those that answered the last search.
func (c *Controller) Devices(ctx context.Context) ([]Device, error) {
	rows, err := c.DB.QueryContext(ctx, `SELECT udn, name, location, ip, mac FROM renderer ORDER BY seen_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	c.mu.Lock()
	online := make(map[string]bool, len(c.online))
	for k := range c.online {
		online[k] = true
	}
	c.mu.Unlock()
	var out []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.UDN, &d.Name, &d.Location, &d.IP, &d.MAC); err != nil {
			return nil, err
		}
		d.Online = online[d.UDN]
		out = append(out, d)
	}
	return out, rows.Err()
}

// Search looks for TVs and remembers them, with their MAC address for waking them later.
func (c *Controller) Search(ctx context.Context) ([]Device, error) {
	c.mu.Lock()
	if wait := c.searching; wait != nil {
		c.mu.Unlock()
		select {
		case <-wait:
		case <-ctx.Done():
		}
		return c.Devices(ctx)
	}
	done := make(chan struct{})
	c.searching = done
	c.mu.Unlock()
	defer func() { c.mu.Lock(); c.searching = nil; c.mu.Unlock(); close(done) }()

	found, err := Search(ctx, c.Interfaces, 3*time.Second)
	if err != nil {
		return nil, err
	}
	online := map[string]Device{}
	for _, d := range found {
		d.MAC = lookupMAC(ctx, d.IP)
		online[d.UDN] = d
		c.Profiles.ObserveDevice(d.IP, d.Name, d.Manufacturer, d.Model)
		_, err := c.DB.ExecContext(ctx, `INSERT INTO renderer (udn, name, location, ip, mac, seen_at) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT (udn) DO UPDATE SET name = excluded.name, location = excluded.location, ip = excluded.ip,
				mac = CASE WHEN excluded.mac = '' THEN renderer.mac ELSE excluded.mac END, seen_at = excluded.seen_at`,
			d.UDN, d.Name, d.Location, d.IP, d.MAC, time.Now().Unix())
		if err != nil {
			return nil, err
		}
	}
	c.mu.Lock()
	c.online = online
	c.mu.Unlock()
	slog.Info("renderers found", "count", len(found))
	return c.Devices(ctx)
}

func (c *Controller) known(ctx context.Context, udn string) (Device, bool) {
	devs, err := c.Devices(ctx)
	if err != nil {
		return Device{}, false
	}
	for _, d := range devs {
		if d.UDN == udn {
			return d, true
		}
	}
	return Device{}, false
}

// Wake turns the TV on over the network.
func (c *Controller) Wake(ctx context.Context, udn string) error {
	d, ok := c.known(ctx, udn)
	if !ok {
		return errors.New("Neznámá televize.")
	}
	if d.MAC == "" {
		return errors.New("MAC adresa televize není známá – zapněte ji jednou ručně, server si ji zapamatuje.")
	}
	return Wake(d.MAC, ssdp.LANInterfaces(c.Interfaces))
}

// Status returns the current session, or the final state of one that just ended.
func (c *Controller) Status() *Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sess != nil {
		st := c.sess.st
		return &st
	}
	if c.last != nil && time.Since(c.lastAt) < 15*time.Second {
		st := *c.last
		return &st
	}
	return nil
}

// Play starts item id on the TV, from fromMs (minus a few seconds) when it is positive.
// It returns at once; waking the TV and loading show up in Status.
func (c *Controller) Play(udn, id string, fromMs int64) error {
	c.mu.Lock()
	ctx := c.ctx
	c.mu.Unlock()
	if ctx == nil {
		return errors.New("Server se teprve spouští.")
	}
	item, err := c.Cat.Metadata(ctx, id)
	if err != nil || item.IsDir || (item.Format.Kind != dlna.Video && item.Format.Kind != dlna.Audio) {
		return errors.New("Tuto položku nelze přehrát na TV.")
	}
	d, ok := c.known(ctx, udn)
	if !ok {
		return errors.New("Neznámá televize.")
	}
	sctx, cancel := context.WithCancel(ctx)
	s := &session{dev: d, item: item, cancel: cancel}
	s.st = Status{UDN: d.UDN, TV: d.Name, ItemID: item.ID, Title: item.Title, State: "STARTING", DurationMs: item.DurationMs}
	if fromMs > 0 {
		s.resume = max(fromMs-resumeLead.Milliseconds(), 1)
	}
	c.mu.Lock()
	if old := c.sess; old != nil {
		old.cancel()
	}
	c.sess, c.last = s, nil
	c.mu.Unlock()
	c.wg.Go(func() { c.run(sctx, s) })
	return nil
}

func (c *Controller) update(s *session, f func(*Status)) {
	c.mu.Lock()
	f(&s.st)
	c.mu.Unlock()
}

// end closes the session, keeping its last state for the UI.
func (c *Controller) end(s *session, errMsg string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s.cancel()
	if c.sess != s {
		return
	}
	st := s.st
	st.State, st.Error = "STOPPED", errMsg
	c.sess, c.last, c.lastAt = nil, &st, time.Now()
	go c.progressed()
}

func (c *Controller) run(ctx context.Context, s *session) {
	dev, err := c.reach(ctx, s)
	if err != nil {
		if ctx.Err() == nil {
			c.end(s, err.Error())
		}
		return
	}
	c.update(s, func(st *Status) { s.dev, st.CanVolume = dev, dev.rc != "" })
	if err := c.load(ctx, s); err != nil {
		if ctx.Err() == nil {
			slog.Warn("play to TV", "tv", dev.Name, "err", err)
			c.end(s, "Televize odmítla přehrávání: "+err.Error())
		}
		return
	}
	failures := 0
	t := time.NewTicker(pollEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			c.save(s)
			return
		case <-t.C:
		}
		done, err := c.poll(ctx, s)
		if ctx.Err() != nil {
			c.save(s)
			return
		}
		if err != nil {
			if failures++; failures >= maxFailures {
				c.save(s)
				c.end(s, "Televize přestala odpovídat.")
				return
			}
			continue
		}
		failures = 0
		if done {
			return
		}
	}
}

// reach returns the TV ready to take commands, waking it when it does not answer and its MAC is known.
func (c *Controller) reach(ctx context.Context, s *session) (Device, error) {
	if d, err := Describe(ctx, s.dev.Location); err == nil {
		d.MAC = s.dev.MAC
		return d, nil
	}
	if s.dev.MAC == "" {
		return Device{}, errors.New("Televize neodpovídá. Zapněte ji a povolte na ní sdílení obsahu (DLNA).")
	}
	c.update(s, func(st *Status) { st.State = "WAKING" })
	ifaces := ssdp.LANInterfaces(c.Interfaces)
	deadline := time.Now().Add(wakeTimeout)
	var lastWake time.Time
	for time.Now().Before(deadline) {
		if time.Since(lastWake) > 15*time.Second {
			if err := Wake(s.dev.MAC, ifaces); err != nil {
				return Device{}, fmt.Errorf("Televizi se nepodařilo zapnout: %v", err)
			}
			lastWake = time.Now()
		}
		// After a boot the renderer may listen on another port: look it up again.
		found, _ := Search(ctx, c.Interfaces, 2*time.Second)
		for _, d := range found {
			if d.UDN == s.dev.UDN {
				d.MAC = s.dev.MAC
				_, _ = c.DB.ExecContext(ctx, `UPDATE renderer SET location = ?, ip = ?, seen_at = ? WHERE udn = ?`,
					d.Location, d.IP, time.Now().Unix(), d.UDN)
				c.mu.Lock()
				if c.online == nil {
					c.online = map[string]Device{}
				}
				c.online[d.UDN] = d
				c.mu.Unlock()
				return d, nil
			}
		}
		if ctx.Err() != nil {
			return Device{}, ctx.Err()
		}
	}
	return Device{}, errors.New("Televize se nezapnula. Povolte na ní zapnutí přes Wi-Fi/LAN.")
}

// load hands the stream to the TV and starts playback.
func (c *Controller) load(ctx context.Context, s *session) error {
	ip, err := localIP(s.dev.IP)
	if err != nil {
		return err
	}
	base := "http://" + net.JoinHostPort(ip, strconv.Itoa(c.Port))
	opts := upnp.RenderOpts{Profile: c.Profiles.For(s.dev.IP, s.dev.Manufacturer+" "+s.dev.Model+" "+s.dev.Name), Transcode: c.Transcode}
	s.uri, _ = upnp.StreamURL(s.item, base, opts)
	meta := upnp.DIDL([]library.Object{s.item}, base, opts)
	slog.Info("play to TV", "tv", s.dev.Name, "item", s.item.Title, "url", s.uri, "from_ms", s.resume)

	// Some TVs refuse a new URI while another one plays.
	_, _ = call(ctx, s.dev.avt, avtType, "Stop", [][2]string{{"InstanceID", "0"}})
	if _, err := call(ctx, s.dev.avt, avtType, "SetAVTransportURI", [][2]string{
		{"InstanceID", "0"}, {"CurrentURI", s.uri}, {"CurrentURIMetaData", meta},
	}); err != nil {
		return err
	}
	_, err = call(ctx, s.dev.avt, avtType, "Play", [][2]string{{"InstanceID", "0"}, {"Speed", "1"}})
	return err
}

// poll reads the TV state; done means the session ended.
func (c *Controller) poll(ctx context.Context, s *session) (done bool, err error) {
	ti, err := call(ctx, s.dev.avt, avtType, "GetTransportInfo", [][2]string{{"InstanceID", "0"}})
	if err != nil {
		return false, err
	}
	pi, err := call(ctx, s.dev.avt, avtType, "GetPositionInfo", [][2]string{{"InstanceID", "0"}})
	if err != nil {
		return false, err
	}
	state := ti["CurrentTransportState"]
	pos, posOK := parseTime(pi["RelTime"])
	dur, _ := parseTime(pi["TrackDuration"])
	var vol int
	var muted, volOK bool
	if s.dev.rc != "" {
		if v, err := call(ctx, s.dev.rc, rcType, "GetVolume", [][2]string{{"InstanceID", "0"}, {"Channel", "Master"}}); err == nil {
			vol, _ = strconv.Atoi(v["CurrentVolume"])
			volOK = true
		}
		if m, err := call(ctx, s.dev.rc, rcType, "GetMute", [][2]string{{"InstanceID", "0"}, {"Channel", "Master"}}); err == nil {
			muted = m["CurrentMute"] == "1" || strings.EqualFold(m["CurrentMute"], "true")
		}
	}

	// The TV now plays something else: someone started other content on it.
	if s.started && pi["TrackURI"] != "" && !sameURI(pi["TrackURI"], s.uri) {
		c.save(s)
		c.end(s, "")
		return true, nil
	}

	playing := state == "PLAYING" || state == "PAUSED_PLAYBACK"
	c.update(s, func(st *Status) {
		st.State = state
		if playing && posOK && (pos > 0 || !s.started) {
			st.PositionMs = pos
		}
		if dur > 0 {
			st.DurationMs = dur
		}
		if volOK {
			st.Volume, st.Muted = vol, muted
		}
	})
	if playing {
		c.update(s, func(*Status) { s.started = true })
		if s.resume > 0 && state == "PLAYING" {
			if err := c.seek(ctx, s, s.resume); err != nil {
				slog.Warn("resume seek", "tv", s.dev.Name, "err", err)
			}
			s.resume = 0
		}
		c.mu.Lock()
		due := time.Since(s.saved) >= saveEvery
		c.mu.Unlock()
		if due {
			c.save(s)
		}
		return false, nil
	}
	if !s.started || (state != "STOPPED" && state != "NO_MEDIA_PRESENT") {
		return false, nil
	}

	// Stopped after playing: by the user, or at the end.
	c.save(s)
	c.mu.Lock()
	st := s.st
	c.mu.Unlock()
	end := st.DurationMs > 0 && st.PositionMs >= st.DurationMs-endSlack.Milliseconds()
	if end {
		if next, ok := c.Cat.NextEpisode(ctx, s.item.ID); ok {
			c.progressed()
			c.update(s, func(st *Status) {
				s.item, s.started, s.resume = next, false, 0
				if next.PositionMs > 0 && !next.Watched {
					s.resume = max(next.PositionMs-resumeLead.Milliseconds(), 1)
				}
				*st = Status{UDN: st.UDN, TV: st.TV, ItemID: next.ID, Title: next.Title, State: "STARTING",
					DurationMs: next.DurationMs, Volume: st.Volume, Muted: st.Muted, CanVolume: st.CanVolume}
			})
			if err := c.load(ctx, s); err != nil {
				c.end(s, "Další díl se nepodařilo spustit: "+err.Error())
				return true, nil
			}
			return false, nil
		}
	}
	c.end(s, "")
	return true, nil
}

// save stores the watch position of the session's item.
func (c *Controller) save(s *session) {
	c.mu.Lock()
	pos, dur, id, started := s.st.PositionMs, s.st.DurationMs, s.item.ID, s.started
	if started && pos > 0 {
		s.saved = time.Now()
	}
	c.mu.Unlock()
	if !started || pos <= 0 {
		return
	}
	// The session context may be cancelled already; the write must still happen.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Cat.SavePosition(ctx, id, pos, dur); err != nil {
		slog.Warn("save position", "err", err)
	}
}

// progressed tells the TV's content directory once per finished item, not on every periodic save.
func (c *Controller) progressed() {
	if c.OnProgress != nil {
		c.OnProgress()
	}
}

func (c *Controller) seek(ctx context.Context, s *session, ms int64) error {
	target := formatTime(ms)
	_, err := call(ctx, s.dev.avt, avtType, "Seek", [][2]string{{"InstanceID", "0"}, {"Unit", "REL_TIME"}, {"Target", target}})
	if err != nil {
		// Some renderers only take ABS_TIME.
		_, err = call(ctx, s.dev.avt, avtType, "Seek", [][2]string{{"InstanceID", "0"}, {"Unit", "ABS_TIME"}, {"Target", target}})
	}
	if err == nil {
		c.update(s, func(st *Status) { st.PositionMs = ms })
	}
	return err
}

// Command controls the running session: pause, play, stop, seek (value ms), volume (0–100), mute (1/0).
func (c *Controller) Command(ctx context.Context, action string, value int64) error {
	c.mu.Lock()
	s := c.sess
	var dev Device
	if s != nil {
		dev = s.dev
	}
	c.mu.Unlock()
	if s == nil {
		return errors.New("Na televizi nic nehraje.")
	}
	if dev.avt == "" {
		return errors.New("Televize se ještě připojuje.")
	}
	var err error
	in := [][2]string{{"InstanceID", "0"}}
	switch action {
	case "pause":
		_, err = call(ctx, dev.avt, avtType, "Pause", in)
	case "play":
		_, err = call(ctx, dev.avt, avtType, "Play", append(in, [2]string{"Speed", "1"}))
	case "stop":
		c.save(s)
		_, err = call(ctx, dev.avt, avtType, "Stop", in)
		if err == nil {
			c.end(s, "")
		}
	case "seek":
		err = c.seek(ctx, s, max(value, 0))
	case "volume", "mute":
		if dev.rc == "" {
			return errors.New("Televize neumožňuje ovládat hlasitost.")
		}
		if action == "volume" {
			v := min(max(value, 0), 100)
			_, err = call(ctx, dev.rc, rcType, "SetVolume", append(in, [2]string{"Channel", "Master"}, [2]string{"DesiredVolume", strconv.FormatInt(v, 10)}))
			if err == nil {
				c.update(s, func(st *Status) { st.Volume = int(v) })
			}
		} else {
			_, err = call(ctx, dev.rc, rcType, "SetMute", append(in, [2]string{"Channel", "Master"}, [2]string{"DesiredMute", strconv.FormatBool(value != 0)}))
			if err == nil {
				c.update(s, func(st *Status) { st.Muted = value != 0 })
			}
		}
	default:
		return errors.New("Neznámý příkaz.")
	}
	if err != nil {
		return fmt.Errorf("Televize příkaz odmítla: %v", err)
	}
	return nil
}

// sameURI compares stream URIs by path: TVs may echo the host or escaping differently.
func sameURI(a, b string) bool {
	ua, err1 := url.Parse(a)
	ub, err2 := url.Parse(b)
	if err1 != nil || err2 != nil {
		return a == b
	}
	return ua.Path == ub.Path
}

// localIP is this Mac's address on the network that reaches ip.
func localIP(ip string) (string, error) {
	conn, err := net.Dial("udp4", net.JoinHostPort(ip, "9"))
	if err != nil {
		return "", err
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String(), nil
}

// parseTime reads H:MM:SS[.fff]; false for NOT_IMPLEMENTED and the like.
func parseTime(s string) (int64, bool) {
	s, frac, _ := strings.Cut(strings.TrimSpace(s), ".")
	parts := strings.Split(s, ":")
	if len(parts) != 3 {
		return 0, false
	}
	var ms int64
	for _, p := range parts {
		n, err := strconv.ParseInt(p, 10, 64)
		if err != nil || n < 0 {
			return 0, false
		}
		ms = ms*60 + n
	}
	ms *= 1000
	if frac != "" {
		f, err := strconv.ParseFloat("0."+frac, 64)
		if err == nil {
			ms += int64(f * 1000)
		}
	}
	return ms, true
}

func formatTime(ms int64) string {
	sec := ms / 1000
	return fmt.Sprintf("%d:%02d:%02d", sec/3600, sec/60%60, sec%60)
}
