variable "monitoring" {
  description = "Private monitoring inputs. null disables Batch 7. Specify an existing action group ID and positive alert thresholds."
  type = object({
    workspace_name         = string
    insights_name          = string
    private_scope_name     = string
    action_group_id        = string
    active_message_limit   = number
    daily_ingestion_gb     = number
    search_throttle_limit  = number
    database_storage_limit = number
    cache_memory_limit     = number
  })
  default = null

  validation {
    condition = var.monitoring == null ? true : (
      can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Insights/actionGroups/[^/]+$", var.monitoring.action_group_id)) &&
      var.monitoring.active_message_limit > 0 && var.monitoring.daily_ingestion_gb > 0 &&
      alltrue([for limit in [var.monitoring.search_throttle_limit, var.monitoring.database_storage_limit, var.monitoring.cache_memory_limit] : limit >= 0 && limit < 100])
    )
    error_message = "Use an existing action group ARM ID and positive thresholds and ingestion cap."
  }
}

resource "azurerm_log_analytics_workspace" "workloads" {
  count                        = var.monitoring == null ? 0 : 1
  name                         = var.monitoring.workspace_name
  resource_group_name          = local.app_storage_resource_group_name
  location                     = local.workload_location
  sku                          = "PerGB2018"
  retention_in_days            = 30
  daily_quota_gb               = var.monitoring.daily_ingestion_gb
  local_authentication_enabled = false
  internet_ingestion_enabled   = false
  internet_query_enabled       = false
  tags                         = local.workload_tags
}

resource "azurerm_application_insights" "workloads" {
  count                        = var.monitoring == null ? 0 : 1
  name                         = var.monitoring.insights_name
  resource_group_name          = local.app_storage_resource_group_name
  location                     = local.workload_location
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.workloads[0].id
  local_authentication_enabled = false
  internet_ingestion_enabled   = false
  internet_query_enabled       = false
  tags                         = local.workload_tags
}

resource "azurerm_monitor_private_link_scope" "workloads" {
  count               = var.monitoring == null ? 0 : 1
  name                = var.monitoring.private_scope_name
  resource_group_name = local.app_storage_resource_group_name
  # Avoid blocking other Monitor resources that share the VNet's DNS.
  ingestion_access_mode = "Open"
  query_access_mode     = "Open"
  tags                  = local.workload_tags
}

resource "azurerm_monitor_private_link_scoped_service" "workloads" {
  for_each = var.monitoring == null ? toset([]) : toset(["insights", "workspace"])

  name                = each.key
  resource_group_name = local.app_storage_resource_group_name
  scope_name          = azurerm_monitor_private_link_scope.workloads[0].name
  linked_resource_id  = each.key == "insights" ? azurerm_application_insights.workloads[0].id : azurerm_log_analytics_workspace.workloads[0].id
}

resource "azurerm_private_endpoint" "monitor" {
  count               = var.monitoring == null ? 0 : 1
  name                = "pe-monitor-${local.workload_tags.environment}"
  resource_group_name = local.app_storage_resource_group_name
  location            = local.workload_location
  subnet_id           = data.azurerm_subnet.private_endpoints.id
  tags                = local.workload_tags

  private_service_connection {
    name                           = "monitor"
    private_connection_resource_id = azurerm_monitor_private_link_scope.workloads[0].id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      for key in ["monitor", "oms", "ods", "agent", "mon_blob"] :
      local.workload_zone_ids[local.workload_endpoints[key]]
    ]
  }

  depends_on = [azurerm_monitor_private_link_scoped_service.workloads]
}

