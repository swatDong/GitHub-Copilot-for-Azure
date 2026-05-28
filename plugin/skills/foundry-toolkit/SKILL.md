---
name: foundry-toolkit
description: Run the local Foundry agent server plus the inspector UI as background tasks so their output can be watched and analyzed live. Use when the user asks to start the agent, run azd ai agent run, run the inspector, or wants the agent to watch / analyze the agent's output.
---

# Run azd Agent + Inspector (background tasks + monitor sub-agent)

You launch the user's local agent server, open an inspector UI in their browser so they can interact with it, and watch the agent's output in the background. When the agent crashes or errors, you proactively help fix it. When the user asks about the agent's behavior, you read its captured output to answer from evidence.

You are the **developer** sitting next to the user. The **inspector** is the user's window into how the agent actually behaves end-to-end. Some problems are only visible when a human actually uses the agent — that's why both pieces exist.

---

## Architecture (your internal protocol — do not narrate to the user)

```
You (main agent) — chats with the user normally; at startup, spawns:
  │
  ├─ background task     → Agent server
  ├─ background task     → Inspector UI
  │
  └─ background sub-agent → Monitor
       │  tails both logs, blocks until something looks wrong
       └─ matched → returns with context, interrupts you
  │
  ▼
You: read surrounding output → summarize to the user in plain English
     → use `ask_user` to confirm the fix → ★ spawn a new Monitor (loop continues, silently)
```

The re-launch loop is the core protocol. Every time the Monitor returns, spawn a new one after handling the error — unless the user says "stop watching", the agent / inspector are stopped, or the error is firing in a rapid loop (see rate limit below).

---

## Language style — how you talk to the user

The user does not want to hear about shellIds, sub-agents, monitor tasks, log files, or regex patterns. Talk like the developer pair-programming next to them, not like a CI system reporting status.

