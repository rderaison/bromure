// Agent transcript parsers — a port of ClaudeTranscriptView.swift's model
// layer (ClaudeTranscriptParser, OmpTranscriptParser, CodexTranscriptParser +
// CodexCodeMode, GrokTranscriptParser, KimiTranscriptParser, AgentTranscript
// dispatch/sniff/stableIDs, AgentAPIError classifiers, BromureBlock,
// TranscriptQuestion.parse, GuestSharePaths, TodoParse) plus the helpers they
// call elsewhere (ActivitySummary.humanTool, DisplayRequest.parse).
//
// Pure data code. Every reader is tolerant: unparseable lines (a tail-cut read
// may start mid-line) and unknown shapes are skipped, never fatal.

import type {
  AgentAPIError,
  APIErrorKind,
  TodoRow,
  TodoStatus,
  TranscriptItem,
  TranscriptKind,
  TranscriptQuestion,
  QuestionOption,
} from './types';

// MARK: - JSON helpers (Swift `as?` casts)

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Dict = Record<string, any>;

const isObj = (v: unknown): v is Dict => v !== null && typeof v === 'object' && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);
const int = (v: unknown): number | undefined =>
  typeof v === 'number' && Number.isInteger(v) ? v : undefined;
const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
const bool = (v: unknown): boolean | undefined => (typeof v === 'boolean' ? v : undefined);
/** `as? [[String: Any]]`: an array whose every element is an object. */
const dicts = (v: unknown): Dict[] | undefined =>
  Array.isArray(v) && v.every(isObj) ? (v as Dict[]) : undefined;
/** `as? [String]`. */
const strings = (v: unknown): string[] | undefined =>
  Array.isArray(v) && v.every((x) => typeof x === 'string') ? (v as string[]) : undefined;
/** `obj[key] != nil` — a present key, JSON null included (NSNull). */
const has = (o: Dict, k: string) => Object.prototype.hasOwnProperty.call(o, k) && o[k] !== undefined;

function parseJSON(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}
function parseObj(s: string): Dict | undefined {
  const v = parseJSON(s);
  return isObj(v) ? v : undefined;
}

/** `split(whereSeparator: \.isNewline)` — empty lines omitted. (U+2028/2029
 *  are not treated as separators: JSON may carry them raw inside a string.) */
function lines(text: string): string[] {
  return text.split(/\r\n|[\n\r\u000B\u000C\u0085]/).filter((l) => l.length > 0);
}

/** `.whitespacesAndNewlines` */
const trim = (s: string) => s.trim();
/** `.whitespaces` (Zs + tab) */
const trimWS = (s: string) => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, '');
/** `.newlines` */
const trimNL = (s: string) => s.replace(/^[\n\r\u000B\u000C\u0085\u2028\u2029]+|[\n\r\u000B\u000C\u0085\u2028\u2029]+$/g, '');

const segmenter: Intl.Segmenter | undefined =
  typeof Intl !== 'undefined' && 'Segmenter' in Intl ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : undefined;

/** `String(s.prefix(n))` in Characters (grapheme clusters). */
export function prefixChars(s: string, n: number): string {
  if (s.length <= n) return s;
  if (segmenter) {
    let count = 0;
    for (const seg of segmenter.segment(s)) {
      if (count === n) return s.slice(0, seg.index);
      count++;
    }
    return s;
  }
  return Array.from(s).slice(0, n).join('');
}
/** `s.count > n` in Characters. */
function longerThan(s: string, n: number): boolean {
  if (s.length <= n) return false;
  return prefixChars(s, n).length < s.length;
}
/** `s.count > 200 ? String(s.prefix(200)) + "…" : s` */
export function clip(s: string, n = 200): string {
  return longerThan(s, n) ? prefixChars(s, n) + '…' : s;
}

const ISO_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})$/i;
/** ISO8601DateFormatter (with or without fractional seconds) → ms epoch. */
export function parseISODate(s: unknown): number | undefined {
  if (typeof s !== 'string') return undefined;
  const m = ISO_RE.exec(s);
  if (!m) return undefined;
  let tz = m[3].toUpperCase();
  if (tz !== 'Z' && !tz.includes(':')) tz = tz.slice(0, 3) + ':' + tz.slice(3);
  const frac = m[2] ? '.' + (m[2] + '00').slice(0, 3) : '';
  const t = Date.parse(m[1] + frac + tz);
  return Number.isNaN(t) ? undefined : t;
}

/** Foundation's JSON string escaping (it escapes `/`). */
const jsonString = (s: string) => JSON.stringify(s).replace(/\//g, '\\/');

function jsonNumber(n: number): string {
  return Number.isFinite(n) ? String(n) : 'null';
}

/** `JSONSerialization.data(withJSONObject:, options: [.prettyPrinted, .sortedKeys])`
 *  — Foundation's layout: 2-space indent, `"key" : value`, slashes escaped,
 *  empty collections as `{\n\n}`. */
export function prettyJSON(obj: unknown): string {
  if (!isObj(obj)) return '';
  const out: string[] = [];
  const write = (v: unknown, indent: string) => {
    if (v === null || v === undefined) out.push('null');
    else if (typeof v === 'string') out.push(jsonString(v));
    else if (typeof v === 'number') out.push(jsonNumber(v));
    else if (typeof v === 'boolean') out.push(v ? 'true' : 'false');
    else if (Array.isArray(v)) {
      const inner = indent + '  ';
      out.push('[\n');
      v.forEach((x, i) => {
        if (i > 0) out.push(',\n');
        out.push(inner);
        write(x, inner);
      });
      out.push('\n' + indent + ']');
    } else if (isObj(v)) {
      const inner = indent + '  ';
      const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
      out.push('{\n');
      keys.forEach((k, i) => {
        if (i > 0) out.push(',\n');
        out.push(inner + jsonString(k) + ' : ');
        write(v[k], inner);
      });
      out.push('\n' + indent + '}');
    } else out.push('null');
  };
  write(obj, '');
  return out.join('');
}

/** Compact, sorted-key JSON (`options: [.sortedKeys]`). */
export function sortedJSON(v: unknown): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'string') return jsonString(v);
  if (typeof v === 'number') return jsonNumber(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (Array.isArray(v)) return '[' + v.map(sortedJSON).join(',') + ']';
  if (isObj(v)) {
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort()
      .map((k) => jsonString(k) + ':' + sortedJSON(v[k])).join(',') + '}';
  }
  return 'null';
}

// Items while parsing: positional, re-keyed by stableIDs at the end.
interface Raw { kind: TranscriptKind; timestamp?: number }

// MARK: - AgentAPIError

/** The first HTTP-looking status in an agent's error message. */
export function statusIn(message: string): number | undefined {
  const m = /(?<![\d.])(40[0-9]|42[0-9]|451|5[0-9]{2})(?![\d.])/.exec(message);
  return m ? Number(m[1]) : undefined;
}

export function kindForStatus(status: number | undefined): APIErrorKind {
  switch (status) {
    case 401: return 'auth';
    case 402: return 'quota';
    case 429: return 'rateLimit';
    case 503: case 529: return 'overloaded';
    default: return 'other';
  }
}

export type BromureBlock =
  | 'promptInjection' | 'rulesInjection' | 'credentialLeak' | 'supplyChain' | 'clientCertificate' | 'unknown';

/** Which Bromure engine blocked a request, from the body it answered with. */
export function bromureBlockOf(message: string): BromureBlock | undefined {
  const m = message.toLowerCase();
  if (m.includes('bromure blocked this request') || m.includes('bromure blocked: possible')) {
    return m.includes('rogue instructions') ? 'rulesInjection' : 'promptInjection';
  }
  if (m.includes('bromure: outbound request blocked')) return 'credentialLeak';
  if (m.includes('bromure supply-chain security blocked')) return 'supplyChain';
  if (m.includes('bromure: client-certificate use denied')) return 'clientCertificate';
  return undefined;
}

export function bromureBlockHeadline(b: BromureBlock): string {
  switch (b) {
    case 'promptInjection': return 'Blocked by Bromure — prompt injection';
    case 'rulesInjection': return 'Blocked by Bromure — rogue instructions';
    case 'credentialLeak': return 'Blocked by Bromure — credential leak';
    case 'supplyChain': return 'Blocked by Bromure — supply chain';
    case 'clientCertificate': return 'Blocked by Bromure — client certificate';
    default: return 'Blocked by Bromure';
  }
}

export function bromureBlockRecoveryHint(b: BromureBlock): string | undefined {
  return b === 'promptInjection'
    ? "Nothing reached the provider. Bromure removes the blocked tool output from this conversation's later requests, so you can send your next message. If the agent keeps failing, rewind the conversation past that step or start a new session."
    : undefined;
}

export function isBromureBlock(status: number | undefined, message: string): boolean {
  return status === 451 || bromureBlockOf(message) !== undefined || statusIn(message) === 451;
}

/** `AgentAPIError.init`: a Bromure block overrides the agent's own kind. */
export function makeAPIError(kind: APIErrorKind, status: number | undefined, message: string): AgentAPIError {
  const e: AgentAPIError = { kind: isBromureBlock(status, message) ? 'blocked' : kind, message };
  if (status !== undefined) e.status = status;
  return e;
}

/** Which engine blocked it, when `kind == 'blocked'`. */
export function apiErrorBlockedBy(e: AgentAPIError): BromureBlock | undefined {
  return e.kind === 'blocked' ? (bromureBlockOf(e.message) ?? 'unknown') : undefined;
}

export function apiErrorHeadline(e: AgentAPIError): string {
  switch (e.kind) {
    case 'auth': return "The agent couldn't authenticate";
    case 'quota': case 'rateLimit': return 'The agent hit a usage limit';
    case 'blocked': return bromureBlockHeadline(apiErrorBlockedBy(e) ?? 'unknown');
    default: return 'The agent stopped with an error';
  }
}

