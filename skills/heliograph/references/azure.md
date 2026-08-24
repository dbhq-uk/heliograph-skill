# Running the agent in Azure

Four places the agent can run. Each ships as bicep and as Terraform, because
estates are split on which they accept.

All of them are bring-your-own. You pass in a VNet, a subnet, a plan or an
environment that already exists. The template creates the compute and nothing
else. That keeps the request to "run this container", not "let us build you a
network".

The checkout is transient everywhere. There is no file share and no storage
account. Git is the persistence: a log sits on local disk only for the seconds
between the capture finishing and the push landing. If the compute dies before
that, run the step again.

## Which one to pick

| | Good for | Watch out for |
|---|---|---|
| ACI | One container. Cheapest and simplest to explain | You cannot read logs while it is crash-looping. See below |
| Web App for Containers | You can get a shell into it to debug | Built for web servers: a container with no open port gets killed and restarted every 230s unless you raise `WEBSITES_CONTAINER_START_TIME_LIMIT`. It also always has a public HTTPS endpoint - VNet integration is outbound-only |
| Container Apps Job | Runs on a schedule, so nothing is long-lived | The published image refuses `REPO_URL` and an argument together, and a Job's whole point is passing `--once` - so the repo URL has to travel positionally instead |
| VM (systemd, no container) | Easiest to debug: SSH in, or `az vm run-command`. No image, no registry | You own an OS and its patching. Could not be proven live in this subscription - see below |

All four were deployed for real against `rg-heliograph-test` and torn down again, except the VM, which this subscription refused to provision at all (any SKU, any region) - see "The VM host could not be deployed" below. Every other finding on this page came from watching a real deployment fail or succeed, not from documentation.

## What we learned by deploying these

Everything here was found by running it, not by reading documentation.

### ACI replaces the entrypoint, and has no args field

In ACI, `command` does the same job as Kubernetes `command`: it **replaces** the
image's ENTRYPOINT. There is no separate `args` field.

So this fails:

```
command: ['https://github.com/org/transport.git']
```

ACI tries to run the URL as a program:

```
exec: "https://github.com/org/transport.git": no such file or directory
```

And so does this, for the same reason:

```
command: ['--check']
```

Two rules follow:

- Pass the repo URL as the `REPO_URL` environment variable, never as `command`.
- If you need to pass an argument, name the entrypoint first:
  `['/usr/local/bin/entrypoint.sh', '--check']`. If you pass no arguments, leave
  `command` empty so the image's own entrypoint runs.

### Each host needs a different subnet delegation

If you are bringing your own VNet, the subnet has to be delegated to the right
service, and the service differs per host. Getting it wrong fails at deploy time
with a message that names the delegation, which is at least honest.

| host | delegate the subnet to |
|---|---|
| Container Instances | `Microsoft.ContainerInstance/containerGroups` |
| Web App for Containers | `Microsoft.Web/serverFarms` |
| Container Apps | `Microsoft.App/environments` |

```
az network vnet subnet update -g RG --vnet-name VNET -n SUBNET \
  --delegations Microsoft.App/environments
```

A Container Apps environment also needs a reasonably large subnet. A /23 worked.

### A VNet with no NAT gateway has no outbound internet

This is the one that will cost you the most time, and it applies to every host
here, not just VMs.

Azure removed default outbound internet access. A VM in a subnet with no public
IP and no NAT gateway cannot reach anything outside the VNet. If your transport
repo is on github.com, the clone hangs and then fails:

```
fatal: unable to access 'https://github.com/org/transport.git/':
Failed to connect to github.com port 443 after 133840 ms: Couldn't connect to server
```

Two minutes of nothing, then a connection error. It does not look like a network
policy problem, it looks like github being down.

Fix it with a NAT gateway on the subnet:

```
az network public-ip create -g RG -n pip-nat --sku Standard --allocation-method Static
az network nat gateway create -g RG -n nat-hg --public-ip-addresses pip-nat
az network vnet subnet update -g RG --vnet-name VNET -n SUBNET --nat-gateway nat-hg
```

Then check from inside before blaming anything else:

```
az vm run-command invoke -g RG -n VM --command-id RunShellScript \
  --scripts "curl -s -o /dev/null -w '%{http_code}' -m 20 https://github.com"
```

