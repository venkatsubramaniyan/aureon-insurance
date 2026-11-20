# ADR 0002: Private Azure workloads and staged delivery

**Status:** Accepted hosting direction for Dev; frontend/API integration and
deployment inputs are pending approval.

Run the independently built Docker API and ingestion images in an internal,
VNet-integrated Azure Container Apps workload profiles environment. Use the
existing VM only in its current build/runner role, not as an application
server. Keep LiveKit Cloud and the voice-worker lifecycle separate; this change
does not deploy the voice worker or change LiveKit networking.

Use private endpoints for OpenAI, AI Search, Managed Redis, ACR, Azure Monitor
and Static Web Apps. Use private VNet integration and a dedicated delegated
subnet for PostgreSQL, separate from the Container Apps subnet. Keep Entra
and managed identity as the default data access model. Existing Service Bus
Standard is an explicit exception to network-private data access; leave it
Entra-only and do not add an unsupported private endpoint.

Use private SWA Standard initially for VNet-based testing. A linked API is the
preferred frontend integration **only** after Azure support for the selected
private topology is proven and Entra login, app roles and API token validation
are designed. SWA Private Link controls client ingress, not proxy egress into
the VNet. Do not expose the API just to make linking work, or bypass token
validation because a client is on the VNet.

Do not grant Service Bus Data Owner to make a scaler work. Until the minimal
scaler permission and private topology are verified, the optional ingestion
revision uses one polling replica and queue-scoped Data Receiver. Offer no
ingestion image or running revision until application code and operating cost
are approved. Review the polling choice once load and latency are known.

Do not copy the Dev names, network IDs, capacity or account-scoped decisions
into higher environments. Use independently approved inputs and separate state
and identities for QA, UAT, Staging and Production; extract modules when a
second environment is prepared. Reassess HA, disaster recovery, customer
ingress, command/index-level access controls and service quotas at that point.
