package sessions

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rderaison/bromure/sidecar/internal/agents"
	"github.com/rderaison/bromure/sidecar/internal/hostexec"
	"github.com/rderaison/bromure/sidecar/internal/logx"
	"github.com/rderaison/bromure/sidecar/internal/paths"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/vpath"
	"github.com/rderaison/bromure/sidecar/internal/worktrees"
)

// StartRequest starts an agent in a new window.
type StartRequest struct {
	Tool        string
	Cwd         string // virtual (or "~")
	CloneURL    string
	Message     string
	Attachments []map[string]any
	ExtraArgs   []string
}

func validTool(t string) bool {
	for _, x := range agents.Tools {
		if x == t {
			return true
		}
	}
	return false
}

// Start starts an agent; its session id and window index.
func (e *Engine) Start(req StartRequest) (string, int, error) {
	if !validTool(req.Tool) {
		return "", 0, bad("unknown agent %s", req.Tool)
	}
	if spec, ok := agents.Get(req.Tool); ok && agents.IsKnownMissing(req.Tool) {
		if spec.Unavailable != "" {
			return "", 0, bad("%s: %s.", spec.Name, spec.Unavailable)
		}
		return "", 0, bad("%s isn't installed on this machine. Install it from Agents in the Bromure Sidecar menu.", spec.Name)
	}
	m := vpath.Default()
	real, err := m.ToReal(req.Cwd)
	if err != nil {
		return "", 0, bad("%s", err.Error())
	}
	dir, err := m.ToVirtual(real)
	if err != nil {
		return "", 0, bad("%s", err.Error())
	}
	if err := vpath.CheckCwd(dir); err != nil {
		return "", 0, bad("%s: %s", dir, err.Error())
	}
	if req.CloneURL == "" {
		if st, err := os.Stat(real); err != nil || !st.IsDir() {
			return "", 0, bad("No folder %s on this machine", dir)
		}
	} else {
		_ = os.MkdirAll(real, 0o755)
	}
	message := req.Message
	if staged := Stage(req.Attachments); len(staged) > 0 {
		if message != "" {
			message += "\n\n"
		}
		message += strings.Join(staged, "\n")
	}
	id := NewUUID()
	title := Title(message, req.Tool, dir)
	var msg *string
	if message != "" {
		msg = &message
	}
	ls, err := Launch(req.Tool, msg, nil, req.CloneURL, req.ExtraArgs)
	if err != nil {
		return "", 0, err
	}
	idx, err := e.newWindow(dir, req.Tool, ls, map[string]string{OptDisplay: title, OptSession: id})
	if err != nil {
		return "", 0, failed("Couldn't open a window: %v", err)
	}
	s := Session{ID: id, ProfileID: e.HostID, Tool: req.Tool, Title: title, Cwd: dir, CreatedAt: *Now()}
	if req.CloneURL != "" {
		s.CloneURL = ptr(req.CloneURL)
	}
	if req.Message != "" {
		s.OpeningMessage = ptr(req.Message)
	}
	s.WindowIndex = ptr(idx)
	s.LaunchingSince = Now()
	s.LaunchDisplay = ptr(title)
	e.put(s)
	logx.Printf("sessions: started %s %s in window %d (%s)", req.Tool, id, idx, dir)
	return id, idx, nil
}

