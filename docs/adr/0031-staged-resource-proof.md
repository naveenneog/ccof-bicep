# ADR 0031: resource-only Stage 1 and explicit later-stage boundaries

Status: accepted for Stage 1; later-stage entry points remain pending.
Date: 2026-10-20.

## Context

The repository has a four-stage customer runbook and multiple integrated paths
that bundle resources, networking, schema, grants or settings. The approved new
plan separates stages 0-8 by ownership and permission boundary. Using the old
stage numbers without a mapping would make a deployment instruction ambiguous.

## Decision

Reuse `infra/staged/main.bicep` for Stage 1. Do not copy the resource definitions
or modify existing quickstart/manual/admin templates. Its resource-only boundary
has passed a new isolated lab deployment and live property read-back.

The new [runbook](../runbooks/STAGED-DEPLOYMENT-V2.md) explicitly labels later
stages as not yet implemented. Old stage 2 maps to new stages 4/5; old stage 3
maps to new stages 3/6/7; old stage 4 maps to new stages 2/8. Both use the same
resource-only Stage 1. Network prerequisites gate publishing regardless of numbering.

A local Ironclad charter/gate and scoped status/unknowns/change log record this
work. No hooks, CI replacement, production-code changes or additional grants are
introduced by that setup.

## Alternatives

- Reuse integrated templates: rejected because they cross the approved boundary.
- Rewrite service resources: rejected because the existing staged definitions
  already implement the boundary and passed provider verification.
- Build all later stages during the proof: deferred to avoid expanding the
  resources-only acceptance packet.

## Consequences

No provider-driven Bicep fix was needed for the tested lab configuration.
Resource provisioning is not application readiness. APIM stays deferred without
separate public-bootstrap approval. The retained shells need network, grants,
settings and packages before runtime acceptance. The proof does not certify
customer policy or least-privilege operation under a restricted identity.
