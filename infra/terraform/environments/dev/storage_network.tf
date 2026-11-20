data "azurerm_client_config" "current" {}

data "azurerm_subnet" "private_endpoints" {
  name                 = "snet-aureon-private-endpoints-dev"
  virtual_network_name = "vnet-aureon-dev-eastus"
  resource_group_name  = "rg-aureon-dev-eastus"
}

data "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "rg-aureon-dev-eastus"
}

resource "azurerm_private_endpoint" "app_storage_blob" {
  name                = "pe-aureon-app-storage-dev"
  location            = "eastus"
  resource_group_name = "rg-aureon-dev-eastus"
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name = "psc-aureon-app-storage-blob-dev"
    # This account already exists; using its ID avoids a dependency cycle during lockdown.
    private_connection_resource_id = format(
      "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s",
      data.azurerm_client_config.current.subscription_id,
      local.app_storage_resource_group_name,
      local.app_storage_name,
    )
    subresource_names    = ["blob"]
    is_manual_connection = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.blob.id]
  }

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }
}
