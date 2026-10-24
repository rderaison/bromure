package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"math"
)

// trayIcon draws the mark (a rounded square with a terminal chevron) and
// wraps it as an .ico with a PNG payload (Vista+). badge adds a dot: an
// agent wants the user.
func trayIcon(badge bool, dim bool) []byte {
	const n = 32
	img := image.NewNRGBA(image.Rect(0, 0, n, n))
	fg := color.NRGBA{0x5E, 0x8B, 0xDE, 0xff}
	if dim {
		fg = color.NRGBA{0x8a, 0x8a, 0x8a, 0xff}
	}
	white := color.NRGBA{0xff, 0xff, 0xff, 0xff}
	r := 7.0
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			fx, fy := float64(x)+0.5, float64(y)+0.5
			// Rounded square 2..30.
			cx := math.Max(2+r-fx, math.Max(fx-(30-r), 0))
			cy := math.Max(2+r-fy, math.Max(fy-(30-r), 0))
			if fx < 2 || fx > 30 || fy < 2 || fy > 30 || cx*cx+cy*cy > r*r {
				continue
			}
			img.Set(x, y, fg)
		}
	}
	// A ">" chevron and an underscore.
	line := func(x0, y0, x1, y1, w float64) {
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				px, py := float64(x)+0.5, float64(y)+0.5
				dx, dy := x1-x0, y1-y0
				t := math.Max(0, math.Min(1, ((px-x0)*dx+(py-y0)*dy)/(dx*dx+dy*dy)))
				ex, ey := x0+t*dx-px, y0+t*dy-py
				if ex*ex+ey*ey <= w*w {
					img.Set(x, y, white)
				}
			}
		}
	}
	line(9, 10, 15, 16, 1.6)
	line(15, 16, 9, 22, 1.6)
	line(17, 22, 23, 22, 1.6)
	if badge {
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				dx, dy := float64(x)-25.5, float64(y)-6.5
				if dx*dx+dy*dy <= 25 {
					img.Set(x, y, color.NRGBA{0xE5, 0x48, 0x4D, 0xff})
				}
			}
		}
	}
	var pngBuf bytes.Buffer
	_ = png.Encode(&pngBuf, img)
	var ico bytes.Buffer
	binary.Write(&ico, binary.LittleEndian, []uint16{0, 1, 1})
	ico.Write([]byte{n, n, 0, 0})
	binary.Write(&ico, binary.LittleEndian, []uint16{1, 32})
	binary.Write(&ico, binary.LittleEndian, []uint32{uint32(pngBuf.Len()), 22})
	ico.Write(pngBuf.Bytes())
	return ico.Bytes()
}
