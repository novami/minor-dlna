package upnp

import (
	"encoding/xml"
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
		if !o.ModTime.IsZero() {
			b.WriteString(`<dc:date>` + o.ModTime.UTC().Format("2006-01-02T15:04:05") + `</dc:date>`)
		}
		b.WriteString(`<res protocolInfo="` + esc(dlna.ProtocolInfo(o.Format)) + `" size="` + strconv.FormatInt(o.Size, 10) + `">`)
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
