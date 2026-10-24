// mkicons makes the Windows icons from the macOS Sidecar's own icon
// (Resources/BromureSidecarIcon.icns, the mark in Sidecar blue): the exe's
// multi-size app.ico, and the tray's variants — normal, idle (not
// attached: greyed) and badged (an agent wants the user: a dot cut beside
// the mark, as the Mac menu bar draws it).
//
//	go run ./tools/mkicons            (from sidecar/; writes cmd/BromureSidecar/assets/)
//
// Run scripts/winres.sh afterwards to embed app.ico in the executables.
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"sort"
)

func main() {
	icns := filepath.Join("..", "Resources", "BromureSidecarIcon.icns")
	out := filepath.Join("cmd", "BromureSidecar", "assets")
	if len(os.Args) > 1 {
		icns = os.Args[1]
	}
	srcs, err := readICNS(icns)
	if err != nil {
		fail(err)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		fail(err)
	}
	write := func(name string, sizes []int, tweak func(*image.NRGBA)) {
		var imgs []*image.NRGBA
		for _, s := range sizes {
			img := scaleFrom(srcs, s)
			if tweak != nil {
				tweak(img)
			}
			imgs = append(imgs, img)
		}
		if err := os.WriteFile(filepath.Join(out, name), encodeICO(imgs), 0o644); err != nil {
			fail(err)
		}
		fmt.Println("wrote", filepath.Join(out, name))
	}
	// The mark nearly full-bleed: macOS icons carry a wide margin that
	// Windows icons don't.
	srcs = map[int]image.Image{0: cropToMark(srcs, 0.04)}
	write("app.ico", []int{16, 20, 24, 32, 40, 48, 64, 128, 256}, nil)
	tray := []int{16, 20, 24, 32, 40, 48}
	// Light taskbar: the icon's own blue; dark taskbar: its dark-appearance
	// blue (icon.json's fill-specializations).
	write("tray.ico", tray, nil)
	write("tray-badge.ico", tray, badge)
	write("tray-dark.ico", tray, tint(0x93, 0xAE, 0xFF))
	write("tray-dark-badge.ico", tray, func(img *image.NRGBA) { tint(0x93, 0xAE, 0xFF)(img); badge(img) })
	write("tray-idle.ico", tray, tint(0x8A, 0x8D, 0x99))
	write("tray-dark-idle.ico", tray, tint(0xA8, 0xAB, 0xB4))
	// The resource objects both executables link: icon + manifest.
	ico, _ := os.ReadFile(filepath.Join(out, "app.ico"))
	res := append(iconResources(ico, 1), resource{typ: rtManifest, id: 1, data: []byte(manifest)})
	for _, pkg := range []string{filepath.Join("cmd", "BromureSidecar"), filepath.Join("cmd", "bromure-sidecar")} {
		for arch, m := range map[string]uint16{"amd64": machineAMD64, "arm64": machineARM64} {
			p := filepath.Join(pkg, "rsrc_windows_"+arch+".syso")
			if err := os.WriteFile(p, syso(m, res), 0o644); err != nil {
				fail(err)
			}
			fmt.Println("wrote", p)
		}
	}
	// A PNG of the mark for the UI's window icon fallbacks.
	f, _ := os.Create(filepath.Join(out, "mark-256.png"))
	png.Encode(f, scaleFrom(srcs, 256))
	f.Close()
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "mkicons:", err)
	os.Exit(1)
}

// readICNS returns the PNG entries by width.
func readICNS(p string) (map[int]image.Image, error) {
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	out := map[int]image.Image{}
	for off := 8; off+8 <= len(b); {
		n := int(binary.BigEndian.Uint32(b[off+4:]))
		if n < 8 || off+n > len(b) {
			break
		}
		if img, err := png.Decode(bytes.NewReader(b[off+8 : off+n])); err == nil {
			out[img.Bounds().Dx()] = img
		}
		off += n
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no PNG images in %s", p)
	}
	return out, nil
}

// scaleFrom downsizes the smallest source at least size wide (2× when
// there is one, for a cleaner filter) by area averaging in premultiplied
// alpha.
func scaleFrom(srcs map[int]image.Image, size int) *image.NRGBA {
	var widths []int
	for w := range srcs {
		widths = append(widths, w)
	}
	sort.Ints(widths)
	pick := widths[len(widths)-1]
	for _, w := range widths {
		if w >= size*2 {
			pick = w
			break
		}
	}
	return areaScale(srcs[pick], size)
}

