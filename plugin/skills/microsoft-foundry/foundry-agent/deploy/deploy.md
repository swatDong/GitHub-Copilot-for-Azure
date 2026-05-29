# Foundry Agent Deploy

Create and manage agent deployments in Azure AI Foundry. For hosted agents this skill drives the full pipeline (env-var scan → build → push → register → RBAC → smoke test → eval-suite generation) through the `foundry` CLI.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent types | Prompt (LLM-based), Hosted |
| Primary commands | `foundry agent deploy`, `foundry agent invoke` (Step 7 smoke test) |
| Container methods | `zip`, `container`, `image` (auto-detected) |
| Container protocols | `a2a`, `responses`, `invocations`, `invocations_ws`, `mcp` |
| Supported languages | .NET, Node.js, Python, Go, Java |
| Azure MCP tools (eval Step 8 only) | `agent_definition_schema_get`, `agent_update`, `agent_get`, `agent_delete` (see [Below the CLI](#below-the-cli-azure-mcp-fallback)) |

## When to Use This Skill

USE FOR: deploy agent to foundry, push agent to foundry, ship my agent, build and deploy container agent, deploy hosted agent, direct code deployment, upload code deployment, create hosted agent, deploy prompt agent, ACR build, container image for agent, docker build for foundry, redeploy agent, update agent deployment, clone agent, delete agent, deploy agent.

> ⚠️ **DO NOT run `foundry agent deploy` directly** without reading this skill first. The bare CLI command skips the env-var scan, post-deploy smoke test, and mandatory eval-suite generation that this skill enforces. Run the CLI from within this skill's workflow.

## Deployment Method Selection

Direct code deployment is opt-in only.

- Prompt agents use [Workflow: Prompt Agent Deployment](#workflow-prompt-agent-deployment).
- Hosted agents use [Workflow: Hosted Agent Deployment](#workflow-hosted-agent-deployment); `foundry agent deploy` auto-detects the method in Step 3.
- Do not infer direct code deployment just because Docker is unavailable or a Dockerfile is missing. Ask, or use the default Docker/ACR detection guidance.

If the user explicitly says `using direct code deployment`, `direct-code deployment`, `upload code deployment`, or otherwise clearly asks to deploy by uploading source code, Step 3 reads [Direct Code Deployment Reference](references/direct-code-deployment.md), passes `--method zip` to `foundry agent deploy`, then proceeds directly to [Step 7: Test the Agent](#step-7-test-the-agent).

## Workflow: Hosted Agent Deployment

> ⚠️ **Warning: hosted agent deployment has 8 steps, not 7.**
>
> The single most common failure of this skill is stopping after Step 7 (invocation smoke test) and emitting a "deployment complete" summary. **Step 8 (auto-generate evaluation suite) is mandatory and runs automatically after every deploy — including redeploys, version bumps, and any rerun against an already-existing agent.**
>
> Before you write any final summary, Playground link, version table, or deployment success message, you MUST self-verify:
>
> 1. Did Step 8 run to completion (suite generated **or** documented fallback persisted)?
> 2. Did you prompt the user to run an evaluation?
>
> If the answer to any of these is **no**, do not summarize — go run Step 8 now.

> ⚠️ **`foundry agent deploy` returning successfully ≠ deployment complete.** The CLI returns after the agent version is registered with Foundry; it does **not** wait for the hosted-agent version to reach `active`. You **MUST** still execute Step 7 (invocation smoke test) and Step 8 (auto-generate evaluation suite) before reporting success to the user.

### Definition of Done — Hosted Agent Deployment

A hosted-agent deployment is complete only when **every** box below is checked. Do **not** produce a final "deployment successful" summary, table, or Playground link until all items are done.

For direct-code deployments, Step 3 runs the direct-code reference and deploys the agent with `foundry agent deploy --method zip`, then proceeds directly to Step 7.

- [ ] Step 1 — Project scanned, type detected
- [ ] Step 2 — Environment variables confirmed with user
- [ ] Step 3 — `foundry agent deploy` completed successfully (build + push + register + RBAC handled by the CLI)
- [ ] Step 4 — Any agent configuration the CLI couldn't infer was collected and passed to deploy
- [ ] Step 5 — Schema validation succeeded (handled by the CLI during Step 3)
- [ ] Step 6 — RBAC assigned by the CLI (or the user was told to ask an admin)
- [ ] Step 7 — Invocation smoke test passed (via the invoke skill)
- [ ] Step 8 — Auto-generated evaluation suite job reached `succeeded` (or documented fallback)
- [ ] Step 8 — Cache files written: `.foundry/suites/<suite>-v<ver>.json`, `.foundry/evaluators/<eval>-v<ver>.json` (FULL definition, not stub), `.foundry/datasets/<agent>-<dataset>-v<ver>.ref.json`, AND `.foundry/datasets/<dataset>-v<ver>/<blob>` (actual dataset rows via SAS-url download)
- [ ] User prompted to run an evaluation

### Prerequisites

- A default Foundry project endpoint set with `foundry project set <url>` (inspect with `foundry project show`), **or** the user will pass `--project-endpoint <url>` on the deploy invocation.
- An Azure CLI login (`az login`) or other `DefaultAzureCredential`-compatible auth in the shell where `foundry agent deploy` runs.

### Step 1: Detect and Scan Project

Get the project path from the user's current context (the agent source folder, typically the folder containing `agent.yaml`). Detect the project type by checking for these files:

| Project Type | Detection Files |
|--------------|-----------------|
| .NET | `*.csproj`, `*.fsproj` |
| Node.js | `package.json` |
| Python | `requirements.txt`, `pyproject.toml`, `setup.py` |
| Go | `go.mod` |
| Java (Maven) | `pom.xml` |
| Java (Gradle) | `build.gradle` |

Delegate an environment variable scan to a sub-agent. Provide the project root and project type. Search source files inside that folder only for these patterns:

| Project Type | Patterns to Search |
|--------------|--------------------|
| .NET (`*.cs`) | `Environment.GetEnvironmentVariable("...")`, `configuration["..."]`, `configuration.GetValue<T>("...")` |
| Node.js (`*.js`, `*.ts`, `*.mjs`) | `process.env.VAR_NAME`, `process.env["..."]` |
| Python (`*.py`) | `os.environ["..."]`, `os.environ.get("...")`, `os.getenv("...")` |
| Go (`*.go`) | `os.Getenv("...")`, `os.LookupEnv("...")` |
| Java (`*.java`) | `System.getenv("...")`, `@Value("${...}")` |

Classification: if followed by a throw/error → required; if followed by a fallback value → optional with default; otherwise → assume required, ask user.

### Step 2: Collect and Confirm Environment Variables

> ⚠️ **Warning:** Environment variables are baked into the agent version and are difficult to change after deployment.

Merge discovered variables with any values the user has already provided. Present them to the user for confirmation with variable name, value, and source (`agent.yaml`, `project default`, `existing .env`, or `user`). Mask sensitive values.

Loop until the user confirms or cancels:
- `yes` → Proceed
- `VAR_NAME=new_value` → Update the value, show updated table, ask again
- `cancel` → Abort deployment

Persist the confirmed values into the project's `.env` (which `foundry agent deploy` auto-loads) **or** be prepared to pass them on the command line:
- `--env KEY=VALUE` (repeatable, highest precedence)
- `--env-file <path>` (suppresses auto-load of `.env`)

### Step 3: Run `foundry agent deploy`

If the user explicitly requested direct code deployment / upload code deployment, do not generate a Dockerfile. Read and follow [Direct Code Deployment Reference](references/direct-code-deployment.md), then run:

```bash
foundry agent deploy --method zip
```

For all other hosted-agent deployments, run `foundry agent deploy` from the agent source folder. Method auto-detection: `--image` (or `agent.yaml#image`) → `image`; a `Dockerfile` next to `agent.yaml` → `container`; otherwise → `zip`.

> ⚠️ **Automation guardrail (Copilot CLI / non-interactive shells):** `foundry agent deploy` **auto-launches an interactive picker** when there is no `agent.yaml`/`--name`/`--image` at the deploy path and stdin/stdout are a TTY. To prevent hangs in agentic runs, either supply enough flags (an `agent.yaml` in the deploy folder, `--name`, `--image`, etc.) **or** pass `--no-prompt` (also via `FOUNDRY_NO_PROMPT=1`, `CI=1`, `TERM=dumb`, `DEBIAN_FRONTEND=noninteractive`) so missing inputs fail fast with an actionable error instead of prompting.

```bash
# Default — auto-detect method, use persisted default project endpoint, auto-provision ACR in the project RG if needed
foundry agent deploy

# Override project endpoint for a single deploy
foundry agent deploy --project-endpoint https://acct.services.ai.azure.com/api/projects/proj

# Inject runtime env vars (highest precedence)
foundry agent deploy --env LOG_LEVEL=debug --env-file ./prod.env

# Bring-your-own-image — skip build/push entirely
foundry agent deploy --method image --image myacr.azurecr.io/agents/sample:1.2.3

# Dry run — resolve & validate config, print plan, exit
foundry agent deploy --dry-run
```

The CLI handles, in this order:
- Resolving env vars from `--env` / `--env-file` / `.env` / `agent.yaml` (with fail-fast on unresolved `${REF}` placeholders unless `--allow-unresolved-env` is passed).
- Building the image remotely (for `container` method) and pushing to ACR (auto-provisioned in the project's resource group if none is specified via `--registry`). Image tags are unique by default; do not pass static tags like `latest`.
- Zipping the source and uploading (for `zip` method).
- Registering the agent definition with Foundry (creates a new agent if it does not exist; pushes a new version on conflict, unless `--no-update-if-exists`).
- Assigning the ACR pull and Foundry roles required for the hosted agent identity to run. `--skip-rbac` opts out.

The CLI remembers resolved choices for future runs; the skill does not need to manage that cache, and should not instruct the user to edit it by hand.

If `foundry agent deploy` exits non-zero, read the error and either ask the user (for credential / permission / config issues) or fix the project (for build / Dockerfile issues) before retrying. Do **not** treat the deploy as successful.

### Step 4: Collect Agent Configuration (Only When Needed)

`foundry agent deploy` reads `agent.yaml` for the agent name, declared protocols, CPU/memory pairing, model deployment, and environment variable keys. Ask the user only for values that are missing from `agent.yaml` (and cannot be inferred from the project) before Step 3:

- **Agent name** — pass `--name <name>` to override `agent.yaml#name` (regex `^[A-Za-z0-9][-A-Za-z0-9]*$`). Required if `agent.yaml` has no `name`.
- **Model deployment** — typically referenced from `agent.yaml` or `.env` (e.g., `AZURE_AI_MODEL_DEPLOYMENT_NAME`). Confirm with the user during Step 2 if missing.

### Step 5: Definition Schema (Optional)

The CLI validates the agent definition against the live Foundry schema before registering it; you do not need to fetch the schema separately. If a deploy fails schema validation, use `agent_definition_schema_get` (see [Below the CLI](#below-the-cli-azure-mcp-fallback)) to inspect the current schema for debugging.

### Step 6: Agent Created — Identities Captured

`foundry agent deploy` automatically assigns the ACR pull role and the Foundry roles required for the per-agent and project-level managed identities to run, unless `--skip-rbac` was passed. The skill does not need to issue `az role assignment` commands directly.

If the deploy succeeded but later steps (smoke test) report a permission error, the most likely cause is that the user does not have permission to create the required role assignments. In that case, stop the deployment workflow and explain that hosted-agent invocation requires `Azure AI User` on the per-agent identity and project-level agent identity at the Cognitive Services account scope, and the deployment cannot be treated as complete until someone with RBAC assignment permission grants the missing role.

### Step 7: Test the Agent

For a hosted agent, the version may still be provisioning even after `foundry agent deploy` returns; the smoke test is the first opportunity to detect provisioning failures.

Read and follow the [invoke skill](../invoke/invoke.md) to send a short probe relevant to the agent's purpose (ask the user for a probe message if unclear). For a default-project, default-name deploy this is:

```bash
foundry agent invoke "<probe message>" --new-session --new-conversation
```

> ⚠️ **`--new-session` is mandatory after every deploy.** Each successful deploy creates a new agent version. A cached session pins the runtime to the version it was created against — so a plain `foundry agent invoke` after a redeploy keeps hitting the **OLD** version (the CLI prints a `cached session pinned to version N` warning on stderr). Always pass `--new-session --new-conversation` for the post-deploy smoke test so the probe actually exercises the version you just shipped.

If the call fails with a "version not active" / `424 FailedDependency` / `session_not_ready` error, wait 15-30 seconds and retry up to a few times. If it continues to fail (including auth or permission errors), immediately read and follow the [troubleshoot skill](../troubleshoot/troubleshoot.md). Do not treat the deployment as fully successful until invocation succeeds.

> ⚠️ **Not done yet: invocation success is the midpoint, not the finish line.** The next action after a passing smoke test is **Step 8**, not a deployment summary. Do not write a summary, version table, or Playground link yet.

### Step 8: Auto-Generate Evaluation Suite (MANDATORY — RUNS AUTOMATICALLY)

> ⚠️ **Pre-summary gate.** If you are about to write a deployment summary, Playground link, or "deployment complete" message and Step 8 has not run, you are violating this skill. Run Step 8 first.
>
> This step **runs automatically** without waiting for the user to ask. The only user input required is the one-question prompt below in 8a.

This step is mandatory — not optional — for every hosted-agent deployment, including redeploys, version bumps, and `azd deploy` re-runs against an already-existing agent. In azd projects, resolve deployment context from `azd env get-values` and treat `.foundry/agent-metadata*.yaml` as an overlay/cache instead of copying azd-owned values into it.

**8a. Ask the user (one question, required).** Before generating, inspect the selected agent root for `eval.yaml`, then ask the user to pick a setup source. Recommend local `eval.yaml` when it exists and matches the selected agent; otherwise recommend traces when the agent has recent traces, or current agent code/definition:

> *"Your agent is deployed. I'll now auto-generate an evaluation suite. Which source should I use?*
> *(a) **Current agent code/definition** — synthetic Q&A from `agent.yaml` / instructions. Best when there's little or no trace history.*
> *(b) **Historical traces** — last 3 days, ~50 traces. Best if the agent has recent invocations.*
> *(c) **Existing eval.yaml** — local dataset/evaluator intent from the selected agent folder. Best when azd eval config already exists."*

**8b. Follow the full procedure.** Read and follow [After Deployment — Auto-Generate Evaluation Suite](#after-deployment--auto-generate-evaluation-suite) below for the generation, polling, persistence, and metadata-update steps. Required parameters and poll-to-terminal rules are non-negotiable.

**8c. Cache artifacts locally (MANDATORY after `succeeded`).** Once the suite-generation job is `succeeded`, perform the required cache calls described in [Evaluation Suite Generation → Cache Artifacts Locally](../observe/references/evaluation-suite-generation.md#cache-artifacts-locally):

- `evaluation_suite_get` → `.foundry/suites/<suite>-v<ver>.json` (full object)
- `evaluator_catalog_get` → `.foundry/evaluators/<eval>-v<ver>.json` (full definition, NOT a stub)
- `evaluation_dataset_get` + `evaluation_dataset_sas_url_get` → `.foundry/datasets/<agent>-<dataset>-v<ver>.ref.json` (metadata stub) AND `.foundry/datasets/<dataset>-v<ver>/<blob>` (actual JSONL rows). The SAS-url tool returns a container-scope SAS — list the container then `curl.exe` each blob. See the reference for the exact list+download steps. Set `contentDownloaded: true` in the stub once files are on disk.

Do not write the deployment summary until all cache files exist.

**8d. Skip-only-on-explicit-request.** If — and only if — the user explicitly says "skip eval suite generation," record that decision in your summary and still ensure deployment context remains resolvable from azd or metadata. "The user didn't ask for it" is **not** a valid reason to skip; this step is opt-out, not opt-in.

## Workflow: Prompt Agent Deployment

### Definition of Done — Prompt Agent Deployment

A prompt-agent deployment is complete only when **every** box below is checked. Do **not** produce a final "deployment successful" summary, table, or Playground link until all items are done.

- [ ] Step 1 — Agent configuration collected
- [ ] Step 2 — Agent definition schema retrieved
- [ ] Step 3 — `agent_update` called successfully
- [ ] Step 4 — Invocation smoke test passed (via the invoke skill)
- [ ] Step 5 — Auto-generated evaluation suite job reached `succeeded` (or documented fallback)
- [ ] Step 5 — Cache files written: `.foundry/suites/<suite>-v<ver>.json`, `.foundry/evaluators/<eval>-v<ver>.json` (FULL definition, not stub), `.foundry/datasets/<agent>-<dataset>-v<ver>.ref.json`, AND `.foundry/datasets/<dataset>-v<ver>/<blob>` (actual dataset rows via SAS-url download)
- [ ] Deployment context is resolvable from azd or metadata; `.foundry/agent-metadata*.yaml` contains only non-derivable overlay/cache state for the selected environment
- [ ] User prompted to run an evaluation

### Step 1: Collect Agent Configuration

Use the project endpoint from the project context (see [Common Project Context Resolution](../../SKILL.md#agent-common-project-context-resolution)). Ask the user only for values not already resolved:
- **Agent name** — Unique name for the agent
- **Model deployment** — Model deployment name (e.g., `gpt-4o`)
- **Instructions** — System prompt (optional)
- **Temperature** — Response randomness 0-2 (optional, default varies by model)
- **Tools** — Tool configurations (optional)

### Step 2: Get Agent Definition Schema

Use `agent_definition_schema_get` with `schemaType: prompt` to retrieve the current schema.

### Step 3: Create the Agent

Use `agent_update` with the agent definition:

```json
{
  "kind": "prompt",
  "model": "<model-deployment>",
  "instructions": "<system-prompt>",
  "temperature": 0.7
}
```

### Step 4: Test the Agent

Read and follow the [invoke skill](../invoke/invoke.md) to send a test message and verify the agent responds correctly.

> ⚠️ **Not done yet: invocation success is the midpoint, not the finish line.** The next action is **Step 5**, not a deployment summary. Do not write a summary or Playground link yet.

### Step 5: Auto-Generate Evaluation Suite (MANDATORY — RUNS AUTOMATICALLY)

> ⚠️ **Pre-summary gate.** If you are about to write a deployment summary or Playground link and Step 5 has not run, you are violating this skill. Run Step 5 first.
>
> This step **runs automatically** without waiting for the user to ask. The only user input required is the one-question prompt below.

**5a. Ask the user (one question, required).** Before generating, inspect the selected agent root for `eval.yaml`, then ask which setup source to use. Recommend local `eval.yaml` when it exists and matches the selected agent; otherwise recommend recent traces when present, or current agent code/definition:

> *"Your agent is deployed. I'll now auto-generate an evaluation suite. Which source should I use? (a) Current agent code/definition (synthetic Q&A), (b) Historical traces (last 3 days, ~50 traces), or (c) Existing eval.yaml from the selected agent folder?"*

**5b. Follow the full procedure.** Read and follow [After Deployment — Auto-Generate Evaluation Suite](#after-deployment--auto-generate-evaluation-suite) below.

**5c. Cache artifacts locally (MANDATORY after `succeeded`).** Once the suite-generation job is `succeeded`, perform the required cache calls described in [Evaluation Suite Generation → Cache Artifacts Locally](../observe/references/evaluation-suite-generation.md#cache-artifacts-locally): suite JSON, evaluator full definition, dataset `.ref.json` PLUS the actual dataset blobs downloaded via `evaluation_dataset_sas_url_get` (container SAS → list → curl each blob). Do not write the deployment summary until those files exist.

**5d. Skip-only-on-explicit-request.** Skip only if the user explicitly says "skip eval suite generation." Keep deployment context resolvable from azd or metadata. "The user didn't ask for it" is **not** a valid reason to skip.

## Display Agent Information

> ⚠️ **Gate:** Do not render the table or Playground link until the Definition of Done checklist for the selected workflow (Hosted or Prompt) is fully satisfied, including the invocation smoke test, the auto-generated evaluation suite (or documented skip), and resolvable deployment context plus `.foundry` overlay/cache updates. The Playground link is the final artifact, not a mid-workflow checkpoint.

Once deployment is done for either hosted or prompt agent, display the agent's details in a nicely formatted table.

Below the table you MUST also display a Playground link for direct access to the agent in Azure AI Foundry:

[Open in Playground](https://ai.azure.com/nextgen/r/{encodedSubId},{resourceGroup},,{accountName},{projectName}/build/agents/{agentName}/build?version={agentVersion})

To calculate the encodedSubId, you need to take subscription id and convert it into its 16-byte GUID, then encode it as URL-safe base64 without padding (= characters trimmed). You can use the following Python code to do this conversion:

```
python -c "import base64,uuid;print(base64.urlsafe_b64encode(uuid.UUID('<SUBSCRIPTION_ID>').bytes).rstrip(b'=').decode())"
```

## Document Deployment Context

After a successful deployment, make the deployment context reusable without duplicating azd-owned values. If `azure.yaml` and `azd env get-values` provide the project endpoint, agent name/version, ACR, App Insights, subscription, resource group, and project identifiers, treat azd as the source of truth. Persist only non-derivable overlay/cache state to the selected metadata file under `<agent-root>/.foundry/`.

| State | Preferred Source | Metadata Behavior |
|-------|------------------|-------------------|
| Project endpoint, agent name/version, ACR, observability | azd env values | Do not copy when azd provides them |
| azd binding | selected azd env/service | Store `azd.environmentName` and `azd.service` when useful |
| Evaluation suites | Foundry lookup/generation or verified `eval.yaml` sync | Persist in `evaluationSuites[]` |
| Local cache paths and results | `.foundry/` cache/results | Persist suite, dataset, evaluator, and result refs |

If metadata and azd disagree for the same deployment value, stop and ask which source is authoritative. If the selected metadata file is a preferred single-environment file, update only that one environment block and leave sibling metadata files untouched. If the selected metadata file is a legacy multi-environment file, merge the selected environment instead of overwriting other environments or cached evaluation suites without confirmation. If the selected environment still uses older `testSuites[]` or legacy `testCases[]`, rewrite that environment to `evaluationSuites[]` when you persist synced suite metadata.

## After Deployment — Auto-Generate Evaluation Suite

> ⚠️ **This step is automatic.** After a successful deployment, immediately prepare the selected `.foundry` environment for evaluation without waiting for the user to request it. This matches the eval-driven optimization loop.

### 1. Resolve Effective Context

Use the [Common Project Context Resolution](../../SKILL.md#agent-common-project-context-resolution) flow. In azd projects, resolve project endpoint, agent name/version, ACR, and observability from `azd env get-values`; use `.foundry/agent-metadata*.yaml` only for overlays and synced suite/cache refs. If `eval.yaml` exists in the selected agent root, parse it as local evaluation intent before generating anything new.

### 2. Read Agent Instructions

Use **`agent_get`** (or local `agent.yaml`) to understand the agent's purpose and capabilities.

### 3. Reuse or Refresh Suite Cache

Inspect the selected agent root before generating anything new:

- Reuse a selected environment `evaluationSuites[]` entry when it has `suiteName`, `suiteVersion`, matching `.foundry/datasets/`, and matching `.foundry/evaluators/` cache files.
- When `eval.yaml` exists and matches the selected agent, prefer verifying/registering its dataset and evaluator references before creating a brand-new generated suite.
- Call `evaluation_suite_get` to confirm the remote suite still exists before reusing it.
- Ask before refreshing cached files, replacing thresholds, or writing a new suite version.
- If cache or the remote suite is missing/stale, generate a new suite and update metadata for the active environment only.

### 4. Identify Generation Deployment

Use **`model_deployment_get`** to list the selected project's actual model deployments, then choose one that supports chat completions for quality evaluators. Do **not** assume `gpt-4o` exists in the project. If no deployment supports chat completions, stop the auto-setup flow and tell the user quality evaluators cannot run until a compatible judge deployment is available.

### 5. Generate Evaluation Suite

Read and follow [Evaluation Suite Generation](../observe/references/evaluation-suite-generation.md) for source selection, required parameters, polling, and cache writes. In the deploy flow, keep these guardrails:

- Ask the user which setup source to use before calling `evaluation_suite_generation_job_create`; recommend matching `eval.yaml` when present, then recent traces when available, otherwise the current agent code/definition.
- Use the chat-capable generation deployment selected above and honor the reference's service constraints, especially `maxSamples` (15-1000) and `agentSourceNames: [<agentName>]` for agent-sourced suites.
- Do not report deployment complete while the generation job is `in_progress`; poll with `evaluation_suite_generation_job_get` until `succeeded`, `failed`, or `canceled`, then inspect the suite with `evaluation_suite_get` and cache artifacts as described in the reference.

### 6. Fallback to Manual Suggestions

If `evaluation_suite_generation_job_create`, `evaluation_suite_generation_job_get`, or `evaluation_suite_get` fails, is unavailable, or returns incomplete artifacts, fall back to the previous manual flow:

1. Call `evaluator_catalog_get` and suggest relevant built-in/custom evaluators.
2. Read [Generate Seed Evaluation Dataset](../eval-datasets/references/generate-seed-dataset.md), generate valid local JSONL with `query` and `expected_behavior`, and register it with `evaluation_dataset_create`.
3. Persist the suite with `generationSource: manual-fallback` and include the fallback reason in the workflow summary.

Do **not** silently ignore generation failures; the user should know whether setup used the generated-suite path or the fallback path.

The local filename must start with the effective selected Foundry agent name before adding stage, environment, or version suffixes.

### 7. Persist Artifacts and Evaluation Suites

Save generated or fallback evaluator definitions, local datasets, and evaluation outputs under `.foundry/` using the cache paths defined in [Evaluation Suite Generation](../observe/references/evaluation-suite-generation.md), then register or update evaluation suites in the selected metadata file for the selected environment:

```text
.foundry/
  agent-metadata.yaml
  agent-metadata.prod.yaml
  suites/
    <suite-name>-v<version>.json
  evaluators/
    <evaluator-name>-v<version>.json
  datasets/
    <agent-name>-<dataset-name>-v<version>.ref.json
    <dataset-name>-v<version>/<blob>
  results/
```

Each evaluation suite should bundle the remote suite reference, local cache paths, thresholds, and a `tags` map (for example, `tier: smoke`, `purpose: baseline`, `stage: generated`). Persist `suiteName`, `suiteVersion`, `generationJobId`, `generationSource`, `datasetFile`, and `datasetUri` together. Do not persist azd-owned deployment fields when azd resolves them. If the selected environment still uses older `testSuites[]` or legacy `testCases[]`, replace that list with `evaluationSuites[]` in the rewritten metadata and map legacy `priority` to `tags.tier` only when `tags.tier` is missing.

### 8. Prompt User

*"Your agent is deployed and running in the selected environment. The `.foundry` cache now contains generated evaluation-suite metadata, local dataset/evaluator references, and remote Foundry suite references. Would you like to run an evaluation to identify optimization opportunities?"*

- **Yes** → follow the [observe skill](../observe/observe.md) starting at **Step 2 (Evaluate)** — cache and metadata are already prepared.
- **No** → stop. The user can return later.
- **Production trace analysis** → follow the [trace skill](../trace/trace.md) to search conversations, diagnose failures, and analyze latency using App Insights.

## Agent Definition Schemas

### Prompt Agent

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `kind` | string | ✅ | Must be `"prompt"` |
| `model` | string | ✅ | Model deployment name (e.g., `gpt-4o`) |
| `instructions` | string | | System message for the model |
| `temperature` | number | | Response randomness (0-2) |
| `top_p` | number | | Nucleus sampling (0-1) |
| `tools` | array | | Tools the model may call |
| `tool_choice` | string/object | | Tool selection strategy |
| `rai_config` | object | | Responsible AI configuration |

### Hosted Agent

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `kind` | string | ✅ | Must be `"hosted"` |
| `image` | string | ✅ | Container image URL |
| `cpu` | string | ✅ | CPU allocation (e.g., `"0.5"`, `"1"`, `"2"`) |
| `memory` | string | ✅ | Memory allocation (e.g., `"1Gi"`, `"2Gi"`) |
| `container_protocol_versions` | array | ✅ | Protocol and version pairs |
| `environment_variables` | object | | Key-value pairs for container env vars |
| `tools` | array | | Tool configurations |
| `rai_config` | object | | Responsible AI configuration |

### Container Protocols

| Protocol | Description |
|----------|-------------|
| `a2a` | Agent-to-Agent protocol |
| `responses` | OpenAI Responses API |
| `invocations` | Invocation payload protocol for arbitrary request bodies and custom SSE behavior |
| `invocations_ws` | Duplex WebSocket protocol for real-time / voice / signaling workloads (`WS /invocations_ws` on port 8088). Connect through `wss://...endpoint/protocols/invocations_ws?...&agent_session_id=...`. See the dedicated [invocations-ws skill](../invocations-ws/invocations-ws.md) for the full client/server contract. |
| `mcp` | Model Context Protocol |

## Agent Management Operations

### Clone an Agent

Use `agent_update` with `isCloneRequest: true` and `cloneTargetAgentName` to create a copy. For prompt agents, optionally override the model with `modelName`.

### Delete an Agent

Use `agent_delete` — automatically cleans up hosted-agent runtime resources.

### List Agents

Use `agent_get` without `agentName` to list all agents, or with `agentName` to get a specific agent's details.

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `--project-endpoint is required` | No default set and no flag passed | Run `foundry project set <url>` once, or pass `--project-endpoint <url>`. |
| `agent name is required` | `agent.yaml` lacks `name` and no `--name` flag | Set `name:` in `agent.yaml` or pass `--name <name>`. |
| `cpu X requires memory Y` | Invalid CPU/memory pair | Valid pairs: `0.5/1`, `1/2`, `2/4`. |
| `agent '<name>' already exists` | Ran with `--no-update-if-exists` | Rerun without that flag to push a new version. |
| `insufficient permissions to create hosted agents` | Caller lacks Foundry roles | Ask an admin for the *Azure AI Project User* role on the project. |
| Auth failure (`AzureCliCredential` / `DefaultAzureCredential`) | Not signed in | `az login`, or set `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET`, then retry. |
| `Dockerfile not found at <path>` | Container method detected but no Dockerfile | Pass `--dockerfile <path>`, place a `Dockerfile` next to `agent.yaml`, or pick `--method zip`. |
| `--image cannot be combined with: --dockerfile, ...` | `image` method is mutually exclusive with build/registry flags | Either pre-build and use `--method image --image <ref>`, or let the CLI build by removing `--image`. |
| Unresolved `${REF}` placeholder | `agent.yaml` references an env var that was not provided | Pass it via `--env KEY=VALUE` / `--env-file`, set it in `.env`, or pass `--allow-unresolved-env` to ship the literal value. |
| `--registry` not in project resource group | PoC limitation — cross-RG / cross-subscription ACR not supported yet | Omit `--registry` to auto-provision an ACR in the project's resource group. |
| Hosted agent not active after deploy | Provisioning failed or the image is not usable | Verify ACR image path, check cpu/memory values, then inspect hosted-agent logs with the [troubleshoot skill](../troubleshoot/troubleshoot.md). |
| Invocation smoke test failed | Missing invocation RBAC, schema mismatch, or runtime error | Check whether `Azure AI User` is assigned to the per-agent identity and project-level agent identity at the Cognitive Services account scope; otherwise inspect logs via the [troubleshoot skill](../troubleshoot/troubleshoot.md) and retry. |
| Permission denied | Insufficient Foundry project permissions | Verify Azure AI Owner or Contributor role on the project. |

## Below the CLI (Azure MCP Fallback)

Use these when the `foundry` CLI is missing a capability:

| Capability | Tool |
|------------|------|
| Inspect the live agent definition schema (debugging) | `agent_definition_schema_get` |
| Manage existing agents (list / get / clone / delete) | `agent_get`, `agent_update` (with `isCloneRequest`), `agent_delete` |
| Evaluation-suite generation, dataset/evaluator cache work | See Step 8 — still MCP-driven |

## Non-Interactive / YOLO Mode

When running in non-interactive mode (e.g., `nonInteractive: true` or YOLO mode), the skill skips user confirmation prompts and relies on values that are already resolvable. **Critically:** `foundry agent deploy` itself can launch its own interactive picker (when there is no `agent.yaml`/`--name`/`--image` and stdin/stdout are a TTY). To opt the CLI out of that picker as well, pass `--no-prompt` or set one of `FOUNDRY_NO_PROMPT=1`, `CI=1`, `TERM=dumb`, `DEBIAN_FRONTEND=noninteractive` in the environment.

- **Environment variables** — uses values from `--env`, `--env-file`, `.env`, and `agent.yaml` without prompting; deploy fails fast on any unresolved `${REF}` placeholder unless `--allow-unresolved-env` is set.
- **Agent name** — must be set in `agent.yaml` or passed via `--name`; otherwise `foundry agent deploy --no-prompt` fails with a clear error.
- **Hosted-agent verification** — continues into RBAC handling (done by the CLI) and the Step 7 invocation smoke test without additional prompts once deploy succeeds.
- **Direct code deployment** — if explicitly requested, Step 3 reads the direct-code reference and runs `foundry agent deploy --method zip`, then proceeds directly to Step 7.

> ⚠️ **Warning:** In non-interactive mode, ensure all required values (project endpoint, agent name, model deployment, env vars, and ACR image for `--method image` deploys) are provided upfront via flags, `agent.yaml`, or `.env`. Missing values cause `foundry agent deploy --no-prompt` to fail rather than prompt.

## Additional Resources

- [Foundry Hosted Agents](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents?view=foundry)
- [Foundry Agent Runtime Components](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/runtime-components?view=foundry)
- [Foundry Samples](https://github.com/microsoft-foundry/foundry-samples/)
