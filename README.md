
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
   The existing apply workflow uses `-auto-approve` and creates its own plan;
   do not dispatch it until the cutover is approved, and use a reviewed saved
   plan if approval of the exact changes is required.
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
