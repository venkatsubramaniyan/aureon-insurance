variable "batch4_postgresql" {
  description = "Nullable PostgreSQL Flexible Server configuration. Null disables Batch 4 PostgreSQL."
  type = object({
    name                  = string
    version               = string
    sku_name              = string
    storage_mb            = number
    backup_retention_days = number
    geo_redundant_backup  = optional(bool, false)
    delegated_subnet_cidr = string
    bootstrap_admin_group = object({
      object_id      = string
      principal_name = string
    })
    private_dns_zone_id = optional(string)
  })
  default  = null
  nullable = true

  validation {
    condition = var.batch4_postgresql == null ? true : (
      trimspace(var.batch4_postgresql.name) != "" &&
      trimspace(var.batch4_postgresql.version) != "" &&
      trimspace(var.batch4_postgresql.sku_name) != "" &&
      can(cidrnetmask(var.batch4_postgresql.delegated_subnet_cidr)) &&
      tonumber(split("/", var.batch4_postgresql.delegated_subnet_cidr)[1]) <= 28 &&
      var.batch4_postgresql.backup_retention_days >= 7 &&
      var.batch4_postgresql.backup_retention_days <= 35 &&
      floor(var.batch4_postgresql.backup_retention_days) == var.batch4_postgresql.backup_retention_days &&
      trimspace(var.batch4_postgresql.bootstrap_admin_group.object_id) != "" &&
      trimspace(var.batch4_postgresql.bootstrap_admin_group.principal_name) != "" &&
      (
        var.batch4_postgresql.private_dns_zone_id == null ||
        trimspace(var.batch4_postgresql.private_dns_zone_id) != ""
      )
    )
    error_message = "PostgreSQL requires non-empty names, an IPv4 delegated subnet CIDR of /28 or larger, 7-35 backup retention days, a bootstrap Entra group object ID and name, and a non-empty existing DNS zone ID when provided."
  }
}

variable "batch4_managed_redis" {
  description = "Nullable Azure Managed Redis configuration. Null disables Batch 4 Managed Redis."
  type = object({
    name                = string
    sku_name            = string
    private_dns_zone_id = optional(string)
    clustering_policy   = optional(string, "OSSCluster")
  })
  default  = null
  nullable = true

  validation {
    condition = var.batch4_managed_redis == null ? true : (
      trimspace(var.batch4_managed_redis.name) != "" &&
      trimspace(var.batch4_managed_redis.sku_name) != "" &&
      contains(["EnterpriseCluster", "OSSCluster", "NoCluster"], var.batch4_managed_redis.clustering_policy) &&
      (
        var.batch4_managed_redis.private_dns_zone_id == null ||
        trimspace(var.batch4_managed_redis.private_dns_zone_id) != ""
      )
    )
    error_message = "Managed Redis requires a name, SKU, supported clustering policy, and a non-empty existing DNS zone ID when provided."
  }
}

resource "azurerm_subnet" "postgresql" {
  count                = var.batch4_postgresql == null ? 0 : 1
  name                 = "snet-aureon-postgresql-dev"
  resource_group_name  = local.app_storage_resource_group_name
  virtual_network_name = data.azurerm_subnet.private_endpoints.virtual_network_name
  address_prefixes     = [var.batch4_postgresql.delegated_subnet_cidr]

  delegation {
    name = "postgresql-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgresql" {
  count               = var.batch4_postgresql == null || var.batch4_postgresql.private_dns_zone_id != null ? 0 : 1
  name                = "aureon-dev.postgres.database.azure.com"
  resource_group_name = local.app_storage_resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  count                 = var.batch4_postgresql == null || var.batch4_postgresql.private_dns_zone_id != null ? 0 : 1
  name                  = "vnet-link-aureon-postgresql-dev"
  private_dns_zone_name = azurerm_private_dns_zone.postgresql[0].name
  resource_group_name   = local.app_storage_resource_group_name
  virtual_network_id    = data.azurerm_virtual_network.workloads[0].id
  registration_enabled  = false
}

resource "azurerm_postgresql_flexible_server" "app" {
  count               = var.batch4_postgresql == null ? 0 : 1
  name                = var.batch4_postgresql.name
  resource_group_name = local.app_storage_resource_group_name
  location            = local.workload_location

  version                      = var.batch4_postgresql.version
  sku_name                     = var.batch4_postgresql.sku_name
  storage_mb                   = var.batch4_postgresql.storage_mb
  backup_retention_days        = var.batch4_postgresql.backup_retention_days
  geo_redundant_backup_enabled = var.batch4_postgresql.geo_redundant_backup

  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.postgresql[0].id
  private_dns_zone_id = (
    var.batch4_postgresql.private_dns_zone_id != null
    ? var.batch4_postgresql.private_dns_zone_id
    : azurerm_private_dns_zone.postgresql[0].id
  )

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgresql]
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "bootstrap_group" {
  count               = var.batch4_postgresql == null ? 0 : 1
  server_name         = azurerm_postgresql_flexible_server.app[0].name
  resource_group_name = local.app_storage_resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.batch4_postgresql.bootstrap_admin_group.object_id
  principal_name      = var.batch4_postgresql.bootstrap_admin_group.principal_name
  principal_type      = "Group"
}

resource "azurerm_private_dns_zone" "managed_redis" {
  count               = var.batch4_managed_redis == null || var.batch4_managed_redis.private_dns_zone_id != null ? 0 : 1
  name                = "privatelink.redis.azure.net"
  resource_group_name = local.app_storage_resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "managed_redis" {
  count                 = var.batch4_managed_redis == null || var.batch4_managed_redis.private_dns_zone_id != null ? 0 : 1
  name                  = "vnet-link-aureon-managed-redis-dev"
  private_dns_zone_name = azurerm_private_dns_zone.managed_redis[0].name
  resource_group_name   = local.app_storage_resource_group_name
  virtual_network_id    = data.azurerm_virtual_network.workloads[0].id
  registration_enabled  = false
}

resource "azurerm_managed_redis" "api_cache" {
  count               = var.batch4_managed_redis == null ? 0 : 1
  name                = var.batch4_managed_redis.name
  resource_group_name = local.app_storage_resource_group_name
  location            = local.workload_location
  sku_name            = var.batch4_managed_redis.sku_name

  public_network_access = "Disabled"

  default_database {
    access_keys_authentication_enabled = false
    client_protocol                    = "Encrypted"
    clustering_policy                  = var.batch4_managed_redis.clustering_policy
  }

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }
}

resource "azurerm_private_endpoint" "managed_redis" {
  count               = var.batch4_managed_redis == null ? 0 : 1
  name                = "pe-aureon-managed-redis-dev"
  location            = local.workload_location
  resource_group_name = local.app_storage_resource_group_name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-aureon-managed-redis-dev"
    private_connection_resource_id = azurerm_managed_redis.api_cache[0].id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      var.batch4_managed_redis.private_dns_zone_id != null
      ? var.batch4_managed_redis.private_dns_zone_id
      : azurerm_private_dns_zone.managed_redis[0].id
    ]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.managed_redis]
}
