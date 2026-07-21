# The Logic App version of the Message Center to Planner helper: what the README means by "you
# should probably automate this with a Logic App". Two consumption workflows, each with a
# system-assigned managed identity calling Microsoft Graph directly (no API connections, no
# secrets):
#   logic-...-mc-daily:   pull recently touched Message Center messages and raise ONE Planner
#                         ticket per message (each area of concern gets one ticket), deduped
#                         against the board by the MC id prefix in the task title.
#   logic-...-mc-monthly: on the 1st, raise a single rollup ticket summarising last month.
# The identities need two Graph APPLICATION roles granted after apply (ServiceMessage.Read.All,
# Tasks.ReadWrite.All); the grant commands are in the terraform outputs. Blocks are ordered by
# dependency, top to bottom.
locals {
  location     = lookup(var.regions, var.loc, "uksouth")
  rg_name      = "rg-${var.short}-${var.loc}-${var.env}-mc-001"
  daily_name   = "logic-${var.short}-${var.loc}-${var.env}-mc-daily-001"
  monthly_name = "logic-${var.short}-${var.loc}-${var.env}-mc-monthly-001"

  graph          = "https://graph.microsoft.com/v1.0"
  graph_audience = "https://graph.microsoft.com"
  admin_link     = "https://admin.microsoft.com/#/MessageCenter/:/messages/"

  mi_auth = { type = "ManagedServiceIdentity", audience = local.graph_audience }
  retry   = { type = "fixed", count = 3, interval = "PT15S" }

  # A newline inside a workflow expression: the reliable spelling is decodeUriComponent('%0A').
  nl = "@{decodeUriComponent('%0A')}"
}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  additional_tags = { Application = "m365-message-center-to-planner" }
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

module "logic_app_workflow" {
  source  = "libre-devops/logic-app-workflow/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  workflows = {
    (local.daily_name) = {
      title = "Recurrence - Daily Message Center sync: one Planner ticket per new message"

      parameters = {
        plan_id = {
          type        = "String"
          value       = var.plan_id
          description = "Planner plan id of the target board."
        }
        bucket_id = {
          type        = "String"
          value       = var.bucket_id
          description = "Bucket (board column) the tickets are created in."
        }
        daily_lookback_days = {
          type        = "Int"
          value       = var.daily_lookback_days
          description = "How many days back the sync looks; overlap is fine, the dedupe absorbs it."
        }
      }
    }

    (local.monthly_name) = {
      title = "Recurrence - Monthly Message Center rollup ticket for last month"

      parameters = {
        plan_id = {
          type        = "String"
          value       = var.plan_id
          description = "Planner plan id of the target board."
        }
        bucket_id = {
          type        = "String"
          value       = var.bucket_id
          description = "Bucket (board column) the rollup ticket is created in."
        }
      }
    }
  }
}

# The identities' Graph APPLICATION roles, managed as code via the estate's azuread module: read
# the Message Center, write Planner. Each grant IS tenant-wide admin consent, so the applier needs
# AppRoleAssignment.ReadWrite.All; set manage_graph_grants = false to skip these and use the az CLI
# commands from the grant_commands output instead.
module "graph_grants" {
  source  = "libre-devops/role-assignment/azuread"
  version = "~> 4.2"

  graph_app_role_grants = var.manage_graph_grants ? {
    for name, identity in module.logic_app_workflow.identities : name => {
      principal_object_id = identity.principal_id
      role_names          = ["ServiceMessage.Read.All", "Tasks.ReadWrite.All"]
    }
  } : {}
}

# ------------------------------------------------------------------------------------------------
# Daily workflow content (raw resources, per the standard). Chain: recurrence -> get recent
# messages -> get the board's current task titles -> for each message, create the ticket only when
# no title starts with its MC id.
# ------------------------------------------------------------------------------------------------

