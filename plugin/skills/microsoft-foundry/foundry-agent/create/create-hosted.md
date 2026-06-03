# Create Hosted Agent (azd ai)

Scaffold a hosted Foundry agent project with the Azure Developer CLI (`azd`) and the `azure.ai.agents` extension. The same flow covers greenfield (from a curated sample) and brownfield (lift existing code), then drops you into a local inner-loop so you can iterate before deploying.

> **Scope:** `azd ai` is the preferred *code-first* path -- use it when the intent is agent code on disk, in a repo, with infrastructure-as-code and a local inner-loop. If the intent is only to create a remote agent resource (no code on disk), other approaches may apply -- for prompt agents see [create-prompt.md](create-prompt.md), or use the Foundry MCP tools / portal.

## Quick Reference

| Property | Value |
|----------|-------|
| Agent type | Hosted (container or code) |
| Primary CLI | `azd ai agent` (from extension `azure.ai.agents`) |
| Scaffold command | `azd ai agent init -m <manifestUrl> --deploy-mode code --runtime python_3_13 --entry-point <file>` (or `--from-code` for brownfield) |
| Local run | `azd ai agent run` + `azd ai agent invoke --local "..."` |
| Deploy handoff | [deploy/deploy.md](../deploy/deploy.md) |
| Sample catalog | `azd ai agent sample list --featured-only --output json` |
| Reference docs | [azd-ai-cli](references/azd-ai-cli.md), [local-run](references/local-run.md), [tools](references/tools.md) |

## When to Use This Skill

- Create a new hosted agent from a curated Foundry sample.
- Lift an existing agent project (Python, .NET, Node.js) into a hosted Foundry agent.
- Add tools (web search, AI Search, MCP, A2A) to a hosted agent.
- Run and iterate on a hosted agent locally before deploying.

For prompt agents (LLM + instructions, no container), use [create-prompt.md](create-prompt.md). For deploy, use [deploy.md](../deploy/deploy.md).

## Hosted vs Prompt

| | Hosted | Prompt |
|--|--------|--------|
| Custom Python / .NET / Node code? | Yes -> this skill | No -> [create-prompt.md](create-prompt.md) |
| Tools / RAG / MCP / A2A | Toolbox + connections | Built-in tool configs |
| Local debugging | `azd ai agent run` | Limited |
| Output | New immutable agent version per `azd deploy` | `agent_update` via MCP / SDK |

## Workflow

### Step 1 -- Verify the environment

Run the bundled verification script to check that the local environment is set up correctly:

```bash
./scripts/verify-environment.sh     # macOS / Linux
./scripts/verify-environment.ps1    # Windows (pwsh)
```

Act on the summary prefixes: `[OK]` nothing to do; `[WARN]` non-blocking (continue); `[ACTION]` resolve first (missing extension -> `azd extension install azure.ai.agents`; failed auth -> ask the user to run `azd auth login`, never run it yourself).

