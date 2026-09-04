# =============================================================================
#  function/main.tf - run the heliograph agent as an Azure Function
# =============================================================================
#  The fifth host, and the only one that needs no long-lived compute, no VM
#  quota and no inbound path. A timer fires, the agent answers at most one
#  request, and the invocation ends.
#
#  WHEN TO REACH FOR THIS. When the estate will not give you anywhere to keep a
#  process. It was written after three container hosts were refused in one
#  subscription: App Service quota was zero on every SKU that allocates a VM,
#  and a VNet-injected Container Apps environment could not provision because
#  the platform itself needs outbound and the subnet had none. Flex Consumption
#  needed neither.
#
#  IT USES THE PIGEONHOLE, NOT GIT, AND NOT BY PREFERENCE. There is no git
#  binary in the Functions Python image. That turns out to be the feature
#  rather than the limitation: blob storage behind a private endpoint needs no
#  egress at all, so this host works in a subnet with no route off it.
#
#  BRING YOUR OWN NETWORK. The VNet, the subnet and the storage account already
#  exist. This creates the plan, the app and nothing else.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "name" {
  description = "Name for the function app."
  type        = string
  default     = "heliograph-agent"
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group. Not created here."
  type        = string
}

# FLEX CONSUMPTION, AND CHECK THIS BEFORE ANYTHING ELSE. Quota for App Service
# SKUs is per-SKU and can be zero without the region saying so - `az appservice
# list-locations` describes the region, not the subscription. The read-only way
# to measure it is ARM preflight: `az deployment group validate` against a
# Microsoft.Web/serverfarms template returns the quota error without creating
# anything. On the estate this was written for, nine SKUs returned zero and FC1
# was the only one that validated.
variable "sku_name" {
  description = "App Service plan SKU. FC1 is Flex Consumption."
  type        = string
  default     = "FC1"
}

variable "storage_account_name" {
  description = "Existing storage account. Holds the deployment package, and can also hold the pigeonhole drop."
  type        = string
}

variable "storage_account_access_key" {
  description = "Key for the deployment container. Never committed."
  type        = string
  sensitive   = true
}

# THE SUBNET IS WHAT PUTS THE AGENT INSIDE THE ESTATE. Without it the app runs
# on the platform's network and can reach nothing private - which is usually
# the entire reason for deploying a runner at all. It must be delegated to
# Microsoft.App/environments.
variable "subnet_id" {
  description = "Existing subnet for VNet integration, delegated to Microsoft.App/environments. Empty means no integration."
  type        = string
  default     = ""
}

# TRUE PUTS EVERY OUTBOUND CONNECTION THROUGH THE SUBNET, including the ones
# the platform makes. That is what you want when the drop is on a private
# endpoint and there is no egress; it is what you do NOT want if the agent
# needs the internet and the subnet has no route to it. This is the setting
# that decides whether git could ever work here.
variable "vnet_route_all_enabled" {
  description = "Route all outbound traffic through the integration subnet."
  type        = bool
  default     = true
}

variable "pigeonhole_account" {
  description = "Storage account holding the drop - requests, logs, status and agent containers."
  type        = string
}

# EMPTY IS NORMAL ON THIS HOST. A Function authenticates as its managed
# identity against a local token endpoint, which needs no egress - so a SAS is
# only wanted where the estate prefers one, and is impossible where shared keys
# are disabled on the account. Leaving this empty selects identity mode.
#
# Identity mode needs a role assignment the template does not make: the app's
# principal needs Storage Blob Data Contributor on the drop account. Terraform
# cannot grant it here without owning the account, which this deliberately does
# not - see the header on bring-your-own.
variable "pigeonhole_sas" {
  description = "SAS for the drop. Empty selects managed identity, which is the default on this host."
  type        = string
  default     = ""
  sensitive   = true
}

# THE LANE IS THE BINDING. Two runners must never answer one request: a
# heliograph log's whole value is that it says what ONE machine saw, and two
# logs seconds apart from two hosts is a failure that looks like success.
variable "pigeonhole_lane" {
  description = "Which request this runner answers - requests/<lane>.txt. No two runners may share a lane."
  type        = string
  default     = "default"
}

# EVERY SIX HOURS, NOT EVERY MINUTE. A timer this slow looks wrong until you
# remember what it costs to be wrong in the other direction: the runner is
# unattended, and a fast timer on a misconfigured lane is a step running every
# minute with nobody watching. Tighten it while an investigation is live.
variable "schedule" {
  description = "NCRONTAB expression for the timer. Six fields, seconds first."
  type        = string
  default     = "0 0 */6 * * *"
}

variable "allow_actions" {
  description = "Whether the agent may run a state-changing step. Off by default, and the request must still say CONFIRM=yes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to what this creates."
  type        = map(string)
  default     = {}
}

# --- intercom: the HTTP transport ---------------------------------------------
# Off unless asked for. See references/intercom.md before turning it on: it runs
# the script the caller sends, so the `heliograph-mode:` header becomes a claim
# the caller makes about its own file rather than a control, and the two
# settings below are then the only real ones.
variable "intercom_enabled" {
  description = "Expose POST /api/run and GET /api/task/{id}. Requires intercom_allowed_ip_addresses."
  type        = bool
  default     = false
}

