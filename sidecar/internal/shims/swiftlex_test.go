package shims

import (
	"regexp"
	"strings"
)

// A small Swift lexer for the contract test: it finds string literals
// ("…", """…""", #"…"#), skips comments, decodes escapes, replaces each
// \(…) interpolation with a placeholder, and joins literals chained with
// `+` (a non-literal operand in the chain becomes a placeholder too) — the
// client builds its shell commands that way.

type swiftLit struct {
	line  int
	text  string
	multi bool // a """ literal: its body starts on the next line
}

// lineOf is the source line of byte at in text.
func (l swiftLit) lineOf(text string, at int) int {
	if !l.multi {
		return l.line
	}
	return l.line + 1 + strings.Count(text[:at], "\n") + strings.Count(text[:at], lostLine)
}

// lostLine marks a source line break the decoded text no longer has (a
// `\` line continuation, a multi-line interpolation), so positions stay
// exact; the shell tokenizer ignores it.
const lostLine = "\x01"

// interpolationPlaceholder stands for \(expr): a number for the names the
// client uses for indices and sizes, else a word that can't be a flag.
var numericNames = regexp.MustCompile(`^(w|i|idx|index|window|windowIndex|tabIndex|c|r|n|since|count|lines|limit|pid|cols|rows|width|height|floorColumns|floorRows|timeout|seconds)$`)

func placeholder(expr string) string {
	e := strings.TrimSpace(expr)
	if numericNames.MatchString(e) {
		return "0"
	}
	return "X"
}

type swiftLexer struct {
	src  string
	i    int
	line int
}

func lexSwift(src string) []swiftLit {
	src = strings.ReplaceAll(src, crlf, "\n")
	lx := &swiftLexer{src: src, line: 1}
	var out []swiftLit
	for lx.i < len(lx.src) {
		c := lx.src[lx.i]
		switch {
		case c == '\n':
			lx.line++
			lx.i++
		case strings.HasPrefix(lx.src[lx.i:], "//"):
			for lx.i < len(lx.src) && lx.src[lx.i] != '\n' {
				lx.i++
			}
		case strings.HasPrefix(lx.src[lx.i:], "/*"):
			lx.skipBlockComment()
		case c == '"' || (c == '#' && lx.rawStart()):
			line := lx.line
			multi := strings.HasPrefix(strings.TrimLeft(lx.src[lx.i:], "#"), `"""`)
			text := lx.literal()
			text += lx.chain()
			out = append(out, swiftLit{line: line, text: text, multi: multi})
		default:
			lx.i++
		}
	}
	return out
}

func (lx *swiftLexer) rawStart() bool {
	j := lx.i
	for j < len(lx.src) && lx.src[j] == '#' {
		j++
	}
	return j < len(lx.src) && lx.src[j] == '"'
}

func (lx *swiftLexer) skipBlockComment() {
	depth := 0
	for lx.i < len(lx.src) {
		switch {
		case strings.HasPrefix(lx.src[lx.i:], "/*"):
			depth++
			lx.i += 2
		case strings.HasPrefix(lx.src[lx.i:], "*/"):
			depth--
			lx.i += 2
			if depth == 0 {
				return
			}
		default:
			if lx.src[lx.i] == '\n' {
				lx.line++
			}
			lx.i++
		}
	}
}

