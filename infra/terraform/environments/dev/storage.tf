locals {
  app_storage_name                = "staureonappdev001"
  app_storage_resource_group_name = "rg-aureon-dev-eastus"
}

resource "azurerm_storage_account" "app_storage" {
  name                     = local.app_storage_name
  resource_group_name      = local.app_storage_resource_group_name
  location                 = "eastus"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  shared_access_key_enabled       = false

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }

  depends_on = [azurerm_private_endpoint.app_storage_blob]
}

resource "azurerm_storage_container" "insurance_documents" {
  name                  = "insurance-documents"
  storage_account_id    = azurerm_storage_account.app_storage.id
  container_access_type = "private"
}