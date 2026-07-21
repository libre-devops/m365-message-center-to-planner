output "grant_commands" {
  description = "The two Graph APPLICATION role grants each workflow identity needs, ready to run as a Global Administrator (aka the one manual step)."
  value = [
    for name, identity in module.logic_app_workflow.identities : join(" ", [
      "az rest --method POST --url https://graph.microsoft.com/v1.0/servicePrincipals/${identity.principal_id}/appRoleAssignments",
      "--body '{\"principalId\":\"${identity.principal_id}\",\"resourceId\":\"fd0a2338-d25b-431d-a8fd-e58500282a5d\",\"appRoleId\":\"1b620472-6534-4fe6-9df2-4680e8aa28ec\"}'",
      "&& az rest --method POST --url https://graph.microsoft.com/v1.0/servicePrincipals/${identity.principal_id}/appRoleAssignments",
      "--body '{\"principalId\":\"${identity.principal_id}\",\"resourceId\":\"fd0a2338-d25b-431d-a8fd-e58500282a5d\",\"appRoleId\":\"44e666d1-d276-445b-a5fc-8815eeb81d55\"}'",
    ])
  ]
}

output "workflow_ids" {
  description = "Map of workflow name to resource id."
  value       = module.logic_app_workflow.ids
}

output "workflow_principal_ids" {
  description = "Map of workflow name to its managed identity principal id."
  value       = { for name, identity in module.logic_app_workflow.identities : name => identity.principal_id }
}
