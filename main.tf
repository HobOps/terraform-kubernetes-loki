locals {
  gateway_service = "${var.release_name}-gateway"
  internal_url    = "http://${local.gateway_service}.${var.namespace}.svc.cluster.local"
  external_url    = var.httproute != null ? "https://${var.httproute.hostname}" : null

  # Per-tenant public hostnames: <prefix>-<tenant>-<random suffix>.<domain>.
  # "_" is valid in a tenant ID but not in a hostname.
  per_tenant_hostnames = var.httproute != null && try(var.httproute.tenant_hostnames, null) != null
  tenant_hostname = local.per_tenant_hostnames ? {
    for t in keys(var.tenants) :
    t => "${var.httproute.tenant_hostnames.prefix}-${replace(t, "_", "-")}-${random_string.tenant_suffix[t].result}.${var.httproute.tenant_hostnames.domain}"
  } : {}
  tenant_external_url = {
    for t in keys(var.tenants) : t => local.per_tenant_hostnames ? "https://${local.tenant_hostname[t]}" : local.external_url
  }

  # Hostnames the gateway serves for any authenticated tenant: the in-cluster
  # service names (Grafana, in-cluster Alloy) and local port-forwards. They are
  # not reachable through the public Gateway, whose routes only carry the
  # public hostnames.
  internal_hostnames = [
    local.gateway_service,
    "${local.gateway_service}.${var.namespace}",
    "${local.gateway_service}.${var.namespace}.svc",
    "${local.gateway_service}.${var.namespace}.svc.cluster.local",
    "localhost",
    "127.0.0.1",
  ]
  nginx_host_map = join("\n", concat(
    [for h in local.internal_hostnames : "  ${h} \"*\";"],
    [for t in sort(keys(local.tenant_hostname)) : "  ${local.tenant_hostname[t]} \"${t}\";"],
  ))

  # Per-tenant limits for Loki's runtime config (overrides). Each tenant gets
  # every limit explicitly, so changing default_limits applies to all of them.
  tenant_overrides = {
    for t, cfg in var.tenants : t => {
      retention_period            = coalesce(cfg.retention, var.default_limits.retention)
      ingestion_rate_mb           = coalesce(cfg.ingestion_rate_mb, var.default_limits.ingestion_rate_mb)
      ingestion_burst_size_mb     = coalesce(cfg.ingestion_burst_size_mb, var.default_limits.ingestion_burst_size_mb)
      max_global_streams_per_user = coalesce(cfg.max_global_streams_per_user, var.default_limits.max_global_streams_per_user)
    }
  }

  htpasswd = join("\n", [
    for t in sort(keys(var.tenants)) : "${t}:${random_password.tenant[t].bcrypt_hash}"
  ])

  # The chart's nginx forwards whatever X-Scope-OrgID the client sends, even
  # with basic auth on, so a client could pick any tenant. These snippets
  # reject (403) any request whose X-Scope-OrgID differs from the authenticated
  # user. "/" (the gateway's health path) stays open. The check runs in the
  # rewrite phase, before auth_basic: a right header with a wrong password
  # still gets 401 afterwards. As a second guard, every proxied location also
  # rewrites X-Scope-OrgID to the authenticated user (location snippet).
  #
  # With per-tenant hostnames the Host must also belong to that tenant
  # ($tenant_host = tenant), or be an in-cluster name ($tenant_host = "*").
  # Any other Host, the shared public hostname included, only serves "/".
  nginx_http_snippet = local.per_tenant_hostnames ? local.nginx_http_snippet_per_tenant : local.nginx_http_snippet_shared

  nginx_http_snippet_per_tenant = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      default  0;
    }
    map $host $tenant_host {
      hostnames;
      default "";
    ${local.nginx_host_map}
    }
    map "$tenant_check_public:$tenant_host:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                      1;
      "~^0:\*:([^:|]+):\1$"       1;
      "~^0:([^:|*]+):\1:\1$"      1;
      default                     0;
    }
  EOT

  nginx_http_snippet_shared = <<-EOT
    map $uri $tenant_check_public {
      "/"      1;
      default  0;
    }
    map "$tenant_check_public:$remote_user:$http_x_scope_orgid" $tenant_check_ok {
      "~^1:"                1;
      "~^0:([^:|]+):\1$"    1;
      default               0;
    }
  EOT

  nginx_server_snippet = <<-EOT
    if ($tenant_check_ok = 0) {
      return 403 "use your tenant's hostname with its basic auth and X-Scope-OrgID equal to the user\n";
    }
  EOT

  nginx_location_snippet = "proxy_set_header X-Scope-OrgID $remote_user;"

  module_values = {
    # Simple scalable deployment: write (distributor + ingester), read
    # (query-frontend + querier) and backend (compactor, index-gateway, ruler,
    # scheduler). Object storage is mandatory in this mode.
    deploymentMode = "SimpleScalable"

    loki = {
      auth_enabled = true
      # The rendered config holds the S3 credentials: keep it in a Secret.
      configStorageType = "Secret"

      commonConfig = {
        replication_factor = var.replication_factor
      }

      storage = {
        type = "s3"
        bucketNames = {
          chunks = var.s3.bucket
          ruler  = var.s3.bucket
          admin  = var.s3.bucket
        }
        s3 = {
          endpoint         = var.s3.endpoint
          region           = var.s3.region
          accessKeyId      = var.s3.access_key_id
          secretAccessKey  = var.s3.secret_access_key
          s3ForcePathStyle = var.s3.force_path_style
          insecure         = var.s3.insecure
        }
      }

      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]
      }

      # Tenants not listed in var.tenants cannot authenticate, but keep the
      # global defaults equal to default_limits anyway.
      limits_config = {
        retention_period            = var.default_limits.retention
        ingestion_rate_mb           = var.default_limits.ingestion_rate_mb
        ingestion_burst_size_mb     = var.default_limits.ingestion_burst_size_mb
        max_global_streams_per_user = var.default_limits.max_global_streams_per_user
        allow_structured_metadata   = true
      }

      # Retention is enforced by the compactor (runs in the backend pods).
      compactor = {
        retention_enabled    = true
        delete_request_store = "s3"
      }

      runtimeConfig = {
        overrides = local.tenant_overrides
      }
    }

    write = {
      replicas = var.write_replicas
      persistence = merge(
        { size = var.write_storage_size },
        var.storage_class != null ? { storageClass = var.storage_class } : {},
      )
    }

    read = {
      replicas = var.read_replicas
    }

    backend = {
      replicas = var.backend_replicas
      persistence = merge(
        { size = var.backend_storage_size },
        var.storage_class != null ? { storageClass = var.storage_class } : {},
      )
    }

    # No memcached, no self-tests, no canary, no bundled MinIO.
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    test         = { enabled = false }
    lokiCanary   = { enabled = false }
    minio        = { enabled = false }

    gateway = {
      enabled = true
      basicAuth = {
        enabled        = true
        existingSecret = kubernetes_secret.htpasswd.metadata[0].name
      }
      nginxConfig = {
        httpSnippet     = local.nginx_http_snippet
        serverSnippet   = local.nginx_server_snippet
        locationSnippet = local.nginx_location_snippet
      }
    }
  }
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "tenant" {
  for_each = var.tenants

  length  = 48
  special = false
}

