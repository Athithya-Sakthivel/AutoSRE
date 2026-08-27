# ------------------------------------------------------------------------------
# Azure identities, Azure DevOps WIF service connections, Azure RBAC, and
# Microsoft Entra directory role assignment.
# ------------------------------------------------------------------------------

data "azuread_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  ci_application_display_name = "bootstrap-ci"
  cd_application_display_name = "bootstrap-cd"

  ci_service_connection_name = "azdo-oidc-ci"
  cd_service_connection_name = "azdo-oidc-cd"
}

# ------------------------------------------------------------------------------
# CI identity
# ------------------------------------------------------------------------------

resource "azuread_application" "ci" {
  display_name = local.ci_application_display_name
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "ci" {
  client_id = azuread_application.ci.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# ------------------------------------------------------------------------------
# CD identity
# ------------------------------------------------------------------------------

resource "azuread_application" "cd" {
  display_name = local.cd_application_display_name
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "cd" {
  client_id = azuread_application.cd.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# ------------------------------------------------------------------------------
# Azure DevOps service connections using workload identity federation
# ------------------------------------------------------------------------------
resource "azuredevops_serviceendpoint_azurerm" "ci" {
  project_id                             = azuredevops_project.this.id
  service_endpoint_name                  = local.ci_service_connection_name
  service_endpoint_authentication_scheme  = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                   = data.azuread_client_config.current.tenant_id
  azurerm_subscription_id                = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name              = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid = azuread_service_principal.ci.client_id
  }
}

resource "azuredevops_serviceendpoint_azurerm" "cd" {
  project_id                             = azuredevops_project.this.id
  service_endpoint_name                  = local.cd_service_connection_name
  service_endpoint_authentication_scheme  = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                   = data.azuread_client_config.current.tenant_id
  azurerm_subscription_id                = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name              = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid = azuread_service_principal.cd.client_id
  }
}

# ------------------------------------------------------------------------------
# Federated Identity Credentials
# ------------------------------------------------------------------------------
resource "azuread_application_federated_identity_credential" "ci" {
  application_id = azuread_application.ci.id
  display_name   = local.ci_service_connection_name
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = azuredevops_serviceendpoint_azurerm.ci.workload_identity_federation_issuer
  subject        = azuredevops_serviceendpoint_azurerm.ci.workload_identity_federation_subject
}

resource "azuread_application_federated_identity_credential" "cd" {
  application_id = azuread_application.cd.id
  display_name   = local.cd_service_connection_name
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = azuredevops_serviceendpoint_azurerm.cd.workload_identity_federation_issuer
  subject        = azuredevops_serviceendpoint_azurerm.cd.workload_identity_federation_subject
}

# ------------------------------------------------------------------------------
# Azure RBAC for CI
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "ci_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "ci_acr_push" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "ci_tfstate" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.ci.object_id
}

# Custom role that grants only the Container Apps secret listing operations
# required by plan/refresh.
resource "azurerm_role_definition" "ci_containerapp_secrets" {
  name        = "Container App Secret Reader (CI)"
  scope       = data.azurerm_subscription.current.id
  description = "Allows listing secrets on Container Apps and Container Apps Jobs."

  permissions {
    actions = [
      "Microsoft.App/containerApps/listSecrets/action",
      "Microsoft.App/jobs/listSecrets/action",
    ]
    not_actions     = []
    data_actions    = []
    not_data_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]

  # Prevent 409 Conflict when the role already exists from a previous bootstrap
  lifecycle {
    ignore_changes = [name]
  }
}

resource "azurerm_role_assignment" "ci_containerapp_secrets" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.ci_containerapp_secrets.role_definition_resource_id
  principal_id       = azuread_service_principal.ci.object_id
}

# CI needs to read Entra ID applications during plan
resource "azuread_directory_role_assignment" "ci_directory_reader" {
  role_id             = "88d8e3e3-8f55-4a1e-953a-9b9898b8876b" # Directory Readers
  principal_object_id = azuread_service_principal.ci.object_id
}

# ------------------------------------------------------------------------------
# Azure RBAC for CD
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "cd_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_rbac_admin" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_acr_pull" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "AcrPull"
  principal_id         = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_tfstate" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.cd.object_id
}

# ------------------------------------------------------------------------------
# Microsoft Entra directory role for CD
# ------------------------------------------------------------------------------
resource "azuread_directory_role" "application_administrator" {
  display_name = "Application Administrator"
}

resource "azuread_directory_role_assignment" "cd_app_admin" {
  role_id             = azuread_directory_role.application_administrator.template_id
  principal_object_id = azuread_service_principal.cd.object_id
}

# ------------------------------------------------------------------------------
# Key Vault Secrets User – grants both CI and CD permission to read the PAT
# from the bootstrap Key Vault at pipeline runtime.
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "ci_keyvault_secrets_user" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "cd_keyvault_secrets_user" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.cd.object_id
}


resource "azurerm_role_assignment" "ci_website_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Website Contributor"
  principal_id         = azuread_service_principal.ci.object_id
}
