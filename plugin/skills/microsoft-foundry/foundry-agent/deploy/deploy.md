# Foundry Agent Deploy

Deploy agents to Microsoft Foundry using `azd deploy`. Covers hosted (container or direct-code) and prompt agents, smoke testing, and the mandatory post-deploy evaluation suite generation.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary tool | `azd` + `azd ai agent` (Foundry extension v0.1.36-preview or later) |
| Key verbs | `azd deploy`, `azd ai agent show`, `azd ai agent doctor`, `azd ai agent invoke`, `azd ai agent eval init`, `azd ai agent eval run` |
| Deploy modes | `container` (Docker image) or `code` (ZIP upload) — declared at `azd ai agent init` time |
| Fallback CLIs | `az acr build`, `az role assignment create`, `az rest` |
| Container protocols | `responses`, `invocations`, `invocations_ws`, `a2a`, `mcp` |
| Supported languages | .NET, Node.js, Python, Go, Java |

## When to Use This Skill

USE FOR: deploy agent to foundry, push agent to foundry, ship my agent, build and deploy container agent, deploy hosted agent, direct code deployment, upload code deployment, create hosted agent, deploy prompt agent, redeploy agent, update agent deployment, clone agent, delete agent, azd deploy hosted agent, azd up for agent.

> ⚠️ **DO NOT manually run** `az acr build`, `docker build`, or write `agent_update`/REST upload calls **without reading this skill first.** `azd deploy` orchestrates: project scan → env var resolution → image build (or ZIP upload) → agent create/version-bump → RBAC verification. Skipping the post-deploy steps (smoke test + auto-gen eval suite) leaves the deployment "incomplete" by this skill's definition.

## Workflow: Hosted Agent Deployment

> ⚠️ **Warning: hosted agent deployment is not done at "azd deploy exit 0."**
>
> `azd deploy` covers Steps 1-3. You MUST still execute Step 4 (smoke test), Step 5 (RBAC verification), and Step 6 (auto-generate evaluation suite) before reporting success. A successful invocation in Step 4 is not a stopping condition either.

### Definition of Done — Hosted Agent Deployment

A hosted-agent deployment is complete only when **every** box below is checked. Do **not** produce a final "deployment successful" summary, table, or Playground link until all items are done.

- [ ] Step 1 — Project context resolved (azd env + agent service in `azure.yaml`)
- [ ] Step 2 — Environment variables confirmed with user
- [ ] Step 3 — `azd deploy` completed successfully
- [ ] Step 4 — `azd ai agent invoke` smoke test passed (via the invoke skill)
- [ ] Step 5 — `azd ai agent doctor` reports no failed checks (RBAC verified)
- [ ] Step 6 — `azd ai agent eval init` job reached `succeeded` (or documented fallback) and `eval.yaml` is written
- [ ] Deployment context is resolvable from azd; `.foundry/agent-metadata*.yaml` contains only non-derivable overlay/cache state for the selected environment
- [ ] User prompted to run an evaluation

### Step 1: Resolve Project Context

