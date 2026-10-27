# ADR 0037: Publishing admin code after Front Door lockdown

Status: accepted, 2026-10-27 (decision set by the owner on 2026-10-27).
Related: [ADR 0033](0033-dr-active-passive.md), [Front Door runbook](../runbooks/DR-FRONT-DOOR.md),
[admin updates from a VM](../runbooks/ADMIN-UPDATE-FROM-VM.md).

## Context

`Invoke-DrFrontDoor.ps1 -Phase Lockdown` sets `publicNetworkAccess` to `Disabled` on both APIM
instances and both admin Function Apps, so they are reached only through Front Door private links.
Code publishing (`az functionapp deployment source config-zip`, used by the staged Stage 7 and the
DR `Code` phase) calls the app's deployment endpoint. From Cloud Shell or a workstation outside the
VNet, that call returns HTTP 403 once public access is disabled:

- Region A, 2026-10-25: Stage 7 failed on the admin package with HTTP 403; public access was enabled
  for the publish and disabled again afterwards (session record).
- Region B, 2026-10-26: the DR `Code` phase published the resolver, sync and reconciler packages and
  failed on the admin package with HTTP 403 (`Deploy-Quickstart.ps1:81`). Region B's admin app runs
  the previous package.

Resolver, sync and reconciler apps are not Front Door origins and keep their configured access.

## Options

1. **Temporary public access for each publish.** Enable public access (optionally with an access
   restriction to the operator's address), publish, disable, and read back. Works from Cloud Shell.
   Weakens the control for the duration and needs security approval each time; a failure between
   the steps can leave the app public.
2. **Publish from a host that reaches the app privately.** A VDI, jump host or Cloud Shell deployed
   into a VNet ([Cloud Shell in a virtual network](https://learn.microsoft.com/azure/cloud-shell/vnet/overview)),
   using a `sites` private endpoint with the SCM record in `privatelink.azurewebsites.net`. Keeps
   public access disabled. Needs the private endpoint, DNS and a host, none of which the repository
   creates today.
3. **Deployment through the app's package storage.** Flex Consumption apps read their package from a
   storage container. Whether replacing that blob and restarting is a supported deployment path is
   not established; a time-boxed spike against Learn and the lab is needed before relying on it.
4. **A Front Door route to the deployment endpoint.** Rejected: it exposes the SCM endpoint at the edge.

## Decision

Accepted 2026-10-27 by the owner, replacing the first recorded decision of the same day:

- **Publish before Lockdown.** The admin package is published by deployment Step 7 (region A) and the
  DR `Code` phase (region B) before `Invoke-DrFrontDoor.ps1 -Phase Lockdown` runs. This is the normal
  path and needs no extra resources.
- **Updates and fix patches after Lockdown come from a VM inside the VNet** (option 2), with
  `infra/admin/Update-AdminFromVm.ps1`: a Linux VM with a managed identity, a `sites` private endpoint
  for the admin app and its `privatelink.azurewebsites.net` record, driven by Run Command from Cloud
  Shell ([runbook](../runbooks/ADMIN-UPDATE-FROM-VM.md)).
- Temporary public access (option 1) is not used. Option 3 is not pursued. Option 4 is rejected.

## Consequences

- Step 7 and the DR `Code` phase read the admin app's `publicNetworkAccess` before publishing. When it
  is `Disabled`, they skip the admin package with the warning `admin_public_access_disabled`, publish
  the other packages, and record `admin.skipped = public_access_disabled` (`Publish-StgAdminPackage`,
  `infra/staged/Staged.Application.ps1`). Before this change, the admin publish failed with HTTP 403.
- An admin update after Lockdown needs the one-time VM setup: a VM, a private endpoint, a DNS record,
  the Website Contributor role for the VM identity, and outbound HTTPS from the VM to the repository
  and package sources. These are created by the runbook's commands, not by the deployment templates.
- The VM path is covered by offline tests (`tests/Test-AdminVmUpdate.ps1`) and has not yet been run
  against Azure (UNKNOWNS DR-19).