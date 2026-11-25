// The parsed transcript model — TranscriptItem / TranscriptQuestion /
// AgentAPIError / TodoRowModel from ClaudeTranscriptView.swift, as plain data.
// Parsers (parse.ts) produce these; the chat view renders them.

export interface QuestionOption { label: string; description: string }

export interface TranscriptQuestion {
  question: string;
  header: string;
  multiSelect: boolean;
  options: QuestionOption[];
  /** What the user picked once the transcript records the answer ("" when
   *  answered but the pick isn't recorded); undefined while unanswered. */
  answer?: string;
  /** The user dismissed the question instead of answering. */
  declined?: boolean;
}

export const questionResolved = (q: TranscriptQuestion) => q.answer !== undefined || !!q.declined;

export type TodoStatus = 'pending' | 'active' | 'done' | 'blocked';   // TodoStatus in Swift
export interface TodoRow { text: string; status: TodoStatus; phase?: string }

export type APIErrorKind = 'auth' | 'quota' | 'rateLimit' | 'overloaded' | 'other' | 'blocked';
export interface AgentAPIError { kind: APIErrorKind; status?: number; message: string }

export type TranscriptKind =
  | { t: 'userText'; text: string }
  | { t: 'assistantText'; text: string }
  | { t: 'thinking'; text: string }
  /** Tool call: name, a one-line summary (command / file path), and the
   *  full input JSON (pretty-printed string) for the disclosure. */
  | { t: 'toolUse'; name: string; summary: string; detail: string }
  /** Tool result: the tool it answers, trimmed content, error flag. */
  | { t: 'toolResult'; tool: string; content: string; isError: boolean }
  | { t: 'question'; q: TranscriptQuestion }
  | { t: 'todo'; title: string; rows: TodoRow[] }
  | { t: 'agentError'; error: AgentAPIError };

export interface TranscriptItem {
  /** Stable id (AgentTranscript.stableIDs): kind tag + timestamp + rank. */
  id: string;
  kind: TranscriptKind;
  /** ms since epoch, when the line had one. */
  timestamp?: number;
}

export type AgentKind = 'claude' | 'codex' | 'grok' | 'kimi' | 'omp' | 'hermes' | string;
