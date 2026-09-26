#!/usr/bin/env python3
"""Write the manual-screenshot demo fixture (spec.json + Claude transcripts).

Usage: scripts/manual-demo/make-fixture.py <out-dir>

The fixture is synthetic: invented machines, sessions and conversations (no
real user data, no personal names) for the manual's screenshots of the main
window. `POST /debug/editor {"action":"seed-demo","spec":"<out-dir>/spec.json"}`
loads it into a running app (see Sources/AgentCoding/DemoMode.swift).
"""
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bromure-manual-demo"
os.makedirs(OUT, exist_ok=True)

_ids = [0]


def nid(prefix="t"):
    _ids[0] += 1
    return f"{prefix}{_ids[0]}"


def user(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def assistant(*blocks):
    return {"type": "assistant", "message": {"role": "assistant", "content": list(blocks)}}


def text(s):
    return {"type": "text", "text": s}


def thinking(s):
    return {"type": "thinking", "thinking": s}


def tool(name, **inp):
    return {"type": "tool_use", "id": nid(), "name": name, "input": inp}


def result(use, content, error=False):
    block = {"type": "tool_result", "tool_use_id": use["id"], "content": content}
    if error:
        block["is_error"] = True
    return {"type": "user", "message": {"role": "user", "content": [block]}}


def call(name, output, lead=None, **inp):
    """An assistant turn making one tool call, and its result."""
    use = tool(name, **inp)
    blocks = ([text(lead)] if lead else []) + [use]
    return [assistant(*blocks), result(use, output)]


def write(name, lines):
    with open(os.path.join(OUT, name), "w") as f:
        for line in lines:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
    return name


# ── Transcripts ──────────────────────────────────────────────────────────

checkout = [user("The checkout page double-charges when someone clicks Pay twice. Can you find out why and fix it?")]
checkout += call("Grep", "src/checkout/PayButton.tsx:42:    onClick={() => submitOrder(cart)}\nsrc/api/orders.ts:18:export async function submitOrder(cart: Cart) {",
                 "I'll start with how the Pay button submits the order.", pattern="submitOrder", path="src")
checkout += call("Read", "export async function submitOrder(cart: Cart) {\n  const res = await fetch('/api/orders', {\n    method: 'POST',\n    body: JSON.stringify(cart),\n  })\n  return res.json()\n}",
                 None, file_path="/home/ubuntu/northwind-web/src/api/orders.ts")
q = tool("AskUserQuestion", questions=[{
    "question": "How should I prevent the double charge?",
    "header": "Fix",
    "multiSelect": False,
    "options": [
        {"label": "Disable the button", "description": "Grey out Pay while the request is in flight (client only)"},
        {"label": "Idempotency key", "description": "Send a per-checkout key; the API ignores repeats (client + server)"},
        {"label": "Both", "description": "Disable the button and add the key"},
    ]}])
checkout += [assistant(text(
    "Found it: `PayButton` calls `submitOrder()` on every click, and nothing stops a second "
    "request while the first is in flight. The orders API has no idempotency key either, so "
    "both requests create a charge."), q)]

applepay = [user("Add Apple Pay to the checkout, behind the `applePay` feature flag.")]
applepay += call("TodoWrite", "Todos updated", "Here's the plan.", todos=[
    {"content": "Add the Apple Pay button component", "status": "completed", "activeForm": "Adding the Apple Pay button"},
    {"content": "Create a payment session on the API", "status": "completed", "activeForm": "Creating the payment session endpoint"},
    {"content": "Wire the button into checkout behind the flag", "status": "in_progress", "activeForm": "Wiring the button into checkout"},
    {"content": "Add tests for the session endpoint", "status": "pending", "activeForm": "Adding tests"},
])
applepay += call("Read", "import { PayButton } from './PayButton'\n\nexport function PaymentOptions({ cart }: Props) {\n  return (\n    <div className=\"payment-options\">\n      <PayButton cart={cart} />\n    </div>\n  )\n}",
                 None, file_path="/home/ubuntu/northwind-web/src/checkout/PaymentOptions.tsx")
applepay += call("Edit", "The file has been updated.", "Now the button itself, shown only when the flag is on and the browser supports it.",
                 file_path="/home/ubuntu/northwind-web/src/checkout/PaymentOptions.tsx",
                 old_string="      <PayButton cart={cart} />\n",
                 new_string="      <PayButton cart={cart} />\n      {flags.applePay && canUseApplePay() && (\n        <ApplePayButton cart={cart} onPaid={onPaid} />\n      )}\n")
applepay += call("Bash", "PASS src/checkout/PaymentOptions.test.tsx\n  ✓ renders the card button (21 ms)\n  ✓ hides Apple Pay when the flag is off (9 ms)\n  ✓ shows Apple Pay when supported (12 ms)\n\nTests: 3 passed, 3 total",
                 None, command="npm test -- PaymentOptions", description="Run the checkout tests")
applepay += [assistant(thinking("The UI side works. Next: the session endpoint needs a test for an expired merchant certificate."),
                       text("The button is wired in and its tests pass. Now I'm adding tests for the payment-session endpoint."))]

refunds = [user("Refund webhooks fail silently when the payment provider times out. Add retries with backoff.")]
refunds += call("Grep", "src/webhooks/refunds.ts:12:export async function handleRefund(event) {", None, pattern="handleRefund", path="src")
refunds += call("Edit", "The file has been updated.", "I'll wrap the provider call in a retry with exponential backoff.",
                file_path="/home/ubuntu/payments-api/src/webhooks/refunds.ts",
                old_string="  const refund = await provider.refund(event.paymentId)\n",
                new_string="  const refund = await withRetry(() => provider.refund(event.paymentId), {\n    attempts: 5,\n    backoffMs: 500,\n  })\n")
refunds += call("Bash", "Tests: 14 passed, 14 total", None, command="npm test", description="Run the test suite")
refunds += [assistant(text(
    "Done. Refunds now retry up to five times with exponential backoff (0.5 s, 1 s, 2 s, 4 s, 8 s), "
    "and a final failure is logged with the payment id instead of being dropped.\n\n"
    "All 14 tests pass. The change is on branch `refund-retries`, ready for review."))]

react = [user("Upgrade the web app to React 19 and fix whatever breaks.")]
react += call("Bash", "npm warn peer react@\"^18\" from @northwind/ui@2.4.1\nadded 3 packages, changed 5 packages in 6s",
              "Starting with the dependency bump.", command="npm install react@19 react-dom@19", description="Upgrade React")
react += call("Bash", "src/components/Modal.tsx(14,5): error TS2322: Type 'RefObject<HTMLDivElement | null>' is not assignable...\nFound 3 errors in 2 files.",
              None, command="npx tsc --noEmit", description="Type-check the project")
react += [assistant(text("Three type errors, all from the new `useRef` typing. Fixing them now."))]

switchboard = [user("What's going on across my sessions?")]
switchboard += [assistant(text(
    "Here's where things stand:\n\n"
    "- **@checkout** (Web app) needs you: it found the double-charge bug and is asking how to fix it — "
    "disable the button, add an idempotency key, or both.\n"
    "- **@applepay** (Payments API) is working: the button is wired in behind the flag, tests next.\n"
    "- **React 19 upgrade** (Web app) is working through three type errors.\n"
    "- **@refunds** is ready: retries with backoff, 14 tests passing, on branch `refund-retries`.\n"
    "- **Checkout load test** is ready: p95 stays under 300 ms at 200 checkouts per second.\n\n"
    "| Session | Machine | State |\n|---|---|---|\n| @checkout | Web app | needs you |\n"
    "| @applepay | Payments API | working |\n| React 19 upgrade | Web app | working |\n"
    "| @refunds | Payments API | ready |\n\n"
    "Want me to answer @checkout with \"Both\"?"))]

room_sb = [user("Summarize the checkout work.")]
room_sb += [assistant(text(
    "Checkout revamp, four sessions:\n\n"
    "1. **@checkout** is waiting on your choice for the double-charge fix.\n"
    "2. **@applepay** is wiring Apple Pay in; tests are next.\n"
    "3. **@refunds** finished retries and is ready for review.\n"
    "4. **Checkout load test** passed at 200 checkouts per second.\n\n"
    "Nothing is blocked except @checkout."))]

loadtest = [user("Load-test the new checkout at 200 checkouts per second for five minutes.")]
loadtest += call("Bash", "  checks.........................: 100.00% ✓ 60000  ✗ 0\n  http_req_duration..............: avg=142ms  p(95)=287ms\n  iterations.....................: 60000  200/s",
                 None, command="k6 run --vus 200 --duration 5m load/checkout.js", description="Run the load test")
loadtest += [assistant(text("The checkout holds up: 60,000 checkouts, no errors, p95 at 287 ms."))]

export = [user("The nightly CSV export times out on large accounts. Stream the rows instead of building the file in memory.")]
export += call("Edit", "The file has been updated.", None,
               file_path="/home/ubuntu/pipeline/export/csv.py",
               old_string="rows = list(query.all())\nwrite_csv(path, rows)\n",
               new_string="with open(path, 'w', newline='') as f:\n    writer = csv.writer(f)\n    for row in query.yield_per(5000):\n        writer.writerow(row)\n")
export += [assistant(text("The export now streams rows in batches of 5,000, so memory stays flat whatever the account size."))]

darkmode = [user("Add a dark mode to the settings page.")]
darkmode += [assistant(text("Dark mode is in: the settings page follows the system appearance, with a manual override in the header."))]

onboarding = [user("Tighten the copy on the onboarding screens.")]
onboarding += [assistant(text("I shortened every onboarding screen to one sentence and a button."))]

# ── Spec ────────────────────────────────────────────────────────────────

spec = {
    "workspaces": [
        {"name": "Web app", "color": "blue", "running": True},
        {"name": "Payments API", "color": "green", "running": True},
        {"name": "Data pipeline", "color": "purple"},
    ],
    "rooms": [{"name": "Checkout revamp", "layout": "2x2"}],
    "sessions": [
        {"title": "Switchboard", "workspace": "Web app", "role": "switchboard", "cwd": "~/.bromure/switchboard",
         "state": "idle", "transcript": write("switchboard.jsonl", switchboard), "ageMinutes": 90, "idleMinutes": 2},
        {"title": "Fix double charge on checkout", "workspace": "Web app", "cwd": "~/northwind-web",
         "nickname": "checkout", "room": "Checkout revamp", "state": "needsYou",
         "transcript": write("checkout.jsonl", checkout), "ageMinutes": 25, "idleMinutes": 1},
        {"title": "Add Apple Pay to checkout", "workspace": "Payments API", "cwd": "~/northwind-web",
         "nickname": "applepay", "room": "Checkout revamp", "state": "working",
         "transcript": write("applepay.jsonl", applepay), "ageMinutes": 40, "idleMinutes": 0},
        {"title": "Refund webhook retries", "workspace": "Payments API", "cwd": "~/payments-api",
         "nickname": "refunds", "room": "Checkout revamp", "state": "idle",
         "branch": {"name": "refund-retries", "parent": "main", "ahead": 3, "changed": 0},
         "transcript": write("refunds.jsonl", refunds), "ageMinutes": 70, "idleMinutes": 6},
        {"title": "Checkout load test", "workspace": "Web app", "cwd": "~/northwind-web",
         "room": "Checkout revamp", "state": "idle",
         "transcript": write("loadtest.jsonl", loadtest), "ageMinutes": 55, "idleMinutes": 12},
        {"title": "Checkout revamp", "workspace": "Web app", "role": "switchboard", "room": "Checkout revamp",
         "cwd": "~/.bromure/rooms/checkout-revamp", "state": "idle",
         "transcript": write("room-switchboard.jsonl", room_sb), "ageMinutes": 60, "idleMinutes": 3},
        {"title": "Upgrade to React 19", "workspace": "Web app", "cwd": "~/northwind-web", "state": "working",
         "transcript": write("react19.jsonl", react), "ageMinutes": 18, "idleMinutes": 0},
        {"title": "Stream the nightly CSV export", "workspace": "Data pipeline", "cwd": "~/pipeline",
         "nickname": "export", "state": "asleep",
         "transcript": write("export.jsonl", export), "ageMinutes": 300, "idleMinutes": 240},
        {"title": "Dark mode for settings", "workspace": "Web app", "cwd": "~/northwind-web", "state": "ended",
         "transcript": write("darkmode.jsonl", darkmode), "ageMinutes": 600, "idleMinutes": 500},
        {"title": "Tighten the onboarding copy", "workspace": "Web app", "cwd": "~/northwind-web",
         "state": "archived", "transcript": write("onboarding.jsonl", onboarding),
         "ageMinutes": 1500, "idleMinutes": 1400},
    ],
}
with open(os.path.join(OUT, "spec.json"), "w") as f:
    json.dump(spec, f, indent=2)
print(os.path.join(OUT, "spec.json"))