None of this applies if the transport repo is on a private git host inside the
same VNet, which is the case this tool is really for. It applies whenever the
repo is on the public internet.

### VM SKU availability is per region, and can be zero

`SkuNotAvailable` is not a quota error and reading quota will send you the wrong
way. On the subscription used to test this, quota was present and unused:

```
Standard BS Family vCPUs:  0/65
Total Regional vCPUs:      0/65
Virtual Machines:          0/25000
```

And yet every VM size failed. The reason only shows in the SKU list itself:

```
type: Location  reason: NotAvailableForSubscription
type: Zone      reason: NotAvailableForSubscription
```

`NotAvailableForSubscription` means the SKU is not offered to this subscription
in that region. More quota does not fix it.

It is also **per region**, and the difference is total:

| region | unrestricted VM SKUs |
|---|---|
| uksouth | 0 of 1227 |
| westeurope | 583 of 1314 |
| eastus | 508 of 1356 |
| centralus | 625 of 1294 |

So do not conclude that a subscription cannot run VMs because one region refuses
every size. Check another region. Testing the same old SKU in four regions is
what misled us: `Standard_B2s` happens to be restricted in all of them, while
hundreds of current-generation sizes are available.

List what is actually available rather than guessing:

```
az rest --method get --url "https://management.azure.com/subscriptions/SUB/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq 'westeurope'"
```

then filter for entries with no `restrictions`. `Standard_F1as_v7` worked.

### App Service kills a container that does not listen, so we serve status

Azure Web App for Containers runs an HTTP startup probe on a port. You cannot
turn it off. heliograph never opened a port, so the platform killed it:

```
Site startup probe failed after 230.0123255 seconds.
No listening ports were detected in the container.
Failed to start site. Revert by stopping site.
```

Raising `WEBSITES_CONTAINER_START_TIME_LIMIT` only delays this. Nothing was ever
going to answer.

The fix is not a stub. The image now ships `status-server.pl`, which serves the
agent's own status file:

```
$ curl https://yourapp.azurewebsites.net/status
state:    idle
id:       web-152519Z
step:     env
host:     aa673558e146
branch:   main
utc:      2026-08-19T15:25:34Z
```

That turns the probe from an obstacle into the reason to pick this host. The
hardest question about a far-side agent is "is it still running, or did it die
an hour ago", and this is the only host that answers it without cloning
anything.

Three things about it:

- **It is off unless `HELIOGRAPH_STATUS_PORT` is set.** ACI, a VM and a plain
  `docker run` are unaffected and open no socket.
- **It is perl, and costs nothing.** git already pulls perl into the image, about
  21MB of it, and `IO::Socket::INET` is core. Adding python3 or busybox for this
  would have been adding a package to do something already possible.
- **`/` and `/health` always return 200 while the server answers. `/status` does
  not.** That split matters. A startup probe asks "did the container come up",
  and returning 503 there because the agent had not written a status yet failed
  the probe and stopped the site. We made that mistake first. Point a platform
  probe at `/`, and point a monitor at `/status`.

It serves status, never logs. Logs go back over git. An unauthenticated endpoint
on a container in someone's estate is the wrong place for captured output.

### App Service quota is separate, and small

On a Sponsorship subscription, `B1` and `S1` App Service quota was 0. `P0v3` and
`P1v2` worked. Quota is also slow to release: deleting a plan and immediately
recreating it fails, and takes a couple of minutes to free up.

If a plan will not create, try another SKU before assuming the template is wrong.

### A crash-looping ACI in a VNet gives you no logs

If the container fails to start, `az container logs` returns:

```
ERROR: (ContainerGroupDeploymentNotReady) The container group is not ready
```

You get container events, which tell you the image pulled, but not why the
process died. There is no `az container exec` into a VNet-injected group either.

To debug it, run the same thing locally with Docker:

```
docker run --rm --entrypoint "" \
  -e REPO_URL=... -e GIT_TOKEN=... \
  ghcr.io/dbhq-uk/heliograph-toolkit:TAG \
  /usr/local/bin/entrypoint.sh --check
```

That reproduces the exact ACI invocation and prints the error straight away.

This matters when choosing a host. For a tool whose job is debugging, a black
box is a poor place to run it. Web App for Containers and a VM both let you get
a shell.

