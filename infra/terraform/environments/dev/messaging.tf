resource "azurerm_servicebus_namespace" "ingestion" {
  name                          = "sb-aureon-ingest-dev-eastus"
  resource_group_name           = local.app_storage_resource_group_name
  location                      = "eastus"
  sku                           = "Standard"
  minimum_tls_version           = "1.2"
  local_auth_enabled            = false
  public_network_access_enabled = true

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }
}

resource "azurerm_servicebus_queue" "ingestion" {
  name                                    = "insurance-document-ingestion"
  namespace_id                            = azurerm_servicebus_namespace.ingestion.id
  lock_duration                           = "PT5M"
  max_size_in_megabytes                   = 1024
  default_message_ttl                     = "P14D"
  dead_lettering_on_message_expiration    = true
  max_delivery_count                      = 10
  requires_duplicate_detection            = true
  duplicate_detection_history_time_window = "PT10M"
  express_enabled                         = false
  partitioning_enabled                    = false
}

resource "azurerm_eventgrid_system_topic" "app_storage" {
  name                = "egst-aureon-app-storage-dev"
  resource_group_name = local.app_storage_resource_group_name
  location            = "eastus"
  source_resource_id  = azurerm_storage_account.app_storage.id
  topic_type          = "Microsoft.Storage.StorageAccounts"

  identity {
    type = "SystemAssigned"
  }

  tags = {
    project     = "aureon-insurance"
    environment = "dev"
  }
}

resource "azurerm_role_assignment" "eventgrid_ingestion_sender" {
  scope                = azurerm_servicebus_queue.ingestion.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.app_storage.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_storage_container" "eventgrid_dead_letters" {
  name                  = "eventgrid-deadletters"
  storage_account_id    = azurerm_storage_account.app_storage.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "eventgrid_dead_letter_writer" {
  scope = azurerm_storage_account.app_storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_eventgrid_system_topic.app_storage.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_eventgrid_system_topic_event_subscription" "insurance_document_created" {
  name                          = "evsub-aureon-insurance-document-created-dev"
  system_topic                  = azurerm_eventgrid_system_topic.app_storage.name
  resource_group_name           = local.app_storage_resource_group_name
  service_bus_queue_endpoint_id = azurerm_servicebus_queue.ingestion.id
  event_delivery_schema         = "EventGridSchema"
  included_event_types          = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_container.insurance_documents.name}/blobs/"
    case_sensitive      = true
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  dead_letter_identity {
    type = "SystemAssigned"
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = azurerm_storage_account.app_storage.id
    storage_blob_container_name = azurerm_storage_container.eventgrid_dead_letters.name
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }

  depends_on = [
    azurerm_role_assignment.eventgrid_ingestion_sender,
    azurerm_role_assignment.eventgrid_dead_letter_writer,
  ]
}
