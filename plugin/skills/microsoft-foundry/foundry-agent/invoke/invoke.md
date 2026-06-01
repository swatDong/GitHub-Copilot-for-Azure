# Invoke Foundry Agent

Invoke deployed agents on Microsoft Foundry (or a locally running agent during development) using `azd ai agent invoke`. Session state is auto-managed per agent — no manual `session_create`/`session_delete` plumbing required.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary tool | `azd ai agent` (Foundry extension v0.1.36-preview or later) |
| Key verbs | `invoke`, `sessions`, `files`, `show` |
| Local vs remote | `--local` to hit a `azd ai agent run` instance; default targets Foundry |
| Protocols | `responses` (default), `invocations` (raw bytes in/out) |
| `invocations_ws` | Not supported by `agent invoke` — see [invocations-ws skill](../invocations-ws/invocations-ws.md) |

## When to Use This Skill

- Send a message to a deployed agent (single or multi-turn)
- Test an agent locally during development
- Manage sessions or files for hosted agents (when you need explicit control)
- Smoke test an agent after deployment

## Workflow

### Step 1: Resolve Project Context

Use the [Common Project Context Resolution](../../SKILL.md#agent-common-project-context-resolution) flow only for missing values. `azd ai agent invoke` auto-resolves agent name, endpoint, and version from `azure.yaml` + active azd environment. Pass `--agent-name` only when the project has multiple `azure.ai.agent` services.

### Step 2: Verify Readiness (Optional)

Use `azd ai agent show` if you need to confirm the agent exists and (for hosted) its version is `active`:

```bash
azd ai agent show              # default service
azd ai agent show --output json
```

> Skip this step for routine invocations — `azd ai agent invoke` returns a clear error if the agent or version is not ready.

### Step 3: Invoke the Agent

**Default (responses protocol, multi-turn auto-managed):**

```bash
azd ai agent invoke "Hello, who are you?"
azd ai agent invoke my-agent "What can you do?"   # when multiple services
```

Consecutive `invoke` calls reuse the same session and conversation — no manual `conversationId` plumbing.

**Invocations protocol (raw bytes in/out):**

```bash
azd ai agent invoke --protocol invocations -f request.json
```

Use `-f`/`--input-file` for structured payloads. The body is forwarded as-is to the container; the agent developer defines the schema. See [Invocations Protocol Guide](references/invocations-protocol.md) for schema discovery (OpenAPI spec at `<endpoint>/protocols/invocations/docs/openapi.json` or the agent's source).

**Local agent (during development):**

```bash
azd ai agent invoke --local "test message"     # hits localhost:8088
azd ai agent invoke --local --port 9090 "..."  # custom port
```

The local agent must be running via `azd ai agent run` first.

**Specific version:**

```bash
azd ai agent invoke --version 3 "Hello"   # creates/reuses a session backed by v3
```

**Reset state:**

```bash
azd ai agent invoke --new-session "Fresh start"        # discard saved session
azd ai agent invoke --new-conversation "..."           # keep session, new conversation
azd ai agent invoke --session-id <id> "..."            # explicit session
azd ai agent invoke --conversation-id <id> "..."       # explicit conversation
```

**From any directory (CI, no azd project):**

```bash
azd ai agent invoke \
  --agent-endpoint "https://<acct>.services.ai.azure.com/api/projects/<proj>/agents/<name>/endpoint/protocols/openai/responses?api-version=v1" \
  "Hello"
```

Protocol is derived from the URL path.

**Raw response (debugging headers):**

```bash
azd ai agent invoke --output raw "Hello"
```

Dumps status line, headers, and body verbatim. Useful for inspecting the agent-version response header or debugging server behavior.

**Header-based isolation:**

```bash
azd ai agent invoke --user-isolation-key <key> --chat-isolation-key <key> "..."
```

Pass both keys on every invocation when the agent is configured for header-based isolation.

### Step 4: Session Management (Optional Explicit Control)

`azd ai agent invoke` auto-creates and reuses sessions per agent. Use the `sessions` subcommands only when you need explicit control:

```bash
azd ai agent sessions create                       # auto-detect agent, latest version
azd ai agent sessions create my-agent 3            # specific agent + version
azd ai agent sessions create --session-id my-id    # caller-provided ID
azd ai agent sessions list
azd ai agent sessions show <id>
azd ai agent sessions delete <id>                  # release compute
```

Session IDs must match `^[A-Za-z0-9_-]{8,128}$`. For full session semantics, see [Session Management](references/session-management.md).

### Step 5: File Operations (Hosted Agents)

Use `azd ai agent files` to read/write the session-scoped filesystem (e.g., to seed data or retrieve agent outputs):

```bash
azd ai agent files upload   <local-path> <remote-path>
azd ai agent files download <remote-path> <local-path>
azd ai agent files list     [remote-dir]
azd ai agent files stat     <remote-path>
azd ai agent files mkdir    <remote-path>
azd ai agent files delete   <remote-path>
```

Session is auto-resolved from the last invocation; override with `--session-id`. See [File Operations](references/file-operations.md) for path semantics and limits.

### Step 6: Clean Up (Optional)

Sessions auto-expire per platform policy. Call `azd ai agent sessions delete <id>` proactively to release compute sooner in CI or batch scenarios.

## Agent Type Differences

| Behavior | Prompt | Hosted |
|----------|--------|--------|
| Readiness | Immediate after deploy | Hosted version must be `active` |
| Session | N/A | Auto-managed; explicit via `sessions create` |
| Multi-turn | `conversationId` (auto) | `conversationId` (responses) or session state (invocations) |
| File operations | ❌ | ✅ via `azd ai agent files` |
| Protocol | `responses` only | `responses`, `invocations`, or `invocations_ws` |

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `agent not found` | Wrong env, service, or name | Switch with `-e <env>`, pass `--agent-name`, or verify with `azd ai agent show` |
| Hosted version not active | Still provisioning or failed | Run [troubleshoot skill](../troubleshoot/troubleshoot.md) → `azd ai agent doctor` |
| `424 FailedDependency` / `session_not_ready` | Sandbox warming up | Wait 15-30s; retry with same session. Stream logs with `azd ai agent monitor --follow` |
| `401`/`403` on invoke | Missing `Azure AI User` on Cognitive Services account scope | Run `azd ai agent doctor`; grant via [rbac skill](../../rbac/rbac.md) |
| Invocations schema mismatch | Body doesn't match agent's expected shape | Fetch OpenAPI at `<endpoint>/protocols/invocations/docs/openapi.json`; do not guess |
| Local invoke connection refused | `azd ai agent run` not started | Start it in another terminal first |
| Rate limited | Too many requests | Implement backoff |

## Fallbacks (when `azd ai agent` is unavailable)

If the extension is not installed, fall back to direct HTTP:

```bash
TOKEN=$(az account get-access-token --resource "https://ai.azure.com" -o tsv --query accessToken)
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"input":"Hello","model":"<model-deployment>"}' \
  "<projectEndpoint>/agents/<name>/endpoint/protocols/openai/responses?api-version=v1"
```

For hosted agents, create a session first via `POST <projectEndpoint>/agents/<name>/sessions?api-version=2025-11-15-preview` (header `Foundry-Features: HostedAgents=V1Preview`), then include `x-session-id` on subsequent requests.

## Additional Resources

- [Session Management](references/session-management.md)
- [File Operations](references/file-operations.md)
- [Invocations Protocol Guide](references/invocations-protocol.md)
- [Foundry Hosted Agents](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples)
