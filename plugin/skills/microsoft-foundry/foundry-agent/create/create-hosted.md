# Create Hosted Agent Application

Create new hosted agent applications for Microsoft Foundry, or convert existing agent projects to be Foundry-compatible using the hosting adapter.

## Quick Reference

| Property | Value |
|----------|-------|
| **Samples Repo** | `microsoft-foundry/foundry-samples` |
| **Python Samples** | `samples/python/hosted-agents/` |
| **C# Samples** | `samples/csharp/hosted-agents/` |
| **Hosted Agents Docs** | https://learn.microsoft.com/azure/ai-foundry/agents/concepts/hosted-agents |
| **Default Selection** | `Python` + `responses` + `Microsoft Agent Framework` |
| **Best For** | Creating new or converting existing agent projects for Foundry |

## When to Use This Skill

- Create a new hosted agent application from scratch (greenfield)
- Start from an official sample and customize it
- Convert an existing agent project to be Foundry-compatible (brownfield)
- Help user choose a language, protocol, framework, or sample for their agent

## Workflow

> Relative reference paths in this file are resolved from the directory containing `create.md`. For example, `./references/agentframework.md` means the file next to this document under `create/references/`, not a path relative to the runtime working directory.

> **Project endpoint (optional at create time)** — the `foundry` CLI accepts a project endpoint via `--project-endpoint <url>`; otherwise it uses the default set with `foundry project set <url>` (inspect via `foundry project show`). It is fine to scaffold without one and bind it later.

### Step 1: Determine Scenario

Check the user's workspace for existing agent project indicators:

- **No agent-related code found** → **Greenfield**. Proceed to Greenfield Workflow (Step 2).
- **Existing agent code present** → **Brownfield**. Proceed to Brownfield Workflow.

### Step 2: Scaffold from a Sample (Greenfield)

Use the `foundry agent init` command. It owns sample browsing, download, and scaffolding for every supported (language, framework, protocol, sample) combination — do **not** call the GitHub Contents API or `gh`/`curl` to fetch samples by hand.

**Pick the lane**

- If the user expressed clear preferences for language, framework, protocol, or sample, pass them as flags:

  ```bash
  foundry agent init <folder> \
    --language <python|csharp> \
    --framework <agent-framework|copilot-sdk|bring-your-own> \
    --protocol <responses|invocations> \
    --sample <slug>
  ```

- If the user has no preferences, default to **Python + `responses` + Microsoft Agent Framework** and pick the simplest sample that matches what the user asked the agent to do (e.g. `tools` for local function tools, `mcp` for MCP integration, `foundry-toolbox` for server-side tools, `hello-world`/`basic`/`simple` for a minimal start).

- If the user wants to browse, run `foundry agent init --interactive` (single-select menus filtered by prior choices) **or** run `foundry agent init --list-templates` to print the canonical sample catalog and surface the options to them. Do **not** invent or duplicate sample listings.

- Optionally bind project + model deployment into the scaffold's `.env` at creation time: `--project-endpoint <url>` and `--model-deployment <name>`.

> ⚠️ **Automation guardrail (Copilot CLI / non-interactive shells):** `foundry agent init` **auto-launches an interactive picker** when no selection flag is supplied and stdin/stdout are a TTY. To prevent hangs in agentic runs, either supply enough flags (`--template-id` or `--language` + `--framework` + `--protocol` + `--sample`) **or** pass `--no-prompt` (also via `FOUNDRY_NO_PROMPT=1`, `CI=1`, `TERM=dumb`, `DEBIAN_FRONTEND=noninteractive`) so missing inputs fail fast instead of prompting.

> ⚠️ **Warning:** LangGraph is Python-only. For C# + LangGraph, suggest Microsoft Agent Framework or `bring-your-own` (Custom) instead.

