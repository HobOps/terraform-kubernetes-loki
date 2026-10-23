# terraform-kubernetes-loki

Terraform module that installs a **multi-tenant Grafana Loki** (chart
`grafana/loki`, simple scalable deployment) for a central logs cluster: one
tenant per customer, basic auth per tenant, per-tenant limits and retention,
S3 object storage and an optional Gateway API route for remote clients (Grafana
Alloy, Promtail, OTLP).

It is the logs twin of
[`terraform-kubernetes-mimir`](https://github.com/HobOps/terraform-kubernetes-mimir):
same inputs, same tenant binding at the gateway, same outputs, so a tenant that
exists in both gets the same username and the same kind of hostname.

Providers (`helm`, `kubernetes`, `kubectl`, `random`) are configured by the
**caller**. Where the tenant credentials end up (Vault, SOPS, a Grafana
datasource) is also the caller's choice: the module only outputs them.

## What it deploys

| Piece | Choice |
|---|---|
| Deployment mode | **SimpleScalable**: write (distributor + ingester), read (query-frontend + querier), backend (compactor, index-gateway, ruler, scheduler) |
| Replicas | write `write_replicas` (default 3, replication factor 3), read `read_replicas` (2), backend `backend_replicas` (2) |
| Caches | memcached chunks/results caches off; no canary, no self-test, no bundled MinIO |
| Storage | One S3 bucket for chunks, TSDB index (schema v13) and ruler; volumes on `storage_class` for write (WAL) and backend |
| Config | Rendered into a Secret (it holds the S3 credentials) |
| Auth | nginx gateway with basic auth; one random password per tenant |
| Tenant binding | `X-Scope-OrgID` **must equal the authenticated user**, or the gateway answers 403; every proxied request also gets the header rewritten to the user |
| Per-tenant hostnames | Optional: `<prefix>-<tenant>-<random suffix>.<domain>` per tenant; a tenant's credentials only work on its own hostname |
| Limits | Per-tenant overrides (retention, ingestion rate/burst in MB/s, global streams) in the runtime config; retention enforced by the compactor |

### Why the tenant binding

The chart's nginx forwards whatever `X-Scope-OrgID` the client sends, even with
basic auth enabled: a client with valid credentials could write to or read from
any tenant. The module adds an `httpSnippet`/`serverSnippet` pair that rejects
requests whose header differs from the basic-auth user, and a `locationSnippet`
that sets the header to the user on every proxied request. `/` stays open for
health checks. Tenant federation (`a|b`) is therefore not possible through the
gateway.

### Per-tenant hostnames

With `httproute.tenant_hostnames`, every tenant gets its own public hostname,
`<prefix>-<tenant>-<random suffix>.<domain>` (suffix: lowercase letters and
digits, `suffix_length` long), all on the same HTTPRoute. The gateway maps the
`Host` to a tenant and requires it to match the authenticated user too, so a
tenant's credentials are useless on another tenant's hostname and on the shared
hostname (which then only answers `/`). The in-cluster service names
(`<release>-gateway.<namespace>.svc...`) keep serving every tenant, for Grafana
and collectors inside the cluster.

The `domain` must be covered by the listener's certificate. A wildcard
certificate (`*.<domain>`) keeps the tenant hostnames out of Certificate
Transparency logs; external-dns still publishes one record per hostname.

## Usage

```hcl
module "loki" {
  source = "git::https://github.com/HobOps/terraform-kubernetes-loki.git?ref=v0.0.1"

  tenants = {
    acme   = {}
    globex = { retention = "90d", ingestion_rate_mb = 20 }
  }

  s3 = {
    endpoint          = "s3.example.internal:3900"
    bucket            = "loki"
    region            = "garage"
    access_key_id     = var.s3_access_key_id
    secret_access_key = var.s3_secret_access_key
    insecure          = true # plain HTTP
  }

  storage_class = "local-path"

  httproute = {
    hostname          = "loki.example.com"
    gateway_name      = "public-gateway"
    gateway_namespace = "infrastructure"
    # Optional: one hostname per tenant under a wildcard certificate.
    tenant_hostnames = { domain = "example.com" }
  }
}
```

A client pushes with basic auth `acme:<password>` and the header
`X-Scope-OrgID: acme` to `https://loki-acme-<suffix>.example.com/loki/api/v1/push`
(`https://loki.example.com/loki/api/v1/push` without `tenant_hostnames`); a
Grafana Loki datasource takes the same base URL (`query_url`) with the same
basic auth and header. OTLP logs go to `<same base>/otlp/v1/logs`. The exact
URLs are in the `tenants` output.

See [`examples/complete`](examples/complete).

## Inputs

| Name | Description | Default |
|---|---|---|
| `tenants` | Map of tenant ID → optional `retention`, `ingestion_rate_mb`, `ingestion_burst_size_mb`, `max_global_streams_per_user` | `{}` |
| `default_limits` | Limits for every tenant unless overridden | 30d, 10 MB/s, burst 20 MB, 10000 streams |
| `s3` | `endpoint`, `bucket`, `region`, `access_key_id`, `secret_access_key`, `insecure`, `force_path_style` | required |
| `namespace` | Namespace (created) | `loki` |
| `release_name` | Helm release name | `loki` |
| `chart_version` | `grafana/loki` chart version | `7.5.0` |
| `write_replicas` / `read_replicas` / `backend_replicas` | Pods per target | `3` / `2` / `2` |
| `replication_factor` | Ingester replication factor (≤ `write_replicas`) | `3` |
| `storage_class` | StorageClass for write and backend volumes | cluster default |
| `write_storage_size` / `backend_storage_size` | Volume per write / backend pod | `10Gi` / `10Gi` |
| `httproute` | `hostname`, `gateway_name`, `gateway_namespace`, `section_name`, optional `tenant_hostnames` (`domain`, `prefix` = `loki`, `suffix_length` = 8) | `null` |
| `values` | Extra chart values, merged after the module's | `{}` |

## Outputs

| Name | Description |
|---|---|
| `namespace` | Namespace |
| `internal_url` | In-cluster gateway URL |
| `external_url` | Shared public URL (with `httproute`); health path only when `tenant_hostnames` is set |
| `tenants` | Sensitive: per tenant `username`, `password`, `hostname`, `push_url`, `query_url`, `otlp_url`, `push_url_internal`, `query_url_internal` |

## Notes

- Tenant IDs: lowercase letters, digits, `-` and `_`.
- `retention` values must be multiples of the index period (24h): "7d", "30d", "90d".
- Removing a tenant removes its password (it can no longer push or query); its
  chunks stay in the bucket until the compactor's retention deletes them.
- Rotating a tenant's password:
  `terraform apply -replace='module.<name>.random_password.tenant["<tenant>"]'`.
  Rotating its hostname suffix:
  `terraform apply -replace='module.<name>.random_string.tenant_suffix["<tenant>"]'`.
  Then hand the client the new values from the `tenants` output.
- Upgrading the chart: re-check that the gateway nginx template still defines
  `httpSnippet`, `serverSnippet` and `locationSnippet`, and that `/` is the
  only path served without auth.