// literal reads one string literal at lx.i and returns its value.
func (lx *swiftLexer) literal() string {
	hashes := 0
	for lx.src[lx.i] == '#' {
		hashes++
		lx.i++
	}
	closeSeq := `"` + strings.Repeat("#", hashes)
	if strings.HasPrefix(lx.src[lx.i:], `"""`) {
		lx.i += 3
		closeML := `"""` + strings.Repeat("#", hashes)
		// content starts after the newline
		for lx.i < len(lx.src) && lx.src[lx.i] != '\n' {
			lx.i++
		}
		lx.i++
		lx.line++
		start := lx.i
		end := -1
		for j := start; j < len(lx.src); j++ {
			if lx.src[j] == '\\' && j+1 < len(lx.src) && hashes == 0 {
				if lx.src[j+1] == '(' {
					j = skipInterp(lx.src, j+2) - 1
				} else {
					j++
				}
				continue
			}
			if strings.HasPrefix(lx.src[j:], closeML) {
				// the closing delimiter is alone on its line
				k := j - 1
				for k >= start && (lx.src[k] == ' ' || lx.src[k] == '\t') {
					k--
				}
				if k < start || lx.src[k] == '\n' {
					end = j
					break
				}
			}
		}
		if end < 0 {
			lx.i = len(lx.src)
			return ""
		}
		lineStart := strings.LastIndexByte(lx.src[:end], '\n') + 1
		indent := lx.src[lineStart:end]
		body := lx.src[start:lineStart]
		lx.line += strings.Count(lx.src[start:end], "\n")
		lx.i = end + len(closeML)
		var lines []string
		for _, l := range strings.SplitAfter(body, "\n") {
			lines = append(lines, strings.TrimPrefix(l, indent))
		}
		raw := strings.Join(lines, "")
		raw = strings.TrimSuffix(raw, "\n")
		return decodeSwift(raw, hashes, true)
	}
	lx.i++ // opening quote
	start := lx.i
	for lx.i < len(lx.src) {
		c := lx.src[lx.i]
		if c == '\n' {
			break // unterminated: stop at the line
		}
		esc := "\\" + strings.Repeat("#", hashes)
		if strings.HasPrefix(lx.src[lx.i:], esc) {
			k := lx.i + len(esc)
			if k < len(lx.src) && lx.src[k] == '(' {
				lx.i = skipInterp(lx.src, k+1)
				continue
			}
			lx.i = k + 1
			continue
		}
		if strings.HasPrefix(lx.src[lx.i:], closeSeq) {
			raw := lx.src[start:lx.i]
			lx.i += len(closeSeq)
			return decodeSwift(raw, hashes, false)
		}
		lx.i++
	}
	return decodeSwift(lx.src[start:lx.i], hashes, false)
}

// skipInterp returns the index after the ')' closing an interpolation
// whose '(' is just before from (nested parens and string literals).
func skipInterp(s string, from int) int {
	depth := 1
	for j := from; j < len(s); j++ {
		switch s[j] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return j + 1
			}
		case '"':
			// a nested literal: skip to its end
			k := j + 1
			for k < len(s) && s[k] != '"' && s[k] != '\n' {
				if s[k] == '\\' {
					k++
				}
				k++
			}
			j = k
		}
	}
	return len(s)
}

func decodeSwift(raw string, hashes int, multi bool) string {
	esc := "\\" + strings.Repeat("#", hashes)
	var b strings.Builder
	for i := 0; i < len(raw); {
		if !strings.HasPrefix(raw[i:], esc) {
			b.WriteByte(raw[i])
			i++
			continue
		}
		k := i + len(esc)
		if k >= len(raw) {
			break
		}
		switch raw[k] {
		case '(':
			end := skipInterp(raw, k+1)
			b.WriteString(placeholder(raw[k+1 : end-1]))
			b.WriteString(strings.Repeat(lostLine, strings.Count(raw[k+1:end-1], "\n")))
			i = end
			continue
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case '0':
			b.WriteByte(0)
		case '\\':
			b.WriteByte('\\')
		case '"':
			b.WriteByte('"')
		case '\'':
			b.WriteByte('\'')
		case '\n':
			if multi { // line continuation
				b.WriteString(lostLine)
				i = k + 1
				continue
			}
		case 'u':
			if k+1 < len(raw) && raw[k+1] == '{' {
				end := strings.IndexByte(raw[k:], '}')
				if end > 0 {
					var r rune
					for _, h := range raw[k+2 : k+end] {
						r = r*16 + rune(hexVal(byte(h)))
					}
					b.WriteRune(r)
					i = k + end + 1
					continue
				}
			}
		default:
			b.WriteByte(raw[k])
		}
		i = k + 1
	}
	return b.String()
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return 0
}

