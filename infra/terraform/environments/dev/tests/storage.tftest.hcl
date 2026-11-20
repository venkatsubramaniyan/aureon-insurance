mock_provider "azurerm" {
  override_data {
    target = data.azurerm_client_config.current
    values = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  override_data {
    target = data.azurerm_subnet.private_endpoints
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aureon-dev-eastus/providers/Microsoft.Network/virtualNetworks/vnet-aureon-dev-eastus/subnets/snet-aureon-private-endpoints-dev"
    }
  }

  override_data {
    target = data.azurerm_private_dns_zone.blob
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aureon-dev-eastus/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    }
  }
}

run "secure_storage_plan" {
  command = plan

  assert {
    condition = (
      azurerm_storage_account.app_storage.name == "staureonappdev001" &&
      azurerm_storage_account.app_storage.public_network_access_enabled == false &&
      azurerm_storage_account.app_storage.shared_access_key_enabled == false &&
      azurerm_storage_account.app_storage.https_traffic_only_enabled == true &&
      azurerm_storage_account.app_storage.min_tls_version == "TLS1_2" &&
      azurerm_storage_account.app_storage.allow_nested_items_to_be_public == false
    )
    error_message = "The existing account must have the requested security settings."
  }

  assert {
    condition = (
      azurerm_storage_container.insurance_documents.name == "insurance-documents" &&
      azurerm_storage_container.insurance_documents.container_access_type == "private"
    )
    error_message = "The existing container must remain private and retain its name."
  }

  assert {
    condition = (
      azurerm_private_endpoint.app_storage_blob.subnet_id == data.azurerm_subnet.private_endpoints.id &&
      azurerm_private_endpoint.app_storage_blob.private_service_connection[0].private_connection_resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aureon-dev-eastus/providers/Microsoft.Storage/storageAccounts/staureonappdev001" &&
      length(azurerm_private_endpoint.app_storage_blob.private_service_connection[0].subresource_names) == 1 &&
      contains(azurerm_private_endpoint.app_storage_blob.private_service_connection[0].subresource_names, "blob") &&
      contains(azurerm_private_endpoint.app_storage_blob.private_dns_zone_group[0].private_dns_zone_ids, data.azurerm_private_dns_zone.blob.id)
    )
    error_message = "The endpoint must connect the existing account's Blob service to the existing subnet and DNS zone."
  }
}
