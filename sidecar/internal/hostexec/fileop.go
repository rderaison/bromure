package hostexec

import (
	"archive/tar"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/rderaison/bromure/sidecar/internal/vpath"
)

// ReadMax caps one `read`.
const ReadMax = 8 << 20

// FileOp is bromure-agentd's `_file_op` on this machine. Paths arrive
// virtual; entries go back as names (no paths).
func FileOp(spec map[string]any) map[string]any {
	op, _ := spec["op"].(string)
	vp, _ := spec["path"].(string)
	fail := func(msg string) map[string]any { return map[string]any{"error": msg, "exit_code": 1} }
	if !strings.HasPrefix(vp, "/") {
		return fail("path must be absolute")
	}
	path, err := vpath.Default().ToReal(vp)
	if err != nil {
		return fail(err.Error())
	}
	switch op {
	case "list":
		items, err := os.ReadDir(path)
		if err != nil {
			return fail(errText(err))
		}
		entries := make([]map[string]any, 0, len(items))
		for _, it := range items {
			full := filepath.Join(path, it.Name())
			info, _ := it.Info()
			isLink := it.Type()&os.ModeSymlink != 0
			isDir := it.IsDir()
			if isLink {
				if st, err := os.Stat(full); err == nil {
					isDir = st.IsDir()
				}
			}
			var size, mtime int64
			if info != nil {
				size = info.Size()
				mtime = info.ModTime().Unix()
			}
			if isDir {
				size = 0
			}
			entries = append(entries, map[string]any{"name": it.Name(), "dir": isDir, "link": isLink, "size": size, "mtime": mtime})
		}
		return map[string]any{"entries": entries, "exit_code": 0}
	case "read":
		offset := int64(intOf(spec["offset"], 0))
		length := intOf(spec["length"], ReadMax)
		if length < 0 {
			length = 0
		}
		if length > ReadMax {
			length = ReadMax
		}
		f, err := os.Open(path)
		if err != nil {
			return fail("can't read " + vp)
		}
		defer f.Close()
		st, err := f.Stat()
		if err != nil {
			return fail(errText(err))
		}
		size := st.Size()
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return fail(errText(err))
		}
		buf := make([]byte, length)
		n, err := io.ReadFull(f, buf)
		if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
			return fail(errText(err))
		}
		return map[string]any{"data": base64.StdEncoding.EncodeToString(buf[:n]), "size": size,
			"eof": offset+int64(n) >= size, "exit_code": 0}
	case "write":
		s, _ := spec["data"].(string)
		data, _ := base64.StdEncoding.DecodeString(s)
		if b, _ := spec["append"].(bool); b {
			if f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0); err == nil {
				defer f.Close()
				if _, err := f.Write(data); err != nil {
					return fail(errText(err))
				}
				return map[string]any{"exit_code": 0}
			}
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return fail(errText(err))
		}
		return map[string]any{"exit_code": 0}
	case "mkdir":
		if err := os.MkdirAll(path, 0o755); err != nil {
			return fail(errText(err))
		}
		return map[string]any{"exit_code": 0}
	case "untar":
		va, _ := spec["archive"].(string)
		if !strings.HasPrefix(va, "/") {
			return fail("archive must be absolute")
		}
		archive, err := vpath.Default().ToReal(va)
		if err != nil {
			return fail(err.Error())
		}
		defer os.Remove(archive)
		if err := os.MkdirAll(path, 0o755); err != nil {
			return fail(errText(err))
		}
		if err := Untar(archive, path); err != nil {
			return fail(err.Error())
		}
		return map[string]any{"exit_code": 0}
	case "remove":
		st, err := os.Lstat(path)
		if err != nil {
			return fail(errText(err))
		}
		if st.IsDir() {
			err = os.RemoveAll(path)
		} else {
			err = os.Remove(path)
		}
		if err != nil {
			return fail(errText(err))
		}
		return map[string]any{"exit_code": 0}
	}
	return fail("unknown file op " + op)
}

// Untar extracts archive into dest, refusing what bsdtar refuses by
// default: absolute names and `..` (and links pointing out of dest).
func Untar(archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	return UntarReader(f, dest)
}

// UntarReader is Untar from a stream.
func UntarReader(r io.Reader, dest string) error {
	dest, _ = filepath.Abs(dest)
	tr := tar.NewReader(r)
	inside := func(name string) (string, error) {
		clean := filepath.FromSlash(strings.TrimPrefix(name, "./"))
		if clean == "" || clean == "." {
			return dest, nil
		}
		if filepath.IsAbs(clean) || strings.HasPrefix(name, "/") || filepath.VolumeName(clean) != "" {
			return "", fmt.Errorf("refusing absolute name %q", name)
		}
		for _, part := range strings.Split(filepath.ToSlash(clean), "/") {
			if part == ".." {
				return "", fmt.Errorf("refusing %q (..)", name)
			}
		}
		return filepath.Join(dest, clean), nil
	}
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		target, err := inside(h.Name)
		if err != nil {
			return err
		}
		mode := os.FileMode(h.Mode).Perm()
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if mode == 0 {
				mode = 0o644
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode|0o200)
			if err != nil {
				return err
			}
			_, err = io.Copy(out, tr)
			out.Close()
			if err != nil {
				return err
			}
			_ = os.Chtimes(target, h.ModTime, h.ModTime)
		case tar.TypeSymlink:
			// A link out of dest is refused; on Windows a symlink needs
			// Developer Mode — skipped when the OS says no.
			linkTarget := h.Linkname
			resolved := linkTarget
			if !filepath.IsAbs(filepath.FromSlash(linkTarget)) {
				resolved = filepath.Join(filepath.Dir(target), filepath.FromSlash(linkTarget))
			}
			if rel, err := filepath.Rel(dest, resolved); err != nil || strings.HasPrefix(rel, "..") {
				return fmt.Errorf("refusing link %q → %q", h.Name, linkTarget)
			}
			_ = os.MkdirAll(filepath.Dir(target), 0o755)
			_ = os.Remove(target)
			_ = os.Symlink(filepath.FromSlash(linkTarget), target)
		case tar.TypeLink:
			src, err := inside(h.Linkname)
			if err != nil {
				return err
			}
			_ = os.MkdirAll(filepath.Dir(target), 0o755)
			if err := os.Link(src, target); err != nil {
				if err := copyFile(src, target); err != nil {
					return err
				}
			}
		default:
			// Devices, fifos: not on this machine.
		}
	}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func errText(err error) string {
	var pe *os.PathError
	if errors.As(err, &pe) {
		// Never leak the real (Windows) path: name the operation and why.
		return pe.Op + ": " + pe.Err.Error()
	}
	return err.Error()
}

func intOf(v any, def int) int {
	if n, ok := number(v); ok {
		return int(n)
	}
	return def
}