// chain consumes `+ "literal"` / `+ operand` continuations after a
// literal and returns what they add.
func (lx *swiftLexer) chain() string {
	var b strings.Builder
	for {
		j, lines := skipSpace(lx.src, lx.i)
		if j >= len(lx.src) || lx.src[j] != '+' || (j+1 < len(lx.src) && lx.src[j+1] == '=') {
			return b.String()
		}
		j++
		j2, lines2 := skipSpace(lx.src, j)
		lx.line += lines + lines2
		lx.i = j2
		if lx.i >= len(lx.src) {
			return b.String()
		}
		if lx.src[lx.i] == '"' || (lx.src[lx.i] == '#' && lx.rawStart()) {
			b.WriteString(lx.literal())
			continue
		}
		// a non-literal operand: an identifier chain with calls/subscripts
		start := lx.i
		for lx.i < len(lx.src) {
			c := lx.src[lx.i]
			if c == '_' || c == '.' || c == '?' || c == '!' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
				lx.i++
				continue
			}
			if c == '(' || c == '[' {
				lx.i = skipBalanced(lx.src, lx.i, &lx.line)
				continue
			}
			break
		}
		if lx.i == start {
			return b.String()
		}
		b.WriteString(placeholder(lx.src[start:lx.i]))
	}
}

func skipSpace(s string, i int) (int, int) {
	lines := 0
	for i < len(s) {
		switch {
		case s[i] == '\n':
			lines++
			i++
		case s[i] == ' ' || s[i] == '\t' || s[i] == '\r':
			i++
		case strings.HasPrefix(s[i:], "//"):
			for i < len(s) && s[i] != '\n' {
				i++
			}
		default:
			return i, lines
		}
	}
	return i, lines
}

func skipBalanced(s string, i int, line *int) int {
	open := s[i]
	close := byte(')')
	if open == '[' {
		close = ']'
	}
	depth := 0
	for ; i < len(s); i++ {
		switch s[i] {
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i + 1
			}
		case '\n':
			*line++
		case '"':
			k := i + 1
			for k < len(s) && s[k] != '"' && s[k] != '\n' {
				if s[k] == '\\' {
					k++
				}
				k++
			}
			i = k
		}
	}
	return len(s)
}

// --- shell side -------------------------------------------------------------

// stripShellComments drops `# …` comments (a # starting a word, outside
// quotes, not a tmux #{…}).
func stripShellComments(s string) string {
	var b strings.Builder
	inS, inD := false, false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\n':
			inS, inD = false, false
		case inS:
			if c == '\'' {
				inS = false
			}
		case inD:
			if c == '\\' && i+1 < len(s) {
				b.WriteByte(c)
				i++
				c = s[i]
			} else if c == '"' {
				inD = false
			}
		case c == '\'':
			inS = true
		case c == '"':
			inD = true
		case c == '#' && (i == 0 || s[i-1] == ' ' || s[i-1] == '\t' || s[i-1] == '\n') && (i+1 >= len(s) || s[i+1] != '{'):
			for i < len(s) && s[i] != '\n' {
				i++
			}
			if i < len(s) {
				b.WriteByte('\n')
			}
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}