### Managed identity works in a VNet-injected ACI

This used to be unsupported, and much of the documentation online still says so.
It works now. We tested it: a container group with a user-assigned identity, in
a delegated subnet, asked IMDS for a token and got HTTP 200 back.

So ACI needs no special case. It can read Key Vault at runtime like the others.

### GitHub needs a token username, and the failure looks like something else

For an https remote, the token goes in as HTTP Basic auth. The username matters:

| Host | `GIT_TOKEN_USER` |
|---|---|
| GitHub | `x-access-token` |
| GitLab | `oauth2` |
| Azure DevOps | leave empty |

Get it wrong on GitHub and you do not get an auth error. You get this:

```
fatal: could not read Username for 'https://github.com': terminal prompts disabled
```

That reads like a missing credential, not a wrong one. The token was sent and
rejected, and git then fell back to asking for a username.

### The published image tag has no `v`

The git tag is `v1.0.0-rc1`. The image tag is `1.0.0-rc1`.

`docker/metadata-action`'s `type=semver,pattern={{version}}` strips the leading
`v`. Pull `ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1`, not `:v1.0.0-rc1`. The
`v` version does not exist and the error says `not found`, which reads like a
permissions problem.

### A private GHCR package returns "not found", not "unauthorized"

If the package is private and you are not logged in, `docker pull` says
`not found`. It does not say you need to authenticate. Check the package's
visibility before assuming the tag is wrong.

### ACI in a VNet is slow to report

`az deployment group create` can sit at `Running` for over ten minutes while the
container is already up and working. Check the container, not the deployment:

```
az container show -g RG -n NAME --query instanceView.state
```

Use `--no-wait` on the deployment and poll the container instead.

### Terraform's azurerm_container_group needs a port even when nothing listens

The bicep template never mentions `ipAddress` at all, and Azure is happy to
omit the object entirely for a VNet-injected group with no ports. Terraform's
`azurerm_container_group` builds that object as soon as `subnet_ids` is set -
a private IP is unavoidable once the group joins a subnet - and then Azure
refuses it two different ways depending on what else is set:

```
MissingIpAddressPorts: The ports in the 'ipAddress' of container group ...
cannot be empty.
```

Add a `ports {}` block and the very next attempt fails a different way,
because `ip_address_type` defaults to `"Public"` and a network profile
forbids that:

```
InvalidIpAddressTypeForNetworkProfile: IP Address type can't be public when
network profile is set.
```

The fix is both together: `ip_address_type = "Private"` AND a `ports {}`
block. The port is declared, not bound - the image never listens on it, and
there is still no public IP - it exists purely to satisfy the provider's own
validation. A difference in what the two tools generate for the same intent,
not a difference in what Azure allows.

## Web App for Containers

### A container with no HTTP server gets killed every 230 seconds

App Service for Linux custom containers runs a mandatory startup probe: it
pings the container over HTTP on port 80 (or `WEBSITES_PORT`) and, if nothing
answers within `WEBSITES_CONTAINER_START_TIME_LIMIT` (default 230 seconds),
kills the container and starts a fresh one. heliograph's agent loop is not a
web server and never will be, so this fires every time:

```
Site startup probe failed after 230.021585 seconds.
... ContainerTimeout ... Container did not respond to startup probe on port 80
within the expected time limit of 230s. No listening ports were detected in
the container. Ensure your application starts a web server that listens on a
port.
```

Confirmed by deploying: the container genuinely runs and does real work for
up to that limit - clone, preflight, and a live request/response round trip
all completed inside the window - but the platform still tears it down and
restarts it the moment the limit passes, whether or not anything went wrong.

There is no setting that turns the probe off. Raising
`WEBSITES_CONTAINER_START_TIME_LIMIT` (max 1800s) only delays the kill, since
the container is never going to open that port - it buys up to half an hour
of uninterrupted operation between forced restarts rather than removing them.
For a short debugging session that is enough; for a host meant to run
indefinitely, this is a genuine limitation of the platform, not a
configuration gap in the template. The only real fix is adding a trivial
stub HTTP listener to the image itself, which is outside what "bring the
compute and nothing else" covers here.

`alwaysOn: true` (or `always_on = true` in Terraform) is unrelated to this and
still required regardless: without it, the platform additionally idles out
and unloads the whole app after about 20 minutes with no *inbound* HTTP
traffic, which a polling loop that serves nothing will never generate.

