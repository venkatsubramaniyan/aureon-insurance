ai = {
  openai_name = "aoai-aureon-dev-eastus"
  search_name = "srch-aureon-dev-eastus"
  search_sku  = "basic"

  deployments = {
    chat = {
      model    = "gpt-5.4-mini"
      version  = "2026-03-17"
      sku      = "DataZoneStandard"
      capacity = 10
    }

    embeddings = {
      model    = "text-embedding-3-large"
      version  = "1"
      sku      = "Standard"
      capacity = 10
    }
  }
}

workload_dns_zone_ids = {}

batch4_postgresql    = null
batch4_managed_redis = null
registry_name        = null
container_apps       = null
workload_images      = {}
deploy_workloads     = false
frontend             = null
monitoring           = null