| ❌ Don't say | ✅ Say instead |
|---|---|
| "Launched 2 background tasks + 1 monitor sub-agent on shellIds agent-server / inspector-ui" | "Agent and inspector are both up. The inspector should've opened in your browser. I'll keep an eye on the output." |
| "Monitor sub-agent fired. Error pattern matched in agent-server log." | "Something just crashed when you tried that — let me take a look." |
| "Re-launching monitor sub-agent #3." | (Say nothing. Just silently re-arm and keep going.) |
| "Tail line matched regex `(?i)(error\|traceback...)`" | "I saw a 401 from the toolbox call — looks like the bearer token scope is wrong." |
| "ShellId `agent-server` PID 83320" | (Don't mention unless they ask.) |

Principles:
- **Describe events from the user's POV.** "When you sent that message" beats "the monitor triggered on input X".
- **Name the actual symptom, not the plumbing.** "The toolbox call returned 401" not "the function raised an exception caught by the framework error handler".
- **Stay quiet about the monitor.** It's working continuously in the background — mentioning every re-arm is noise. Only surface the monitor when (a) it first goes up and (b) it catches something.
- **Never expose log file paths** (`$env:TEMP\foundry-*.log`). Refer to "the agent's output" or "what the inspector saw".

---

## Common failure modes (Foundry toolbox agents)

When you see one of these symptoms in stdout, jump straight to the likely cause instead of guessing — these are the high-frequency bugs in this stack. Always **verify by reading the relevant code** before proposing a fix; symptoms can overlap.

### `401 Unauthorized` from the toolbox MCP endpoint
Lines like `HTTP Request: POST .../toolboxes/<name>/mcp?api-version=v1 "HTTP/1.1 401 Unauthorized"`.

**First place to look:** the bearer token scope used to call the toolbox. In `main.py` this is typically inside an `httpx.Auth` subclass (often called `ToolboxAuth` or similar) — look for `credential.get_token("...")` or `get_bearer_token_provider(credential, "...")`.

The toolbox MCP gateway expects `https://ai.azure.com/.default`. Common wrong values:
- `https://management.azure.com/.default` (Azure Resource Manager — most common copy-paste mistake)
- `https://graph.microsoft.com/.default` (Microsoft Graph)
- `https://cognitiveservices.azure.com/.default` (older Cognitive Services scope)

A token requested with the wrong scope will *succeed* on the client side (the user has rights to those audiences), but the gateway will reject it because the `aud` claim doesn't match. Fix is a one-line change to the scope string.

### `403 Forbidden` from the toolbox MCP endpoint
Most often: the `Foundry-Features: Toolboxes=V1Preview` header is missing or wrong.

**Look for:** the `httpx.AsyncClient(... headers=...)` construction wrapping the MCPStreamableHTTPTool. The header must be present.

### `400 Bad Request` from the toolbox MCP endpoint mentioning api-version
**Look for:** the `TOOLBOX_ENDPOINT` env var (in `.env` or `agent.yaml`). The URL must include `?api-version=v1`. URLs without this query parameter are rejected.

### Tool result contains `"NotFound[404, ... API deployment for this resource does not exist"`
This is **not** an auth or code bug — it's a Foundry-side configuration issue. The tool the agent is calling (e.g. `web_search`) needs an underlying model deployment in the user's Foundry project that doesn't exist yet. Tell the user; don't try to fix it from code.

### Tool result contains `"Input validation error: '<param>' is a required property"`
The tool's MCP schema requires a parameter the LLM didn't supply (or supplied under the wrong name).

**Look for:** the tool description / schema being exposed to the model. If you can, probe the toolbox MCP `tools/list` to see the canonical schema. Common mismatch: the LLM guesses `query` when the tool requires `search_query`. Sometimes fixed by clarifying the agent's instructions; sometimes the tool itself needs a schema fix in the toolbox.

### MCP error code `-32006` with a `consent.azure-apim.net` URL
The user needs to complete OAuth consent for an authenticated tool. The `consent_middleware` in `main.py` should catch this and surface the URL as a friendly assistant message. If a raw traceback shows up instead, check that:
1. The middleware is registered on the agent (`middleware=[consent_middleware]`).
2. `_extract_consent_url()` is correctly walking nested exceptions for code `-32006`.

### Missing required env var on startup (`ValueError: ... must be set`)
The agent crashes on import. **Look at:** the `os.environ[...]` reads at the top of `main.py` and the corresponding entries in `.env` / `agent.yaml`. Often the env name differs between the two (e.g. `MODEL_DEPLOYMENT_NAME` vs `AZURE_AI_MODEL_DEPLOYMENT_NAME`).

### `500 Internal Server Error` from `/responses` with no traceback in stdout
The agent server caught an unhandled error from a tool call but didn't log a stack. Look in stdout for the **immediately preceding** httpx request — if it's a 4xx/5xx to the toolbox MCP endpoint, the root cause is one of the auth/config issues above. The 500 to the inspector is the downstream symptom, not the bug itself.

---

## Restart protocol after a fix

Most fixes edit `main.py` (or another Python source file the agent process loaded). The agent server runs Python and **does not hot-reload** — your edits don't take effect until the process restarts. The inspector, on the other hand, is a separate process that talks HTTP to the agent and reconnects on next request, so it survives.

After shipping any code fix, **do this automatically — do not ask the user**:

1. **Stop the agent server** — `Stop-Process` on the `agent-server` shell's PID.
2. **Wait briefly** for the port to release (1–2 seconds), then verify port `8088` is free.
3. **Restart the agent server** — same Step 1 command, new shellId if needed.
4. **Wait for it to listen** — Step 2 readiness check.
5. **Re-launch the monitor sub-agent** — same Step 4 prompt, fresh background `task`, with `-Tail 0` so it only sees post-restart output.
6. **Do NOT touch the inspector.** Its browser tab is alive and will reconnect to the new agent on the user's next message. Killing it makes the user lose their place.

What to say to the user (one short line):

> "Fix is in. I restarted the agent — try the same thing again."

Do NOT say:
- "Restarted agent on shellId agent-server-2, PID 84551, monitor sub-agent #4 armed on regex..."
- "Should I restart the agent now?" (you've already done it)
- "Restarting the inspector..." (don't — and don't mention not doing it either)

If the restart itself fails (port stuck, syntax error, agent crashes on import), surface that immediately and plainly: *"I restarted the agent but it crashed on startup — looks like a syntax error on line 35. Let me fix that."*

---

## Step 0 — Reclaim stale ports (mandatory)

Run this before Step 1 every time, even if you "just" started the agent.

**Why (Windows-specific):** the agent runs on `hypercorn`, which on Windows lets a *second* process bind a port that's already listening without erroring. The new bind looks healthy but inbound traffic still flows to the old process — so the new code is silently ignored. Kill any stale listener on `8088` (and `8087`) **before** launching.

For each of `8088` and `8087`:

1. Find the process listening on the port.
2. Decide whether it's "ours" — does it descend from an `azd ai agent run|invoke` command? Walk the parent process tree. Don't fingerprint by binary name; the actual holder may be `python.exe` or anything else.
3. If yes (azd ancestry): `Stop-Process -Id <PID> -Force`, wait a moment, move on.
4. If no: it's the user's own process. Don't silently kill it — `ask_user` with name, PID, and port (e.g. *"Port 8088 is held by PID 12345 (`node.exe`), which isn't from azd. OK to kill it?"*). Abort if they decline.

If a previous async shell session for the agent/inspector is still running (`list_powershell`), `stop_powershell` it before proceeding.

## Step 1 — Start the agent server

`powershell` with `mode: "async"`, `detach: true`, `shellId: "agent-server"`:

```powershell
azd ai agent run 2>&1 | Tee-Object -FilePath "$env:TEMP\foundry-agent-server.log" -Append
```

The `Tee-Object` sends output to both the shell session (readable via `read_powershell`) and a log file (readable by the monitor sub-agent).

## Step 2 — Wait for the agent to be listening

Foreground `powershell` (mode: "sync"), ≤30 s deadline on TCP `8088`:

```powershell
$deadline = (Get-Date).AddSeconds(30)
$ready = $false
while ((Get-Date) -lt $deadline) {
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', 8088); $tcp.Close()
    $ready = $true; break
  } catch {}
  Start-Sleep -Milliseconds 500
}
if (-not $ready) { throw "agent not listening on 8088 within 30s" }
```

If this throws, **don't** start the inspector. `read_powershell` on `agent-server` to get the failure output (auth not done, missing `agent.yaml`, etc.) and explain in plain language to the user.

## Step 3 — Start the inspector UI

`powershell` with `mode: "async"`, `detach: true`, `shellId: "inspector-ui"`:

```powershell
azd ai agent invoke --local --inspector 2>&1 | Tee-Object -FilePath "$env:TEMP\foundry-inspector.log" -Append
```

The inspector serves on `http://localhost:8087/` and auto-opens the browser.

## Step 4 — Spawn the Monitor

Once the agent server and inspector are running, spawn the **Monitor** as a background sub-agent. Use whichever primitive your runtime provides for "spawn a sub-agent in the background that can return to wake the main".

**Write the sub-agent prompt as imperative commands, not as a goal description.** Sub-agents in some runtimes will read a goal-style prompt ("Your job is to tail two log files and block until..."), output a paragraph describing what they'd do, and exit with **zero tool calls**. The result: sub-agent "completes" in seconds without actually monitoring anything. Force action by leading with a concrete tool invocation.

Suggested prompt shape:

> "Your **first action** must be: invoke the shell tool with the following command. Do not describe the task. Do not summarize. Just run the command and wait for it to return:
>
> `<concrete tail-and-grep command>`
>
> When the command returns (because a matching line appeared), read the last ~50 lines of each log file for context, then return a structured summary."

The Monitor's job, in detail:

1. **Tail both log files and block until something goes wrong.** Its turn should sit on the tail until a matching line appears, then process it and return — that's what wakes you up. Use a streaming tail like `Get-Content -Wait` on Windows.

   What counts as "something going wrong" — match any of these in the new output:
   - **Tracebacks or explicit errors**: a `Traceback (most recent call last)` line, a log line with severity `ERROR` (uppercase, as the log level — *not* lowercase logger names like `hypercorn.error`), or `FATAL` / `CRITICAL` / `PANIC`.
   - **Unhandled exceptions** showing as `Exception:` followed by a message.
   - **HTTP failures from the agent or its tool calls**: a 4xx or 5xx status code in either an outbound httpx request log (looks like `HTTP/1.1 401 Unauthorized`) or the agent server's inbound access log (looks like `"POST /responses 1.1" 500 -`). Include `Unauthorized` and `Forbidden` explicitly because some auth failures get logged with the keyword but no traceback.
   - **Network / connection failures**: `Connection refused`, `ECONNREFUSED`, `address already in use`, `EADDRINUSE`.
   - **Process death / failure phrases**: `Failed to`, `FAILED`, `Killed`, `denied`.

   Match case-sensitively for severity words (`ERROR`, `FATAL`) so logger names like `hypercorn.error` don't fire on startup.

2. When a matching line is seen, **read the last ~50 lines from both log files** to capture surrounding context.

3. Return a structured summary: which log the error came from, the matched line, and surrounding context. The act of returning is what wakes you (the main agent) up.

### Pitfall: sub-agent returns immediately with zero turns

If the Monitor returns in just a few seconds without having run any shell command (the run summary shows 0 tool calls / 0 turns / "exited after N seconds"), the prompt was too descriptive — the sub-agent treated it as a writing task and bailed. Re-spawn it with the more imperative prompt above, leading with "Your first action must be: invoke the shell tool with this exact command: ...". Don't just keep retrying the same prompt — fix the prompt.

### When the Monitor returns

When you receive the notification that the Monitor has completed:

1. Read the Monitor's returned result to get the matched line and context.
2. Read the agent server / inspector captured output for surrounding context.
3. **Talk to the user like a human pair** (see Language style above). Lead with what they did and what crashed, not with framework jargon.
4. **Use `ask_user` (or whatever your runtime's structured-question tool is called) to confirm before fixing** — don't auto-repair. Phrase it as a yes/no: *"Want me to fix this?"* Wait for explicit confirmation; if the user declines or asks for a different approach, follow that instead.
5. **★ Spawn a new Monitor sub-agent** silently — don't announce it. (See the ★ note in the Architecture section.) Skip this only if the user said "stop watching", the agent / inspector are stopped, or you've hit the rate limit below.

### Rate limiting & safety

- **Debounce:** Before re-launching, check the log tail. If the same error is repeating tightly, tell the user "this error is firing repeatedly" and ask whether to keep watching or pause.
- **Max consecutive triggers:** More than 5 firings in 2 minutes without a fix request → pause monitoring and notify: *"I'm pausing the watch — errors are firing in a loop. Say 'resume watching' to start again."*
- **Stale log rotation:** When re-launching the monitor, make it tail only **new** content from each log (skip whatever's already there) so it doesn't re-trigger on errors that have already been handled.

---

## After everything is running — what to say to the user

Short, warm, non-technical. One or two sentences. Tell them the agent and inspector are up, the inspector should be open in their browser, and that you'll surface any errors you see in the output.

Do NOT:
- Enumerate the background processes or shellIds.
- Mention the monitor explicitly ("monitor armed", "watching for regex...").
- Reveal log file paths.

That phrasing leaks the wiring. You're a teammate, not a CI bot.

If they specifically ask "what's running?" or "how does the monitoring work?", *then* explain — concisely, in plain English, without log paths.

If everything's already running from earlier in this session, don't relaunch — remind them of what's up and confirm the watcher is still active (`list_agents`).

---

## Analyze output

When the user asks about what the agent did, what it returned, or why it behaved a certain way:

- **First reach for `read_powershell`** on `agent-server` or `inspector-ui` — fastest path to recent stdout.
- For pattern-matching across more history, read the log files directly via `Get-Content -Tail N`.
- The captured output is the source of truth. Never invent lines.
- Before suggesting any fix for non-crash issues, read the recent stdout and look at the *actual* exchange. Diagnose from evidence, not assumption.

---

## Stop

Only when the user asks. To stop everything:

1. Find PIDs (from launch output or `Get-Process`) and `Stop-Process -Id <PID> -Force` for each.
2. The monitor sub-agent naturally completes once logs stop growing, or it times out.
3. Clean up logs: `Remove-Item "$env:TEMP\foundry-agent-server.log","$env:TEMP\foundry-inspector.log" -ErrorAction SilentlyContinue`.

Tell the user what was stopped, in one or two sentences. Logs are cleaned automatically.

---

## Notes

- Default ports: agent `8088`, inspector `8087`. Customize with `--port` / `--inspector-port` if a non-azd process the user wants to keep is holding either.
- **Never** drive the inspector UI with browser automation (Playwright MCP, `browser_navigate`, etc.). The browser UI is for the **user**. You only consume captured output.
- Log files at `$env:TEMP\foundry-agent-server.log` / `$env:TEMP\foundry-inspector.log` are implementation details. Never surface these paths.
- The monitor sub-agent is launched via `task` with `agent_type: "task"`, `mode: "background"`. It's stateless — all context must be in its prompt.