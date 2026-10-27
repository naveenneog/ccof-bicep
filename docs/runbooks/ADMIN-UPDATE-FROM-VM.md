# Admin console updates and fix patches from a VM

This runbook publishes a new admin console package (a code update or a fix patch) after Front Door
`Lockdown`. Part A sets up the VM once; Part B is repeated for every update.

**Status:** the scripts are covered by offline tests (`tests/Test-AdminVmUpdate.ps1`). The full path
has not yet been run against Azure (UNKNOWNS DR-19).

## Why a VM

`Invoke-DrFrontDoor.ps1 -Phase Lockdown` sets public network access to `Disabled` on the admin
Function App, so the app is reached only through Front Door's private link
([Front Door runbook](DR-FRONT-DOOR.md) section 3). Code is published through the app's deployment
endpoint, `<app>.scm.azurewebsites.net`. With public access disabled, that endpoint answers only
callers inside a virtual network that has a private endpoint to the app
([Azure Functions networking options](https://learn.microsoft.com/azure/azure-functions/functions-networking-options):
"With network restrictions in place, you can deploy only from within your virtual network").
Cloud Shell is outside the VNet and receives HTTP 403.

The first publish of the admin package happens before `Lockdown` (deployment Step 7, or the DR
`Code` phase), as decided in [ADR 0037](../adr/0037-admin-publishing-after-front-door-lockdown.md).
After `Lockdown`, Step 7 and the DR `Code` phase skip the admin package with the warning
`admin_public_access_disabled` and publish the other packages. This runbook publishes the admin package.

## How it works

1. You run `infra/admin/Update-AdminFromVm.ps1` in Cloud Shell. Nothing is copied to the VM by hand.
2. The script sends `infra/admin/vm/admin-update.sh` to the VM with
   [Run Command](https://learn.microsoft.com/azure/virtual-machines/linux/run-command). No SSH, no
   public IP address and no Bastion are needed.
3. On the VM, the script signs in with the VM's own managed identity, downloads the repository at
   the commit you name, builds the admin package with `admin/Build-AdminPackage.ps1` (the same
   build, including unit tests, as Step 7) and publishes it with OneDeploy through the private endpoint.
4. The VM prints one result line. Cloud Shell prints the result and saves an evidence file in
   `$HOME/ccof-admin-updates/`.

| Phase | What it does | Changes |
|---|---|---|
| `Setup` | Installs git, curl, Azure CLI, Node.js 22 and PowerShell 7 on the VM if missing, then runs `Check` | VM only |
| `Check` | Checks the tools, the identity sign-in, read access to the admin app, that `<app>.scm.azurewebsites.net` resolves to a private address, and outbound HTTPS to the repository and the npm registry | Nothing |
| `Update` | `Check`, then build and publish the admin package at one commit; waits until the app lists `projects`, `adminUi` and `adminHealth` | Admin app code |

Run Command limits: one script at a time, 90 minutes at most, the last 4,096 bytes of output
returned ([Run Command restrictions](https://learn.microsoft.com/azure/virtual-machines/linux/run-command#restrictions)).
The full log stays on the VM in `/var/lib/ccof-admin-update/`.

---

## Part A: first-time setup (once)

### A0. What you need

| Item | Why | Who usually has it |
|---|---|---|
| Contributor on the CCOF resource group | Create the VM and the private endpoint | Deployment owner |
| `Microsoft.Network/virtualNetworks/subnets/join/action` on the subnet (for example Network Contributor on the subnet) | Place the VM and the private endpoint in the VNet | Network team |
| Private DNS Zone Contributor on the `privatelink.azurewebsites.net` zone, or permission to create it | DNS record for the private endpoint | Network team |
| Owner or User Access Administrator on the admin Function App | Give the VM's identity the Website Contributor role | Security or subscription owner |
| Azure Policy allows the Ubuntu 24.04 marketplace image | The VM image | Policy owner. ADR 0024 records a tenant where marketplace images were denied |
| Outbound HTTPS from the VM subnet to `github.com` (or your repository host), `registry.npmjs.org`, `deb.nodesource.com`, `packages.microsoft.com`, `aka.ms`, the Ubuntu archive, and Azure (service tag `AzureCloud`) | Downloads the source, the npm packages and the tools; Run Command returns its result over Azure endpoints | Network team (firewall or NAT gateway) |

A VM without a public IP address reaches the internet only through the subnet's outbound path. For
virtual networks created with API versions released after 31 March 2026, subnets are private by
default and need an explicit outbound method such as a NAT gateway or a firewall route
([default outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)).

### A1. Open Cloud Shell and set the names

Open [Cloud Shell](https://shell.azure.com) in **PowerShell**. If the repository is not there yet:
`git clone https://github.com/naveenneog/ccof-bicep.git`. Then replace each `REPLACE-` value:

```powershell
$repo = "$HOME/ccof-bicep"                     # the repository folder in Cloud Shell
$sub  = 'REPLACE-subscription-id'              # the CCOF subscription
$rg   = 'REPLACE-ccof-resource-group'          # the resource group with the admin app
$loc  = 'REPLACE-region'                       # region A, for example eastus2
$vm   = 'ccof-admin-update'                    # the VM name (any name)
$peSubnetId = 'REPLACE-subnet-resource-id'     # see A2
az account set --subscription $sub
az functionapp list -g $rg --query "[?ends_with(name, '-admin')].{name:name, region:location}" -o table
$adminApp = 'REPLACE-admin-app-name'           # region A's admin app from the table above
$adminId  = az functionapp show -g $rg -n $adminApp --query id -o tsv
"admin app: $adminApp"; "id: $adminId"
```

**Expect:** a table of admin apps. With DR, region A and region B share the resource group, so the
table shows two: region B's name holds the standby suffix (for example `<prefix>-b-admin`) and its
region is the standby region. Set `$adminApp` to region A's app; the last line prints its name and
resource ID. Stop if the ID is empty.

### A2. Choose the subnet

The VM and the private endpoint can share one subnet. A private endpoint subnet can hold other
resources ([private endpoint overview](https://learn.microsoft.com/azure/app-service/overview-private-endpoint)).
The subnet must not be delegated: the Function Apps' integration subnet (delegated to
`Microsoft.App/environments`) and the APIM subnet cannot hold a VM.

- **Staged deployment, `network.mode` `existing`:** `network.existing.privateEndpointSubnetId` from
  your `staged.config.json`, or a separate subnet the network team gives you.
- **Created network:** the private endpoint subnet of the CCOF VNet.

```powershell
az network vnet subnet show --ids $peSubnetId --query "{name:name, prefix:addressPrefix, delegations:length(delegations)}" -o table
$vnetId = $peSubnetId -replace '/subnets/[^/]+$', ''
```

**Expect:** the subnet name and address prefix, and `0` delegations.

### A3. The private DNS zone `privatelink.azurewebsites.net`

The private endpoint needs a DNS record in the zone `privatelink.azurewebsites.net`, and the zone
must be linked to the VNet the VM uses, or to the DNS resolver that VNet uses
([App Service private endpoint DNS](https://learn.microsoft.com/azure/app-service/overview-private-endpoint#dns)).

**Case 1: the network team already has the zone** (common with a central hub). Ask for its resource
ID and confirm that it is linked to your VNet or to the hub resolver:

```powershell
$zoneId = 'REPLACE-zone-resource-id'           # .../privateDnsZones/privatelink.azurewebsites.net
```

**Case 2: no zone yet.** Create it in the CCOF resource group and link it to the VNet:

```powershell
az network private-dns zone create -g $rg -n privatelink.azurewebsites.net
az network private-dns link vnet create -g $rg -z privatelink.azurewebsites.net -n ccof-admin-update-link -v $vnetId -e false
$zoneId = az network private-dns zone show -g $rg -n privatelink.azurewebsites.net --query id -o tsv
```

If the VNet uses custom DNS servers (its **DNS servers** setting is not `Default (Azure-provided)`),
the zone has to be linked where those servers resolve; ask the network team.

The zone affects only apps that have a private endpoint. Front Door's private link to the admin app
is one of them. After the zone is linked, names of the admin app resolve inside the VNet only from
this zone, which the next step fills.

### A4. Private endpoint for the admin app

```powershell
az network private-endpoint create -g $rg -n "$adminApp-pe" -l $loc --subnet $peSubnetId `
  --private-connection-resource-id $adminId --group-id sites --connection-name "$adminApp-pe"
az network private-endpoint dns-zone-group create -g $rg --endpoint-name "$adminApp-pe" -n default `
  --private-dns-zone $zoneId --zone-name sites
az network private-endpoint show -g $rg -n "$adminApp-pe" --query "{state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, ip:customDnsConfigs[0].ipAddresses[0]}" -o table
```

**Expect:** `Approved` and a private IP address from the subnet. The DNS zone group adds two records,
`<app>` and `<app>.scm`, both pointing to that address
([Kudu/scm endpoint](https://learn.microsoft.com/azure/app-service/overview-private-endpoint#kuduscm-endpoint)).
Flex Consumption apps support private endpoints
([networking options](https://learn.microsoft.com/azure/azure-functions/functions-networking-options)).

### A5. Create the VM

A small Linux VM with no public IP address and a system-assigned managed identity:

```powershell
az vm create -g $rg -n $vm -l $loc --image Canonical:ubuntu-24_04-lts:server:latest --size Standard_B2s `
  --subnet $peSubnetId --public-ip-address "" --nsg "" --assign-identity '[system]' `
  --admin-username azureuser --generate-ssh-keys
$vmPrincipal = az vm show -g $rg -n $vm --query identity.principalId -o tsv
"VM identity: $vmPrincipal"
```

**Expect:** JSON with `"powerState": "VM running"` and an empty `publicIpAddress`, then the identity's
object ID. On a Windows workstation, `az` runs through `az.cmd`, which drops an empty `""` argument
(`argument --public-ip-address: expected one argument`); write `'""'` there instead
(`--public-ip-address '""' --nsg '""'`). Cloud Shell passes `""` as written. `--generate-ssh-keys` stores a key pair in `$HOME/.ssh` in Cloud Shell; the key is required by
the Linux VM API but is not used, because Run Command needs no SSH connection. If Azure Policy
refuses the image or the size, choose an allowed image of Ubuntu 22.04 or later and any 2-vCPU size.

### A6. Give the VM permission to publish to the admin app

Website Contributor on the admin app only: it can manage the app and publish code, and cannot assign
roles ([Website Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/web-and-mobile#website-contributor)).
The check guards against empty values: an empty `--scope` would assign the role on the whole subscription.

```powershell
if (-not $vmPrincipal -or -not $adminId) { throw 'vmPrincipal or adminId is empty: rerun A1 and A5' }
az role assignment create --assignee-object-id $vmPrincipal --assignee-principal-type ServicePrincipal `
  --role 'Website Contributor' --scope $adminId --query "{role:roleDefinitionName, scope:scope}" -o table
```

**Expect:** `Website Contributor` and the admin app's resource ID. A new role assignment can take
several minutes to take effect
([RBAC troubleshooting](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignment-changes-are-not-being-detected)).

### A7. Install the tools on the VM

```powershell
$upd = "$repo/infra/admin/Update-AdminFromVm.ps1"
pwsh -NoProfile -File $upd -Phase Setup -Subscription $sub -VmResourceGroup $rg -VmName $vm -AdminApp $adminApp -Apply
```

**Expect:** after a few minutes, lines such as `installing: az node22 pwsh`, `node v22...`,
`<app> publicNetworkAccess=Disabled`, `<app>.scm.azurewebsites.net -> 10.x.x.x`,
`outbound HTTPS ok`, then `result: Setup succeeded`. The installers come from the
[Azure CLI apt script](https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=apt),
[NodeSource](https://github.com/nodesource/distributions) and the
[Microsoft package repository for PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu).
If an organization requires its own VM image with these tools, `Setup` finds them and installs nothing.

### A8. Check

```powershell
pwsh -NoProfile -File $upd -Phase Check -Subscription $sub -VmResourceGroup $rg -VmName $vm -AdminApp $adminApp
```

**Expect:** the same lines as A7 without `installing`, and `result: Check succeeded`. `Check` changes
nothing and can be run at any time. If it fails, see [When something fails](#when-something-fails).

### A9. Stop the VM until the next update

```powershell
az vm deallocate -g $rg -n $vm
```

A deallocated VM is not billed for compute; its disk is billed
([VM states and billing](https://learn.microsoft.com/azure/virtual-machines/states-billing)).

---

## Part B: each update or fix patch

A fix patch is a commit in the repository. The VM downloads the repository from the URL of
Cloud Shell's `origin` remote, so the commit must be pushed there before the update.

### B1. Get the commit in Cloud Shell

```powershell
cd $repo
git pull
git log -1 --format='%H %s'
```

**Expect:** the 40-character commit ID and the title of the fix. `Update` publishes this commit
unless `-Commit <id>` names another one.

### B2. Start the VM

```powershell
az vm start -g $rg -n $vm
```

### B3. Preview, then publish

```powershell
pwsh -NoProfile -File $upd -Phase Update -Subscription $sub -VmResourceGroup $rg -VmName $vm -AdminApp $adminApp
pwsh -NoProfile -File $upd -Phase Update -Subscription $sub -VmResourceGroup $rg -VmName $vm -AdminApp $adminApp -Apply
```

**Expect:** the preview prints `preview: Check, then on the VM clone ... build admin/ ... publish it`.
The apply prints the `Check` lines, `built admin-<commit>.zip`, `published`, and
`result: Update succeeded; package sha256 <hash>`. It stops with `commit_not_pushed` (exit 2) if the
commit is not on a remote branch of the checkout.

### B4. Verify

1. Open the admin console through Front Door (the admin URL from the Front Door runbook) and sign in.
   `/api/v3/version` returns the console version; open the page or change that the fix concerns.
2. The evidence file `$HOME/ccof-admin-updates/admin-update-<time>.json` records the commit, the package
   SHA-256 and the VM's output.
3. On the VM, `/var/lib/ccof-admin-update/history.log` lists every published commit and package hash.

### B5. Stop the VM

```powershell
az vm deallocate -g $rg -n $vm
```

### B6. The standby region (DR)

Region B's admin app is locked down by the same `Lockdown` phase. One VM can publish to both apps: a
private endpoint can be in a different region than its app
([private endpoint overview](https://learn.microsoft.com/azure/app-service/overview-private-endpoint)).
Repeat A4 and A6 with region B's admin app: set `$adminApp` to the region B name from the A1 table
(same resource group; `Invoke-DrStandby.ps1` requires that) and read `$adminId` again, then run B3
with `-AdminApp $adminApp`. While region A is down, a VM in region A cannot run; the same Part A in
region B's VNet gives a second VM.

---

## Rolling back

Publish the previous commit again. The commit IDs are in the evidence files and in the VM's
`history.log`:

```powershell
pwsh -NoProfile -File $upd -Phase Update -Subscription $sub -VmResourceGroup $rg -VmName $vm -AdminApp $adminApp -Commit <previous 40-character commit> -Apply
```

OneDeploy replaces the whole package; app settings are not changed by an update.

## When something fails

`Update-AdminFromVm.ps1` exits 0 on success, 1 when a step on the VM fails (it prints the step, the
reason and the last lines of the VM log), 2 when an input or precondition is refused, and 3 when Run
Command fails or returns no result line.

| Message | Cause | What to do |
|---|---|---|
| `vm_not_running` | The VM is deallocated | `az vm start -g $rg -n $vm` |
| `commit_not_pushed` | The commit is only in Cloud Shell | `git push`, then `git fetch`, and rerun |
| `failed at check: ... not a private address` | No private endpoint, or the VNet does not resolve `privatelink.azurewebsites.net` | A3 and A4; with custom DNS servers, ask the network team |
| `failed at check: cannot read <app>` or `subscription ... is not visible` | The role assignment is missing or not yet effective | A6; wait a few minutes and rerun `Check` |
| `failed at check: outbound HTTPS to ... returned` | A firewall or missing outbound path | A0 outbound list |
| `failed at setup` | A package source is blocked | A0 outbound list; or a VM image with the tools |
| `failed at clone: commit ... is not in` | The commit is not on the repository the VM downloads | Push the commit; check `git remote get-url origin` |
| `failed at build` | `npm ci`, the TypeScript build or an admin unit test failed | The VM log named in the message; fix the code and push a new commit |
| `failed at deploy` | OneDeploy refused the package | Role (A6) and private endpoint (A4); the VM log |
| `failed at verify` | The app did not list its functions within 5 minutes | Function App > **Functions** in the Portal; rerun `Update` |
| `no_run_line` | The VM could not return its result | Outbound HTTPS to Azure (`AzureCloud`); the evidence file holds the raw output |

## Removing the setup

```powershell
az vm delete -g $rg -n $vm --yes
az network private-endpoint delete -g $rg -n "$adminApp-pe"
```

Also delete the VM's OS disk and network interface (`az disk list -g $rg`, `az network nic list -g $rg`),
the Website Contributor role assignment (`az role assignment list --scope $adminId`), and, in case 2
of A3, the zone link and the zone.
