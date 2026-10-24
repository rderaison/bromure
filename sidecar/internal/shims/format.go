package shims

import (
	"fmt"
	"math"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// The tmux 3.4 format language (format.c), the subset that makes sense
// here: #{var}, #{@option}, the single-letter aliases, `##` `#,` `#}`
// escapes, #{?cond,a,b}, comparisons (== != < > <= >=), || &&, and the
// modifiers l b d n w q t E T = p m s e and the W/P/S/L loops. #(cmd) is
// empty (tmux runs it in the background and prints "" the first time), #[…]
// is kept as is. Like tmux, an unterminated #{ or a malformed conditional
// ends the expansion there.

// fmtCtx is what a format is expanded against.
type fmtCtx struct {
	r      *tmuxRun
	win    *winView    // nil: no window (a failed CANFAIL target)
	client *clientView // nil: no client (a command-line client has none)
	noSess bool        // no session at all (a failed target)
}

var aliasLetters = map[byte]string{
	'D': "pane_id", 'F': "window_flags", 'H': "host", 'I': "window_index",
	'P': "pane_index", 'S': "session_name", 'T': "pane_title", 'W': "window_name",
	'h': "host_short",
}

func (r *tmuxRun) expand(f string, ctx *fmtCtx) string {
	out, _ := r.expand1(f, ctx, 0)
	return out
}

// expand1 returns the expansion and false when it stopped early.
func (r *tmuxRun) expand1(f string, ctx *fmtCtx, depth int) (string, bool) {
	if depth > 10 {
		return "", false
	}
	var b strings.Builder
	for i := 0; i < len(f); i++ {
		c := f[i]
		if c != '#' || i+1 >= len(f) {
			b.WriteByte(c)
			continue
		}
		i++
		ch := f[i]
		switch ch {
		case '(':
			end := skipParen(f, i+1)
			if end < 0 {
				return b.String(), false
			}
			i = end // #(…) expands to nothing
		case '[':
			b.WriteString("#[")
		case '{':
			end := formatSkip(f[i-1:], "}")
			if end < 0 {
				return b.String(), false
			}
			key := f[i+1 : i-1+end]
			v, ok := r.replace(key, ctx, depth)
			if !ok {
				return b.String(), false
			}
			b.WriteString(v)
			i = i - 1 + end
		case '}', '#', ',':
			b.WriteByte(ch)
		default:
			if name, ok := aliasLetters[ch]; ok {
				v, _ := r.lookup(name, ctx)
				b.WriteString(v)
			} else {
				b.WriteByte('#')
				b.WriteByte(ch)
			}
		}
	}
	return b.String(), true
}

func skipParen(s string, from int) int {
	depth := 1
	for i := from; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// formatSkip is tmux's format_skip: the index of the first byte of end at
// nesting level 0 (counting "#{"), skipping "#," "##" "#{" "#}" "#:".
func formatSkip(s, end string) int {
	brackets := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '#' && i+1 < len(s) && s[i+1] == '{' {
			brackets++
		}
		if s[i] == '#' && i+1 < len(s) && strings.IndexByte(",#{}:", s[i+1]) >= 0 {
			i++
			continue
		}
		if s[i] == '}' {
			brackets--
		}
		if strings.IndexByte(end, s[i]) >= 0 && brackets == 0 {
			return i
		}
	}
	return -1
}

type fmtMod struct {
	name string
	args []string
}

func isModEnd(s string, i int) bool { return i >= len(s) || s[i] == ';' || s[i] == ':' }

// buildModifiers is format_build_modifiers: the modifiers before the
// first ':' and the rest, or ok=false when the key has none.
func (r *tmuxRun) buildModifiers(key string, ctx *fmtCtx, depth int) ([]fmtMod, string, bool) {
	var mods []fmtMod
	i := 0
	for i < len(key) && key[i] != ':' {
		if key[i] == ';' {
			i++
			if i >= len(key) {
				break
			}
		}
		c := key[i]
		if strings.IndexByte("labcdnwETSWPL<>", c) >= 0 && i+1 <= len(key) && isModEnd(key, i+1) {
			mods = append(mods, fmtMod{name: string(c)})
			i++
			continue
		}
		if i+2 <= len(key) {
			two := key[i : i+2]
			if (two == "||" || two == "&&" || two == "!=" || two == "==" || two == "<=" || two == ">=") && isModEnd(key, i+2) {
				mods = append(mods, fmtMod{name: two})
				i += 2
				continue
			}
		}
		if strings.IndexByte("mCNst=peq", c) < 0 {
			break
		}
		if isModEnd(key, i+1) {
			mods = append(mods, fmtMod{name: string(c)})
			i++
			continue
		}
		next := key[i+1]
		if !isPunct(next) || next == '-' {
			end := formatSkip(key[i+1:], ":;")
			if end < 0 {
				break
			}
			v, _ := r.expand1(key[i+1:i+1+end], ctx, depth+1)
			mods = append(mods, fmtMod{name: string(c), args: []string{v}})
			i = i + 1 + end
			continue
		}
		delim := string(next)
		i++ // at the first delimiter
		var args []string
		for {
			if i < len(key) && key[i] == delim[0] && isModEnd(key, i+1) {
				i++
				break
			}
			end := formatSkip(key[i+1:], delim+";:")
			if end < 0 {
				break
			}
			v, _ := r.expand1(key[i+1:i+1+end], ctx, depth+1)
			args = append(args, v)
			i = i + 1 + end
			if isModEnd(key, i) {
				break
			}
		}
		mods = append(mods, fmtMod{name: string(c), args: args})
	}
	if i >= len(key) || key[i] != ':' {
		return nil, key, false
	}
	return mods, key[i+1:], true
}

func isPunct(c byte) bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

func formatTrue(s string) bool { return s != "" && s != "0" }

// choose splits "left,right" at the first top-level comma.
func choose(s string) (string, string, bool) {
	i := formatSkip(s, ",")
	if i < 0 {
		return "", "", false
	}
	return s[:i], s[i+1:], true
}

// replace is format_replace for one #{key}.
func (r *tmuxRun) replace(key string, ctx *fmtCtx, depth int) (string, bool) {
	mods, rest, has := r.buildModifiers(key, ctx, depth)
	if !has {
		rest = key
	}
	var (
		cmp, loop, search, expr                                          *fmtMod
		literal, base, dir, length, width, quote, again, again2, timeStr bool
		limit                                                            int
		limitMarker, padArg                                              string
		hasPad                                                           bool
		subs                                                             []fmtMod
	)
	for k := range mods {
		m := &mods[k]
		switch m.name {
		case "l":
			literal = true
		case "b":
			base = true
		case "d":
			dir = true
		case "n":
			length = true
		case "w":
			width = true
		case "q":
			quote = true
		case "E":
			again = true
		case "T":
			again2 = true
		case "t":
			timeStr = true
		case "S", "W", "P", "L":
			loop = m
		case "m", "C":
			search = m
		case "e":
			expr = m
		case "s":
			if len(m.args) >= 2 {
				subs = append(subs, *m)
			}
		case "=":
			if len(m.args) >= 1 {
				limit, _ = strconv.Atoi(m.args[0])
				if len(m.args) >= 2 {
					limitMarker = m.args[1]
				}
			}
		case "p":
			if len(m.args) >= 1 {
				padArg, hasPad = m.args[0], true
			}
		case "||", "&&", "==", "!=", "<", ">", "<=", ">=":
			cmp = m
		}
	}

	var value string
	switch {
	case literal:
		value = rest
	case loop != nil:
		value = r.loop(loop.name, rest, ctx, depth)
	case search != nil:
		if search.name == "C" {
			value = "0"
			break
		}
		l, rt, ok := choose(rest)
		if !ok {
			return "", false
		}
		pat, _ := r.expand1(l, ctx, depth+1)
		s, _ := r.expand1(rt, ctx, depth+1)
		value = boolStr(matchMod(search.args, pat, s))
	case cmp != nil:
		l, rt, ok := choose(rest)
		if !ok {
			return "", false
		}
		left, _ := r.expand1(l, ctx, depth+1)
		right, _ := r.expand1(rt, ctx, depth+1)
		switch cmp.name {
		case "||":
			value = boolStr(formatTrue(left) || formatTrue(right))
		case "&&":
			value = boolStr(formatTrue(left) && formatTrue(right))
		case "==":
			value = boolStr(left == right)
		case "!=":
			value = boolStr(left != right)
		case "<":
			value = boolStr(left < right)
		case ">":
			value = boolStr(left > right)
		case "<=":
			value = boolStr(left <= right)
		case ">=":
			value = boolStr(left >= right)
		}
	case strings.HasPrefix(rest, "?"):
		ci := formatSkip(rest[1:], ",")
		if ci < 0 {
			return "", false
		}
		cond := rest[1 : 1+ci]
		found, ok := r.lookup(cond, ctx)
		if !ok {
			found, _ = r.expand1(cond, ctx, depth+1)
			if found == cond {
				found = ""
			}
		}
		l, rt, ok := choose(rest[2+ci:])
		if !ok {
			return "", false
		}
		if formatTrue(found) {
			value, _ = r.expand1(l, ctx, depth+1)
		} else {
			value, _ = r.expand1(rt, ctx, depth+1)
		}
	case expr != nil:
		l, rt, ok := choose(rest)
		if !ok {
			return "", false
		}
		left, _ := r.expand1(l, ctx, depth+1)
		right, _ := r.expand1(rt, ctx, depth+1)
		v, ok := arith(expr.args, left, right)
		if !ok {
			return "", false
		}
		value = v
	default:
		v, ok := r.lookup(rest, ctx)
		if !ok {
			v = ""
		}
		value = v
		if timeStr {
			if n, err := strconv.ParseInt(value, 10, 64); err == nil && n != 0 {
				value = time.Unix(n, 0).Format("Mon Jan _2 15:04:05 2006")
			} else {
				value = ""
			}
		}
		if base {
			value = path.Base(value)
		}
		if dir {
			value = path.Dir(value)
		}
	}
	if again {
		value, _ = r.expand1(value, ctx, depth+1)
	}
	if again2 {
		value, _ = r.expand1(strftime(value, time.Now()), ctx, depth+1)
	}
	for _, s := range subs {
		re, err := regexp.Compile(s.args[0])
		if err == nil {
			value = re.ReplaceAllString(value, regexpRepl(s.args[1]))
		}
	}
	if limit > 0 {
		if utf8.RuneCountInString(value) > limit {
			value = string([]rune(value)[:limit]) + limitMarker
		}
	} else if limit < 0 {
		if n := utf8.RuneCountInString(value); n > -limit {
			value = limitMarker + string([]rune(value)[n+limit:])
		}
	}
	if hasPad {
		if n, err := strconv.Atoi(padArg); err == nil {
			w := utf8.RuneCountInString(value)
			if n > 0 && w < n {
				value += strings.Repeat(" ", n-w)
			} else if n < 0 && w < -n {
				value = strings.Repeat(" ", -n-w) + value
			}
		}
	}
	if length || width {
		value = strconv.Itoa(utf8.RuneCountInString(value))
	}
	if quote {
		value = quoteShell(value)
	}
	return value, true
}

func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// regexpRepl turns tmux's \1 back-references into Go's ${1}.
func regexpRepl(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' {
			b.WriteString("${" + string(s[i+1]) + "}")
			i++
			continue
		}
		if s[i] == '$' {
			b.WriteString("$$")
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func matchMod(args []string, pat, s string) bool {
	flags := ""
	if len(args) > 0 {
		flags = args[0]
	}
	if strings.Contains(flags, "r") {
		if strings.Contains(flags, "i") {
			pat = "(?i)" + pat
		}
		re, err := regexp.Compile(pat)
		return err == nil && re.MatchString(s)
	}
	if strings.Contains(flags, "i") {
		pat, s = strings.ToLower(pat), strings.ToLower(s)
	}
	ok, _ := path.Match(pat, s)
	return ok
}

// arith is the e|op[|f[|prec]] modifier.
func arith(args []string, left, right string) (string, bool) {
	if len(args) < 1 {
		return "", false
	}
	op := args[0]
	useFloat := len(args) >= 2 && strings.Contains(args[1], "f")
	prec := 2
	if len(args) >= 3 {
		if p, err := strconv.Atoi(args[2]); err == nil {
			prec = p
		}
	}
	l, err1 := strconv.ParseFloat(strings.TrimSpace(left), 64)
	rv, err2 := strconv.ParseFloat(strings.TrimSpace(right), 64)
	if err1 != nil || err2 != nil {
		return "", false
	}
	if !useFloat {
		l, rv = math.Trunc(l), math.Trunc(rv)
	}
	var res float64
	switch op {
	case "+":
		res = l + rv
	case "-":
		res = l - rv
	case "*":
		res = l * rv
	case "/":
		if rv == 0 {
			return "", false
		}
		res = l / rv
	case "m", "%":
		if rv == 0 {
			return "", false
		}
		res = math.Mod(l, rv)
	case "==":
		res = b2f(l == rv)
	case "!=":
		res = b2f(l != rv)
	case "<":
		res = b2f(l < rv)
	case ">":
		res = b2f(l > rv)
	case "<=":
		res = b2f(l <= rv)
	case ">=":
		res = b2f(l >= rv)
	default:
		return "", false
	}
	if useFloat {
		return strconv.FormatFloat(res, 'f', prec, 64), true
	}
	return strconv.FormatInt(int64(math.Trunc(res)), 10), true
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// quoteShell is the q modifier: a backslash before shell specials.
func quoteShell(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune("|&;<>()$`\\\"'*?[# =%", r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// loop is the S/W/P/L modifiers: the format once per session, window,
// pane or client, concatenated.
func (r *tmuxRun) loop(kind, f string, ctx *fmtCtx, depth int) string {
	var b strings.Builder
	switch kind {
	case "S":
		if ctx.noSess {
			return ""
		}
		v, _ := r.expand1(f, ctx, depth+1)
		b.WriteString(v)
	case "W":
		ws, _ := r.visible()
		for k := range ws {
			v, _ := r.expand1(f, &fmtCtx{r: r, win: r.view(&ws[k]), client: ctx.client}, depth+1)
			b.WriteString(v)
		}
	case "P":
		if ctx.win != nil {
			v, _ := r.expand1(f, ctx, depth+1)
			b.WriteString(v)
		}
	case "L":
		cls, _ := r.clients()
		for k := range cls {
			c := cls[k]
			v, _ := r.expand1(f, &fmtCtx{r: r, win: ctx.win, client: &c}, depth+1)
			b.WriteString(v)
		}
	}
	return b.String()
}

// strftime is the subset of strftime(3) display-message -p applies.
func strftime(s string, t time.Time) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '%' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case '%':
			b.WriteByte('%')
		case 'a':
			b.WriteString(t.Format("Mon"))
		case 'A':
			b.WriteString(t.Format("Monday"))
		case 'b', 'h':
			b.WriteString(t.Format("Jan"))
		case 'B':
			b.WriteString(t.Format("January"))
		case 'c':
			b.WriteString(t.Format("Mon Jan _2 15:04:05 2006"))
		case 'd':
			b.WriteString(t.Format("02"))
		case 'e':
			b.WriteString(t.Format("_2"))
		case 'D':
			b.WriteString(t.Format("01/02/06"))
		case 'F':
			b.WriteString(t.Format("2006-01-02"))
		case 'H':
			b.WriteString(t.Format("15"))
		case 'I':
			b.WriteString(t.Format("03"))
		case 'j':
			fmt.Fprintf(&b, "%03d", t.YearDay())
		case 'k':
			fmt.Fprintf(&b, "%2d", t.Hour())
		case 'l':
			fmt.Fprintf(&b, "%2d", (t.Hour()+11)%12+1)
		case 'm':
			b.WriteString(t.Format("01"))
		case 'M':
			b.WriteString(t.Format("04"))
		case 'n':
			b.WriteByte('\n')
		case 'p':
			b.WriteString(t.Format("PM"))
		case 'R':
			b.WriteString(t.Format("15:04"))
		case 's':
			b.WriteString(strconv.FormatInt(t.Unix(), 10))
		case 'S':
			b.WriteString(t.Format("05"))
		case 't':
			b.WriteByte('\t')
		case 'T':
			b.WriteString(t.Format("15:04:05"))
		case 'u':
			wd := int(t.Weekday())
			if wd == 0 {
				wd = 7
			}
			b.WriteString(strconv.Itoa(wd))
		case 'w':
			b.WriteString(strconv.Itoa(int(t.Weekday())))
		case 'y':
			b.WriteString(t.Format("06"))
		case 'Y':
			b.WriteString(t.Format("2006"))
		case 'z':
			b.WriteString(t.Format("-0700"))
		case 'Z':
			b.WriteString(t.Format("MST"))
		default:
			b.WriteByte('%')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}