### VNet integration here is outbound-only, and the app still has a public URL

Regional VNet Integration gives the app egress into the VNet; it is not the
inbound isolation ACI's subnet injection provides. `<name>.azurewebsites.net`
resolves and answers regardless of the VNet configuration - closing that needs
a private endpoint, which is further estate infrastructure this template
deliberately does not add. Anyone choosing this host for the "no inbound"
property ACI has should not assume it carries over.

`vnetRouteAllEnabled` (bicep) / `vnet_route_all_enabled` (Terraform) is not
optional either: without it, only traffic bound for addresses inside the
VNet's own range goes through the integration, and everything else - the git
host included - takes the platform's ordinary public egress, defeating the
point of handing the template a subnet at all.

### The persistent /home mount has to be turned off by hand

Every Linux container Web App gets a persistent Azure Files share mounted at
`/home` by default, so a checkout would survive a restart - the opposite of
every other host in this PR, where git is the only persistence. Turn it off
explicitly with `WEBSITES_ENABLE_APP_SERVICE_STORAGE=false`, or the "the
checkout is transient" story silently stops being true on this one host.

### Terraform: setting `docker_registry_url` alongside a fully-qualified image name double-prefixes it

`azurerm_linux_web_app`'s `application_stack.docker_image_name` expects the
FULL image reference, registry host included - `var.image` here is already
`ghcr.io/dbhq-uk/...`. Also setting `docker_registry_url = "https://ghcr.io"`
(a field meant for a registry that needs credentials attached separately,
such as ACR) makes the provider double-prefix what it builds:

```
linuxFxVersion: "DOCKER|ghcr.io/ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1"
```

a registry ghcr.io does not have. For a public registry, leave
`docker_registry_url` unset entirely - the image name alone is enough.

### Getting a full boot log needs a download, not `log tail`

`az webapp log tail` reliably showed nothing during these tests, including
across a restart timed to land inside the tail window. What worked every
time was enabling filesystem container logging once
(`az webapp log config --docker-container-logging filesystem`) and then
pulling the whole log file after the fact:

```
az webapp log download -g RG -n NAME --log-file logs.zip
unzip logs.zip
grep -i entrypoint LogFiles/*_docker.log   # NOT the *_default_scm_docker.log one -
                                            # that is Kudu's own sidecar, not the app
```

The entrypoint clone, the credential line and the full preflight table all
showed up there, confirming the agent starts correctly on this host despite
the startup-probe restarts above.

## Container Apps Job

### `command` and `args` are genuinely separate here, unlike ACI

ACI's `command` field replaces the image's ENTRYPOINT outright and there is
no separate arguments field at all (see above). Azure Container Apps -
including Jobs - has both `command` and `args`, closer to Kubernetes: leaving
`command` unset keeps the image's own ENTRYPOINT in force, and `args` becomes
its argv. That distinction does not, on its own, get around the trap below -
it is what makes the workaround possible to express cleanly.

### The published image refuses REPO_URL plus an argument - so the URL travels positionally instead

`ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1` ships an `entrypoint.sh` that
refuses outright whenever `REPO_URL` is set AND any positional argument is
also given. The fix for this lives in this branch's working tree but is not
published in that tag. A Container Apps Job cannot avoid the collision: a Job
runs once and exits, which means passing `--once` to `agent.sh`, and every
other host in this PR only avoids the refusal by passing no arguments at all
in its default configuration.

Two ways out, both real:

1. **Pass the URL positionally, leave `REPO_URL` unset.** `args = [repoUrl,
   "--", "--once"]`, no `REPO_URL` environment variable at all. Works today
   against the published image, confirmed by deploying both the bicep and
   the Terraform version of this template and watching a genuine
   request/response round trip complete.
2. **Publish a new image tag** built from this branch, and use `REPO_URL` +
   `args` everywhere, exactly like the other three hosts.

**This PR takes option 1** for both containerappsjob templates. It needs no
publish step, it is provably correct against the exact image every other
host in this PR was tested against, and the cost is confined to one
host-specific comment block rather than a new release process. Option 2 is
the more uniform long-term answer once a new tag exists - worth revisiting
then, not a reason to block this PR on a publish today.

