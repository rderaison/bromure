#!/usr/bin/env python3
"""Generate differential test cases: OpenShell reference engine vs Bromure.

Each case: {id, policy (YAML), host, port, binary, ancestors, request?}.
Random policies are built from pools chosen to hit rule edges; requests are
probes around them. Also emits connection probes for every real policy in an
OpenShell checkout (argv[2]). Deterministic (seeded).
"""
import json, random, sys, os, re, glob

rnd = random.Random(int(os.environ.get("SEED", "1")))
N_POLICIES = int(os.environ.get("N_POLICIES", "400"))
FOCUS = os.environ.get("FOCUS", "")
LAST_VERS = []
META_PROTO = []

HOSTS = ["api.example.com", "www.example.com", "example.com", "*.example.com",
         "**.example.com", "api-*.example.org", "api.*.example.net", "Mixed.Example.io"]
PROBE_HOSTS = ["api.example.com", "API.EXAMPLE.COM", "www.example.com", "example.com",
               "a.b.example.com", "api-v2.example.org", "api.example.org", "api.eu.example.net",
               "api.eu.us.example.net", "mixed.example.io", "evil.com", "example.com.evil.com"]
PORT_SETS = [[443], [8443], [80], [443, 8443]]
IP_PORT_SETS = [[443], [443, 6443], [10250], [5432], [80, 443]]
ADDRS = ["93.184.216.34", "8.8.8.8", "2606:2800:220:1::1", "10.0.0.5", "10.1.2.3", "192.168.1.10", "172.16.0.1",
         "100.64.1.1", "127.0.0.1", "169.254.169.254", "192.0.2.1", "198.18.0.1", "192.0.0.8", "255.255.255.255",
         "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "::"]
ALLOWED_IPS = ["10.0.0.0/8", "10.0.0.5", "192.168.1.0/24", "fd00::/8", "2606:2800:220:1::/64", "93.184.216.0/24",
               "0.0.0.0/0", "169.254.169.254", "127.0.0.1", "not-an-ip", "8.8.8.8/32", "::/0", "10.0.0.0/33"]
IP_HOSTS = ["10.0.0.5", "8.8.8.8", "169.254.169.254", "127.0.0.1", "192.168.1.10"]
def ws_graphql_endpoint(host, ports):
    lines = [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]", "protocol: websocket",
             f"enforcement: {rnd.choice(['enforce', 'enforce', 'audit'])}", "rules:",
             f"  - allow: {{ method: GET, path: {q(rnd.choice(['**', '/graphql', '/ws']))} }}"]
    for _ in range(rnd.randint(1, 2)):
        t = rnd.choice(["query", "mutation", "subscription"])
        parts = [f"operation_type: {t}"]
        if rnd.random() < 0.3: parts.append(f"operation_name: {q(rnd.choice(['Get*', 'OnUpdate']))}")
        if rnd.random() < 0.3: parts.append("fields: " + json.dumps(rnd.choice([["viewer"], ["issueUpdated"], ["*"]])))
        lines.append("  - allow: { " + ", ".join(parts) + " }")
    if rnd.random() < 0.4:
        lines += ["deny_rules:", "  - { operation_type: mutation, fields: [\"delete*\"] }"]
    return lines

WS_MESSAGES = [
    '{"type":"connection_init","payload":{}}', '{"type":"ping"}', '{"type":"complete","id":"1"}',
    '{"type":"subscribe","id":"1","payload":{"query":"subscription OnUpdate { issueUpdated { id } }"}}',
    '{"type":"subscribe","id":"2","payload":{"query":"{ viewer { login } }"}}',
    '{"type":"start","id":"3","payload":{"query":"query GetViewer { viewer { login } }","operationName":"GetViewer"}}',
    '{"type":"subscribe","id":"4","payload":{"query":"mutation { deleteRepository(input: {}) { x } }"}}',
    '{"type":"subscribe","payload":{"query":"{ viewer }"}}', '{"type":"subscribe","id":"5","payload":"x"}',
    '{"type":"subscribe","id":"6","payload":{"query":"{ viewer "}}', '{"type":"weird","id":"7"}',
    'not json', '[1,2]', 'hello there', '{"type":"subscribe","id":"8","payload":{"extensions":{"persistedQuery":{"sha256Hash":"abc"}}}}',
]

