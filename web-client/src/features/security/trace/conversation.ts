// Port of ConversationParser (ConversationView.swift): turns a captured AI
// exchange (full HTTP wire frames) into a chat-style Conversation.

export type Role = 'system' | 'user' | 'assistant' | 'tool';
export type Block =
  | { kind: 'text'; text: string }
  | { kind: 'toolUse'; name: string; input: string; id?: string }
  | { kind: 'thinking'; text: string }
  | { kind: 'toolResult'; toolUseId?: string; content: string; isError: boolean }
  | { kind: 'image'; mediaType: string };
export interface Message { role: Role; content: Block[] }
export interface Conversation {
  provider: 'anthropic' | 'openai' | 'gemini' | 'cohere' | 'unknown';
  model?: string;
  systemPrompt?: string;
  messages: Message[];
  inputTokens?: number;
  outputTokens?: number;
  requestEnvelope?: string;
}

const dec = new TextDecoder('utf-8', { fatal: false });
const text = (b: Uint8Array) => dec.decode(b);
function json(b: Uint8Array | null): any {
  if (!b) return null;
  try { const v = JSON.parse(text(b)); return v && typeof v === 'object' && !Array.isArray(v) ? v : null; } catch { return null; }
}
const pretty = (v: any) => { try { return JSON.stringify(sortKeys(v), null, 2); } catch { return ''; } };
function sortKeys(v: any): any {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') { const o: any = {}; for (const k of Object.keys(v).sort()) o[k] = sortKeys(v[k]); return o; }
  return v;
}

function indexOfSeq(b: Uint8Array, seq: number[]) {
  outer: for (let i = 0; i + seq.length <= b.length; i++) {
    for (let j = 0; j < seq.length; j++) if (b[i + j] !== seq[j]) continue outer;
    return i;
  }
  return -1;
}
function stripHTTPFraming(raw: Uint8Array | null): Uint8Array | null {
  if (!raw || !raw.length) return raw;
  let i = indexOfSeq(raw, [13, 10, 13, 10]);
  if (i >= 0) return raw.subarray(i + 4);
  i = indexOfSeq(raw, [10, 10]);
  if (i >= 0) return raw.subarray(i + 2);
  return raw;
}

export function hostIsUnder(host: string, domain: string) {
  let h = host.toLowerCase();
  if (!h.startsWith('[') && (h.match(/:/g) ?? []).length === 1) h = h.slice(0, h.indexOf(':'));
  h = h.replace(/\.+$/, '');
  return !!h && (h === domain || h.endsWith('.' + domain));
}

export function parseConversation(host: string, requestBody: Uint8Array | null, responseBody: Uint8Array | null): Conversation | null {
  const req = stripHTTPFraming(requestBody), res = stripHTTPFraming(responseBody);
  const under = (d: string) => hostIsUnder(host, d);
  if (under('anthropic.com')) return parseAnthropic(req, res);
  if (['openai.com', 'chatgpt.com', 'mistral.ai', 'x.ai', 'grok.com', 'groq.com', 'moonshot.ai', 'kimi.ai', 'kimi.com', 'perplexity.ai'].some(under))
    return parseOpenAI(req, res);
  if (under('googleapis.com') || under('google.com')) return parseGemini(req, res);
  if (under('cohere.com')) return parseCohere(req, res);
  return parseAnthropic(req, res) ?? parseOpenAI(req, res) ?? parseGemini(req, res);
}

// ── Anthropic ────────────────────────────────────────────────────────────