resource "azurerm_logic_app_trigger_recurrence" "daily" {
  name         = "Recurrence_-_Every_day_at_07_00_UTC"
  logic_app_id = module.logic_app_workflow.ids[local.daily_name]

  frequency = "Day"
  interval  = 1
  time_zone = "UTC"

  schedule {
    at_these_hours   = [7]
    at_these_minutes = [0]
  }
}

resource "azurerm_logic_app_action_custom" "daily_get_messages" {
  name         = "HTTP_-_Get_recently_touched_Message_Center_messages"
  logic_app_id = module.logic_app_workflow.ids[local.daily_name]

  body = jsonencode({
    description = "Message Center messages modified inside the lookback window, via Graph with the workflow's managed identity. One page of 100 is comfortably above daily volume."
    type        = "Http"
    inputs = {
      method = "GET"
      uri    = "${local.graph}/admin/serviceAnnouncement/messages"
      queries = {
        "$filter"  = "lastModifiedDateTime ge @{formatDateTime(addDays(utcNow(), mul(-1, parameters('daily_lookback_days'))), 'yyyy-MM-ddTHH:mm:ssZ')}"
        "$top"     = "100"
        "$orderby" = "lastModifiedDateTime desc"
      }
      authentication = local.mi_auth
      retryPolicy    = local.retry
    }
    runAfter = {}
  })

  depends_on = [azurerm_logic_app_trigger_recurrence.daily]
}