export const classifyAPIError = {
  /** Claude Code: `error` on an `isApiErrorMessage` line. */
  claude(error: string | undefined, status: number | undefined, message: string): AgentAPIError {
    let kind: APIErrorKind;
    switch (error ?? '') {
      case 'authentication_failed': case 'oauth_org_not_allowed': case 'account_on_hold':
      case 'verification_required': case 'cloud_credential_error': kind = 'auth'; break;
      case 'billing_error': kind = 'quota'; break;
      case 'rate_limit': kind = 'rateLimit'; break;
      case 'overloaded': case 'server_error': kind = 'overloaded'; break;
      default: kind = kindForStatus(status ?? statusIn(message));
    }
    return makeAPIError(kind, status ?? statusIn(message), message);
  },
  /** Codex: `codex_error_info` / `codexErrorInfo`. */
  codex(info: string | undefined, message: string): AgentAPIError {
    const status = statusIn(message);
    let kind: APIErrorKind;
    switch ((info ?? '').replace(/_/g, '').toLowerCase()) {
      case 'unauthorized': kind = 'auth'; break;
      case 'usagelimitexceeded': case 'sessionbudgetexceeded': kind = 'quota'; break;
      case 'ratelimitexceeded': kind = 'rateLimit'; break;
      case 'serveroverloaded': kind = 'overloaded'; break;
      default: kind = kindForStatus(status);
    }
    return makeAPIError(kind, status, message);
  },
  /** Kimi Code: `turn.ended` error `code` + class `name` + `statusCode`. */
  kimi(code: string | undefined, name: string | undefined, status: number | undefined, message: string): AgentAPIError {
    const c = code ?? '';
    let kind: APIErrorKind;
    if (c === 'provider.auth_error' || c.startsWith('auth.')) kind = 'auth';
    else if (name === 'APIProviderQuotaExhaustedError') kind = 'quota';
    else if (c === 'provider.rate_limit' || name === 'APIProviderRateLimitError') kind = 'rateLimit';
    else kind = kindForStatus(status ?? statusIn(message));
    return makeAPIError(kind, status ?? statusIn(message), message);
  },
  /** Grok: `retry_state.error_type`. */
  grok(errorType: string | undefined, rateLimited: boolean, message: string): AgentAPIError {
    const status = statusIn(message);
    let kind: APIErrorKind;
    switch (errorType ?? '') {
      case 'auth': kind = 'auth'; break;
      case 'rate_limited': kind = 'rateLimit'; break;
      default: kind = rateLimited ? 'rateLimit' : kindForStatus(status);
    }
    return makeAPIError(kind, status, message);
  },
  /** Oh My Pi: the `errorId` classifier bitfield and `errorStatus`. */
  omp(errorID: number | undefined, status: number | undefined, message: string): AgentAPIError {
    const id = errorID ?? 0;
    let kind: APIErrorKind;
    if (hasBit(id, 0x1000000) || hasBit(id, 0x40000000)) kind = 'auth';
    else if (hasBit(id, 0x80000)) kind = 'quota';
    else kind = kindForStatus(status ?? statusIn(message));
    return makeAPIError(kind, status ?? statusIn(message), message);
  },
};

/** `id & bit != 0` without 32-bit truncation. */
function hasBit(id: number, bit: number): boolean {
  return Math.floor(Math.abs(id) / bit) % 2 === 1;
}

// MARK: - Questions

function parseOptions(v: unknown): QuestionOption[] {
  return (dicts(v) ?? []).flatMap((o) => {
    const label = str(o.label);
    return label ? [{ label, description: str(o.description) ?? '' }] : [];
  });
}

/** AskUserQuestion input → its questions, in order. */
export function parseQuestions(input: Dict): TranscriptQuestion[] {
  const qs = dicts(input.questions);
  if (!qs) return [];
  return qs.flatMap((q) => {
    const text = str(q.question);
    if (!text) return [];
    return [{ question: text, header: str(q.header) ?? '', multiSelect: bool(q.multiSelect) ?? false,
      options: parseOptions(q.options) }];
  });
}

// MARK: - Shared Claude helpers

const LOCAL_TAGS = [
  '<command-name>', '<command-message>', '<command-args>',
  '<local-command-stdout>', '<local-command-caveat>',
  '<bash-input>', '<bash-stdout>', '<bash-stderr>',
  '<system-reminder>',
];
/** A terminal record Claude Code wrote as a user turn (slash command, `!`
 *  shell, reminders) — not something the user said. */
export const isLocalRecord = (text: string) => LOCAL_TAGS.some((t) => text.startsWith(t));
export const isClearCommand = (text: string) => text.includes('<command-name>/clear</command-name>');

/** `<pasted_content id="…">text</pasted_content>` → text (well-formed pairs only). */
export function unwrapPasted(text: string): string {
  if (!text.includes('<pasted_content')) return text;
  const tagEnd = (start: number): number | undefined => {
    const end = text.indexOf('>', start);
    if (end < 0) return undefined;
    const seg = text.slice(start, end);
    if (seg.includes('<') || seg.includes('\n')) return undefined;
    if (seg.length > 0 && seg[0] !== ' ') return undefined;
    return end;
  };
  let out = '';
  let pos = 0;
  for (;;) {
    const open = text.indexOf('<pasted_content', pos);
    if (open < 0) break;
    const openEnd = tagEnd(open + '<pasted_content'.length);
    if (openEnd === undefined) break;
    const bodyStart = openEnd + 1;
    let search = bodyStart;
    let close: [number, number] | undefined;
    for (;;) {
      const c = text.indexOf('</pasted_content', search);
      if (c < 0) break;
      const cEnd = tagEnd(c + '</pasted_content'.length);
      if (cEnd !== undefined) { close = [c, cEnd + 1]; break; }
      search = c + '</pasted_content'.length;
    }
    if (!close) break;
    out += text.slice(pos, open) + text.slice(bodyStart, close[0]);
    pos = close[1];
  }
  out += text.slice(pos);
  return trim(out);
}

const SUMMARY_KEYS = ['command', 'file_path', 'path', 'pattern', 'query', 'url', 'prompt', 'description'];
/** The one-liner on a collapsed tool call: the command for shells, the path
 *  for file tools, the first string value otherwise (clipped at 200). */
export function toolSummary(_name: string, input: Dict): string {
  for (const k of SUMMARY_KEYS) {
    const v = str(input[k]);
    if (v) return clip(v);
  }
  for (const v of Object.values(input)) if (typeof v === 'string') return clip(v);
  return '';
}

/** tool_result content: a bare string, or the text of an array of blocks. */
export function resultText(content: unknown): string {
  if (typeof content === 'string') return content;
  const blocks = dicts(content);
  if (!blocks) return '';
  return blocks.flatMap((b) => (typeof b.text === 'string' ? [b.text] : [])).join('\n');
}

export function compactSummaryKind(summary: string): TranscriptKind {
  return { t: 'toolUse', name: 'Compact', summary: 'Conversation compacted', detail: trim(summary) };
}

// MARK: - Claude parser

export function parseClaude(text: string): { items: Raw[]; cleared: boolean } {
  let cleared = false;
  let items: Raw[] = [];
  const toolNames = new Map<string, string>();
  const questionItems = new Map<string, number[]>();
  let lastAskedQuestions: string[] = [];
  const pendingDumps: TranscriptQuestion[][] = [];

  for (const line of lines(text)) {
    const obj = parseObj(line);
    if (!obj) continue;
    const type = str(obj.type) ?? '';
    if (type === '' && obj.tool_name === 'AskUserQuestion' && isObj(obj.tool_input)) {
      const qs = parseQuestions(obj.tool_input);
      if (qs.length) pendingDumps.push(qs);
      continue;
    }
    const message = obj.message;
    if (!(type === 'user' || type === 'assistant') || !isObj(message)) continue;
    if (obj.isMeta === true) continue;
    const stamp = parseISODate(obj.timestamp);
    const add = (kind: TranscriptKind) => { items.push({ kind, timestamp: stamp }); };

    if (type === 'user' && obj.isCompactSummary === true) {
      add(compactSummaryKind(resultText(message.content)));
      continue;
    }
    if (type === 'assistant' && obj.isApiErrorMessage === true) {
      const t = trim(resultText(message.content));
      add({ t: 'agentError', error: classifyAPIError.claude(str(obj.error), int(obj.apiErrorStatus), t) });
      continue;
    }
    if (typeof message.content === 'string') {
      const trimmed = trim(message.content);
      if (type === 'user' && isLocalRecord(trimmed)) {
        if (isClearCommand(trimmed)) { items = []; cleared = true; }
        continue;
      }
      if (trimmed) add(type === 'user' ? { t: 'userText', text: unwrapPasted(trimmed) } : { t: 'assistantText', text: trimmed });
      continue;
    }
    const blocks = dicts(message.content);
    if (!blocks) continue;
    for (const block of blocks) {
      switch (str(block.type)) {
        case 'text': {
          const s = trim(str(block.text) ?? '');
          if (!s) continue;
          if (type === 'user' && isLocalRecord(s)) {
            if (isClearCommand(s)) { items = []; cleared = true; }
            continue;
          }
          add(type === 'user' ? { t: 'userText', text: unwrapPasted(s) } : { t: 'assistantText', text: s });
          break;
        }
        case 'thinking': {
          const s = trim(str(block.thinking) ?? '');
          if (s) add({ t: 'thinking', text: s });
          break;
        }
        case 'tool_use': {
          const name = str(block.name) ?? 'tool';
          const id = str(block.id);
          if (id !== undefined) toolNames.set(id, name);
          const input: Dict = isObj(block.input) ? block.input : {};
          const questions = name === 'AskUserQuestion' ? parseQuestions(input) : [];
          if (questions.length) {
            lastAskedQuestions = questions.map((q) => q.question);
            const first = items.length;
            questions.forEach((q) => add({ t: 'question', q }));
            if (id !== undefined) questionItems.set(id, range(first, items.length));
          } else {
            add({ t: 'toolUse', name, summary: toolSummary(name, input), detail: prettyJSON(input) });
          }
          break;
        }
        case 'tool_result': {
          const useID = str(block.tool_use_id);
          const idxs = useID !== undefined ? questionItems.get(useID) : undefined;
          if (useID !== undefined && idxs) {
            questionItems.delete(useID);
            const declined = bool(block.is_error) ?? false;
            const tur = obj.toolUseResult;
            const rawAnswers = isObj(tur) ? tur.answers : undefined;
            const answers: Dict = isObj(rawAnswers) && Object.values(rawAnswers).every((v) => typeof v === 'string')
              ? rawAnswers : {};
            for (const i of idxs) {
              const it = items[i];
              if (!it || it.kind.t !== 'question') continue;
              const q = { ...it.kind.q };
              if (declined) q.declined = true;
              else q.answer = str(answers[q.question]) ?? '';
              it.kind = { t: 'question', q };
            }
          }
          const tool = (useID !== undefined ? toolNames.get(useID) : undefined) ?? 'tool';
          add({ t: 'toolResult', tool, content: resultText(block.content), isError: bool(block.is_error) ?? false });
          break;
        }
        default:
          continue;
      }
    }
  }
  for (const qs of pendingDumps) {
    if (sameStrings(qs.map((q) => q.question), lastAskedQuestions)) continue;
    qs.forEach((q) => items.push({ kind: { t: 'question', q } }));
  }
  return { items, cleared };
}

