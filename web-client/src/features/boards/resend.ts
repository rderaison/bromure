// A request that got no answer at all (it threw: the connection under it was
// gone) is sent once more when `resend` says it's safe to send twice. A
// connection that died while idle (the computer slept, the network changed)
// is only found out by the request riding it, which fails at once; the host
// reconnects, so the resend gets through. An answer, even an error, is final.

export const RESEND_DELAY_MS = 500;

export async function requestResending<T>(send: () => Promise<T>, resend: boolean,
                                          delayMs = RESEND_DELAY_MS): Promise<T> {
  try {
    return await send();
  } catch (e) {
    if (!resend) throw e;
    await new Promise(r => setTimeout(r, delayMs));
    return send();
  }
}
