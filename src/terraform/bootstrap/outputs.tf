output "azure_devops_project_id" {
  value = azuredevops_project.this.id
}

output "azure_devops_project_name" {
  value = azuredevops_project.this.name
}

output "github_service_endpoint_id" {
  value = azuredevops_serviceendpoint_github.this.id
}

output "github_service_endpoint_name" {
  value = azuredevops_serviceendpoint_github.this.service_endpoint_name
}

output "pipeline_ids" {
  value = {
    for k, v in azuredevops_build_definition.pipeline : k => v.id
  }
}

output "pipeline_names" {
  value = {
    for k, v in azuredevops_build_definition.pipeline : k => v.name
  }
}

output "github_repository_full_name" {
  value = local.github_repo_id
}