const range = (a: number, b: number) => Array.from({ length: Math.max(0, b - a) }, (_, i) => a + i);
const sameStrings = (a: string[], b: string[]) => a.length === b.length && a.every((x, i) => x === b[i]);

// MARK: - Shared-folder paths (GuestSharePaths)

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/** `/mnt/bromure-share-<i+1>` → `~/<name>` for each share name in order. */
export function shareNames(mountNames: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  mountNames.forEach((n, i) => { if (n) out[`/mnt/bromure-share-${i + 1}`] = '~/' + n; });
  return out;
}

/** `text` with each share root (a whole path component) read as its folder. */
export function displaySharePaths(text: string, names: Record<string, string>): string {
  const escaped = text.includes('\\/mnt\\/bromure-share-');
  const entries = Object.entries(names);
  if (!entries.length || !(text.includes('/mnt/bromure-share-') || escaped)) return text;
  let out = text;
  for (const [root, shown] of entries.sort((a, b) => b[0].length - a[0].length)) {
    if (shown.includes('"') || shown.includes('\\')) continue;
    out = out.replace(new RegExp(escapeRe(root) + '(?![0-9A-Za-z_-])', 'g'), () => shown);
    if (escaped) {
      const eRoot = root.replace(/\//g, '\\/');
      const eShown = shown.replace(/\//g, '\\/');
      out = out.replace(new RegExp(escapeRe(eRoot) + '(?![0-9A-Za-z_-])', 'g'), () => eShown);
    }
  }
  return out;
}

export const GUEST_HOME = '/home/ubuntu';
/** The guest's home as "~" — a whole leading path component only. */
export function homeDisplay(text: string): string {
  let out = text;
  if (out.includes(GUEST_HOME)) {
    out = out.replace(/(?<![0-9A-Za-z_.~/\-])\/home\/ubuntu(?![0-9A-Za-z_.-])/g, '~');
  }
  if (out.includes('\\/home\\/ubuntu')) {
    out = out.replace(/(?<![0-9A-Za-z_.~/-])\\\/home\\\/ubuntu(?![0-9A-Za-z_.-])/g, '~');
  }
  return out;
}

export const isShellTool = (name: string) =>
  ['bash', 'shell', 'exec_command', 'local_shell', 'run_terminal_command', 'terminal'].includes(name.toLowerCase());

/** The items with share paths read as folders (tool calls, results, the
 *  agent's prose — never what the user typed); tool-call headers also read
 *  the guest home as "~" (except command lines). */
export function rewriteSharePaths(items: TranscriptItem[], names: Record<string, string>): TranscriptItem[] {
  const empty = Object.keys(names).length === 0;
  const d = (s: string) => (empty ? s : displaySharePaths(s, names));
  return items.map((item) => {
    const k = item.kind;
    switch (k.t) {
      case 'toolUse': {
        const shell = isShellTool(k.name);
        const detail = parseDisplayRequest(k.name, k.detail) ? k.detail : shell ? d(k.detail) : homeDisplay(d(k.detail));
        return { ...item, kind: { t: 'toolUse', name: k.name, summary: shell ? d(k.summary) : homeDisplay(d(k.summary)), detail } };
      }
      case 'toolResult': return { ...item, kind: { ...k, content: d(k.content) } };
      case 'assistantText': return { ...item, kind: { t: 'assistantText', text: d(k.text) } };
      case 'thinking': return { ...item, kind: { t: 'thinking', text: d(k.text) } };
      default: return item;
    }
  });
}

// MARK: - Display MCP (DisplayRequest.parse)

export type DisplayRequest =
  | { t: 'media'; path: string; title?: string; caption?: string }
  | { t: 'chart'; spec: string; title?: string; caption?: string }
  | { t: 'file'; path: string; note?: string };

/** A display-MCP call (`mcp__display__show_chart`, `display.show_media`, …). */
export function parseDisplayRequest(name: string, detail: string): DisplayRequest | undefined {
  const n = name.toLowerCase();
  const media = n.endsWith('show_media'), chart = n.endsWith('show_chart'), send = n.endsWith('send_file');
  if (!(media || chart || send)) return undefined;
  if (!(n.includes('display') || n === 'show_media' || n === 'show_chart' || n === 'send_file')) return undefined;
  const input = parseObj(detail);
  if (!input) return undefined;
  const nonEmpty = (v: unknown) => { const s = str(v); return s ? s : undefined; };
  if (send) {
    const path = str(input.path);
    if (!path || !path.startsWith('/')) return undefined;
    return { t: 'file', path, note: nonEmpty(input.note) };
  }
  const title = nonEmpty(input.title), caption = nonEmpty(input.caption);
  if (media) {
    const path = str(input.path);
    if (!path || !path.startsWith('/')) return undefined;
    return { t: 'media', path, title, caption };
  }
  let spec: unknown = input.spec;
  if (typeof spec === 'string') spec = parseJSON(spec);
  if (!isObj(spec)) return undefined;
  return { t: 'chart', spec: sortedJSON(spec), title, caption };
}

// MARK: - ActivitySummary.humanTool

export const OMP_TOOL_LOOKUP = 'tool_lookup';
export const OMP_READ_OUTPUT = 'read_output';

/** A tool name for people: "mcp__delegation__request" → "delegation request". */
export function humanTool(name: string): string {
  if (name === OMP_TOOL_LOOKUP) return 'tool lookup';
  if (name === OMP_READ_OUTPUT) return 'earlier output';
  if (!name.startsWith('mcp__')) return name;
  const rest = name.slice(5);
  let words: string[];
  const sep = rest.indexOf('__');
  if (sep >= 0) {
    const server = rest.slice(0, sep);
    let tool = rest.slice(sep + 2);
    const s = server.toLowerCase(), t = tool.toLowerCase();
    if (s && t.length > s.length && t.startsWith(s)) {
      const next = t[s.length];
      if (next === '_' || next === '-') tool = tool.slice(s.length + 1);
    }
    words = [...server.split(/[_-]/).filter(Boolean), ...tool.split('_').filter(Boolean)];
  } else {
    words = rest.split('_').filter(Boolean);
  }
  return words.join(' ');
}

// MARK: - Dispatch

const KNOWN = ['claude', 'codex', 'grok', 'kimi', 'omp'];

function resolveAgent(text: string, agent?: string): string {
  if (agent === 'hermes') return 'claude';
  if (agent && KNOWN.includes(agent)) return agent;
  return sniffAgent(text);
}

/** Every transcript render: the parser for the agent that wrote the file
 *  (`hermes` mirrors Claude's format; unknown/absent agents are sniffed),
 *  then stable ids. `cleared`: a Claude `/clear` started the chat over. */
export function parseTranscript(text: string, agent?: string): { items: TranscriptItem[]; cleared: boolean } {
  let raw: Raw[];
  let cleared = false;
  switch (resolveAgent(text, agent)) {
    case 'codex': raw = parseCodex(text); break;
    case 'grok': raw = parseGrok(text); break;
    case 'kimi': raw = parseKimi(text); break;
    case 'omp': raw = parseOmp(text); break;
    default: ({ items: raw, cleared } = parseClaude(text));
  }
  return { items: stableIDs(raw), cleared };
}

const STABLE_TAG: Record<TranscriptKind['t'], number> = {
  userText: 1, assistantText: 2, thinking: 3, toolUse: 4, toolResult: 5, question: 6, todo: 7, agentError: 8,
};

/** Re-key items by what they ARE (kind + when written) plus their rank among
 *  equals, so ids survive the bytes in front of them changing. */
export function stableIDs(items: { kind: TranscriptKind; timestamp?: number }[]): TranscriptItem[] {
  const rank = new Map<string, number>();
  return items.map((it) => {
    const key = `${STABLE_TAG[it.kind.t]}:${it.timestamp ?? -1}`;
    const n = rank.get(key) ?? 0;
    rank.set(key, n + 1);
    const out: TranscriptItem = { id: `${key}:${n}`, kind: it.kind };
    if (it.timestamp !== undefined) out.timestamp = it.timestamp;
    return out;
  });
}

export const SNIFF_LINES = 200;

/** Whether `sniffAgent` saw all it reads, so a longer copy reads the same. */
export function sniffIsSettled(text: string): boolean {
  let n = 0;
  for (let i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) if (++n >= SNIFF_LINES) return true;
  return false;
}

/** Which agent wrote this file, from line shapes alone (default "claude"). */
export function sniffAgent(text: string): string {
  // Only the first SNIFF_LINES lines matter: don't split a multi-MB file.
  let end = 0, count = 0;
  while (count < SNIFF_LINES + 1 && end < text.length) {
    const nl = text.indexOf('\n', end);
    if (nl < 0) { end = text.length; break; }
    end = nl + 1;
    count++;
  }
  for (const line of lines(text.slice(0, end)).slice(0, SNIFF_LINES)) {
    const obj = parseObj(line);
    if (!obj) continue;
    const method = str(obj.method);
    if (method !== undefined && method.endsWith('session/update')) return 'grok';
    if (isObj(obj.params) && isObj(obj.params.update)) return 'grok';
    const type = str(obj.type) ?? '';
    if (type === 'session' && has(obj, 'cwd') && has(obj, 'version')) return 'omp';
    if (type === 'model_change' && has(obj, 'model')) return 'omp';
    if (type === 'message' && isObj(obj.message) && typeof obj.message.role === 'string') return 'omp';
    if (type.includes('.')) return 'kimi';
    if (type === 'metadata' && has(obj, 'protocol_version')) return 'kimi';
    if (isObj(obj.payload) && ['session_meta', 'response_item', 'event_msg', 'turn_context', 'compacted'].includes(type)) return 'codex';
    if ((type === 'user' || type === 'assistant') && has(obj, 'message')) return 'claude';
    if (type === 'message' && typeof obj.role === 'string' && !has(obj, 'message')) return 'codex';
  }
  return 'claude';
}

/** The model the conversation's latest turn ran on, where the agent records
 *  it (Codex `turn_context`); undefined otherwise. */
export function latestModel(text: string, agent?: string): string | undefined {
  return resolveAgent(text, agent) === 'codex' ? codexLatestModel(text) : undefined;
}

// MARK: - omp parser

export function parseOmp(text: string): Raw[] {
  const items: Raw[] = [];
  const toolNames = new Map<string, string>();
  let todoInit: TodoRow[] = [];
  let todoResult: string | undefined;
  let todoAnchor: number | undefined;
  const askAnchors = new Map<string, { at: number; questions: TranscriptQuestion[] }>();

  for (const line of lines(text)) {
    const obj = parseObj(line);
    if (!obj || obj.type !== 'message' || !isObj(obj.message)) continue;
    const message = obj.message;
    const role = str(message.role);
    if (role === undefined) continue;
    const isUser = role === 'user';
    const stamp = parseISODate(obj.timestamp);
    const add = (kind: TranscriptKind) => { items.push({ kind, timestamp: stamp }); };

    if (role === 'toolResult') {
      const callID = str(message.toolCallId);
      const tool = (callID !== undefined ? toolNames.get(callID) : undefined) ?? str(message.toolName) ?? 'tool';
      const content = resultText(message.content);
      if (tool === 'todo' && todoAnchor !== undefined) { todoResult = content; continue; }
      if (tool === 'ask' && callID !== undefined) {
        const anchor = askAnchors.get(callID);
        if (anchor) {
          askAnchors.delete(callID);
          const answered = answeredAsk(anchor.questions, content, bool(message.isError) ?? false);
          if (answered.length) {
            items[anchor.at].kind = { t: 'question', q: answered[0] };
            answered.slice(1).forEach((q) => add({ t: 'question', q }));
            continue;
          }
        }
      }
      add({ t: 'toolResult', tool, content, isError: bool(message.isError) ?? false });
      continue;
    }
    if (role !== 'user' && role !== 'assistant') continue;

    if (role === 'assistant' && message.stopReason === 'error') {
      const t = trim(str(message.errorMessage) ?? '');
      const status = int(message.errorStatus);
      const errorID = int(message.errorId);
      const userStop = errorID !== undefined && (hasBit(errorID, 0x4000000) || hasBit(errorID, 0x8000000));
      if (!userStop && (status !== undefined || errorID !== undefined || t)) {
        add({ t: 'agentError', error: classifyAPIError.omp(errorID, status, t) });
      }
    }

    if (typeof message.content === 'string') {
      const t = trim(isUser ? unwrapAttachments(message.content) : message.content);
      if (t) add(isUser ? { t: 'userText', text: t } : { t: 'assistantText', text: t });
      continue;
    }
    const blocks = dicts(message.content);
    if (!blocks) continue;
    for (const block of blocks) {
      switch (str(block.type)) {
        case 'text': {
          const rawText = str(block.text) ?? '';
          const s = trim(isUser ? unwrapAttachments(rawText) : rawText);
          if (s) add(isUser ? { t: 'userText', text: s } : { t: 'assistantText', text: s });
          break;
        }
        case 'thinking': {
          const s = trim(str(block.thinking) ?? str(block.text) ?? '');
          if (s) add({ t: 'thinking', text: s });
          break;
        }
        case 'toolCall': case 'tool_use': {
          let name = str(block.name) ?? 'tool';
          let input = ompToolInput(block);
          let virtualSummary: string | undefined;
          const v = ompVirtualCall(name, input);
          if (v) { name = v.name; input = v.input; virtualSummary = v.summary; }
          const id = str(block.id);
          if (id !== undefined) toolNames.set(id, name);
          if (name === 'todo') {
            const rows = todoRows(input);
            if (rows.length) todoInit = rows;
            if (todoInit.length && todoAnchor === undefined) {
              todoAnchor = items.length;
              add({ t: 'todo', title: 'To-dos', rows: todoInit });
            }
            continue;
          }
          const questions = name === 'AskUserQuestion' ? parseQuestions(input) : [];
          if (questions.length) {
            questions.forEach((q) => add({ t: 'question', q }));
          } else {
            if (name === 'ask' && id !== undefined) {
              const asked = ompAskQuestions(input);
              if (asked.length) askAnchors.set(id, { at: items.length, questions: asked });
            }
            const intent = str(block.intent) !== undefined ? trim(block.intent) : undefined;
            const summary = intent ? intent : virtualSummary ?? toolSummary(name, input);
            add({ t: 'toolUse', name, summary, detail: prettyJSON(input) });
          }
          break;
        }
        case 'tool_result': {
          const useID = str(block.tool_use_id);
          const tool = (useID !== undefined ? toolNames.get(useID) : undefined) ?? 'tool';
          add({ t: 'toolResult', tool, content: resultText(block.content), isError: bool(block.is_error) ?? false });
          break;
        }
        default:
          continue;
      }
    }
  }
  if (todoAnchor !== undefined) {
    items[todoAnchor].kind = { t: 'todo', title: 'To-dos', rows: todoMerge(todoInit, todoResult) };
  }
  return items;
}

/** omp's `ask` arguments: `questions: [{id, question, options, multi?}]`. */
export function ompAskQuestions(input: Dict): TranscriptQuestion[] {
  const qs = dicts(input.questions);
  if (!qs) return [];
  return qs.flatMap((q) => {
    const text = str(q.question);
    if (!text) return [];
    return [{ question: text, header: str(q.id) ?? '', multiSelect: bool(q.multi) ?? false, options: parseOptions(q.options) }];
  });
}

/** The questions with what the user answered, from omp's `ask` result text. */
export function answeredAsk(questions: TranscriptQuestion[], result: string, isError: boolean): TranscriptQuestion[] {
  const out = questions.map((q) => ({ ...q }));
  const ls = lines(result).map(trimWS);
  const value = (prefix: string) => {
    const l = ls.find((x) => x.startsWith(prefix));
    return l === undefined ? undefined : trimWS(l.slice(prefix.length));
  };
  const cancelled = isError || result.includes('User cancelled the selection')
    || result.includes('User did not select any options');
  for (const q of out) {
    if (cancelled) { q.declined = true; continue; }
    let answer: string | undefined;
    if (questions.length === 1) answer = value('User selected:') ?? value('User provided custom input:');
    if (answer === undefined && q.header) {
      const a0 = value(q.header + ':');
      if (a0 !== undefined) {
        let a = a0;
        if (a.startsWith('[') && a.endsWith(']')) a = a.length >= 2 ? a.slice(1, -1) : '';
        if (a.startsWith('"') && a.endsWith('"') && a.length >= 2) a = a.slice(1, -1);
        answer = a;
      }
    }
    if (answer === '(cancelled)') { q.declined = true; continue; }
    q.answer = answer ?? '';
  }
  return out;
}

/** omp's large-paste marker `<attachment>\n…\n</attachment>`, unwrapped. */
export function unwrapAttachments(text: string): string {
  if (!text.includes('<attachment>')) return text;
  return text.replace(/<attachment>\r?\n?([\s\S]*?)\r?\n?<\/attachment>/g, '$1');
}

export interface VirtualCall { name: string; summary?: string; input: Dict }

/** A read/write that isn't a file: omp's `xd://<tool>` devices and
 *  `artifact://N` spilled output. */
export function ompVirtualCall(name: string, input: Dict): VirtualCall | undefined {
  const n = name.toLowerCase();
  const p = str(input.path);
  if (!(n === 'read' || n === 'write') || p === undefined) return undefined;
  const path = trim(p);
  const lower = path.toLowerCase();
  if (lower.startsWith('xd://')) {
    const tool = path.slice(5).split(/[/?#:]/).find((x) => x.length > 0) ?? '';
    if (n === 'write') {
      if (!tool) return undefined;
      let args: Dict = {};
      if (isObj(input.content)) args = input.content;
      else if (typeof input.content === 'string') args = parseObj(input.content) ?? {};
      return { name: tool, input: args };
    }
    const label = tool ? `Looking up ${humanTool(tool)}` : 'Listing its tools';
    return { name: OMP_TOOL_LOOKUP, summary: label, input: tool ? { tool } : {} };
  }
  if (n === 'read' && lower.startsWith('artifact://')) {
    const rest = path.slice('artifact://'.length);
    const id = /^\p{N}*/u.exec(rest)?.[0] ?? '';
    const label = id ? `Reading earlier output #${id}` : 'Reading earlier output';
    return { name: OMP_READ_OUTPUT, summary: label, input: { artifact: rest } };
  }
  return undefined;
}

function ompToolInput(block: Dict): Dict {
  if (isObj(block.input)) return block.input;
  if (isObj(block.arguments)) return block.arguments;
  for (const k of ['arguments', 'input', 'partialArgs']) {
    if (typeof block[k] === 'string') {
      const d = parseObj(block[k]);
      if (d) return d;
    }
  }
  return {};
}

// MARK: - Codex parser

interface CodexState {
  toolNames: Map<string, string>;
  scripts: Map<string, CodeModeCall[]>;
  waits: Map<string, string>;
  runningCells: Map<string, CodeModeCall[]>;
  hidden: Set<string>;
}

export function parseCodex(text: string): Raw[] {
  const primary: Raw[] = [];
  const fallback: Raw[] = [];
  const state: CodexState = { toolNames: new Map(), scripts: new Map(), waits: new Map(), runningCells: new Map(), hidden: new Set() };
  for (const line of lines(text)) {
    const obj = parseObj(line);
    if (!obj) continue;
    const stamp = parseISODate(obj.timestamp);
    const type = str(obj.type) ?? '';
    switch (type) {
      case 'response_item':
        if (!isObj(obj.payload)) continue;
        for (const kind of codexResponseItemKinds(obj.payload, state)) primary.push({ kind, timestamp: stamp });
        break;
      case 'event_msg': {
        if (!isObj(obj.payload)) continue;
        const err = codexTurnError(obj.payload);
        if (err) {
          primary.push({ kind: err, timestamp: stamp });
          fallback.push({ kind: err, timestamp: stamp });
          continue;
        }
        for (const kind of codexEventKinds(obj.payload)) fallback.push({ kind, timestamp: stamp });
        break;
      }
      case 'message': case 'reasoning': case 'function_call': case 'function_call_output':
      case 'local_shell_call': case 'custom_tool_call': case 'custom_tool_call_output': case 'web_search_call':
        if (has(obj, 'payload')) continue;
        for (const kind of codexResponseItemKinds(obj, state)) primary.push({ kind, timestamp: stamp });
        break;
      default:
        continue;
    }
  }
  const hasConversation = primary.some((r) => r.kind.t === 'userText' || r.kind.t === 'assistantText');
  return hasConversation || fallback.length === 0 ? primary : fallback;
}

/** The model of Codex's latest turn (`turn_context` records). */
export function codexLatestModel(text: string): string | undefined {
  let model: string | undefined;
  for (const line of lines(text)) {
    if (!line.includes('"turn_context"')) continue;
    const obj = parseObj(line);
    if (!obj || obj.type !== 'turn_context' || !isObj(obj.payload)) continue;
    const m = str(obj.payload.model);
    if (m) model = m;
  }
  return model;
}

function codexResponseItemKinds(payload: Dict, state: CodexState): TranscriptKind[] {
  switch (str(payload.type) ?? '') {
    case 'message': {
      const role = str(payload.role) ?? '';
      if (role !== 'user' && role !== 'assistant') return [];
      const t = trim((dicts(payload.content) ?? []).flatMap((b) => {
        if (!['input_text', 'output_text', 'text'].includes(str(b.type) ?? '')) return [];
        const s = str(b.text);
        if (s === undefined) return [];
        return role === 'user' && isInjectedContext(s) ? [] : [s];
      }).join('\n'));
      if (!t) return [];
      return [role === 'user' ? { t: 'userText', text: t } : { t: 'assistantText', text: t }];
    }
    case 'reasoning': {
      const parts = [
        ...(dicts(payload.summary) ?? []).flatMap((b) => (typeof b.text === 'string' ? [b.text] : [])),
        ...(dicts(payload.content) ?? []).flatMap((b) => (typeof b.text === 'string' ? [b.text] : [])),
      ];
      const t = trim(parts.join('\n\n'));
      return t ? [{ t: 'thinking', text: t }] : [];
    }
    case 'function_call': {
      const name = str(payload.name) ?? 'tool';
      const callID = str(payload.call_id);
      const argsString = str(payload.arguments) ?? '';
      const args = parseObj(argsString);
      if (name === 'wait' && callID !== undefined) {
        const cell = cellID(args?.cell_id);
        if (cell !== undefined && state.runningCells.has(cell)) {
          state.waits.set(callID, cell);
          return [];
        }
      }
      if (callID !== undefined) state.toolNames.set(callID, name);
      const summary = (args ? shellSummary(args.command) : undefined)
        ?? (args ? toolSummary(name, args) : undefined)
        ?? prefixChars(argsString, 200);
      const detail = args ? prettyJSON(args) : argsString;
      return [{ t: 'toolUse', name, summary, detail }];
    }
    case 'local_shell_call': {
      const id = str(payload.call_id);
      if (id !== undefined) state.toolNames.set(id, 'shell');
      const action: Dict = isObj(payload.action) ? payload.action : {};
      return [{ t: 'toolUse', name: 'shell', summary: shellSummary(action.command) ?? '', detail: prettyJSON(action) }];
    }
    case 'custom_tool_call': {
      const name = str(payload.name) ?? 'tool';
      const callID = str(payload.call_id);
      const input = str(payload.input) ?? '';
      if (name === 'exec') {
        const calls = codeModeCalls(input);
        if (calls.length) {
          if (callID !== undefined) state.scripts.set(callID, calls);
          return calls.flatMap(callKinds);
        }
        if (input.includes('ALL_TOOLS') && callID !== undefined) {
          state.hidden.add(callID);
          return [];
        }
      }
      if (callID !== undefined) state.toolNames.set(callID, name);
      if (name === 'apply_patch') return callKinds({ name, args: input, hasArgs: true, raw: '' });
      return [{ t: 'toolUse', name, summary: prefixChars(input, 200), detail: input }];
    }
    case 'function_call_output': case 'custom_tool_call_output': {
      const callID = str(payload.call_id);
      if (callID !== undefined && state.hidden.has(callID)) return [];
      if (callID !== undefined) {
        const cell = state.waits.get(callID);
        if (cell !== undefined) return scriptResults(payload.output, state.runningCells.get(cell) ?? [], cell, state);
        const calls = state.scripts.get(callID);
        if (calls) return scriptResults(payload.output, calls, undefined, state);
      }
      const tool = (callID !== undefined ? state.toolNames.get(callID) : undefined) ?? 'tool';
      const [content, isError] = codexOutputText(payload.output);
      return [{ t: 'toolResult', tool, content, isError }];
    }
    case 'web_search_call': {
      const action: Dict = isObj(payload.action) ? payload.action : {};
      return [{ t: 'toolUse', name: 'web_search', summary: str(action.query) ?? '', detail: '' }];
    }
    default:
      return [];
  }
}

/** A user-message part Codex wrote, not the user (AGENTS.md, env dump…). */
export function isInjectedContext(text: string): boolean {
  const t = trim(text);
  return t.startsWith('# AGENTS.md instructions for ') || t.startsWith('<user_instructions>')
    || t.startsWith('<environment_context>') || t.startsWith('<INSTRUCTIONS>');
}

function cellID(v: unknown): string | undefined {
  if (typeof v === 'string' && v) return v;
  const n = int(v);
  return n !== undefined ? String(n) : undefined;
}

function scriptResults(output: unknown, calls: CodeModeCall[], cell: string | undefined, state: CodexState): TranscriptKind[] {
  let texts: string[] = [];
  const blocks = dicts(output);
  if (blocks) texts = blocks.flatMap((b) => (typeof b.text === 'string' ? [b.text] : []));
  else if (typeof output === 'string') texts = [output];
  const header = texts[0] ?? '';
  const printed = texts.slice(1);
  if (header.startsWith('Script running')) {
    const id = runningCell(header);
    if (id !== undefined) state.runningCells.set(id, calls);
    return [];
  }
  if (cell !== undefined) state.runningCells.delete(cell);
  const out: TranscriptKind[] = [];
  const used = new Set<number>();
  const results = printed.map(scriptResult);
  for (const call of calls) {
    let i = results.findIndex((r, j) => !used.has(j) && resultFits(r, call, true));
    if (i < 0) i = results.findIndex((r, j) => !used.has(j) && resultFits(r, call, false));
    if (i < 0) continue;
    used.add(i);
    const k = resultKind(results[i], call);
    if (k) out.push(k);
  }
  if (!header.startsWith('Script completed') && header) {
    const body = trim(texts.join('\n'));
    out.push({ t: 'toolResult', tool: calls.length ? callDisplayName(calls[calls.length - 1]) : 'exec', content: body, isError: true });
  }
  return out;
}

function codexTurnError(payload: Dict): TranscriptKind | undefined {
  const type = str(payload.type) ?? '';
  let error: Dict | undefined;
  if (type === 'task_complete' || type === 'turn_complete') error = isObj(payload.error) ? payload.error : undefined;
  else if (type === 'error') error = payload;
  else return undefined;
  if (!error) return undefined;
  const message = trim(str(error.message) ?? '');
  const info = has(error, 'codex_error_info') ? error.codex_error_info : error.codexErrorInfo;
  const infoName = str(info) ?? (isObj(info) ? Object.keys(info)[0] : undefined);
  if (!message && infoName === undefined) return undefined;
  return { t: 'agentError', error: classifyAPIError.codex(infoName, message) };
}

function codexEventKinds(payload: Dict): TranscriptKind[] {
  switch (str(payload.type) ?? '') {
    case 'user_message': {
      if ((str(payload.kind) ?? 'plain') !== 'plain') return [];
      const t = trim(str(payload.message) ?? '');
      return t ? [{ t: 'userText', text: t }] : [];
    }
    case 'agent_message': {
      const t = trim(str(payload.message) ?? '');
      return t ? [{ t: 'assistantText', text: t }] : [];
    }
    case 'agent_reasoning': {
      const t = trim(str(payload.text) ?? '');
      return t ? [{ t: 'thinking', text: t }] : [];
    }
    default:
      return [];
  }
}

/** argv → the command line, unwrapping `bash -lc "…"`. */
function unwrapArgv(argv: string[]): string {
  if (argv.length >= 3 && ['bash', 'sh', 'zsh'].includes(argv[0]) && ['-lc', '-c'].includes(argv[1])) {
    return argv.slice(2).join(' ');
  }
  return argv.join(' ');
}

function shellSummary(command: unknown): string | undefined {
  if (!Array.isArray(command)) return undefined;
  const argv = command.filter((x): x is string => typeof x === 'string');
  if (!argv.length) return undefined;
  return clip(unwrapArgv(argv));
}

function codexOutputText(output: unknown): [string, boolean] {
  const blocks = dicts(output);
  if (blocks) return [blocks.flatMap((b) => (typeof b.text === 'string' ? [b.text] : [])).join('\n'), false];
  if (typeof output !== 'string') return ['', false];
  const obj = parseObj(output);
  if (obj && typeof obj.output === 'string') {
    const exit = isObj(obj.metadata) ? int(obj.metadata.exit_code) : undefined;
    return [obj.output, (exit ?? 0) !== 0];
  }
  return [output, false];
}

// MARK: - Codex code mode

export interface CodeModeCall {
  name: string;
  /** The first argument decoded (object, string, …; JSON null = null). */
  args: unknown;
  /** Whether the argument was a literal (`args != nil` in Swift). */
  hasArgs: boolean;
  raw: string;
}

export function callDisplayName(c: CodeModeCall): string {
  switch (c.name) {
    case 'exec_command': case 'shell': case 'shell_command': case 'local_shell': return 'shell';
    default: return c.name;
  }
}

export function callCommand(c: CodeModeCall): string | undefined {
  if (typeof c.args === 'string' && callDisplayName(c) === 'shell') return c.args;
  if (!isObj(c.args)) return undefined;
  for (const k of ['cmd', 'command']) {
    const v = c.args[k];
    if (typeof v === 'string') return v;
    if (Array.isArray(v)) return unwrapArgv(v.filter((x): x is string => typeof x === 'string'));
  }
  return undefined;
}

export function callPatch(c: CodeModeCall): string | undefined {
  if (typeof c.args === 'string') return c.args;
  if (!isObj(c.args)) return undefined;
  return str(c.args.input) ?? str(c.args.patch);
}

function callKinds(c: CodeModeCall): TranscriptKind[] {
  const patch = callPatch(c);
  if (c.name !== 'apply_patch' || patch === undefined) return [callKind(c)];
  const sections = patchSections(patch);
  if (sections.length <= 1) return [callKind(c)];
  return sections.map((s) => callKind({ name: c.name, args: s, hasArgs: true, raw: '' }));
}

function callKind(c: CodeModeCall): TranscriptKind {
  const cmd = callDisplayName(c) === 'shell' ? callCommand(c) : undefined;
  if (cmd !== undefined) {
    const input: Dict = isObj(c.args) ? { ...c.args } : {};
    delete input.cmd;
    input.command = cmd;
    return { t: 'toolUse', name: 'shell', summary: clip(cmd), detail: prettyJSON(input) };
  }
  const patch = callPatch(c);
  if (c.name === 'apply_patch' && patch !== undefined) {
    const files = patchFiles(patch);
    const input: Dict = { patch };
    if (files.length) input.path = files[0];
    return { t: 'toolUse', name: 'apply_patch', summary: clip(files.join(', ')), detail: prettyJSON(input) };
  }
  if (isObj(c.args)) return { t: 'toolUse', name: c.name, summary: toolSummary(c.name, c.args), detail: prettyJSON(c.args) };
  if (typeof c.args === 'string') return { t: 'toolUse', name: c.name, summary: clip(c.args), detail: c.args };
  return { t: 'toolUse', name: c.name, summary: clip(c.raw), detail: c.raw };
}

/** The files a Codex patch touches. */
export function patchFiles(patch: string): string[] {
  const files: string[] = [];
  for (const line of patch.split('\n')) {
    if (!line) continue;
    for (const p of ['*** Update File: ', '*** Add File: ', '*** Delete File: ', '*** Move to: ']) {
      if (line.startsWith(p)) {
        const f = trimWS(line.slice(p.length));
        if (f && !files.includes(f)) files.push(f);
      }
    }
  }
  return files;
}

/** A multi-file Codex patch split per file, each re-wrapped as a patch. */
export function patchSections(patch: string): string[] {
  const heads = ['*** Update File: ', '*** Add File: ', '*** Delete File: '];
  const sections: string[][] = [];
  for (const raw of patch.split('\n')) {
    const l = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (l.startsWith('*** Begin Patch') || l.startsWith('*** End Patch')) continue;
    if (heads.some((h) => l.startsWith(h))) sections.push([l]);
    else if (sections.length) sections[sections.length - 1].push(l);
  }
  if (!sections.length) return [patch];
  return sections.map((body) => {
    const ls = [...body];
    while (ls.length && trimWS(ls[ls.length - 1]) === '') ls.pop();
    return ['*** Begin Patch', ...ls, '*** End Patch'].join('\n');
  });
}

/** "Script running with cell ID 10…" → "10". */
export function runningCell(header: string): string | undefined {
  const i = header.indexOf('cell ID ');
  if (i < 0) return undefined;
  const id = /^\S*/.exec(header.slice(i + 8))?.[0] ?? '';
  return id || undefined;
}

type ResultShape = 'command' | 'mcp' | 'empty' | 'list' | 'other';
interface ScriptResult { text: string; value: unknown; rejected: boolean; shape: ResultShape }

function scriptResult(text: string): ScriptResult {
  let v = parseJSON(text);
  let rejected = false;
  if (isObj(v) && (v.status === 'fulfilled' || v.status === 'rejected') && Object.keys(v).length <= 2) {
    rejected = v.status === 'rejected';
    v = has(v, 'value') ? v.value : v.reason;
  }
  let shape: ResultShape;
  if (isObj(v)) {
    if (has(v, 'exit_code') || has(v, 'chunk_id') || (has(v, 'session_id') && has(v, 'output'))) shape = 'command';
    else if (Array.isArray(v.content)) shape = 'mcp';
    else if (Object.keys(v).length === 0) shape = 'empty';
    else shape = 'other';
  } else if (Array.isArray(v)) shape = 'list';
  else shape = 'other';
  return { text, value: v, rejected, shape };
}

function resultFits(r: ScriptResult, call: CodeModeCall, strict: boolean): boolean {
  if (r.rejected) return true;
  const dn = callDisplayName(call);
  if (dn === 'shell' || dn === 'write_stdin') return r.shape === 'command';
  if (call.name.startsWith('mcp__')) return r.shape === 'mcp' || (!strict && r.shape === 'other');
  return r.shape === 'empty' || r.shape === 'other';
}

function resultKind(r: ScriptResult, call: CodeModeCall): TranscriptKind | undefined {
  const tool = callDisplayName(call);
  if (r.rejected) {
    const msg = (isObj(r.value) ? str(r.value.message) : undefined) ?? str(r.value) ?? r.text;
    return { t: 'toolResult', tool, content: msg, isError: true };
  }
  switch (r.shape) {
    case 'command': {
      const d: Dict = isObj(r.value) ? r.value : {};
      let out = str(d.output) ?? '';
      const e = d.exit_code;
      const exit = typeof e === 'number' ? Math.trunc(e) : typeof e === 'boolean' ? (e ? 1 : 0) : undefined;
      if (exit !== undefined && exit !== 0) {
        out += (out === '' || out.endsWith('\n') ? '' : '\n') + `(exit code ${exit})`;
      }
      return { t: 'toolResult', tool, content: trimNL(out), isError: (exit ?? 0) !== 0 };
    }
    case 'mcp': {
      const d: Dict = isObj(r.value) ? r.value : {};
      return { t: 'toolResult', tool, content: resultText(d.content), isError: bool(d.isError) ?? false };
    }
    case 'empty':
      return undefined;
    default: {
      const s = str(r.value) ?? r.text;
      if (!trim(s)) return undefined;
      return { t: 'toolResult', tool, content: s, isError: false };
    }
  }
}

// Source scanning — over code points (Swift's unicodeScalars).

const isAlnum = (c: string | undefined) => c !== undefined && /^[\p{L}\p{M}\p{N}]$/u.test(c);
const isIdent = (c: string | undefined) => isAlnum(c) || c === '_' || c === '$';
const isSpace = (c: string | undefined) => c !== undefined && /^\s$/u.test(c);

/** The `tools.<name>(…)` calls in a code-mode script, in source order;
 *  string literals and comments skipped. */
export function codeModeCalls(script: string): CodeModeCall[] {
  const s = Array.from(script);
  const out: CodeModeCall[] = [];
  const word = Array.from('tools.');
  let i = 0;
  const P = { i: 0 };
  while (i < s.length) {
    const c = s[i];
    if (c === '"' || c === "'" || c === '`') { P.i = i; skipString(s, P); i = P.i; continue; }
    if (c === '/' && s[i + 1] === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (c === '/' && s[i + 1] === '*') {
      i += 2;
      while (i + 1 < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    if (c === 't' && i + word.length < s.length && word.every((w, k) => s[i + k] === w)
      && (i === 0 || (!isIdent(s[i - 1]) && s[i - 1] !== '.'))) {
      let j = i + word.length;
      const nameStart = j;
      while (j < s.length && isIdent(s[j])) j++;
      const name = s.slice(nameStart, j).join('');
      const K = { i: j };
      skipSpace(s, K);
      if (!name || K.i >= s.length || s[K.i] !== '(') { i = j; continue; }
      K.i += 1;
      const argStart = K.i;
      skipSpace(s, K);
      const call: CodeModeCall = { name, args: undefined, hasArgs: false, raw: '' };
      if (K.i < s.length && s[K.i] === ')') {
        call.args = {};
        call.hasArgs = true;
        i = K.i + 1;
      } else {
        const M = { i: K.i };
        const v = jsLiteral(s, M);
        if (v.ok) {
          const N = { i: M.i };
          skipSpace(s, N);
          if (N.i < s.length && (s[N.i] === ')' || s[N.i] === ',')) { call.args = v.value; call.hasArgs = true; }
        }
        let depth = 1;
        const E = { i: argStart };
        while (E.i < s.length && depth > 0) {
          const ch = s[E.i];
          if (ch === '"' || ch === "'" || ch === '`') { skipString(s, E); continue; }
          if (ch === '(' || ch === '{' || ch === '[') depth++;
          if (ch === ')' || ch === '}' || ch === ']') depth--;
          E.i++;
        }
        const end = Math.max(argStart, Math.min(s.length, E.i - 1));
        call.raw = trim(s.slice(argStart, end).join(''));
        i = call.hasArgs ? M.i : argStart;
      }
      out.push(call);
      continue;
    }
    i++;
  }
  return out;
}

interface Cursor { i: number }

function skipSpace(s: string[], p: Cursor) { while (p.i < s.length && isSpace(s[p.i])) p.i++; }

function skipString(s: string[], p: Cursor) {
  const q = s[p.i];
  p.i++;
  while (p.i < s.length) {
    if (s[p.i] === '\\') { p.i += 2; continue; }
    if (s[p.i] === q) { p.i++; return; }
    p.i++;
  }
}

type Lit = { ok: true; value: unknown } | { ok: false };
const FAIL: Lit = { ok: false };

/** A JavaScript literal at `p.i` (object, array, string, number,
 *  true/false/null/undefined → null). */
function jsLiteral(s: string[], p: Cursor): Lit {
  skipSpace(s, p);
  if (p.i >= s.length) return FAIL;
  const c = s[p.i];
  if (c === '{') {
    p.i++;
    const d: Dict = {};
    for (;;) {
      skipSpace(s, p);
      if (p.i >= s.length) return FAIL;
      if (s[p.i] === '}') { p.i++; return { ok: true, value: d }; }
      let key: string;
      if (s[p.i] === '"' || s[p.i] === "'") {
        const k = jsString(s, p);
        if (k === undefined) return FAIL;
        key = k;
      } else {
        const st = p.i;
        while (p.i < s.length && isIdent(s[p.i])) p.i++;
        if (p.i === st) return FAIL;
        key = s.slice(st, p.i).join('');
      }
      skipSpace(s, p);
      if (p.i >= s.length || s[p.i] !== ':') return FAIL;
      p.i++;
      const v = jsLiteral(s, p);
      if (!v.ok) return FAIL;
      d[key] = v.value;
      skipSpace(s, p);
      if (p.i >= s.length) return FAIL;
      if (s[p.i] === ',') { p.i++; continue; }
      if (s[p.i] === '}') { p.i++; return { ok: true, value: d }; }
      return FAIL;
    }
  }
  if (c === '[') {
    p.i++;
    const a: unknown[] = [];
    for (;;) {
      skipSpace(s, p);
      if (p.i >= s.length) return FAIL;
      if (s[p.i] === ']') { p.i++; return { ok: true, value: a }; }
      const v = jsLiteral(s, p);
      if (!v.ok) return FAIL;
      a.push(v.value);
      skipSpace(s, p);
      if (p.i >= s.length) return FAIL;
      if (s[p.i] === ',') { p.i++; continue; }
      if (s[p.i] === ']') { p.i++; return { ok: true, value: a }; }
      return FAIL;
    }
  }
  if (c === '"' || c === "'" || c === '`') {
    const v = jsString(s, p);
    return v === undefined ? FAIL : { ok: true, value: v };
  }
  const st = p.i;
  while (p.i < s.length && (isAlnum(s[p.i]) || s[p.i] === '+' || s[p.i] === '-' || s[p.i] === '.')) p.i++;
  const w = s.slice(st, p.i).join('');
  switch (w) {
    case 'true': return { ok: true, value: true };
    case 'false': return { ok: true, value: false };
    case 'null': case 'undefined': return { ok: true, value: null };
    default: {
      if (/^[+-]?\d+$/.test(w)) return { ok: true, value: Number(w) };
      if (w && /^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(w)) return { ok: true, value: Number(w) };
      return FAIL;
    }
  }
}

const HEX = /^[0-9a-fA-F]+$/;

/** A quoted string literal, escapes decoded; a template literal with `${`
 *  isn't a literal (undefined). */
function jsString(s: string[], p: Cursor): string | undefined {
  const q = s[p.i];
  p.i++;
  const out: string[] = [];
  const hex = (n: number): string | undefined => {
    if (p.i + n > s.length) return undefined;
    const h = s.slice(p.i, p.i + n).join('');
    if (!HEX.test(h)) return undefined;
    p.i += n;
    return String.fromCodePoint(parseInt(h, 16));
  };
  while (p.i < s.length) {
    const c = s[p.i];
    if (c === q) { p.i++; return out.join(''); }
    if (q === '`' && c === '$' && s[p.i + 1] === '{') return undefined;
    if (c === '\\' && p.i + 1 < s.length) {
      const e = s[p.i + 1];
      p.i += 2;
      switch (e) {
        case 'n': out.push('\n'); break;
        case 't': out.push('\t'); break;
        case 'r': out.push('\r'); break;
        case 'b': out.push('\b'); break;
        case 'f': out.push('\f'); break;
        case 'v': out.push('\v'); break;
        case '0': out.push('\0'); break;
        case '\n': break;
        case 'x': { const h = hex(2); if (h === undefined) return undefined; out.push(h); break; }
        case 'u': {
          if (s[p.i] === '{') {
            p.i++;
            const st = p.i;
            while (p.i < s.length && s[p.i] !== '}') p.i++;
            const h = s.slice(st, p.i).join('');
            if (p.i >= s.length || !HEX.test(h)) return undefined;
            const v = parseInt(h, 16);
            if (v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff)) return undefined;
            p.i++;
            out.push(String.fromCodePoint(v));
          } else {
            if (p.i + 4 > s.length) return undefined;
            const h = s.slice(p.i, p.i + 4).join('');
            if (!HEX.test(h)) return undefined;
            const v = parseInt(h, 16);
            p.i += 4;
            const loH = s.slice(p.i + 2, p.i + 6).join('');
            if (v >= 0xd800 && v <= 0xdbff && p.i + 6 <= s.length && s[p.i] === '\\' && s[p.i + 1] === 'u'
              && HEX.test(loH) && parseInt(loH, 16) >= 0xdc00 && parseInt(loH, 16) <= 0xdfff) {
              const lo = parseInt(loH, 16);
              p.i += 6;
              out.push(String.fromCodePoint(0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00)));
            } else if (!(v >= 0xd800 && v <= 0xdfff)) {
              out.push(String.fromCodePoint(v));
            }
          }
          break;
        }
        default: out.push(e);
      }
      continue;
    }
    out.push(c);
    p.i++;
  }
  return undefined;
}

// MARK: - Grok parser

export function parseGrok(text: string): Raw[] {
  const items: Raw[] = [];
  const toolNames = new Map<string, string>();
  let recordKind = '';
  let lastUserPromptIndex: number | undefined;

  for (const line of lines(text)) {
    const obj = parseObj(line);
    if (!obj || !isObj(obj.params) || !isObj(obj.params.update)) continue;
    const update = obj.params.update;
    const kind = str(update.sessionUpdate);
    if (kind === undefined) continue;
    const ts = num(obj.timestamp);
    const stamp = ts !== undefined ? ts * 1000 : undefined;
    const add = (k: TranscriptKind) => { items.push({ kind: k, timestamp: stamp }); };
    const prevRecordKind = recordKind;
    recordKind = kind;

    switch (kind) {
      case 'user_message_chunk': case 'agent_message_chunk': case 'agent_thought_chunk': {
        const chunk = grokChunkText(update.content);
        if (!chunk) continue;
        const promptIndex = isObj(update._meta) ? int(update._meta.promptIndex) : undefined;
        const newPrompt = kind === 'user_message_chunk'
          && (prevRecordKind !== 'user_message_chunk'
            || (promptIndex !== undefined && lastUserPromptIndex !== undefined && promptIndex !== lastUserPromptIndex));
        if (kind === 'user_message_chunk') lastUserPromptIndex = promptIndex;
        const last = items[items.length - 1];
        const merged = !newPrompt && last ? grokMerged(last.kind, kind, chunk) : undefined;
        if (merged) last.kind = merged;
        else if (kind === 'user_message_chunk') add({ t: 'userText', text: chunk });
        else if (kind === 'agent_message_chunk') add({ t: 'assistantText', text: chunk });
        else add({ t: 'thinking', text: chunk });
        break;
      }
      case 'tool_call': {
        const rawName = str(update.title) ?? str(update.kind) ?? 'tool';
        const meta = isObj(update._meta) && isObj(update._meta['x.ai/tool']) ? update._meta['x.ai/tool'] : undefined;
        const name = grokDisplayName(rawName, str(meta?.kind), meta?.namespace === 'grok_build');
        const id = str(update.toolCallId);
        if (id !== undefined) toolNames.set(id, name);
        const input = isObj(update.rawInput) ? grokCanonicalInput(update.rawInput) : undefined;
        add({ t: 'toolUse', name, summary: input ? toolSummary(name, input) : '', detail: input ? prettyJSON(input) : '' });
        break;
      }
      case 'tool_call_update': {
        const status = str(update.status) ?? '';
        if (status !== 'completed' && status !== 'failed') continue;
        const id = str(update.toolCallId);
        const tool = (id !== undefined ? toolNames.get(id) : undefined) ?? 'tool';
        let content = (dicts(update.content) ?? []).flatMap((it) => {
          switch (str(it.type) ?? '') {
            case 'content': { const t = isObj(it.content) ? str(it.content.text) : undefined; return t !== undefined ? [t] : []; }
            case 'diff': { const p = str(it.path); return p !== undefined ? [`diff: ${p}`] : []; }
            default: return [];
          }
        }).join('\n');
        if (!content) {
          if (typeof update.rawOutput === 'string') content = update.rawOutput;
          else if (isObj(update.rawOutput)) content = prettyJSON(update.rawOutput);
        }
        add({ t: 'toolResult', tool, content, isError: status === 'failed' });
        break;
      }
      case 'retry_state': {
        const st = str(update.type) ?? '';
        if (st !== 'failed' && st !== 'exhausted') continue;
        let t = trim(str(update.message) ?? str(update.reason) ?? '');
        if (bromureBlockOf(t) === undefined) {
          const b = jsonStrings(update).find((x) => bromureBlockOf(x) !== undefined);
          if (b !== undefined) t = trim(b);
        }
        add({ t: 'agentError', error: classifyAPIError.grok(str(update.error_type), bool(update.is_rate_limited) ?? false, t) });
        break;
      }
      default:
        continue;
    }
  }
  return trimmedTextItems(items);
}

/** Every string in a JSON value, depth-first (sorted keys). */
export function jsonStrings(value: unknown, depth = 0): string[] {
  if (depth >= 8) return [];
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap((v) => jsonStrings(v, depth + 1));
  if (isObj(value)) return Object.keys(value).sort().flatMap((k) => jsonStrings(value[k], depth + 1));
  return [];
}

/** Grok's built-in tools by the names the cards know (Claude's). */
export function grokDisplayName(name: string, kind?: string, builtIn = false): string {
  switch (name) {
    case 'run_terminal_command': case 'run_command': case 'terminal': return 'Bash';
    case 'search_replace': case 'edit_file': case 'str_replace': case 'multi_edit': return 'Edit';
    case 'write_file': case 'create_file': case 'write': return 'Write';
    case 'read_file': case 'view_file': case 'read': return 'Read';
    case 'list_dir': case 'list_directory': case 'ls': return 'LS';
    case 'grep': case 'grep_search': case 'search_files': return 'Grep';
    case 'glob': case 'find_files': case 'file_search': return 'Glob';
    case 'web_fetch': case 'fetch_url': return 'WebFetch';
    case 'web_search': return 'WebSearch';
    case 'todo_write': case 'update_todos': case 'todo': return 'TodoWrite';
  }
  if (!builtIn) return name;
  if (kind === 'execute') return 'Bash';
  if (kind === 'fetch') return 'WebFetch';
  return name;
}

/** Grok's input keys under the names the cards read. */
export function grokCanonicalInput(input: Dict): Dict {
  const out: Dict = { ...input };
  for (const [from, to] of [['target_file', 'file_path'], ['target_directory', 'path'], ['directory', 'path'], ['relative_workspace_path', 'path']]) {
    if (has(out, to)) continue;
    if (has(out, from)) { out[to] = out[from]; delete out[from]; }
  }
  return out;
}

function grokChunkText(content: unknown): string | undefined {
  if (!isObj(content) || content.type !== 'text') return undefined;
  return str(content.text);
}

function grokMerged(last: TranscriptKind, chunkKind: string, text: string): TranscriptKind | undefined {
  if (last.t === 'userText' && chunkKind === 'user_message_chunk') return { t: 'userText', text: last.text + text };
  if (last.t === 'assistantText' && chunkKind === 'agent_message_chunk') return { t: 'assistantText', text: last.text + text };
  if (last.t === 'thinking' && chunkKind === 'agent_thought_chunk') return { t: 'thinking', text: last.text + text };
  return undefined;
}

/** Text kinds trimmed once assembled; empty ones dropped. */
function trimmedTextItems(items: Raw[]): Raw[] {
  const out: Raw[] = [];
  for (const it of items) {
    const k = it.kind;
    if (k.t === 'userText' || k.t === 'assistantText' || k.t === 'thinking') {
      const t = trim(k.text);
      if (!t) continue;
      out.push({ kind: { t: k.t, text: t }, timestamp: it.timestamp });
    } else out.push(it);
  }
  return out;
}

// MARK: - Kimi parser

/** Whether a Kimi journal's tail shows a turn under way (started, not
 *  ended, written within `freshForSec` of `now`). `notBefore` (ms): when the
 *  agent process now running started — an older turn is interrupted. */
export function kimiTurnInProgress(text: string, now: number = Date.now(), freshForSec = 180, notBefore?: number): boolean {
  const tail = text.length > 256_000 ? text.slice(text.length - 256_000) : text;
  const ls = lines(tail);
  let lastTime: number | undefined;
  for (let i = ls.length - 1; i >= 0; i--) {
    const line = ls[i];
    if (!line.includes('"type"')) continue;
    const obj = parseObj(line);
    if (!obj) continue;
    if (lastTime === undefined) lastTime = num(obj.time);
    switch (str(obj.type) ?? '') {
      case 'turn.ended': case 'agent.turn.ended': case 'prompt.completed': return false;
      case 'turn.prompt': case 'agent.turn.started': {
        if (lastTime === undefined) return false;
        const began = num(obj.time);
        if (notBefore !== undefined && began !== undefined && began < notBefore - 2000) return false;
        return (now - lastTime) / 1000 < freshForSec;
      }
      default: continue;
    }
  }
  return false;
}

export function parseKimi(text: string): Raw[] {
  const items: Raw[] = [];
  const toolNames = new Map<string, string>();
  const seenResults = new Set<string>();
  let lastPartStep: string | undefined;

  for (const line of lines(text)) {
    const obj = parseObj(line);
    if (!obj) continue;
    const stamp = num(obj.time);
    const add = (kind: TranscriptKind) => { items.push({ kind, timestamp: stamp }); };

    switch (str(obj.type) ?? '') {
      case 'context.append_message': {
        lastPartStep = undefined;
        if (!isObj(obj.message)) continue;
        const message = obj.message;
        const parts = dicts(message.content) ?? [];
        switch (str(message.role) ?? '') {
          case 'user': {
            const origin = isObj(message.origin) ? str(message.origin.kind) : undefined;
            if (origin !== undefined && origin !== 'user') continue;
            const t = trim(parts.flatMap((p) => (typeof p.text === 'string' ? [p.text] : [])).join('\n'));
            if (!t || t.startsWith('<system-reminder>')) continue;
            add({ t: 'userText', text: t });
            break;
          }
          case 'assistant': {
            for (const part of parts) {
              const think = str(part.think), tx = str(part.text);
              if (think) add({ t: 'thinking', text: think });
              else if (tx) add({ t: 'assistantText', text: tx });
            }
            for (const call of dicts(message.toolCalls) ?? []) {
              const name = str(call.name) ?? 'tool';
              const id = str(call.id);
              if (id !== undefined) toolNames.set(id, name);
              const args = str(call.arguments) ?? '';
              add({ t: 'toolUse', name, summary: prefixChars(args, 200), detail: args });
            }
            break;
          }
          case 'tool': {
            const id = str(message.toolCallId);
            if (id === undefined || seenResults.has(id)) continue;
            seenResults.add(id);
            const t = parts.flatMap((p) => (typeof p.text === 'string' ? [p.text] : [])).join('\n');
            add({ t: 'toolResult', tool: toolNames.get(id) ?? 'tool', content: t, isError: bool(message.isError) ?? false });
            break;
          }
          default: continue;
        }
        break;
      }
      case 'context.append_loop_event': {
        if (!isObj(obj.event)) continue;
        const event = obj.event;
        switch (str(event.type) ?? '') {
          case 'content.part': {
            if (!isObj(event.part)) continue;
            const part = event.part;
            const step = str(event.stepUuid);
            const last = items[items.length - 1];
            const think = str(part.think), tx = str(part.text);
            if (think) {
              if (step !== undefined && step === lastPartStep && last?.kind.t === 'thinking') last.kind = { t: 'thinking', text: last.kind.text + think };
              else add({ t: 'thinking', text: think });
            } else if (tx) {
              if (step !== undefined && step === lastPartStep && last?.kind.t === 'assistantText') last.kind = { t: 'assistantText', text: last.kind.text + tx };
              else add({ t: 'assistantText', text: tx });
            } else continue;
            lastPartStep = step;
            break;
          }
          case 'tool.call': {
            lastPartStep = undefined;
            const name = str(event.name) ?? 'tool';
            const id = str(event.toolCallId);
            if (id !== undefined) toolNames.set(id, name);
            const args = isObj(event.args) ? event.args : undefined;
            add({ t: 'toolUse', name, summary: args ? toolSummary(name, args) : '', detail: args ? prettyJSON(args) : '' });
            break;
          }
          case 'tool.result': {
            lastPartStep = undefined;
            const result: Dict = isObj(event.result) ? event.result : {};
            const id = str(event.toolCallId);
            if (id !== undefined) seenResults.add(id);
            add({ t: 'toolResult', tool: (id !== undefined ? toolNames.get(id) : undefined) ?? 'tool',
              content: resultText(result.output), isError: bool(result.isError) ?? false });
            break;
          }
          default: continue;
        }
        break;
      }
      case 'turn.ended': {
        lastPartStep = undefined;
        if (obj.reason !== 'failed' || !isObj(obj.error)) continue;
        const error = obj.error;
        const details = isObj(error.details) ? error.details : undefined;
        add({ t: 'agentError', error: classifyAPIError.kimi(str(error.code), str(error.name),
          int(details?.statusCode), trim(str(error.message) ?? '')) });
        break;
      }
      default:
        lastPartStep = undefined;
        continue;
    }
  }
  return trimmedTextItems(items);
}

// MARK: - Todo

/** TodoStatus.parse */
export function todoStatusParse(s: string | undefined | null): TodoStatus {
  switch ((s ?? '').toLowerCase()) {
    case 'completed': case 'complete': case 'done': case 'x': return 'done';
    case 'in_progress': case 'inprogress': case 'active': case 'doing': case 'running': return 'active';
    case 'blocked': return 'blocked';
    default: return 'pending';
  }
}

/** TodoStatus.wire — the canonical string (round-trips via todoStatusParse). */
export function todoStatusWire(s: TodoStatus): string {
  switch (s) {
    case 'active': return 'in_progress';
    case 'done': return 'completed';
    default: return s;
  }
}

/** TodoRowModel.id — stable, content-derived. */
export const todoRowID = (r: TodoRow) => (r.phase ?? '') + '\u0001' + r.text;

const row = (text: string, status: TodoStatus, phase?: string): TodoRow =>
  phase !== undefined ? { text, status, phase } : { text, status };

/** A todo/plan tool call's arguments → checklist rows (Claude `todos`, omp
 *  `list`, Codex `plan`); a delta op with no item list yields none. */
export function todoRows(input: unknown): TodoRow[] {
  if (!isObj(input)) return [];
  const todos = dicts(input.todos);
  if (todos) {
    return todos.flatMap((t) => {
      const text = str(t.content) ?? str(t.activeForm) ?? '';
      return text ? [row(text, todoStatusParse(str(t.status)))] : [];
    });
  }
  const list = dicts(input.list);
  if (list) {
    const out: TodoRow[] = [];
    for (const p of list) {
      const phase = str(p.phase);
      for (const it of strings(p.items) ?? []) out.push(row(it, 'pending', phase));
    }
    return out;
  }
  const plan = dicts(input.plan);
  if (plan) {
    return plan.flatMap((p) => {
      const s = str(p.step);
      return s ? [row(s, todoStatusParse(str(p.status)))] : [];
    });
  }
  return [];
}

/** Per-item status from omp's todo RESULT text (absent → done). */
export function todoStatusFromResult(itemText: string, resultText: string): TodoStatus {
  for (const line of lines(resultText)) {
    if (!line.includes(itemText)) continue;
    const l = line.toLowerCase();
    if (l.includes('[x]')) return 'done';
    if (l.includes('[in_progress]') || l.includes('[in progress]')) return 'active';
    if (l.includes('[blocked]')) return 'blocked';
    return 'pending';
  }
  return 'done';
}

/** The plan's items with each status from the latest result text. */
export function todoMerge(initRows: TodoRow[], resultText: string | undefined): TodoRow[] {
  if (!resultText) return initRows;
  return initRows.map((r) => row(r.text, todoStatusFromResult(r.text, resultText), r.phase));
}
