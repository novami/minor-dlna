package upnp

import (
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/stream"
	"github.com/novami/minor-dlna/internal/thumbs"
	"github.com/novami/minor-dlna/internal/transcode"
)

const didlHeader = `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ` +
	`xmlns:dc="http://purl.org/dc/elements/1.1/" ` +
	`xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" ` +
	`xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" ` +
	`xmlns:sec="http://www.sec.co.kr/">`

// RenderOpts tailor resources to the requesting client.
type RenderOpts struct {
	Profile   transcode.Profile
	Transcode bool // ffmpeg available
}

// DIDL renders objects as DIDL-Lite. baseURL is "http://host:port" as seen by the client.
func DIDL(objs []library.Object, baseURL string, opts RenderOpts) string {
	var b strings.Builder
	b.WriteString(didlHeader)
	for _, o := range objs {
		if o.IsDir {
			writeContainer(&b, o, baseURL)
		} else {
			writeItem(&b, o, baseURL, opts)
		}
	}
	b.WriteString(`</DIDL-Lite>`)
	return b.String()
}

func writeContainer(b *strings.Builder, o library.Object, baseURL string) {
	b.WriteString(`<container id="` + esc(o.ID) + `" parentID="` + esc(o.ParentID) + `" restricted="1" searchable="0"`)
	if o.ChildCount >= 0 {
		b.WriteString(` childCount="` + strconv.Itoa(o.ChildCount) + `"`)
	}
	b.WriteString(`><dc:title>` + esc(o.Title) + `</dc:title>`)
	class := o.Class
	if class == "" {
		class = "object.container.storageFolder"
	}
	b.WriteString(`<upnp:class>` + class + `</upnp:class>`)
	if o.Artist != "" {
		b.WriteString(`<upnp:artist>` + esc(o.Artist) + `</upnp:artist>`)
	}
	writeArt(b, o, baseURL)
	b.WriteString(`</container>`)
}

func writeItem(b *strings.Builder, o library.Object, baseURL string, opts RenderOpts) {
	b.WriteString(`<item id="` + esc(o.ID) + `" parentID="` + esc(o.ParentID) + `" restricted="1">`)
	b.WriteString(`<dc:title>` + esc(o.Title) + `</dc:title>`)
	b.WriteString(`<upnp:class>` + itemClass(o.Format.Kind) + `</upnp:class>`)
	switch {
	case !o.Taken.IsZero() && o.Format.Kind == dlna.Image:
		b.WriteString(`<dc:date>` + o.Taken.Format("2006-01-02T15:04:05") + `</dc:date>`)
	case o.Year > 0:
		b.WriteString(`<dc:date>` + strconv.Itoa(o.Year) + `-01-01</dc:date>`)
	case !o.ModTime.IsZero():
		b.WriteString(`<dc:date>` + o.ModTime.UTC().Format("2006-01-02T15:04:05") + `</dc:date>`)
	}
	if o.Format.Kind == dlna.Audio {
		if o.Artist != "" {
			b.WriteString(`<upnp:artist>` + esc(o.Artist) + `</upnp:artist><dc:creator>` + esc(o.Artist) + `</dc:creator>`)
		}
		if o.Album != "" {
			b.WriteString(`<upnp:album>` + esc(o.Album) + `</upnp:album>`)
		}
		if o.Genre != "" {
			b.WriteString(`<upnp:genre>` + esc(o.Genre) + `</upnp:genre>`)
		}
		if o.Track > 0 {
			b.WriteString(`<upnp:originalTrackNumber>` + strconv.Itoa(o.Track) + `</upnp:originalTrackNumber>`)
		}
	}
	if o.Format.Kind == dlna.Video {
		if o.Genre != "" {
			b.WriteString(`<upnp:genre>` + esc(o.Genre) + `</upnp:genre>`)
		}
		if o.Description != "" {
			b.WriteString(`<dc:description>` + esc(o.Description) + `</dc:description>`)
		}
		if o.PositionMs > 0 {
			// UPnP AV bookmark; whether LG resumes from it is unverified.
			b.WriteString(`<upnp:lastPlaybackPosition>` + formatDuration(o.PositionMs) + `</upnp:lastPlaybackPosition>`)
		}
	}
	writeArt(b, o, baseURL)
	subURL := ""
	if o.Subtitle != "" {
		subURL = baseURL + stream.SubtitlePath(o.ID)
		b.WriteString(`<sec:CaptionInfoEx sec:type="srt">` + esc(subURL) + `</sec:CaptionInfoEx>`)
	}

	switch {
	case o.Format.Kind == dlna.Image:
		writePhotoRes(b, o, baseURL)
	default:
		plan := playPlan(o, opts)
		if plan.Direct() {
			writeRes(b, dlna.ProtocolInfo(o.Format), o.Size, o.DurationMs, o.Width, o.Height, baseURL+o.MediaPath)
		} else {
			// Only the converted stream: offering the original too lets the TV pick a format it can't play.
			writeRes(b, transcode.ProtocolInfo(plan), 0, o.DurationMs, o.Width, o.Height, baseURL+transcode.Path(o.ID, plan))
		}
	}
	if subURL != "" {
		writeRes(b, "http-get:*:text/srt:*", 0, 0, 0, 0, subURL)
	}
	b.WriteString(`</item>`)
}