function anthropicBlock(b: any): Block | null {
  if (!b || typeof b.type !== 'string') return null;
  switch (b.type) {
    case 'text': return { kind: 'text', text: b.text ?? '' };
    case 'tool_use': return { kind: 'toolUse', name: b.name ?? 'tool', input: b.input && typeof b.input === 'object' ? pretty(b.input) : '', id: b.id };
    case 'thinking': return b.thinking ? { kind: 'thinking', text: b.thinking } : null;
    case 'tool_result': {
      let t = '';
      if (typeof b.content === 'string') t = b.content;
      else if (Array.isArray(b.content)) t = b.content.map((x: any) => x?.text).filter((x: any) => typeof x === 'string').join('\n');
      return { kind: 'toolResult', toolUseId: b.tool_use_id, content: t, isError: !!b.is_error };
    }
    case 'image': return { kind: 'image', mediaType: b.source?.media_type ?? 'image' };
    default: return null;
  }
}
const anthropicBlocks = (a: any): Block[] =>
  typeof a === 'string' ? [{ kind: 'text', text: a }] : Array.isArray(a) ? a.map(anthropicBlock).filter((x): x is Block => !!x) : [];

function sseData(chunk: string): string[] {
  return chunk.split('\n').filter(l => l.startsWith('data:')).map(l => l.slice(5).trim());
}

function parseAnthropicSSE(s: string): Message {
  const by = new Map<number, { type: string; text: string; toolName: string; toolJSON: string; toolID?: string }>();
  let max = -1;
  const acc = (i: number) => by.get(i) ?? by.set(i, { type: 'text', text: '', toolName: '', toolJSON: '' }).get(i)!;
  for (const chunk of s.split('\n\n')) {
    const d = sseData(chunk)[0];
    if (!d) continue;
    let o: any; try { o = JSON.parse(d); } catch { continue; }
    if (!o || typeof o.type !== 'string') continue;
    if (o.type === 'content_block_start' && typeof o.index === 'number' && o.content_block) {
      const a = acc(o.index);
      a.type = o.content_block.type ?? 'text';
      if (a.type === 'tool_use') { a.toolName = o.content_block.name ?? 'tool'; a.toolID = o.content_block.id; }
      max = Math.max(max, o.index);
    } else if (o.type === 'content_block_delta' && typeof o.index === 'number' && o.delta) {
      const a = acc(o.index);
      if (typeof o.delta.text === 'string') a.text += o.delta.text;
      if (typeof o.delta.thinking === 'string') a.text += o.delta.thinking;
      if (typeof o.delta.partial_json === 'string') a.toolJSON += o.delta.partial_json;
      max = Math.max(max, o.index);
    }
  }
  const blocks: Block[] = [];
  for (let i = 0; i <= Math.max(max, 0); i++) {
    const a = by.get(i); if (!a) continue;
    if (a.type === 'tool_use') blocks.push({ kind: 'toolUse', name: a.toolName, input: a.toolJSON, id: a.toolID });
    else if (a.type === 'thinking') { if (a.text) blocks.push({ kind: 'thinking', text: a.text }); }
    else if (a.text) blocks.push({ kind: 'text', text: a.text });
  }
  return { role: 'assistant', content: blocks };
}

function parseAnthropic(req: Uint8Array | null, res: Uint8Array | null): Conversation | null {
  const c: Conversation = { provider: 'anthropic', messages: [] };
  const j = json(req);
  if (j) {
    c.model = j.model;
    if (typeof j.system === 'string') c.systemPrompt = j.system;
    else if (Array.isArray(j.system)) c.systemPrompt = j.system.map((x: any) => x?.text).filter((x: any) => typeof x === 'string').join('\n\n');
    if (Array.isArray(j.messages)) for (const m of j.messages) {
      if (!['system', 'user', 'assistant', 'tool'].includes(m?.role)) continue;
      c.messages.push({ role: m.role, content: anthropicBlocks(m.content) });
    }
  }
  if (res) {
    const r = json(res);
    if (r) {
      if (Array.isArray(r.content)) c.messages.push({ role: 'assistant', content: r.content.map(anthropicBlock).filter((x: any): x is Block => !!x) });
      if (r.usage) { c.inputTokens = r.usage.input_tokens; c.outputTokens = r.usage.output_tokens; }
    } else {
      const a = parseAnthropicSSE(text(res));
      if (a.content.length) c.messages.push(a);
    }
  }
  return c.messages.length ? c : null;
}