# Random part of each tenant's public hostname. Rotate it with
# terraform apply -replace='module.<name>.random_string.tenant_suffix["<tenant>"]'.
resource "random_string" "tenant_suffix" {
  for_each = local.per_tenant_hostnames ? var.tenants : {}

  length  = var.httproute.tenant_hostnames.suffix_length
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "kubernetes_secret" "htpasswd" {
  metadata {
    name      = "${var.release_name}-gateway-htpasswd"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    ".htpasswd" = local.htpasswd
  }
}

resource "helm_release" "loki" {
  name       = var.release_name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name
  timeout    = 900
  wait       = true

  values = [
    yamlencode(local.module_values),
    yamlencode(var.values),
  ]
}

resource "kubectl_manifest" "httproute" {
  count = var.httproute != null ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = local.gateway_service
      namespace = var.namespace
    }
    spec = {
      parentRefs = [{
        name        = var.httproute.gateway_name
        namespace   = var.httproute.gateway_namespace
        sectionName = var.httproute.section_name
      }]
      hostnames = concat([var.httproute.hostname], [for t in sort(keys(local.tenant_hostname)) : local.tenant_hostname[t]])
      rules = [{
        matches     = [{ path = { type = "PathPrefix", value = "/" } }]
        backendRefs = [{ name = local.gateway_service, port = 80 }]
      }]
    }
  })

  depends_on = [helm_release.loki]
}