def ip_endpoint(host, ports):
    """L4 endpoints exercising the destination plan."""
    r = rnd.random()
    ips = rnd.sample(ALLOWED_IPS, rnd.randint(1, 2))
    extra = ["tls: skip"] if rnd.random() < 0.15 else []
    if r < 0.35:
        return [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]", "allowed_ips: " + json.dumps(ips)] + extra
    if r < 0.55:
        return [f"ports: [{', '.join(map(str, ports))}]", "allowed_ips: " + json.dumps(ips)] + extra
    if r < 0.75:
        return [f"host: {q(rnd.choice(IP_HOSTS))}", f"ports: [{', '.join(map(str, ports))}]"] + extra
    return [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]"] + extra
BINARY_SETS = [[], ["/usr/bin/curl"], ["/usr/bin/python3*"], ["/usr/bin/git", "/usr/bin/gh"],
               ["/usr/lib/**/node"], ["/usr/local/bin/*"]]
PROBE_BINARIES = [("/usr/bin/curl", []), ("/usr/bin/python3.12", []), ("/usr/bin/git", []),
                  ("/usr/lib/git-core/git-remote-https", ["/usr/bin/git"]),
                  ("/usr/lib/node_modules/x/bin/node", []), ("/usr/local/bin/node", ["/usr/bin/bash"]),
                  ("/usr/bin/wget", ["/usr/bin/python3.12"])]
RULE_PATHS = ["**", "/repos/*/*", "/repos/**", "/v1/**", "/v1/items", "/a/*", "/graphql", "/mcp",
              "/**/git-upload-pack", "/repos/acme/app/hooks", "/repos/acme/app/hooks/**", "/a/b"]
METHODS = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
TARGETS = ["/", "/repos/acme/app", "/repos/acme/app/hooks", "/repos/acme/app/hooks/1",
           "/v1/items?tag=prod-1", "/v1/items?tag=dev", "/v1/items?tag=prod-1&tag=dev",
           "/v1/items?tag=prod-1&tag=stage-2", "/v1/items?tag=", "/v1/items", "/v1", "/v1/",
           "/a/./b", "/a/../a/b", "/../x", "/%2e%2e/x", "/a%2Fb", "/a%2fb", "/a;p=1/b", "//a//b",
           "/x#frag", "/graphql", "/mcp", "/a/b?x=%41", "/foo/bar/git-upload-pack", "/a/%62",
           "/public/..%3b/secret", "/a/%252F/b", "/fetch/http://x.test/a", "/files/hello%20world", "/users/caf%c3%a9",
           "/a/b/.", "/a%2", "/a/b?x=%zz", "/a/b?x=%C3%28", "/a/b?x=a+b", "http://api.example.com/a/b", "/a/b/..",
           "/repos/acme/app/hooks/..;/x", "/a/%2e%2e;/b", "/v1/items?tag=prod%2D1", "/%7Euser", "/a/b%3Fc"]
QUERY_MATCHERS = [None, {"tag": "prod-*"}, {"tag": {"any": ["prod-*", "stage-*"]}}]

def q(s):
    return json.dumps(s)

def rest_endpoint(host, ports, proto):
    lines = [f"host: {q(host)}"] if host else []
    lines.append(f"ports: [{', '.join(map(str, ports))}]")
    lines.append(f"protocol: {proto}")
    lines.append(f"enforcement: {rnd.choice(['enforce', 'audit'])}")
    if rnd.random() < 0.4:
        lines.append(f"access: {rnd.choice(['read-only', 'read-write', 'full'])}")
        if rnd.random() < 0.3:
            lines.append("deny_rules:")
            lines.append(f"  - {{ method: {q(rnd.choice(METHODS + ['*']))}, path: {q(rnd.choice(RULE_PATHS))} }}")
    else:
        lines.append("rules:")
        for _ in range(rnd.randint(1, 3)):
            m = rnd.choice(METHODS + ["*"]) if proto == "rest" else rnd.choice(["GET", "WEBSOCKET_TEXT", "*"])
            qm = rnd.choice(QUERY_MATCHERS)
            extra = f", query: {json.dumps(qm)}" if qm else ""
            lines.append(f"  - allow: {{ method: {q(m)}, path: {q(rnd.choice(RULE_PATHS))}{extra} }}")
        if rnd.random() < 0.4:
            lines.append("deny_rules:")
            qm = rnd.choice(QUERY_MATCHERS)
            extra = f", query: {json.dumps(qm)}" if qm else ""
            lines.append(f"  - {{ method: {q(rnd.choice(METHODS + ['*']))}, path: {q(rnd.choice(RULE_PATHS))}{extra} }}")
    if rnd.random() < 0.2:
        lines.append("allow_encoded_slash: true")
    if rnd.random() < 0.2:
        lines.append(f"path: {q(rnd.choice(['/v1/**', '/graphql', '/repos/**']))}")
    return lines

