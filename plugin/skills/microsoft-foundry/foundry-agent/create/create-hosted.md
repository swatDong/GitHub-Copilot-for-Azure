# Create Hosted Agent Application

Create new hosted agent applications for Microsoft Foundry, or convert existing agent projects to be Foundry-compatible. Built around `azd ai agent init`, which scaffolds the full project (`agent.yaml`, `.agentignore`, `Dockerfile`, `azure.yaml`, `.env`) from a sample manifest or local source.

## Quick Reference

| Property | Value |
|----------|-------|
| Primary tool | `azd ai agent init` (Foundry extension v0.1.36-preview or later) |
| Sample catalog | `azd ai agent sample list` (same catalog the interactive picker uses) |
| Local dev | `azd ai agent run` + `azd ai agent invoke --local` + optional `azd ai inspector launch` |
| Default selection | `Python` + `responses` + Microsoft Agent Framework |
| Best For | New hosted agent projects (greenfield) or wrapping existing code (brownfield) |

## When to Use This Skill

- Create a new hosted agent application from scratch (greenfield)
- Start from an official sample and customize it
- Convert an existing agent project to be Foundry-compatible (brownfield)
- Help the user choose a language, protocol, framework, or sample

## Workflow

### Step 1: Determine Scenario

Check the user's workspace for existing agent project indicators:

- **No agent-related code found** → **Greenfield** (Step 2 — manifest path)
- **Existing agent code present** → **Brownfield** (Step 2 — `--src` path)

### Step 2: Initialize the Project

`azd ai agent init` is the single entry point for both scenarios. It writes `agent.yaml`, `.agentignore`, a `Dockerfile` (for container deploy) or skips Docker (for code deploy), registers the agent service in `azure.yaml`, and ingests the chosen model deployment into the azd environment.

#### 2a. Greenfield (sample-based)

Browse the curated catalog non-interactively first when you need to pick a sample programmatically:

```bash
azd ai agent sample list                                  # text
azd ai agent sample list --output json --type agent       # only agent-manifest samples
azd ai agent sample list --language python --featured-only --output json
```

Each entry includes a ready-to-execute `initCommand` string — prefer it over composing flags manually.

Initialize from a manifest:

```bash
azd ai agent init                                        # interactive picker
azd ai agent init -m <manifest-url-or-path>              # specific manifest
azd ai agent init -m <manifest-url> --agent-name my-unique-agent
```

> ⚠️ **Agent name = Foundry identity.** Foundry agents are unique by name within a project. Reusing a name on `azd deploy` creates a **new version** of that existing agent. Use `--agent-name` to give a reusable sample a unique name.

For tools-enabled samples, the catalog includes lanes that pre-wire a [Foundry Toolbox](references/use-toolbox-in-hosted-agent.md). Hosted agents access tools through a **toolbox MCP endpoint** — they do NOT wire tools directly. If the user wants tools (web search, AI search, code interpreter, MCP servers, etc.), pick a `toolbox` sample.

#### 2b. Brownfield (existing source)

Point `azd ai agent init` at the existing source directory:

```bash
azd ai agent init --src ./existing-agent --agent-name my-unique-agent
```

