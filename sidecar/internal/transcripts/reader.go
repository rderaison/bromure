// Package transcripts serves `POST /vms/:id/transcript-chunk` (hostAPI 2):
// it finds the transcript an agent window is writing and returns a chunk of
// it in the format Bromure AC's beautified view already parses
// (BeautifiedSessionView.swift):
//
//	<path>\n<pending-question line or empty>\n<size>\n<start>\n<end>\n<bytes…>
//
// It replaces the python3 heredoc reader (CodingTasks.swift
// transcriptReaderPython) and the shell locator, neither of which can run
// under Git Bash: no python3, and the agents' Windows store encodings.
package transcripts

import (
	"bytes"
	"io"
	"os"
	"strconv"
	"unicode/utf8"
)

// TailJumpFactor: a tail read more than this many windows behind the file
// starts over from a fresh window at the end.
const TailJumpFactor = 4

const blk = 1 << 16

// Chunk is the reader's answer for one file.
type Chunk struct {
	Size, Start, End int64
	Bytes            []byte
}

// Read is transcriptReaderPython in Go, decision for decision: file f, the
// path the client holds (known), its offset, the window size and the mode
// ("tail", or "earlier"/"from" for the bytes before off). ok false when
// the file can't be read (the python exited 0 with no output then).
func Read(f, known string, off, want int64, mode string) (Chunk, bool) {
	fh, err := os.Open(f)
	if err != nil {
		return Chunk{}, false
	}
	defer fh.Close()
	st, err := fh.Stat()
	if err != nil {
		return Chunk{}, false
	}
	size := st.Size()
	if want < 1 {
		want = 1
	}
	r := &reader{fh: fh}
	var start, end int64
	if mode == "earlier" || mode == "from" {
		end = clamp(off, 0, size)
		s0 := end - want
		if s0 < 0 {
			s0 = 0
		}
		start = 0
		if s0 > 0 {
			if nx, ok := r.nextLine(s0, end); ok && nx < end {
				start = nx
			} else {
				start, _ = r.lineStart(maxI(end-1, 0), -1)
			}
		}
	} else {
		fresh := f != known || off < 0 || off > size || (size-off) > want*TailJumpFactor
		if fresh {
			s0 := size - want
			if s0 < 0 {
				s0 = 0
			}
			start = 0
			if s0 > 0 {
				if ls, ok := r.lineStart(s0, want); ok {
					start = ls
				} else {
					we := r.wholeEnd(s0, size)
					if nx, ok := r.nextLine(s0, we); ok && nx < we {
						start = nx
					} else {
						start, _ = r.lineStart(s0, -1)
					}
				}
			}
		} else {
			start = off
		}
		end = r.wholeEnd(start, size)
	}
	if end < start {
		end = start
	}
	buf := make([]byte, end-start)
	n, _ := fh.ReadAt(buf, start)
	return Chunk{Size: size, Start: start, End: end, Bytes: buf[:n]}, true
}

type reader struct{ fh *os.File }

func (r *reader) read(p, n int64) []byte {
	b := make([]byte, n)
	m, err := r.fh.ReadAt(b, p)
	if err != nil && err != io.EOF {
		return b[:m]
	}
	return b[:m]
}

// lineStart is the start of the line holding byte pos; ok false when it
// begins more than limit bytes back (limit < 0: no bound).
func (r *reader) lineStart(pos, limit int64) (int64, bool) {
	p := pos
	floor := int64(0)
	if limit >= 0 {
		floor = maxI(0, pos-limit)
	}
	for p > floor {
		q := maxI(floor, p-blk)
		b := r.read(q, p-q)
		if j := bytes.LastIndexByte(b, '\n'); j >= 0 {
			return q + int64(j) + 1, true
		}
		p = q
	}
	if floor == 0 {
		return 0, true
	}
	return 0, false
}

// nextLine is the offset just past the first newline in [pos, end).
func (r *reader) nextLine(pos, end int64) (int64, bool) {
	p := pos
	for p < end {
		b := r.read(p, minI(blk, end-p))
		if len(b) == 0 {
			break
		}
		if j := bytes.IndexByte(b, '\n'); j >= 0 {
			return p + int64(j) + 1, true
		}
		p += int64(len(b))
	}
	return 0, false
}

// wholeEnd is the offset just past the last newline in [start, end).
func (r *reader) wholeEnd(start, end int64) int64 {
	p := end
	for p > start {
		q := maxI(start, p-blk)
		b := r.read(q, p-q)
		if j := bytes.LastIndexByte(b, '\n'); j >= 0 {
			return q + int64(j) + 1
		}
		p = q
	}
	return start
}

func clamp(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
func minI(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// Sanitize drops invalid UTF-8 bytes, as `iconv -f UTF-8 -t UTF-8 -c`.
func Sanitize(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	out := make([]byte, 0, len(b))
	for len(b) > 0 {
		r, n := utf8.DecodeRune(b)
		if r == utf8.RuneError && n <= 1 {
			b = b[1:]
			continue
		}
		out = append(out, b[:n]...)
		b = b[n:]
	}
	return out
}

// Format is the wire body: path, pq, then the reader's header and bytes;
// UTF-8-sanitized as a whole. A missing file yields only path and pq lines
// (what the shell printed when python found nothing).
func Format(virtualPath, pq string, c Chunk, ok bool) []byte {
	var b bytes.Buffer
	b.WriteString(virtualPath)
	b.WriteByte('\n')
	b.WriteString(pq)
	b.WriteByte('\n')
	if ok {
		b.WriteString(strconv.FormatInt(c.Size, 10) + "\n" + strconv.FormatInt(c.Start, 10) + "\n" + strconv.FormatInt(c.End, 10) + "\n")
		b.Write(c.Bytes)
	}
	return Sanitize(b.Bytes())
}