def graphql_endpoint(host, ports):
    lines = [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]", "protocol: graphql",
             "enforcement: enforce"]
    if rnd.random() < 0.3:
        lines.append(f"access: {rnd.choice(['read-only', 'read-write', 'full'])}")
    else:
        lines.append("rules:")
        for _ in range(rnd.randint(1, 3)):
            t = rnd.choice(["query", "mutation", "subscription"])
            f = rnd.choice([None, ["viewer"], ["createIssue", "add*"], ["*"]])
            n = rnd.choice([None, "Get*", "Viewer"])
            parts = [f"operation_type: {t}"]
            if n: parts.append(f"operation_name: {q(n)}")
            if f: parts.append(f"fields: {json.dumps(f)}")
            lines.append("  - allow: { " + ", ".join(parts) + " }")
    if rnd.random() < 0.5:
        lines.append("deny_rules:")
        f = rnd.choice([None, ["deleteRepository"], ["delete*"]])
        parts = ["operation_type: mutation"] + ([f"fields: {json.dumps(f)}"] if f else [])
        lines.append("  - { " + ", ".join(parts) + " }")
    if rnd.random() < 0.3:
        lines.append(f"persisted_queries: {rnd.choice(['allow_registered', 'allow_registered', 'deny'])}")
        lines.append("graphql_persisted_queries:")
        lines.append('  abc123: { operation_type: query, operation_name: GetViewer, fields: ["viewer"] }')
        lines.append('  q-1: { operation_type: mutation, fields: ["deleteRepository"] }')
    if rnd.random() < 0.2:
        lines.append(f"graphql_max_body_bytes: {rnd.choice([0, 40, 100000])}")
    return lines

def rpc_endpoint(host, ports, mcp):
    lines = [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]",
             f"protocol: {'mcp' if mcp else 'json-rpc'}", "enforcement: enforce"]
    allow_all = mcp and rnd.random() < 0.3
    if mcp:
        global LAST_VERS
        vers = rnd.choice([["2025-06-18", "2025-11-25"], ["2025-11-25", "2026-07-28"], ["2026-07-28"], ["2025-03-26", "2025-11-25"]])
        LAST_VERS = vers
        lines.append("mcp: { versions: " + json.dumps(vers) +
                     (", allow_all_known_mcp_methods: true" if allow_all else "") + " }")
    if rnd.random() < 0.2:
        lim = rnd.choice([0, 30, 100000])
        if mcp: lines[-1] = lines[-1].replace(" }", f", max_body_bytes: {lim} }}", 1)
        else: lines.append(f"json_rpc: {{ max_body_bytes: {lim} }}")
    rules = []
    if mcp:
        rules += ["{ method: initialize }", "{ method: notifications/initialized }"]
        for _ in range(rnd.randint(1, 3)):
            c = rnd.random()
            if c < 0.3: rules.append("{ method: tools/list }")
            elif c < 0.7:
                rules.append("{ method: tools/call, tool: " +
                             json.dumps(rnd.choice(["search", {"any": ["list_*", "get_*"]}, "send.email"])) + " }")
            else: rules.append("{ method: \"tools/*\" }")
        if allow_all:
            rules = ["{ tool: " + json.dumps(rnd.choice(["search", {"any": ["list_*"]}])) + " }"]
    else:
        for _ in range(rnd.randint(1, 3)):
            rules.append("{ method: " + q(rnd.choice(["reports.search", "reports.get", "*"])) + " }")
    lines.append("rules:")
    lines += [f"  - allow: {r}" for r in rules]
    if rnd.random() < 0.5:
        lines.append("deny_rules:")
        lines.append("  - " + ("{ method: tools/call, tool: send_email }" if mcp else "{ method: reports.delete }"))
    return lines

