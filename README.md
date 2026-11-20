
# Aureon Insurance

A production-grade, AI-powered insurance assistant supporting real-time voice and text conversations.

## Project Overview

Aureon Insurance enables authenticated customers to:
- Ask general insurance questions.
- Retrieve information about their own insurance policies.
- Interact through text or real-time voice.

The platform also supports authorized test engineers and administrators.

## Architecture

- Frontend: React
- Backend API: FastAPI
- Voice Platform: LiveKit Cloud
- AI Orchestration: LangGraph
- Document Processing: Docling
- Search: Azure AI Search
- Database: Azure Database for PostgreSQL
- Messaging: Azure Event Grid and Service Bus
- Cloud Platform: Microsoft Azure

## Repository Structure

- `apps/web` — React frontend
- `services/api` — FastAPI backend
- `services/voice-worker` — LiveKit voice worker
- `services/ingestion-worker` — Document ingestion worker
- `packages/insurance-ai` — Shared LangGraph agents
- `infra` — Infrastructure configuration
- `tests` — Integration and system tests
- `docs` — Architecture decisions and project documentation

## Development Approach

Understand → Implement → Verify → Review → Commit

Each component is implemented incrementally with an emphasis on security, reliability, testing, and maintainability.

## Dev infrastructure: Batches 3–7

The [deployment guide](docs/batches-3-7-deployment.md) describes the opt-in
AI, data, hosting, frontend and monitoring configuration, approval gates
and rollout order. See [ADR 0002](docs/adr/0002-private-azure-workloads.md)
for the private hosting and frontend integration decisions.

## Dev document storage

The dev Terraform configuration manages the existing `staureonappdev001`
account and `insurance-documents` container. It uses the existing Blob
private DNS zone and creates a Blob private endpoint before disabling public
network and shared-key access. The account and container resource addresses
are unchanged. AzureRM is pinned to 4.81.0; its storage data-plane feature is
disabled because this environment does not manage `queue_properties` or
`static_website`. Those blocks cannot be managed while that feature is
disabled. The provider is also configured to use Microsoft Entra ID for
supported Blob and Queue data-plane operations.

Before deploying:

1. Confirm the subscription, existing account, subnet, DNS zone and VNet link
   are the intended resources. The DNS zone is read, not created or imported.
2. Verify that the container's Terraform state ID is its ARM resource ID
   (`.../blobServices/default/containers/insurance-documents`). AzureRM
   4.81.0 uses ARM for the container when `storage_account_id` and an ARM ID
   are used. A legacy data-plane state ID can follow a different provider
   path; resolve any migration or unexpected replacement in the plan before
   disabling shared-key access. Never publish state or account keys.
3. Check the GitHub Actions identity's effective permissions. Container
   management through ARM requires container `read`, `write`, and `delete`
   management actions, scoped to the existing container or inherited from the
   account. An existing management role may already grant these; no Blob data
   role is needed just to manage this ARM-based container. The identity also
   needs the appropriate account, private endpoint, subnet join, DNS zone
   read/join, and existing remote-state permissions. Do not grant roles
   automatically or duplicate existing grants.
