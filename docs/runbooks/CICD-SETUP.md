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
| ccof-preview | `self-hosted`, `ccof-vnet`, `ccof-preview` | `<prefix>-preview-id` | Read only (section 5) | Read-only checks and reports from protected branches |
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
- **Job policy on both runners.** Both runners reach IMDS and the VNet, so both are fail-closed.
  `Install-CcofRunner register` installs a root-owned (Windows: administrator-only)
  [job-started hook](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)
  and policy file (`/etc/ccof-runner/policy`). The hook fails the job before any step unless all of these hold:
  the event is `push`, `workflow_dispatch` or `schedule`; the repository is the configured one; the ref is a
  branch in `github.applyBranches` (default `main`); `GITHUB_HEAD_REF` is empty; the workflow file is listed in
  `github.previewWorkflows` (preview runner) or `github.applyWorkflows` (apply runner) and comes from the same
  branch and commit as the job (`GITHUB_WORKFLOW_REF`, `GITHUB_WORKFLOW_SHA`). `pull_request`,
  `pull_request_target` and every other event are refused, and an empty or missing policy refuses everything.
  The runner user cannot change the hook or policy. The hook trusts the listed workflows only as far as the
  branch is protected, and it cannot check how the branch is protected: see "Reviewed main" below.
- **Reviewed main (required before registering either runner).** Whoever can put a commit on an allowed branch
  runs code with the runner identity. GitHub must therefore enforce, for every branch in
  `github.applyBranches`, a [ruleset](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
  or [branch protection rule](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
  that requires a pull request with approving review, requires code owner review (CODEOWNERS for
  `.github/workflows/**`, `.github/actions/**` and `deploy/**`), dismisses stale approvals or requires approval
  of the most recent push, blocks force pushes and deletion, and has no bypass: an empty bypass list for a
  ruleset, or "Do not allow bypassing the above settings" for a branch protection rule. A branch that only
  shows as protected is not enough: by default a branch protection rule only blocks force pushes and deletion,
  and administrators bypass it. In a private repository, rulesets and branch protection need GitHub Pro, Team
  or Enterprise; on GitHub Free they cannot be set, so do not connect these runners to such a repository
  outside a lab.
  - `register` refuses to run without `--reviewed-main-enforced yes` (Windows: `-ReviewedMainEnforced`), and
    `Invoke-CicdSetup.ps1 -Phase Host -ViaRunCommand -Apply` refuses without `-ReviewedMainEnforced`. This is
    the operator's statement that the protection is in place. Neither the scripts nor the runner verify it.
  - The runner host cannot verify it either. The job-started hook runs before checkout. It has no GitHub
    credential, and reading branch protection or ruleset bypass actors needs one with repository
    administration read access. A check inside a workflow is code from the same branch, so whoever can change
    that branch can change the check. It shows a configuration mistake. It does not stop malicious code on
    `main`. A host-side check would need a GitHub credential stored on the runner host that the job cannot
    read, plus a per-commit query (merged pull request and reviews for `GITHUB_SHA`). It is not implemented.
  - Recheck the protection after any change to repository administrators, rulesets or the plan.
- **Pull request validation** (tests, lint, Bicep build) runs on GitHub-hosted runners, offline: no Azure
  sign-in and no VNet access. Pull request code never runs on a CCOF runner.
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
  On GitHub Free, `gh` returns HTTP 422 and the driver stops with that hint. The apply gate is then only the
  runner's job-started hook (`--allowed-refs`, `pull_request` refused). The hook does not stop a direct push to
  `main`, and on GitHub Free `main` cannot be protected in a private repository (see "Reviewed main").
- **STG and Prod do not share anything.** Use one configuration file per environment. Prod runners and their
  identities are in the Prod subscription and VNet; the STG identities have no role in Prod.

### What-if needs deploy permissions

`az deployment group what-if` needs the same permissions as the deployment itself
([What-if, required permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if)).
The preview identity (Reader) therefore cannot run the staged drivers' previews. Lab result: section 10.
Run what-if previews of `main` on the apply runner in environment `<env>-preview`; the preview runner keeps
read-only checks from protected branches. Pull request jobs run on GitHub-hosted runners (section 1).

### Runner groups and user-owned repositories

For an organization, put the apply runner in a
[runner group](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups)
limited to this repository and to selected workflows. A repository owned by a user account has no runner
groups: the runner is registered to the repository and any workflow in it can target its labels. Mitigations
(all needed in both cases):

- No `pull_request` jobs from forks (private repository; "Run workflows from fork pull requests" off).
- `pull_request` jobs never use a CCOF runner; the job-started hook refuses them on both runners.
- Reviewed `main` enforced by GitHub without bypass, before either runner is registered ("Reviewed main" above).
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

**Windows runner: not supported for production in this release.** The lab regression uses Linux runners only.
`Install-CcofRunner.ps1` passes its offline tests and the lab run in section 10, but two blockers are open:
runner 2.338.2 `ConfigureService` starts the Windows service before the bootstrap protects the runner
directory ACL, so the service runs for a short time on an unprotected directory; and the `.ccof-version` marker that
decides the layout migration is a plain file and can be forged. Use RHEL or Ubuntu runners until both are fixed.
Linux registration runs `config.sh` as root for that one command only
([ADR 0042](../adr/0042-linux-runner-registration-identity.md)).

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
| HTTP proxy | `--proxy http://proxy:port` (no user name or password: a proxy URL with credentials is refused and never printed; use an IP- or Kerberos-authenticated proxy) sets `HTTPS_PROXY`/`HTTP_PROXY` for the install and in the runner `.env` ([runner proxy](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/using-a-proxy-server-with-self-hosted-runners)). `NO_PROXY` always contains `localhost`, `127.0.0.1`, `169.254.169.254`, `168.63.129.16` and the private endpoint suffixes (`.documents.azure.com`, `.azurewebsites.net`, `.azure-api.net`, `.vaultcore.azure.net`, `.cognitiveservices.azure.com`, `.services.ai.azure.com`, `.openai.azure.com`); `--no-proxy` adds more |
| TLS inspection | `--ca-cert <pem>` writes `<tools>/ca/ccof-ca-bundle.pem` (system bundle plus the CA) and sets `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `SSL_CERT_FILE`, `GIT_SSL_CAINFO` and `NODE_EXTRA_CA_CERTS` in the runner `.env` only. The system trust store and the system git configuration are not changed (Windows: `GIT_CONFIG_*` variables in `.env`, no certificate import) |
| `noexec` on `/tmp` | The bootstrap uses `/var/lib/ccof-runner/tmp`; jobs get `TMPDIR=<runner>/_work/_tmp` |
| SELinux enforcing | Labels the runner entry points `bin_t` with `semanage fcontext` (or `chcon` when `semanage` is missing) and runs `restorecon -RF` on the runner and tool directories only, so the systemd service can start. After moving or restoring the runner directory, run `restorecon -RF /opt/actions-runner /opt/ccof-tools` |
| FIPS mode | Reported by the preflight as a warning, never as a pass. Lab result (section 10, RHEL 9.8): install, register and the preview job ran on a FIPS-mode OS, but this is a functional check, not FIPS compliance. The official Node.js 22 build bundles its own OpenSSL (`crypto.getFips()` = 0) and computed MD5; pwsh (.NET) computed MD5; the runner's bundled action runtimes (`externals/node*`, used by `uses:` actions such as `actions/checkout`) have their own crypto and were not checked. The scripts do not provide a FIPS-validated toolchain: where strict FIPS compliance is required, treat these runners as not meeting it. Azure VM extensions that use protected settings (Run Command, Custom Script) fail on a FIPS-mode RHEL 9 VM until the VM is opted in with `additionalCapabilities.enableFips1403Encryption` and reallocated ([FIPS 140-3 for Linux VM extensions](https://learn.microsoft.com/azure/virtual-machines/extensions/agent-linux-fips)); the bootstrap itself does not use extensions |
| No sudo for the runner user | The admin runs the bootstrap; the runner service runs as `ghrunner`; the hook, policy and `.env` (mode 640, group `ghrunner`) are owned by root. The runner user must be a dedicated non-root account (uid 1000 or higher, not in `wheel`, `sudo`, `admin`, `root` or `docker`) |
| Existing host, other services | Tools go to `<tools>/bin` (default `/opt/ccof-tools/bin`), on the runner `PATH` only; nothing is written to `/usr/local/bin`. `--runner-dir` and `--tools-dir` must be dedicated: absolute, at least two levels deep, not a system directory, no symbolic link in the path, parent not writable by others, and empty or already marked as CCOF-owned. Service commands act only on the service recorded in `<runner dir>/.service` after checking that its unit (Windows: service binary path) points to that directory; other `actions.runner.*` services are never stopped, removed or restarted. `Install-CcofRunner.sh check` (or `-Command check`) prints these checks without changing anything |
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
4. Protect the allowed branches on GitHub first (section 1, "Reviewed main"), with CODEOWNERS on `main`.
   Bootstrap each VM only after that. The driver prints the exact commands (with `-ReviewedMainEnforced`,
   including `--reviewed-main-enforced yes`). The VM admin copies `scripts/cicd/` to the VM and runs:

   ```bash
   sudo bash Install-CcofRunner.sh install --role apply [--stage /mnt/ccof-stage] [--proxy http://proxy:8080] [--ca-cert /etc/pki/corp.pem]
   read -rs RUNNER_TOKEN && sudo env RUNNER_TOKEN="$RUNNER_TOKEN" bash Install-CcofRunner.sh register --role apply \
     --client-id <deploy identity client id> --subscription-id <sub> --tenant-id <tenant> \
     --repository <owner>/<repo> --labels ccof-vnet,ccof-apply --allowed-refs refs/heads/main \
     --allowed-workflows ".github/workflows/deploy-environment.yml .github/workflows/onboard-foundry.yml .github/workflows/drift-check.yml .github/workflows/ccof-runner-smoke.yml" \
     --reviewed-main-enforced yes
   sudo bash Install-CcofRunner.sh status --role apply
   ```

   The registration token comes from the repository's Settings > Actions > Runners > New self-hosted runner,
   or `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token`. It is valid for one
   hour, is read from the terminal and is never written to disk. On Windows Server 2022 use
   `Install-CcofRunner.ps1` with the same commands and options (`-Command install`, `-Role apply`, ...).
   Where the customer allows Azure Run Command, `-Phase Host -ViaRunCommand -Apply -ReviewedMainEnforced -FetchToken` runs the same
   commands through [managed Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command-managed),
   passing the token as a protected parameter and deleting the Run Command afterwards.
5. GitHub: `... -Phase GitHub` prints the environments; `-Apply -ConfigureGitHub` creates them with `gh`.
6. Check: `gh api repos/<owner>/<repo>/actions/runners` lists both runners `online` with their labels.

Workflow allow-lists (`--allowed-workflows`, space-separated; `github.previewWorkflows` and
`github.applyWorkflows` in the configuration). A reusable workflow such as `ccof-step.yml` is checked as
its calling workflow, so it is not listed. A workflow missing from the list fails closed: the hook
refuses every job of that workflow on that runner.

| Runner | Workflows that send jobs to it |
|---|---|
| preview (`ccof-preview`) | `deploy-environment.yml`, `onboard-foundry.yml`, `ccof-runner-smoke.yml` |
| apply (`ccof-apply`) | `deploy-environment.yml`, `onboard-foundry.yml`, `drift-check.yml`, `ccof-runner-smoke.yml` |

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

- `-Mode Build -Ref <commit> -OutFile <zip>`: `git archive` of the commit, the ZIP entry check and the secret
  scan. `<zip>.manifest.json` records the commit, the SHA-256, the file count and the scanner.
- `-Mode Publish -ZipPath <zip> -Repository <owner>/<name>`: checks the manifest SHA-256 and the ZIP entries,
  extracts, scans again, then (with `-Apply`) creates the repository as private when missing, commits the
  files to `main` and pushes with the `gh` credential.
- **Entry check** (before any git or gh command): no `.git` path component (any case, trailing dot or space,
  `GIT~1`), no symbolic link entry, no absolute, `..`, backslash or duplicate path. Such a ZIP is refused
  (exit 2) before it is committed anywhere.
- **Remote.** The push goes only to `https://github.com/<owner>/<name>.git`, after `gh repo view` reports that
  same repository (no rename or redirect) as private. A different `-RemoteUrl` is refused.
- **Existing history.** An empty repository gets `main` with a lease that `main` does not exist. A repository
  with commits is refused and the current `main` commit is printed; to replace it, check the repository and
  re-run with `-ReplaceMainAt <that sha>`. The push uses `--force-with-lease=refs/heads/main:<sha>`, so a `main`
  that moved in the meantime is not overwritten. There is no plain force push.
- **Commit.** Extraction goes to a new work directory next to the ZIP that only this run uses and deletes.
  Local git commands run without system or global git configuration, hooks, filters or templates, with the
  git directory outside the files. The commit must hold exactly the extracted files with identical bytes
  (`.gitignore` does not drop files).
- **Secret scan.** `scripts/SecretScan.psm1` always runs; gitleaks (`gitleaks dir --redact`) runs as well when
  installed. Rules: private keys, GitHub tokens, Entra client secrets, storage and Cosmos keys, SAS
  signatures, connection string keys, AWS keys, Slack tokens, JWTs, runner tokens. Text is read as UTF-8,
  UTF-16 or UTF-32 (with or without BOM); ZIP-based files (`.docx`, `.xlsx`, nested ZIPs) and PNG text chunks
  are scanned inside. A file that cannot be scanned (unknown binary type, over 20 MB, link) fails the scan like
  a finding. Findings show file, line, rule and the SHA-256 of the value, never the value. Customer names and
  resource IDs are allowed. Exit 3 deletes the built ZIP or stops the publish.
- **Exceptions** come only from `-AllowList <file>`, kept by the operator outside the ZIP and outside the
  scanned tree, with exact entries: `finding:<path>:<line>:<rule>:<sha256>` or `file:<path>:<sha256>` (values
  as printed by the scan). No patterns; a changed value or file is reported again. A `.secretscan-allow` file
  in the tree has no effect.
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
| Job-started hook, both runners (allow-listed workflow file modified on a feature branch) | `push` and `workflow_dispatch` on the branch: refused, ref not in `refs/heads/main`; `pull_request` (same repository): refused, event not allowed. The same workflow from `main`: accepted on both. Hook context logged from the live job (`GITHUB_WORKFLOW_REF`, `GITHUB_WORKFLOW_SHA` equal to `GITHUB_SHA`) |
| Pull request validation (`public-ci`) | Ran on GitHub-hosted runners, not on the CCOF runners |
| DNS from the VNet | Private `azurewebsites.net` record resolved to its private endpoint address; a host without a private record fell back to its public address |
| ZIP publish | Second publish refused until `-ReplaceMainAt` gave the current `main` commit; then pushed with a lease |
| What-if with the preview identity (Reader) | Denied on `Microsoft.Resources/deployments/whatIf/action`. With a custom role adding `whatIf/action` and `validate/action`, an empty template passes but any resource fails with "Authorization failed for template resource": what-if needs write on each resource |
| What-if with the deploy identity | Succeeded |
| RHEL 9.8 (`RedHat:RHEL:9-lvm-gen2`), SELinux enforcing, `/tmp` remounted `noexec` | Install succeeded; preflight first failed on disk (2 GB `rootlv`), passed after a 20 GB volume at `_work`; runner service in `unconfined_service_t`; runner user without sudo; Cosmos read, write denied, Bicep build passed. VM deleted after the test |
| Foundry roles | Operator Owner with a condition: Role Based Access Control Administrator cannot be assigned; `foundryRolesBy: foundry-owner` used |
| GitHub environments | Private repository on GitHub Free: protection rules rejected (HTTP 422); environments created without rules |
| RHEL 9.8 (`RedHat:RHEL:9_8-gen2`, LVM, SELinux enforcing), FIPS mode enabled after deployment with `fips-mode-setup --enable` and a restart (Red Hat: enabling FIPS after installation does not guarantee compliance), preview identity only, no public IP | Run Command first failed: the extension could not decrypt its protected settings (3DES/RSA padding refused in FIPS mode); after `enableFips1403Encryption` and a reallocation it worked. Install with a wrong Node.js SHA-256: refused at the download check (exit 3), no runner, tools or service installed; OS packages (git, Azure CLI) and the tools user from the earlier steps stayed. Install and register then passed. Smoke run with `fips=true` (runner labels `ccof-preview,ccof-fips`): `fips_enabled=1`, crypto policy FIPS, `openssl md5` refused, Python of the Azure CLI refused MD5, Node.js 22.23.5 `crypto.getFips()`=0 and MD5 computed, pwsh (.NET) MD5 computed; managed identity sign-in, Cosmos private address and HTTP 200, write `AuthorizationFailed`, deploy identity not found, role mismatch refused, Bicep build passed. Runner removed, VM deleted. Functional only; not a FIPS compliance test |
| Windows Server 2022 (marketplace `2022-datacenter-azure-edition`, not hardened, FIPS off), preview identity | `Install-CcofRunner.ps1` install, register, status and check passed; the service runs only the runner recorded in `.service`. First job failed with `pwsh: command not found`: the Windows runner service ignores `.path`, so register now writes `PATH` to `.env` (`print-env` shows it). Then: hook accepted the `main` job, preflight 0 failures, Cosmos private address and HTTP 200, write `AuthorizationFailed`, deploy identity not found. A non-`main` ref was refused by the hook. `remove` unregistered the runner and deleted its service; VM deleted |

Not tested: proxy and TLS inspection, FIPS compliance of the toolchain (only a FIPS-mode OS was
tested), FIPS mode set at installation time, a CIS-hardened Linux or Windows image, an egress
allow-list firewall.