MATCH_HOST = {"api.example.com": ["api.example.com", "API.Example.com"], "www.example.com": ["www.example.com"],
              "example.com": ["example.com"], "*.example.com": ["www.example.com", "api.example.com", "a.b.example.com", "example.com"],
              "**.example.com": ["a.b.example.com", "api.example.com", "example.com"],
              "api-*.example.org": ["api-v2.example.org", "api-.example.org", "api.example.org"],
              "api.*.example.net": ["api.eu.example.net", "api.eu.us.example.net"], "Mixed.Example.io": ["mixed.example.io"]}
MATCH_BIN = {"/usr/bin/curl": [("/usr/bin/curl", [])], "/usr/bin/python3*": [("/usr/bin/python3.12", []), ("/usr/bin/python3", [])],
             "/usr/bin/git": [("/usr/bin/git", []), ("/usr/lib/git-core/git-remote-https", ["/usr/bin/git"])],
             "/usr/bin/gh": [("/usr/bin/gh", [])], "/usr/lib/**/node": [("/usr/lib/node_modules/x/bin/node", []), ("/usr/lib/node", [])],
             "/usr/local/bin/*": [("/usr/local/bin/node", []), ("/usr/local/bin/a/b", [])]}
META = []

def policy():
    META.clear(); META_PROTO.clear()
    rules = []
    for i in range(rnd.randint(1, 3)):
        eps = []
        for _ in range(rnd.randint(1, 2)):
            host = rnd.choice(HOSTS)
            ports = rnd.choice(PORT_SETS)
            kind = rnd.random()
            if FOCUS == "mcp" and rnd.random() < 0.7: kind = 0.85
            if FOCUS == "graphql" and rnd.random() < 0.7: kind = 0.75
            proto = ("rest" if 0.3 <= kind < 0.6 else "websocket" if 0.6 <= kind < 0.67 else "graphql" if 0.67 <= kind < 0.8
                     else "mcp" if 0.8 <= kind < 0.9 else "json-rpc" if kind >= 0.9 else "l4")
            if FOCUS == "ws" and rnd.random() < 0.75:
                ep = ws_graphql_endpoint(host, ports) if rnd.random() < 0.6 else rest_endpoint(host, ports, "websocket")
                proto = "websocket"
            elif FOCUS == "ip" and rnd.random() < 0.8:
                ports = rnd.choice(IP_PORT_SETS)
                ep = ip_endpoint(host, ports)
            elif kind < 0.25:
                ep = [f"host: {q(host)}", f"ports: [{', '.join(map(str, ports))}]"]
            elif kind < 0.3:
                ep = [f"host: {q(host.replace('*', 'x'))}", f"port: {ports[0]}", "protocol: tcp"]
            elif kind < 0.6:
                ep = rest_endpoint(host, ports, "rest")
            elif kind < 0.67:
                ep = rest_endpoint(host, ports, "websocket")
            elif kind < 0.8:
                ep = graphql_endpoint(host, ports)
            elif kind < 0.9:
                ep = rpc_endpoint(host, ports, mcp=True)
            else:
                ep = rpc_endpoint(host, ports, mcp=False)
            eps.append(ep)
            META.append((host, ports))
            META_PROTO.append((proto, list(LAST_VERS) if proto == "mcp" else []))
        bins = rnd.choice(BINARY_SETS)
        for j in range(len(META) - len(eps), len(META)):
            META[j] = META[j] + (bins,)
        body = [f"  r{i}:", "    endpoints:"]
        for ep in eps:
            body.append("      - " + ep[0])
            body += ["        " + l for l in ep[1:]]
        if bins:
            body.append("    binaries:")
            body += [f"      - {{ path: {q(b)} }}" for b in bins]
        rules.append("\n".join(body))
    return "version: 1\nnetwork_policies:\n" + "\n".join(rules) + "\n"

