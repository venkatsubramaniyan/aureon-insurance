
# ADR 0001: Monorepo Architecture

## Status
Accepted

## Context
Aureon Insurance consists of a React frontend, three independently deployable Python backend services, and shared AI orchestration logic.

We need a repository structure that supports independent service deployment while allowing code reuse, consistent testing, and coordinated development.

## Decision
Use a single GitHub monorepo containing:

- `apps/web` — React frontend
- `services/api` — FastAPI backend
- `services/voice-worker` — LiveKit Python voice worker
- `services/ingestion-worker` — Document ingestion worker
- `packages/insurance-ai` — Shared LangGraph agents
- `infra` — Infrastructure definitions
- `tests` — Integration and system tests
- `docs` — Engineering documentation

Each backend service will have its own dependencies, container image, and deployment lifecycle.

The FastAPI backend and voice worker will reuse the shared LangGraph package.

## Alternatives Considered

### Separate repositories
Maintain independent repositories for the frontend, backend services, and shared AI package.

Advantages:
- Strong repository-level separation
- Independent access controls and release processes

Disadvantages:
- More cross-repository coordination
- Additional shared-package version management
- More complex changes spanning multiple services

## Consequences

Benefits:
- Centralized source code and architecture documentation
- Easier cross-service development
- Shared AI logic without duplication
- Consistent integration testing

Trade-offs:
- CI/CD must support independent service builds
- Repository access must be managed carefully
- Shared package changes require compatibility testing

## Review Conditions
Revisit this decision if team ownership, security boundaries, or release requirements make separate repositories more appropriate.
