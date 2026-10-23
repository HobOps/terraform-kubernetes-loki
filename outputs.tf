output "namespace" {
  description = "Namespace where Loki runs."
  value       = kubernetes_namespace.this.metadata[0].name
}

output "internal_url" {
  description = "In-cluster base URL of the Loki gateway (basic auth required)."
  value       = local.internal_url
}

output "external_url" {
  description = "Shared public base URL of the Loki gateway when httproute is set, else null. With tenant_hostnames it only answers the health path."
  value       = local.external_url
}

output "tenants" {
  description = <<-EOT
    Credentials and endpoints per tenant. Send basic auth with username/password
    and the header X-Scope-OrgID equal to the username. *_url_internal work
    inside the cluster; hostname, push_url, query_url and otlp_url are the
    public ones (null without httproute; the tenant's own hostname with
    tenant_hostnames, else the shared one). query_url is the base URL a
    Grafana Loki datasource takes.
  EOT
  sensitive   = true
  value = {
    for t in keys(var.tenants) : t => {
      username           = t
      password           = random_password.tenant[t].result
      hostname           = local.per_tenant_hostnames ? local.tenant_hostname[t] : try(var.httproute.hostname, null)
      push_url           = local.tenant_external_url[t] != null ? "${local.tenant_external_url[t]}/loki/api/v1/push" : null
      query_url          = local.tenant_external_url[t]
      otlp_url           = local.tenant_external_url[t] != null ? "${local.tenant_external_url[t]}/otlp/v1/logs" : null
      push_url_internal  = "${local.internal_url}/loki/api/v1/push"
      query_url_internal = local.internal_url
    }
  }
}
