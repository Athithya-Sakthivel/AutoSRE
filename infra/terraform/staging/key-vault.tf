resource "azapi_resource" "key_vault" {
  type      = "Microsoft.KeyVault/vaults@2024-11-01"
  name      = var.key_vault_name
  parent_id = data.azurerm_resource_group.staging.id
  location  = data.azurerm_resource_group.staging.location

  body = {
    properties = {
      tenantId = var.tenant_id

      enableRbacAuthorization = false

      enableSoftDelete          = true
      softDeleteRetentionInDays = 7

      # DO NOT set enablePurgeProtection. The Azure API rejects the value
      # "false". Omitting it leaves purge protection disabled, which is what
      # this staging stack requires so run.sh --destroy can free the name.

      publicNetworkAccess = "Enabled"

      sku = {
        family = "A"
        name   = "standard"
      }

      networkAcls = {
        defaultAction       = "Allow"
        bypass              = "AzureServices"
        ipRules             = []
        virtualNetworkRules = []
      }

      accessPolicies = [
        {
          tenantId = var.tenant_id
          objectId = data.azurerm_client_config.current.object_id

          permissions = {
            keys         = []
            secrets      = ["get", "list", "set", "delete", "purge", "recover"]
            certificates = []
          }
        }
      ]
    }
  }

  tags = local.tags

  schema_validation_enabled = true

  response_export_values = [
    "properties.vaultUri",
  ]

  lifecycle {
    ignore_changes = [
      body.properties.accessPolicies,
    ]
  }
}