For frameworks/protocols `azd init` does not auto-wrap, the existing agent must already expose the hosting adapter as its default entrypoint. Use [Brownfield Adapter Wrapping](#brownfield-adapter-wrapping) below as a checklist before re-running `azd ai agent init`.

#### 2c. Non-interactive (CI / scripts)

```bash
azd ai agent init --no-prompt \
  --project-id "<resource-id>" \
  --deploy-mode code \
  --runtime python_3_13 \
  --entry-point app.py \
  --agent-name my-agent \
  --model gpt-4o
```

Key flags:
- `--deploy-mode container | code` — Docker image vs ZIP upload (defaults to `container` in `--no-prompt`)
- `--runtime python_3_13 | python_3_14 | dotnet_10` — code-deploy runtime (required with `--deploy-mode code --no-prompt`)
- `--entry-point app.py | MyAgent.dll` — code-deploy entrypoint
- `--protocol responses,invocations` — declared protocols (repeat or comma-separate)
- `--model <name>` or `--model-deployment <name>` — model selection
- `--dep-resolution remote_build | bundled` — code-deploy dependency strategy
- `--force` — required with `--no-prompt` if an input manifest already lives inside the generated src tree

### Step 3: Configure Local Environment

`.env` and azd environment variables drive local runs and deploys. After `init`:

1. Populate any placeholder values in `.env` (model deployment names, toolbox endpoints, etc.) — use `ask_user` to collect from the user when values are unknown.
   - **Tools / toolboxes**: resolve the toolbox endpoint via [references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint](references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint), then either set it in `.env` for local dev or rely on the platform-injected `FOUNDRY_TOOLBOX_ENDPOINT` at deploy time.
2. For Python, ensure the code uses `load_dotenv(override=False)` so Foundry-injected variables win at runtime.
3. For Azure credentials, use `DefaultAzureCredential` locally and `ManagedIdentityCredential` in production. See [auth-best-practices.md](../../references/auth-best-practices.md).

### Step 4: Verify Locally

`azd ai agent run` auto-detects the project type, installs dependencies, and starts the agent server on `localhost:8088`. It opens **Agent Inspector** in the browser by default.

Run it as an async/background task (the server runs until Ctrl+C):

```bash
azd ai agent run                       # auto-detect everything
azd ai agent run my-agent              # specific service
azd ai agent run --port 9090           # custom port
azd ai agent run --no-inspector        # skip browser UI
azd ai agent run --start-command "python app.py"  # override
```

Once it reports "listening on :8088", send a test invocation in a separate terminal:

```bash
azd ai agent invoke --local "Hello"                       # responses
azd ai agent invoke --local --protocol invocations -f request.json
```

For `invocations_ws` agents, follow the [invocations-ws skill](../invocations-ws/invocations-ws.md) — `azd ai agent invoke` is HTTP-only.

**Guardrails:**
- ✅ Perform a real local run to catch startup errors
- ✅ Stop the server after verification (Ctrl+C) to free port/resources
- ✅ Ignore auth/connection/timeout errors against Azure services (expected without deploy)
- ❌ Do not create custom test scripts when `azd ai agent invoke --local` works

### Step 5: Deploy Handoff

Once local verification succeeds, tell the user the project is ready to deploy and ask them to say `deploy agent to foundry` to continue with the [deploy skill](../deploy/deploy.md).

## Brownfield Adapter Wrapping

Use this only when an existing agent project does not already expose a Foundry hosting adapter as its default entrypoint. `azd ai agent init --src` requires the adapter to be in place; wrap first, then run `init`.

### Step B1: Analyze the Project

| Indicator | Framework |
|-----------|-----------|
| Imports from `agent_framework` or `Microsoft.Agents.AI` | Microsoft Agent Framework |
| Imports from `langgraph`, `langchain` | LangGraph (Python only) |
| Anything else (Semantic Kernel, AutoGen, custom) | Custom |

Identify: language, framework, target protocol (`responses` for HTTP request/response, `invocations` for arbitrary payloads, `invocations_ws` for duplex/voice), entrypoint script, and the agent object to wrap.

### Step B2: Add Hosting Adapter Dependency

Add the correct adapter package; pull the latest version from the package registry rather than hardcoding.

**Python:**

| Framework | Package(s) |
|-----------|------------|
| Microsoft Agent Framework | `agent-framework-foundry-hosting` (both `responses` and `invocations`) |
| LangGraph | `responses`: `azure-ai-agentserver-responses` + `azure-ai-agentserver-core` · `invocations`: `azure-ai-agentserver-invocations` + `azure-ai-agentserver-core` |
| Custom | `responses`: `azure-ai-agentserver-responses` · `invocations`: `azure-ai-agentserver-invocations` |

**.NET:**

| Framework | Package(s) |
|-----------|------------|
| Microsoft Agent Framework | `Microsoft.Agents.AI.Foundry.Hosting` (+ `Azure.AI.AgentServer.Invocations` for `invocations`) |
| Custom | `responses`: `Azure.AI.AgentServer.Responses` · `invocations`: `Azure.AI.AgentServer.Invocations` |

For Python, also ensure `python-dotenv` is present.

### Step B3: Wrap the Agent

Modify the project's entrypoint so the adapter is the **default startup target** (no flags required to start). High level:

- **MAF + `responses` (Python)** — `ResponsesHostServer(agent).run()`
- **MAF + `invocations` (Python)** — `InvocationAgentServerHost()` + `@app.invoke_handler`
- **MAF (C#)** — register Foundry responses or invocations services and map the protocol
- **LangGraph** — follow `samples/python/hosted-agents/bring-your-own/{protocol}/langgraph-chat`
- **Custom** — follow `samples/python/hosted-agents/bring-your-own/{protocol}/` for the chosen lane
- **`invocations_ws`** — register a WebSocket handler with `@app.ws_handler` on the same `InvocationAgentServerHost`; see [invocations-ws skill](../invocations-ws/invocations-ws.md)

> ⚠️ The adapter MUST be the default entrypoint. This is required for both `azd ai agent run` and containerized deploy.

### Step B4: Run `azd ai agent init --src`

After the adapter is in place, run `azd ai agent init --src ./your-source --agent-name <unique>` to generate `agent.yaml`, `.agentignore`, `Dockerfile` (or skip for code deploy), and register the service in `azure.yaml`. Then proceed to Step 3 (configure) and Step 4 (verify locally) above.

## Common Guidelines

IMPORTANT: YOU MUST FOLLOW THESE.

1. **Sample-first** — Prefer `azd ai agent sample list` + `azd ai agent init -m` over manual scaffolding. Do not invent unsupported combinations.

2. **Protocol consistency** — Selected protocol must match across `agent.yaml`, code, and test request.

3. **Logging** — Use the language's standard logging framework (Python `logging`, .NET `ILogger`). Hosted agents stream stdout/stderr to Foundry; view them via `azd ai agent monitor` after deploy.

4. **Framework best practices** — For Microsoft Agent Framework, read [agentframework.md](references/agentframework.md).

5. **Deploy handoff** — After local verification, prompt the user to say `deploy agent to foundry`.

6. **Tool integration** — Use [Foundry Toolbox](references/use-toolbox-in-hosted-agent.md). Do not wire tools directly into the agent.

7. **Reserved environment variables** — The Foundry platform injects these at runtime. You MUST NOT set them in `.env`, `agent.yaml` `environment_variables`, or application config:

   **Blocked prefixes** (any variable starting with these is reserved):
   - `FOUNDRY_*` — platform identity, session, project, toolset
   - `AGENT_*` — reserved for platform use

   **Exact reserved names** (overwritten at runtime):
   - `PORT` (default `8088`), `HOME` (`/home/session`), `SSE_KEEPALIVE_INTERVAL`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `OTEL_EXPORTER_OTLP_ENDPOINT`

   **Key runtime values your code can read** (do not set):
   - `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_AGENT_NAME`, `FOUNDRY_AGENT_VERSION`, `FOUNDRY_TOOLBOX_ENDPOINT`

## Coding Tips

1. Create or update a `.gitignore` after generation. For Python, `.venv/` MUST be ignored at minimum.

## Non-Interactive / YOLO Mode

When running non-interactive, defaults are: Python + `responses` + Microsoft Agent Framework. Use `azd ai agent init --no-prompt` with explicit `--deploy-mode`, `--runtime`, and `--entry-point` flags as shown in Step 2c.

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `azd: command not found` | azd not installed | Install per [azd install docs](https://aka.ms/azd-install) |
| `unknown command "ai"` | `azure.ai.agents` extension missing | `azd extension install azure.ai.agents` |
| `azd ai agent init` cannot resolve project | No `--project-id` and no active azd env with `AZURE_AI_PROJECT_ENDPOINT` | Run `azd ai project set` or pass `--project-id` |
| Sample manifest 404 | URL changed | Re-list with `azd ai agent sample list` and use the current `initCommand` |
| `azd ai agent run` fails to start | Dependency install or runtime mismatch | Inspect logs; verify `agent.yaml` `startupCommand` and language toolchain |
| `agent invoke --local` connection refused | `azd ai agent run` not running, or different port | Start the server first; use matching `--port` |
| Local invoke 5xx | Agent code error | Read `azd ai agent run` console; fix and restart |
| Combination unsupported | Example: C# + LangGraph | Switch to the nearest supported lane (MAF or Custom in C#) |

## Additional Resources

- [azd ai agent init docs](https://aka.ms/azd-ai-agent-docs)
- [Foundry Samples Catalog](https://github.com/microsoft-foundry/foundry-samples)
- [Hosted Agents Concepts](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents)
- [Agent Framework Best Practices](references/agentframework.md)
- [Foundry Toolbox in Hosted Agents](references/use-toolbox-in-hosted-agent.md)
- [Auth Best Practices](../../references/auth-best-practices.md)
