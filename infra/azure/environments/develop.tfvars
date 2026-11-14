# Develop: its own small copy, asleep when nobody uses it.
name                = "ckhubdev"
resource_group_name = "rg-ckhub-dev"
min_replicas        = 0
# custom_domain stays empty: the Hub runs in an express Container Apps environment, which Azure does not
# allow custom domains on (docs/azure.md).
