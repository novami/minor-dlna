package library

import (
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	reSxE       = regexp.MustCompile(`(?i)(?:^|[^a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})(?:[-e]\d{1,3})*`)
	reNxN       = regexp.MustCompile(`(?i)(?:^|[^a-z0-9])(\d{1,2})x(\d{2,3})(?:[^a-z0-9]|$)`)
	reSeasonDir = regexp.MustCompile(`(?i)^(?:season|s[eé]rie|serie|sezona|sezóna|s)[ ._-]*(\d{1,2})$`)
	reLeadNum   = regexp.MustCompile(`^(?:e|ep|episode|díl|dil)?[ ._-]*(\d{1,3})(?:[ ._-]+(.*))?$`)
	reYear      = regexp.MustCompile(`(?:^|[ ._(\[-])((?:19|20)\d{2})(?:[ ._)\]-]|$)`)
	reJunk      = regexp.MustCompile(`(?i)[ ._(\[-](?:2160p|1080p|1080i|720p|576p|480p|4k|uhd|hdr|hdr10|dv|bluray|blu-ray|bdrip|brrip|remux|web-?dl|webrip|web|hdtv|dvdrip|dvd|x264|x265|h264|h265|hevc|avc|xvid|aac|ac3|dts|atmos|10bit|proper|repack|extended|unrated|cz|czech|dabing|titulky|sk)(?:[ ._)\]-]|$)`)
	reSpaces    = regexp.MustCompile(`\s+`)
)

// Episode is a parsed TV episode.
type Episode struct {
	Show    string
	Season  int
	Episode int
	Title   string
}

// ParseEpisode recognises "Show S01E02 Title", "Show 1x02" and "Show/Season 1/02 Title.ext".
// rel is the path relative to the library root.
func ParseEpisode(rel string) (Episode, bool) {
	base := stripExt(filepath.Base(rel))
	dirs := splitDirs(filepath.Dir(rel))

	for _, re := range []*regexp.Regexp{reSxE, reNxN} {
		m := re.FindStringSubmatchIndex(base)
		if m == nil {
			continue
		}
		ep := Episode{Season: atoi(base[m[2]:m[3]]), Episode: atoi(base[m[4]:m[5]])}
		ep.Show = cleanName(base[:m[0]])
		ep.Title = cleanTitle(base[m[1]:])
		if ep.Show == "" {
			ep.Show = showFromDirs(dirs)
		}
		return ep, ep.Show != ""
	}

	// Folder layout: Show/Season 1/02 Title.ext
	if len(dirs) >= 2 {
		if sm := reSeasonDir.FindStringSubmatch(dirs[len(dirs)-1]); sm != nil {
			if em := reLeadNum.FindStringSubmatch(cleanName(base)); em != nil {
				return Episode{
					Show:    cleanName(dirs[len(dirs)-2]),
					Season:  atoi(sm[1]),
					Episode: atoi(em[1]),
					Title:   cleanTitle(em[2]),
				}, true
			}
		}
	}
	return Episode{}, false
}

// showFromDirs takes the nearest parent folder that is not a season folder.
func showFromDirs(dirs []string) string {
	for i := len(dirs) - 1; i >= 0; i-- {
		if !reSeasonDir.MatchString(dirs[i]) {
			return cleanName(dirs[i])
		}
	}
	return ""
}

// ParseMovie extracts title and year from a file name like "Film.Name.2019.1080p.mkv".
func ParseMovie(name string) (title string, year int) {
	base := stripExt(name)
	// Last plausible year wins: "2001 A Space Odyssey (1968)".
	if all := reYear.FindAllStringSubmatchIndex(base, -1); len(all) > 0 {
		m := all[len(all)-1]
		if t := cleanName(base[:m[2]]); t != "" {
			return t, atoi(base[m[2]:m[3]])
		}
	}
	if m := reJunk.FindStringIndex(base); m != nil && m[0] > 0 {
		base = base[:m[0]]
	}
	return cleanName(base), 0
}

// cleanName turns separators into spaces and trims brackets and dashes.
func cleanName(s string) string {
	if !strings.Contains(s, " ") {
		s = strings.NewReplacer(".", " ", "_", " ").Replace(s)
	} else {
		s = strings.ReplaceAll(s, "_", " ")
	}
	s = reSpaces.ReplaceAllString(s, " ")
	return strings.Trim(s, " -([.")
}

// cleanTitle removes release tags from an episode title.
func cleanTitle(s string) string {
	s = " " + s
	if m := reJunk.FindStringIndex(s); m != nil {
		s = s[:m[0]]
	}
	return cleanName(s)
}

func stripExt(name string) string { return strings.TrimSuffix(name, filepath.Ext(name)) }

func splitDirs(dir string) []string {
	if dir == "." || dir == "" {
		return nil
	}
	return strings.Split(filepath.ToSlash(dir), "/")
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// SortKey makes plain string ordering natural: lower-case, numbers zero-padded, leading articles kept.
func SortKey(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] >= '0' && s[i] <= '9' {
			j := i
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j++
			}
			num := strings.TrimLeft(s[i:j], "0")
			if len(num) < 8 {
				b.WriteString(strings.Repeat("0", 8-len(num)))
			}
			b.WriteString(num)
			i = j
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}
