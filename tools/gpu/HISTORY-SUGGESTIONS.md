Native address-bar history lookup
================================

The existing native tab agent accepts this profile-local command on host-only
vsock port 5810 in both legacy and shared-window sessions:

```json
{"cmd":"query_history","request_id":"window-specific-uuid","query":"example","limit":8}
```

Reply:

```json
{"event":"history_suggestions","request_id":"window-specific-uuid","query":"example","status":"ok","items":[{"url":"https://example.com/","title":"Example"}]}
```

The host should debounce typing, correlate both request ID and query to the
requesting window, and discard stale replies. An empty list clears suggestions.
`status` is `ok`, `invalid`, `unavailable`, or `timeout`; unsuccessful reads return
no items. Invalid/missing request IDs are ignored. IDs are strings of 1–128
characters; queries at most 512 characters; limits are integers from 1 to 10.
The default limit is 8. Blank queries return an empty successful result.

The agent reads only `Default/History` under its configured `PROFILE_DIR`, or
the existing ephemeral Chromium default when unset. No caller-selected path,
profile, window, or target controls that choice. It uses SQLite read-only mode,
including committed WAL data, with a 20ms lock wait and a 100ms/2-million-opcode
query budget. These bound SQLite work, not arbitrary kernel filesystem stalls.
Results are HTTP(S) URLs without credentials/control characters. Literal,
Unicode-casefolded URL/title matches rank URL prefixes first, then typed count,
recency, and visit count. Replies cap item JSON at 24KiB. No database copy or
history cache is retained, and this RPC never opens a page or changes focus.

Chromium may commit new visits asynchronously. Missing, incompatible, locked,
or over-budget history produces empty suggestions; it does not read another
profile or fall back to the separate Bromure History-menu database. The existing
`get_history` command is unchanged.

Schema reference: [Chromium URLDatabase](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/history/core/browser/url_database.cc).

Regression command:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/gpu/test-history-suggestions.py
```

These tests use real SQLite databases and the actual tab-agent command handler.
Native address-bar interaction and the installed Chromium image need separate
live Mac acceptance.
