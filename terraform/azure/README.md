# Azure Kubernetes Service (AKS) Infrastructure

This directory contains the Terraform configuration files required to provision a managed Kubernetes cluster on Microsoft Azure for Mifos Gazelle.

The main `run.sh` script invokes this automatically when using `-p aks`, but it can also be used standalone for development, debugging, or custom deployments.

## Project Structure

| File | Description |
|------|-------------|
| `main.tf` | Defines the Azure resources: Resource Group, AKS Cluster, and Node Pool. |
| `variables.tf` | input variables to customize the deployment (Region, VM Size, Node count). |
| `outputs.tf` | Defines the data returned after deployment (Cluster Name, Resource Group, Kube Config). |
| `versions.tf` | Pins the specific versions of Terraform and the Azure Provider to ensure stability. |

## Prerequisites

If running manually (bypassing `run.sh`), ensure you have:

1.  **Terraform** (v1.0 or later)
2.  **Azure CLI** (`az`) installed and authenticated via `az login`.

## Configuration Variables

You can customize the infrastructure by modifying `variables.tf` or passing `-var` flags.

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `location` | Azure Region for resources | `East US` |
| `resource_group_name` | Name of the Resource Group | `gazelle-gsoc-rg` |
| `cluster_name` | Name of the AKS Cluster | `gazelle-aks` |
| `node_count` | Number of worker nodes | `1` |
| `vm_size` | Virtual Machine size (SKU) | `Standard_B2s` (Cost-effective) |

> **Note on Costs:** The default `Standard_B2s` is chosen for cost-efficiency during testing. For production workloads, consider upgrading to `Standard_D2s_v3` or larger.

## Manual Usage Guide

If you need to debug the infrastructure creation without running the full Gazelle installer:

1.  **Initialize Terraform:**
    Downloads the required provider plugins.
    ```bash
    terraform init
    ```

2.  **Review the Plan:**
    Shows what resources will be created.
    ```bash
    terraform plan
    ```

3.  **Apply Changes:**
    Provisions the infrastructure on Azure.
    ```bash
    terraform apply
    ```

4.  **Connect to Cluster:**
    After a successful apply, configure your local `kubectl`:
    ```bash
    az aks get-credentials --resource-group gazelle-gsoc-rg --name gazelle-aks
    ```

## Cleanup

To destroy all resources created by this configuration and stop billing:

```bash
terraform destroy
```