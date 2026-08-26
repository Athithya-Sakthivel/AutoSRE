#!/usr/bin/env bash
set -uo pipefail

# -----------------------------------------------------------------------------
# Temporary Azure resources for local development.
#
# Creates/reuses:
#   - Resource Group
#   - Azure Key Vault using Azure RBAC
#   - Log Analytics workspace
#   - Application Insights (workspace-based)
#   - Key Vault secrets
#
# Requirements:
#   - Azure CLI >= 2.71.0
#   - Logged-in identity must be able to:
#       * create/update resources in the target resource group
#       * create/update Azure RBAC role assignments on the Key Vault
#
# IMPORTANT:
#   The Key Vault secret values below are development credentials only.
#   Do not commit real production credentials to source control.
# -----------------------------------------------------------------------------

# -----------------------------
# Configuration
# -----------------------------

LOCATION="eastus"

SUB_ID="$(az account show --query id --output tsv)"
SUB_LAST4="${SUB_ID: -4}"

RG="temp-az-${SUB_LAST4}"
KV="az-temp-kv-101"
AI="task-api-insights"
LAW="task-api-logs-${SUB_LAST4}"          # Log Analytics workspace name

# Development-only values.
DB_PASSWORD="bulZpXGOiFOORRLRs6V+24gv/egWbQQVzdDT1wcwghU="
JWT_SECRET="K43DB0QpZzitfSFr9zGoQSfDglm8ahRmerCDzwBbzIT26tB9xCYP7sVhCmV/PBWNLKq2aAks57AbDWEcjNju1w=="
DB_URL="jdbc:postgresql://127.0.0.1:5432/taskdb"   # Will be overwritten by e2e script
DB_USERNAME="taskuser"

# Microsoft built-in role ID for Key Vault Secrets Officer.
# Using the stable role ID avoids depending on role-name changes.
KEY_VAULT_SECRETS_OFFICER_ROLE_ID="b86a8fe4-44ce-4948-aee5-eccb2c155cd7"


# -----------------------------
# Preconditions
# -----------------------------

command -v az >/dev/null 2>&1 || {
    echo "ERROR: Azure CLI (az) is not installed." >&2
    exit 1
}

az account show --output none || {
    echo "ERROR: Azure CLI is not logged in. Run: az login" >&2
    exit 1
}

CALLER_OBJECT_ID="$(
    az ad signed-in-user show \
        --query id \
        --output tsv
)"

if [[ -z "$CALLER_OBJECT_ID" ]]; then
    echo "ERROR: Could not determine the signed-in user's object ID." >&2
    exit 1
fi

# -----------------------------
# Azure CLI extension
# -----------------------------

az extension add \
    --name application-insights \
    --upgrade \
    --yes \
    --only-show-errors \
    --output none

EXT_VERSION="$(
    az extension show \
        --name application-insights \
        --query version \
        --output tsv
)"

if [[ -z "$EXT_VERSION" ]]; then
    echo "ERROR: Could not determine application-insights extension version." >&2
    exit 1
fi

echo "Application Insights CLI extension: ${EXT_VERSION}"

# -----------------------------
# Resource Group
# -----------------------------

echo "Ensuring resource group exists: ${RG}"

az group create \
    --name "$RG" \
    --location "$LOCATION" \
    --output none

# -----------------------------
# Key Vault
# -----------------------------

echo "Ensuring Key Vault exists: ${KV}"

if ! az keyvault show \
    --name "$KV" \
    --resource-group "$RG" \
    --output none 2>/dev/null; then

    az keyvault create \
        --name "$KV" \
        --resource-group "$RG" \
        --location "$LOCATION" \
        --enable-rbac-authorization true \
        --enable-purge-protection true \
        --output none
fi

KV_ID="$(
    az keyvault show \
        --name "$KV" \
        --resource-group "$RG" \
        --query id \
        --output tsv
)"

if [[ -z "$KV_ID" ]]; then
    echo "ERROR: Failed to resolve Key Vault resource ID." >&2
    exit 1
fi

RBAC_ENABLED="$(
    az keyvault show \
        --name "$KV" \
        --resource-group "$RG" \
        --query properties.enableRbacAuthorization \
        --output tsv
)"

if [[ "$RBAC_ENABLED" != "true" ]]; then
    echo "ERROR: Key Vault '${KV}' is not using Azure RBAC authorization." >&2
    exit 1
fi

# -----------------------------
# Grant current user permission
# -----------------------------

echo "Ensuring current user can write Key Vault secrets."

ROLE_ASSIGNMENT_EXISTS="$(
    az role assignment list \
        --assignee-object-id "$CALLER_OBJECT_ID" \
        --scope "$KV_ID" \
        --role "$KEY_VAULT_SECRETS_OFFICER_ROLE_ID" \
        --query "[?principalId=='${CALLER_OBJECT_ID}'] | length(@)" \
        --output tsv
)"

