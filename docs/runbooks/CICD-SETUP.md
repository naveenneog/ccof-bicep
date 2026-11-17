# CI/CD runners with managed identities (add-on)

This add-on sets up two self-hosted GitHub Actions runners inside the CCOF VNet. Workflows use them to
preview and apply the staged deployment. The runners sign in to Azure with the runner VM's user-assigned
managed identity (`az login --identity`). GitHub holds no Azure secret, certificate, federated credential or
Azure variable. Microsoft Graph and Microsoft Entra are not changed: the identities are Azure resources and
all role assignments are Azure RBAC (Azure Resource Manager only).

| File | Content |
| --- | --- |
| [infra/cicd/Invoke-CicdSetup.ps1](../../infra/cicd/Invoke-CicdSetup.ps1) | Driver: phases Infra, Attach, Roles, Host, GitHub; preview by default, `-Apply` |
| [infra/cicd/Cicd.psm1](../../infra/cicd/Cicd.psm1) | Configuration checks, bootstrap arguments, Run Command script, attach decision |
| [infra/cicd/cicd.bicep](../../infra/cicd/cicd.bicep) | The two identities; optional VMs ([modules/runner-vm.bicep](../../infra/cicd/modules/runner-vm.bicep)) |
| [infra/cicd/runner-subnet.bicep](../../infra/cicd/runner-subnet.bicep) | Optional runner subnet and NSG (deny all inbound) |
| [infra/cicd/roles.bicep](../../infra/cicd/roles.bicep) | All role assignments of the two identities (section 5) |
| [infra/cicd/cicd.config.example.json](../../infra/cicd/cicd.config.example.json) | Configuration sample (one file per environment) |
| [scripts/cicd/Install-CcofRunner.sh](../../scripts/cicd/Install-CcofRunner.sh) | Host bootstrap for RHEL 8/9 and Ubuntu 22.04/24.04, run by the VM admin |
| [scripts/cicd/Install-CcofRunner.ps1](../../scripts/cicd/Install-CcofRunner.ps1) | Host bootstrap for Windows Server 2022 |
| [scripts/cicd/Test-RunnerHost.sh](../../scripts/cicd/Test-RunnerHost.sh), [.ps1](../../scripts/cicd/Test-RunnerHost.ps1) | Host preflight; the first step of every job |
| [.github/actions/azure-login-mi/](../../.github/actions/azure-login-mi/action.yml) | Shared sign-in and sign-out step for workflows |
| [scripts/New-CustomerRepoFromZip.ps1](../../scripts/New-CustomerRepoFromZip.ps1), [scripts/SecretScan.psm1](../../scripts/SecretScan.psm1) | Customer ZIP from a commit, secret scan, ZIP to private repository (section 9) |
| [tests/Test-CicdSetup.ps1](../../tests/Test-CicdSetup.ps1), [tests/Test-CustomerRepoZip.ps1](../../tests/Test-CustomerRepoZip.ps1) | Offline tests (no Azure, no GitHub) |

## 1. Design

| Runner | Labels | Identity | Roles | Jobs |
| --- | --- | --- | --- | --- |
| ccof-preview | `self-hosted`, `ccof-vnet`, `ccof-preview` | `<prefix>-preview-id` | Read only (section 5) | Pull requests, read-only checks, reports |
| ccof-apply | `self-hosted`, `ccof-vnet`, `ccof-apply` | `<prefix>-deploy-id` | Deploy (section 5) | `environment: <env>-apply` jobs from `main`; what-if previews from `main` |

- **Why a managed identity.** Any job on a runner can use the identity of its VM, so nothing needs to be stored
  in GitHub, and nothing in GitHub can be copied and used elsewhere: the identity only works from the VM
  ([Sign in with a managed identity](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-managed-identity)).
  A service principal secret would be stored in GitHub; OIDC federation would need a federated credential per
  environment (at most 20 per identity) and trust in GitHub's token issuer. Neither is used.
