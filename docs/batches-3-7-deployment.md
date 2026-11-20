# Dev infrastructure: Batches 3–7

These are opt-in additions to the existing Dev Terraform root, not new state
files or changes to Batches 1–2. The tests contain fictitious deployment data,
not deployable defaults. Once an input has been applied, do not reset it to
`null`, remove an image key, or turn off `deploy_workloads` as a pause
mechanism: Terraform can plan deletions. Use a reviewed full plan for each
group, not routine `-target`. Stop on unexpected change to any existing
resource, deletion or replacement. The Dev workflows described below are
restricted to Batch 3; they are not a deployment mechanism for Batches 4–7.

## What each group adds

| Batch | Inputs and expected additions | Cost and operational decisions |
|---|---|---|
| 3 | `ai`: OpenAI S0 account with explicit versioned model deployments; AI Search (one replica and partition); private endpoints and linked DNS; API/worker data roles supplied by Batch 5. | Price token-based chat/embedding use, or provisioned capacity separately. Approve deployment type for data residency, model retirement/upgrade policy, capacity and quota. Paid Search units run continuously. One unit is Dev capacity, not an HA guarantee. Confirm vector/index limits. |
| 4 | `batch4_postgresql`, `batch4_managed_redis`: privately delegated Entra-only Flexible Server and bootstrap Entra group; TLS/Entra-only Managed Redis through Private Link (no access keys). | Both are recurring compute costs. PostgreSQL uses service-managed encryption at rest, default TLS enforcement and configured 7–35 day backups, local by default. Approve version, tier, storage, geo backup and restore RPO/RTO before creation. For clients require TLS hostname verification. Redis is a disposable cache (no application recovery from it, no persistence configured); approve size, HA cost (service default enabled), cluster-aware client and rebuild behavior. |
| 5 | `registry_name`, `container_apps`, `workload_images`, `deploy_workloads`: private Premium ACR, dedicated ACA subnet, internal Consumption environment/DNS, per-app identities/roles and optionally two revisions. | Premium ACR is required for Private Link and bills even when idle. API can scale to zero; account for cold starts. The deployed polling worker uses one replica and incurs recurring consumption. No VM, VM changes, or dedicated compute profile. |
| 6 | `frontend`: private SWA Standard site shell with a partition-specific private DNS zone or an existing linked zone. No React artifacts, linked backend or customer authentication are provisioned. | Standard and Private Link bill even before release. Verify SWA deployment region independently of the endpoint's East US location. Private Dev client ingress is not customer ingress. |
| 7 | `monitoring`: Log Analytics, workspace-based Application Insights, Azure Monitor Private Link Scope and private endpoint; diagnostics on Blob, Event Grid, Service Bus, AI and ACA where enabled; queue depth/DLQ, Event Grid failures/dead letters, Search throttling, API 5xx, PostgreSQL storage, and Redis memory alerts. | Ingestion, retained data, metric alerts and notifications may incur charges. Approve an existing action group, thresholds and daily cap. A cap can interrupt observability; monitor usage. Platform alerts aren't end-to-end availability checks. |

Use the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
with approved regions/SKUs. Separate the fixed monthly floor (roughly 730
hours of always-on meters, registry/site base charge, private endpoints, DNS
zones) from requests, tokens, throughput, telemetry, retention and egress.
No subscription-specific dollar estimate is represented by the mock inputs.

### Manual Dev Batch 3 rollout

Both workflows explicitly select the non-secret
[`batch3.workflow.tfvars`](../infra/terraform/environments/dev/batch3.workflow.tfvars)
from the checked-out commit. It disables Batches 4–7. The earlier local
`batch3.dev.tfvars` remains ignored and is not used by CI. Neither workflow
runs on push, and both are restricted to the default branch.

1. Manually run **Aureon Terraform Dev - Plan Batch 3** on the default branch.
   Review the full plan and copy the commit SHA shown in the run summary.
   Stop if the guard rejects the plan; do not use `-target` to bypass it.
   The guard compares refresh drift separately from planned actions. It warns
   for the existing document Event Grid subscription only when Terraform
   plans no action and the only refresh differences are unset versus empty
   labels or unset versus disabled array filtering. Other drift outside
   Batch 3 blocks the run. The guard reports field names, not values; inspect
   a fresh plan in a trusted environment before classifying new differences.
2. Manually run **Aureon Terraform Dev - Apply Batch 3** and provide that
   SHA as `reviewed_commit`. If the branch advanced, review a new plan.
   Apply independently generates and checks a fresh full plan, then applies
   that saved file without replanning. The SHA check ties the runs to the
   same configuration; it is an operator attestation, not proof of a prior
   review or approval of the exact earlier plan. Live state can change
   between runs.
3. Keep the default branch protected, restrict the `dev` environment to
   trusted refs, and configure required reviewers where available. The same
   environment applies to both workflows. The shared concurrency group
   prevents simultaneous Dev workflow runs and the existing Terraform
   backend still provides state locking. The Linux runner needs `python3`.
   Binary plans may contain sensitive state: they are kept in a restricted
   runner temp directory, not uploaded, and removed on normal shell exit.
   Restrict runner and workflow-log access; a forced runner stop can leave
   temporary files.

The deployment names are `chat` (GPT‑5.4 mini, US Data Zone Standard) and
`embeddings` (text-embedding-3-large, regional Standard), both with capacity
`10`. The empty DNS map requests new private zones and links; substitute
verified existing linked zone IDs if applicable. When defining the Search
index, use the same vector dimensions for the index, ingestion and query
embeddings; the large model returns 3,072 dimensions by default.

## Review and deployment order

