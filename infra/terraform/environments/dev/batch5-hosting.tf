variable "registry_name" {
  description = "Approved globally unique name for the private Premium registry. null disables registry creation."
  type        = string
  default     = null
}

variable "container_apps" {
  description = "Approved dedicated ACA subnet and environment name. Workloads are deployed separately after images are published."
  type = object({
    name        = string
    subnet_name = string
    subnet_cidr = string
  })
  default = null

  validation {
    condition     = var.container_apps == null ? true : try(cidrnetmask(var.container_apps.subnet_cidr) != "" && tonumber(split("/", var.container_apps.subnet_cidr)[1]) <= 27, false)
    error_message = "Supply an approved IPv4 subnet of /27 or larger for the workload profiles environment."
  }
}

variable "workload_images" {
  description = "Role-specific images in the new ACR, pinned by digest. Keys are api and ingestion. Key Vault secret IDs are optional ARM IDs, never values."
  type = map(object({
    name                 = string
    image                = string
    cpu                  = number
    memory               = string
    max_replicas         = number
    port                 = optional(number)
    use_managed_redis    = optional(bool, false)
    key_vault_secret_ids = optional(set(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for key, app in var.workload_images :
      contains(["api", "ingestion"], key) &&
      can(regex("^[a-z0-9][a-z0-9/._-]*@sha256:[a-f0-9]{64}$", app.image)) &&
      (key == "api" ? try(app.port >= 1 && app.port <= 65535 && floor(app.port) == app.port, false) : app.port == null) &&
      app.max_replicas >= 1 && floor(app.max_replicas) == app.max_replicas &&
      (key != "ingestion" || app.max_replicas == 1) &&
      (!app.use_managed_redis || (key == "api" && var.batch4_managed_redis != null)) &&
      alltrue([for id in app.key_vault_secret_ids : can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/rg-aureon-dev-eastus/providers/Microsoft.KeyVault/vaults/kv-aureon-dev-eastus/secrets/[^/]+$", id))])
    ])
    error_message = "Use digest-pinned images, an API-only port and Redis opt-in, exactly one ingestion replica, and existing Aureon Key Vault secret ARM scopes."
  }

  validation {
    condition     = length(var.workload_images) == 0 || (var.container_apps != null && var.registry_name != null && var.ai != null)
    error_message = "Workloads require the Container Apps environment, private registry, and AI configuration."
  }
}

variable "deploy_workloads" {
  description = "Create app revisions after image publishing, identity propagation and data bootstrap. Keep false during identity preparation."
  type        = bool
  default     = false

  validation {
    condition     = !var.deploy_workloads || length(var.workload_images) > 0
    error_message = "Supply at least one approved workload image before deploying workloads."
  }
}

resource "azurerm_container_registry" "workloads" {
  count                                        = var.registry_name == null ? 0 : 1
  name                                         = var.registry_name
  resource_group_name                          = local.app_storage_resource_group_name
  location                                     = local.workload_location
  sku                                          = "Premium"
  admin_enabled                                = false
  public_network_access_enabled                = false
  network_rule_bypass_option                   = "None"
  role_assignment_mode                         = "LegacyRegistryPermissions"
  azuread_authentication_as_arm_policy_enabled = true
  tags                                         = local.workload_tags
}

resource "azurerm_subnet" "container_apps" {
  count                = var.container_apps == null ? 0 : 1
  name                 = var.container_apps.subnet_name
  resource_group_name  = local.app_storage_resource_group_name
  virtual_network_name = data.azurerm_subnet.private_endpoints.virtual_network_name
  address_prefixes     = [var.container_apps.subnet_cidr]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_container_app_environment" "workloads" {
  count                          = var.container_apps == null ? 0 : 1
  name                           = var.container_apps.name
  resource_group_name            = local.app_storage_resource_group_name
  location                       = local.workload_location
  infrastructure_subnet_id       = azurerm_subnet.container_apps[0].id
  internal_load_balancer_enabled = true
  public_network_access          = "Disabled"
  logs_destination               = "azure-monitor"
  tags                           = local.workload_tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_private_dns_zone" "container_apps" {
  count               = var.container_apps == null ? 0 : 1
  name                = azurerm_container_app_environment.workloads[0].default_domain
  resource_group_name = local.app_storage_resource_group_name
  tags                = local.workload_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "container_apps" {
  count                 = var.container_apps == null ? 0 : 1
  name                  = "aureon-workloads"
  resource_group_name   = local.app_storage_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.container_apps[0].name
  virtual_network_id    = data.azurerm_virtual_network.workloads[0].id
}

resource "azurerm_private_dns_a_record" "container_apps" {
  count               = var.container_apps == null ? 0 : 1
  name                = "*"
  zone_name           = azurerm_private_dns_zone.container_apps[0].name
  resource_group_name = local.app_storage_resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.workloads[0].static_ip_address]
}

resource "azurerm_user_assigned_identity" "workloads" {
  for_each            = var.workload_images
  name                = "id-aureon-${each.key}-${local.workload_tags.environment}"
  resource_group_name = local.app_storage_resource_group_name
  location            = local.workload_location
  tags                = local.workload_tags
}

locals {
  workload_grants = merge([
    for key, app in var.workload_images : merge({
      "${key}/pull"   = { app = key, role = "AcrPull", scope = azurerm_container_registry.workloads[0].id }
      "${key}/openai" = { app = key, role = "Cognitive Services OpenAI User", scope = azurerm_cognitive_account.openai[0].id }
      "${key}/search" = {
        app   = key
        role  = key == "api" ? "Search Index Data Reader" : "Search Index Data Contributor"
        scope = azurerm_search_service.documents[0].id
      }
      }, key == "ingestion" ? {
      "ingestion/queue" = { app = key, role = "Azure Service Bus Data Receiver", scope = azurerm_servicebus_queue.ingestion.id }
      "ingestion/blob"  = { app = key, role = "Storage Blob Data Reader", scope = azurerm_storage_container.insurance_documents.id }
      } : {}, {
      for id in app.key_vault_secret_ids : "${key}/vault/${lower(id)}" => {
        app = key, role = "Key Vault Secrets User", scope = id
      }
    })
  ]...)
}

resource "azurerm_role_assignment" "workloads" {
  for_each             = local.workload_grants
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.workloads[each.value.app].principal_id
  principal_type       = "ServicePrincipal"

  lifecycle {
    precondition {
      condition = !strcontains(each.key, "/vault/") || startswith(
        lower(each.value.scope),
        "/subscriptions/${lower(data.azurerm_client_config.current.subscription_id)}/"
      )
      error_message = "Key Vault secret scopes must be in the current subscription."
    }
  }
}

resource "azurerm_managed_redis_access_policy_assignment" "api" {
  for_each         = { for key, app in var.workload_images : key => app if app.use_managed_redis }
  managed_redis_id = azurerm_managed_redis.api_cache[0].id
  object_id        = azurerm_user_assigned_identity.workloads[each.key].principal_id
}

resource "azurerm_container_app" "workloads" {
  for_each                     = var.deploy_workloads ? var.workload_images : {}
  name                         = each.value.name
  resource_group_name          = local.app_storage_resource_group_name
  container_app_environment_id = azurerm_container_app_environment.workloads[0].id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.workload_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workloads[each.key].id]
  }

  registry {
    server   = azurerm_container_registry.workloads[0].login_server
    identity = azurerm_user_assigned_identity.workloads[each.key].id
  }

  dynamic "ingress" {
    for_each = each.key == "api" ? [each.value.port] : []
    content {
      # External to the app environment, but reachable only via the internal load balancer.
      external_enabled           = true
      allow_insecure_connections = false
      target_port                = ingress.value
      traffic_weight {
        latest_revision = true
        percentage      = 100
      }
    }
  }

  template {
    min_replicas = each.key == "ingestion" ? 1 : 0
    max_replicas = each.value.max_replicas

    container {
      name   = each.key
      image  = "${azurerm_container_registry.workloads[0].login_server}/${each.value.image}"
      cpu    = each.value.cpu
      memory = each.value.memory

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.workloads[each.key].client_id
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.workloads,
    azurerm_managed_redis_access_policy_assignment.api,
    azurerm_private_endpoint.workloads,
    azurerm_private_dns_zone_virtual_network_link.workloads,
  ]
}
