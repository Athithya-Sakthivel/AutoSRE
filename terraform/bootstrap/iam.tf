# ------------------------------------------------------------------------------
# Azure identities and Azure DevOps service connections.
# CI and CD are separate principals for clear permissions.
# ------------------------------------------------------------------------------

data "azuread_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  tenant_id  = data.azurerm_subscription.current.tenant_id
  issuer_url = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"

  ci_app_name = "id-azdo-oidc-${var.github_repo}-ci"
  cd_app_name = "id-azdo-oidc-${var.github_repo}-cd"
}

# ------------------------------------------------------------------------------
# CI identity
# ------------------------------------------------------------------------------

resource "azuread_application" "ci" {
  display_name = local.ci_app_name
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
  display_name = local.cd_app_name
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "cd" {
  client_id = azuread_application.cd.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# ------------------------------------------------------------------------------
# Azure DevOps Azure service connections
# (must be created BEFORE the federated credentials)
# ------------------------------------------------------------------------------

resource "azuredevops_serviceendpoint_azurerm" "ci" {
  project_id                             = azuredevops_project.this.id
  service_endpoint_name                  = "azdo-oidc-ci"
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                  = local.tenant_id
  azurerm_subscription_id               = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name             = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid = azuread_service_principal.ci.client_id
  }
}

resource "azuredevops_serviceendpoint_azurerm" "cd" {
  project_id                             = azuredevops_project.this.id
  service_endpoint_name                  = "azdo-oidc-cd"
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                  = local.tenant_id
  azurerm_subscription_id               = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name             = data.azurerm_subscription.current.display_name

  credentials {
    serviceprincipalid = azuread_service_principal.cd.client_id
  }
}

# ------------------------------------------------------------------------------
# Federated Identity Credentials – using Entra issuer (matches service connections)
# ------------------------------------------------------------------------------

resource "azuread_application_federated_identity_credential" "ci" {
  application_id = azuread_application.ci.id
  display_name   = "azdo-oidc-ci"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.issuer_url   #  Entra issuer – matches service connection
  subject        = azuredevops_serviceendpoint_azurerm.ci.workload_identity_federation_subject
}

resource "azuread_application_federated_identity_credential" "cd" {
  application_id = azuread_application.cd.id
  display_name   = "azdo-oidc-cd"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.issuer_url   # Entra issuer – matches service connection
  subject        = azuredevops_serviceendpoint_azurerm.cd.workload_identity_federation_subject
}

# ------------------------------------------------------------------------------
# Azure RBAC (unchanged)
# ------------------------------------------------------------------------------

resource "azurerm_role_assignment" "ci_reader" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id        = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "ci_acr_push" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "AcrPush"
  principal_id        = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "ci_tfstate" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id        = azuread_service_principal.ci.object_id
}

resource "azurerm_role_assignment" "cd_contributor" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id        = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_rbac_admin" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id        = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_acr_pull" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "AcrPull"
  principal_id        = azuread_service_principal.cd.object_id
}

resource "azurerm_role_assignment" "cd_tfstate" {
  scope               = data.azurerm_subscription.current.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id        = azuread_service_principal.cd.object_id
}