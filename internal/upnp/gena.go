package upnp

import (
	"context"
	"crypto/rand"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const subTimeout = 1800 * time.Second

type subscription struct {
	urls    []string
	seq     uint32
	expires time.Time
}

// eventer manages GENA subscriptions for one service.
type eventer struct {
	props func() [][2]string // evented state variables

	mu   sync.Mutex
	subs map[string]*subscription
}

func newEventer(props func() [][2]string) *eventer {
	return &eventer{props: props, subs: map[string]*subscription{}}
}

var reCallback = regexp.MustCompile(`<([^>]+)>`)

func (e *eventer) handle(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "SUBSCRIBE":
		e.subscribe(w, r)
	case "UNSUBSCRIBE":
		e.mu.Lock()
		_, ok := e.subs[r.Header.Get("SID")]
		delete(e.subs, r.Header.Get("SID"))
		e.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusPreconditionFailed)
			return
		}
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (e *eventer) subscribe(w http.ResponseWriter, r *http.Request) {
	timeout := subTimeout
	if t := strings.TrimPrefix(r.Header.Get("TIMEOUT"), "Second-"); t != "" && t != "infinite" {
		if n, err := strconv.Atoi(t); err == nil && n > 0 {
			timeout = min(time.Duration(n)*time.Second, subTimeout)
		}
	}
	// Renewal.
	if sid := r.Header.Get("SID"); sid != "" {
		e.mu.Lock()
		s, ok := e.subs[sid]
		if ok {
			s.expires = time.Now().Add(timeout)
		}
		e.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusPreconditionFailed)
			return
		}
		writeSubHeaders(w, sid, timeout)
		return
	}
	if r.Header.Get("NT") != "upnp:event" {
		w.WriteHeader(http.StatusPreconditionFailed)
		return
	}
	remote, _, _ := net.SplitHostPort(r.RemoteAddr)
	var urls []string
	for _, m := range reCallback.FindAllStringSubmatch(r.Header.Get("CALLBACK"), 4) {
		u, err := url.Parse(m[1])
		// Only call back the subscriber itself, never a third host.
		if err == nil && u.Scheme == "http" && u.Hostname() == remote {
			urls = append(urls, u.String())
		}
	}
	if len(urls) == 0 {
		w.WriteHeader(http.StatusPreconditionFailed)
		return
	}
	sid := newSID()
	s := &subscription{urls: urls, expires: time.Now().Add(timeout)}
	e.mu.Lock()
	e.expire()
	e.subs[sid] = s
	e.mu.Unlock()
	writeSubHeaders(w, sid, timeout)
	// Initial event must follow the SUBSCRIBE response.
	go func() {
		time.Sleep(200 * time.Millisecond)
		e.send(sid)
	}()
}

func writeSubHeaders(w http.ResponseWriter, sid string, timeout time.Duration) {
	w.Header().Set("SID", sid)
	w.Header().Set("TIMEOUT", fmt.Sprintf("Second-%d", int(timeout.Seconds())))
	w.WriteHeader(http.StatusOK)
}

// expire drops stale subscriptions; caller holds mu.
func (e *eventer) expire() {
	now := time.Now()
	for sid, s := range e.subs {
		if now.After(s.expires) {
			delete(e.subs, sid)
		}
	}
}

// notifyAll sends the current state to every subscriber.
func (e *eventer) notifyAll() {
	e.mu.Lock()
	e.expire()
	sids := make([]string, 0, len(e.subs))
	for sid := range e.subs {
		sids = append(sids, sid)
	}
	e.mu.Unlock()
	for _, sid := range sids {
		go e.send(sid)
	}
}

var eventClient = &http.Client{Timeout: 5 * time.Second}

func (e *eventer) send(sid string) {
	e.mu.Lock()
	s, ok := e.subs[sid]
	if !ok {
		e.mu.Unlock()
		return
	}
	seq := s.seq
	s.seq++
	if s.seq == 0 {
		s.seq = 1 // wraps to 1, 0 is reserved for the initial event
	}
	urls := s.urls
	e.mu.Unlock()

	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?><e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">`)
	for _, p := range e.props() {
		b.WriteString("<e:property><" + p[0] + ">" + esc(p[1]) + "</" + p[0] + "></e:property>")
	}
	b.WriteString(`</e:propertyset>`)

	for _, u := range urls {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		req, err := http.NewRequestWithContext(ctx, "NOTIFY", u, strings.NewReader(b.String()))
		if err != nil {
			cancel()
			continue
		}
		req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
		req.Header.Set("NT", "upnp:event")
		req.Header.Set("NTS", "upnp:propchange")
		req.Header.Set("SID", sid)
		req.Header.Set("SEQ", strconv.FormatUint(uint64(seq), 10))
		resp, err := eventClient.Do(req)
		cancel()
		if err != nil {
			slog.Debug("event delivery failed", "url", u, "err", err)
			continue
		}
		resp.Body.Close()
		return // first URL that accepts wins
	}
}

func newSID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("uuid:%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}
