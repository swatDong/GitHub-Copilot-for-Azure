# Foundry Agent Troubleshoot

Diagnose hosted and prompt agent issues using `azd ai agent` commands, with fall-throughs to `az` CLI and Application Insights for telemetry.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary tool | `azd ai agent` (Foundry extension v0.1.36-preview or later) |
| Key verbs | `doctor`, `show`, `monitor`, `sessions` |
| Fallback CLIs | `az monitor app-insights query`, `az cognitiveservices account connection list` |
| Related skills | `trace` (deep telemetry analysis) |

## When to Use This Skill

- Agent is not responding or returning errors
- Hosted agent version is not becoming active
- Need to view hosted-agent session logs
- Diagnose latency or timeout issues
- Investigate agent runtime failures or RBAC drift

## Workflow

### Step 1: Resolve Project Context

Use the [Common Project Context Resolution](../../SKILL.md#agent-common-project-context-resolution) flow only for values not already known. The `azd ai agent *` commands auto-resolve agent name, version, and project endpoint from `azure.yaml` plus the active azd environment — pass `--agent-name` only when the project has multiple `azure.ai.agent` services.

### Step 2: Run the Diagnostic Check Suite

Run `azd ai agent doctor` first. It executes a sequence of local and remote checks (azd env, agent.yaml, project endpoint, RBAC, deployed agent status) and prints a structured report.

```bash
azd ai agent doctor              # full suite
azd ai agent doctor --local-only # offline / fast triage
azd ai agent doctor --unredacted # show raw principal IDs and scope ARNs
```

Exit codes:
- `0` — at least one check passed, none failed
- `1` — any check failed (read the report and fix the first failure)
- `2` — all checks were skipped (preconditions unmet)

If `doctor` reports a missing RBAC role assignment, follow the [rbac skill](../../rbac/rbac.md) to grant it (typically `Foundry User` on the **Foundry project scope** for the per-agent managed identity; the Foundry project managed identity needs `AcrPull` on the ACR).

### Step 3: Inspect Agent Status

If `doctor` passed but the agent still misbehaves, use `azd ai agent show` to inspect deployment state:

```bash
azd ai agent show                 # default agent service
azd ai agent show my-agent        # specific service
azd ai agent show --output json   # machine-readable
```

Look for `kind` (hosted vs prompt) and, for hosted agents, the version status. A version that is not `active` is either still provisioning or failed; check `doctor` output for the root cause.

### Step 4: Stream Hosted Agent Logs

For hosted agents, stream container stdout/stderr or system events with `azd ai agent monitor`. The session ID auto-resolves from the last invocation; no manual SSE/curl/token plumbing is needed.

```bash
azd ai agent monitor                              # last 50 lines, last-used session
azd ai agent monitor --follow                     # stream in real time
azd ai agent monitor --session-id <id> --follow   # specific session
azd ai agent monitor --type system                # container lifecycle events
azd ai agent monitor --tail 300                   # bigger window (max 300)
```

> ℹ️ **No session yet?** A hosted-agent session sandbox is created on first invocation. If `monitor` reports no session, run `azd ai agent invoke "test"` once to create one, then retry.

For agents configured with header-based isolation, pass `--user-isolation-key` and `--chat-isolation-key`.

### Step 5: Inspect Sessions

When a specific session is misbehaving:

```bash
azd ai agent sessions list                # all sessions for the agent
azd ai agent sessions show <session-id>   # session metadata & status
azd ai agent sessions delete <session-id> # release compute and force a clean restart on next invoke
```

### Step 6: Query Application Insights Telemetry

`azd` does not yet expose a telemetry query verb. For deeper trace / exception / latency analysis:

1. **Find the App Insights connection** linked to the project:

   ```bash
   az cognitiveservices account connection list \
     --name <account> --resource-group <rg> --query "[?category=='AppInsights']"
   ```

   (Reference: [az cognitiveservices account connection](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account/connection?view=azure-cli-latest).)

2. **Run a KQL query** against the App Insights resource:

   ```bash
   az monitor app-insights query \
     --app <appinsights-name> --resource-group <rg> \
     --analytics-query "traces | where message contains '<agent-name>' | take 50"
   ```

   Or hand off to the `azure-kusto` skill for ad-hoc query authoring.

> 💡 If `APPLICATIONINSIGHTS_CONNECTION_STRING` is set in `azd env get-values`, use that as the source of truth for the App Insights resource ID.

### Step 7: Summarize Findings

Present a short summary covering:
- **Agent type and status** — hosted/prompt; hosted version status when relevant
- **Doctor findings** — first failed check (if any) and the recommended fix
- **Log errors** — key errors from `azd ai agent monitor`
- **Telemetry insights** — exceptions, failed requests, latency outliers
- **Recommended actions** — specific next steps (redeploy, RBAC fix, code fix)

## Error Handling

| Symptom | Likely Cause | Resolution |
|---------|--------------|------------|
| `azd ai agent show` returns "agent not found" | Wrong service, wrong env, or agent never deployed | Switch env with `-e`, or run `azd deploy` |
| Hosted agent version not active | Still provisioning, ACR image bad, or per-agent MI missing pull permissions | Run `azd ai agent doctor`; check ACR build logs |
| `azd ai agent monitor` reports no session | Sandbox not yet created | Run `azd ai agent invoke "test"` once, then retry monitor |
| Invocation 401/403 | Per-agent MI missing `Foundry User` on the Foundry project scope | Run `azd ai agent doctor` to confirm; grant via rbac skill |
| Invocation 424 / `session_not_ready` | Session still warming up | Wait 15-30s and retry; check `monitor --follow` |
| No App Insights connection found | Telemetry not configured | Add an App Insights connection via `azd ai connection create` or Foundry portal |
| KQL query returns nothing | Agent not instrumented, or data still ingesting | Confirm SDK setup; ingestion can lag 1-5 minutes |

## Fallbacks (when `azd ai agent` is unavailable)

If the `azd ai agent` extension is not installed or a verb returns "unknown command," fall back to:

- **Agent status / list** — `az rest --method GET --url "<projectEndpoint>/agents?api-version=2025-11-15-preview" --resource "https://ai.azure.com"`
- **Session logs** — `curl -H "Authorization: Bearer $(az account get-access-token --resource https://ai.azure.com -o tsv --query accessToken)" --max-time 15 -H "Accept: text/event-stream" "<projectEndpoint>/agents/<name>/sessions/<id>:logstream?api-version=2025-11-15-preview"` (SSE; each frame is `event: log\ndata: {...}\n\n`).

These match the legacy MCP-equivalent paths and remain valid for break-glass scenarios.

## Additional Resources

- [Foundry Hosted Agents](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Account Connection CLI Reference](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account/connection?view=azure-cli-latest)
- [KQL Quick Reference](https://learn.microsoft.com/azure/data-explorer/kusto/query/kql-quick-reference)
- [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples)
