variable "frontend" {
  description = "Private Static Web Apps Standard site for VNet-based testing. null disables Batch 6. This does not link an API."
  type = object({
    name                        = string
    location                    = string
    reuse_partition_dns_zone    = optional(bool, false)
    existing_partition_dns_zone = optional(string)
  })
  default = null

  validation {
    condition     = var.frontend == null ? true : var.frontend.reuse_partition_dns_zone == (var.frontend.existing_partition_dns_zone != null)
    error_message = "Supply the existing linked partition DNS zone ID when reuse_partition_dns_zone is true."
  }
}

resource "azurerm_static_web_app" "chatbot" {
  count                              = var.frontend == null ? 0 : 1
  name                               = var.frontend.name
  resource_group_name                = local.app_storage_resource_group_name
  location                           = var.frontend.location
  sku_tier                           = "Standard"
  sku_size                           = "Standard"
  public_network_access_enabled      = false
  preview_environments_enabled       = false
  configuration_file_changes_enabled = true
  tags                               = local.workload_tags
}

locals {
  static_web_private_zone = var.frontend == null ? null : "privatelink.${join(".", slice(split(".", azurerm_static_web_app.chatbot[0].default_host_name), 1, length(split(".", azurerm_static_web_app.chatbot[0].default_host_name))))}"
}

resource "azurerm_private_dns_zone" "chatbot" {
  count               = var.frontend == null ? 0 : var.frontend.reuse_partition_dns_zone ? 0 : 1
  name                = local.static_web_private_zone
  resource_group_name = local.app_storage_resource_group_name
  tags                = local.workload_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "chatbot" {
  count                 = length(azurerm_private_dns_zone.chatbot)
  name                  = "aureon-workloads"
  resource_group_name   = local.app_storage_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.chatbot[0].name
  virtual_network_id    = data.azurerm_virtual_network.workloads[0].id
}

resource "azurerm_private_endpoint" "chatbot" {
  count               = var.frontend == null ? 0 : 1
  name                = "pe-chatbot-${local.workload_tags.environment}"
  resource_group_name = local.app_storage_resource_group_name
  location            = local.workload_location
  subnet_id           = data.azurerm_subnet.private_endpoints.id
  tags                = local.workload_tags

  private_service_connection {
    name                           = "chatbot"
    private_connection_resource_id = azurerm_static_web_app.chatbot[0].id
    subresource_names              = ["staticSites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      var.frontend.reuse_partition_dns_zone ? var.frontend.existing_partition_dns_zone : azurerm_private_dns_zone.chatbot[0].id
    ]
  }

  lifecycle {
    precondition {
      condition     = !var.frontend.reuse_partition_dns_zone || endswith(lower(coalesce(var.frontend.existing_partition_dns_zone, "none")), "/privatednszones/${local.static_web_private_zone}")
      error_message = "The existing Static Web Apps DNS zone must match the site hostname's assigned partition."
    }
  }
}
