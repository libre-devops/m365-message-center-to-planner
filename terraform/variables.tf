variable "cost_centre" {
  description = "Cost centre tag applied to everything. Replace the placeholder with yours."
  type        = string
  default     = "1888/67"
}

variable "owner" {
  description = "Owner tag applied to everything: the person or team accountable for the deployment. Replace the placeholder with yours."
  type        = string
  default     = "craig@craigthacker.dev"
}

variable "bucket_id" {
  description = "Planner bucket (board column) id the tickets land in, normally the To be discussed column. Find it with: mc.ps1 plans -Buckets (or mc.py plans --buckets)."
  type        = string
}

variable "daily_lookback_days" {
  description = "How many days back the daily sync looks for created or updated messages. A little overlap is intended: the dedupe makes re-seen messages a no-op."
  type        = number
  default     = 2
}

variable "env" {
  description = "Environment code used in resource names."
  type        = string
  default     = "dev"
}

variable "loc" {
  description = "Outfix: short Azure region code used in resource names."
  type        = string
  default     = "uks"
}

variable "manage_graph_grants" {
  description = "Manage the identities' Graph application role grants (ServiceMessage.Read.All, Tasks.ReadWrite.All) in this stack via the azuread role-assignment module. The applier then needs AppRoleAssignment.ReadWrite.All (Global Administrator works). Set false to skip them and use the az CLI commands from the grant_commands output instead."
  type        = bool
  default     = true
}

variable "plan_id" {
  description = "Planner plan id of the target board. Find it with: mc.ps1 plans -Buckets (or from the Planner board URL)."
  type        = string
}

variable "regions" {
  description = "Map of short region codes to Azure region slugs."
  type        = map(string)
  default = {
    uks = "uksouth"
    ukw = "ukwest"
    eus = "eastus"
    euw = "westeurope"
  }
}

variable "short" {
  description = "Infix: short product code used in resource names."
  type        = string
  default     = "ldo"
}
