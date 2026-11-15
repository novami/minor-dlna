// Package dlna maps media files to DLNA content types and protocolInfo strings.
package dlna

import (
	"path/filepath"
	"slices"
	"strings"
)

type Kind int

const (
	Unknown Kind = iota
	Video
	Image
	Audio
)

type Format struct {
	Kind Kind
	Mime string
}

var formats = map[string]Format{
	".mkv":  {Video, "video/x-matroska"},
	".mp4":  {Video, "video/mp4"},
	".m4v":  {Video, "video/mp4"},
	".mov":  {Video, "video/quicktime"},
	".avi":  {Video, "video/x-msvideo"},
	".ts":   {Video, "video/mp2t"},
	".m2ts": {Video, "video/vnd.dlna.mpeg-tts"},
	".mts":  {Video, "video/vnd.dlna.mpeg-tts"},
	".mpg":  {Video, "video/mpeg"},
	".mpeg": {Video, "video/mpeg"},
	".webm": {Video, "video/webm"},
	".wmv":  {Video, "video/x-ms-wmv"},
	".jpg":  {Image, "image/jpeg"},
	".jpeg": {Image, "image/jpeg"},
	".png":  {Image, "image/png"},
	".gif":  {Image, "image/gif"},
	".mp3":  {Audio, "audio/mpeg"},
	".flac": {Audio, "audio/flac"},
	".m4a":  {Audio, "audio/mp4"},
	".aac":  {Audio, "audio/aac"},
	".wav":  {Audio, "audio/wav"},
	".ogg":  {Audio, "audio/ogg"},
}

// Lookup returns the format of a file by its extension.
func Lookup(name string) (Format, bool) {
	f, ok := formats[strings.ToLower(filepath.Ext(name))]
	return f, ok
}

// DLNA.ORG_FLAGS: streaming transfer, background transfer, connection stalling, DLNA 1.5.
const (
	flagsStreaming   = "01700000000000000000000000000000"
	flagsInteractive = "00D00000000000000000000000000000"
)

// ContentFeatures returns the 4th field of protocolInfo, also used as the contentFeatures.dlna.org header.
// OP=01 announces byte-range seeking on the original file.
func ContentFeatures(f Format) string {
	flags := flagsStreaming
	if f.Kind == Image {
		flags = flagsInteractive
	}
	return "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=" + flags
}

func ProtocolInfo(f Format) string {
	return "http-get:*:" + f.Mime + ":" + ContentFeatures(f)
}

// TransferMode returns the default transferMode.dlna.org value.
func TransferMode(f Format) string {
	if f.Kind == Image {
		return "Interactive"
	}
	return "Streaming"
}

// SourceProtocolInfo lists everything the server can serve (ConnectionManager GetProtocolInfo).
func SourceProtocolInfo() string {
	seen := map[string]bool{}
	var out []string
	for _, f := range formats {
		if !seen[f.Mime] {
			seen[f.Mime] = true
			out = append(out, "http-get:*:"+f.Mime+":*")
		}
	}
	slices.Sort(out)
	return strings.Join(out, ",")
}