Passing `--once` also needs the same `--` that `start.sh` itself requires -
`args = [repoUrl, "--once"]` alone reaches `start.sh` as an unrecognised
option (`unknown option: --once`, exit 2) and never gets to `agent.sh` at
all. `[repoUrl, "--", "--once"]` is the whole shape.

### Executions are cheap to trigger by hand for testing

`az containerapp job start -g RG -n NAME` runs one execution immediately,
regardless of whether the job's configured trigger type is `Schedule` or
`Manual` - useful for proving a scheduled job actually works without waiting
for the cron to fire. `az containerapp job execution list -g RG -n NAME -o
table` shows whether it Succeeded; `az containerapp job logs show -g RG -n
NAME --container agent` streams the console output of the most recent
execution, though it only reliably shows the TAIL of a fast-finishing
execution's output rather than the whole thing (the underlying Log Analytics
ingestion lags by several minutes, so querying the workspace directly right
after a run comes back empty too) - the transport repo's own
`agent/status`/`ops-logs/` are the more reliable evidence for a fast job.

## VM (systemd, no container)

This host runs no image at all: cloud-init installs git and a small set of
packages, clones the transport repo directly, and starts `agent.sh` under a
systemd unit. Both the bicep and the Terraform templates were written,
bicep-built/`terraform validate`d clean, and the cloud-init script that
drives first boot passes `shellcheck -S warning` and `bash -n` - but neither
could be proven with a real deployment.

### The VM host could not be deployed in this subscription

Every `Microsoft.Compute/virtualMachines` size tried - `Standard_B1s`,
`Standard_B1ms`, `Standard_B2s`, `Standard_D2s_v3`, `Standard_D2_v5`,
`Standard_E2s_v5`, `Standard_F2s_v2`, `Standard_DS1_v2`, `Standard_A1_v2`,
`Standard_A2_v2`, `Standard_B2ats_v2` - was refused with the same error, in
`uksouth` and, tried again as a direct check, in `northeurope` too:

```
SkuNotAvailable: The requested VM size for resource 'Following SKUs have
failed for Capacity Restrictions: Standard_B1s' is currently not available in
location 'uksouth'. Please try another size or deploy to a different location
or different zone.
```

That message reads like a per-SKU stock-out, and it invites exactly the wrong
next move - trying another size, then another region. Both were tried here,
repeatedly, and both failed identically across eleven different SKUs and two
regions. `az vm list-usage` showed healthy quota throughout (0 of 65 vCPUs
used in the relevant families). The consistent, size-independent,
region-independent failure is the signature of a subscription-level
restriction on raw IaaS compute - common on sponsorship/trial subscriptions -
not a genuine capacity shortage. This subscription (`Microsoft Azure
Sponsorship`) could not provision a single VM of any size anywhere it was
tried, while ACI, Web App for Containers and Container Apps Jobs - all VM-backed
under the hood, all provisioned through a managed platform rather than
directly - worked without incident.

