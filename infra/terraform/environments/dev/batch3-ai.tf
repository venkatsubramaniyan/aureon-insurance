variable "ai" {
  description = "Approved OpenAI deployments and Search capacity. null leaves Batch 3 disabled."
  type = object({
    openai_name = string
    search_name = string
    search_sku  = string
    deployments = map(object({
      model    = string
      version  = string
      sku      = string
      capacity = number
    }))
  })
  default = null

  validation {
    condition = var.ai == null ? true : (
      contains(["basic", "standard", "standard2", "standard3"], var.ai.search_sku) &&
      length(var.ai.deployments) > 0 &&
      alltrue([for d in values(var.ai.deployments) : d.capacity >= 1 && floor(d.capacity) == d.capacity && trimspace(d.version) != ""])
    )
    error_message = "Use a private-link-capable Search SKU and supply approved, versioned OpenAI deployments with positive integer capacity."
  }
}

variable "workload_dns_zone_ids" {
  description = "Existing linked private DNS zone IDs by DNS zone name. Only omit a key when creation of a new zone and link is approved."
  type        = map(string)
  default     = {}
}

data "azurerm_virtual_network" "workloads" {
  count               = var.ai != null || var.registry_name != null || var.container_apps != null || var.frontend != null || var.monitoring != null || var.batch4_postgresql != null || var.batch4_managed_redis != null ? 1 : 0
  name                = data.azurerm_subnet.private_endpoints.virtual_network_name
  resource_group_name = local.app_storage_resource_group_name
}

locals {
  workload_location = try(data.azurerm_virtual_network.workloads[0].location, null)
  workload_tags     = azurerm_storage_account.app_storage.tags
  workload_endpoints = merge(
    var.ai == null ? {} : {
      openai = "privatelink.openai.azure.com"
      search = "privatelink.search.windows.net"
    },
    var.registry_name == null ? {} : { registry = "privatelink.azurecr.io" },
    var.monitoring == null ? {} : {
      monitor  = "privatelink.monitor.azure.com"
      oms      = "privatelink.oms.opinsights.azure.com"
      ods      = "privatelink.ods.opinsights.azure.com"
      agent    = "privatelink.agentsvc.azure-automation.net"
      mon_blob = "privatelink.blob.core.windows.net"
    },
  )
  workload_endpoint_targets = merge(
    var.ai == null ? {} : {
      openai = { id = azurerm_cognitive_account.openai[0].id, group = "account" }
      search = { id = azurerm_search_service.documents[0].id, group = "searchService" }
    },
    var.registry_name == null ? {} : {
      registry = { id = azurerm_container_registry.workloads[0].id, group = "registry" }
    },
  )
  workload_zones = toset(values(local.workload_endpoints))
  reused_workload_zones = merge(var.workload_dns_zone_ids, {
    "privatelink.blob.core.windows.net" = data.azurerm_private_dns_zone.blob.id
  })
  workload_zone_ids = merge(local.reused_workload_zones, {
    for zone, resource in azurerm_private_dns_zone.workloads : zone => resource.id
  })
}

resource "azurerm_private_dns_zone" "workloads" {
  for_each            = setsubtract(local.workload_zones, toset(keys(local.reused_workload_zones)))
  name                = each.key
  resource_group_name = local.app_storage_resource_group_name
  tags                = local.workload_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "workloads" {
  for_each              = azurerm_private_dns_zone.workloads
  name                  = "aureon-workloads"
  resource_group_name   = each.value.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = data.azurerm_virtual_network.workloads[0].id
}

resource "azurerm_private_endpoint" "workloads" {
  for_each            = local.workload_endpoint_targets
  name                = "pe-${each.key}-${local.workload_tags.environment}"
  location            = local.workload_location
  resource_group_name = local.app_storage_resource_group_name
  subnet_id           = data.azurerm_subnet.private_endpoints.id
  tags                = local.workload_tags

  private_service_connection {
    name                           = each.key
    private_connection_resource_id = each.value.id
    subresource_names              = [each.value.group]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.workload_zone_ids[local.workload_endpoints[each.key]]]
  }
}

resource "azurerm_cognitive_account" "openai" {
  count                         = var.ai == null ? 0 : 1
  name                          = var.ai.openai_name
  custom_subdomain_name         = var.ai.openai_name
  resource_group_name           = local.app_storage_resource_group_name
  location                      = local.workload_location
  kind                          = "OpenAI"
  sku_name                      = "S0"
  public_network_access_enabled = false
  local_auth_enabled            = false
  tags                          = local.workload_tags
}

resource "azurerm_cognitive_deployment" "models" {
  for_each             = var.ai == null ? {} : var.ai.deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.openai[0].id

  model {
    format  = "OpenAI"
    name    = each.value.model
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

resource "azurerm_search_service" "documents" {
  count                         = var.ai == null ? 0 : 1
  name                          = var.ai.search_name
  resource_group_name           = local.app_storage_resource_group_name
  location                      = local.workload_location
  sku                           = var.ai.search_sku
  public_network_access_enabled = false
  local_authentication_enabled  = false
  replica_count                 = 1
  partition_count               = 1
  tags                          = local.workload_tags
}
