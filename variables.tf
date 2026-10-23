variable "namespace" {
  description = "Namespace for Loki (created by the module)."
  type        = string
  default     = "loki"
}

variable "release_name" {
  description = "Helm release name. Service names derive from it (e.g. <release>-gateway)."
  type        = string
  default     = "loki"
}

variable "chart_version" {
  description = "Version of the grafana/loki chart."
  type        = string
  default     = "7.5.0"
}

variable "s3" {
  description = <<-EOT
    S3-compatible object storage for chunks, the TSDB index and the ruler
    (one bucket; Loki keys objects by tenant). `endpoint` is host:port without
    scheme; `insecure = true` means plain HTTP. Path-style addressing suits
    Garage and MinIO.
  EOT
  type = object({
    endpoint          = string
    bucket            = string
    region            = optional(string, "us-east-1")
    access_key_id     = string
    secret_access_key = string
    insecure          = optional(bool, false)
    force_path_style  = optional(bool, true)
  })
  sensitive = true
}

variable "tenants" {
  description = <<-EOT
    Tenants, keyed by tenant ID (also the basic-auth username). One per
    customer: hosts go in labels, not in tenants. Every field is optional and
    falls back to `default_limits`; values use Loki's limit names and units
    (retention like "30d", a multiple of 24h; rates in MB/s).
  EOT
  type = map(object({
    retention                   = optional(string)
    ingestion_rate_mb           = optional(number)
    ingestion_burst_size_mb     = optional(number)
    max_global_streams_per_user = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for t in keys(var.tenants) : can(regex("^[a-z0-9][a-z0-9_-]{0,149}$", t))])
    error_message = "Tenant IDs must be lowercase letters, digits, '-' or '_' (no ':' or '|')."
  }
}

variable "default_limits" {
  description = "Limits applied to every tenant unless the tenant overrides them."
  type = object({
    retention                   = optional(string, "30d")
    ingestion_rate_mb           = optional(number, 10)
    ingestion_burst_size_mb     = optional(number, 20)
    max_global_streams_per_user = optional(number, 10000)
  })
  default = {}
}

variable "write_replicas" {
  description = "Write pods (distributor + ingester). Must be >= replication_factor."
  type        = number
  default     = 3
}

variable "read_replicas" {
  description = "Read pods (query-frontend + querier)."
  type        = number
  default     = 2
}

variable "backend_replicas" {
  description = "Backend pods (compactor, index-gateway, ruler, query-scheduler)."
  type        = number
  default     = 2
}

variable "replication_factor" {
  description = "Ingester replication factor (copies of every log line in the write path)."
  type        = number
  default     = 3
}

variable "storage_class" {
  description = "StorageClass for write and backend volumes. null = cluster default. Durable data lives in S3."
  type        = string
  default     = null
}

variable "write_storage_size" {
  description = "Volume size per write pod (WAL)."
  type        = string
  default     = "10Gi"
}

variable "backend_storage_size" {
  description = "Volume size per backend pod (compactor working directory, index cache)."
  type        = string
  default     = "10Gi"
}

variable "httproute" {
  description = <<-EOT
    Optional Gateway API HTTPRoute to the Loki gateway (push and query for
    remote clients). null = no route.

    `hostname` is the shared public hostname. With `tenant_hostnames` set, every
    tenant also gets its own hostname `<prefix>-<tenant>-<random suffix>.<domain>`
    and the gateway accepts a tenant's credentials only on that hostname (or on
    the in-cluster service names); the shared hostname then answers only the
    health path. `domain` must be covered by the listener's certificate: a
    wildcard keeps the tenant names out of Certificate Transparency.
  EOT
  type = object({
    hostname          = string
    gateway_name      = string
    gateway_namespace = string
    section_name      = optional(string, "https")
    tenant_hostnames = optional(object({
      domain        = string
      prefix        = optional(string, "loki")
      suffix_length = optional(number, 8)
    }))
  })
  default = null
}

variable "values" {
  description = "Extra values for the loki chart, applied after the module's (Helm deep-merges maps; lists replace)."
  type        = any
  default     = {}
}
