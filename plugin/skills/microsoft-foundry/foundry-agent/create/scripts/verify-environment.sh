#!/usr/bin/env bash
# verify-environment.sh
# Verifies the local environment for creating a hosted Foundry agent with `azd ai`.
# Runs all the read-only checks in one pass and prints a single concise summary,
# so the agent does not have to run (and reason over) each azd command separately.
#
# Usage:
#   ./verify-environment.sh [--set-az-cli-auth]
#
# Flags:
#   --set-az-cli-auth   Run `azd config set auth.useAzCliAuth true` so azd reuses
#                       the Azure CLI (`az`) credentials and the user does not
#                       need to sign in twice. Writes to user-global azd config
#                       (~/.azure/config.json).
#
# Output: human-readable summary lines, each prefixed with [OK], [WARN], or [ACTION].
# Exit code: 0 if no blocking actions, 1 if at least one [ACTION] is required.

set -uo pipefail

SET_AZ_CLI_AUTH=0
for arg in "$@"; do
  case "$arg" in
    --set-az-cli-auth) SET_AZ_CLI_AUTH=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
  esac
done

ACTION_REQUIRED=0

note_ok()     { echo "[OK] $1"; }
note_warn()   { echo "[WARN] $1"; }
note_action() { echo "[ACTION] $1"; ACTION_REQUIRED=1; }

# Refresh PATH to pick up recently-installed tools (e.g. azd installed in same session)
if [ -f /etc/environment ]; then
  # shellcheck disable=SC1091
  . /etc/environment 2>/dev/null || true
fi
hash -r 2>/dev/null || true

# 1. azd present + version
if ! command -v azd >/dev/null 2>&1; then
  note_action "Azure Developer CLI (azd) is not installed. Install it from https://aka.ms/azd-install, then re-run."
  echo ""
  echo "Summary: azd missing -- cannot continue."
  exit 1
fi

AZD_VERSION="$(azd version --output json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("azd",{}).get("version","unknown"))' 2>/dev/null || echo unknown)"
note_ok "azd installed (version ${AZD_VERSION})."

# 2. Required extensions
EXT_JSON="$(azd extension list --output json 2>/dev/null || echo '[]')"
for ext in azure.ai.agents azure.ai.projects; do
  if printf '%s' "$EXT_JSON" | grep -q "$ext"; then
    note_ok "Extension '$ext' is installed."
  else
    note_action "Extension '$ext' is missing. Run: azd extension install $ext"
  fi
done

# 3. Auth status
# Optionally apply auth.useAzCliAuth first so the rest of the run reflects the flipped state.
if [ "$SET_AZ_CLI_AUTH" -eq 1 ]; then
  if azd config set auth.useAzCliAuth true >/dev/null 2>&1; then
    note_ok "Set auth.useAzCliAuth=true (azd will now reuse az CLI credentials)."
  else
    note_warn "Failed to set auth.useAzCliAuth=true. Continuing with current setting."
  fi
fi

# Detect current azd auth mode (silently — returns non-zero if unset).
USE_AZ_CLI_AUTH_RAW="$(azd config get auth.useAzCliAuth 2>/dev/null || true)"
case "$USE_AZ_CLI_AUTH_RAW" in
  true|True|TRUE) USE_AZ_CLI_AUTH=1 ;;
  *)              USE_AZ_CLI_AUTH=0 ;;
esac

if azd auth login --check-status >/dev/null 2>&1; then
  if [ "$USE_AZ_CLI_AUTH" -eq 1 ]; then
    note_ok "Logged in to azd (using az CLI credentials, auth.useAzCliAuth=true)."
  else
    note_ok "Logged in to azd."
  fi
else
  # azd not authenticated -- see if `az` is, and suggest the cheapest fix.
  if az account show >/dev/null 2>&1; then
    AZ_LOGGED_IN=1
  else
    AZ_LOGGED_IN=0
  fi
  if [ "$AZ_LOGGED_IN" -eq 1 ] && [ "$USE_AZ_CLI_AUTH" -eq 0 ]; then
    note_action "azd is not authenticated, but 'az' is. To reuse your az login (no second browser sign-in), run: azd config set auth.useAzCliAuth true   -- or re-run this script with --set-az-cli-auth."
  elif [ "$AZ_LOGGED_IN" -eq 1 ] && [ "$USE_AZ_CLI_AUTH" -eq 1 ]; then
    note_action "auth.useAzCliAuth=true but az credentials are not usable by azd. Ask the user to run 'az login' to refresh."
  else
    note_action "Not logged in. Ask the user to run 'azd auth login' (or 'az login' if auth.useAzCliAuth=true). Never run it for them; it opens a browser."
  fi
fi

# 4. Foundry project endpoint (optional at this stage)
PROJECT_JSON="$(azd ai project show --output json 2>/dev/null || echo '')"
ENDPOINT=""
if [ -n "$PROJECT_JSON" ]; then
  ENDPOINT="$(printf '%s' "$PROJECT_JSON" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
if isinstance(d,dict):
    for k in ("endpoint","projectEndpoint","aiProjectEndpoint"):
        if d.get(k):
            print(d[k]); break
' 2>/dev/null)"
fi
if [ -n "$ENDPOINT" ]; then
  note_ok "Foundry project endpoint configured: ${ENDPOINT}"
else
  note_warn "No Foundry project endpoint set yet. A new project will be created at provision/deploy time, or supply an existing project resource ID."
fi

# 5. Agent deployment status
AGENT_JSON="$(azd ai agent show --output json 2>/dev/null || echo '')"
if [ -n "$AGENT_JSON" ]; then
  STATUS="$(printf '%s' "$AGENT_JSON" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit
print(d.get("status","unknown") if isinstance(d,dict) else "unknown")' 2>/dev/null)"
  case "$STATUS" in
    active|deployed) note_ok "An agent is already deployed (status: ${STATUS}). Skip to deploy.md to redeploy, or tools to add a tool." ;;
    not_deployed)    note_ok "No agent deployed yet (status: not_deployed). Proceed with create." ;;
    *)               note_warn "Agent status: ${STATUS}." ;;
  esac
else
  note_ok "No agent deployed yet. Proceed with create."
fi

echo ""
if [ "$ACTION_REQUIRED" -eq 1 ]; then
  echo "Summary: action required -- resolve the [ACTION] items above before continuing."
  exit 1
else
  echo "Summary: environment ready for 'azd ai' hosted-agent creation."
  exit 0
fi