// Command runs one verb on a session (`POST /agent-sessions/:id/<verb>`).
func (e *Engine) Command(id, action string, body map[string]any) (map[string]any, error) {
	s, ok := e.Session(id)
	if !ok {
		return nil, notFound("unknown session")
	}
	id = s.ID
	live := s.WindowIndex
	ok200 := map[string]any{"ok": true}
	switch action {
	case "resume":
		message := strOf(body["message"])
		if live != nil {
			if message != "" {
				go e.Type(*live, message)
			}
		} else {
			var msg *string
			if message != "" {
				msg = &message
			}
			resume := str(s.AgentTranscriptID)
			ls, err := Launch(s.Tool, msg, &resume, "", nil)
			if err != nil {
				return nil, err
			}
			idx, err := e.newWindow(s.Cwd, s.Tool, ls, map[string]string{OptDisplay: s.Title, OptSession: s.ID})
			if err != nil {
				return nil, failed("Couldn't open a window: %v", err)
			}
			s.WindowIndex = ptr(idx)
			s.LaunchDisplay = ptr(s.Title)
			s.LaunchingSince = Now()
			s.ResumedAt = Now()
			s.EndedAt = nil
		}
		s.ArchivedAt = nil
	case "send":
		text := strOf(body["text"])
		if text == "" {
			return nil, bad("text required")
		}
		if live == nil {
			return e.Command(id, "resume", map[string]any{"message": text})
		}
		go e.Type(*live, text)
	case "keys":
		keys := strList(body["keys"])
		if live == nil || len(keys) == 0 || len(keys) > 12 {
			return nil, bad("keys required on a live session")
		}
		go e.SendKeys(*live, keys)
	case "close":
		if live != nil {
			e.killWindow(*live)
		}
		s.WindowIndex = nil
		s.AgentAlive = ptr(false)
		s.EndedAt = Now()
	case "archive":
		if live != nil {
			e.killWindow(*live)
		}
		s.WindowIndex = nil
		s.AgentAlive = ptr(false)
		if s.EndedAt == nil {
			s.EndedAt = Now()
		}
		s.ArchivedAt = Now()
	case "unarchive":
		s.ArchivedAt = nil
	case "delete":
		if live != nil {
			e.killWindow(*live)
		}
		s.WindowIndex = nil
		s.DeletedAt = Now()
	case "forget":
		if live != nil {
			e.killWindow(*live)
		}
		e.mu.Lock()
		kept := e.sessions[:0]
		for _, x := range e.sessions {
			if x.ID != id {
				kept = append(kept, x)
			}
		}
		e.sessions = kept
		e.saveLocked()
		e.mu.Unlock()
		e.notify()
		return ok200, nil
	case "rename":
		t := strings.TrimSpace(strOf(body["title"]))
		if t == "" {
			return nil, bad("title required")
		}
		s.Title = t
		s.UserTitled = ptr(true)
		// The tab is known by this name from now on: a client checks
		// launchDisplay against the tab's @display before it types.
		s.LaunchDisplay = ptr(t)
		if live != nil {
			e.setOption(*live, OptDisplay, t)
		}
	case "worktree":
		name := strings.TrimSpace(strOf(body["name"]))
		if name == "" {
			words := strings.Fields(strOf(body["message"]))
			if len(words) > 6 {
				words = words[:6]
			}
			name = "branch"
			if len(words) > 0 {
				name = strings.Join(words, " ")
			}
		}
		tool := strOf(body["tool"])
		if tool == "" {
			tool = s.Tool
		}
		initGit, _ := body["initGit"].(bool)
		nid, idx, err := e.StartWorktree(s, name, tool, strOf(body["message"]), initGit, strOf(body["base"]))
		if err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "id": nid, "window": idx}, nil
	case "branch-request":
		if s.WorktreeBranch == nil {
			return nil, bad("not a branch session")
		}
		if m := s.BranchMerge; m != nil && (m.Phase == "merging" || m.Phase == "conflicts") {
			return nil, bad("a merge is already under way")
		}
		target := strOf(body["into"])
		if target == "" {
			target = str(s.BranchParent)
		}
		if target == "" {
			target = "main"
		}
		if b := worktrees.UnsafeBranch(str(s.WorktreeBranch), target); b != "" {
			return nil, bad("%s", unsafeBranchWhy(b))
		}
		squash, _ := body["squash"].(bool)
		var asked *string
		if a := ParseUUID(strOf(body["askedBy"])); a != "" {
			asked = &a
		}
		s.BranchMerge = &BranchMerge{Target: target, Squash: squash, RemoveAfter: true, StartedAt: *Now(), Phase: "requested", AskedBy: asked}
	case "branch-merge":
		if s.WorktreeBranch == nil {
			return nil, bad("not a branch session")
		}
		into := strOf(body["into"])
		if into == "" && s.BranchMerge != nil {
			into = s.BranchMerge.Target
		}
		if into == "" {
			into = str(s.BranchParent)
		}
		if into == "" {
			into = "main"
		}
		if b := worktrees.UnsafeBranch(str(s.WorktreeBranch), into); b != "" {
			return nil, bad("%s", unsafeBranchWhy(b))
		}
		squash, _ := body["squash"].(bool)
		removeAfter := true
		if v, ok := body["removeAfter"].(bool); ok {
			removeAfter = v
		}
		var asked *string
		if s.BranchMerge != nil {
			asked = s.BranchMerge.AskedBy
		}
		s.BranchMerge = &BranchMerge{Target: into, Squash: squash, RemoveAfter: removeAfter, StartedAt: *Now(), Phase: "merging", AskedBy: asked}
		snap := clone(s)
		go e.merge(snap)
	case "branch-decline":
		m := s.BranchMerge
		if m == nil || m.Phase != "requested" {
			return ok200, nil
		}
		s.BranchMerge = nil
		asker := s
		if m.AskedBy != nil {
			if a, ok := e.Session(*m.AskedBy); ok {
				asker = a
			}
		}
		msg := "The user declined merging '" + str(s.WorktreeBranch) + "' into '" + m.Target + "' for now. Don't ask again unless they bring it up."
		go e.Command(asker.ID, "resume", map[string]any{"message": msg})
	case "branch-pr":
		if s.WorktreeBranch == nil {
			return nil, bad("not a branch session")
		}
		into := strOf(body["into"])
		if into == "" {
			into = str(s.BranchParent)
		}
		if into == "" {
			into = "main"
		}
		if b := worktrees.UnsafeBranch(*s.WorktreeBranch, into); b != "" {
			return nil, bad("%s", unsafeBranchWhy(b))
		}
		msg := worktrees.PullRequestPrompt(*s.WorktreeBranch, into)
		go e.Command(id, "resume", map[string]any{"message": msg})
	case "branch-discard":
		if s.WorktreeBranch == nil {
			return nil, bad("not a branch session")
		}
		if live != nil {
			e.killWindow(*live)
		}
		if s.BranchRoot != nil {
			root, branch := *s.BranchRoot, *s.WorktreeBranch
			go worktrees.Remove(root, branch)
		}
		s.WindowIndex = nil
		s.DeletedAt = Now()
	case "branch-keep":
		return ok200, nil
	case "review":
		switch strOf(body["op"]) {
		case "add":
			text := strings.TrimSpace(strOf(body["text"]))
			if text == "" {
				return nil, bad("text required")
			}
			c := ReviewComment{ID: NewUUID(), Text: text, CreatedAt: *Now()}
			if f, ok := body["file"].(string); ok {
				c.File = &f
			}
			if l, ok := body["line"].(float64); ok {
				c.Line = ptr(int(l))
			}
			s.ReviewComments = append(s.ReviewComments, c)
		case "remove":
			cid := ParseUUID(strOf(body["comment"]))
			if cid == "" {
				return nil, bad("comment required")
			}
			kept := []ReviewComment{}
			for _, c := range s.ReviewComments {
				if c.ID != cid {
					kept = append(kept, c)
				}
			}
			s.ReviewComments = kept
			if len(kept) == 0 {
				s.ReviewComments = nil
			}
		case "viewed":
			p, ok := body["path"].(string)
			if !ok {
				return nil, bad("path required")
			}
			v := map[string]string{}
			for k, x := range s.ReviewViewed {
				v[k] = x
			}
			if fp, ok := body["fingerprint"].(string); ok {
				v[p] = fp
			} else {
				delete(v, p)
			}
			s.ReviewViewed = v
			if len(v) == 0 {
				s.ReviewViewed = nil
			}
		case "send":
			var drafts []ReviewComment
			for _, c := range s.ReviewComments {
				if c.SentAt == nil {
					drafts = append(drafts, c)
				}
			}
			if len(drafts) == 0 {
				return map[string]any{"ok": true, "sent": 0}, nil
			}
			now := Now()
			for i := range s.ReviewComments {
				if s.ReviewComments[i].SentAt == nil {
					s.ReviewComments[i].SentAt = now
				}
			}
			e.put(s)
			message := ReviewMessage(drafts)
			go e.Command(id, "resume", map[string]any{"message": message})
			return map[string]any{"ok": true, "sent": len(drafts)}, nil
		default:
			return nil, bad("op must be add, remove, viewed or send")
		}
	case "signin":
		st, err := agents.StartLogin(s.Tool)
		return st, loginErr(err)
	case "signin-state":
		return agents.LoginState(s.Tool), nil
	case "signin-code":
		st, err := agents.SubmitCode(s.Tool, strOf(body["code"]))
		return st, loginErr(err)
	case "signin-cancel":
		agents.Cancel(s.Tool, "")
		return agents.LoginState(s.Tool), nil
	case "restart":
		if live != nil {
			e.killWindow(*live)
		}
		transcript := str(s.AgentTranscriptID)
		var msg, resume *string
		if transcript != "" {
			resume = &transcript
		} else {
			msg = s.OpeningMessage
		}
		ls, err := Launch(s.Tool, msg, resume, "", nil)
		if err != nil {
			return nil, err
		}
		idx, err := e.newWindow(s.Cwd, s.Tool, ls, map[string]string{OptDisplay: s.Title, OptSession: s.ID})
		if err != nil {
			return nil, failed("Couldn't open a window: %v", err)
		}
		s.WindowIndex = ptr(idx)
		s.LaunchingSince = Now()
		s.ResumedAt = Now()
		s.EndedAt = nil
		s.ArchivedAt = nil
		s.LaunchDisplay = ptr(s.Title)
	case "delegation-link":
		if p := ParseUUID(strOf(body["parentSessionID"])); p != "" {
			s.ParentSessionID = &p
		} else {
			s.ParentSessionID = nil
		}
		if d := ParseUUID(strOf(body["delegationID"])); d != "" {
			s.DelegationID = &d
		} else {
			s.DelegationID = nil
		}
	case "nickname":
		n := strings.Trim(strings.TrimSpace(strOf(body["nickname"])), "@")
		if n == "" {
			s.Nickname = nil
		} else {
			s.Nickname = &n
		}
	default:
		return nil, notSupported("%s isn't available on a native machine", action)
	}
	e.put(s)
	return ok200, nil
}

