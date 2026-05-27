# Invoke Foundry Agent

Invoke deployed agents in Azure AI Foundry, or smoke-test a locally-running hosted agent. Use the `foundry` CLI as the primary entry point; sessions and conversations are persisted by the CLI automatically.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary command | `foundry agent invoke` (local + remote) |
| Conversation support | Single-turn and multi-turn (CLI auto-persists `conversationId` for `responses`, `sessionId` for `invocations`) |
| Session support | Managed sessions for hosted agents (CLI auto-creates on first invoke) |
| Protocols | `responses` (OpenAI-compatible), `invocations` (custom payloads); for `invocations_ws` use the dedicated sub-skill |

## When to Use This Skill

- Send messages to a deployed agent (single or multi-turn)
- Smoke-test a locally-running hosted agent
- Upload/download files to/from hosted agent sessions (still MCP — see [File Operations](#step-5-file-operations-hosted-agents))
- Validate agent behavior right after deploy

## CLI Commands

| Command | Purpose |
|---------|---------|
| `foundry agent invoke [<name>] "<message>"` | Remote invoke against the persisted default project endpoint; reads `<name>` from positional arg or `agent.yaml`. |
| `foundry agent invoke --project-endpoint <url> [<name>] "<message>"` | Remote invoke with an explicit project endpoint (overrides the default). |
| `foundry agent invoke --agent-endpoint <url> "<message>"` | Ephemeral remote invoke when you have the full agent endpoint URL (no project setup needed). |
| `foundry agent invoke --local "<message>"` | Smoke-test a local hosted agent listening on `:8088`. |
| `foundry agent invoke --local --inspect` | Launch the interactive web inspector against a local agent (chat + request/response + tool calls). |
| `foundry agent invoke ... -f <file>` | Send a file body instead of an inline message (works for both protocols). |
| `foundry agent invoke ... -p <responses|invocations>` | Force a protocol; otherwise auto-detected from `agent.yaml` or the agent endpoint URL. |
| `foundry agent invoke ... --new-session` / `--session-id <id>` | Reset or pin the session (any protocol). |
| `foundry agent invoke ... --new-conversation` / `--conversation-id <id>` | Reset or pin the conversation (`responses` only). |

> **Project endpoint** — pass `--project-endpoint <url>` to override; otherwise the CLI uses the default set via `foundry agent project set <url>` (inspect with `foundry agent project show`). If neither is available, ask the user.
>
> **Agent name** — pass as positional argument; otherwise the CLI reads `agent.yaml` in the current directory.

## Protocols

Hosted agents support three protocols declared at deployment time. They are distinct contracts — pick per use case (an agent may declare more than one and serve them from the same container):

| Protocol | Recommended Version | Route | Best For |
|----------|-------------------|-------|----------|
| `responses` | `1.0.0` | `.../agents/{agentName}/endpoint/protocols/openai/responses` | Conversational agents, OpenAI-compatible |
| `invocations` | `1.0.0` | `.../agents/{agentName}/endpoint/protocols/invocations` | Custom payloads, protocol bridges, webhook callers |
| `invocations_ws` | `1.0.0` | `wss://.../agents/endpoint/protocols/invocations_ws` | Duplex WebSocket — voice, WebRTC signaling, custom real-time streams. See the dedicated [invocations-ws skill](../invocations-ws/invocations-ws.md); `foundry agent invoke` does **not** speak WebSocket. |

Key difference: `responses` takes a natural language message and the platform manages history. `invocations` is **bytes in, bytes out** — the request body is forwarded as-is to the container and the raw response is returned. The developer defines the schema; the platform is pure pass-through. See [Invocations Protocol Guide](references/invocations-protocol.md) for I/O details, schema discovery, and examples.

> ⚠️ **Critical for invocations:** the message you pass (or `-f <file>` body) is forwarded as the raw HTTP request body. The agent developer defines what the container accepts. **Do not guess** — fetch the agent's OpenAPI spec or inspect its source code first (see Step 3 below).

## Workflow

### Step 1: Decide Local vs Remote

- **Right after create or local fix** → use `--local`. The local entrypoint must already be running on `:8088` (see the [create sub-skill](../create/create-hosted.md#step-4-verify-startup) for how to start it).
- **Smoke-testing a freshly deployed agent or any later remote call** → use the default (remote) mode. The CLI uses the persisted default project endpoint and reads the agent name from `agent.yaml` unless you pass them explicitly.
- **One-off invoke with no project setup** → use `--agent-endpoint <url>` (the URL `foundry agent` printed after deploy identifies project + agent + protocol directly).

The CLI creates and reuses sessions automatically for hosted agents — you do not need a pre-step to create one. For prompt agents, sessions are not used (the CLI handles the difference).

### Step 2: Invoke the Agent

```bash
# Remote, default project endpoint + agent.yaml name
foundry agent invoke "Hello!"

# Remote, explicit agent name
foundry agent invoke my-agent "Hello!"

# Remote, ephemeral (paste the URL printed at deploy time)
foundry agent invoke --agent-endpoint \
  "https://acct.services.ai.azure.com/api/projects/proj/agents/my-agent/endpoint/protocols/openai/responses" \
  "Hello!"

# Local smoke test (agent already running on :8088)
foundry agent invoke --local "Hello!"

# Force invocations protocol with a structured body
foundry agent invoke --protocol invocations -f request.json
```

Remote invocations stream by default when the server supports SSE (`responses` always; `invocations` when the server emits `text/event-stream`).

### Step 3: Discover the Schema (Invocations Only)

`invocations` is developer-defined. Before sending a body, confirm the expected schema:

1. Fetch the OpenAPI spec (if the developer registered one):
   ```bash
   curl "$(foundry agent project show)/agents/<agentName>/endpoint/protocols/invocations/docs/openapi.json"
   ```
2. Inspect the agent's route-handler code or `README.md` for the expected payload shape.
3. If still unknown, ask the user for the agent's API contract before invoking.

See [Invocations Protocol Guide](references/invocations-protocol.md) for full details and examples.

### Step 4: Multi-Turn Conversations

The CLI persists per-agent session and conversation IDs automatically; consecutive invokes against the same agent continue the same thread.

- **Responses protocol** — conversation reused automatically. Use `--new-conversation` to start fresh or `--conversation-id <id>` to pin one.
- **Invocations protocol** — session reused automatically. Use `--new-session` to start fresh or `--session-id <id>` to pin one. Conversation IDs are not meaningful for `invocations`.

### Step 5: File Operations (Hosted Agents)

Upload/download files to pass data to and retrieve results from agents. All file operations require an active session. The `foundry` CLI does not currently expose file-operation verbs — use the Azure MCP tools described in [File Operations](references/file-operations.md). Run `foundry agent invoke` at least once first so the session sandbox exists.

### Step 6: Clean Up

Sessions expire per platform policies; the CLI does not currently expose a `sessions delete` verb. Avoid creating large numbers of pinned `--session-id` values during testing.

## Agent Type Differences

| Behavior | Prompt Agent | Hosted Agent |
|----------|--------------|--------------|
| Readiness | Immediate | After deployment, version must be `active` |
| Session | Not applicable | Auto-created by `foundry agent invoke` on first call |
| Multi-turn | Auto via `--conversation-id` reuse | Auto via `--conversation-id` (responses) or `--session-id` (invocations) reuse |
| File operations | ❌ | ✅ via Azure MCP session-file tools |
| Protocol | `responses` only | `responses`, `invocations`, or `invocations_ws` |

## Below the CLI (Azure MCP Fallback)

Use these when the `foundry` CLI is missing a capability:

| Capability | Tool |
|------------|------|
| Determine agent kind / version status | `agent_get` |
| Explicit session lifecycle (create / list / get / delete) | `session_create`, `session_list`, `session_get`, `session_delete` |
| Session file operations | `session_file_upload`, `session_file_download`, `session_file_list`, `session_file_delete`, `session_file_stat`, `session_file_mkdir` |
| Stream session logs from invoke context | `session_logstream` (or use the [troubleshoot skill](../troubleshoot/troubleshoot.md) which wraps `foundry agent monitor`) |

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `agent '<name>' not found` | Wrong name, wrong project endpoint, or agent not deployed | Verify with the user; pass `--project-endpoint <url>` to retarget. |
| Hosted agent version not yet active | Provisioning still in progress or failed | Wait, then retry. If it stays inactive, follow the [troubleshoot skill](../troubleshoot/troubleshoot.md). |
| `424 FailedDependency` or `session_not_ready` | Session sandbox is warming up | Wait 15-30 seconds and retry. Use `foundry agent monitor` (troubleshoot skill) to confirm the sandbox came up. |
| Invocation returned an error body | Model error, timeout, or invalid input | Check `foundry agent monitor` logs, verify the model deployment, validate the request shape (invocations). |
| Invocations schema mismatch | Request body does not match what the agent expects | Inspect the agent's route handler or OpenAPI spec; do not guess. |
| File operation failed | Session not active or invalid path | Run a `foundry agent invoke` first to warm the sandbox; then retry the file operation via MCP. |
| Permission error | Missing RBAC | Follow the [troubleshoot skill](../troubleshoot/troubleshoot.md). |
| Rate limit exceeded | Too many requests | Back off and retry. |

## Additional Resources

- [Session Management](references/session-management.md) (MCP-level details; the CLI manages sessions for you)
- [File Operations](references/file-operations.md)
- [Invocations Protocol Guide](references/invocations-protocol.md)
- [Foundry Hosted Agents](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Foundry Samples](https://github.com/azure-ai-foundry/foundry-samples)
