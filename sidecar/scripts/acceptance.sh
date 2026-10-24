#!/usr/bin/env bash
# M2 acceptance: drives a real daemon end to end over control.sock with
# curl --unix-socket (Git Bash on Windows; bash on macOS/Linux).
#
#   scripts/acceptance.sh [path/to/bromure-sidecar[.exe]]
#
# Runs against an isolated data dir and SSH port (never the user's own
# Sidecar). ACCEPT_CLAUDE=1 also starts a real Claude Code session (hooks,
# agentStatus, transcript) — it may ask to trust the folder; no prompt is
# sent to the model unless ACCEPT_CLAUDE_PROMPT=1.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
exe="${1:-}"
if [ -z "$exe" ]; then
  exe="$here/dist/acceptance/bromure-sidecar"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe="$exe.exe";; esac
  ( cd "$here" && go build -o "$exe" ./cmd/bromure-sidecar ) || exit 1
fi
data="$(mktemp -d)"
export BROMURE_SIDECAR_DATA="$data"
export BROMURE_SIDECAR_SSH_PORT="${ACCEPT_SSH_PORT:-2299}"
sock="$data/control.sock"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
req()  { # method path [json]
  if [ -n "${3:-}" ]; then
    curl -s --max-time 60 --unix-socket "$sock" -X "$1" -H 'Content-Type: application/json' --data-binary "$3" "http://localhost$2"
  else
    curl -s --max-time 60 --unix-socket "$sock" -X "$1" "http://localhost$2"
  fi
}
expect() { # name haystack needle
  case "$2" in *"$3"*) ok "$1";; *) bad "$1" "wanted '$3' in: ${2:0:300}";; esac
}
num() { sed -n "s/.*\"$1\":\([0-9-]*\).*/\1/p" | head -1; }

cleanup() {
  req POST /sidecar/panehost-stop '{"force":true}' >/dev/null 2>&1
  req POST /sidecar/quit '{}' >/dev/null 2>&1
  sleep 1
  kill "$daemon" 2>/dev/null
  rm -rf "$data"
}
trap cleanup EXIT

echo "== daemon ($exe, data $data)"
"$exe" serve >"$data/serve.log" 2>&1 &
daemon=$!
for _ in $(seq 1 50); do [ -S "$sock" ] || [ -e "$sock" ] && req GET /health >/dev/null 2>&1 && break; sleep 0.2; done

r=$(req GET /health);                expect "health" "$r" '"status":"ok"'
r=$(req GET /state);                 expect "state hostAPI" "$r" '"hostAPI":2'
expect "state hostOS" "$r" '"hostOS":'
expect "state home is virtual" "$r" '"home":"/home/ubuntu"'
expect "state running" "$r" '"state":"running"'
r=$(req GET /vms);                   expect "vms" "$r" '"hostKind":"agent-host"'
r=$(req GET /nope);                  expect "unknown route" "$r" 'Not available on a native machine'

echo "== exec"
r=$(req POST /vms/x/exec '{"command":"echo hi; echo $HOME; pwd"}')
expect "exec stdout" "$r" '"stdout":"hi\n'
expect "exec home mapped back" "$r" '/home/ubuntu'
expect "exec exit" "$r" '"exitCode":0'
r=$(req POST /vms/x/exec '{"command":"ls /home/ubuntu >/dev/null && echo mapped"}')
expect "exec /home/ubuntu maps" "$r" 'mapped'
r=$(req POST /vms/x/exec '{"command":"sleep 5","timeout":1}')
expect "exec timeout 124" "$r" '"exitCode":124'
r=$(req POST /vms/x/exec '{"argv":["tmux","-V"]}')
expect "argv exec (tmux shim)" "$r" 'tmux'
r=$(req POST /vms/x/exec '{"command":"git -C /home/ubuntu rev-parse --is-inside-work-tree 2>&1; git --version"}')
expect "git under Git Bash" "$r" 'git version'

echo "== files"
d="/home/ubuntu/.bromure/acceptance-$$"
r=$(req POST /vms/x/file "{\"op\":{\"op\":\"mkdir\",\"path\":\"$d\"}}");  expect "mkdir" "$r" '"exit_code":0'
r=$(req POST /vms/x/file "{\"op\":{\"op\":\"write\",\"path\":\"$d/a.txt\",\"data\":\"aGVsbG8K\"}}"); expect "write" "$r" '"exit_code":0'
r=$(req POST /vms/x/file "{\"op\":{\"op\":\"read\",\"path\":\"$d/a.txt\"}}"); expect "read" "$r" '"data":"aGVsbG8K"'
r=$(req POST /vms/x/file "{\"op\":{\"op\":\"list\",\"path\":\"$d\"}}");  expect "list" "$r" '"name":"a.txt"'
r=$(req POST /vms/x/file "{\"op\":{\"op\":\"remove\",\"path\":\"$d\"}}"); expect "remove" "$r" '"exit_code":0'
r=$(req POST /agent-sessions/folders '{"path":"~"}'); expect "folders" "$r" '"folders":['

