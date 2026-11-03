#!/usr/bin/env bash
# OpenShell e2e/policy-advisor/sandbox-runner.sh, adapted to Bromure.
#
# Same subcommands, payloads and output contract as upstream: every subcommand
# prints `HTTP_STATUS=<code>`, then the response body, then a newline.
# Bromure differences:
#   - check-skill: OpenShell ships /etc/openshell/skills/policy_advisor.md in
#     the image; Bromure serves the same guide at http://policy.local/v1/guide.
#   - policy.local is answered transparently by Bromure's host (the guest maps
#     it to a reserved address the switch diverts), with no proxy, as in OpenShell.
set -uo pipefail

cmd="${1:-}"
shift || true
body="$(mktemp)"
payload="$(mktemp)"
trap 'rm -f "$body" "$payload"' EXIT

json_status_response() {
    echo "HTTP_STATUS=$1"
    cat "$body"
    echo
}

# policy_local <max-time> <method> <url> [curl args...]
policy_local() {
    local max="$1" method="$2" url="$3"
    shift 3
    local st
    st="$(curl -sS -o "$body" -w "%{http_code}" --max-time "$max" -X "$method" "$@" "$url" 2>/dev/null)"
    echo "${st:-000}"
}

case "$cmd" in
    check-skill)
        status="$(policy_local 20 GET http://policy.local/v1/guide)"
        echo "HTTP_STATUS=$status"
        sed -n '1,40p' "$body"
        test "$status" = 200
        ;;
    current-policy)
        status="$(policy_local 20 GET http://policy.local/v1/policy/current)"
        json_status_response "$status"
        ;;
    put-file)
        owner="$1"; repo="$2"; branch="$3"; file_path="$4"; run_id="$5"
        python3 - "$branch" "$run_id" "$payload" <<'PY'
import base64, json, sys
branch, run_id, out = sys.argv[1], sys.argv[2], sys.argv[3]
content = f"""# OpenShell policy advisor demo\n\nRun id: {run_id}\n\nThis file was written from inside an OpenShell sandbox after an agent-authored\npolicy proposal was approved.\n"""
payload = {"message": f"docs: add OpenShell policy advisor demo note {run_id}",
           "branch": branch,
           "content": base64.b64encode(content.encode()).decode()}
with open(out, "w") as f:
    json.dump(payload, f)
PY
        status="$(curl -sS -o "$body" -w "%{http_code}" -X PUT \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: application/json" \
            --data-binary "@${payload}" \
            "https://api.github.com/repos/${owner}/${repo}/contents/${file_path}")"
        json_status_response "${status:-000}"
        ;;
    submit-proposal)
        owner="$1"; repo="$2"; file_path="$3"
        python3 - "$owner" "$repo" "$file_path" "$payload" <<'PY'
import json, sys
owner, repo, file_path, out = sys.argv[1:5]
doc = {"intent_summary": f"Allow curl to write the demo note to {owner}/{repo} at {file_path} only.",
       "operations": [{"addRule": {"ruleName": "github_api_demo_contents_write",
         "rule": {"name": "github_api_demo_contents_write",
                  "endpoints": [{"host": "api.github.com", "port": 443, "protocol": "rest", "enforcement": "enforce",
                                 "rules": [{"allow": {"method": "PUT", "path": f"/repos/{owner}/{repo}/contents/{file_path}"}}]}],
                  "binaries": [{"path": "/usr/bin/curl"}]}}}]}
with open(out, "w") as f:
    json.dump(doc, f)
PY
        status="$(policy_local 20 POST http://policy.local/v1/proposals \
            -H "Content-Type: application/json" --data-binary "@${payload}")"
        json_status_response "$status"
        ;;
    submit-test-proposal)
        rule_id="$1"
        python3 - "$rule_id" "$payload" <<'PY'
import json, sys
rule_id, out = sys.argv[1:3]
doc = {"intent_summary": f"Smoke test proposal {rule_id}",
       "operations": [{"addRule": {"ruleName": f"smoke_{rule_id}",
         "rule": {"name": f"smoke_{rule_id}",
                  "endpoints": [{"host": "example.invalid", "port": 443, "protocol": "rest", "enforcement": "enforce",
                                 "rules": [{"allow": {"method": "GET", "path": f"/{rule_id}"}}]}],
                  "binaries": [{"path": "/usr/bin/curl"}]}}}]}
with open(out, "w") as f:
    json.dump(doc, f)
PY
        status="$(policy_local 20 POST http://policy.local/v1/proposals \
            -H "Content-Type: application/json" --data-binary "@${payload}")"
        json_status_response "$status"
        ;;
    proposal-status)
        status="$(policy_local 20 GET "http://policy.local/v1/proposals/$1")"
        json_status_response "$status"
        ;;
    proposal-wait)
        # Upstream sets no --max-time; the server clamps the wait to 300 s.
        status="$(policy_local 330 GET "http://policy.local/v1/proposals/$1/wait?timeout=${2:-60}")"
        json_status_response "$status"
        ;;
    *)
        echo "unknown command: $cmd" >&2
        exit 64
        ;;
esac
