terraform {
  backend "azurerm" {
    resource_group_name  = "rg-aureon-tfstate-eastus"
    storage_account_name = "staureontfstate001"
    container_name       = "tfstate"
    key                  = "aureon-dev.tfstate"

    use_azuread_auth = true
    use_oidc         = true
  }
}