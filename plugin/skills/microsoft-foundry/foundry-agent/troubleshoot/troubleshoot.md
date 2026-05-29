# Foundry Agent Troubleshoot

Troubleshoot and debug Foundry agents by streaming hosted-agent session logs through the `foundry` CLI, and (advanced) by discovering observability connections and querying Application Insights telemetry.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary command | `foundry agent monitor` (session logs, console + system channels) |
| Related skills | [invoke](../invoke/invoke.md), [trace](../trace/trace.md) (telemetry analysis) |
| Advanced (beyond CLI scope today) | App Insights KQL via Azure MCP `monitor_resource_log_query` |
| CLI references | `az cognitiveservices account connection` (advanced step), `az login` (auth) |

## When to Use This Skill

- Agent is not responding or returning errors
- Hosted agent version is not becoming active
- Need to view hosted-agent session logs
- Diagnose latency or timeout issues
- (Advanced) Query Application Insights for agent traces and exceptions
- Investigate agent runtime failures

## CLI Commands

| Command | Purpose |
|---------|---------|
| `foundry agent monitor [<name>]` | Snapshot the last 50 console events for a deployed agent session. Uses the persisted default project endpoint and `agent.yaml#name` unless overridden. |
| `foundry agent monitor --follow` | Stream until Ctrl+C. |
| `foundry agent monitor --type system` | Switch from `console` (default) to the `system` log channel. |
| `foundry agent monitor --tail <int>` | Last N events (1…300, default 50). |
| `foundry agent monitor --session-id <id>` | Target a specific session (otherwise the CLI reuses the session cached by the last `foundry agent invoke`). |
| `foundry agent monitor --raw` | Forward the raw SSE stream (pipe to `jq`/`grep`/`tee`). |
| `foundry agent monitor --utc` | UTC timestamps instead of local. |
| `foundry agent monitor --project-endpoint <url>` / `--agent-endpoint <url>` | Override the persisted defaults / target a specific deployed agent URL. |

## Workflow

### Step 1: Collect Agent Information

Identify the agent and project endpoint:
- **Project endpoint** — pass `--project-endpoint <url>` to override; otherwise the CLI uses the default set via `foundry project set <url>` (inspect with `foundry project show`). If neither is available, ask the user.
- **Agent name** — pass as positional argument; otherwise the CLI reads `agent.yaml` in the current directory.

### Step 2: Determine Agent Type (Best-Effort)

There is no CLI verb that returns the agent kind today. Proceed straight to Step 3; `foundry agent monitor` will succeed for hosted agents and emit a clear error for prompt agents (which do not have session logs). If you get a "not a hosted agent" / "no sessions" style error, skip to Step 4 (Advanced).

### Step 3: Stream Hosted-Agent Session Logs

> ℹ️ **`invocations_ws` agents:** the session referenced here is the client-supplied `agent_session_id` that the WebSocket client put on the upgrade URL — not a value issued by a separate session-create call. If the user has the WS client logs, pull the `agent_session_id` from there and pass it as `--session-id`. See the [invocations-ws skill](../invocations-ws/invocations-ws.md) for the WS URL contract.

Run `foundry agent monitor`. Default behavior: snapshot the last 50 console events for the cached session.

```bash
# Snapshot (last 50 console events, default project endpoint + agent.yaml name)
foundry agent monitor

# Follow until Ctrl+C, override the persisted default project endpoint
foundry agent monitor my-agent --follow \
  --project-endpoint https://acct.services.ai.azure.com/api/projects/proj

# System log channel, last 200 entries, UTC timestamps
foundry agent monitor my-agent --type system --tail 200 --utc

# Specific session, raw SSE for piping into jq/grep
foundry agent monitor --session-id <session-id> --raw

# One-off run against a deployed agent URL (no project endpoint required)
foundry agent monitor --agent-endpoint \
  "https://acct.services.ai.azure.com/api/projects/proj/agents/my-agent/endpoint/protocols/invocations"
```

