resource "azurerm_resource_group" "gazelle_rg" {
  name     = "mifos-gazelle-rg"
  location = "East US"
}

resource "azurerm_kubernetes_cluster" "gazelle_aks" {
  name                = "mifos-gazelle-aks"
  location            = azurerm_resource_group.gazelle_rg.location
  resource_group_name = azurerm_resource_group.gazelle_rg.name
  dns_prefix          = "mifosgazelle"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "Development"
    Project     = "Mifos Gazelle"
  }
}

output "kube_config" {
  value = azurerm_kubernetes_cluster.gazelle_aks.kube_config_raw
  sensitive = true
}