// Guest-side shell command builders for the chat view: locate an agent's
// transcript in the VM and read it incrementally, and type into its tmux
// pane through the guarded-send machinery. A port of (Sources/AgentCoding/)
// CodingTasks.swift — AgentSessionLocator, TranscriptPin,
// CodingTaskEngine.transcriptChunkCommand, TranscriptChunkReader,
// AgentPaneProbe, PaneTarget, PaneTypeGuard — plus ChatQueueStore.Outcome.of,
// AgentSessionEngine.isForeignConversation and TranscriptFetch.parse
// (BeautifiedSessionView.swift). Every string the guest runs is
// byte-identical to the Swift builders' output.

// MARK: - Constants

/** BeautifiedSessionModel.initialHistoryBytes: the first read's window (24 MB). */
export const INITIAL_HISTORY_BYTES = 24_000_000;
/** BeautifiedSessionModel.earlierHistoryBytes: what "load earlier" adds. */
export const EARLIER_HISTORY_BYTES = Math.max(4_096, Math.floor(INITIAL_HISTORY_BYTES / 3));
/** BeautifiedSessionModel.historyBudget: the size past which the head is trimmed. */
export const HISTORY_BUDGET = INITIAL_HISTORY_BYTES + Math.floor((INITIAL_HISTORY_BYTES * 2) / 3);
/** The fat client's historyBytesHint: window for both tail and earlier reads over a remote link. */
export const FAT_CLIENT_HISTORY_BYTES_HINT = 1_500_000;
/** TranscriptChunkReader.tailJumpFactor: a tail read this many windows behind restarts at the end. */
export const TAIL_JUMP_FACTOR = 4;

// MARK: - Small helpers

/** Single-quoted for sh (CodingTaskEngine.shellQuote / PaneTypeGuard.quote). */
export function shellQuote(s: string): string {
  return "'" + s.split("'").join("'\\''") + "'";
}

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** What Foundation's UUID(uuidString:) accepts. */
function isUUIDString(s: string): boolean {
  return UUID_RE.test(s);
}

/** Trims spaces and tabs only (Swift's CharacterSet.whitespaces). */
function trimWhitespaces(s: string): string {
  return s.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, '');
}

/** Swift's Int(String): optional sign then decimal digits, nothing else. */
function parseSwiftInt(s: string): number | null {
  return /^[+-]?[0-9]+$/.test(s) ? parseInt(s, 10) : null;
}

