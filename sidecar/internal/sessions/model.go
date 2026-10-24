// Package sessions owns the agent sessions and keeps them bound to pane
// host windows (Sessions.swift). A window we open carries
// `@bromure_session = <id>`, so a binding survives index reuse and daemon
// restarts (the pane host outlives the daemon). An agent the user starts by
// hand in a window is adopted the same way.
package sessions

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Time is a date as Bromure AC's JSONDecoder(.iso8601) reads it: whole
// seconds, UTC, "2006-01-02T15:04:05Z" (fractional seconds don't decode).
type Time struct{ time.Time }

const isoLayout = "2006-01-02T15:04:05Z"

func Now() *Time { return &Time{time.Now().UTC().Truncate(time.Second)} }

func (t Time) MarshalJSON() ([]byte, error) {
	return json.Marshal(t.UTC().Format(isoLayout))
}

func (t *Time) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	for _, layout := range []string{isoLayout, time.RFC3339Nano, time.RFC3339} {
		if v, err := time.Parse(layout, s); err == nil {
			t.Time = v.UTC()
			return nil
		}
	}
	return fmt.Errorf("bad date %q", s)
}

// Since is the elapsed time since t (0 for nil).
func Since(t *Time) time.Duration {
	if t == nil {
		return 0
	}
	return time.Since(t.Time)
}

// NewUUID is an uppercase RFC 4122 v4 UUID (Foundation's uuidString).
func NewUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

// ParseUUID normalises a UUID string (Foundation's UUID(uuidString:)
// accepts either case); "" when it isn't one.
func ParseUUID(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	if len(s) != 36 {
		return ""
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return ""
			}
		default:
			if !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
				return ""
			}
		}
	}
	return s
}

// Session is an agent session as a fat client decodes it (`AgentSession`,
// JSON with ISO-8601 dates): the same keys, the subset this host fills
// in. Unknown extras (transcriptPath) are ignored by the client. Paths
// (cwd, branchRoot) are virtual.
type Session struct {
	ID                string            `json:"id"`
	ProfileID         string            `json:"profileID"`
	Tool              string            `json:"tool"`
	Title             string            `json:"title"`
	Cwd               string            `json:"cwd"`
	CloneURL          *string           `json:"cloneURL,omitempty"`
	OpeningMessage    *string           `json:"openingMessage,omitempty"`
	CreatedAt         Time              `json:"createdAt"`
	WindowIndex       *int              `json:"windowIndex,omitempty"`
	LaunchingSince    *Time             `json:"launchingSince,omitempty"`
	EndedAt           *Time             `json:"endedAt,omitempty"`
	LastSeenAt        *Time             `json:"lastSeenAt,omitempty"`
	AgentSeenAt       *Time             `json:"agentSeenAt,omitempty"`
	AgentAlive        *bool             `json:"agentAlive,omitempty"`
	ResumedAt         *Time             `json:"resumedAt,omitempty"`
	UserTitled        *bool             `json:"userTitled,omitempty"`
	LaunchDisplay     *string           `json:"launchDisplay,omitempty"`
	ArchivedAt        *Time             `json:"archivedAt,omitempty"`
	DeletedAt         *Time             `json:"deletedAt,omitempty"`
	Nickname          *string           `json:"nickname,omitempty"`
	AgentTranscriptID *string           `json:"agentTranscriptID,omitempty"`
	ParentSessionID   *string           `json:"parentSessionID,omitempty"`
	DelegationID      *string           `json:"delegationID,omitempty"`
	WorktreeOf        *string           `json:"worktreeOf,omitempty"`
	WorktreeBranch    *string           `json:"worktreeBranch,omitempty"`
	BranchParent      *string           `json:"branchParent,omitempty"`
	BranchRoot        *string           `json:"branchRoot,omitempty"`
	BranchInfo        *BranchInfo       `json:"branchInfo,omitempty"`
	BranchMerge       *BranchMerge      `json:"branchMerge,omitempty"`
	FolderMissing     *bool             `json:"folderMissing,omitempty"`
	ReviewComments    []ReviewComment   `json:"reviewComments,omitempty"`
	ReviewViewed      map[string]string `json:"reviewViewed,omitempty"`
	// The transcript the agent's hook last reported (host-only, virtual).
	TranscriptPath *string `json:"transcriptPath,omitempty"`
}

type BranchInfo struct {
	Ahead     int  `json:"ahead"`
	Behind    int  `json:"behind"`
	Changed   int  `json:"changed"`
	CheckedAt Time `json:"checkedAt"`
}

type BranchMerge struct {
	Target      string  `json:"target"`
	Squash      bool    `json:"squash"`
	RemoveAfter bool    `json:"removeAfter"`
	StartedAt   Time    `json:"startedAt"`
	Phase       string  `json:"phase"` // requested / merging / conflicts / merged / failed
	Detail      *string `json:"detail,omitempty"`
	AskedBy     *string `json:"askedBy,omitempty"`
}

// ReviewComment is Bromure AC's ReviewComment, over the wire.
type ReviewComment struct {
	ID        string  `json:"id"`
	Text      string  `json:"text"`
	File      *string `json:"file,omitempty"`
	Line      *int    `json:"line,omitempty"`
	CreatedAt Time    `json:"createdAt"`
	SentAt    *Time   `json:"sentAt,omitempty"`
}

func ptr[T any](v T) *T { return &v }

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func clone(s Session) Session {
	data, _ := json.Marshal(s)
	var out Session
	_ = json.Unmarshal(data, &out)
	return out
}

func equal(a, b Session) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// Error is a failed command with its HTTP status.
type Error struct {
	Status  int
	Message string
}

func (e *Error) Error() string { return e.Message }

func bad(format string, a ...any) *Error {
	return &Error{400, fmt.Sprintf(format, a...)}
}
func notFound(format string, a ...any) *Error {
	return &Error{404, fmt.Sprintf(format, a...)}
}
func failed(format string, a ...any) *Error {
	return &Error{500, fmt.Sprintf(format, a...)}
}
func notSupported(format string, a ...any) *Error {
	return &Error{501, fmt.Sprintf(format, a...)}
}