**This is an environment limitation, not a template defect.** The templates
are built, validated and reviewed against the same patterns already proven
live on the other three hosts (the credential handling mirrors
`entrypoint.sh`'s own env-based approach exactly; the systemd unit's
`Restart=on-failure` mirrors ACI's `restartPolicy: OnFailure`). They have not
been proven by an actual boot, and that gap should not be quietly assumed
away: the next person to reach for this host needs a subscription where
`Microsoft.Compute/virtualMachines` is actually enabled, and should expect to
spend their first attempt confirming that, not debugging cloud-init.

### The design, for whenever a working subscription is available

- **Custom data, not a container.** `cloud-init.sh` runs once at first boot:
  installs `git` and `ca-certificates` (everything else `start.sh`'s
  preflight needs - bash, GNU sed, GNU coreutils, `setsid` - already ships on
  Ubuntu 24.04), creates an unprivileged `heliograph` user, clones the
  transport repo, and writes a `heliograph.service` systemd unit with
  `Restart=on-failure`.
- **The credential travels the same way `entrypoint.sh`'s does**: through
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` rather than `git
  -c http.extraHeader=...`, so it never appears in that process's own argv -
  exactly as readable via `/proc/<pid>/cmdline` on a bare VM as inside a
  container.
- **Azure custom data is not a safe place for a long-lived secret.** Anyone
  who can read this VM's own resource definition (`az vm show`) can read the
  base64 payload straight back out - the same class of caveat as ACI's plain
  environment variable and the Web App's app setting, not a new one, but
  worth naming because a VM more easily suggests "this is just a box" than a
  managed container resource does. The right fix is a managed identity
  reading the token from Key Vault at boot, never putting it in custom data
  at all; that needs a Key Vault as further bring-your-own estate
  infrastructure this template does not assume exists, so it is documented
  as a real limitation rather than built here.
- **No inbound, same as ACI**: no public IP on the NIC. Debugging still
  works without one - `az vm run-command invoke --command-id
  RunShellScript` talks to the VM agent through the control plane, not a
  direct network path from the operator's machine, so there is nothing to
  open for it.

## App Service Plan: deleting the last app on a plan deletes the plan too

`az webapp delete` on the only app left on a plan deletes that plan as well,
unless `--keep-empty-plan` is passed - and the warning naming this appears
*before* the delete, easy to miss when tearing down quickly between tests.
Recreating the same plan straight after can then fail on quota that a moment
ago was fine:

```
ERROR: Operation cannot be completed without additional quota.
Current Limit (B1 VMs): 0
Current Usage: 0
```

`Current Limit: 0` alongside `Current Usage: 0` looks like a hard cap, not a
transient one - but it cleared on trying a different SKU tier (`S1` instead
of `B1`) immediately, with no wait needed. Read as SKU-family capacity
settling right after a delete, not a real quota exhaustion; the fix that
worked here was picking a different tier, not waiting it out.

### Do not let terraform artefacts into the transport repo

`terraform init` writes a provider binary into `.terraform/` next to each
template. The azurerm provider alone is over 300MB.

`bootstrap.sh` copies the toolkit with `find`, not with git, so it does not know
about `.gitignore`. Before this was fixed, a bootstrapped transport repo was
913MB instead of about 200KB. That repo gets cloned on the control node, which
is often the machine with the slowest link.

`bootstrap.sh` now prunes `.terraform`, `.git` and `node_modules`. If you add a
tool that writes build artefacts under `toolkit/`, add it to that prune list.

Check it after any change:

```
bootstrap.sh /tmp/check && du -sh /tmp/check
```

A few hundred KB is right. Megabytes means something is being copied that
should not be.


## Two hosts that need no infrastructure at all

The four templates above all create compute. These two use something the estate
already runs, which is usually the harder problem: not "can it run" but "who has
to approve it".

### A build agent, triggered by the request itself

`toolkit/pipelines/github-actions.yml` and `azure-pipelines.yml`.

The agent is already inside the estate with network reach and git credentials,
because that is what a build agent is for. Adding a pipeline is an approved
activity. Deploying a container into production is a change board conversation.

**It triggers on the push, not on a schedule.** A cron would mean waiting for
the next tick for every step, and a hundred steps would mean a hundred waits.
Pushing a request is the trigger. Measured end to end on GitHub Actions:

```
09:17:56  request pushed
09:17:59  workflow run started
09:18:04  log committed back
```

Eight seconds, which is faster than the five-second polling agent.

**The path filter is load-bearing.** The job pushes a log back, and that push is
a commit. Without a filter it triggers itself, then does it again. Logs land in
`ops-logs/` and the agent writes `agent/status`, so triggering only on
`agent/request` means neither can re-fire it. Verified: two requests produced
exactly two runs, and the log pushes started nothing.

GitHub gives a second guard for free, because a push made with the built-in
`GITHUB_TOKEN` does not trigger another workflow. **Azure DevOps has no
equivalent**, so there the path filter is the only structural guard and
`***NO_CI***` in the commit message is the second.

**Both files are now proven.** The Azure DevOps one ran end to end against a
real organisation on 2026-08-24: request pushed, agent picked it up, step ran,
log pushed back, and the log push did not re-fire the trigger. Everything in the
next section was found during that first run.

**Use `--once`, never the polling loop.** A pipeline job holds the agent for its
whole duration, and polling git for an hour would block everyone else's builds.

The limit: a step that takes two hours holds a build agent for two hours. For
long-running work use a VM or a container.

### What the first Azure DevOps run cost

Four things, in the order they bite. Each looked like a different problem than
it was, which is what made them expensive.

**A new pipeline is not authorised for the pool or the repo, and the symptom is
indistinguishable from an outage.** The run sits at `notStarted`. It never
appears in the pool's job request list, so no agent is ever asked for and none
comes up - and if the pool uses on-demand agents, you will find them all
`offline` and conclude the pool is dead. It is not. The evidence is in the
build's own timeline:

```
Checkpoint.Authorization   state=inProgress
Job                        (absent - nothing dispatched)
```

Queue the pipeline once from the web UI and click **Authorize** on the banner it
shows, or grant it directly. The `queue` resource is the agent pool; do the
repository too, or the checkout fails next:

```
PATCH https://dev.azure.com/{org}/{projectId}/_apis/pipelines/pipelinePermissions/queue/{queueId}?api-version=7.1-preview.1
PATCH .../pipelinePermissions/repository/{projectId}.{repoId}?api-version=7.1-preview.1
{"pipelines":[{"id":<definitionId>,"authorized":true}]}
```

Once authorised, the wait was seconds, not minutes: an agent came online and
started the job almost immediately.

**The build service needs Contribute on the transport repo, and finding its
identity is its own trap.** Without it the run looks clean and no log arrives -
`start.sh`'s preflight catches this as a failing `git write` check. Granting it
needs a *subject descriptor*, and `az devops security permission update` rejects
both the display name and the `Microsoft.TeamFoundation.ServiceIdentity;...`
form with errors that name neither problem:

```
Could not cast or convert from System.String to ...IdentityDescriptor.
The string must have at least one character. Parameter name: descriptors element.IdentityType
```

Only the Graph `svc.*` descriptor works. Read it from the identity itself:

```
GET https://vssps.dev.azure.com/{org}/_apis/identities?searchFilter=DisplayName&filterValue={Project}%20Build%20Service%20({Org})&api-version=7.1-preview.1
```

then pass its `subjectDescriptor` as `--subject`, with `--allow-bit 6` (2 Read +
4 Contribute) on namespace `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87` and token
`repoV2/{projectId}/{repoId}`.

**The checkout is a detached HEAD.** Azure DevOps checks out a commit, not a
branch, and `agent.sh` refuses to start on one. That refusal is correct - a
commit on a detached HEAD goes nowhere, so the captured log would be written,
committed, and destroyed with the workspace. The template now re-attaches with
`git checkout -B "${BUILD_SOURCEBRANCH#refs/heads/}"` before anything else.

**`$(...)` in an inline script is Azure DevOps macro syntax**, expanded before
bash sees the line. `$(hostname)` in the old template only worked because no
variable of that name existed. Use `${VAR}` for shell variables.

### The definition's default queue is not what picks the pool

Worth knowing because it wastes an afternoon otherwise: `az pipelines create`
sets a definition-level default queue, and it may pick something long dead -
ours chose `Hosted Ubuntu 1604`, retired in 2021. That is **not** what routes
the job. The `pool:` in the YAML wins, and a pipeline whose definition names a
retired pool still runs correctly on the self-hosted pool its YAML names.
Confirmed by watching a run whose definition said `Hosted Ubuntu 1604` execute
on a self-hosted agent.

So if a run will not start, read the timeline for a checkpoint before touching
the queue.

### A Kubernetes cluster they already run

`toolkit/kubernetes/heliograph.yaml`. One `Deployment`, one replica, no Service
and no Ingress, because the agent only makes outbound connections.

The cluster has already solved what bit the other hosts: egress is configured,
so no NAT gateway surprise, secrets have a home, and **`kubectl logs` works**.
That last one is worth more than it sounds. A crash-looping VNet-injected ACI
returns no logs at all, so debugging it means reproducing the failure elsewhere.
Here you read them.

`strategy: Recreate`, not RollingUpdate: two agents on one transport repo would
both answer the same request and race on the push.

Two things to know if you try this:

- **AKS has its own allowed node-size list**, separate from the subscription's
  VM SKUs. `Standard_D2as_v5` was refused where `Standard_B2s_v2` was fine. The
  error names every size it will accept, which is genuinely helpful.
- A Kubernetes `Secret` is base64, not encryption. If the cluster has the Key
  Vault CSI driver or workload identity, use that instead.
