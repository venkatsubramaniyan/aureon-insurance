resource "azurerm_storage_account" "app_storage" {
  name                     = "staureonappdev001"
  resource_group_name      = "rg-aureon-dev-eastus"
  location                 = "eastus"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }
}

resource "azurerm_storage_container" "insurance_documents" {
  name                  = "insurance-documents"
  storage_account_id    = azurerm_storage_account.app_storage.id
  container_access_type = "private"
}