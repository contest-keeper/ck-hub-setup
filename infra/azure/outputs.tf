output "hub_url" {
  description = "Where organizers and sticks reach the Hub. HTTPS, with Azure's own certificate."
  value       = "https://${azurerm_container_app.hub.ingress[0].fqdn}"
}

output "resource_group" {
  value = data.azurerm_resource_group.this.name
}

output "container_app" {
  value = azurerm_container_app.hub.name
}

output "key_vault" {
  value = azurerm_key_vault.this.name
}

output "database_host" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "download_storage_account" {
  description = "The private storage account that holds the installers."
  value       = azurerm_storage_account.downloads.name
}