// ── OpenAI ───────────────────────────────────────────────────────────────

function parseOpenAI(req: Uint8Array | null, res: Uint8Array | null): Conversation | null {
  const r = json(req);
  if (r) {
    if (r.input !== undefined || r.instructions !== undefined) return parseResponses(r, res);
    if (r.messages !== undefined) return parseChat(r, res);
  }
  const s = json(res);
  if (s) {
    if (s.output !== undefined) return parseResponses(null, res);
    if (s.choices !== undefined) return parseChat(null, res);
  }
  if (res) {
    const sse = text(res);
    if (sse.includes('event: response.')) return parseResponses(null, res);
    if (sse.includes('"choices"')) return parseChat(null, res);
  }
  return null;
}

function openAIBlocks(a: any): Block[] {
  if (typeof a === 'string') return [{ kind: 'text', text: a }];
  if (Array.isArray(a)) return a.map((p: any): Block | null => {
    if (p?.type === 'text' && typeof p.text === 'string') return { kind: 'text', text: p.text };
    if (p?.type === 'image_url') return { kind: 'image', mediaType: 'image' };
    return null;
  }).filter((x): x is Block => !!x);
  return [];
}

function parseChat(j: any, res: Uint8Array | null): Conversation | null {
  const c: Conversation = { provider: 'openai', messages: [] };
  if (j) {
    c.model = j.model;
    if (Array.isArray(j.messages)) for (const m of j.messages) {
      if (typeof m?.role !== 'string') continue;
      const role: Role = m.role === 'developer' || m.role === 'system' ? 'system'
        : m.role === 'tool' || m.role === 'function' ? 'tool' : m.role === 'assistant' ? 'assistant' : 'user';
      if (role === 'system' && c.systemPrompt == null && typeof m.content === 'string') { c.systemPrompt = m.content; continue; }
      c.messages.push({ role, content: openAIBlocks(m.content) });
    }
  }
  if (res) {
    const r = json(res);
    if (r) {
      if (Array.isArray(r.choices)) for (const ch of r.choices) if (ch?.message) c.messages.push({ role: 'assistant', content: openAIBlocks(ch.message.content) });
      if (r.usage) { c.inputTokens = r.usage.prompt_tokens; c.outputTokens = r.usage.completion_tokens; }
    } else {
      let combined = '';
      for (const chunk of text(res).split('\n\n')) for (const line of sseData(chunk)) {
        if (line === '[DONE]') continue;
        try { const o = JSON.parse(line); for (const ch of o?.choices ?? []) if (typeof ch?.delta?.content === 'string') combined += ch.delta.content; } catch {}
      }
      if (combined) c.messages.push({ role: 'assistant', content: [{ kind: 'text', text: combined }] });
    }
  }
  return c.messages.length ? c : null;
}