/** UTF-8 bytes of `s`, base64 (Data(s.utf8).base64EncodedString()). */
function base64UTF8(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function utf8Length(s: string): number {
  return new TextEncoder().encode(s).length;
}

// MARK: - TranscriptPin

/** What ties a read to ONE conversation when the agent's store is keyed by folder or date. */
export interface TranscriptPin {
  /** Kimi's "session_<uuid>": read that session's journal, nothing else. */
  kimiSession?: string;
  /** Epoch seconds: a Kimi journal begun before this is another conversation's. */
  kimiCreatedSince?: number;
  /** Kimi sessions other sessions on the machine own: never this tab's. */
  kimiExclude?: string[];
  /** Grok's session uuid: that conversation only. */
  grokSession?: string;
  /** Codex's conversation uuid: that rollout only. */
  codexSession?: string;
  /** omp's session uuid: that file only. */
  ompSession?: string;
  /** Hermes's session id (its hook's mirror): that file, in whichever folder. */
  hermesSession?: string;
  /** Grok / Codex / omp conversations (lowercased uuids) other sessions own. */
  foreignConversations?: string[];
}

/** TranscriptPin.conversation(tool:id:): the pin a session's own conversation id gives. */
export function transcriptPinForConversation(tool: string, id: string | null | undefined): TranscriptPin {
  const p: TranscriptPin = {};
  if (id == null) return p;
  switch (tool) {
    case 'kimi': if (isKimiSessionID(id)) p.kimiSession = id; break;
    case 'grok': if (isConversationUUID(id)) p.grokSession = id; break;
    case 'codex': if (isConversationUUID(id)) p.codexSession = id; break;
    case 'omp': if (isConversationUUID(id)) p.ompSession = id; break;
    case 'hermes': if (isHermesSessionID(id)) p.hermesSession = id; break;
  }
  return p;
}

/** TranscriptPin.kimiUnpinned: a Kimi tab whose session isn't pinned yet. */
export function kimiUnpinnedPin(argsSession: string | null | undefined, resumed: boolean,
                                since: number, exclude: string[]): TranscriptPin {
  const p: TranscriptPin = {};
  if (argsSession != null && isKimiSessionID(argsSession)) {
    p.kimiSession = argsSession;
    return p;
  }
  p.kimiExclude = exclude.filter(isKimiSessionID);
  if (!resumed && since > 0) p.kimiCreatedSince = since - 2;
  return p;
}

// MARK: - AgentSessionLocator

/** The epoch a `find -newermt @<epoch>` floor is written as (never before 1970-01-02). */
export function findEpoch(since: number): number {
  return Math.max(since, 86_400);
}

const SANITIZE_ALLOWED = new Set(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./+ ');
const SANITIZE_UNSAFE = /[\p{Cc}\p{Cf}\p{Cn}\p{Cs}\u0085\u2028\u2029]/u;

/** The cwd as it may be spliced between quotes: trailing slashes stripped, null when unquotable. */
export function sanitizedGuestCwd(guestCwd: string): string | null {
  let path = guestCwd;
  while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  if (path.length === 0) return null;
  for (const ch of path) {
    const cp = ch.codePointAt(0)!;
    if (cp < 0x80 ? !SANITIZE_ALLOWED.has(ch) : SANITIZE_UNSAFE.test(ch)) return null;
  }
  return path;
}

/** A Hermes session id: [A-Za-z0-9][A-Za-z0-9_.-]{5,127}, no "..". */
export function isHermesSessionID(s: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9_.-]{5,127}$/.test(s) && !s.includes('..');
}

/** A Kimi session id ("session_<uuid>"). */
export function isKimiSessionID(s: string): boolean {
  return s.startsWith('session_') && s.length === 44 && isUUIDString(s.slice(8));
}

/** A conversation id as Grok/Codex/omp/Claude name their files: a canonical UUID. */
export function isConversationUUID(s: string): boolean {
  return s.length === 36 && isUUIDString(s);
}

/** The Kimi session id in a journal's path, null when none. */
export function kimiSessionIDInPath(path: string): string | null {
  return path.split('/').filter((c) => c.length > 0).find(isKimiSessionID) ?? null;
}

/** Where the Hermes hook mirrors sessions (a shell word, $HOME-relative). */
export const HERMES_TRANSCRIPT_ROOT = '$HOME/.hermes/bromure-transcripts';

/** RFC 3986 percent-encoding with an empty safe set (Grok's session-folder rule). */
export function grokPercentEncode(s: string): string {
  try {
    return encodeURIComponent(s).replace(/[!'()*]/g,
      (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  } catch {
    return s;
  }
}

/** Kimi Code's slugifyWorkDirName: lowercased, runs outside [a-z0-9._-] → "-", trimmed, ≤40. */
export function kimiWorkDirSlug(name: string): string {
  let out = '';
  let inRun = false;
  for (const ch of name.toLowerCase()) {
    const v = ch.codePointAt(0)!;
    const keep = (v >= 0x61 && v <= 0x7a) || (v >= 0x30 && v <= 0x39) || ch === '.' || ch === '_' || ch === '-';
    if (keep) { out += ch; inRun = false; } else if (!inRun) { out += '-'; inRun = true; }
  }
  const trimDashes = (s: string) => s.replace(/^-+/, '').replace(/-+$/, '');
  const slug = trimDashes(trimDashes(out).slice(0, 40));
  return slug === '' || slug === '.' || slug === '..' ? 'workspace' : slug;
}

/** CodingTaskEngine.kimiSlug: a worktree slug as Kimi names its workspace bucket. */
export const kimiSlug = kimiWorkDirSlug;

/** Claude Code store fragment: newest ~/.claude/projects/<enc cwd>/*.jsonl into `varName`. */
export function claudeFragment(path: string, since: number, varName: string): string {
  const enc1 = path.replaceAll('/', '-');
  const enc2 = path.replaceAll('.', '-').replaceAll('/', '-');
  const legacy = (enc1 === enc2 ? [enc1] : [enc1, enc2])
    .map((e) => "\"$HOME/.claude/projects/" + e + "\"").join(' ');
  return "e1=$(printf %s \"$d\" | tr -c 'a-zA-Z0-9' '-'); "
    + "e2=$(printf %s \"$r\" | tr -c 'a-zA-Z0-9' '-'); "
    + varName + "=$(find \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
    + legacy + " -maxdepth 1 -name '*.jsonl' -newermt @" + findEpoch(since) + " "
    + "2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null | head -1); ";
}

/** Hermes store fragment: newest mirrored <root>/<enc cwd>/*.jsonl into `varName`. */
export function hermesFragment(since: number, varName: string): string {
  return "h1=$(printf %s \"$d\" | tr -c 'a-zA-Z0-9' '-'); "
    + "h2=$(printf %s \"$r\" | tr -c 'a-zA-Z0-9' '-'); "
    + varName + "=$(find \"" + HERMES_TRANSCRIPT_ROOT + "/$h1\" \"" + HERMES_TRANSCRIPT_ROOT + "/$h2\" "
    + "-maxdepth 1 -name '*.jsonl' -newermt @" + findEpoch(since) + " "
    + "2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null | head -1); ";
}

/** Codex store fragment: newest rollout whose session_meta names the cwd into `varName`. */
export function codexFragment(since: number, varName: string): string {
  return varName + "=\"\"; for c in $(find \"$HOME/.codex/sessions\" "
    + "-name 'rollout-*.jsonl' -newermt @" + findEpoch(since) + " 2>/dev/null "
    + "| xargs -r ls -t 2>/dev/null | head -24); do "
    + "head -c 8192 \"$c\" 2>/dev/null "
    + "| grep -qF -e \"\\\"cwd\\\":\\\"$d\\\"\" -e \"\\\"cwd\\\":\\\"$r\\\"\" "
    + "&& { " + varName + "=\"$c\"; break; }; done; ";
}

/** Grok store fragment: newest ~/.grok/sessions/<pct cwd>/<uuid>/updates.jsonl into `varName`. */
export function grokFragment(path: string, since: number, varName: string): string {
  return "g1=\"$HOME/.grok/sessions/" + grokPercentEncode(path) + "\"; g2=\"\"; "
    + "if [ \"$r\" != \"$d\" ]; then "
    + "ge=$(python3 -c 'import urllib.parse,sys;"
    + "print(urllib.parse.quote(sys.argv[1],safe=\"\"))' \"$r\" 2>/dev/null); "
    + "[ -n \"$ge\" ] && g2=\"$HOME/.grok/sessions/$ge\"; fi; "
    + varName + "=$(find \"$g1\" ${g2:+\"$g2\"} -maxdepth 2 -name updates.jsonl "
    + "-newermt @" + findEpoch(since) + " 2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null "
    + "| head -1); ";
}

/** `$kb`/`$kh`/`$kr`: Kimi's workspace-bucket slug and hashes for `$d`/`$r`. */
export const KIMI_BUCKET_VARS =
  "kb=$(basename \"$d\" | LC_ALL=C tr 'A-Z' 'a-z' "
  + "| LC_ALL=C sed -E 's/[^a-z0-9._-]+/-/g;s/^-+//;s/-+$//' "
  + "| cut -c1-40 | sed -E 's/-+$//'); "
  + "case \"$kb\" in ''|.|..) kb=workspace;; esac; "
  + "kh=$(printf %s \"$d\" | sha256sum | cut -c1-12); "
  + "kr=$(printf %s \"$r\" | sha256sum | cut -c1-12); ";

/** A pipeline stage dropping the journals of the given Kimi sessions; "" for none. */
export function kimiExcludeFilter(ids: string[]): string {
  const safe = ids.filter(isKimiSessionID);
  if (safe.length === 0) return '';
  return ' | grep -v -F ' + safe.map((id) => "-e '/" + id + "/'").join(' ');
}

function kimiCandidates(since: number): string {
  return "find \"$HOME/.kimi-code/sessions/wd_${kb}_$kh\" "
    + "\"$HOME/.kimi-code/sessions/wd_${kb}_$kr\" "
    + "\"$HOME/.kimi-code/sessions/wd_${kb}_\"* "
    + "\\( -path '*/agents/main/wire.jsonl' "
    + "-o \\( -name wire.jsonl ! -path '*/agents/*' \\) \\) "
    + "-newermt @" + findEpoch(since) + " 2>/dev/null | sort -u "
    + "| xargs -r ls -t 2>/dev/null";
}

/** Kimi store fragment: the bucket's newest main journal (begun since `createdSince`) into `varName`. */
export function kimiFragment(since: number, varName: string, createdSince?: number | null,
                             exclude: string[] = []): string {
  let pick: string;
  const candidates = kimiCandidates(since) + kimiExcludeFilter(exclude);
  if (createdSince != null) {
    pick = "kc=$(" + candidates + "); " + varName + "=\"\"; "
      + "for c in $kc; do ca=$(head -c 1024 \"$c\" 2>/dev/null "
      + "| grep -o '\"created_at\":[0-9]*' | head -1 | cut -d: -f2); "
      + "if [ -z \"$ca\" ] || [ \"$ca\" -ge " + Math.max(0, createdSince) * 1000 + " ]; then "
      + varName + "=\"$c\"; break; fi; done; ";
  } else {
    pick = varName + "=$(" + candidates + " | head -1); ";
  }
  return KIMI_BUCKET_VARS + pick;
}

/** POSIX sh setting `$v` to omp's session-dir name for the path in `$src`. */
export function ompDirName(src: string, v: string): string {
  return "if [ \"$" + src + "\" = \"$HOME\" ]; then " + v + "=-; "
    + "elif [ \"${" + src + "#$HOME/}\" != \"$" + src + "\" ]; then "
    + v + "=\"-$(printf %s \"${" + src + "#$HOME/}\" | tr /: -)\"; "
    + "elif [ \"$" + src + "\" = /tmp ]; then " + v + "=-tmp; "
    + "elif [ \"${" + src + "#/tmp/}\" != \"$" + src + "\" ]; then "
    + v + "=\"-tmp-$(printf %s \"${" + src + "#/tmp/}\" | tr /: -)\"; "
    + "else " + v + "=\"--$(printf %s \"${" + src + "#/}\" | tr /: -)--\"; fi; ";
}

/** omp store fragment: newest session in the cwd's dir (else anywhere since the floor) into `varName`. */
export function ompFragment(since: number, varName: string): string {
  return "ob=\"${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions\"; "
    + ompDirName('d', 'os1') + ompDirName('r', 'os2')
    + varName + "=$(find \"$ob/$os1\" \"$ob/$os2\" -maxdepth 1 -name '*.jsonl' "
    + "-newermt @" + findEpoch(since) + " 2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null "
    + "| head -1); "
    + "[ -z \"$" + varName + "\" ] && [ " + since + " -gt 0 ] && " + varName + "=$(find \"$ob\" -mindepth 2 -maxdepth 2 "
    + "-name '*.jsonl' -newermt @" + findEpoch(since) + " 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); ";
}

/** Sets `$d`/`$r` and leaves the newest matching session file in `$f` (every store when agent is unknown). */
export function locateBlock(path: string, since: number, agent: string | null | undefined,
                            kimiCreatedSince?: number | null, kimiExclude: string[] = []): string {
  let cmd = "d='" + path + "'; r=$(readlink -f \"$d\" 2>/dev/null || printf %s \"$d\"); ";
  switch (agent) {
    case 'claude': cmd += claudeFragment(path, since, 'f'); break;
    case 'codex': cmd += codexFragment(since, 'f'); break;
    case 'grok': cmd += grokFragment(path, since, 'f'); break;
    case 'kimi': cmd += kimiFragment(since, 'f', kimiCreatedSince, kimiExclude); break;
    case 'omp': cmd += ompFragment(since, 'f'); break;
    case 'hermes': cmd += hermesFragment(since, 'f'); break;
    default:
      cmd += claudeFragment(path, since, 'tc');
      cmd += codexFragment(since, 'tx');
      cmd += grokFragment(path, since, 'tg');
      cmd += kimiFragment(since, 'tk');
      cmd += ompFragment(since, 'to');
      cmd += hermesFragment(since, 'th');
      cmd += "set --; for c in \"$tc\" \"$tx\" \"$tg\" \"$tk\" \"$to\" \"$th\"; do "
        + "[ -n \"$c\" ] && set -- \"$@\" \"$c\"; done; "
        + "f=\"\"; [ $# -gt 0 ] && f=$(ls -t \"$@\" 2>/dev/null | head -1); ";
  }
  return cmd;
}

/** `$varName` = Claude conversation `id`'s transcript, whatever project folder. */
export function claudePinnedFragment(id: string, varName: string): string {
  if (!isConversationUUID(id)) return '';
  return varName + "=$(ls -t \"$HOME\"/.claude/projects/*/" + id + ".jsonl 2>/dev/null | head -1); ";
}

/** `$varName` = Grok session `id`'s transcript, whatever folder. */
export function grokPinnedFragment(id: string, varName: string): string {
  if (!isConversationUUID(id)) return '';
  return varName + "=$(ls -t \"$HOME\"/.grok/sessions/*/" + id + "/updates.jsonl 2>/dev/null | head -1); ";
}

/** `$varName` = Codex conversation `id`'s rollout, whatever day it began. */
export function codexPinnedFragment(id: string, varName: string): string {
  if (!isConversationUUID(id)) return '';
  return varName + "=$(find \"$HOME/.codex/sessions\" -name 'rollout-*" + id + ".jsonl' 2>/dev/null "
    + "| xargs -r ls -t 2>/dev/null | head -1); ";
}

/** `$varName` = omp session `id`'s file, whatever folder. */
export function ompPinnedFragment(id: string, varName: string): string {
  if (!isConversationUUID(id)) return '';
  return varName + "=$(ls -t \"${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}\"/sessions/*/*_" + id + ".jsonl 2>/dev/null | head -1); ";
}

/** `$varName` = Hermes session `id`'s mirrored transcript, whatever folder. */
export function hermesPinnedFragment(id: string, varName: string): string {
  if (!isHermesSessionID(id)) return '';
  return varName + "=$(ls -t \"" + HERMES_TRANSCRIPT_ROOT + "\"/*/" + id + ".jsonl 2>/dev/null | head -1); ";
}

/** `$varName` = the main journal of Kimi session `id`, wherever its bucket is. */
export function kimiPinnedFragment(id: string, varName: string): string {
  if (!isKimiSessionID(id)) return '';
  return varName + "=$(ls -t \"$HOME\"/.kimi-code/sessions/wd_*/" + id + "/agents/main/wire.jsonl "
    + "\"$HOME\"/.kimi-code/sessions/wd_*/" + id + "/wire.jsonl 2>/dev/null | head -1); ";
}

/** `$varName` = the transcript of conversation `id` for `tool`, "" when no file is named by it. */
export function pinnedFragment(tool: string, id: string, varName: string): string {
  switch (tool) {
    case 'claude': return claudePinnedFragment(id, varName);
    case 'kimi': return kimiPinnedFragment(id, varName);
    case 'grok': return grokPinnedFragment(id, varName);
    case 'codex': return codexPinnedFragment(id, varName);
    case 'omp': return ompPinnedFragment(id, varName);
    default: return '';
  }
}

/** `$varName` = the transcript path the agent in tmux window `window` recorded, when still this tab's. */
export function pinnedTranscriptBlock(window: string, varName: string): string {
  return "pp=\"$HOME/.bromure/transcript-" + window + ".path\"; " + varName + "=\"\"; "
    + "if [ -f \"$pp\" ]; then " + varName + "=$(sed -n 1p \"$pp\" 2>/dev/null); "
    + "pk=$(sed -n 2p \"$pp\" 2>/dev/null); "
    + "if [ -z \"$pk\" ] || [ \"$pk\" != \"$(tmux display-message -p -t bromure:" + window + " '#{pane_id}' 2>/dev/null) "
    + "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)\" ]; then " + varName + "=\"\"; fi; fi; ";
}

/** `$f` = the window's pinned transcript when newer than the floor; `$pe` set when it doesn't exist yet. */
export function pinnedPick(window: number, since: number): string {
  return pinnedTranscriptBlock(String(window), 'c')
    + "pe=\"\"; if [ -n \"$c\" ]; then if [ -f \"$c\" ]; then "
    + "[ -n \"$(find \"$c\" -newermt @" + findEpoch(since) + " 2>/dev/null)\" ] && f=\"$c\"; "
    + "else pe=1; fi; fi; ";
}

/** The shell that resolves `$f`: the pin's conversation, else the window's named file, else the folder's newest. */
export function locatePrefix(path: string, since: number, agent: string | null | undefined,
                             pinnedWindow: number | null | undefined, pin: TranscriptPin = {}): string {
  let cmd = "f=\"\"; pe=\"\"; ";
  if (agent === 'kimi' && pin.kimiSession != null && isKimiSessionID(pin.kimiSession)) {
    cmd += kimiPinnedFragment(pin.kimiSession, 'f');
  } else if (agent === 'grok' && pin.grokSession != null && isConversationUUID(pin.grokSession)) {
    cmd += grokPinnedFragment(pin.grokSession, 'f') + "[ -z \"$f\" ] && pe=1; ";
  } else if (agent === 'codex' && pin.codexSession != null && isConversationUUID(pin.codexSession)) {
    cmd += codexPinnedFragment(pin.codexSession, 'f') + "[ -z \"$f\" ] && pe=1; ";
  } else if (agent === 'omp' && pin.ompSession != null && isConversationUUID(pin.ompSession)) {
    cmd += ompPinnedFragment(pin.ompSession, 'f') + "[ -z \"$f\" ] && pe=1; ";
  } else if (agent === 'hermes' && pin.hermesSession != null && isHermesSessionID(pin.hermesSession)) {
    cmd += hermesPinnedFragment(pin.hermesSession, 'f') + "[ -z \"$f\" ] && pe=1; ";
  } else if (pinnedWindow != null) {
    cmd += pinnedPick(pinnedWindow, since);
  }
  cmd += "if [ -z \"$f\" ] && [ -z \"$pe\" ]; then "
    + locateBlock(path, since, agent, pin.kimiCreatedSince, pin.kimiExclude ?? [])
    + "fi; ";
  return cmd;
}

/** CodingTaskEngine.transcriptLocatePrefix (an alias of locatePrefix). */
export const transcriptLocatePrefix = locatePrefix;

// MARK: - Floor probe

/** Prints "<cwd>\n<floor>\n<kimi session>\n<resumed 0|1>\n<process start>\n" for tmux window `window`. */
export function floorProbeCommand(window: number): string {
  return "i=" + window + "; "
    + "cwd=$(tmux -u display-message -p -t bromure:$i '#{pane_current_path}' 2>/dev/null); "
    + "tty=$(tmux display-message -p -t bromure:$i '#{pane_tty}' 2>/dev/null); "
    + "pid=$(ps -t \"${tty#/dev/}\" -o pid=,stat=,args= 2>/dev/null | awk '"
    + "$2 ~ /\\+/ { if (first == \"\") first = $1; "
    + "if (!found && $3 !~ /(^|\\/)-?(bash|sh|zsh|dash|fish|login)$/) { print $1; found = 1 } } "
    + "END { if (!found) print first }'); "
    + "et=$(ps -o etimes= -p \"$pid\" 2>/dev/null | tr -d ' '); "
    + "if [ -n \"$et\" ]; then s=$(( $(date +%s) - et )); else s=0; fi; ps0=$s; "
    + "a=$(ps -ww -o args= -p \"$pid\" 2>/dev/null); "
    + "case \"$a\" in "
    + "*--resume*|*--continue*|*--restore*) s=0;; "
    + "esac; "
    + "ks=$(printf %s \"$a\" | grep -o -E 'session_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1); "
    + "rs=0; case \" $a \" in *' -c '*|*' -S '*|*' --session '*|*' --session='*|*' --continue'*|*' --resume'*) rs=1;; esac; "
    + "printf '%s\\n%s\\n%s\\n%s\\n%s\\n' \"$cwd\" \"$s\" \"$ks\" \"$rs\" \"$ps0\"";
}

export interface FloorProbe {
  /** The tab's cwd. */
  cwd: string;
  /** Transcript floor (epoch seconds; 0 = no floor, e.g. a resumed agent). */
  since: number;
  /** The Kimi session the process names on its command line, if any. */
  kimiSession: string | null;
  /** Whether the process resumed a conversation. */
  resumed: boolean;
  /** When the foreground process started (epoch seconds). */
  started: number;
}

/** floorProbeCommand's answer; null when unreadable. */
export function parseFloorProbe(out: string | null | undefined): FloorProbe | null {
  const lines = (out ?? '').split('\n');
  if (lines.length < 2) return null;
  const cwd = trimWhitespaces(lines[0]);
  if (cwd === '') return null;
  const field = (i: number) => (lines.length > i ? trimWhitespaces(lines[i]) : '');
  const ks = field(2);
  const since = parseSwiftInt(field(1)) ?? 0;
  return {
    cwd,
    since,
    kimiSession: isKimiSessionID(ks) ? ks : null,
    resumed: field(3) === '1',
    started: parseSwiftInt(field(4)) ?? since,
  };
}

// MARK: - Incremental transcript reader

/** TranscriptChunkReader.python, verbatim (argv: file, known path, offset, bytes, "tail"|"earlier"). */
export const TRANSCRIPT_READER_PYTHON: string = [
  "import sys, os",
  "f, known, off, want, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]",
  "try:",
  "    size = os.path.getsize(f)",
  "except OSError:",
  "    sys.exit(0)",
  "want = max(want, 1)",
  "BLK = 1 << 16",
  "def line_start(fh, pos, limit):",
  "    # Start of the line holding byte `pos`; None when it begins more",
  "    # than `limit` bytes back (limit None: no bound).",
  "    p = pos",
  "    floor = 0 if limit is None else max(0, pos - limit)",
  "    while p > floor:",
  "        q = max(floor, p - BLK)",
  "        fh.seek(q)",
  "        b = fh.read(p - q)",
  "        j = b.rfind(b'\\n')",
  "        if j >= 0:",
  "            return q + j + 1",
  "        p = q",
  "    return 0 if floor == 0 else None",
  "def next_line(fh, pos, end):",
  "    # Offset just past the first newline in [pos, end); None if none.",
  "    p = pos",
  "    while p < end:",
  "        fh.seek(p)",
  "        b = fh.read(min(BLK, end - p))",
  "        if not b:",
  "            break",
  "        j = b.find(b'\\n')",
  "        if j >= 0:",
  "            return p + j + 1",
  "        p += len(b)",
  "    return None",
  "def whole_end(fh, start, end):",
  "    # Offset just past the last newline in [start, end); start if none.",
  "    p = end",
  "    while p > start:",
  "        q = max(start, p - BLK)",
  "        fh.seek(q)",
  "        b = fh.read(p - q)",
  "        j = b.rfind(b'\\n')",
  "        if j >= 0:",
  "            return q + j + 1",
  "        p = q",
  "    return start",
  "with open(f, 'rb') as fh:",
  "    if mode == 'earlier':",
  "        end = min(max(off, 0), size)",
  "        s0 = max(0, end - want)",
  "        start = 0",
  "        if s0 > 0:",
  "            nx = next_line(fh, s0, end)",
  "            start = nx if nx is not None and nx < end else line_start(fh, max(end - 1, 0), None)",
  "    else:",
  "        fresh = (f != known) or off < 0 or off > size or (size - off) > want * TAILJUMP",
  "        if fresh:",
  "            s0 = max(0, size - want)",
  "            start = 0",
  "            if s0 > 0:",
  "                ls = line_start(fh, s0, want)",
  "                if ls is not None:",
  "                    start = ls",
  "                else:",
  "                    we = whole_end(fh, s0, size)",
  "                    nx = next_line(fh, s0, we)",
  "                    start = nx if nx is not None and nx < we else line_start(fh, s0, None)",
  "        else:",
  "            start = off",
  "        end = whole_end(fh, start, size)",
  "    sys.stdout.write('%d\\n%d\\n%d\\n' % (size, start, end))",
  "    sys.stdout.flush()",
  "    fh.seek(start)",
  "    left = end - start",
  "    while left > 0:",
  "        b = fh.read(min(1 << 20, left))",
  "        if not b:",
  "            break",
  "        sys.stdout.buffer.write(b)",
  "        left -= len(b)",
].join('\n').replaceAll('TAILJUMP', String(TAIL_JUMP_FACTOR));

export interface TranscriptChunkOptions {
  /** The tab's cwd (from the floor probe). */
  guestCwd: string;
  /** Transcript floor (epoch seconds). */
  since: number;
  /** Canonical agent kind; null/undefined probes every store. */
  agent?: string | null;
  /** The tmux window whose agent-recorded transcript path wins. */
  pinnedWindow?: number | null;
  pin?: TranscriptPin;
  /** The path the client already holds bytes of (null on the first read). */
  knownPath?: string | null;
  /** File offset the client holds up to (-1 on the first read; the history's start for "earlier"). */
  knownOffset: number;
  /** Window size (INITIAL_HISTORY_BYTES / EARLIER_HISTORY_BYTES or a hint). */
  bytes: number;
  /** "Load earlier conversation" mode. */
  earlier: boolean;
  /** Fat-client variant: when the cwd's pq file is missing, fall back to the newest pq-*.json of the last 5 min. */
  pqFallback?: boolean;
}

/** One round-trip: resolve `$f` and print "path\npq\nsize\nstart\nend\n<bytes>"; null for an unquotable cwd. */
export function transcriptChunkCommand(o: TranscriptChunkOptions): string | null {
  const path = sanitizedGuestCwd(o.guestCwd);
  if (path == null) return null;
  const agent = o.agent ?? null;
  let cmd = locatePrefix(path, o.since, agent, o.pinnedWindow ?? null, o.pin ?? {});
  cmd += "if [ -n \"$f\" ]; then printf '%s\\n' \"$f\"; ";
  if (agent == null || agent === 'claude') {
    const enc2 = path.replaceAll('.', '-').replaceAll('/', '-');
    const pq = "\"$HOME/.bromure/pq-" + enc2 + ".json\"";
    if (o.pqFallback) {
      cmd += "q=" + pq + "; "
        + "if [ ! -f \"$q\" ]; then n=$(date +%s); "
        + "q=$(find \"$HOME/.bromure\" -maxdepth 1 -name 'pq-*.json' "
        + "-newermt @$((n-300)) 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); fi; "
        + "if [ -n \"$q\" ] && [ -n \"$(find \"$q\" -newermt @" + findEpoch(o.since) + " 2>/dev/null)\" ]; "
        + "then tr -d '\\n' < \"$q\"; fi; ";
    } else {
      cmd += "if [ -n \"$(find " + pq + " -newermt @" + findEpoch(o.since) + " 2>/dev/null)\" ]; "
        + "then tr -d '\\n' < " + pq + "; fi; ";
    }
  }
  cmd += "echo; ";
  cmd += "python3 - \"$f\" " + shellQuote(o.knownPath ?? '') + " " + o.knownOffset + " " + o.bytes + " "
    + (o.earlier ? 'earlier' : 'tail')
    + " <<'BROMURE_PY' | iconv -f UTF-8 -t UTF-8 -c\n" + TRANSCRIPT_READER_PYTHON + "\nBROMURE_PY\nfi";
  return cmd;
}

export interface TranscriptFetch {
  path: string;
  /** A pending AskUserQuestion dump (Claude), or "". */
  pq: string;
  size: number;
  /** File byte offsets of `chunk` (continue from `end`). */
  start: number;
  end: number;
  chunk: string;
}

/** TranscriptFetch.parse: 5 newline-terminated header lines then the bytes; null for empty/no transcript. */
export function parseTranscriptFetch(out: string | null | undefined): TranscriptFetch | null {
  if (!out) return null;
  const cuts: number[] = [];
  let i = 0;
  while (cuts.length < 5 && i < out.length) {
    const nl = out.indexOf('\n', i);
    if (nl < 0) break;
    cuts.push(nl);
    i = nl + 1;
  }
  if (cuts.length !== 5) return null;
  const field = (k: number) => out.slice(k === 0 ? 0 : cuts[k - 1] + 1, cuts[k]);
  const int = (k: number) => parseSwiftInt(trimWhitespaces(field(k)));
  const path = field(0);
  const size = int(2), start = int(3), end = int(4);
  if (path === '' || size == null || start == null || end == null) return null;
  return { path, pq: field(1), size, start, end, chunk: out.slice(cuts[4] + 1) };
}

// MARK: - Foreign-conversation check (AgentSessionEngine)

function lastPathComponent(p: string): string {
  const parts = p.split('/').filter((c) => c.length > 0);
  return parts.length ? parts[parts.length - 1] : (p.startsWith('/') ? '/' : '');
}

/** omp's session id in a file name (`<timestamp>_<uuid>`, minus .jsonl). */
export function ompConversationIDInFileName(name: string): string | null {
  const us = name.lastIndexOf('_');
  if (us < 0) return null;
  const id = name.slice(us + 1);
  return isConversationUUID(id) ? id : null;
}

/** The conversation id a transcript's file name (minus .jsonl) carries. */
export function transcriptIDFromFileName(name: string): string | null {
  if (isConversationUUID(name)) return name;
  const omp = ompConversationIDInFileName(name);
  if (omp) return omp;
  if (!name.startsWith('rollout-') || name.length <= 36) return null;
  const tail = name.slice(-36);
  return isConversationUUID(tail) ? tail : null;
}

/** The Codex conversation id in a rollout path, null when none. */
export function codexConversationIDInPath(path: string): string | null {
  let name = lastPathComponent(path);
  if (name.endsWith('.jsonl')) name = name.slice(0, -6);
  if (!name.startsWith('rollout-')) return null;
  return transcriptIDFromFileName(name);
}

/** The Grok conversation id in a session path, null when none. */
export function grokConversationIDInPath(path: string): string | null {
  const comps = path.split('/').filter((c) => c.length > 0);
  if (comps.length && comps[comps.length - 1].includes('.')) comps.pop();
  const id = comps[comps.length - 1];
  if (id == null || !isConversationUUID(id) || !comps.slice(0, -1).includes('.grok')) return null;
  return id;
}

/** omp's session id in a session path, null when none. */
export function ompConversationIDInPath(path: string): string | null {
  const name = lastPathComponent(path);
  if (!name.endsWith('.jsonl') || !path.includes('/sessions/')) return null;
  return ompConversationIDInFileName(name.slice(0, -6));
}

/** A read that landed on another session's Grok / Codex / omp conversation. */
export function isForeignConversation(path: string, agent: string | null | undefined,
                                      pin: TranscriptPin): boolean {
  const foreign = pin.foreignConversations ?? [];
  if (foreign.length === 0) return false;
  let id: string | null;
  switch (agent) {
    case 'codex': id = codexConversationIDInPath(path); break;
    case 'grok': id = grokConversationIDInPath(path); break;
    case 'omp': id = ompConversationIDInPath(path); break;
    default: id = null;
  }
  return id != null && foreign.includes(id.toLowerCase());
}

// MARK: - AgentPaneProbe

/** Agent names as they show in a process's arguments (whole words). */
export const AGENT_NAMES = 'claude|codex|kimi|grok|omp|hermes|aider|goose|opencode|gemini';
/** Process-args lines that are shells (by name or path). */
export const SHELL_LINES = '^-?([^ ]*/)?(bash|sh|zsh|dash|fish|login|tmux)( |$)';

/** Process argument lines in, the first agent's name out. */
export const AGENT_FILTER = "grep -v -E '" + SHELL_LINES + "' "
  + "| grep -E -o -m1 '(^|[^A-Za-z0-9])(" + AGENT_NAMES + ")([^A-Za-z]|$)' "
  + "| head -1 | tr -cd 'a-z'";

/** One line: `pane gone`, `pane none`, or `pane <agent>`. */
export function agentPaneProbeCommand(window: number): string {
  return "t=$(tmux display-message -p -t bromure:" + window + " '#{pane_tty}' 2>/dev/null); "
    + "if [ -z \"$t\" ]; then echo 'pane gone'; exit 0; fi; "
    + "a=$(ps -t \"${t#/dev/}\" -o args= 2>/dev/null | " + AGENT_FILTER + "); "
    + "echo \"pane ${a:-none}\"";
}

export type AgentPaneState = { running: string } | 'shell' | 'gone';

/** agentPaneProbeCommand's answer; null when it isn't one. */
export function parseAgentPaneProbe(out: string): AgentPaneState | null {
  for (const raw of out.split(/\r\n|[\n\r\u000B\u000C\u0085\u2028\u2029]/)) {
    const line = trimWhitespaces(raw);
    if (!line.startsWith('pane')) continue;
    const v = line.slice(4).toLowerCase().replace(/\P{L}/gu, '');
    if (v === 'gone') return 'gone';
    if (v === '' || v === 'none') return 'shell';
    return { running: v };
  }
  return null;
}

// MARK: - PaneTarget

export type PaneRef =
  | { index: number }
  | { windowID: string }
  | { worktree: string };

export type PaneForeground = 'agent' | 'shell';

/** Where host-typed text goes, and what must hold there right before every keystroke batch. */
export interface PaneTarget {
  ref: PaneRef;
  expectWorktree?: string;
  expectDisplay?: string;
  /** A second `@display` that also names the intended window (a Sidecar session's current title). */
  expectDisplayAlt?: string;
  expectWindowID?: string;
  foreground: PaneForeground;
}

/** A tmux window id as tmux prints it ("@12"). */
export function isWindowID(s: string): boolean {
  return /^@\p{N}+$/u.test(s);
}

/** PaneTarget.index: `bromure:<i>`. */
export function paneTargetIndex(i: number, foreground: PaneForeground = 'agent'): PaneTarget {
  return { ref: { index: i }, foreground };
}

/** PaneTarget.task: a board task's tab, by its branch. */
export function paneTargetTask(branch: string, foreground: PaneForeground = 'agent'): PaneTarget {
  return { ref: { worktree: branch }, expectWorktree: branch, foreground };
}

/** PaneTarget.chat: a chat's tab, by window id when known else index, still carrying its markers. */
export function paneTargetChat(o: {
  window: number; windowID?: string | null; display?: string | null; worktree?: string | null;
  alsoDisplay?: string | null; foreground?: PaneForeground;
}): PaneTarget {
  const id = o.windowID != null && isWindowID(o.windowID) ? o.windowID : null;
  const t: PaneTarget = { ref: id != null ? { windowID: id } : { index: o.window }, foreground: o.foreground ?? 'agent' };
  if (id != null) t.expectWindowID = id;
  if (o.display != null && o.display !== '') {
    t.expectDisplay = o.display;
    if (o.alsoDisplay != null && o.alsoDisplay !== '' && o.alsoDisplay !== o.display) t.expectDisplayAlt = o.alsoDisplay;
  }
  if (o.worktree != null && o.worktree !== '') t.expectWorktree = o.worktree;
  return t;
}

/** PaneTarget as Swift's synthesized Codable + JSONEncoder emits it (POST /vms/<id>/type). */
export function paneTargetJSON(t: PaneTarget): string {
  let ref: unknown;
  if ('index' in t.ref) ref = { index: { _0: t.ref.index } };
  else if ('windowID' in t.ref) ref = { windowID: { _0: t.ref.windowID } };
  else ref = { worktree: { _0: t.ref.worktree } };
  const o: Record<string, unknown> = { ref };
  if (t.expectWorktree != null) o.expectWorktree = t.expectWorktree;
  if (t.expectDisplay != null) o.expectDisplay = t.expectDisplay;
  if (t.expectDisplayAlt != null) o.expectDisplayAlt = t.expectDisplayAlt;
  if (t.expectWindowID != null) o.expectWindowID = t.expectWindowID;
  o.foreground = { [t.foreground]: {} };
  // JSONEncoder escapes "/" as "\/" by default (no .withoutEscapingSlashes).
  return JSON.stringify(o).replaceAll('/', '\\/');
}

// MARK: - PaneTypeGuard

export type PaneRefusal = 'gone' | 'identity' | 'shell' | 'agent';

/** Printed (with the reason) when a guard refused to type. */
export const REFUSED_MARKER = 'BROMURE_TYPE_REFUSED';
/** Printed when a guarded type held off because a menu or dialog is up. */
export const HELD_MARKER = 'BROMURE_TYPE_HELD';
/** Printed once the text and its Enter went in. */
export const TYPED_MARKER = 'BROMURE_TYPE_OK';
/** Printed when the text went in but its Enter never took. */
export const UNCONFIRMED_MARKER = 'BROMURE_TYPE_UNCONFIRMED';
/** Printed when the Enter didn't take and the agent's input box is empty. */
export const DROPPED_MARKER = 'BROMURE_TYPE_DROPPED';

/** What a command's output says about a refusal, null when none. */
export function refusalIn(out: string): PaneRefusal | null {
  const at = out.indexOf(REFUSED_MARKER + ' ');
  if (at < 0) return null;
  const word = /^\p{L}*/u.exec(out.slice(at + REFUSED_MARKER.length + 1))![0];
  return (['gone', 'identity', 'shell', 'agent'] as const).find((r) => r === word) ?? 'gone';
}
/** Whether a guarded type held off for an open menu or dialog. */
export const heldIn = (out: string) => out.includes(HELD_MARKER);
/** Whether a guarded type went all the way in (text and Enter). */
export const typedIn = (out: string) => out.includes(TYPED_MARKER);
/** Whether a guarded type went in but its Enter never took. */
export const unconfirmedIn = (out: string) => out.includes(UNCONFIRMED_MARKER);
/** Whether a type's text isn't in the agent's box after its Enter didn't take. */
export const droppedIn = (out: string) => out.includes(DROPPED_MARKER);

/** Single-quoted for sh. */
export const quote = shellQuote;

/** Sets `$_bt` to the target's window id (empty when it can't be found). */
export function resolvePaneTarget(t: PaneTarget): string {
  if ('index' in t.ref) {
    return "_bt=$(tmux display-message -p -t bromure:" + t.ref.index + " '#{window_id}' 2>/dev/null); ";
  }
  if ('windowID' in t.ref) {
    const q = isWindowID(t.ref.windowID) ? quote(t.ref.windowID) : "''";
    return "_bt=$(tmux display-message -p -t " + q + " '#{window_id}' 2>/dev/null); ";
  }
  return "_bt=$(tmux list-windows -t bromure -F '#{window_id} #{@worktree}' 2>/dev/null "
    + "| awk -v b=" + quote(t.ref.worktree) + " '$2==b {w=$1} END {print w}'); ";
}

/** Defines `_bg`: true while `$_bt` is still the intended window with the wanted foreground; else prints the refusal. */
export function guardFunction(t: PaneTarget): string {
  const refuse = (r: PaneRefusal) => "{ echo '" + REFUSED_MARKER + " " + r + "'; return 1; }";
  let f = "_bg() { ";
  f += "[ -n \"$_bt\" ] || " + refuse('gone') + "; ";
  f += "[ \"$(tmux display-message -p -t \"$_bt\" '#{window_id}' 2>/dev/null)\" = \"$_bt\" ] || " + refuse('gone') + "; ";
  if (t.expectWindowID != null) {
    f += "[ \"$_bt\" = " + quote(t.expectWindowID) + " ] || " + refuse('identity') + "; ";
  }
  if (t.expectWorktree != null) {
    f += "[ \"$(tmux display-message -p -t \"$_bt\" '#{@worktree}' 2>/dev/null)\" = " + quote(t.expectWorktree) + " ] || " + refuse('identity') + "; ";
  }
  if (t.expectDisplay != null) {
    f += "_bd=$(tmux display-message -p -t \"$_bt\" '#{@display}' 2>/dev/null); ";
    const alt = t.expectDisplayAlt != null ? " || [ \"$_bd\" = " + quote(t.expectDisplayAlt) + " ]" : '';
    f += "[ -z \"$_bd\" ] || [ \"$_bd\" = " + quote(t.expectDisplay) + " ]" + alt + " || " + refuse('identity') + "; ";
  }
  f += "_by=$(tmux display-message -p -t \"$_bt\" '#{pane_tty}' 2>/dev/null); ";
  f += "[ -n \"$_by\" ] || " + refuse('gone') + "; ";
  f += "_ba=$(ps -A -o tty= -o tpgid= -o pgid= -o args= 2>/dev/null "
    + "| awk -v t=\"${_by#/dev/}\" '$1==t && $2==$3 { $1=\"\"; $2=\"\"; $3=\"\"; sub(/^ +/, \"\"); print }' "
    + "| grep -v -E '" + SHELL_LINES + "' "
    + "| grep -E -o -m1 '(^|[^A-Za-z0-9])(" + AGENT_NAMES + ")([^A-Za-z]|$)' "
    + "| head -1 | tr -cd 'a-z'); ";
  if (t.foreground === 'agent') f += "[ -n \"$_ba\" ] || " + refuse('shell') + "; ";
  else f += "[ -z \"$_ba\" ] || " + refuse('agent') + "; ";
  f += "return 0; }; ";
  return f;
}

/** Resolve + guard, ready for `if _bg; then …; fi`. */
export function prelude(t: PaneTarget): string {
  return resolvePaneTarget(t) + guardFunction(t);
}

/** The text as it is typed: line breaks as LF only. */
export function normalizedText(text: string): string {
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/** Text longer than this (UTF-8 bytes) is staged in pieces before it's typed. */
export const INLINE_LIMIT = 24 * 1024;
/** Base64 characters per staging command. */
export const STAGE_CHUNK = 64 * 1024;

/** Whether `text` must be staged (stageCommands) before it's typed. */
export function needsStaging(text: string): boolean {
  return utf8Length(normalizedText(text)) > INLINE_LIMIT;
}

/** A fresh path for a staged message (in the guest's /tmp). */
export function newStagePath(): string {
  return '/tmp/bromure-msg-' + crypto.randomUUID().toLowerCase() + '.b64';
}

/** Whether `p` is a stage path newStagePath could have made. */
export function isStagePath(p: string): boolean {
  return p.startsWith('/tmp/bromure-msg-') && p.endsWith('.b64')
    && /^[\p{L}\p{N}.-]*$/u.test(p.slice(5));
}

/** The guest commands that write `text` (base64) to `path`. */
export function stageCommands(text: string, path: string): string[] {
  if (!isStagePath(path)) return [];
  const b64 = base64UTF8(normalizedText(text));
  const out = ['umask 077; : > ' + quote(path)];
  for (let i = 0; i < b64.length; i += STAGE_CHUNK) {
    out.push('printf %s ' + b64.slice(i, i + STAGE_CHUNK) + ' >> ' + quote(path));
  }
  return out;
}

/** The literal send of `text` into "$_bt" as one bracketed tmux paste (base64, inline or from `staged`). */
export function literalSend(text: string, staged?: string | null): string {
  const source = staged != null && isStagePath(staged)
    ? 'base64 -d < ' + quote(staged)
    : 'echo ' + base64UTF8(normalizedText(text)) + ' | base64 -d';
  return "{ _bb=bromure-msg-$$; " + source + " | tmux load-buffer -b \"$_bb\" - "
    + "&& tmux paste-buffer -p -r -d -b \"$_bb\" -t \"$_bt\" "
    + "|| { tmux delete-buffer -b \"$_bb\" 2>/dev/null; false; }; }";
}

const WS = /\p{White_Space}/u;

/** `text` plus a space when it ends in a token an agent's composer would complete (path, /cmd, @, $). */
export function completionSafe(text: string): string {
  const t = normalizedText(text);
  const chars = Array.from(t);
  const end = chars[chars.length - 1];
  if (end === undefined || WS.test(end)) return text;
  const tokens = t.split(/\p{White_Space}+/u).filter((s) => s.length > 0);
  if (tokens.length < 2) return text;
  const last = tokens[tokens.length - 1];
  const first = last[0];
  if (!('/@$'.includes(first) || last.includes('/'))) return text;
  return text + ' ';
}

/** Named tmux keys into the target, one at a time `beat` s apart, each re-guarded; "" when none valid. */
export function keysCommand(target: PaneTarget, keys: string[], beat = 0.4): string {
  const safe = keys.filter((k) => /^[\p{L}\p{N}-]+$/u.test(k));
  if (safe.length === 0) return '';
  const steps = safe.map((k) => "_bg && tmux send-keys -t \"$_bt\" " + k);
  return prelude(target) + '{ ' + steps.join(' && sleep ' + swiftDouble(beat) + ' && ') + '; }';
}

/** Swift's Double description for simple values ("0.4", "1.0"). */
function swiftDouble(d: number): string {
  return Number.isInteger(d) ? d.toFixed(1) : String(d);
}

/** True (exit 0) while an agent's option picker is on screen in "$_bt". */
export const PICKER_VISIBLE_IN_TARGET =
  "tmux capture-pane -p -t \"$_bt\" 2>/dev/null | grep -qE 'Enter to (select|confirm)'";

/** An AskUserQuestion picker's key sequence into the target, each key re-guarded; "" when none valid. */
export function answerKeysCommand(target: PaneTarget, keys: string[]): string {
  const named = ['Enter', 'Right', 'Left', 'Down', 'Up', 'Tab', 'Space'];
  const steps: string[] = [];
  for (const k of keys) {
    const isDigit = /^\p{N}$/u.test(k);
    if (!isDigit && !named.includes(k)) continue;
    const send = "tmux send-keys -t \"$_bt\" " + (isDigit ? '-l ' : '') + k;
    steps.push(isDigit
      ? "{ _bg || exit 1; " + PICKER_VISIBLE_IN_TARGET + " && " + send + "; true; }"
      : "{ _bg || exit 1; " + send + "; }");
  }
  if (steps.length === 0) return '';
  return prelude(target) + steps.join('; sleep 1; ');
}

/** The bottom of "$_bt"'s screen with its escapes (for an input-box reader). */
export function boxProbeCommand(t: PaneTarget): string {
  return resolvePaneTarget(t) + "[ -n \"$_bt\" ] && tmux capture-pane -p -e -t \"$_bt\" 2>/dev/null | tail -n 30";
}

// MARK: - ChatQueueStore.Outcome

export type TypeOutcome =
  | 'typed' | 'held' | 'unreachable' | { refused: PaneRefusal } | 'failed' | 'unconfirmed' | 'dropped';

/** What a guarded type's output says (only its success marker counts as typed); null = unreachable. */
export function typeOutcome(out: string | null): TypeOutcome {
  if (out == null) return 'unreachable';
  const r = refusalIn(out);
  if (r != null) return { refused: r };
  if (heldIn(out)) return 'held';
  if (typedIn(out)) return 'typed';
  if (droppedIn(out)) return 'dropped';
  return unconfirmedIn(out) ? 'unconfirmed' : 'failed';
}