resource "azurerm_logic_app_action_custom" "daily_get_tasks" {
  name         = "HTTP_-_Get_the_boards_current_task_titles"
  logic_app_id = module.logic_app_workflow.ids[local.daily_name]

  body = jsonencode({
    description = "Every task already on the plan, titles only; the dedupe compares MC id prefixes against these."
    type        = "Http"
    inputs = {
      method = "GET"
      uri    = "${local.graph}/planner/plans/@{parameters('plan_id')}/tasks"
      queries = {
        "$select" = "title"
      }
      authentication = local.mi_auth
      retryPolicy    = local.retry
    }
    runAfter = {
      (azurerm_logic_app_action_custom.daily_get_messages.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "daily_select_titles" {
  name         = "Select_-_Existing_task_titles"
  logic_app_id = module.logic_app_workflow.ids[local.daily_name]

  body = jsonencode({
    description = "Flattens the task objects to a bare list of titles for the per-message filter."
    type        = "Select"
    inputs = {
      from   = "@body('${azurerm_logic_app_action_custom.daily_get_tasks.name}')?['value']"
      select = "@item()?['title']"
    }
    runAfter = {
      (azurerm_logic_app_action_custom.daily_get_tasks.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "daily_foreach" {
  name         = "For_each_-_Create_a_ticket_for_each_new_message"
  logic_app_id = module.logic_app_workflow.ids[local.daily_name]

  # The nested body lives in a template so the structure stays readable; the only Terraform
  # interpolation is structural (action names and Graph constants), per the Logic App standard.
  body = templatefile("${path.module}/templates/daily-foreach-create-tickets.json.tftpl", {
    self_name            = "For_each_-_Create_a_ticket_for_each_new_message"
    get_messages_action  = azurerm_logic_app_action_custom.daily_get_messages.name
    select_titles_action = azurerm_logic_app_action_custom.daily_select_titles.name
    graph                = local.graph
    graph_audience       = local.graph_audience
    admin_link           = local.admin_link
  })
}

# ------------------------------------------------------------------------------------------------
# Monthly workflow content. Chain: recurrence on the 1st -> get last month's messages -> compose
# the rollup title -> get task titles -> create the rollup ticket only when that exact title is
# not on the board yet.
# ------------------------------------------------------------------------------------------------

resource "azurerm_logic_app_trigger_recurrence" "monthly" {
  name         = "Recurrence_-_First_of_the_month_at_06_00_UTC"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  frequency = "Month"
  interval  = 1
  time_zone = "UTC"
  # Monthly triggers anchor to start_time's day of month: this pins runs to the 1st.
  start_time = "2026-08-01T06:00:00Z"
}

resource "azurerm_logic_app_action_custom" "monthly_get_messages" {
  name         = "HTTP_-_Get_last_months_messages"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  body = jsonencode({
    description = "Everything Message Center touched last calendar month, via Graph with the workflow's managed identity."
    type        = "Http"
    inputs = {
      method = "GET"
      uri    = "${local.graph}/admin/serviceAnnouncement/messages"
      queries = {
        "$filter"  = "lastModifiedDateTime ge @{formatDateTime(startOfMonth(subtractFromTime(utcNow(), 1, 'Month')), 'yyyy-MM-ddTHH:mm:ssZ')} and lastModifiedDateTime lt @{formatDateTime(startOfMonth(utcNow()), 'yyyy-MM-ddTHH:mm:ssZ')}"
        "$top"     = "100"
        "$orderby" = "lastModifiedDateTime desc"
      }
      authentication = local.mi_auth
      retryPolicy    = local.retry
    }
    runAfter = {}
  })

  depends_on = [azurerm_logic_app_trigger_recurrence.monthly]
}

resource "azurerm_logic_app_action_custom" "monthly_compose_title" {
  name         = "Compose_-_The_rollup_tickets_title"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  body = jsonencode({
    description = "The rollup title doubles as the dedupe key, so a rerun in the same month is a no-op."
    type        = "Compose"
    inputs      = "Message Center rollup: @{formatDateTime(subtractFromTime(utcNow(), 1, 'Month'), 'yyyy-MM')} (@{length(body('${azurerm_logic_app_action_custom.monthly_get_messages.name}')?['value'])} messages)"
    runAfter = {
      (azurerm_logic_app_action_custom.monthly_get_messages.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "monthly_select_lines" {
  name         = "Select_-_One_summary_line_per_message"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  body = jsonencode({
    description = "The rollup body: one line per message, joined with newlines at write time."
    type        = "Select"
    inputs = {
      from   = "@body('${azurerm_logic_app_action_custom.monthly_get_messages.name}')?['value']"
      select = "- @{item()?['id']} @{item()?['title']}"
    }
    runAfter = {
      (azurerm_logic_app_action_custom.monthly_compose_title.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "monthly_get_tasks" {
  name         = "HTTP_-_Get_the_boards_current_task_titles"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  body = jsonencode({
    description = "Existing task titles, for the exact-title rollup dedupe."
    type        = "Http"
    inputs = {
      method = "GET"
      uri    = "${local.graph}/planner/plans/@{parameters('plan_id')}/tasks"
      queries = {
        "$select" = "title"
      }
      authentication = local.mi_auth
      retryPolicy    = local.retry
    }
    runAfter = {
      (azurerm_logic_app_action_custom.monthly_select_lines.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "monthly_filter_existing" {
  name         = "Filter_-_Tickets_already_carrying_the_rollup_title"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  body = jsonencode({
    description = "Empty when this month's rollup has not been raised yet."
    type        = "Query"
    inputs = {
      from  = "@body('${azurerm_logic_app_action_custom.monthly_get_tasks.name}')?['value']"
      where = "@equals(item()?['title'], outputs('${azurerm_logic_app_action_custom.monthly_compose_title.name}'))"
    }
    runAfter = {
      (azurerm_logic_app_action_custom.monthly_get_tasks.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "monthly_condition_create" {
  name         = "Condition_-_Only_when_this_months_rollup_is_missing"
  logic_app_id = module.logic_app_workflow.ids[local.monthly_name]

  # Template for the same reason as the daily foreach: nested structure reads as JSON, Terraform
  # only wires the action names.
  body = templatefile("${path.module}/templates/monthly-create-rollup.json.tftpl", {
    filter_existing_action = azurerm_logic_app_action_custom.monthly_filter_existing.name
    compose_title_action   = azurerm_logic_app_action_custom.monthly_compose_title.name
    select_lines_action    = azurerm_logic_app_action_custom.monthly_select_lines.name
    graph                  = local.graph
    graph_audience         = local.graph_audience
  })
}