export function responsesOutputText(o: any): string {
  if (typeof o === 'string') return o;
  if (Array.isArray(o)) return o.map(responsesOutputText).filter(Boolean).join('\n');
  if (o && typeof o === 'object') {
    if (typeof o.text === 'string') return o.text;
    return ['output', 'stdout', 'stderr', 'message', 'content'].map(k => responsesOutputText(o[k])).filter(Boolean).join('\n');
  }
  return '';
}
function outputHasImage(o: any): boolean {
  if (Array.isArray(o)) return o.some(outputHasImage);
  if (o && typeof o === 'object') { const t = String(o.type ?? ''); return t.includes('image') || t.includes('screenshot'); }
  return false;
}
function mapRole(r?: string): Role {
  return r === 'system' || r === 'developer' ? 'system' : r === 'assistant' ? 'assistant' : r === 'tool' || r === 'function' ? 'tool' : 'user';
}
function responsesRole(item: any): Role {
  if (typeof item.role === 'string') return mapRole(item.role);
  const t = String(item.type ?? '');
  if (t.endsWith('_output')) return 'tool';
  if (t.endsWith('_call') || t === 'reasoning') return 'assistant';
  return 'user';
}
function responsesItemBlocks(item: any): Block[] {
  const type = item?.type;
  if (typeof type === 'string') {
    if (type === 'function_call' || type === 'tool_call') {
      const args = typeof item.arguments === 'string' ? item.arguments : item.arguments && typeof item.arguments === 'object' ? pretty(item.arguments) : '';
      return [{ kind: 'toolUse', name: item.name ?? item.call_id ?? 'tool', input: args, id: item.call_id }];
    }
    if (['custom_tool_call', 'local_shell_call', 'shell_call', 'apply_patch_call', 'computer_call'].includes(type)) {
      const a = item.action ?? item.operation;
      const input = typeof item.input === 'string' ? item.input : a != null ? (typeof a === 'string' ? a : JSON.stringify(sortKeys(a))) : '';
      return [{ kind: 'toolUse', name: item.name ?? type, input, id: item.call_id ?? item.id }];
    }
    if (type === 'mcp_call') {
      const blocks: Block[] = [{ kind: 'toolUse', name: item.name ?? 'mcp', input: typeof item.arguments === 'string' ? item.arguments : '', id: item.id }];
      const out = responsesOutputText(item.output), err = responsesOutputText(item.error);
      if (out || err) blocks.push({ kind: 'toolResult', toolUseId: item.id, content: out || err, isError: !out });
      return blocks;
    }
    if (type.endsWith('_output')) {
      const t = responsesOutputText(item.output);
      if (!t && outputHasImage(item.output)) return [{ kind: 'image', mediaType: 'image' }];
      return [{ kind: 'toolResult', toolUseId: item.call_id ?? item.id, content: t, isError: false }];
    }
  }
  if (typeof item?.content === 'string') return [{ kind: 'text', text: item.content }];
  if (Array.isArray(item?.content)) return item.content.map((p: any): Block | null => {
    if (['input_text', 'output_text', 'text'].includes(p?.type)) return typeof p.text === 'string' ? { kind: 'text', text: p.text } : null;
    if (p?.type === 'input_image' || p?.type === 'image') return { kind: 'image', mediaType: 'image' };
    return null;
  }).filter((x: Block | null): x is Block => !!x);
  return [];
}

function parseResponses(j: any, res: Uint8Array | null): Conversation | null {
  const c: Conversation = { provider: 'openai', messages: [] };
  if (j) {
    c.model = j.model ?? j.response?.model;
    c.systemPrompt = typeof j.instructions === 'string' ? j.instructions : typeof j.response?.instructions === 'string' ? j.response.instructions : undefined;
    for (const cand of [j.input, j.messages, j.response?.input, j.response?.messages]) {
      if (typeof cand === 'string' && cand) { c.messages.push({ role: 'user', content: [{ kind: 'text', text: cand }] }); break; }
      if (Array.isArray(cand)) {
        let added = false;
        for (const item of cand) {
          const blocks = responsesItemBlocks(item);
          if (blocks.length) { c.messages.push({ role: responsesRole(item), content: blocks }); added = true; }
        }
        if (added) break;
      }
    }
    c.requestEnvelope = pretty(j);
  }
  if (res) {
    const r = json(res);
    if (r) {
      if (Array.isArray(r.output)) for (const item of r.output) {
        const blocks = responsesItemBlocks(item);
        if (blocks.length) c.messages.push({ role: responsesRole(item), content: blocks });
      }
      if (r.usage) { c.inputTokens = r.usage.input_tokens; c.outputTokens = r.usage.output_tokens; }
    } else {
      const a = parseResponsesSSE(text(res));
      if (a.content.length) c.messages.push(a);
    }
  }
  if (!c.messages.length && c.systemPrompt == null && c.requestEnvelope == null) return null;
  return c;
}

