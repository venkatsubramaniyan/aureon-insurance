
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