4. Review a plan for endpoint creation and **in-place** account changes only;
   stop if the account or container would be replaced. For a safer cutover,
   first review and apply a targeted plan for
   `azurerm_private_endpoint.app_storage_blob`, then verify its approval,
   private DNS resolution, and connectivity from every actual client network.
   Review a fresh full plan before applying the public-network and shared-key
   lockdown. Terraform ordering alone does not verify client connectivity.
   The [Dev Batch 3 workflow](docs/batches-3-7-deployment.md#manual-dev-batch-3-rollout)
   does not apply storage cutover changes.
5. Inventory clients using account keys, account/service SAS, or public
   endpoints and migrate them before lockdown. Public access is disabled for
   the entire account, but only a Blob private endpoint is configured; Queue,
   File, Table, and static-website clients need separately designed access.
   Confirm the self-hosted runner still reaches the separate remote-state
   backend. That backend is not modified by this configuration.

For a future ingestion worker that only reads documents, assign **Storage Blob
Data Reader** at the `insurance-documents` container scope to its actual
managed identity once known. If it must write or delete blobs, decide the
required operations first: Storage Blob Data Contributor also permits deletion
and is not a read-only role. No worker identity or role assignment is created
here.

## Dev document ingestion events

Batch 2 adds an Event Grid system topic for `staureonappdev001` and a
subscription for `Microsoft.Storage.BlobCreated` events whose subject starts
with `/blobServices/default/containers/insurance-documents/blobs/`. The
subscription delivers Event Grid schema events to the
`insurance-document-ingestion` queue in `sb-aureon-ingest-dev-eastus`. Blob
creation includes replacement of an existing blob. Objects created before
the subscription is active are not backfilled.

The topic's system-assigned identity has the **Azure Service Bus Data Sender**
role at the queue scope. Delivery explicitly uses that identity; the namespace
disables SAS/local authentication and requires TLS 1.2. No credentials are
configured. AzureRM 4.81.0 nevertheless attempts to list the namespace's
default SAS keys on refresh and may put returned connection strings and keys
in Terraform state. Where feasible, exclude
`Microsoft.ServiceBus/namespaces/authorizationRules/listKeys/action` from
the Terraform identity's effective permissions and protect the existing
remote state as sensitive. The provider tolerates a failed key lookup. Do not
print state or keys when verifying permissions.

The queue is durable (not express), unpartitioned, with a 1 GiB limit,
14-day message TTL, five-minute lock, ten delivery attempts, and dead-lettering
on expiration. Duplicate detection is enabled for ten minutes, but only
suppresses messages with the same Service Bus `MessageId` in that window.
Do not assume Event Grid retries always use the same `MessageId`: the worker
must be idempotent using the event ID and appropriate blob version/ETag
semantics. Queue dead-letter messages need monitoring and an operator replay
process; DLQ messages count toward the queue size and are not automatically
cleaned up. These limits and retention are initial dev assumptions and should
be reviewed for expected volume and recovery time.

Event Grid retries delivery for up to 30 attempts or 24 hours, whichever is
reached first; some errors, including 403, are not retried. Undelivered events
are configured to be dead-lettered to the private `eventgrid-deadletters`
container in the existing application account. The system topic's
system-assigned identity has the existing **Storage Blob Data Contributor**
grant at the application storage account's ARM scope. This built-in role also
permits blob deletion and covers the document container; the destination
itself remains the dedicated dead-letter container. Dead-letter blob subjects
do not match the document subscription's prefix.

Event Grid push delivery does not use the account's private endpoint. It uses
managed identity and the storage trusted-services exception. The account was
observed with `publicNetworkAccess = Disabled`, shared-key access disabled,
and network bypass `AzureServices`; Azure Storage documents that existing
trusted-service exceptions can remain effective even when public network
access is disabled, and lists Event Grid system topics as trusted
managed-identity resources. This is not a private-IP-only network path.
Terraform does not manage or enforce the account's existing network rules;
verify the `AzureServices` bypass before deployment and monitor it for drift.
Do not remove the exception without replacing the delivery design, and do not
enable public Blob access or shared keys as a workaround.

The configuration is not proof of end-to-end delivery. After an approved
deployment, allow RBAC propagation and perform a controlled test that
produces an undeliverable event, then read the dead-letter blob from an
authorized private client. Microsoft notes a delay of around five minutes
before dead-lettering and drops events if the dead-letter destination remains
unavailable for four hours. Configure operational alerts, periodically test
the path, and implement reconciliation/backfill; this is not a guarantee of
lossless delivery. Until the test succeeds, treat this path as unverified.

### Networking and future worker

The dev Service Bus namespace uses Standard to support duplicate detection
without provisioning Premium capacity. Its public network endpoint is
enabled; access requires an authorized Entra identity, not a connection
string, but the endpoint is not network-private. No Service Bus firewall,
private endpoint, or DNS zone is introduced. Service Bus Private Link requires
Premium; moving from Standard requires a new namespace/migration, not an
in-place upgrade. A future Premium design must include private DNS, worker
connectivity and the supported trusted-service exception for Event Grid
system-assigned identity delivery. Verify those paths before disabling public
access.

When the Python worker exists, evaluate an event-driven Azure Container Apps
worker with minimum replicas zero and a Service Bus scale rule using managed
identity, or another short-lived host appropriate to document-processing
duration. Validate the scaler's identity and network requirements, quotas,
cost and cold-start behavior before choosing a host. It must have private
Blob DNS resolution and routing to the existing Blob private endpoint; that
may require a separately planned, delegated Container Apps subnet, not
repurposing the existing runner or private-endpoint subnet. It also needs
outbound HTTPS/AMQP connectivity to the Standard Service Bus endpoint.

Assign the actual worker identity **Azure Service Bus Data Receiver** at the
queue scope and **Storage Blob Data Reader** at the source-container scope
only when the identity exists. Use peek-lock, renew locks for long processing,
complete only after durable processing, and handle duplicate, overwritten,
deleted and out-of-order blobs. No worker, identity, host or worker role
assignment is provisioned in this batch.

### Deployment prerequisites and review

- `Microsoft.EventGrid` and `Microsoft.ServiceBus` must be registered
  separately at subscription scope; automatic provider registration remains
  disabled. Verify registration before deployment.
- Confirm the GitHub `AZURE_CLIENT_ID` dev environment variable identifies
  the intended OIDC service principal. Its object ID and effective grants
  could not be established from the checked-in workflow. It needs management
  permissions for the namespace, queue, system topic and subscription;
  `Microsoft.EventGrid/EventSubscriptions/Write` at the source storage
  account; write access to the destination queue; and
  `Microsoft.Authorization/roleAssignments/write`, read and delete at the
  queue and application storage account scopes to manage the sender and blob-writer
  grants. It also needs ARM container read/write/delete permissions to manage
  the dead-letter container. Check existing inherited grants before
  requesting additional permissions. Provider registration requires separate
  subscription-level authority.
- Confirm the chosen globally unique namespace name is still available and
  that no system topic already exists for the storage account. A namespace
  availability check and subscription topic list were clear during
  inspection.
- Role assignment ordering does not guarantee Entra/RBAC propagation. Before
  uploads begin, allow propagation and verify delivery with a controlled
  `BlobCreated` event and an authorized queue receiver. Verify that a blob in
  another container and a non-creation event do not enqueue messages. Avoid
  sending sensitive documents during this check.
- Review a fresh plan for the messaging resources, dedicated dead-letter
  container and two role assignments, and separately inspect any pending
  Batch 1 changes. Stop
  for any unexpected replacement of storage, container, network or backend
  resources. The [Dev Batch 3 workflow](docs/batches-3-7-deployment.md#manual-dev-batch-3-rollout)
  does not apply messaging changes.

References: [Event Grid managed-identity delivery](https://learn.microsoft.com/en-us/azure/event-grid/deliver-events-using-managed-identity),
[delivery and retry](https://learn.microsoft.com/en-us/azure/event-grid/delivery-and-retry),
[trusted Azure services](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-trusted-azure-services),
[storage firewall limitations](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-limitations),
[Service Bus duplicate detection](https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection),
and [Service Bus Private Link](https://learn.microsoft.com/en-us/azure/service-bus-messaging/private-link-service).
