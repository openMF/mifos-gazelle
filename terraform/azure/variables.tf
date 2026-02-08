variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "gazelle-gsoc-rg"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "gazelle-aks"
}

variable "node_count" {
  description = "Number of nodes"
  type        = number
  default     = 1
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_B2s" # Cost-effective for development
}