func areaScale(src image.Image, size int) *image.NRGBA {
	b := src.Bounds()
	sw, sh := b.Dx(), b.Dy()
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	fx, fy := float64(sw)/float64(size), float64(sh)/float64(size)
	for y := 0; y < size; y++ {
		y0, y1 := float64(y)*fy, float64(y+1)*fy
		for x := 0; x < size; x++ {
			x0, x1 := float64(x)*fx, float64(x+1)*fx
			var r, g, bl, a, wsum float64
			for sy := int(y0); sy < int(math.Ceil(y1)); sy++ {
				wy := math.Min(y1, float64(sy+1)) - math.Max(y0, float64(sy))
				for sx := int(x0); sx < int(math.Ceil(x1)); sx++ {
					wx := math.Min(x1, float64(sx+1)) - math.Max(x0, float64(sx))
					w := wx * wy
					c := color.NRGBAModel.Convert(src.At(b.Min.X+sx, b.Min.Y+sy)).(color.NRGBA)
					al := float64(c.A) / 255
					r += float64(c.R) * al * w
					g += float64(c.G) * al * w
					bl += float64(c.B) * al * w
					a += al * w
					wsum += w
				}
			}
			if a <= 0 {
				continue
			}
			dst.SetNRGBA(x, y, color.NRGBA{
				R: uint8(math.Round(r / a)), G: uint8(math.Round(g / a)), B: uint8(math.Round(bl / a)),
				A: uint8(math.Round(a / wsum * 255)),
			})
		}
	}
	return dst
}

// cropToMark is the largest source cut to its opaque bounds (squared,
// centered) with margin of the side around it.
func cropToMark(srcs map[int]image.Image, margin float64) image.Image {
	big := 0
	for w := range srcs {
		if w > big {
			big = w
		}
	}
	src := srcs[big]
	b := src.Bounds()
	minX, minY, maxX, maxY := b.Max.X, b.Max.Y, b.Min.X, b.Min.Y
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			if _, _, _, a := src.At(x, y).RGBA(); a > 0x0800 {
				minX, minY = min(minX, x), min(minY, y)
				maxX, maxY = max(maxX, x+1), max(maxY, y+1)
			}
		}
	}
	side := max(maxX-minX, maxY-minY)
	pad := int(float64(side) * margin)
	side += 2 * pad
	cx, cy := (minX+maxX)/2, (minY+maxY)/2
	out := image.NewNRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			sx, sy := cx-side/2+x, cy-side/2+y
			if (image.Point{sx, sy}).In(b) {
				out.Set(x, y, src.At(sx, sy))
			}
		}
	}
	return out
}

// tint recolours the mark (its alpha kept).
func tint(r, g, b uint8) func(*image.NRGBA) {
	return func(img *image.NRGBA) {
		for i := 0; i+3 < len(img.Pix); i += 4 {
			img.Pix[i], img.Pix[i+1], img.Pix[i+2] = r, g, b
		}
	}
}

// badge cuts a clear ring and draws a dot at the top right.
func badge(img *image.NRGBA) {
	s := float64(img.Bounds().Dx())
	r := math.Max(2.2, s*0.17)
	cx, cy := s-r, r
	ring := r + math.Max(1, s*0.07)
	for y := 0; y < img.Bounds().Dy(); y++ {
		for x := 0; x < img.Bounds().Dx(); x++ {
			d := math.Hypot(float64(x)+0.5-cx, float64(y)+0.5-cy)
			i := img.PixOffset(x, y)
			switch {
			case d <= r:
				cov := math.Min(1, r-d+0.5)
				img.Pix[i], img.Pix[i+1], img.Pix[i+2] = 0xFF, 0x9F, 0x0A // macOS orange
				img.Pix[i+3] = uint8(math.Max(float64(img.Pix[i+3])*(1-cov), 255*cov))
			case d <= ring:
				img.Pix[i+3] = uint8(float64(img.Pix[i+3]) * math.Min(1, d-ring+0.5) * 0)
			}
		}
	}
}

// encodeICO writes PNG-compressed entries (Vista+), largest last.
func encodeICO(imgs []*image.NRGBA) []byte {
	var pngs [][]byte
	for _, img := range imgs {
		var b bytes.Buffer
		png.Encode(&b, img)
		pngs = append(pngs, b.Bytes())
	}
	var out bytes.Buffer
	binary.Write(&out, binary.LittleEndian, []uint16{0, 1, uint16(len(imgs))})
	offset := 6 + 16*len(imgs)
	for i, img := range imgs {
		w := img.Bounds().Dx()
		dim := byte(w)
		if w >= 256 {
			dim = 0
		}
		out.Write([]byte{dim, dim, 0, 0})
		binary.Write(&out, binary.LittleEndian, []uint16{1, 32})
		binary.Write(&out, binary.LittleEndian, []uint32{uint32(len(pngs[i])), uint32(offset)})
		offset += len(pngs[i])
	}
	for _, p := range pngs {
		out.Write(p)
	}
	return out.Bytes()
}