function parseResponsesSSE(s: string): Message {
  let combined = '';
  const tools = new Map<string, { name: string; args: string }>();
  const order: string[] = [];
  const callIDs = new Map<string, string>();
  for (const chunk of s.split('\n\n')) {
    let event = '', data = '';
    for (const line of chunk.split('\n')) {
      if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) { const v = line.slice(5).trim(); data = data ? data + '\n' + v : v; }
    }
    if (!data) continue;
    let o: any; try { o = JSON.parse(data); } catch { continue; }
    if (!o || typeof o !== 'object') continue;
    if (event === 'response.output_text.delta') { if (typeof o.delta === 'string') combined += o.delta; }
    else if (event === 'response.function_call_arguments.delta') {
      const id = o.item_id ?? 'tool';
      if (!tools.has(id)) { tools.set(id, { name: id, args: '' }); order.push(id); }
      if (typeof o.delta === 'string') tools.get(id)!.args += o.delta;
    } else if (event === 'response.output_item.added') {
      const it = o.item;
      if (it?.type === 'function_call' && typeof it.id === 'string' && typeof it.name === 'string') {
        if (typeof it.call_id === 'string') callIDs.set(it.id, it.call_id);
        if (tools.has(it.id)) tools.get(it.id)!.name = it.name;
        else { tools.set(it.id, { name: it.name, args: '' }); order.push(it.id); }
      }
    }
  }
  const blocks: Block[] = [];
  if (combined) blocks.push({ kind: 'text', text: combined });
  for (const id of order) { const t = tools.get(id)!; blocks.push({ kind: 'toolUse', name: t.name, input: t.args, id: callIDs.get(id) ?? id }); }
  return { role: 'assistant', content: blocks };
}

// ── Cohere / Gemini ──────────────────────────────────────────────────────

function parseCohere(req: Uint8Array | null, res: Uint8Array | null): Conversation | null {
  const c: Conversation = { provider: 'cohere', messages: [] };
  const j = json(req);
  if (j) {
    c.model = j.model;
    if (typeof j.preamble === 'string') c.systemPrompt = j.preamble;
    if (Array.isArray(j.chat_history)) for (const h of j.chat_history) {
      const role = String(h?.role ?? 'USER').toUpperCase();
      if (typeof h?.message === 'string') c.messages.push({ role: role === 'CHATBOT' || role === 'ASSISTANT' ? 'assistant' : 'user', content: [{ kind: 'text', text: h.message }] });
    }
    if (typeof j.message === 'string') c.messages.push({ role: 'user', content: [{ kind: 'text', text: j.message }] });
  }
  const r = json(res);
  if (r) {
    if (typeof r.text === 'string' && r.text) c.messages.push({ role: 'assistant', content: [{ kind: 'text', text: r.text }] });
    if (r.meta?.tokens) { c.inputTokens = r.meta.tokens.input_tokens; c.outputTokens = r.meta.tokens.output_tokens; }
  }
  return c.messages.length ? c : null;
}

function parseGemini(req: Uint8Array | null, res: Uint8Array | null): Conversation | null {
  const c: Conversation = { provider: 'gemini', messages: [] };
  const parts = (ps: any): Block[] => (Array.isArray(ps) ? ps : []).filter((p: any) => typeof p?.text === 'string').map((p: any) => ({ kind: 'text', text: p.text }));
  const j = json(req);
  if (j) {
    if (Array.isArray(j.systemInstruction?.parts)) c.systemPrompt = j.systemInstruction.parts.map((p: any) => p?.text).filter((x: any) => typeof x === 'string').join('\n\n');
    if (Array.isArray(j.contents)) for (const ct of j.contents) c.messages.push({ role: ct?.role === 'model' ? 'assistant' : 'user', content: parts(ct?.parts) });
  }
  const r = json(res);
  if (r && Array.isArray(r.candidates)) for (const cd of r.candidates) if (Array.isArray(cd?.content?.parts)) c.messages.push({ role: 'assistant', content: parts(cd.content.parts) });
  return c.messages.length ? c : null;
}