func playPlan(o library.Object, opts RenderOpts) transcode.Plan {
	if !opts.Transcode {
		return transcode.Plan{}
	}
	return transcode.Decide(opts.Profile, transcode.Media{
		Audio: o.Format.Kind == dlna.Audio, Container: o.Container, VideoCodec: o.VideoCodec,
		AudioCodec: o.AudioCodec, PixFmt: o.PixFmt, Channels: o.Channels,
	})
}

// StreamURL is the URL of the audio or video resource DIDL offers for o, with its protocolInfo.
func StreamURL(o library.Object, baseURL string, opts RenderOpts) (url, protocolInfo string) {
	plan := playPlan(o, opts)
	if plan.Direct() {
		return baseURL + o.MediaPath, dlna.ProtocolInfo(o.Format)
	}
	return baseURL + transcode.Path(o.ID, plan), transcode.ProtocolInfo(plan)
}

// writePhotoRes lists a TV-sized rendition first (LG picks the first resource), then the original and smaller sizes.
func writePhotoRes(b *strings.Builder, o library.Object, baseURL string) {
	id, _ := strconv.ParseInt(strings.TrimPrefix(o.ID, "I"), 10, 64)
	heif := media.IsHEIF(o.Path)
	if thumbs.ServesOriginal(o) {
		writeRes(b, "http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=00D00000000000000000000000000000",
			o.Size, 0, o.Width, o.Height, baseURL+o.MediaPath)
	} else {
		writeDerived(b, "lrg", id, baseURL)
		if !heif {
			writeRes(b, dlna.ProtocolInfo(o.Format), o.Size, 0, o.Width, o.Height, baseURL+o.MediaPath)
		}
	}
	writeDerived(b, "sm", id, baseURL)
	writeDerived(b, "tn", id, baseURL)
}

func writeDerived(b *strings.Builder, name string, id int64, baseURL string) {
	size, _ := thumbs.Lookup(name)
	writeRes(b, "http-get:*:image/jpeg:"+thumbs.ContentFeatures(size), 0, 0, 0, 0, baseURL+library.ThumbPath(id, name))
}

func writeRes(b *strings.Builder, protocolInfo string, size, durationMs int64, w, h int, url string) {
	b.WriteString(`<res protocolInfo="` + esc(protocolInfo) + `"`)
	if size > 0 {
		b.WriteString(` size="` + strconv.FormatInt(size, 10) + `"`)
	}
	if durationMs > 0 {
		b.WriteString(` duration="` + formatDuration(durationMs) + `"`)
	}
	if w > 0 && h > 0 {
		b.WriteString(` resolution="` + strconv.Itoa(w) + "x" + strconv.Itoa(h) + `"`)
	}
	b.WriteString(`>` + esc(url) + `</res>`)
}

func writeArt(b *strings.Builder, o library.Object, baseURL string) {
	if o.ArtPath != "" {
		b.WriteString(`<upnp:albumArtURI dlna:profileID="JPEG_TN">` + esc(baseURL+o.ArtPath) + `</upnp:albumArtURI>`)
	}
}

func itemClass(k dlna.Kind) string {
	switch k {
	case dlna.Image:
		return "object.item.imageItem.photo"
	case dlna.Audio:
		return "object.item.audioItem.musicTrack"
	default:
		return "object.item.videoItem"
	}
}

func esc(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// formatDuration renders H:MM:SS.mmm as used by the res@duration attribute.
func formatDuration(ms int64) string {
	return fmt.Sprintf("%d:%02d:%02d.%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}