echo "== panes + tmux shim"
r=$(req POST /sessions/x/tab '{"action":"new"}'); expect "new shell tab" "$r" '"ok":true'
sleep 2
r=$(req POST /vms/x/exec '{"command":"tmux list-windows -t bromure -F \"#{window_index}\t#{window_id}\t#{pane_tty}\t#{pane_current_path}\""}')
expect "tmux list-windows" "$r" '/dev/pty/bromure-'
win=$(printf '%s' "$r" | sed -n 's/.*"stdout":"\([0-9]*\)\\t.*/\1/p')
[ -n "$win" ] || win=0
r=$(req POST /vms/x/exec "{\"command\":\"tmux send-keys -t bromure:$win -l 'echo accept-\$((40+2))' && tmux send-keys -t bromure:$win Enter; sleep 1.5; tmux capture-pane -p -t bromure:$win\"}")
expect "send-keys + capture" "$r" 'accept-42'
r=$(req POST /vms/x/exec "{\"command\":\"tty=\$(tmux display-message -p -t bromure:$win '#{pane_tty}'); ps -t \${tty#/dev/} -o pid=,stat=,args=\"}")
expect "ps shim by tty" "$r" 'bash'
r=$(req POST /vms/x/screen "{\"window\":$win}");  expect "screen route" "$r" '"cursor":{'
r=$(req POST /vms/x/type "{\"target\":{\"ref\":{\"index\":{\"_0\":$win}},\"foreground\":{\"shell\":{}}},\"text\":\"echo typed-\$((1+1))\"}")
expect "type route (shell)" "$r" 'BROMURE_TYPE_OK'
sleep 1.5
r=$(req POST /vms/x/screen "{\"window\":$win}");  expect "type landed" "$r" 'typed-2'
r=$(req POST /vms/x/type "{\"target\":{\"ref\":{\"index\":{\"_0\":$win}},\"foreground\":{\"agent\":{}}},\"text\":\"x\"}")
expect "type refuses a shell for an agent" "$r" 'BROMURE_TYPE_REFUSED shell'

echo "== interactive exec (frame stream)"
# A 'command' run in a fresh pseudoconsole: the reply is a 200 header, then
# frames; the exit frame is type 2. curl can't speak frames back, so it
# just reads until the exit frame (stdin EOF from curl is ignored).
r=$(curl -s --max-time 20 --unix-socket "$sock" -X POST --data-binary '{"interactive":true,"command":"echo framed-ok","cols":80,"rows":24}' http://localhost/vms/x/exec --output - | tr -d '\000-\010' | head -c 4000)
expect "framed output" "$r" 'framed-ok'

if [ "${ACCEPT_CLAUDE:-0}" = 1 ]; then
  echo "== Claude session (hooks)"
  r=$(req POST /agent-sessions/start '{"tool":"claude","cwd":"~"}')
  expect "start claude" "$r" '"ok":true'
  cw=$(printf '%s' "$r" | num window)
  sleep 8
  r=$(req GET /state); expect "session listed" "$r" '"agentSessions":[{'
  expect "agent{} on the tab" "$r" '"agent":{'
  # Clear the folder-trust gate, because on a FRESH machine there always is
  # one. Claude opens it before its hooks exist, so the session sits at
  # needsInput and neither of the two checks below can ever pass. The engine
  # sees the gate (`waitsOnUser`) and deliberately does not answer it --
  # trusting a folder is the user's call, and in Bromure AC the user clicks
  # it. Here the script IS the user, so it presses the same keys a person
  # would. Measured on a fresh Linux box: without this, "agentStatus from
  # hooks" and "transcript-chunk" fail every run, which is exactly the
  # machine a Linux Sidecar is installed on.
  for _ in $(seq 1 20); do
    s=$(req POST /vms/x/screen "{\"window\":$cw}")
    case "$s" in
      *"trust this folder"*|*"Enter to confirm"*)
        req POST /vms/x/exec "{\"command\":\"tmux send-keys -t bromure:$cw Down\"}" >/dev/null
        sleep 1
        req POST /vms/x/exec "{\"command\":\"tmux send-keys -t bromure:$cw Enter\"}" >/dev/null
        sleep 3
        ;;
      *) break;;
    esac
  done
  if [ "${ACCEPT_CLAUDE_PROMPT:-0}" = 1 ]; then
    id=$(printf '%s' "$r" | sed -n 's/.*"agentSessions":\[{[^]]*"id":"\([0-9A-F-]*\)".*/\1/p')
    req POST "/agent-sessions/$id/send" '{"text":"Reply with the single word: pong"}' >/dev/null
    # Wait for the condition, not a fixed 20s: a cold model start or a slow
    # link blows through any sleep, and the failure then reads as a broken
    # hook rather than a short wait.
    st=""
    for _ in $(seq 1 40); do
      st=$(req GET /state)
      case "$st" in *'"agentStatus":"done"'*) break;; esac
      sleep 3
    done
    expect "agentStatus from hooks" "$st" '"agentStatus":"done"'
    tc=""
    for _ in $(seq 1 20); do
      tc=$(req POST /vms/x/transcript-chunk "{\"window\":$cw,\"bytes\":100000,\"mode\":\"tail\"}")
      [ -n "$tc" ] && break
      sleep 3
    done
    expect "transcript-chunk" "$tc" '/home/ubuntu/.claude/projects/'
  fi
  req POST /sessions/x/tab "{\"action\":\"close\",\"index\":$cw}" >/dev/null
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