Use the [Common Project Context Resolution](../../SKILL.md#agent-common-project-context-resolution) flow only for values not already known. The agent must already be initialized via `azd ai agent init` (see [create-hosted skill](../create/create-hosted.md)), which produces:

- `azure.yaml` with a service of `host: azure.ai.agent`
- `agent.yaml` defining the agent (name, protocols, env-var declarations, deploy mode)
- `Dockerfile` (for `container` mode) or `.agentignore` (for `code` mode)

If `azure.yaml` is missing or has no `azure.ai.agent` service, stop and run the create skill first.

### Step 2: Collect and Confirm Environment Variables

> ⚠️ Environment variables are baked into the deployed agent payload and are difficult to change after deployment.

Read the agent service's declared `environment_variables` from `agent.yaml`. Resolve values from `azd env get-values` (preferred source) and merge any user-provided overrides. Present all variables to the user for confirmation with name, value, and source (`azd`, `agent.yaml default`, or `user`). Mask sensitive values.

Loop until the user confirms or cancels:
- `yes` → proceed to Step 3
- `VAR_NAME=new_value` → update via `azd env set VAR_NAME new_value`, show updated table, ask again
- `cancel` → abort

> ℹ️ Reserved `FOUNDRY_*`, `AGENT_*`, `PORT`, `HOME`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, and `OTEL_EXPORTER_OTLP_ENDPOINT` are platform-injected — do not set or confirm them.

### Step 3: Deploy with azd

`azd deploy` handles project type detection, build, push (for container), or ZIP packaging (for code), agent definition assembly from `agent.yaml`, and agent creation/version-bump in one verb.

```bash
azd deploy                       # all services in azure.yaml
azd deploy <service-name>        # specific azure.ai.agent service
azd up                           # first deploy: provision + deploy in one step
```

Behind the scenes:
- **Container mode** — uses ACR Tasks (`az acr build` equivalent) with `--platform linux/amd64`. No local Docker required.
- **Code mode** — packages source per `.agentignore` and uploads to Foundry direct-code deploy.
- Image tag is timestamped automatically; image is pushed to the ACR resolved from `AZURE_CONTAINER_REGISTRY_*` env values.
- Calls the equivalent of `agent_update` with the assembled definition; reusing the agent name creates a new version.

On success, `azd ai agent show` will display the new version.

> 💡 **Direct-code deployment** is selected at `azd ai agent init` time via `--deploy-mode code`. If the user explicitly asks now to switch to direct code, re-init with `--deploy-mode code --runtime <runtime> --entry-point <file> --force`, then re-run `azd deploy`. The legacy manual direct-code path is documented in [direct-code-deployment.md](references/direct-code-deployment.md) for break-glass scenarios.

### Step 4: Smoke Test the Deployed Agent

Read and follow the [invoke skill](../invoke/invoke.md). Minimum smoke test:

```bash
azd ai agent invoke "Hello, can you respond?"
```

For invocations-protocol agents, send a known-good payload:

```bash
azd ai agent invoke --protocol invocations -f smoke.json
```

For `invocations_ws`, the smoke test must use a WebSocket client; see the [invocations-ws skill](../invocations-ws/invocations-ws.md).

> ⚠️ **Not done yet.** A passing smoke test is the midpoint, not the finish line. Continue to Step 5.

### Step 5: Verify RBAC and Health

Run the diagnostic check suite:

```bash
azd ai agent doctor
```

`doctor` validates (among other things) that the per-agent identity has the required `Foundry User` role on the Foundry project, that the Foundry project managed identity has ACR pull permissions, and that the deployed agent version is `active`.

> ℹ️ **Role name history:** `Foundry User` is the current built-in role. Earlier documentation referred to it as `Azure AI User`; that name has been retired.

> ✅ **`azd deploy` auto-grants the required roles.** When the agent is deployed against an azd-provisioned ACR (i.e., you ran `azd provision` first instead of pre-setting `AZURE_CONTAINER_REGISTRY_*` env vars), `azd deploy` assigns:
> - `Foundry User` → per-agent MI, scoped to `.../accounts/<account>/projects/<project>` (project scope, not CS account scope)
> - `AcrPull` → Foundry project MI, scoped to the ACR (registry scope)
> - `Container Registry Tasks Contributor` → the developer running `azd deploy`, scoped to the ACR (required for ACR Tasks `scheduleRun`)
>
> Manual assignment is only needed when reusing pre-existing infrastructure or recovering from a partial failure.

**If `doctor` reports a missing role assignment** and your account has RBAC permissions, grant it via [rbac skill](../../rbac/rbac.md) (or as a one-off):

```bash
# Per-agent MI missing Foundry User on the Foundry project
az role assignment create --assignee <per-agent-mi-principal-id> --role "Foundry User" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>"

# Foundry project MI missing ACR pull
az role assignment create --assignee <project-mi-principal-id> --role "AcrPull" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr>"

# Developer account missing ACR Tasks role (needed when azd deploy invokes `scheduleRun`)
az role assignment create --assignee <your-user-principal-id> --role "Container Registry Tasks Contributor" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr>"
```

> 💡 **Three distinct identities** are involved in a hosted agent:
> 1. **Per-agent managed identity** (one per agent, `principal_id` from `azd ai agent show`) — needs `Foundry User` on the **project scope** to invoke the project plane.
> 2. **Foundry project managed identity** (display name `<account>/projects/<project>`) — needs `AcrPull` on the ACR to pull container images.
> 3. **CS account system-assigned identity** — typically needs no role assignments for normal hosted-agent operation.

> ⚠️ **Known issue (June 2026, `azd ai agents` ≤ 0.1.36-preview):** when an existing ACR is supplied via the `AZURE_CONTAINER_REGISTRY_NAME`/`_ENDPOINT` env vars (instead of letting `azd provision` create one), `azd deploy` invokes ACR Tasks without credentials and fails with `when specifying push, at least one credential is required`. Workaround: let `azd provision` create the ACR, or fall back to manually building the image (`az acr build`) and calling `agent_update` directly.

If your account lacks RBAC permissions, stop here and tell the user the deployment cannot be treated as complete until someone with `User Access Administrator` (or equivalent) grants the missing role. Do not silently skip.

Re-run `azd ai agent doctor` until it passes, then `azd ai agent invoke "retry"` to confirm.

### Step 6: Auto-Generate Evaluation Suite (MANDATORY — RUNS AUTOMATICALLY)

> ⚠️ **Pre-summary gate.** If you are about to write a deployment summary, Playground link, or "deployment complete" message and Step 6 has not run, you are violating this skill. Run Step 6 first.
>
> This step **runs automatically** without waiting for the user to ask. The only user input required is the one-question prompt below.

**6a. Ask the user (one question, required).** Before generating, inspect the selected agent root for an existing `eval.yaml`, then ask which source to use:

> *"Your agent is deployed. I'll now auto-generate an evaluation suite. Which source should I use?*
> *(a) **Current agent code/definition** — synthetic Q&A from `agent.yaml` / instructions. Best when there's little or no trace history.*
> *(b) **Historical traces** — last 3 days. Best if the agent has recent invocations.*
> *(c) **Existing eval.yaml** — use the local dataset/evaluator already configured. Best when eval config already exists."*

**6b. Run `azd ai agent eval init`** with the chosen source. The command submits dataset and evaluator generation jobs, waits for completion, downloads review artifacts, and writes `eval.yaml` **inside the agent's sub-project folder** (typically `src/<service-name>/eval.yaml`, the same directory as `agent.yaml`).

> ℹ️ When run interactively without `--no-prompt`, `eval init` prompts for an `Eval suite name` (defaults to the agent name). In automation, pass `--name <suite>` or `--no-prompt` to avoid the prompt.

```bash
# (a) Current agent code/definition
azd ai agent eval init --eval-model gpt-4o --max-samples 50

# (a) with explicit generation instruction
azd ai agent eval init \
  --gen-instruction "This agent handles restaurant reservations." \
  --eval-model gpt-4o --max-samples 50

# (b) Historical traces (last 3 days)
azd ai agent eval init --trace-days 3 --eval-model gpt-4o --max-samples 50

# (c) Existing local dataset + evaluator
azd ai agent eval init \
  --dataset ./tests/golden.jsonl \
  --evaluator builtin.intent_resolution \
  --eval-model gpt-4o
```

Required/useful flags:
- `--eval-model` — model deployment used for evaluation and synthetic Q&A generation (must exist in the project; verify with `azd ai agent show` or the deploy-model skill)
- `--max-samples` — number of samples to generate (15-1000, default 15)
- `--name` — eval suite name (defaults derived from agent)
- `--no-wait` — submit jobs and return immediately; resume later
- `--reset-defaults` — overwrite an existing eval config
- `--out-file` — alternate path (default `eval.yaml`)

**6c. Verify completion.** After the command returns (or after polling completes when `--no-wait`), confirm:
- `eval.yaml` exists in the agent sub-project folder (e.g., `src/<service>/eval.yaml`)
- The dataset file referenced in `eval.yaml` exists locally
- The chosen evaluators are listed under `evaluators:`

**6d. Fallback** — if `eval init` fails (model unavailable, generation quota, etc.), follow the manual fallback in [observe skill → evaluation-suite-generation](../observe/references/evaluation-suite-generation.md): suggest evaluators from `evaluator_catalog_get`, generate a seed dataset per [eval-datasets skill](../eval-datasets/references/generate-seed-dataset.md), and register them. Persist with `generationSource: manual-fallback` in any `.foundry` metadata overlay.

**6e. Skip-only-on-explicit-request.** Skip only if the user explicitly says "skip eval suite generation." "The user didn't ask for it" is **not** a valid reason to skip.

### Step 7: Display Agent Information and Prompt for Evaluation

> ⚠️ **Gate:** Do not render the table or Playground link until the Definition of Done is fully satisfied (Steps 1-6 above).

Show the agent's details:

```bash
azd ai agent show --output json
```

Render a summary table (name, version, kind, status, protocols, image, endpoint). Below the table, display a Playground link:

```
[Open in Playground](https://ai.azure.com/nextgen/r/{encodedSubId},{resourceGroup},,{accountName},{projectName}/build/agents/{agentName}/build?version={agentVersion})
```

To compute `encodedSubId` (URL-safe base64 of the 16-byte GUID, no padding):

```bash
python -c "import base64,uuid;print(base64.urlsafe_b64encode(uuid.UUID('<SUBSCRIPTION_ID>').bytes).rstrip(b'=').decode())"
```

Then prompt the user:

> *"Your agent is deployed and `eval.yaml` is ready. Run `azd ai agent eval run` to score the agent and identify optimization opportunities. Want me to run it now?"*

- **Yes** → `azd ai agent eval run`, then hand off to the [observe skill](../observe/observe.md) for results analysis.
- **No** → stop. The user can return later via the observe skill.
- **Production trace analysis** → hand off to the [trace skill](../trace/trace.md).

## Workflow: Prompt Agent Deployment

### Definition of Done — Prompt Agent Deployment

- [ ] Step 1 — Project context resolved
- [ ] Step 2 — `agent.yaml` configured (model, instructions, etc.)
- [ ] Step 3 — `azd deploy` completed successfully
- [ ] Step 4 — `azd ai agent invoke` smoke test passed
- [ ] Step 5 — `azd ai agent eval init` reached `succeeded` (or documented fallback)
- [ ] User prompted to run an evaluation

### Step 1: Resolve Project Context

Same as hosted (Step 1 above). Agent service in `azure.yaml` must have `kind: prompt` in its `agent.yaml`.

### Step 2: Configure the Agent

`agent.yaml` for prompt agents needs:
- `kind: prompt`
- `model: <deployment-name>` (e.g., `gpt-4o`)
- `instructions: "<system prompt>"` (optional)
- `temperature`, `top_p`, `tools`, `rai_config` (optional)

Edit `agent.yaml` directly or re-init via `azd ai agent init --model <name>` to update model.

### Step 3: Deploy

```bash
azd deploy
```

No build is required for prompt agents.

### Step 4: Smoke Test

```bash
azd ai agent invoke "Hello"
```

### Step 5: Auto-Generate Evaluation Suite

Same procedure as hosted Step 6 above.

## Display Agent Information

See Step 7 of the hosted workflow.

## Document Deployment Context

After a successful deployment, treat azd as the source of truth for deployment context. `azd env get-values` already provides:

| Variable | Resolves To |
|----------|-------------|
| `AZURE_AI_PROJECT_ENDPOINT` | Project endpoint |
| `AGENT_<SERVICE>_NAME` / `_VERSION` | Agent identity |
| `AZURE_CONTAINER_REGISTRY_*` | ACR registry/endpoint |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Observability |
| `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_AI_ACCOUNT_NAME`, `AZURE_AI_PROJECT_NAME` | Resource lookup, Playground links |

Persist only **non-derivable overlay/cache state** to `<agent-root>/.foundry/agent-metadata*.yaml` for the selected environment:

| State | Persist? | Notes |
|-------|----------|-------|
| Project endpoint, agent name/version, ACR, observability | ❌ | azd is the source of truth |
| azd binding (`azd.environmentName`, `azd.service`) | ✅ | when useful for future resolution |
| Evaluation suites — remote ref + local cache paths + thresholds + tags | ✅ | persist under `evaluationSuites[]` |
| Last eval result summaries / comparison refs | ✅ | persist under `results/` |

If azd and metadata disagree for the same value, stop and ask which source is authoritative. Update only the selected environment block; never copy or merge environments across sibling files automatically.

## Agent Definition Schemas

### Prompt Agent

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `kind` | string | ✅ | Must be `"prompt"` |
| `model` | string | ✅ | Model deployment name (e.g., `gpt-4o`) |
| `instructions` | string | | System message |
| `temperature` | number | | 0-2 |
| `top_p` | number | | 0-1 |
| `tools` | array | | Tools the model may call |
| `tool_choice` | string/object | | Tool selection strategy |
| `rai_config` | object | | Responsible AI configuration |

### Hosted Agent

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `kind` | string | ✅ | Must be `"hosted"` |
| `image` | string | ✅ for container mode | Container image URL (azd fills in after build) |
| `cpu` | string | ✅ | e.g., `"0.5"`, `"1"`, `"2"` |
| `memory` | string | ✅ | e.g., `"1Gi"`, `"2Gi"` |
| `container_protocol_versions` | array | ✅ | Protocol + version pairs (must match adapter version) |
| `environment_variables` | object | | Key-value pairs |
| `tools` | array | | Tool configurations (typically a Toolbox ref) |
| `rai_config` | object | | Responsible AI configuration |

### Container Protocols

| Protocol | Description |
|----------|-------------|
| `a2a` | Agent-to-Agent protocol |
| `responses` | OpenAI Responses API |
| `invocations` | Custom request bodies + SSE |
| `invocations_ws` | Duplex WebSocket (voice, signaling) — see [invocations-ws skill](../invocations-ws/invocations-ws.md) |
| `mcp` | Model Context Protocol |

## Agent Management Operations

### Clone an Agent

`azd ai agent` does not currently expose a `clone` verb. Use the fallback REST/MCP path: call `agent_update` with `isCloneRequest: true`, `cloneTargetAgentName`, and (for prompt agents) optional `modelName`.

### Delete an Agent

`azd ai agent` does not currently expose a `delete` verb. Use `az rest --method DELETE --url "<projectEndpoint>/agents/<name>?api-version=2025-11-15-preview" --resource "https://ai.azure.com"` — automatically cleans up hosted-agent runtime resources.

### Update Endpoint / Card Without New Version

```bash
azd ai agent endpoint update            # patches agent_endpoint + agent_card from agent.yaml
azd ai agent endpoint update my-agent
```

This does **not** create a new agent version.

### List Agents

```bash
azd ai agent show --output json   # current service
az rest --method GET --url "<projectEndpoint>/agents?api-version=2025-11-15-preview" --resource "https://ai.azure.com"  # all
```

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `azd deploy` cannot find service | `azure.yaml` missing or no `azure.ai.agent` service | Run `azd ai agent init` first |
| ACR build failed | Dockerfile errors or insufficient permissions | Inspect build logs in `azd deploy` output; fix Dockerfile or run `azd ai agent doctor` |
| `azd ai agent doctor` reports missing role | RBAC not provisioned | Grant `Azure AI User` (CS account scope) and `Container Registry Repository Reader` (ACR) per Step 5 |
| Hosted agent version not active | Image bad, env vars wrong, or sandbox failed | `azd ai agent show` + `azd ai agent monitor --follow`; consult troubleshoot skill |
| Smoke test 401/403 | Missing RBAC | See Step 5 |
| Smoke test 424 / `session_not_ready` | Sandbox warming up | Wait 15-30s and retry |
| `eval init` fails with "no chat-capable deployment" | `--eval-model` not deployed in the project | Deploy a chat-capable model first via deploy-model skill, then retry |
| `eval init` job stuck | Generation quota or service issue | Use `--no-wait` and check Foundry portal; fall back to manual flow (Step 6d) |
| Direct-code ZIP too large | Source tree includes vendored deps or build artifacts | Add patterns to `.agentignore`; re-deploy |

## Non-Interactive / YOLO Mode

When running non-interactive:

- **Env vars** — Pre-populated from `azd env get-values` and `agent.yaml` defaults; no confirmation prompt.
- **Agent name** — Must be set via `agent.yaml` (written by `azd ai agent init`); if missing, fails fast.
- **Smoke test** — `azd ai agent invoke --no-prompt "smoke test"` continues automatically on success.
- **Eval source** — Defaults to `(a) current agent code/definition`. Override with explicit `--trace-days N` or `--dataset`/`--evaluator`.
- **`--no-prompt` flag** — Pass it to every `azd ai agent` command so unresolved values fail rather than prompt.

> ⚠️ Ensure all required values (project endpoint, agent name, model deployment, env vars) are resolvable from `azure.yaml`, `agent.yaml`, and `azd env get-values` before starting. Missing values cause hard failures instead of prompts.

## Fallbacks (when `azd ai agent` is unavailable)

If the extension is not installed:

- **Build & push** — `az acr build --registry <acr> --image <repo>:<tag> --platform linux/amd64 --source-acr-auth-id "[caller]" --file Dockerfile .`
- **Local build alternative** — `docker build --platform linux/amd64 -t ... -f Dockerfile .` + `az acr login` + `docker push`
- **Agent create/update** — `az rest --method POST --url "<projectEndpoint>/agents/<name>?api-version=2025-11-15-preview" --body @agent-def.json --resource "https://ai.azure.com"`
- **Eval generation** — fall through to the MCP procedure in [observe skill → evaluation-suite-generation](../observe/references/evaluation-suite-generation.md)
- **Direct-code** — see [direct-code-deployment.md](references/direct-code-deployment.md)

These remain valid for break-glass scenarios but lose azd's environment resolution, idempotence, and RBAC verification.

## Additional Resources

- [azd ai agent docs](https://aka.ms/azd-ai-agent-docs)
- [Foundry Hosted Agents](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Foundry Agent Runtime Components](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/runtime-components?view=foundry)
- [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples/)
- [Direct Code Deployment Reference](references/direct-code-deployment.md)