# THE ALLOWLIST IS NOT OPTIONAL, and the precondition on the app enforces it
# rather than trusting the reader. A function key alone guards an endpoint that
# runs arbitrary shell inside the VNet, and one leaked key is then the whole
# distance between an attacker and code execution there. Two independent
# controls means a leaked key is useless off-network and an on-network caller
# still needs the key.
variable "intercom_allowed_ip_addresses" {
  description = "CIDRs allowed to call the agent. App Service refuses a bare address: use x.x.x.x/32."
  type        = list(string)
  default     = []
}

# OFF, AND ON AN ESTATE WITH NO EGRESS IT CANNOT WORK. SyncTriggers is how the
# platform tells the SCALE CONTROLLER which triggers this app has, and it is an
# outbound call. Where the subnet's default route goes to a firewall with no
# policy for it, SyncTriggers times out after 100 seconds, the scale controller
# never learns there is a queue trigger, and nothing polls the queue - while the
# host reports Running, the worker shows as registered, and every HTTP call
# succeeds. HTTP triggers are unaffected because the front end routes straight to
# an always-ready instance without consulting the scale controller.
#
# Turning this on also needs AzureWebJobsStorage__queueServiceUri: the queue
# extension cannot build a QueueServiceClient from __accountName alone, and fails
# to INDEX rather than to run.
variable "intercom_queue_mode" {
  description = "Run steps in a queue invocation instead of inline. Needs egress for SyncTriggers, and __queueServiceUri. See references/intercom.md."
  type        = bool
  default     = false
}

variable "intercom_queue" {
  description = "Queue carrying submitted tasks. The binding is %HELIOGRAPH_QUEUE%, so the app will not index without it."
  type        = string
  default     = "heliograph-tasks"
}

variable "intercom_prefix" {
  description = "Prefix for the intercom container and queue, for a drop sharing an account."
  type        = string
  default     = ""
}

resource "azurerm_service_plan" "agent" {
  name                = "${var.name}-plan"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = var.sku_name

  tags = var.tags
}

