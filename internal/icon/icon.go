// Package icon renders the app icon at runtime, so the binary needs no image assets.
package icon

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
)

// App draws the app icon (see assets/icon.svg): orange gradient tile, play symbol and cast waves.
// Rendered at runtime so the binary needs no image assets; 4×4 supersampling for smooth edges.
func App(size int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const ss = 4
	scale := 1024 / float64(size*ss)
	for y := range size {
		for x := range size {
			var r, g, b, a float64
			for sy := range ss {
				for sx := range ss {
					u := (float64(x*ss+sx) + 0.5) * scale
					v := (float64(y*ss+sy) + 0.5) * scale
					if !inRoundRect(u, v, 1024, 230) {
						continue
					}
					cr, cg, cb := iconBackground(u, v)
					if w := iconForeground(u, v); w > 0 {
						cr, cg, cb = cr+(1-cr)*w, cg+(1-cg)*w, cb+(1-cb)*w
					}
					r, g, b, a = r+cr, g+cg, b+cb, a+1
				}
			}
			if a == 0 {
				continue
			}
			img.SetNRGBA(x, y, color.NRGBA{uint8(r / a * 255), uint8(g / a * 255), uint8(b / a * 255), uint8(a / (ss * ss) * 255)})
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func inRoundRect(u, v, size, rad float64) bool {
	dx := max(rad-u, 0, u-(size-rad))
	dy := max(rad-v, 0, v-(size-rad))
	return dx*dx+dy*dy <= rad*rad
}

// iconBackground is the diagonal gradient #FFB020 → #FF7A00 → #F0441C with a soft top-left glow.
func iconBackground(u, v float64) (r, g, b float64) {
	stops := [][4]float64{{0, 0xFF, 0xB0, 0x20}, {0.55, 0xFF, 0x7A, 0x00}, {1, 0xF0, 0x44, 0x1C}}
	t := (u + v) / 2048
	for i := 1; i < len(stops); i++ {
		if t <= stops[i][0] || i == len(stops)-1 {
			p, q := stops[i-1], stops[i]
			f := min(max((t-p[0])/(q[0]-p[0]), 0), 1)
			r, g, b = (p[1]+(q[1]-p[1])*f)/255, (p[2]+(q[2]-p[2])*f)/255, (p[3]+(q[3]-p[3])*f)/255
			break
		}
	}
	d := math.Hypot(u-307, v-205)
	if glow := 0.28 * (1 - d/768); glow > 0 {
		r, g, b = r+(1-r)*glow, g+(1-g)*glow, b+(1-b)*glow
	}
	return
}

// iconForeground returns white coverage: rounded play triangle and two cast arcs (outer one 60 %).
func iconForeground(u, v float64) float64 {
	tri := [3][2]float64{{251, 307}, {251, 717}, {538, 512}}
	if inTriangle(u, v, tri) || distToTriangle(u, v, tri) <= 22 {
		return 1
	}
	const cx, cy = 345.0, 512.0
	for i, rad := range []float64{297, 397} {
		d := math.Hypot(u-cx, v-cy)
		ang := math.Atan2(v-cy, u-cx)
		onArc := math.Abs(d-rad) <= 28 && math.Abs(ang) <= math.Pi/4
		e := rad * math.Sqrt2 / 2
		caps := math.Hypot(u-(cx+e), v-(cy-e)) <= 28 || math.Hypot(u-(cx+e), v-(cy+e)) <= 28
		if onArc || caps {
			return []float64{1, 0.6}[i]
		}
	}
	return 0
}

func inTriangle(u, v float64, t [3][2]float64) bool {
	sign := func(a, b [2]float64) float64 { return (u-b[0])*(a[1]-b[1]) - (a[0]-b[0])*(v-b[1]) }
	d1, d2, d3 := sign(t[0], t[1]), sign(t[1], t[2]), sign(t[2], t[0])
	neg := d1 < 0 || d2 < 0 || d3 < 0
	pos := d1 > 0 || d2 > 0 || d3 > 0
	return !(neg && pos)
}

func distToTriangle(u, v float64, t [3][2]float64) float64 {
	best := math.MaxFloat64
	for i := range 3 {
		a, b := t[i], t[(i+1)%3]
		dx, dy := b[0]-a[0], b[1]-a[1]
		f := min(max(((u-a[0])*dx+(v-a[1])*dy)/(dx*dx+dy*dy), 0), 1)
		best = min(best, math.Hypot(u-(a[0]+f*dx), v-(a[1]+f*dy)))
	}
	return best
}

// Template draws the menu bar icon: play symbol and waves in black on transparent.
// macOS treats it as a template image and recolors it for light, dark and highlighted menu bars.
func Template(size int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const ss = 4
	scale := 1024 / float64(size*ss)
	for y := range size {
		for x := range size {
			var a float64
			for sy := range ss {
				for sx := range ss {
					// The glyph spans x 229..770, y 203..821 of the tile; crop a 687-unit square around it (5 % margin).
					u := 157 + (float64(x*ss+sx)+0.5)*scale*0.671
					v := 169 + (float64(y*ss+sy)+0.5)*scale*0.671
					a += iconForeground(u, v)
				}
			}
			if a > 0 {
				img.SetNRGBA(x, y, color.NRGBA{0, 0, 0, uint8(min(a/(ss*ss), 1) * 255)})
			}
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}
