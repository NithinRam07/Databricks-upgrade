terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# provider.tf.json is injected by the engine; variables live in variables.tf.
#
# WHAT THIS DOES
#   Scans var.ResourceGroup for Databricks workspaces below the target tier
#   (trial or standard). If EXACTLY ONE is found, upgrades it in place to
#   premium without `terraform import`, by sending the change as an ARM
#   deployment (a PUT onto the existing resource ID) through azurerm.
#
#   0 candidates -> nothing happens (plan is empty, see Action_Taken)
#   1 candidate  -> upgraded
#   2+           -> plan FAILS with the names listed. The template will not
#                   guess which workspace to upgrade.
#
#   Upgrade steps:
#   1. Deployment "read"    - ARM reads the workspace's full current properties.
#   2. Deployment "upgrade" - re-sends those properties with the new SKU and
#      the requested environment tag. A PUT replaces the resource, so the
#      current properties are echoed back rather than omitted.
#
# SAFETY
#   - ResourceGroup must be supplied by the engine. If it arrives empty the
#     plan fails; the scan never falls back to the whole subscription.
#   - deployment_mode MUST stay "Incremental". "Complete" would delete every
#     other resource in the resource group.
#   - Upgrade only. Environment replaces any existing environment tag (any
#     capitalisation) and is written only when an upgrade happens.
#   - Destroying this deletes the deployment records only. It does not revert
#     the SKU or the tag, and does not delete the workspace.
#   - Untested against Azure. Run it on a disposable workspace first.

locals {
  sku_rank    = { trial = 0, standard = 1, premium = 2 }
  api_version = "2023-02-01"
  schema      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"

  target_sku = lower(var.Pricing_Tier)

  # Workspaces in the resource group sitting below the target tier.
  # An unrecognised SKU ranks 99, so it is never treated as a candidate.
  candidates = {
    for name, w in data.azurerm_databricks_workspace.found : name => w
    if lookup(local.sku_rank, lower(w.sku), 99) < local.sku_rank[local.target_sku]
  }
  candidate_names = sort(keys(local.candidates))
  candidate_count = length(local.candidate_names)
  upgrade_needed  = local.candidate_count == 1

  chosen_name     = try(local.candidate_names[0], "")
  chosen_sku      = try(lower(local.candidates[local.chosen_name].sku), "")
  chosen_location = try(local.candidates[local.chosen_name].location, "")
  chosen_tags     = try(local.candidates[local.chosen_name].tags, {})

  # Existing tags minus any environment tag (any capitalisation), plus the requested one.
  merged_tags = merge(
    { for k, v in local.chosen_tags : k => v if lower(k) != "environment" },
    { environment = var.Environment }
  )
}

# Deployment names must be unique per run: azurerm refuses to create a
# deployment whose name already exists in the resource group.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

data "azurerm_resources" "databricks" {
  type                = "Microsoft.Databricks/workspaces"
  resource_group_name = var.ResourceGroup

  lifecycle {
    precondition {
      condition     = trimspace(var.ResourceGroup) != ""
      error_message = "ResourceGroup was not provided by the engine. Refusing to scan without a resource group."
    }
    precondition {
      condition     = lower(var.Pricing_Tier) == "premium"
      error_message = "Pricing_Tier must be premium. Standard is no longer offered in the portal and trial is not an upgrade target."
    }
    precondition {
      condition     = contains(["Dev", "Test", "PreProd", "Prod"], var.Environment)
      error_message = "Environment must be one of Dev, Test, PreProd or Prod."
    }
  }
}

# azurerm_resources returns IDs and names but not the SKU, so fetch detail.
data "azurerm_databricks_workspace" "found" {
  for_each            = { for r in data.azurerm_resources.databricks.resources : r.name => r }
  name                = each.key
  resource_group_name = var.ResourceGroup
}

resource "azurerm_resource_group_template_deployment" "read" {
  count               = local.candidate_count > 0 ? 1 : 0
  name                = "dbx-read-${random_string.suffix.result}"
  resource_group_name = var.ResourceGroup
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = local.schema
    contentVersion = "1.0.0.0"
    parameters = {
      workspaceName = { type = "string" }
    }
    resources = []
    outputs = {
      existingProperties = {
        type  = "object"
        value = "[reference(resourceId('Microsoft.Databricks/workspaces', parameters('workspaceName')), '${local.api_version}')]"
      }
    }
  })

  parameters_content = jsonencode({
    workspaceName = { value = local.chosen_name }
  })

  lifecycle {
    precondition {
      condition     = local.candidate_count == 1
      error_message = format("Found %d workspaces below %s in '%s' (%s). Refusing to guess which one to upgrade - nothing was changed.", local.candidate_count, local.target_sku, var.ResourceGroup, join(", ", local.candidate_names))
    }
  }
}

resource "azurerm_resource_group_template_deployment" "upgrade" {
  count               = local.upgrade_needed ? 1 : 0
  name                = "dbx-sku-${random_string.suffix.result}"
  resource_group_name = var.ResourceGroup
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = local.schema
    contentVersion = "1.0.0.0"
    parameters = {
      workspaceName      = { type = "string" }
      location           = { type = "string" }
      skuName            = { type = "string" }
      tags               = { type = "object" }
      existingProperties = { type = "object" }
    }
    resources = [
      {
        type       = "Microsoft.Databricks/workspaces"
        apiVersion = local.api_version
        name       = "[parameters('workspaceName')]"
        location   = "[parameters('location')]"
        sku        = { name = "[parameters('skuName')]" }
        tags       = "[parameters('tags')]"
        properties = "[parameters('existingProperties')]"
      }
    ]
  })

  parameters_content = jsonencode({
    workspaceName      = { value = local.chosen_name }
    location           = { value = local.chosen_location }
    skuName            = { value = local.target_sku }
    tags               = { value = local.merged_tags }
    existingProperties = { value = jsondecode(azurerm_resource_group_template_deployment.read[0].output_content).existingProperties.value }
  })
}

# Post-check: deferred to apply time because it depends on the upgrade deployment.
data "azurerm_databricks_workspace" "after" {
  count               = local.upgrade_needed ? 1 : 0
  name                = local.chosen_name
  resource_group_name = var.ResourceGroup
  depends_on          = [azurerm_resource_group_template_deployment.upgrade]
}

output "Action_Taken" {
  value = local.upgrade_needed ? format("Upgrade requested for '%s': %s -> %s", local.chosen_name, local.chosen_sku, local.target_sku) : format("No workspace below %s found in '%s' - nothing changed", local.target_sku, var.ResourceGroup)
}

output "Workspaces_Scanned" {
  value = { for name, w in data.azurerm_databricks_workspace.found : name => lower(w.sku) }
}

output "Workspace_Name" {
  value = local.upgrade_needed ? local.chosen_name : null
}

output "Sku_Before" {
  value = local.upgrade_needed ? local.chosen_sku : null
}

output "Sku_Requested" {
  value = local.target_sku
}

output "Sku_After" {
  value = try(data.azurerm_databricks_workspace.after[0].sku, null)
}

output "Environment_Applied" {
  value = local.upgrade_needed ? var.Environment : "not applied - no upgrade was needed"
}

output "Workspace_Id" {
  value = try(data.azurerm_databricks_workspace.found[local.chosen_name].id, null)
}

output "Workspace_Url" {
  value = try(data.azurerm_databricks_workspace.found[local.chosen_name].workspace_url, null)
}