> 💡 **Tip:** A single hosted agent can expose **multiple protocols simultaneously** (e.g. `invocations` + `invocations_ws` for a control HTTP path plus a WebSocket path). Declare each in `agent.yaml` under `protocols:` and register the matching handlers on the same `InvocationAgentServerHost`. For `invocations_ws` specifics, follow the dedicated [invocations-ws skill](../invocations-ws/invocations-ws.md).

> ⚠️ **Tools:** Hosted agents access tools through a **Foundry Toolbox MCP endpoint** — they do NOT wire tools directly. If the user wants an agent with tools (web search, AI search, code interpreter, MCP servers, etc.), pick a `toolbox`/`mcp`/`foundry-toolbox` sample (see [references/use-toolbox-in-hosted-agent.md#code-integration-patterns](references/use-toolbox-in-hosted-agent.md#code-integration-patterns)). These samples include Foundry Toolbox integration in the sample code out of the box, but the user still needs an actual toolbox resource — resolve its endpoint in Step 4 (Verify Startup).

`foundry agent init` writes the project structure, `agent.yaml`, `.env`, dependency files, and (for container samples) a `Dockerfile`. Do not regenerate those by hand unless the user wants to deviate from the sample.

### Step 3: Customize and Implement

1. Read the scaffolded `README.md` and `agent.yaml` (or `agent.manifest.yaml`) to understand the sample's structure.
2. Read the sample code to understand patterns, protocol handling, and dependencies used.
3. If using Microsoft Agent Framework, follow the best practices in [references/agentframework.md](references/agentframework.md).
4. Implement the user's specific requirements on top of the sample.
5. Update configuration (`.env`, dependency files, `agent.yaml`, `agent.manifest.yaml`) as needed, and keep the selected protocol consistent across code and config.
6. Ensure the project is in a runnable state.

### Step 4: Verify Startup

1. Install dependencies using the language's standard tool (e.g. `pip install -r requirements.txt` inside a `.venv` for Python, `dotnet restore` for C#, `npm install` for Node). The scaffolded `README.md` documents the exact command if any setup is non-standard.
2. Ask the user to fill in any placeholder `.env` values using `ask_user` / `askQuestions`.
   - **If the agent uses tools / toolboxes**: resolve the toolbox endpoint per [references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint](references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint).
3. Run the entrypoint exactly as documented in the scaffolded `README.md` (typically `python main.py` / `dotnet run` / `npm start`). The adapter should bind `http://localhost:8088`.
4. Fix startup errors and retry if needed.
5. In a **separate shell**, send a smoke-test request with `foundry agent invoke --local`:

   ```bash
   # responses or invocations protocol — auto-detected from agent.yaml
   foundry agent invoke --local "<probe message>"

   # explicit protocol
   foundry agent invoke --local --protocol invocations -f request.json

   # interactive web inspector (chat, request/response, tool calls)
   foundry agent invoke --local --inspect
   ```

   For `invocations_ws` (WebSocket) samples, follow the [invocations-ws skill](../invocations-ws/invocations-ws.md); `foundry agent invoke` does not speak WebSocket.
6. Fix any errors from the smoke test and retry until it succeeds.
7. Once startup and smoke test succeed, stop the local server to free the port.

**Guardrails:**
- ✅ Perform a real run to catch startup errors.
- ✅ Cleanup after verification (stop the server).
- ✅ Auth/connection/timeout errors against Azure services are **expected** here — the smoke test only validates that the local HTTP server starts and accepts requests.
- ❌ Don't wait for user input or create disposable test scripts.

### Step 5: Deploy Handoff

Tell the user the local agent works and offer the next step: *"Say `deploy agent to foundry` to continue with the deploy sub-skill."*

## Brownfield Workflow: Convert Existing Agent to Hosted Agent

Use this workflow when the user has an existing agent project that needs to be made compatible with Foundry hosted agent deployment. The key requirement is wrapping the existing agent with the appropriate hosting adapter.

### Step B1: Analyze Existing Project

Scan the project to determine:

1. **Language** — Python (look for `requirements.txt`, `pyproject.toml`, `*.py`) or C# (look for `*.csproj`, `*.cs`)
2. **Framework** — Identify which agent framework is in use:

| Indicator | Framework |
|-----------|-----------|
| Imports from `agent_framework` or `Microsoft.Agents.AI` | Microsoft Agent Framework |
| Imports from `langgraph`, `langchain` | LangGraph |
| No recognized framework imports, or other frameworks (e.g., Semantic Kernel, AutoGen, custom code) | Custom |

3. **Target protocol** — If the user has not specified one, infer whether the project should target `responses`, `invocations`, or `invocations_ws` based on the existing caller contract (HTTP request/response → `responses` or `invocations`; long-lived duplex stream / real-time media → `invocations_ws`)
4. **Entry point** — Identify the main script/entrypoint that creates and runs the agent
5. **Agent object** — Identify the agent instance that needs to be wrapped (e.g., a `BaseAgent` subclass, a compiled `StateGraph`, or an existing server/app)

### Step B2: Add Hosting Adapter Dependency

Add the correct adapter package based on framework, language, and protocol. Get the latest version from the package registry — do not hardcode versions.

**Python adapter packages:**

| Framework | Package(s) |
|-----------|------------|
| Microsoft Agent Framework | `responses`: `agent-framework-foundry-hosting`; `invocations`: `agent-framework-foundry-hosting` |
| LangGraph | `responses`: `azure-ai-agentserver-responses` + `azure-ai-agentserver-core`; `invocations`: `azure-ai-agentserver-invocations` + `azure-ai-agentserver-core` |
| Custom | `responses`: `azure-ai-agentserver-responses`; `invocations`: `azure-ai-agentserver-invocations` |

**.NET adapter packages:**

| Framework | Package(s) |
|-----------|------------|
| Microsoft Agent Framework | `responses`: `Microsoft.Agents.AI.Foundry.Hosting`; `invocations`: `Microsoft.Agents.AI.Foundry.Hosting` + `Azure.AI.AgentServer.Invocations` |
| Custom | `responses`: `Azure.AI.AgentServer.Responses`; `invocations`: `Azure.AI.AgentServer.Invocations` |

Add the package to the project's dependency file (`requirements.txt`, `pyproject.toml`, or `.csproj`). For Python, also add `python-dotenv` if not present.

### Step B3: Wrap Agent with Hosting Adapter

Modify the project's main entrypoint to wrap the existing agent with the adapter. The approach differs by framework and protocol:

**Microsoft Agent Framework + `responses` (Python):**
- Import `ResponsesHostServer` from the adapter package
- Pass the agent instance (from `agent_framework` package) to the adapter
- Call `.run()` on the adapter as the default entrypoint

**Microsoft Agent Framework + `invocations` (Python):**
- Use `InvocationAgentServerHost()`
- Implement an `@app.invoke_handler`
- Manage session state if the agent needs multi-turn memory

**Microsoft Agent Framework + `responses` (C#):**
- Register Foundry responses hosting and map the `responses` protocol

**Microsoft Agent Framework + `invocations` (C#):**
- Register invocations services and an invocation handler
- Map the `invocations` protocol

**LangGraph:**
- Python only
- Follow the `bring-your-own/{protocol}/langgraph-chat` sample for the selected protocol lane

**Custom:**
- Follow the corresponding `bring-your-own/{protocol}` sample for the selected language
- Prefer the protocol SDK sample for the selected lane instead of inventing a custom contract when a sample already exists

**`invocations_ws`:**
- Use the `azure-ai-agentserver-invocations` SDK and register a WebSocket handler with `@app.ws_handler` on the same `InvocationAgentServerHost`
- Follow the [invocations-ws skill](../invocations-ws/invocations-ws.md) for the wire-level contract and `agent_session_id` semantics
- Reference samples live under `samples/python/hosted-agents/bring-your-own/invocations_ws/`

> ⚠️ **Warning:** The adapter MUST be the default entrypoint (no flags required to start). This is required for both local debugging and containerized deployment.

### Step B4: Configure Environment

1. Create or update a `.env` file with required environment variables (project endpoint, model deployment name, etc.)
   - **If the agent uses tools / toolboxes**: resolve the toolbox endpoint per [references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint](references/use-toolbox-in-hosted-agent.md#resolve-toolbox-endpoint).
2. For Python: ensure the code uses `load_dotenv(override=False)` so Foundry-injected environment variables are available at runtime.
3. If the project uses Azure credentials: ensure Python uses `azure.identity.DefaultAzureCredential` for **local development**. In production, use `ManagedIdentityCredential`. See [auth-best-practices.md](../../references/auth-best-practices.md)

### Step B5: Create agent.yaml

Create an `agent.yaml` file in the project root. This file defines the agent's metadata and deployment configuration for Foundry. Required fields:

- `name` — Unique identifier (alphanumeric + hyphens, max 63 chars)
- `description` — What the agent does
- `template.kind` — Must be `hosted`
- `template.protocols` — Must include the selected protocol and matching version from the chosen sample
- `template.environment_variables` — List all environment variables the agent needs at runtime

Refer to the chosen sample's `agent.yaml` or `agent.manifest.yaml` in the [foundry-samples repo](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents) for the exact schema.

### Step B6: Create Dockerfile

Create a `Dockerfile` if one doesn't exist. Requirements:

- Base image appropriate for the language (e.g., `python:3.12-slim` for Python, `mcr.microsoft.com/dotnet/sdk` for C#)
- Copy source code into the container
- Install dependencies
- Expose port **8088** (the adapter's default port)
- Set the main entrypoint as the CMD

> ⚠️ **Warning:** When building, MUST use `--platform linux/amd64`. Hosted agents run on Linux AMD64 infrastructure. Images built for other architectures (e.g., ARM64 on Apple Silicon) will fail.

Refer to the chosen sample's `Dockerfile` in the [foundry-samples repo](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents) for the exact pattern.

### Step B7: Test Locally

1. Install dependencies (use virtual environment for Python)
2. Run the main entrypoint — the adapter should start an HTTP server on `localhost:8088`
3. Send a protocol-appropriate test request:
   - `responses` → `POST /responses`
   - `invocations` → `POST /invocations`
   - `invocations_ws` → open a WebSocket to `ws://localhost:8088/invocations_ws` (see the [invocations-ws skill](../invocations-ws/invocations-ws.md) for framing)
4. Verify the response follows the expected protocol shape for the selected lane
5. Fix any errors and retry until the test request succeeds
6. Stop the server

> 💡 **Tip:** If auth/connection errors occur for Azure services, that's expected without real Azure credentials configured. The key validation is that the HTTP server starts and accepts requests.

## Common Guidelines

IMPORTANT: YOU MUST FOLLOW THESE.

Apply these to both greenfield and brownfield projects:

1. **Sample-first** — Start from a real sample. For greenfield, `foundry agent init` enforces this (it only scaffolds from the canonical sample index). For brownfield, follow the named sample in the adapter lane. Do not invent unsupported combinations, paths, or protocol behavior.

2. **Protocol consistency** — Keep the selected protocol consistent across sample choice, code, config, and verification steps.

3. **Logging** — Implement proper logging using the language's standard logging framework (Python `logging` module, .NET `ILogger`). Hosted agents stream container stdout/stderr logs to Foundry, so all log output is visible via the troubleshoot workflow. Use structured log levels (INFO, WARNING, ERROR) and include context like request IDs and agent names.

4. **Framework-specific best practices** — When using Microsoft Agent Framework, read the [Agent Framework best practices](references/agentframework.md) for hosting adapter setup, credential patterns, and debugging guidance.

5. **Deploy handoff** — After the agent has been created and local verification succeeds, explicitly tell the user that they can deploy the agent if they want, and ask them to say `deploy agent to foundry` to continue with the deploy sub-skill.

6. **Tool integration** — Hosted agents access tools through [Foundry Toolbox](references/use-toolbox-in-hosted-agent.md), NOT by wiring tools directly. If the user needs tools (web search, AI search, code execution, file search, MCP servers, etc.), follow the toolbox integration guide. The toolbox provides a single MCP-compatible endpoint that handles credential injection and tool discovery.

7. **Reserved environment variables** — The Foundry platform injects environment variables into every hosted agent container at startup. You MUST NOT generate, suggest, or configure any of these in `.env` files, `agent.yaml` `environment_variables`, or application code:

   **Blocked prefixes** (any variable starting with these is reserved):
   - `FOUNDRY_*` — platform-injected identity, session, project, and toolset variables
   - `AGENT_*` — reserved for platform use

   **Exact reserved names** (platform-managed, overwritten at runtime):
   - `PORT` — HTTP listen port (default `8088`)
   - `HOME` — session filesystem path (`/home/session`)
   - `SSE_KEEPALIVE_INTERVAL` — SSE keep-alive config
   - `APPLICATIONINSIGHTS_CONNECTION_STRING` — observability
   - `OTEL_EXPORTER_OTLP_ENDPOINT` — OTLP collector endpoint

   **Key `FOUNDRY_*` variables available at runtime** (read-only, do not set):
   - `FOUNDRY_PROJECT_ENDPOINT` — project endpoint URL for calling Azure services
   - `FOUNDRY_AGENT_NAME` — the deployed agent's name
   - `FOUNDRY_AGENT_VERSION` — the deployed agent's version
   - `FOUNDRY_TOOLBOX_ENDPOINT` — MCP-compatible toolbox endpoint (if toolbox is configured)

   If user code needs to read these values at runtime (e.g., `FOUNDRY_PROJECT_ENDPOINT` to call Azure services), read them from the environment — do not set or override them.

## Coding Tips

Use these when generating or modifying project code:

1. **Create a `.gitignore` file** — After generating code, create a `.gitignore` file if one does not already exist. If one already exists, update it as needed.
   - Choose the ignore entries based on the language, framework, and files generated.
   - Do not leave the project with no ignored files.
   - For Python projects, `.venv/` MUST be ignored at a minimum.

## Non-Interactive / YOLO Mode

When running in non-interactive mode (e.g., YOLO mode), skip selection prompts and use these defaults unless the user has already specified otherwise:

- **Language** — `Python`
- **Protocol** — `responses`
- **Framework** — `Microsoft Agent Framework`

If the user's request clearly requires another supported lane, use that lane instead of forcing the defaults.

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| `foundry agent init` lane has no sample | Requested combination is unsupported (e.g. C# + LangGraph) or `--sample` slug doesn't exist in that lane | Re-run without filters or with `--interactive`; the CLI prints the candidate table for the surviving lane. Switch to the nearest supported lane. |
| Sample download / GitHub rate limit during `init` | Anonymous GitHub API requests hit 60/hr cap | Set `GITHUB_TOKEN` (or `GH_TOKEN`) before re-running `foundry agent init`. |
| `foundry agent init` refuses to scaffold | Destination folder exists and is non-empty | Re-run with `--force` (after confirming with the user). |
| Protocol mismatch | Code, `agent.yaml`, and smoke-test request are not aligned | Make all three match the selected protocol. The CLI auto-detects protocol from `agent.yaml` when none is passed to `invoke`. |
| Dependency install fails | Version conflicts | Use versions from the scaffolded sample's own dependency file. |
| Local smoke test connects to nothing | Local entrypoint isn't running, or bound to a different port | Confirm the entrypoint is running and listening on `:8088`; otherwise pass `--port <int>` to `foundry agent invoke --local`. |