1. **Preflight.** Have a subscription operator check/register
   `Microsoft.CognitiveServices`, `Microsoft.Search`, `Microsoft.DBforPostgreSQL`,
   `Microsoft.Cache`, `Microsoft.ContainerRegistry`, `Microsoft.App`,
   `Microsoft.Web`, `Microsoft.OperationalInsights`, and `Microsoft.Insights`;
   these were observed unregistered. Confirm `Microsoft.ManagedIdentity`
   (observed registered), `Microsoft.Network`, and existing storage/messaging
   registrations. Terraform registration stays `none`. Provider schema and
   regional catalog visibility are not guarantees of East US SKU availability,
   model entitlement, capacity, or quota for this subscription. Verify names,
   policy and quotas in Azure before deployment.
2. **Private foundations.** Approve distinct, nonoverlapping CIDRs inside
   `vnet-aureon-dev-eastus` (ACA /27 or larger; PostgreSQL /28 or larger).
   Verify IP capacity in `snet-aureon-private-endpoints-dev`, routing, custom
   DNS forwarding if used, and required outbound service dependencies.
   The runner, Bastion and existing endpoint subnets must not be delegated.
   Inventory linked zones and supply existing zone ARM IDs for reuse via
   `workload_dns_zone_ids` or the service-specific inputs; omission means
   approval to create a zone and link. The existing Blob zone is reused
   automatically, and the existing vault and its endpoint are not changed.
   Stage AI/data/registry/environment independently as approved. Do private
   DNS, TLS and positive/negative Entra access tests from the VNet.
3. **Application and identity preparation.** Build and publish immutable
   image digests from an approved VNet client; app images are not implemented
   here. Grant its publisher `AcrPush` at this registry (not the runtime
   identities); verify the intended publisher and OIDC grants rather than
   creating a new CI identity. Set `workload_images` and leave
   `deploy_workloads = false` to stage identities and grants. Allow RBAC
   propagation before deploying revisions. The app roles are registry
   `AcrPull`, account `Cognitive Services OpenAI User`, and Search data
   reader (API) or data contributor (worker) at the dedicated service.
   Only the worker gets queue Data Receiver and source-container Blob Data
   Reader. Verify the app's actual indexes; provision schemas separately
   and narrow to index scope where possible before sharing a Search service.
   Optional Key Vault grants are `Key Vault Secrets User` at confirmed secret
   ARM scopes; configure SDK retrieval through the existing private vault
   without injecting values into Terraform. Opt-in Redis policy applies to
   the API only and is **full command/key access to this dedicated cache**;
   approve it separately. The locked provider does not expose a custom
   command/key ACL. Do not enable it for a shared cache. Use an Entra token
   refreshing Redis client. From a private migration runner, the PostgreSQL
   bootstrap group creates application database/roles and maps identities to
   narrow SQL permissions; runtime identities are not server administrators.
4. **Monitoring and workload smoke tests.** Verify that no other Monitor
   scope conflicts with VNet DNS; adding an AMPLS endpoint affects shared
   DNS. Open scope access modes avoid blocking unrelated Monitor resources
   using those zones; the new workspace and Insights disable internet query
   and ingestion. Verify actual diagnostic categories, metric dimensions
   and delivery to the private workspace in Azure. Configure Python
   OpenTelemetry with Entra, the Insights connection metadata and private
   DNS; do not export customer data, document text or tokens. Enable app
   revisions only after the backend validates Entra tokens for protected
   endpoints and the app settings/SDKs are wired. Only `AZURE_CLIENT_ID` is
   wired here; service hostnames, deployment/index names, data roles and
   application settings need a defined contract. Test private API health,
   synthetic authorized and unauthorized requests, queue receive/ack/retry
   and dead-letter/replay paths separately. Queue delivery alone does not
   verify Event Grid Blob dead-letter delivery. Verify HTTP alert dimension
   values and add a VNet-based synthetic availability check and OpenAI
   throttling/latency thresholds when the app SLO and telemetry are known.
   Keep outbound network access to the existing Entra-only Standard Service
   Bus endpoint; Premium Private Link requires a namespace migration.
5. **Private frontend, then a separate release decision.** Validate the
   assigned SWA hostname partition and reuse its linked zone if present.
   Confirm the build/deploy artifact workflow and private test client.
   AzureRM 4.81.0 exposes a computed SWA deployment API key, so treat Terraform
   state as credential-bearing even though no key is input or output. Keep
   state access constrained and approve the frontend deployment auth
   separately without changing Terraform's GitHub OIDC. Do not publish
   customer content until a supported private `/api` path, an approved
   Entra tenant/app registration and audience, route/app-role rules and API
   token validation are proven. There is no native linked backend resource
   in this AzureRM pin; approve a supported ARM/provider path separately
   if the topology qualifies. Do not expose the API as a workaround.

The Terraform GitHub OIDC identity needs management read/write/delete only
for enabled resource types, VNet/subnet join and private endpoint approval
permissions, DNS zone/link/zone-group permissions and scoped role-assignment
management (`read`, `write`, `delete`) where the above grants are applied.
Verify cross-resource scopes (DNS, vault secrets and action group), Entra
group object ID/tenant, and access to read/join the existing resources as
applicable. Restrict delegation to the intended role definitions/principals
where possible. SWA additionally requires the provider's `listSecrets` access
when enabled. No subscription Owner or Terraform data roles are assumed.

See [ADR 0002](adr/0002-private-azure-workloads.md),
[ACA networking](https://learn.microsoft.com/azure/container-apps/networking),
[SWA private endpoints](https://learn.microsoft.com/azure/static-web-apps/private-endpoint),
[PostgreSQL Entra configuration](https://learn.microsoft.com/azure/postgresql/security/security-entra-configure),
and [Managed Redis permissions](https://learn.microsoft.com/azure/redis/configure-access-permissions).
