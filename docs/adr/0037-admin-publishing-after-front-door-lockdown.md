# ADR 0037: Publishing admin code after Front Door lockdown

Status: accepted, 2026-10-27 (owner may revise in the review of PR #12).
Related: [ADR 0033](0033-dr-active-passive.md), [Front Door runbook](../runbooks/DR-FRONT-DOOR.md).

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

Accepted 2026-10-27:

- Option 2 is the standard path: admin code is published from a host inside the VNet through a
  `sites` private endpoint, with public access left disabled. The private endpoint, DNS record and
  host are not created by the repository yet; until they exist, admin code is published before
  `Lockdown` (runbook section 3).
- Option 1 is an exception, used only with a recorded security approval. Public access is enabled
  with an access restriction to the operator's address, the package is published, and public access
  is disabled and read back as `Disabled` in the same scripted run.
- Option 3 is not used until a spike shows it is a supported deployment path.
- Option 4 is rejected: no Front Door route to the deployment (SCM) endpoint.

## Consequences

- A DR `Code` phase run after `Lockdown` fails on the admin package by design; the phase reports the
  three published packages and the refused one.
- Region B's admin app is one package behind until it is republished by the chosen path.