if [[ "${ROLE_ASSIGNMENT_EXISTS:-0}" == "0" ]]; then
    echo "Creating Key Vault Secrets Officer assignment."
    az role assignment create \
        --assignee-object-id "$CALLER_OBJECT_ID" \
        --assignee-principal-type User \
        --role "$KEY_VAULT_SECRETS_OFFICER_ROLE_ID" \
        --scope "$KV_ID" \
        --output none
else
    echo "Key Vault Secrets Officer assignment already exists."
fi

echo "Waiting for Key Vault RBAC propagation."

MAX_ATTEMPTS=12
SLEEP_SECONDS=5

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if az keyvault secret list \
        --vault-name "$KV" \
        --query "[0:1]" \
        --output none 2>/dev/null; then
        echo "Key Vault secret access is ready."
        break
    fi

    if (( attempt == MAX_ATTEMPTS )); then
        echo "ERROR: Key Vault RBAC assignment did not become effective." >&2
        echo "Current caller object ID: ${CALLER_OBJECT_ID}" >&2
        echo "Key Vault: ${KV_ID}" >&2
        exit 1
    fi

    sleep "$SLEEP_SECONDS"
done

# -----------------------------
# Log Analytics workspace
# -----------------------------

echo "Ensuring Log Analytics workspace exists: ${LAW}"

if ! az monitor log-analytics workspace show \
    --resource-group "$RG" \
    --workspace-name "$LAW" \
    --output none 2>/dev/null; then

    az monitor log-analytics workspace create \
        --resource-group "$RG" \
        --workspace-name "$LAW" \
        --location "$LOCATION" \
        --output none
fi

LAW_RESOURCE_ID="$(
    az monitor log-analytics workspace show \
        --resource-group "$RG" \
        --workspace-name "$LAW" \
        --query id \
        --output tsv
)"

if [[ -z "$LAW_RESOURCE_ID" ]]; then
    echo "ERROR: Failed to resolve Log Analytics workspace resource ID." >&2
    exit 1
fi

echo "Log Analytics workspace: ${LAW_RESOURCE_ID}"

# -----------------------------
# Application Insights (workspace-based)
# -----------------------------

echo "Ensuring Application Insights exists: ${AI}"

# The command may return an array. We handle both possibilities.
AI_JSON="$(
    az monitor app-insights component show \
        --app "$AI" \
        --resource-group "$RG" \
        --output json 2>/dev/null
)"

# If no existing AI, create one linked to the workspace.
# If exists but wrong workspace, we'll delete and recreate to avoid stale links.
if [[ -z "$AI_JSON" || "$AI_JSON" == "[]" ]]; then
    echo "Creating new Application Insights resource linked to workspace..."
    az monitor app-insights component create \
        --app "$AI" \
        --location "$LOCATION" \
        --resource-group "$RG" \
        --kind web \
        --application-type web \
        --workspace "$LAW_RESOURCE_ID" \
        --output none
else
    # Extract workspaceResourceId robustly (array or object)
    EXISTING_LAW="$(echo "$AI_JSON" | jq -r 'if type=="array" then .[0].workspaceResourceId else .workspaceResourceId end // empty' 2>/dev/null)"
    if [[ "$EXISTING_LAW" != "$LAW_RESOURCE_ID" ]]; then
        echo "WARNING: Existing Application Insights is not linked to the desired workspace."
        echo "Recreating to ensure correct link."
        az monitor app-insights component delete \
            --app "$AI" \
            --resource-group "$RG" \
            --yes \
            --output none || true

        az monitor app-insights component create \
            --app "$AI" \
            --location "$LOCATION" \
            --resource-group "$RG" \
            --kind web \
            --application-type web \
            --workspace "$LAW_RESOURCE_ID" \
            --output none
    else
        echo "Application Insights already linked correctly."
    fi
fi

# Resolve and validate the connection string.
CONN_STR="$(
    az monitor app-insights component show \
        --app "$AI" \
        --resource-group "$RG" \
        --query connectionString \
        --output tsv
)"

if [[ -z "$CONN_STR" ]]; then
    echo "ERROR: Application Insights connection string is empty." >&2
    exit 1
fi

# -----------------------------
# Key Vault secrets
# -----------------------------

set_secret() {
    local name="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        echo "ERROR: Refusing to write empty secret: ${name}" >&2
        exit 1
    fi

    echo "Setting Key Vault secret: ${name}"

    az keyvault secret set \
        --vault-name "$KV" \
        --name "$name" \
        --value "$value" \
        --output none
}

set_secret "ApplicationInsightsConnectionString" "$CONN_STR"
set_secret "DatabaseUrl" "$DB_URL"
set_secret "DatabaseUsername" "$DB_USERNAME"
set_secret "DatabasePassword" "$DB_PASSWORD"
set_secret "JwtSecret" "$JWT_SECRET"

# -----------------------------
# Result
# -----------------------------

echo
echo "Temporary Azure resources are ready."
echo "Subscription:          ${SUB_ID}"
echo "Resource group:        ${RG}"
echo "Key Vault:             ${KV}"
echo "Log Analytics:         ${LAW}"
echo "Application Insights:  ${AI}"
echo
echo "Application Insights connection string stored in Key Vault:"
echo "  ApplicationInsightsConnectionString"