locals {
  diagnostic_targets = merge(
    var.monitoring == null ? {} : {
      storage   = { id = "${azurerm_storage_account.app_storage.id}/blobServices/default", logs = ["StorageRead", "StorageWrite", "StorageDelete"], metrics = [] }
      eventgrid = { id = azurerm_eventgrid_system_topic.app_storage.id, logs = ["DeliveryFailures"], metrics = ["AllMetrics"] }
      queue     = { id = azurerm_servicebus_namespace.ingestion.id, logs = [], metrics = ["AllMetrics"] }
    },
    var.monitoring == null || var.ai == null ? {} : {
      openai = { id = azurerm_cognitive_account.openai[0].id, logs = [], metrics = ["AllMetrics"] }
      search = { id = azurerm_search_service.documents[0].id, logs = [], metrics = ["AllMetrics"] }
    },
    var.monitoring == null || var.container_apps == null ? {} : {
      hosting = { id = azurerm_container_app_environment.workloads[0].id, logs = ["ContainerAppSystemLogs"], metrics = [] }
    },
  )
  ingestion_alerts = var.monitoring == null ? {} : {
    backlog = { metric = "ActiveMessages", threshold = var.monitoring.active_message_limit }
    dlq     = { metric = "DeadletteredMessages", threshold = 0 }
  }
  platform_alerts = merge(
    var.monitoring == null ? {} : {
      eventgrid-delivery = {
        id        = azurerm_eventgrid_system_topic.app_storage.id, namespace = "Microsoft.EventGrid/systemTopics"
        metric    = "DeliveryAttemptFailCount", aggregation = "Total", threshold = 0
        dimension = { name = "EventSubscriptionName", value = azurerm_eventgrid_system_topic_event_subscription.insurance_document_created.name }
      }
      eventgrid-deadletters = {
        id        = azurerm_eventgrid_system_topic.app_storage.id, namespace = "Microsoft.EventGrid/systemTopics"
        metric    = "DeadLetteredCount", aggregation = "Total", threshold = 0
        dimension = { name = "EventSubscriptionName", value = azurerm_eventgrid_system_topic_event_subscription.insurance_document_created.name }
      }
    },
    var.monitoring == null || var.ai == null ? {} : {
      search-throttle = {
        id        = azurerm_search_service.documents[0].id, namespace = "Microsoft.Search/searchServices"
        metric    = "ThrottledSearchQueriesPercentage", aggregation = "Average", threshold = var.monitoring.search_throttle_limit
        dimension = null
      }
    },
    var.monitoring == null || var.batch4_postgresql == null ? {} : {
      postgres-storage = {
        id        = azurerm_postgresql_flexible_server.app[0].id, namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
        metric    = "storage_percent", aggregation = "Maximum", threshold = var.monitoring.database_storage_limit
        dimension = null
      }
    },
    var.monitoring == null || var.batch4_managed_redis == null ? {} : {
      redis-memory = {
        id        = azurerm_managed_redis.api_cache[0].id, namespace = "Microsoft.Cache/redisEnterprise"
        metric    = "usedmemorypercentage", aggregation = "Maximum", threshold = var.monitoring.cache_memory_limit
        dimension = null
      }
    },
    var.monitoring == null || !contains(keys(azurerm_container_app.workloads), "api") ? {} : {
      api-errors = {
        id        = azurerm_container_app.workloads["api"].id, namespace = "Microsoft.App/containerApps"
        metric    = "Requests", aggregation = "Total", threshold = 0
        dimension = { name = "statusCodeCategory", value = "5xx" }
      }
    },
  )
}

resource "azurerm_monitor_metric_alert" "platform" {
  for_each            = local.platform_alerts
  name                = "aureon-${each.key}-${local.workload_tags.environment}"
  resource_group_name = local.app_storage_resource_group_name
  scopes              = [each.value.id]
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.workload_tags

  criteria {
    metric_namespace = each.value.namespace
    metric_name      = each.value.metric
    aggregation      = each.value.aggregation
    operator         = "GreaterThan"
    threshold        = each.value.threshold
    dynamic "dimension" {
      for_each = each.value.dimension == null ? [] : [each.value.dimension]
      content {
        name     = dimension.value.name
        operator = "Include"
        values   = [dimension.value.value]
      }
    }
  }
  action {
    action_group_id = var.monitoring.action_group_id
  }
}

resource "azurerm_monitor_diagnostic_setting" "workloads" {
  for_each                   = local.diagnostic_targets
  name                       = "aureon-operational"
  target_resource_id         = each.value.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.workloads[0].id

  dynamic "enabled_log" {
    for_each = each.value.logs
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metrics
    content {
      category = enabled_metric.value
    }
  }
}

resource "azurerm_monitor_metric_alert" "ingestion" {
  for_each            = local.ingestion_alerts
  name                = "aureon-ingestion-${each.key}-${local.workload_tags.environment}"
  resource_group_name = local.app_storage_resource_group_name
  scopes              = [azurerm_servicebus_namespace.ingestion.id]
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.workload_tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = each.value.metric
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = each.value.threshold
    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = [azurerm_servicebus_queue.ingestion.name]
    }
  }
  action {
    action_group_id = var.monitoring.action_group_id
  }
}

resource "azurerm_role_assignment" "application_telemetry" {
  for_each             = var.monitoring == null ? {} : var.workload_images
  scope                = azurerm_application_insights.workloads[0].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.workloads[each.key].principal_id
  principal_type       = "ServicePrincipal"
}
