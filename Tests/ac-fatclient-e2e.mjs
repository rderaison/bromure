#!/usr/bin/env node
/**
 * Bromure Agentic Coding E2E Test Suite — fat client
 *
 * The same tests as Tests/ac-e2e.mjs, run through the rich ("fat") client
 * instead of against the local app:
 *
 *   0. The app's SSH front door comes up on localhost:2222 (pubkey-only on
 *      127.0.0.1 unless it already listens there; the user's own remote-access
 *      settings are put back afterwards). The app mints a throwaway login
 *      (POST /remote/test-login — a random user + password, debug runs only,
 *      in memory until relaunch). The client signs in with it: a wrong
 *      password and the owner's name are refused, the right password
 *      enrolls the client key, and the key then signs in alone. The client's
 *      tunnel, CLI transport and mirror window all connect.
 *   1–34. The native suite, with every request riding that tunnel:
 *      HTTP/control-socket routes through `bromure-ac __fatclient-proxy`,
 *      the CLI through BROMURE_AC_REMOTE_HOST, the AppleScript verbs through
 *      POST /scripting on the server, and session start/stop + the settings
 *      editor through the client's mirror window.
 *
 * Client and server are the same app on this Mac (a self-mirror): run it
 * against the app you'd run ac-e2e.mjs against. Same prerequisites (a built
 * app bundle, a base image; BROMURE_DEBUG_CLAUDE=1 — the preflight launches
 * the app with it if it isn't running).
 *
 * Usage:
 *   node Tests/ac-fatclient-e2e.mjs                  # run all
 *   node Tests/ac-fatclient-e2e.mjs --filter mcp     # tests matching "mcp"
 *   node Tests/ac-fatclient-e2e.mjs --no-sessions    # skip VM-booting tests
 *
 * Env: everything ac-e2e.mjs reads, plus BROMURE_AC_FATCLIENT_PORT (the front
 * door's port, default 2222).
 */

process.env.BROMURE_AC_E2E_FATCLIENT = "1";
await import("./ac-e2e.mjs");