- **Privilege is separated by runner, not by GitHub identity.** Each VM has exactly one user-assigned identity
  and no system-assigned identity, so the Instance Metadata Service (IMDS) on that VM offers only that identity
  ([IMDS](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)). A job that does
  not run on the apply runner cannot get the deploy identity. The Attach phase refuses a VM that has any other
  identity.
- **Job policy on the apply runner.** `Install-CcofRunner register` installs a root-owned
  [job-started hook](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)
  and policy file (`/etc/ccof-runner/policy`). On the apply runner the hook fails the job before any step unless
  the event is `push`, `workflow_dispatch` or `schedule`, the repository is the configured one, the ref is in
  `github.applyBranches` (default `refs/heads/main`) and, when `github.applyWorkflows` is set, the workflow is
  listed. The runner user cannot change the hook or policy.
- **Workflows** sign in with the shared action: `uses: ./.github/actions/azure-login-mi` with
  `expected-role: preview` or `apply` at the start, and `mode: logout` under `if: always()` at the end. It
  creates a per-job `AZURE_CONFIG_DIR` under `RUNNER_TEMP`, runs `az login --identity --client-id <client id>`
  (from the runner's `CCOF_RUNNER_IDENTITY_CLIENT_ID`, written by the bootstrap), selects
  `CCOF_RUNNER_SUBSCRIPTION_ID`, and fails when the runner's role is not `expected-role`.
- **Environments.** For each environment stem `<env>` (`github.environments`): `<env>-preview` (no reviewers),
  `<env>-apply` (required reviewers from `github.reviewers`, deployment branches `main` only) and
  `<env>-gate-<name>` for each of `github.gates` (required reviewers). See
  [Deployments and environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment).
  In a private repository, required reviewers need GitHub Enterprise and deployment branch policies need GitHub
  Pro, Team or Enterprise ([plan availability](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)).
  On GitHub Free, `gh` returns HTTP 422 and the driver stops with that hint; the apply gate is then only the
  runner's job-started hook (`--allowed-refs`, `pull_request` refused).
- **STG and Prod do not share anything.** Use one configuration file per environment. Prod runners and their
  identities are in the Prod subscription and VNet; the STG identities have no role in Prod.

### What-if needs deploy permissions

`az deployment group what-if` needs the same permissions as the deployment itself
([What-if, required permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if)).
The preview identity (Reader) therefore cannot run the staged drivers' previews. Lab result: section 10.
Run what-if previews of `main` on the apply runner in environment `<env>-preview`; keep pull request jobs on
the preview runner (lint, tests, Bicep build, read-only queries).

### Runner groups and user-owned repositories

For an organization, put the apply runner in a
[runner group](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups)
limited to this repository and to selected workflows. A repository owned by a user account has no runner
groups: the runner is registered to the repository and any workflow in it can target its labels. Mitigations
(all needed in both cases):

- No `pull_request` jobs from forks (private repository; "Run workflows from fork pull requests" off).
- `pull_request` jobs never use `ccof-apply`; the job-started hook refuses them anyway.
- Branch protection on `main`: pull request, review, no force push.
- CODEOWNERS for `.github/workflows/**`, `.github/actions/**` and `deploy/**`, with code owner review required.
- `<env>-apply` and `<env>-gate-*` environments with required reviewers and deployment branch `main`.

See [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners).

## 2. Host requirements

The customer provides the VMs from its own image (for example a CIS-hardened RHEL or Ubuntu, or Windows Server
2022, from its Compute Gallery). Nothing is installed through cloud-init, custom data or VM extensions.

| Item | Requirement |
| --- | --- |
| OS | RHEL 8/9, Ubuntu 22.04/24.04 (x64), or Windows Server 2022 |
| Size | 2 vCPU, 4 GB RAM (`Standard_B2s`), 64 GB disk; 10 GB free in the work directory. LVM images with a small root volume (RHEL 9 `rootlv` is 2 GB) need a dedicated volume mounted at `/opt/actions-runner/_work` (`nodev,nosuid`), owned by `ghrunner`, then `restorecon -RF` on it |
| Network | A subnet in the workload VNet (or a peered VNet) linked to the private DNS zones; no public IP; no inbound rule |
| Identity | Exactly one user-assigned identity (set by the Attach phase) |
| IMDS | `169.254.169.254` reachable and not proxied (managed identity tokens come from IMDS) |
| Admin | Root or local administrator, only for the bootstrap; the runner runs as a dedicated non-root user (`ghrunner`) without sudo |

Tools installed by the bootstrap (pinned, verified by SHA-256 in [cicd.config.example.json](../../infra/cicd/cicd.config.example.json)):
GitHub Actions runner 2.338.2, Node.js 22.23.5, PowerShell 7.7.0, Bicep v0.46.1, Azure CLI (distribution
package from packages.microsoft.com, or `--az-package`), git, jq, curl, tar.

## 3. Egress allow-list

Outbound HTTPS (443) only. Sources:
[GitHub self-hosted runner communication](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#communication-requirements),
[Azure CLI endpoints](https://learn.microsoft.com/en-us/cli/azure/azure-cli-endpoints).

| FQDN | Used for | When |
| --- | --- | --- |
| `github.com`, `api.github.com`, `codeload.github.com` | Runner registration, jobs, checkout | Always |
| `*.actions.githubusercontent.com`, `results-receiver.actions.githubusercontent.com` | Job messages, logs, results | Always |
| `objects.githubusercontent.com`, `objects-origin.githubusercontent.com`, `github-releases.githubusercontent.com`, `release-assets.githubusercontent.com`, `github-registry-files.githubusercontent.com` | Runner updates, actions, release downloads | Always (runner self-update) |
| `*.blob.core.windows.net` | Job summaries, logs, artifacts and caches | Always |
| `login.microsoftonline.com`, `management.azure.com` | Azure CLI sign-in token exchange, Azure Resource Manager | Always |
| `169.254.169.254` | IMDS (not proxied; link-local, not an FQDN) | Always |
| `packages.microsoft.com`, `aka.ms` | Azure CLI and PowerShell packages | Bootstrap, unless staged |
| `nodejs.org` | Node.js tarball | Bootstrap, unless staged |
| `github.com/PowerShell/...`, `github.com/Azure/bicep/...`, `github.com/actions/runner/...` (release assets, above) | PowerShell, Bicep, runner tarballs | Bootstrap, unless staged |
| Distribution repositories (or the customer mirror) | git, jq, curl, runner dependencies (libicu, openssl, krb5) | Bootstrap |

Private endpoints (Cosmos, Function Apps, Key Vault, APIM, Foundry) are reached in the VNet through the private
DNS zones; they must not go through a proxy (section 4). In a VNet without NAT gateway, firewall or public IP,
VMs have no outbound access in new subnets
([default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access));
`runner-subnet.bicep` sets `defaultOutboundAccess` from its parameter (default `false`).

## 4. Hardened hosts

| Constraint | What the bootstrap does |
| --- | --- |
| No internet, only an allow-list or a mirror | `--stage <dir or mirror URL>` takes `actions-runner-linux-x64-<v>.tar.gz`, `node-v<v>-linux-x64.tar.gz`, `powershell-<v>-linux-x64.tar.gz` and `bicep-linux-x64` from there; `--az-package <file> --az-sha256 <sum>` installs a downloaded Azure CLI package. Every file is checked against its pinned SHA-256; a mismatch stops the install |
| HTTP proxy | `--proxy http://proxy:port` sets `HTTPS_PROXY`/`HTTP_PROXY` for the install and in the runner `.env` ([runner proxy](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/using-a-proxy-server-with-self-hosted-runners)). `NO_PROXY` always contains `localhost`, `127.0.0.1`, `169.254.169.254`, `168.63.129.16` and the private endpoint suffixes (`.documents.azure.com`, `.azurewebsites.net`, `.azure-api.net`, `.vaultcore.azure.net`, `.cognitiveservices.azure.com`, `.services.ai.azure.com`, `.openai.azure.com`); `--no-proxy` adds more |
| TLS inspection | `--ca-cert <pem>` adds the CA to the system trust store and sets `REQUESTS_CA_BUNDLE` (Azure CLI), `NODE_EXTRA_CA_CERTS` (Node.js) and git `http.sslCAInfo` |
| `noexec` on `/tmp` | The bootstrap uses `/var/lib/ccof-runner/tmp`; jobs get `TMPDIR=<runner>/_work/_tmp` |
| SELinux enforcing | Labels the runner entry points `bin_t` with `semanage fcontext` (or `chcon` when `semanage` is missing) and runs `restorecon -RF` on the runner and tool directories, so the systemd service can start. After moving or restoring the runner directory, run `restorecon -RF /opt/actions-runner /opt/ccof-tools /usr/local/bin` |
| FIPS mode | Detected and reported. Not lab-tested: Node.js 22 official builds and the Azure CLI may need the distribution's FIPS-validated OpenSSL; check with the preflight before use |
| No sudo for the runner user | The admin runs the bootstrap; the runner service runs as `ghrunner`; the hook and policy are owned by root |
| IMDS blocked | Checked first; the install stops with the reason when IMDS does not answer |

## 5. Roles

`infra/cicd/roles.bicep` makes every assignment; nothing else assigns roles to the identities. No Owner and no
User Access Administrator. Role assignment rights are Role Based Access Control Administrator with a
[condition](https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-portal)
that allows only the role IDs Stage 3 assigns, and only to principals of type `ServicePrincipal`
([infra/cicd/modules/rbac-condition.bicep](../../infra/cicd/modules/rbac-condition.bicep)).

The condition checks the principal type, not the principal. `ServicePrincipal` covers managed identities and
also ordinary application (Entra app registration) service principals
([condition attributes](https://learn.microsoft.com/en-us/azure/role-based-access-control/conditions-authorization-actions-attributes)).
With `roles.assignablePrincipalIds` empty (default), the deploy identity can grant those roles to any service
principal in the tenant, including an application that is not part of CCOF. Users and groups are blocked.
To limit it to exact identities, list their object IDs in `roles.assignablePrincipalIds`; the condition then
also requires `PrincipalId` for writes and deletes. Stage 3 grants to identities created in Stages 1-2 (Function
App and APIM identities), so their IDs are known only after those stages: run the Roles phase again with the IDs
after Stage 2, before Stage 3. Until then, treat the role-ID limit as the boundary.

| Identity | Role (ID) | Scope | Why (source) |
| --- | --- | --- | --- |
| preview | Reader (`acdd72a7-3385-48ef-bd42-f606fba81ae7`) | Workload RG, network RG, each Foundry account | Read-only checks and reports |
| preview | Cosmos DB Built-in Data Reader (`00000000-0000-0000-0000-000000000001`) | Cosmos database `ccof` | Data plane reads in checks ([Cosmos RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-setup-rbac)) |
| deploy | Contributor (`b24988ac-6180-42a0-ab88-20f7382dd24c`) | Workload RG | Stage 1-3 and D2 resources, code publishing, Cosmos SQL role definitions and assignments ([stage3-grants.bicep:179](../../infra/staged/stage3-grants.bicep); `Microsoft.DocumentDB/*` actions, not `Microsoft.Authorization`) |
| deploy | Role Based Access Control Administrator (`f58310d9-a9f6-439a-9e8d-f62e7b41a168`), conditioned | Workload RG | Stage 3 Azure role assignments: Storage Blob Data Owner (`b7e6dc6d-f1e8-4753-8033-0f276bb0955b`), Monitoring Metrics Publisher (`3913510d-42f4-4e42-8a64-420c390055eb`), Log Analytics Reader (`73c42c96-874c-492b-b04d-ab87d138a893`) ([stage3-grants.bicep:37-79](../../infra/staged/stage3-grants.bicep)) |
| deploy | Network Contributor (`4d97b98b-1d4f-4787-a291-c67834d212e7`) | Network RG | Private endpoints, NIC and subnet joins, private DNS records and zone groups |
| deploy | Role Based Access Control Administrator, conditioned | Each Foundry account (may be another subscription) | Cognitive Services User (`a97b65f3-24c7-4388-baec-2e87135dc908`) for the APIM identity ([foundry-role.bicep:18](../../infra/quickstart/modules/foundry-role.bicep)) |
| deploy | Cognitive Services Contributor (`25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68`), optional (`foundryPrivateEndpointApproval`) | Each Foundry account | Approving private endpoint connections from the pipeline. Default off: the Foundry owner approves |
| deploy | Cosmos DB Built-in Data Contributor (`00000000-0000-0000-0000-000000000002`), optional (`deployCosmosDataWriter`) | Cosmos database `ccof` | Pipeline steps that write data (seeding). Default off |

Role assignment rights on a Foundry account need Owner or an unconditioned User Access Administrator there.
When the operator lacks them (for example an Owner assignment with a condition that excludes the
Role Based Access Control Administrator role), set `roles.foundryRolesBy` to `foundry-owner`: the Roles phase
assigns nothing on Foundry, writes `foundry-roles-<n>.parameters.json` and prints the
`az deployment group create ... modules/foundry-roles.bicep` command for the Foundry owner to run.

Entra steps of the staged deployment (groups, app registrations, consent) are not done by these identities;
they stay with the identity team as in [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md).

## 6. Setup

Run the driver from Cloud Shell or an admin workstation (Azure CLI, PowerShell 7, `gh` for the GitHub phase).
The operator needs Owner, or Contributor plus Role Based Access Control Administrator, on the CICD, workload
and network resource groups and on each Foundry account.

1. Copy `infra/cicd/cicd.config.example.json` outside the repository (or under `.customer-private/`) and fill it.
   `runner.createVms: false` (default) uses the customer VMs in `runner.existingVms`; `true` creates VMs from
   `runner.images` (marketplace reference or a gallery image `{ "id": ... }`).
2. Preview: `pwsh -File infra/cicd/Invoke-CicdSetup.ps1 -ConfigPath <file>`. It checks the configuration, runs
   what-if for the identities and the roles, and prints the bootstrap commands. Nothing is changed.
3. Apply Azure: `... -Apply -Phase Infra, Attach, Roles`. Parameter files and evidence are written to
   `.cicd-state/` next to the configuration file (ignored by git).
4. Bootstrap each VM. The driver prints the exact commands; the VM admin copies `scripts/cicd/` to the VM and runs:

   ```bash
   sudo bash Install-CcofRunner.sh install --role apply [--stage /mnt/ccof-stage] [--proxy http://proxy:8080] [--ca-cert /etc/pki/corp.pem]
   read -rs RUNNER_TOKEN && sudo env RUNNER_TOKEN="$RUNNER_TOKEN" bash Install-CcofRunner.sh register --role apply \
     --client-id <deploy identity client id> --subscription-id <sub> --tenant-id <tenant> \
     --repository <owner>/<repo> --labels ccof-vnet,ccof-apply --allowed-refs refs/heads/main
   sudo bash Install-CcofRunner.sh status --role apply
   ```

   The registration token comes from the repository's Settings > Actions > Runners > New self-hosted runner,
   or `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token`. It is valid for one
   hour, is read from the terminal and is never written to disk. On Windows Server 2022 use
   `Install-CcofRunner.ps1` with the same commands and options (`-Command install`, `-Role apply`, ...).
   Where the customer allows Azure Run Command, `-Phase Host -ViaRunCommand -Apply -FetchToken` runs the same
   commands through [managed Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command-managed),
   passing the token as a protected parameter and deleting the Run Command afterwards.
5. GitHub: `... -Phase GitHub` prints the environments; `-Apply -ConfigureGitHub` creates them with `gh`.
   Then set branch protection and CODEOWNERS (section 1).
6. Check: `gh api repos/<owner>/<repo>/actions/runners` lists both runners `online` with their labels.

## 7. Preflight

`Test-RunnerHost.sh` / `.ps1` prints one `PASS`, `FAIL`, `WARN` or `INFO` line per check with evidence and
exits 1 on any failure. Workflows run it as their first step. Checks: tool versions (az, bicep, node, pwsh,
git, jq), IMDS reachable, `az login --identity` with the runner identity in a throw-away `AZURE_CONFIG_DIR`,
`CCOF_PRIVATE_FQDNS` resolve to private addresses, `github.com` reachable (through the proxy when set), free
disk in the work directory, `noexec` on `TMPDIR`, clock synchronised.

## 8. Remove

`sudo env RUNNER_TOKEN=<remove token> bash Install-CcofRunner.sh remove --role <role>` (remove token:
`gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token --jq .token`), then delete the role
assignments (`az role assignment delete --assignee <principal id>` per scope) and the identities.

## 9. Customer ZIP and private repository

`scripts/New-CustomerRepoFromZip.ps1`:

- `-Mode Build -Ref <commit> -OutFile <zip>`: `git archive` of the commit, then a secret scan. gitleaks
  (`gitleaks dir --redact`) is used when installed, else the rules in `scripts/SecretScan.psm1` (private keys,
  GitHub tokens, Entra client secrets, storage and Cosmos keys, SAS signatures, connection string keys, AWS
  keys, Slack tokens, JWTs, runner tokens). Any finding deletes the ZIP and exits 3; findings show file, line
  and rule, never the value. Customer names and resource IDs are allowed. `<zip>.manifest.json` records the
  commit, the SHA-256 and the scanner.
- `-Mode Publish -ZipPath <zip> -Repository <owner>/<name>`: checks the manifest SHA-256, scans again, then
  (with `-Apply`) creates the repository as private when missing, commits the contents to `main` and pushes
  with the `gh` credential. A public or internal repository is refused. A repository with commits is refused
  unless `-Force`, which replaces `main` (re-creating a lab repository from a newer ZIP).
- A false positive is allowed with a `.secretscan-allow` file at the tree root (one regex per line against
  `path:line:rule`).

## 10. Lab results

Lab: a replica of the STG network (two peered VNets, private endpoints, Cosmos public access disabled), runners
in a dedicated `/27` subnet without public IP, workflow `.github/workflows/ccof-runner-smoke.yml`
(`workflow_dispatch` only), November 2026.

| Check | Result |
| --- | --- |
| Ubuntu 22.04 (marketplace), preview and apply runners | Bootstrap and registration through managed Run Command; both runners online with their labels |
| Preflight | 0 failures on both runners |
| `az login --identity` | Preview job signed in as the preview identity, apply job as the deploy identity; no GitHub secret or variable for Azure |
| VNet | Cosmos FQDN resolved to the private endpoint address; data plane `GET /dbs/ccof/colls` with an Entra token: HTTP 200 |
| Write from the preview runner | Denied, `AuthorizationFailed` |
| Deploy identity from the preview runner | `az login --identity --client-id <deploy>` fails: identity not found (not attached to that VM) |
| Role mismatch | `azure-login-mi` with `expected-role: apply` on the preview runner fails |
| Job from a non-`main` ref on the apply runner | Refused by the job-started hook before any step |
| What-if with the preview identity (Reader) | Denied on `Microsoft.Resources/deployments/whatIf/action`. With a custom role adding `whatIf/action` and `validate/action`, an empty template passes but any resource fails with "Authorization failed for template resource": what-if needs write on each resource |
| What-if with the deploy identity | Succeeded |
| RHEL 9.8 (`RedHat:RHEL:9-lvm-gen2`), SELinux enforcing, `/tmp` remounted `noexec` | Install succeeded; preflight first failed on disk (2 GB `rootlv`), passed after a 20 GB volume at `_work`; runner service in `unconfined_service_t`; runner user without sudo; Cosmos read, write denied, Bicep build passed. VM deleted after the test |
| Foundry roles | Operator Owner with a condition: Role Based Access Control Administrator cannot be assigned; `foundryRolesBy: foundry-owner` used |
| GitHub environments | Private repository on GitHub Free: protection rules rejected (HTTP 422); environments created without rules |

Not tested: proxy and TLS inspection, FIPS mode, Windows Server 2022 bootstrap, a CIS-hardened image,
an egress allow-list firewall.
