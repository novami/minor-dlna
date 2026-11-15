package thumbs

import (
	"image"
	"image/color"
	"testing"
)

func TestOrientAndFit(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 4, 2))
	img.Set(0, 0, color.RGBA{255, 0, 0, 255}) // top-left marker

	// Orientation 6: rotate 90° clockwise → 2x4, marker moves to top-right.
	r := Orient(img, 6)
	if b := r.Bounds(); b.Dx() != 2 || b.Dy() != 4 {
		t.Fatalf("bounds %v", b)
	}
	if c := color.RGBAModel.Convert(r.At(1, 0)).(color.RGBA); c.R != 255 {
		t.Fatalf("marker not rotated: %v", c)
	}

	big := image.NewRGBA(image.Rect(0, 0, 3000, 4000)) // portrait
	f := Fit(big, sizes["sm"])
	if b := f.Bounds(); b.Dx() != 480 || b.Dy() != 640 {
		t.Fatalf("fit %v", b)
	}
	if Fit(img, sizes["tn"]) != img {
		t.Fatal("small image was rescaled")
	}
}