GRAPHQL_BODIES = [
    {"query": "{ viewer { login } }"},
    {"query": "query GetViewer { viewer { login } }"},
    {"query": "mutation { createIssue(input: {}) { issue { id } } }"},
    {"query": "mutation M { first: addComment(input: {}) { x } }"},
    {"query": "mutation { deleteRepository(input: {}) { x } }"},
    {"query": "mutation { createIssue(input: {}) { x } deleteRepository(input: {}) { x } }"},
    {"query": "mutation { ...F } fragment F on Mutation { deleteRepository(input: {}) { x } }"},
    {"query": "subscription { issueUpdated { id } }"},
    {"query": "{ viewer { login }"},
    [{"query": "{ viewer { login } }"}, {"query": "mutation { deleteRepository(input: {}) { x } }"}],
]
RPC_BODIES = [
    {"jsonrpc": "2.0", "id": 1, "method": "reports.search"},
    {"jsonrpc": "2.0", "id": 1, "method": "reports.delete"},
    {"jsonrpc": "2.0", "id": 1, "method": "other.thing"},
    [{"jsonrpc": "2.0", "id": 1, "method": "reports.search"}, {"jsonrpc": "2.0", "id": 2, "method": "reports.delete"}],
    {"jsonrpc": "2.0", "id": 1, "result": {}},
]
MCP_BODIES = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_issues", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send_email", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send.email", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 4, "method": "resources/list"},
    {"jsonrpc": "2.0", "id": 5, "result": {}},
    [{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search", "arguments": {}}}],
    {"jsonrpc": "2.0", "id": 9, "method": "ping"},
    {"jsonrpc": "2.0", "id": 9, "method": "tasks/get", "params": {"taskId": "t1"}},
    {"jsonrpc": "2.0", "id": 9, "method": "server/discover", "params": {}},
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call"},
    {"jsonrpc": "2.0", "id": 9, "method": "vendor/thing"},
    {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_repo", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "bad name!", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 4, "method": "prompts/list"},
    {"jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": {"uri": "file:///a"}},
    {"jsonrpc": "2.0", "id": 4, "method": "logging/setLevel", "params": {"level": "info"}},
    {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": 1, "progress": 5}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {"cursor": 3}},
    {"jsonrpc": "2.0", "id": 4.5, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 6, "error": {"code": -32601, "message": "nope"}},
    [{"jsonrpc": "2.0", "id": 5, "result": {}}, {"jsonrpc": "2.0", "id": 6, "result": {}}],
    [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}],
]

GQL_DOCS = ["{ viewer { login } }", "query GetViewer { viewer { login } }", "query A { a } query B { viewer }",
            "mutation M { createIssue(input: {}) { x } } query GetViewer { viewer { login } }",
            "subscription GetUpdates { issueUpdated { id } }", "mutation { deleteRepository(input: {}) { x } }",
            "query { ...F } fragment F on Query { viewer secret }", "query { ...Missing viewer }",
            "{ ... on Query { viewer } }", "query Q { viewer { login }", "fragment F on Query { viewer }"]
def gql_case():
    import urllib.parse
    doc = rnd.choice(GQL_DOCS)
    env = {"query": doc}
    r = rnd.random()
    if r < 0.3: env["operationName"] = rnd.choice(["GetViewer", "A", "B", "M", "Nope", ""])
    elif r < 0.4: env = {"extensions": {"persistedQuery": {"version": 1, "sha256Hash": rnd.choice(["abc123", "unknown"])}}}
    elif r < 0.45: env = {"id": rnd.choice(["abc123", "q-1"])}
    elif r < 0.5: env["extensions"] = {"persistedQuery": {"version": 1, "sha256Hash": "abc123"}}
    m = rnd.random()
    if m < 0.35:
        qs = urllib.parse.urlencode({k: (json.dumps(v) if isinstance(v, dict) else v) for k, v in env.items()})
        if rnd.random() < 0.05: qs += "&query=%7Bx%7D"
        if rnd.random() < 0.05: qs += "&documentId=z"
        return {"method": "GET", "target": "/graphql?" + qs}
    if m < 0.4:
        return {"method": rnd.choice(["PUT", "HEAD"]), "target": "/graphql", "body": json.dumps(env)}
    body = json.dumps([env, {"query": rnd.choice(GQL_DOCS)}] if rnd.random() < 0.1 else env)
    req = {"method": "POST", "target": "/graphql", "body": body}
    if rnd.random() < 0.04: req["headers"] = {"Content-Encoding": "gzip"}
    elif rnd.random() < 0.04: req["headers"] = {"Content-Type": "multipart/form-data; boundary=x"}
    return req

META26 = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {}}
def mcp26_case():
    """A sessionless (2026-07-28) request, with right or subtly wrong headers."""
    kind = rnd.choice(["tools/list", "tools/call", "tools/call", "resources/read", "prompts/get",
                       "server/discover", "initialize", "ping", "custom/ext", "notifications/cancelled",
                       "resources/subscribe"])
    params = {"_meta": dict(META26)}
    name = None
    if kind == "tools/call":
        name = rnd.choice(["search", "list_issues", "send_email", "send.email"]); params.update(name=name, arguments={})
    elif kind == "resources/read":
        name = "file:///a"; params["uri"] = name
    elif kind == "prompts/get":
        name = "greet"; params["name"] = name
    elif kind == "resources/subscribe":
        params["uri"] = "file:///a"
    elif kind == "notifications/cancelled":
        params = {"requestId": 1}
    r = rnd.random()
    if r < 0.08: params.pop("_meta", None)
    elif r < 0.14: params["_meta"] = {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}
    elif r < 0.18 and "_meta" in params: params["_meta"]["io.modelcontextprotocol/protocolVersion"] = "2025-11-25"
    body = {"jsonrpc": "2.0", "method": kind, "params": params}
    if kind != "notifications/cancelled": body["id"] = 7
    if rnd.random() < 0.05: body = [body]
    headers = {"Mcp-Method": kind}
    if name is not None: headers["Mcp-Name"] = name
    r = rnd.random()
    if r < 0.08: headers.pop("Mcp-Method")
    elif r < 0.14: headers["Mcp-Method"] = "tools/list"
    elif r < 0.2 and name: headers["Mcp-Name"] = "other"
    elif r < 0.24 and name: headers["Mcp-Name"] = "=?base64?" + __import__("base64").b64encode(name.encode()).decode() + "?="
    method = "POST" if rnd.random() < 0.92 else rnd.choice(["GET", "DELETE"])
    ver = "2026-07-28" if rnd.random() < 0.9 else rnd.choice(["2025-11-25", "2026-07-29"])
    return {"method": method, "target": "/mcp", "body": json.dumps(body), "mcp_version": ver, "headers": headers}

def main(out_path, repo):
    cases = []
    n = 0
    def add(pol, host, port, binary, anc, req=None):
        nonlocal n
        c = {"id": n, "policy": pol, "host": host, "port": port, "binary": binary, "ancestors": anc}
        if req: c["request"] = req
        cases.append(c); n += 1
    for _ in range(N_POLICIES):
        pol = policy()
        meta = list(META)
        def probe():
            # 75%: aimed at a real endpoint (matching host / port / binary); 25%: random.
            if meta and rnd.random() < 0.75:
                host_pat, ports, bins = rnd.choice(meta)
                host = rnd.choice(MATCH_HOST.get(host_pat, [host_pat]))
                port = rnd.choice(ports) if rnd.random() < 0.9 else 8080
                if bins and rnd.random() < 0.85:
                    b, anc = rnd.choice(MATCH_BIN[rnd.choice(bins)])
                else:
                    b, anc = rnd.choice(PROBE_BINARIES)
                return host, port, b, anc
            b, anc = rnd.choice(PROBE_BINARIES)
            return rnd.choice(PROBE_HOSTS), rnd.choice([443, 8443, 80]), b, anc
        for _ in range(12):   # connection probes
            host, port, b, anc = probe()
            if FOCUS == "ip":
                if rnd.random() < 0.3: host = rnd.choice(IP_HOSTS)
                if rnd.random() < 0.3: port = rnd.choice([443, 6443, 10250, 5432, 80])
            add(pol, host, port, b, anc)
            if FOCUS == "ip" or rnd.random() < 0.15:
                cases[-1]["resolved"] = rnd.sample(ADDRS, rnd.choice([1, 1, 1, 2, 3]))
        for _ in range(24):   # request probes (only meaningful when the connection passes)
            focus_idx = [i for i, (pr, _) in enumerate(META_PROTO) if pr == (FOCUS if FOCUS != "ws" else "websocket")]
            if FOCUS and focus_idx and rnd.random() < 0.85:
                i = rnd.choice(focus_idx)
                host_pat, ports, bins = META[i]
                host = rnd.choice(MATCH_HOST.get(host_pat, [host_pat]))
                port = rnd.choice(ports)
                b, anc = rnd.choice(MATCH_BIN[rnd.choice(bins)]) if bins else rnd.choice(PROBE_BINARIES)
                if FOCUS == "mcp":
                    vers = META_PROTO[i][1]
                    if rnd.random() < 0.35:
                        req = mcp26_case()
                    else:
                        req = {"method": "POST", "target": rnd.choice(["/mcp", "/mcp", "/v1/mcp"]),
                               "body": json.dumps(rnd.choice(MCP_BODIES)),
                               "mcp_version": rnd.choice(vers) if rnd.random() < 0.8 else rnd.choice(["2025-03-26", "2025-06-18"])}
                        if rnd.random() < 0.05: req.pop("mcp_version")
                        if rnd.random() < 0.06:
                            req = {"method": "GET", "target": "/mcp", "headers": {"Accept": "text/event-stream"},
                                   "mcp_version": rnd.choice(vers)}
                    if "2026-07-28" in vers and rnd.random() < 0.5 and req.get("mcp_version") == "2026-07-28":
                        pass
                elif FOCUS == "ws":
                    req = {"method": "GET", "target": rnd.choice(["/ws", "/v1/realtime", "/graphql", "/v1/other"]),
                           "ws_messages": rnd.sample(WS_MESSAGES, 3)}
                else:
                    req = gql_case()
                add(pol, host, port, b, anc, req)
                continue
            host, port, b, anc = probe()
            kind = rnd.random()
            if kind < 0.55:
                req = {"method": rnd.choice(METHODS), "target": rnd.choice(TARGETS)}
            elif kind < 0.7:
                req = {"method": "POST", "target": "/graphql", "body": json.dumps(rnd.choice(GRAPHQL_BODIES))}
            elif kind < 0.85:
                req = {"method": "POST", "target": "/rpc", "body": json.dumps(rnd.choice(RPC_BODIES))}
            elif kind < 0.93:
                req = {"method": "POST", "target": "/mcp", "body": json.dumps(rnd.choice(MCP_BODIES)),
                       "mcp_version": rnd.choice(["2025-11-25", "2025-06-18", "2025-03-26"])}
                if rnd.random() < 0.1: req.pop("mcp_version")
                if rnd.random() < 0.07:
                    req = {"method": "GET", "target": "/mcp", "headers": {"Accept": "text/event-stream"},
                           "mcp_version": rnd.choice(["2025-11-25", "2026-07-28"])}
            else:
                req = mcp26_case()
            add(pol, host, port, b, anc, req)
    # Real policies from the OpenShell checkout: connection probes per endpoint.
    if repo:
        for path in glob.glob(os.path.join(repo, "**/*.yaml"), recursive=True):
            if "/deploy/" in path or "template" in path or "invalid" in path or "reject" in path:
                continue
            text = open(path, encoding="utf-8", errors="replace").read()
            if not re.search(r"(?m)^version: 1\b", text) or "network_policies" not in text:
                continue
            hosts = set(re.findall(r"host:\s*\"?([A-Za-z0-9*._-]+)\"?", text))
            bins = re.findall(r"path:\s*\"?(/[^\s\"}]+)\"?", text) or ["/usr/bin/curl"]
            for h in list(hosts)[:20]:
                probe = h.replace("**", "a.b").replace("*", "x")
                for port in (443, 80):
                    for b in bins[:4] + ["/usr/bin/nope"]:
                        add(text, probe, port, b, [])
    with open(out_path, "w") as f:
        for c in cases:
            f.write(json.dumps(c) + "\n")
    print(f"{len(cases)} cases")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
