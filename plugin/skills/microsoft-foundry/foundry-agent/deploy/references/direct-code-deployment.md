# Direct Code Deployment Reference

Use this reference only when the user explicitly requested direct code deployment (e.g. *"direct-code deployment"*, *"upload code deployment"*, *"deploy by uploading source code"*).

This reference covers only direct-code deployment from [deploy.md](../deploy.md) Step 3. After deployment completes, proceed directly back to [deploy.md Step 7: Test the Agent](../deploy.md#step-7-test-the-agent).

## Command

Direct code deployment is handled by `foundry agent deploy --method zip`. The CLI bundles the project, uploads the zip, creates / versions the agent, and polls until the agent record is registered. It is the default method when there is no `Dockerfile` and no `--image` flag, so passing `--method zip` is only required to be explicit.

```bash
foundry agent deploy --method zip
```

Key flags:

| Flag | Purpose |
|------|---------|
| `--source <path>` | Folder to zip (default: the deploy path). |
| `--runtime <id>` | Force a specific runtime (e.g. `python_3_14`, `dotnet_10`). The CLI picks a default per detected project type otherwise. |
| `--entrypoint <cmd>` | Override the runtime's default entrypoint, as a quoted shell command. |
| `--package-mode <local\|remote>` | Dependency resolution (default `remote`). `remote` ships source + manifest and lets Foundry install on the server; `local` ships pre-bundled dependencies. |
| `--package-cmd <shell>` | Override the `pip` / `dotnet publish` command used in `--package-mode local`. |
| `--env KEY=VALUE`, `--env-file <path>` | Same env-var precedence as `container` deploys (see [deploy.md Step 2](../deploy.md#step-2-collect-and-confirm-environment-variables)). |
| `--no-update-if-exists` | Fail instead of pushing a new version when the agent already exists. |
| `--dry-run` | Resolve and validate config; print the plan; no upload. |

The CLI handles authentication (`DefaultAzureCredential`), preflight checks, zip layout, SHA-256 calculation, multipart upload, version creation, and status polling internally.

## Runtime / Entrypoint Quick Reference

When letting the CLI pick automatically, it follows the project-type detection rules in [deploy.md Step 1](../deploy.md#step-1-detect-and-scan-project). When you want to override, the supported runtime ids today are:

| Project Type | Runtime ids | Default entrypoint |
|--------------|-------------|--------------------|
| Python | `python_3_13`, `python_3_14` | `python main.py` |
| C# / .NET | `dotnet_8`, `dotnet_9`, `dotnet_10` | `dotnet <AssemblyName>.dll` |

Notes:

- For Python, prefer the runtime explicitly declared in `agent.yaml` / `agent.manifest.yaml`. `python_3_11` and `python_3_12` are not supported in the direct-code preview path.
- For .NET, the `TargetFramework` in `*.csproj` must match the chosen `dotnet_*` runtime (`net8.0` → `dotnet_8`, `net9.0` → `dotnet_9`, `net10.0` → `dotnet_10`).
- For .NET, never use `dotnet run` as the entrypoint — the runtime image has the .NET runtime, not the SDK, and `dotnet run` fails with `No .NET SDKs were found`. Use `dotnet <AssemblyName>.dll`.

## What Gets Packaged

The CLI zips the source folder (`--source`, default the deploy path) and excludes common local artifacts. Make sure the following are **not** committed to your project root in a way that would inflate the bundle:

```text
.env
.foundry/
.git/
.vscode/
.venv/
__pycache__/
bin/
obj/
Dockerfile
.dockerignore
docker-compose.yml
Properties/launchSettings.json
```

For **remote packaging** (default), include the dependency manifest (`requirements.txt`, `pyproject.toml`, `*.csproj`) — the service installs dependencies during the remote build. Do not pre-bundle a `packages/` folder.

For **local packaging** (`--package-mode local`), pre-build dependencies for Linux x64 that match the selected runtime, and avoid Windows binaries.

## Reserved Environment Variables

Do not set or override the variables listed in the create sub-skill's [Reserved Environment Variables](../../create/create-hosted.md#common-guidelines) section (e.g. `FOUNDRY_*`, `PORT`, `HOME`). The Foundry platform injects them at startup. If your code reads them, just read — do not include them in `--env` / `.env`.

## Below the CLI (Azure MCP / REST Fallback)

Use these only when the `foundry` CLI cannot do what you need (e.g. you need to update an existing agent in place without bumping the version, or download an existing code zip for inspection):

| Purpose | Tool |
|---------|------|
| Inspect agent / list versions / download code zip | REST API (`GET <project-endpoint>/agents/<agent-name>` and related endpoints with `Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview`). |
| In-place update without a new version | Azure MCP `agent_update` against the named agent. |
| Delete an agent | Azure MCP `agent_delete`. |

Refer to the version of this document in git history for the full raw REST recipe if you have to hand-roll a multipart upload.