**Interpreting the output:**

- Default formatting: one line per event, e.g. `14:23:01  INFO  agent.run  request started (trace=0123…)`.
- The console channel mixes stdout, stderr, and status messages from the container.
- Error events / stack traces / failed dependency hints surface inline — highlight them to the user.

If the CLI reports that no session is available, run a `foundry agent invoke "<probe>"` (see the [invoke skill](../invoke/invoke.md)) first to warm a session sandbox, then retry `foundry agent monitor`.

### Step 4: Discover Observability Connections (Advanced — Beyond CLI Scope Today)

The `foundry` CLI does not yet expose telemetry queries. The steps below remain `az` + Azure MCP-driven; only use them when the user explicitly wants to dig into Application Insights.

List the project connections to find Application Insights or Azure Monitor resources using the Azure CLI command documented at:
[az cognitiveservices account connection](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account/connection?view=azure-cli-latest)

Refer to the documentation above for the exact command syntax and parameters. Look for connections of type `ApplicationInsights` or `AzureMonitor` in the output.

If no observability connection is found, inform the user and suggest setting up Application Insights for the project. Ask if they want to proceed without telemetry data.

### Step 5: Query Application Insights Telemetry (Advanced — Beyond CLI Scope Today)

Use **`monitor_resource_log_query`** (Azure MCP tool) to run KQL queries against the Application Insights resource discovered in Step 4. This is preferred over delegating to the `azure-kusto` skill. Pass the App Insights resource ID and the KQL query directly.

> ⚠️ **Always pass `subscription` explicitly** to Azure MCP tools like `monitor_resource_log_query` — they don't extract it from resource IDs.

Use `* contains "<response_id>"` or `* contains "<agent_name>"` filters to narrow down results to the specific agent instance.

### Step 6: Summarize Findings

Present a summary to the user including:
- **Agent type and status** — hosted or prompt; hosted agent version status when relevant
- **Log errors** — key errors from hosted-agent session logs
- **Telemetry insights** — exceptions, failed requests, latency trends
- **Recommended actions** — specific steps to resolve identified issues

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `agent '<name>' not found` | Invalid agent name or project endpoint | Verify the name with the user; pass `--project-endpoint <url>` to retarget. |
| `cached session pinned to version N` warning, but agent behavior matches an older version | Cached `session_id` pins the runtime to the version it was created against — a plain `foundry agent invoke` after a redeploy keeps hitting the old version | Re-run with `foundry agent invoke <name> "..." --new-session --new-conversation` to move onto the latest deployed version. `--new-conversation` alone is **not** enough. |
| Hosted agent not active | Hosted agent is still provisioning or failed | Check ACR image push succeeded and agent identity permissions are assigned; wait and re-check by running `foundry agent monitor` again. |
| `foundry agent monitor` reports "no session available" | No session has been invoked yet (sandbox not created) | Run `foundry agent invoke "<probe>"` first to warm a sandbox, then retry monitor. |
| `foundry agent monitor` errors for a prompt agent | Prompt agents do not have session logs | Skip to Step 4 (advanced telemetry) or rely on the model deployment's metrics. |
| SSE / `--raw` shows server-side error events | Container error inside the session sandbox | Inspect the message body; fix the agent code and redeploy. |
| Auth failure (`DefaultAzureCredential`) | Not signed in | Run `az login` and retry. |
| Kusto query failed (Step 5) | Invalid cluster/database or insufficient permissions | Verify Application Insights resource details and reader permissions. |
| No telemetry data (Step 5) | Agent not instrumented or too recent | Check if Application Insights SDK is configured; data may take a few minutes to appear. |

## Additional Resources

- [Foundry Hosted Agents](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Account Connection CLI Reference](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account/connection?view=azure-cli-latest)
- [KQL Quick Reference](https://learn.microsoft.com/azure/data-explorer/kusto/query/kql-quick-reference)
- [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples)