// shellWords tokenizes a simple command starting at s[i] up to its end
// (; | & ) newline), expanding quotes; $… expansions become "1"; a
// redirection and its target are dropped.
func shellWords(s string, i int) []string {
	var words []string
	var cur strings.Builder
	have := false
	flush := func() {
		if have {
			words = append(words, cur.String())
		}
		cur.Reset()
		have = false
	}
	for i < len(s) {
		c := s[i]
		switch {
		case c == lostLine[0]:
			i++
		case c == ' ' || c == '\t':
			flush()
			i++
		case c == '\n' || c == ';' || c == '|' || c == '&' || c == ')' || c == '`':
			flush()
			return words
		case c == '}' && !have:
			return words
		case c == '>' || c == '<':
			// drop an fd number just before, the operator, and the target
			if have && isDigits(cur.String()) {
				cur.Reset()
				have = false
			}
			flush()
			i++
			for i < len(s) && (s[i] == '>' || s[i] == '&') {
				i++
			}
			for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
				i++
			}
			for i < len(s) && strings.IndexByte(" \t\n;|&)", s[i]) < 0 {
				i++
			}
		case c == '\\':
			if i+1 < len(s) {
				if s[i+1] != '\n' {
					cur.WriteByte(s[i+1])
					have = true
				}
				i += 2
			} else {
				i++
			}
		case c == '\'':
			end := strings.IndexByte(s[i+1:], '\'')
			if end < 0 {
				cur.WriteString(s[i+1:])
				i = len(s)
			} else {
				cur.WriteString(s[i+1 : i+1+end])
				i += end + 2
			}
			have = true
		case c == '"':
			i++
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i+1 < len(s) && strings.IndexByte("\"\\$`\n", s[i+1]) >= 0 {
					cur.WriteByte(s[i+1])
					i += 2
					continue
				}
				if s[i] == '$' {
					i = skipDollar(s, i)
					cur.WriteString("1")
					continue
				}
				cur.WriteByte(s[i])
				i++
			}
			i++
			have = true
		case c == '$':
			if strings.HasPrefix(s[i:], "$'") {
				end := strings.IndexByte(s[i+2:], '\'')
				if end < 0 {
					end = len(s) - i - 2
				}
				cur.WriteString(ansiC(s[i+2 : i+2+end]))
				i += end + 3
			} else {
				i = skipDollar(s, i)
				cur.WriteString("1")
			}
			have = true
		default:
			cur.WriteByte(c)
			have = true
			i++
		}
	}
	flush()
	return words
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// skipDollar returns the index after a $ expansion at s[i].
func skipDollar(s string, i int) int {
	i++
	if i >= len(s) {
		return i
	}
	switch s[i] {
	case '(':
		depth := 0
		for ; i < len(s); i++ {
			if s[i] == '(' {
				depth++
			} else if s[i] == ')' {
				depth--
				if depth == 0 {
					return i + 1
				}
			}
		}
		return i
	case '{':
		end := strings.IndexByte(s[i:], '}')
		if end < 0 {
			return len(s)
		}
		return i + end + 1
	}
	if strings.IndexByte("$#?!@*-0123456789", s[i]) >= 0 {
		return i + 1
	}
	for i < len(s) && (s[i] == '_' || (s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= '0' && s[i] <= '9')) {
		i++
	}
	return i
}

func ansiC(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'e', 'E':
			b.WriteByte(27)
		case '0', '1', '2', '3':
			n := 0
			k := 0
			for k < 3 && i < len(s) && s[i] >= '0' && s[i] <= '7' {
				n = n*8 + int(s[i]-'0')
				i++
				k++
			}
			i--
			b.WriteByte(byte(n))
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// commandWord finds `word` used as a command (a whole word) in s; it
// returns the index just after it and a space.
var shellCmdBoundary = " \t\n(;|&{`!"

func commandPositions(s, word string) []int {
	var out []int
	for i := 0; ; {
		k := strings.Index(s[i:], word+" ")
		if k < 0 {
			return out
		}
		at := i + k
		i = at + len(word)
		if at > 0 && strings.IndexByte(shellCmdBoundary, s[at-1]) < 0 {
			continue
		}
		out = append(out, at+len(word)+1)
	}
}

// crlf is a Windows line ending (sources checked out with autocrlf).
const crlf = string(rune(13)) + string(rune(10))
