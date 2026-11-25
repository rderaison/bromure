// "Test Connection" for a custom inference server (vLLM, Ollama, …): the
// mirrored host probes it (POST /models/probe-server) — the machine whose
// launches use it, from its own network and address. The client never
// contacts that server itself (a hosted page couldn't, and the answer would
// be about the wrong machine). A redacted key makes the host use the key it
// stores for that same server.

type Request = (method: string, path: string, body?: unknown, opts?: { allowError?: boolean }) => Promise<any>;

export const PROBE_TOO_OLD = "This server's Bromure is too old to test the connection. Update Bromure on it, then try again.";

/** The host's model ids for the server, or throws with the host's reason. */
export async function probeCustomServer(request: Request, baseURL: string, apiKey?: string | null): Promise<string[]> {
  const body: Record<string, string> = { baseURL };
  if (apiKey) body.apiKey = apiKey;
  const r = await request('POST', '/models/probe-server', body, { allowError: true });
  if (r?.ok === true) return Array.isArray(r.models) ? r.models.filter((m: unknown) => typeof m === 'string') : [];
  // A host that predates the route answers the generic /models/ action's 400.
  if (r?.error === 'bad action or repo') throw new Error(PROBE_TOO_OLD);
  throw new Error(r?.error || "The server couldn't test the connection.");
}
