output "storage_account" {
  description = "The storage account that serves the site."
  value       = azurerm_storage_account.site.name
}

output "website_url" {
  description = "The address of the site."
  value       = azurerm_storage_account.site.primary_web_endpoint
}
