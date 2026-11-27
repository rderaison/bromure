// "Test Connection" for a custom inference server (vLLM, Ollama, …): the
// mirrored host probes it (POST /models/probe-server) — the machine whose
// launches use it, from its own network and address. The client never
// contacts that server itself (a hosted page couldn't, and the answer would
// be about the wrong machine). A redacted key makes the host use the key it
// stores for that same server.

type Request = (method: string, path: string, body?: unknown, opts?: { allowError?: boolean }) => Promise<any>;

export const PROBE_TOO_OLD = "This server's Bromure is too old to test the connection. Update Bromure on it, then try again.";

/** The configuration being tested: the host resolves a redacted key from it
 *  alone (the same server URL may hold different keys globally and in a
 *  workspace). A workspace without an id is one not saved yet. */
export type ProbeScope = { kind: 'global' } | { kind: 'workspace'; id?: string };

/** The host's model ids for the server, or throws with the host's reason. */
export async function probeCustomServer(request: Request, baseURL: string, apiKey?: string | null,
                                        scope?: ProbeScope): Promise<string[]> {
  const body: Record<string, string> = { baseURL };
  if (apiKey) body.apiKey = apiKey;
  if (scope) {
    body.scope = scope.kind;
    if (scope.kind === 'workspace' && scope.id) body.profileId = scope.id;
  }
  const r = await request('POST', '/models/probe-server', body, { allowError: true });
  if (r?.ok === true) return Array.isArray(r.models) ? r.models.filter((m: unknown) => typeof m === 'string') : [];
  // A host that predates the route answers the generic /models/ action's 400.
  if (r?.error === 'bad action or repo') throw new Error(PROBE_TOO_OLD);
  throw new Error(r?.error || "The server couldn't test the connection.");
}