func loginErr(err error) error {
	if err == nil {
		return nil
	}
	if le, ok := err.(*agents.LoginError); ok {
		return &Error{le.Status, le.Message}
	}
	return failed("%v", err)
}

func unsafeBranchWhy(name string) string {
	return "“" + name + "” isn't a plain branch name — git would read it as an option. Rename the branch, then retry."
}

// ReviewMessage is Bromure AC's AgentSessionEngine.reviewMessage, word for word.
func ReviewMessage(comments []ReviewComment) string {
	lines := []string{"Review comments on your changes — address each one, then reply briefly with what you changed:"}
	if len(comments) == 1 {
		lines[0] = "A review comment on your changes — address it, then reply briefly with what you changed:"
	}
	lines = append(lines, "")
	for i, c := range comments {
		at := ""
		switch {
		case c.File != nil && c.Line != nil:
			at = "`" + *c.File + "` line " + strconv.Itoa(*c.Line) + ": "
		case c.File != nil:
			at = "`" + *c.File + "`: "
		}
		lines = append(lines, strconv.Itoa(i+1)+". "+at+c.Text)
	}
	return strings.Join(lines, "\n")
}

// Stage writes files dropped on a client's new-session screen ({name,
// data, folder?}) to ~/.bromure/drops; their virtual paths.
func Stage(attachments []map[string]any) []string {
	if len(attachments) == 0 {
		return nil
	}
	_ = os.MkdirAll(paths.DropsDir(), 0o755)
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	var out []string
	for i, a := range attachments {
		name := filepath.Base(strings.ReplaceAll(strOf(a["name"]), `\`, "/"))
		if name == "" || name == "." || name == "/" {
			continue
		}
		data, err := base64.StdEncoding.DecodeString(strOf(a["data"]))
		if err != nil {
			continue
		}
		fname := stamp + "_" + strconv.Itoa(i) + "_" + name
		dest := filepath.Join(paths.DropsDir(), fname)
		if folder, _ := a["folder"].(bool); folder {
			tar := dest + ".tar"
			if os.WriteFile(tar, data, 0o600) != nil {
				continue
			}
			_ = os.MkdirAll(dest, 0o755)
			_ = hostexec.Untar(tar, dest)
			os.Remove(tar)
		} else if os.WriteFile(dest, data, 0o644) != nil {
			continue
		}
		out = append(out, vpath.GuestHome+"/.bromure/drops/"+fname)
	}
	return out
}

// Transcript is the session's transcript (Claude's JSONL tail, 24 MB):
// the path its hook reported, else its conversation or the newest in the
// folder's project directory.
func (e *Engine) Transcript(id string) ([]byte, bool) {
	s, ok := e.Session(id)
	if !ok {
		return nil, false
	}
	p := ""
	if s.TranscriptPath != nil {
		if r, err := vpath.Default().ToReal(*s.TranscriptPath); err == nil {
			p = r
		}
	}
	if _, err := os.Stat(p); p == "" || err != nil {
		real, _ := vpath.Default().ToReal(s.Cwd)
		dir := filepath.Join(paths.Home(), ".claude", "projects", ClaudeProjectDir(real))
		p = ""
		if s.AgentTranscriptID != nil {
			c := filepath.Join(dir, *s.AgentTranscriptID+".jsonl")
			if _, err := os.Stat(c); err == nil {
				p = c
			}
		}
		if p == "" {
			p = newest(dir, ".jsonl")
		}
	}
	if p == "" {
		return nil, false
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	st, _ := f.Stat()
	const capBytes = 24 << 20
	if st.Size() > capBytes {
		_, _ = f.Seek(st.Size()-capBytes, 0)
	}
	data := make([]byte, 0, min64(st.Size(), capBytes))
	buf := make([]byte, 1<<20)
	for {
		n, err := f.Read(buf)
		data = append(data, buf[:n]...)
		if err != nil {
			break
		}
	}
	return data, true
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

// ClaudeProjectDir is how Claude Code names a folder's project directory:
// every character outside [a-zA-Z0-9] becomes '-' (per UTF-16 unit, as its
// JavaScript does) — C:\Users\me\src\x → C--Users-me-src-x.
func ClaudeProjectDir(real string) string {
	var b strings.Builder
	for _, r := range real {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else if r > 0xffff {
			b.WriteString("--")
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

// newest is the most recently modified file with ext in dir.
func newest(dir, ext string) string {
	items, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	best, bestT := "", time.Time{}
	for _, it := range items {
		if it.IsDir() || !strings.HasSuffix(it.Name(), ext) {
			continue
		}
		info, err := it.Info()
		if err != nil {
			continue
		}
		if best == "" || info.ModTime().After(bestT) {
			best, bestT = filepath.Join(dir, it.Name()), info.ModTime()
		}
	}
	return best
}

// --- branches --------------------------------------------------------------

// StartWorktree starts a session on a new branch of parent's folder.
func (e *Engine) StartWorktree(parent Session, name, tool, message string, initGit bool, base string) (string, int, error) {
	if !validTool(tool) {
		return "", 0, bad("unknown agent %s", tool)
	}
	made, err := worktrees.Make(parent.Cwd, name, initGit, base, tool)
	if err != nil {
		if we, ok := err.(*worktrees.Error); ok {
			return "", 0, &Error{we.Status, we.Message}
		}
		return "", 0, failed("%v", err)
	}
	id := NewUUID()
	var msg *string
	if message != "" {
		msg = &message
	}
	ls, err := Launch(tool, msg, nil, "", nil)
	if err != nil {
		return "", 0, err
	}
	idx, err := e.newWindow(made.Dir, tool, ls, map[string]string{
		OptDisplay: name, OptSession: id, OptWorktree: made.Branch, OptParentBranch: made.Parent, OptRootRepo: made.Root,
	})
	if err != nil {
		return "", 0, failed("Couldn't open a window: %v", err)
	}
	s := Session{ID: id, ProfileID: e.HostID, Tool: tool, Title: name, Cwd: made.Dir, CreatedAt: *Now()}
	s.OpeningMessage = msg
	s.WindowIndex = ptr(idx)
	s.LaunchingSince = Now()
	s.LaunchDisplay = ptr(name)
	s.UserTitled = ptr(true)
	s.WorktreeOf = ptr(parent.ID)
	s.WorktreeBranch = ptr(made.Branch)
	s.BranchParent = ptr(made.Parent)
	s.BranchRoot = ptr(made.Root)
	e.put(s)
	logx.Printf("sessions: branch %s of “%s” → window %d", made.Branch, parent.Title, idx)
	return id, idx, nil
}

// OpenBranch is the Branches window's "Open in a session".
func (e *Engine) OpenBranch(dir, branch, parent, root, display, tool string) (string, int, error) {
	if !worktrees.IsWorktreeDir(dir) {
		return "", 0, bad("Not a Bromure worktree")
	}
	id, idx, err := e.Start(StartRequest{Tool: tool, Cwd: dir})
	if err != nil {
		return "", 0, err
	}
	name := display
	if name == "" {
		name = branch
	}
	for _, kv := range [][2]string{{OptWorktree, branch}, {OptParentBranch, parent}, {OptRootRepo, root}, {OptDisplay, name}} {
		if kv[1] != "" {
			e.setOption(idx, kv[0], kv[1])
		}
	}
	e.update(id, func(s *Session) {
		s.Title = name
		s.LaunchDisplay = ptr(name)
		s.UserTitled = ptr(true)
		s.WorktreeBranch = ptr(branch)
		s.BranchParent = nil
		if parent != "" {
			s.BranchParent = ptr(parent)
		}
		s.BranchRoot = nil
		if root != "" {
			s.BranchRoot = ptr(root)
		}
	})
	return id, idx, nil
}

// DiscardWorktree is the Branches window's "Discard".
func (e *Engine) DiscardWorktree(root, branch, session string) {
	if session != "" {
		if s, ok := e.Session(session); ok && str(s.WorktreeBranch) == branch {
			_, _ = e.Command(session, "branch-discard", map[string]any{})
			return
		}
	}
	if root == "" || !strings.HasPrefix(branch, "wt/") {
		return
	}
	worktrees.Remove(root, branch)
	logx.Printf("sessions: discarded left-behind %s", branch)
}

// merge is the merge the user asked for: on its own when the branch is
// clean, else the session's agent finishes it.
func (e *Engine) merge(s Session) {
	if s.WorktreeBranch == nil || s.BranchRoot == nil || s.BranchMerge == nil {
		return
	}
	m := s.BranchMerge
	outcome := worktrees.TryMerge(*s.BranchRoot, *s.WorktreeBranch, m.Target, s.Cwd, m.Squash)
	logx.Printf("sessions: merge %s → %s: %s", *s.WorktreeBranch, m.Target, outcome)
	if outcome == worktrees.Merged {
		e.landed(s.ID)
		return
	}
	e.update(s.ID, func(x *Session) {
		if x.BranchMerge != nil {
			x.BranchMerge.Phase = "conflicts"
		}
	})
	_, _ = e.Command(s.ID, "resume", map[string]any{"message": worktrees.MergePrompt(*s.WorktreeBranch, m.Target, m.Squash, outcome)})
}

// landed: tell whoever asked, and tidy up as asked.
func (e *Engine) landed(id string) {
	s, ok := e.Session(id)
	if !ok || s.BranchMerge == nil {
		return
	}
	m := *s.BranchMerge
	e.update(id, func(x *Session) {
		if x.BranchMerge != nil {
			x.BranchMerge.Phase = "merged"
		}
		x.BranchInfo = nil
	})
	if m.AskedBy != nil && *m.AskedBy != id {
		if _, ok := e.Session(*m.AskedBy); ok {
			_, _ = e.Command(*m.AskedBy, "resume", map[string]any{"message": "'" + str(s.WorktreeBranch) + "' (session “" + s.Title + "”) is merged into '" + m.Target + "'."})
		}
	}
	if !m.RemoveAfter || s.WorktreeBranch == nil || s.BranchRoot == nil {
		return
	}
	if s.WindowIndex != nil {
		e.killWindow(*s.WindowIndex)
	}
	worktrees.Remove(*s.BranchRoot, *s.WorktreeBranch)
	e.update(id, func(x *Session) {
		x.WindowIndex = nil
		x.AgentAlive = ptr(false)
		x.FolderMissing = ptr(true)
		if x.EndedAt == nil {
			x.EndedAt = Now()
		}
		x.ArchivedAt = Now()
	})
}

// BranchLoop: every 5 s merges finishing; every 20 s each open branch's
// ahead / behind / uncommitted counts.
func (e *Engine) BranchLoop(stop <-chan struct{}) {
	tick := 0
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		tick++
		e.mu.Lock()
		all := append([]Session{}, e.sessions...)
		e.mu.Unlock()
		for _, s := range all {
			if s.WorktreeBranch == nil || s.BranchRoot == nil || s.DeletedAt != nil {
				continue
			}
			if m := s.BranchMerge; m != nil && (m.Phase == "merging" || m.Phase == "conflicts") {
				if worktrees.Landed(*s.BranchRoot, *s.WorktreeBranch, m.Target, m.Squash) {
					e.landed(s.ID)
				} else if time.Since(m.StartedAt.Time) > 30*time.Minute {
					e.update(s.ID, func(x *Session) {
						if x.BranchMerge != nil {
							x.BranchMerge.Phase = "failed"
							x.BranchMerge.Detail = ptr("The merge hasn't landed after 30 minutes — ask the agent where it stands.")
						}
					})
				}
				continue
			}
			if tick%4 != 0 || (s.BranchMerge != nil && s.BranchMerge.Phase == "merged") || (s.FolderMissing != nil && *s.FolderMissing) {
				continue
			}
			if p := worktrees.ProbeBranch(s.Cwd, str(s.BranchParent)); p != nil {
				info := &BranchInfo{Ahead: p.Ahead, Behind: p.Behind, Changed: p.Changed, CheckedAt: *Now()}
				e.update(s.ID, func(x *Session) {
					o := x.BranchInfo
					if o == nil || o.Ahead != info.Ahead || o.Behind != info.Behind || o.Changed != info.Changed {
						x.BranchInfo = info
					}
					if x.BranchRoot == nil {
						x.BranchRoot = ptr(p.Root)
					}
					if x.BranchParent == nil {
						x.BranchParent = ptr(p.Parent)
					}
				})
			} else if real, err := vpath.Default().ToReal(s.Cwd); err == nil {
				if _, err := os.Stat(real); os.IsNotExist(err) {
					e.update(s.ID, func(x *Session) { x.FolderMissing = ptr(true) })
				}
			}
		}
	}
}

// --- approvals -------------------------------------------------------------

func approvalsLevel(tool string) string {
	v := settings.String(settings.ApprovalPrefix+tool, "")
	switch v {
	case "ask", "auto", "full":
		return v
	}
	return "ask"
}

// SetApprovals saves a level for a tool.
func SetApprovals(tool, level string) error {
	switch level {
	case "ask", "auto", "full":
	default:
		return bad("level must be ask, auto or full")
	}
	if tool == "omp" && level == "auto" {
		return bad("Oh My Pi has no middle mode")
	}
	return settings.Set(settings.ApprovalPrefix+tool, level)
}

// ApprovalFlags are the flags after the agent's command.
func ApprovalFlags(tool string) []string {
	switch level := approvalsLevel(tool); {
	case level == "ask":
		return nil
	case tool == "claude" && level == "auto":
		return []string{"--permission-mode", "auto"}
	case tool == "claude" && level == "full":
		return []string{"--dangerously-skip-permissions"}
	case tool == "grok" && level == "auto":
		return []string{"--permission-mode", "auto"}
	case tool == "grok" && level == "full":
		return []string{"--always-approve"}
	case tool == "kimi" && level == "auto":
		return []string{"--yolo"}
	case tool == "kimi" && level == "full":
		return []string{"--auto"}
	case tool == "omp" && level == "full":
		return []string{"--auto-approve"}
	}
	return nil
}

// CodexOverrides are Codex's approval settings as -c overrides.
func CodexOverrides() [][2]string {
	switch approvalsLevel("codex") {
	case "auto":
		return [][2]string{{"approval_policy", "never"}, {"sandbox_mode", "workspace-write"}}
	case "full":
		return [][2]string{{"approval_policy", "never"}, {"sandbox_mode", "danger-full-access"}}
	}
	return nil
}

// --- helpers ---------------------------------------------------------------

func strOf(v any) string {
	s, _ := v.(string)
	return s
}

func strList(v any) []string {
	arr, _ := v.([]any)
	out := []string{}
	for _, x := range arr {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

var _ = sort.Strings
