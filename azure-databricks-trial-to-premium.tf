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

# No `provider "azurerm"` block: the engine injects provider.tf.json.
# No `variable` blocks: they would duplicate against variables.tf.json.
#
# WHAT THIS DOES
#   Scans source_resource_group for Databricks workspaces. If any is on the
#   trial SKU, creates a NEW resource group and a NEW premium workspace in
#   the same region. The trial workspace is left completely untouched.
#
# WHAT THIS IS NOT
#   Not an upgrade, and not a clone. The new workspace is EMPTY - no
#   notebooks, jobs, clusters, policies, permissions, mounts, secret scopes
#   or Unity Catalog bindings carry over. It has a new workspace_url and a
#   new workspace_id, so every existing reference to the old workspace
#   keeps pointing at the old workspace.
#
# IF NO TRIAL WORKSPACE IS FOUND
#   count evaluates to 0 and the plan is empty. That is a silent no-op, not
#   an error. Read trial_Found and action_Taken in the outputs to tell the
#   difference between "nothing to do" and "done".

locals {
  # <<< EDIT PER RUN - cannot be a parameter until the variables bug is fixed >>>
  source_resource_group = "Nithin-RG"

  # Where the new premium workspace goes. Must not already exist.
  target_resource_group = "Nithin-RG-premium"

  target_sku = "premium"

  tags = {
    environment = "QA"
    managed_by  = "terraform"
    purpose     = "trial-to-premium"
  }
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

data "azurerm_resources" "databricks" {
  type                = "Microsoft.Databricks/workspaces"
  resource_group_name = local.source_resource_group
}

# azurerm_resources returns IDs and names but not the SKU, so fetch detail.
data "azurerm_databricks_workspace" "found" {
  for_each            = { for r in data.azurerm_resources.databricks.resources : r.name => r }
  name                = each.key
  resource_group_name = local.source_resource_group
}

locals {
  # Every workspace in the source RG currently on the trial SKU.
  trial_workspaces = {
    for name, w in data.azurerm_databricks_workspace.found : name => {
      id       = w.id
      location = w.location
      sku      = w.sku
      url      = w.workspace_url
    } if w.sku == "trial"
  }

  trial_names = sort(keys(local.trial_workspaces))
  trial_found = length(local.trial_names) > 0

  # If several are on trial, act on the first by name - deterministic, and
  # avoids creating N premium workspaces from one run by accident.
  source_name     = local.trial_found ? local.trial_names[0] : ""
  source_location = local.trial_found ? local.trial_workspaces[local.source_name].location : ""
}

# ---------------------------------------------------------------------------
# Conditional creation - count = 0 means the whole block is skipped
# ---------------------------------------------------------------------------

resource "random_string" "suffix" {
  count   = local.trial_found ? 1 : 0
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "premium" {
  count    = local.trial_found ? 1 : 0
  name     = local.target_resource_group
  location = local.source_location
  tags     = local.tags
}

resource "azurerm_databricks_workspace" "premium" {
  count               = local.trial_found ? 1 : 0
  name                = "${local.source_name}-premium-${random_string.suffix[0].result}"
  resource_group_name = azurerm_resource_group.premium[0].name
  location            = azurerm_resource_group.premium[0].location
  sku                 = local.target_sku

  managed_resource_group_name = "${local.target_resource_group}-managed-${random_string.suffix[0].result}"

  tags = merge(local.tags, {
    source_workspace = local.source_name
    source_rg        = local.source_resource_group
  })
}

# ---------------------------------------------------------------------------
# Outputs - the only way to distinguish no-op from success
# ---------------------------------------------------------------------------

output "action_Taken" {
  value = local.trial_found ? "Created premium workspace from trial '${local.source_name}'" : "No trial workspace found in '${local.source_resource_group}' - nothing created"
}

output "trial_Found" {
  value = local.trial_found
}

output "workspaces_Scanned" {
  value = { for name, w in data.azurerm_databricks_workspace.found : name => w.sku }
}

output "trial_Workspaces" {
  value = local.trial_workspaces
}

output "source_Workspace_Name" {
  value = local.trial_found ? local.source_name : null
}

output "new_Workspace_Name" {
  value = local.trial_found ? azurerm_databricks_workspace.premium[0].name : null
}

output "new_Workspace_Url" {
  value = local.trial_found ? azurerm_databricks_workspace.premium[0].workspace_url : null
}

output "new_Workspace_Sku" {
  value = local.trial_found ? azurerm_databricks_workspace.premium[0].sku : null
}

output "new_Resource_Group" {
  value = local.trial_found ? azurerm_resource_group.premium[0].name : null
}

output "new_Managed_Resource_Group_Id" {
  value = local.trial_found ? azurerm_databricks_workspace.premium[0].managed_resource_group_id : null
}