resource "azurerm_function_app_flex_consumption" "agent" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.agent.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "https://${var.storage_account_name}.blob.core.windows.net/${var.name}-deployments"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = var.storage_account_access_key

  runtime_name    = "python"
  runtime_version = "3.12"

  # NOTHING CONNECTS TO THE AGENT when it runs the pigeonhole: it makes outbound
  # connections only, so the public endpoint is closed rather than left open and
  # unused. intercom is the exception, and the only one - it exists precisely to
  # be called, so enabling it opens the front door and the allowlist below
  # decides who comes through.
  public_network_access_enabled = var.intercom_enabled

  virtual_network_subnet_id = var.subnet_id == "" ? null : var.subnet_id

  # THE IDENTITY IS THE CREDENTIAL, not a convenience. It authenticates to the
  # drop where no SAS can be minted, and it is what the deployment container
  # is read with. Without it the app starts and can reach neither.
  identity { type = "SystemAssigned" }

  site_config {
    vnet_route_all_enabled = var.subnet_id == "" ? false : var.vnet_route_all_enabled

    # Deny by default and allow the listed CIDRs. scm follows the same list
    # because it does not inherit these, and an SCM host left open is the same
    # endpoint by another name.
    ip_restriction_default_action     = length(var.intercom_allowed_ip_addresses) > 0 ? "Deny" : "Allow"
    scm_ip_restriction_default_action = length(var.intercom_allowed_ip_addresses) > 0 ? "Deny" : "Allow"
    scm_use_main_ip_restriction       = length(var.intercom_allowed_ip_addresses) > 0

    dynamic "ip_restriction" {
      for_each = var.intercom_allowed_ip_addresses
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        priority   = 100 + ip_restriction.key
        ip_address = ip_restriction.value
      }
    }
  }

  app_settings = {
    # DECLARED EMPTY, AND ON PURPOSE. Where the storage account has shared keys
    # disabled, this provider writes an AzureWebJobsStorage connection string
    # with an EMPTY AccountKey every time it updates the app: it cannot read a
    # key, and writes the string anyway. The host PREFERS that over
    # AzureWebJobsStorage__accountName, tries shared-key auth, and cannot reach
    # its own key store - every call answers 401 and listkeys returns
    # "Encountered an error (InternalServerError) from host runtime", which
    # reads as a broken runtime rather than a bad setting.
    #
    # Terraform does not see it as drift on its own, because a key it does not
    # manage is a key it does not look at. Naming it here makes it managed.
    #
    # THIS COSTS A PERMANENT ONE-LINE DIFF, which is the cheaper half of the
    # trade. Azure drops an empty setting rather than storing it, so terraform
    # reads it back as absent and proposes it again on every plan.
    #
    # `ignore_changes` on this key removes the diff and was MEASURED to break
    # it: with the key ignored, a genuine app update (changing a tag was enough)
    # had the provider write the broken string straight back. The declaration
    # only works while it is live.
    AzureWebJobsStorage = ""

    # THE QUEUE EXTENSION CANNOT BUILD ITS CLIENT FROM __accountName ALONE. Set
    # only when queue mode is on: naming an endpoint the subnet cannot reach is
    # how a hang gets built in for later. No table URI for the same reason.
    AzureWebJobsStorage__queueServiceUri = var.intercom_queue_mode ? "https://${var.storage_account_name}.queue.core.windows.net" : ""

    PIGEONHOLE_ACCOUNT  = var.pigeonhole_account
    PIGEONHOLE_SAS      = var.pigeonhole_sas
    PIGEONHOLE_LANE     = var.pigeonhole_lane
    HELIOGRAPH_SCHEDULE = var.schedule

    # The two that make a loop behave like an invocation. function_app.py sets
    # them too; they are here so that what the runner does is visible in the
    # app's own configuration rather than only in its code.
    PIGEONHOLE_RESUME = "1"
    PIGEONHOLE_ONCE   = "1"

    # BOTH NAMES, because two runners read two different variables and setting
    # only one is a gate that silently does nothing. pigeonhole.sh reads
    # PIGEONHOLE_ALLOW_ACTIONS; intercom.py reads HELIOGRAPH_ALLOW_ACTIONS. This
    # file used to set only the second, so `allow_actions = true` had no effect
    # on the timer runner at all - it read the default and refused.
    HELIOGRAPH_ALLOW_ACTIONS = var.allow_actions ? "1" : "0"
    PIGEONHOLE_ALLOW_ACTIONS = var.allow_actions ? "1" : "0"

    # Unset leaves intercom off: the routes are indexed but every call 500s on a
    # missing account, which is the honest outcome for a transport that was not
    # configured. HELIOGRAPH_QUEUE is different and must ALWAYS be set - the
    # trigger binds %HELIOGRAPH_QUEUE% and the app will not index without it,
    # taking the timer trigger down too.
    HELIOGRAPH_ACCOUNT = var.intercom_enabled ? var.storage_account_name : ""
    HELIOGRAPH_QUEUE   = "${var.intercom_prefix}${var.intercom_queue}"
    HELIOGRAPH_PREFIX  = var.intercom_prefix

    HELIOGRAPH_QUEUE_MODE = var.intercom_queue_mode ? "1" : "0"
  }

  lifecycle {
    # A KEY IS ONE CONTROL AND THIS ENDPOINT NEEDS TWO. Refusing at plan time is
    # the point: an allowlist that someone means to add later is an allowlist
    # that does not exist, and the window where it is missing is a public URL
    # that runs shell inside the VNet.
    precondition {
      condition     = !var.intercom_enabled || length(var.intercom_allowed_ip_addresses) > 0
      error_message = "intercom_enabled requires intercom_allowed_ip_addresses. A function key alone does not guard an endpoint that runs caller-supplied shell inside the VNet. See references/intercom.md."
    }
  }

  tags = var.tags
}

output "name" {
  description = "The function app."
  value       = azurerm_function_app_flex_consumption.agent.name
}

# A FUNCTION THAT NEVER FIRES LOOKS IDENTICAL TO ONE WITH NOTHING TO DO. This
# is how to tell them apart.
output "check_logs" {
  description = "Watch the agent decide whether to run."
  value       = "az webapp log tail -g ${var.resource_group_name} -n ${var.name}"
}

output "lane" {
  description = "The request this runner answers. No other runner may be given it."
  value       = "requests/${var.pigeonhole_lane}.txt"
}

output "intercom" {
  description = "How to drive the HTTP transport, once the code is deployed."
  value = var.intercom_enabled ? join("\n", [
    "export INTERCOM_URL=https://${azurerm_function_app_flex_consumption.agent.default_hostname}",
    "export INTERCOM_KEY=$(az functionapp keys list -g ${var.resource_group_name} -n ${var.name} --query functionKeys.default -o tsv)",
    "./intercom.sh run steps/tools-inventory.sh",
  ]) : "intercom is disabled"
}

# THE GRANT THAT IS NOT MADE HERE, said out loud because its absence fails
# silently. The app's identity needs BOTH Storage Blob Data Contributor and
# Storage Queue Data Contributor on the account. With the blob role alone the
# routes answer, a task is recorded, and nothing ever runs it - which reads as a
# hung step rather than a missing role. This module does not own the account, so
# it cannot make the assignment; make it wherever the account is declared.
output "required_roles" {
  description = "Data-plane roles the app's identity needs on the storage account."
  value       = var.intercom_queue_mode ? "Storage Blob Data Contributor, Storage Queue Data Contributor" : "Storage Blob Data Contributor"
}

# WHY EVERY PLAN SAYS "1 to change". The AzureWebJobsStorage note in
# app_settings above explains it: the empty value cannot be stored, so terraform
# proposes it again each time. The diff is always that one key. If a plan shows
# anything else, that part is real.
output "expected_permanent_diff" {
  description = "The one diff every plan will show, so a real change is not lost in it."
  value       = "app_settings[\"AzureWebJobsStorage\"] - see the note in main.tf"
}