> 💡 **Auth alignment:** If the script reports that `az` is logged in but `azd` is not, ask the user **once**: *"Run `azd config set auth.useAzCliAuth true` so azd reuses your az login (avoids a second browser sign-in)? [Y/n]"*. On consent, run the command directly (it's a config write, not auth). The script also accepts `-SetAzCliAuth` (PowerShell) or `--set-az-cli-auth` (bash) to apply the flip in one pass.

Branch on the reported agent status:

- `not_deployed` -> Step 2.
- `active` / `deployed` -> already deployed. Skip to [deploy/deploy.md](../deploy/deploy.md) for redeploy or [tools](references/tools.md) to add a tool.

### Step 2 -- New or existing Foundry project?

Ask: "Do you want to create a new Foundry project, or use an existing one?"

- **New project** -- do NOT pass `--project-id`. `azd provision` (in deploy) will create it.
- **Existing project** -- ask for the ARM resource ID:
  > Open https://ai.azure.com -> Operate -> Admin -> select the project -> Copy the Resource ID.

Do not guess or shell out to `az` to discover the ID.

### Step 3 -- Pick the scaffolding source

| User has ... | Use |
|--------------|-----|
| Empty workspace, or wants a starter | **Greenfield** -- Step 4a |
| Hand-written agent code already in cwd | **Brownfield** -- Step 4b |

If unsure, default to greenfield. Never guess a manifest URL by hand.

> 💡 **Prefer code deploy over container.** The [deploy skill](../deploy/deploy.md) defaults to direct code deployment (no Docker, no ACR). Pass `--deploy-mode code --runtime <r> --entry-point <e>` to `azd ai agent init` in **both greenfield and brownfield** to scaffold with `language: python` (or `csharp`/`js`/`ts`), no `docker:` block, and `code_configuration:` in `agent.yaml`. Only use `--deploy-mode container` when the agent needs a custom `Dockerfile` or system-level packages.

### Step 4a -- Greenfield: scaffold from a sample

List the curated catalog (filter by language if known):

```bash
azd ai agent sample list --featured-only --language python --output json
```

Each entry has a `manifestUrl` and an `initCommand`. Pick one and run (passing `--deploy-mode code` so the scaffold uses code deploy, not container):

```bash
# New Foundry project, code deploy (recommended)
azd ai agent init --no-prompt \
  -m "<manifestUrl>" \
  --deploy-mode code --runtime python_3_13 --entry-point main.py

# Existing Foundry project
azd ai agent init --no-prompt \
  --project-id "<resourceId>" \
  -m "<manifestUrl>" \
  --deploy-mode code --runtime python_3_13 --entry-point main.py
```

Runtimes: `python_3_13`, `python_3_14`, `dotnet_10`, `node_22`. Resolve the entry point from the sample before running init: download the manifest (e.g., `curl -sSL <manifestUrl>` after rewriting `github.com/.../blob/` to `raw.githubusercontent.com/...`) and find the agent's main module, or open the sample's `README.md` / source files. Common values: `main.py`, `app.py`. Omit `--deploy-mode code` if the sample requires a custom `Dockerfile` (rare for current featured samples).

> Tip: if the manifest declares a `parameters:` block (check by `curl <manifestUrl>`), do NOT drop `--no-prompt`. Instead, collect any required values with `ask_user`, set them via `azd env set PARAM_<CONN>_<KEY> <value>` first, then run `init` with `--no-prompt`. This avoids azd's interactive prompts, which the agent cannot answer reliably.

`init` writes `azure.yaml` (or appends to it), `<service-dir>/agent.yaml`, and `<service-dir>/.agentignore` (code-deploy only). For file shapes, see [azd-ai-cli](references/azd-ai-cli.md).

### Step 4b -- Brownfield: lift existing code

Use ONLY when the workspace already contains hand-written agent source.

```bash
azd ai agent init --no-prompt \
  --from-code \
  --deploy-mode code \
  --runtime python_3_13 \
  --entry-point app.py
```

`--runtime` and `--entry-point` are required with `--deploy-mode code --no-prompt`. Runtimes: `python_3_13`, `python_3_14`, `dotnet_10`, `node_22`. Prefer `--deploy-mode code` (no Docker, no ACR) unless the agent needs a custom `Dockerfile` or system-level packages; use `--deploy-mode container` only in that case. For an existing Foundry project, add `--project-id "<resourceId>"`.

### Step 4c -- (Optional) Convert an existing container scaffold to code deploy

If a project was already scaffolded with `language: docker` + `docker: remoteBuild: true` (e.g., from an older init), re-running init with `--deploy-mode code` is the cleanest fix. Otherwise convert manually:

1. **`azure.yaml`**: change `language: docker` -> `language: python` (or `csharp`/`js`/`ts`); delete the `docker:` block.
2. **`<service>/agent.yaml`**: add `code_configuration:` with `runtime`, `entry_point`, and `dependency_resolution: remote_build`.
3. **Skip ACR**: `azd env set AZD_AGENT_SKIP_ACR true` so `azd provision` doesn't create one.
4. Optional: delete the unused `Dockerfile`.

See [deploy.md](../deploy/deploy.md) for the fully `azd`-free REST direct-code path.

### Step 5 -- Run locally and iterate

> **Iterate locally before deploying.** Once the project is provisioned, `azd ai agent run` calls the Foundry model endpoint with your local credentials (`DefaultAzureCredential`), so you can change agent code freely without pushing a new agent version each time.
>
> You need two values in a `.env` file in the agent source directory:
> ```env
> FOUNDRY_PROJECT_ENDPOINT=https://<account>.services.ai.azure.com/api/projects/<project>
> AZURE_AI_MODEL_DEPLOYMENT_NAME=<model-deployment-name>
> ```
>
> Pick the path that matches the scenario:
> - **Existing project (endpoint + model from teammate, prior env, or portal)** -> create `.env` with those values, run locally, deploy later.
> - **New project, just scaffolded** -> run `azd provision` (Step 7 / [deploy.md](../deploy/deploy.md)) first to create the project + model (typically ~1 min with code deploy); then `azd env get-values` exposes the values for `.env`, and you iterate locally before `azd deploy`.

```bash
azd ai agent run                          # localhost:8088 + opens Agent Inspector
azd ai agent invoke --local "hello"       # test message (no billing)
```

First start takes 30-60 seconds. `Ctrl+C` stops the agent. For overrides (custom port, custom start command, headless), see [local-run](references/local-run.md).

### Step 6 -- Add tools (optional)

Tools attach through **toolboxes** -- bundled MCP-compatible endpoints. Flow:

1. Create the **connection** (`azd ai agent connection create ...`).
2. Create or update the **toolbox** (`azd ai toolbox create` / `connection add`).
3. Set the agent env var (`azd env set TOOLBOX_<NAME>_MCP_ENDPOINT ...`).
4. Reference it in `agent.yaml` `environment_variables[]`.
5. `azd deploy`.

Full recipes (GitHub MCP, Azure AI Search, A2A, Bing Custom) in [tools](references/tools.md).

### Step 7 -- Hand off to deploy

Once local invocation succeeds, tell the user the agent is ready and ask if they want to deploy. Read [deploy/deploy.md](../deploy/deploy.md).

## Common Guidelines

1. **Sample-first** -- always get `manifestUrl` from `azd ai agent sample list`.
2. **Prefer azd over az** -- fall back to `az` only as a last resort, with explicit consent.
3. **Don't auto-login** -- `azd auth login` opens a browser; ask the user.
4. **JSON output** -- add `--output json` to `azd ai agent` commands (not to `azd ai doc`).
5. **Two files** -- `agent.yaml` is the agent; `azure.yaml services.<name>.config` is service config. See [azd-ai-cli](references/azd-ai-cli.md).
6. **Reserved env vars** -- `FOUNDRY_*` and `AGENT_*` are platform-injected at runtime. Never set them.

## Non-Interactive / YOLO Mode

Defaults when unspecified: greenfield + Python + `azd ai agent sample list --featured-only --language python`, plus `--no-prompt` on every write, plus `--deploy-mode code --runtime python_3_13` (resolve `--entry-point` from the sample's source; fall back to `main.py` only after a quick check fails). If creating a new project and the user did not provide a project name, auto-generate one using the pattern `ai-project-<random>` (6-8 lowercase alphanumeric characters). Show the generated name to the user but do not block on confirmation. If project ID is missing and the user wants to use an existing project, stop and ask. If the manifest declares secret parameters, collect them with `ask_user` and set them via `azd env set PARAM_...` before init -- keep `--no-prompt` (do not fall into azd's interactive prompts).

## Error Handling

| Error | Fix |
|-------|-----|
| `extension not installed` | `azd extension install azure.ai.agents` |
| `not_logged_in` / `login_expired` | Ask user to run `azd auth login` |
| `not_logged_in` (azd) but `az` is logged in | Run `azd config set auth.useAzCliAuth true` so azd reuses az credentials (avoids second sign-in); or re-run `verify-environment` with `-SetAzCliAuth` / `--set-az-cli-auth` |
| `missing_project_endpoint` | Run `azd provision`, or `azd env set AZURE_AI_PROJECT_ENDPOINT <url>` |
| `project_not_found` | cwd has no `azure.yaml`; move to project root or run init |
| Secret parameter prompt under `--no-prompt` | Set the value via `azd env set PARAM_<CONN>_<KEY>` before init; keep `--no-prompt` |
| `cannot use --version with --local` | Drop `--version`, or drop `--local` to hit the deployed agent |
| `could not detect project type` | Set `startupCommand` in `azure.yaml` or pass `--start-command` |
| Local agent slow to respond | Wait 30-60 seconds on first start |

Run `azd ai agent doctor --output json` to surface failing checks with `suggestion` fields.

## Next Steps

- Deploy to Foundry -> [deploy/deploy.md](../deploy/deploy.md)
- Add tools -> [tools](references/tools.md)
- Invoke the deployed agent -> [invoke/invoke.md](../invoke/invoke.md)
- Evaluate / optimize -> [observe/observe.md](../observe/observe.md)
- Diagnose failures -> [troubleshoot/troubleshoot.md](../troubleshoot/troubleshoot.md)
