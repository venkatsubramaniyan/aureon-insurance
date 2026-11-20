mock_provider "azurerm" {
  override_data {
    target = data.azurerm_client_config.current
    values = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  override_data {
    target = data.azurerm_subnet.private_endpoints
    values = {
      virtual_network_name = "vnet-aureon-dev-eastus"
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/vnet-aureon-dev-eastus/subnets/endpoints"
    }
  }
  override_data {
    target = data.azurerm_virtual_network.workloads
    values = {
      location = "eastus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/vnet-aureon-dev-eastus"
    }
  }
  override_data {
    target = data.azurerm_private_dns_zone.blob
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    }
  }
}

variables {
  ai = {
    openai_name = "aureon-test-openai"
    search_name = "aureon-test-search"
    search_sku  = "basic"
    deployments = {
      chat = { model = "gpt-4o-mini", version = "2024-07-18", sku = "Standard", capacity = 1 }
    }
  }
  batch4_postgresql = {
    name                  = "aureon-test-postgres"
    version               = "16"
    sku_name              = "B_Standard_B1ms"
    storage_mb            = 32768
    backup_retention_days = 7
    delegated_subnet_cidr = "10.100.0.0/28"
    bootstrap_admin_group = {
      object_id      = "00000000-0000-0000-0000-000000000003"
      principal_name = "test-database-admins"
    }
  }
  batch4_managed_redis = {
    name     = "aureon-test-cache"
    sku_name = "Balanced_B3"
  }
  registry_name = "aureontestregistry"
  container_apps = {
    name        = "aureon-test-aca"
    subnet_name = "aca-test-subnet"
    subnet_cidr = "10.100.1.0/27"
  }
  workload_images = {
    api = {
      name              = "aureon-test-api"
      image             = "api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      cpu               = 0.25
      memory            = "0.5Gi"
      max_replicas      = 2
      port              = 8000
      use_managed_redis = true
    }
    ingestion = {
      name         = "aureon-test-ingestion"
      image        = "ingestion@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      cpu          = 0.25
      memory       = "0.5Gi"
      max_replicas = 1
    }
  }
  frontend = {
    name     = "aureon-test-frontend"
    location = "eastus2"
  }
  monitoring = {
    workspace_name         = "aureon-test-logs"
    insights_name          = "aureon-test-insights"
    private_scope_name     = "aureon-test-monitor"
    action_group_id        = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/test/providers/Microsoft.Insights/actionGroups/test"
    active_message_limit   = 100
    daily_ingestion_gb     = 1
    search_throttle_limit  = 5
    database_storage_limit = 80
    cache_memory_limit     = 80
  }
}

run "private_foundations_and_staged_identities" {
  command = plan

  assert {
    condition = (
      !azurerm_cognitive_account.openai[0].public_network_access_enabled &&
      !azurerm_cognitive_account.openai[0].local_auth_enabled &&
      !azurerm_search_service.documents[0].public_network_access_enabled &&
      !azurerm_search_service.documents[0].local_authentication_enabled &&
      !azurerm_postgresql_flexible_server.app[0].public_network_access_enabled &&
      azurerm_postgresql_flexible_server.app[0].authentication[0].active_directory_auth_enabled &&
      !azurerm_postgresql_flexible_server.app[0].authentication[0].password_auth_enabled &&
      azurerm_managed_redis.api_cache[0].public_network_access == "Disabled" &&
      !azurerm_managed_redis.api_cache[0].default_database[0].access_keys_authentication_enabled &&
      !azurerm_container_registry.workloads[0].public_network_access_enabled &&
      !azurerm_container_registry.workloads[0].admin_enabled &&
      !azurerm_static_web_app.chatbot[0].public_network_access_enabled &&
      !azurerm_application_insights.workloads[0].internet_ingestion_enabled &&
      !azurerm_log_analytics_workspace.workloads[0].internet_query_enabled
    )
    error_message = "The opt-in services must retain their private and keyless settings where supported."
  }

  assert {
    condition = (
      length(azurerm_container_app.workloads) == 0 &&
      length(azurerm_user_assigned_identity.workloads) == 2 &&
      length(azurerm_managed_redis_access_policy_assignment.api) == 1 &&
      azurerm_role_assignment.workloads["ingestion/queue"].role_definition_name == "Azure Service Bus Data Receiver" &&
      azurerm_role_assignment.workloads["ingestion/blob"].role_definition_name == "Storage Blob Data Reader" &&
      !contains(keys(azurerm_role_assignment.workloads), "api/queue") &&
      !contains(keys(azurerm_private_dns_zone.workloads), "privatelink.blob.core.windows.net")
    )
    error_message = "Identity staging must not run workloads, broaden queue privileges, or duplicate the Blob DNS zone."
  }
}

run "deploy_private_workloads" {
  command = plan

  variables {
    deploy_workloads = true
  }

  assert {
    condition = (
      azurerm_container_app_environment.workloads[0].internal_load_balancer_enabled &&
      azurerm_container_app_environment.workloads[0].public_network_access == "Disabled" &&
      !azurerm_container_app.workloads["api"].ingress[0].allow_insecure_connections &&
      length(azurerm_container_app.workloads["ingestion"].ingress) == 0 &&
      azurerm_container_app.workloads["ingestion"].template[0].min_replicas == 1 &&
      azurerm_container_app.workloads["ingestion"].template[0].max_replicas == 1 &&
      contains(keys(azurerm_monitor_metric_alert.platform), "api-errors")
    )
    error_message = "Only the private API should receive ingress; ingestion must keep one polling replica and monitoring must cover the API."
  }
}
