package upnp

import (
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
)

const didlHeader = `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ` +
	`xmlns:dc="http://purl.org/dc/elements/1.1/" ` +
	`xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" ` +
	`xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">`

// DIDL renders objects as DIDL-Lite. baseURL is "http://host:port" as seen by the client.
func DIDL(objs []library.Object, baseURL string) string {
	var b strings.Builder
	b.WriteString(didlHeader)
	for _, o := range objs {
		if o.IsDir {
			b.WriteString(`<container id="` + esc(o.ID) + `" parentID="` + esc(o.ParentID) + `" restricted="1" searchable="0"`)
			if o.ChildCount >= 0 {
				b.WriteString(` childCount="` + strconv.Itoa(o.ChildCount) + `"`)
			}
			b.WriteString(`><dc:title>` + esc(o.Title) + `</dc:title>`)
			b.WriteString(`<upnp:class>object.container.storageFolder</upnp:class></container>`)
			continue
		}
		b.WriteString(`<item id="` + esc(o.ID) + `" parentID="` + esc(o.ParentID) + `" restricted="1">`)
		b.WriteString(`<dc:title>` + esc(o.Title) + `</dc:title>`)
		b.WriteString(`<upnp:class>` + itemClass(o.Format.Kind) + `</upnp:class>`)
		switch {
		case o.Year > 0:
			b.WriteString(`<dc:date>` + strconv.Itoa(o.Year) + `-01-01</dc:date>`)
		case !o.ModTime.IsZero():
			b.WriteString(`<dc:date>` + o.ModTime.UTC().Format("2006-01-02T15:04:05") + `</dc:date>`)
		}
		b.WriteString(`<res protocolInfo="` + esc(dlna.ProtocolInfo(o.Format)) + `" size="` + strconv.FormatInt(o.Size, 10) + `"`)
		if o.DurationMs > 0 {
			b.WriteString(` duration="` + formatDuration(o.DurationMs) + `"`)
		}
		if o.Width > 0 && o.Height > 0 {
			b.WriteString(` resolution="` + strconv.Itoa(o.Width) + "x" + strconv.Itoa(o.Height) + `"`)
		}
		b.WriteString(`>`)
		b.WriteString(esc(baseURL + o.MediaPath))
		b.WriteString(`</res></item>`)
	}
	b.WriteString(`</DIDL-Lite>`)
	return b.String()
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
