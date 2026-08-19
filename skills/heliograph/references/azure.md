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
| Web App for Containers | You can get a shell into it to debug | Built for web servers, so a container with no open port needs settings |
| Container Apps Job | Runs on a schedule, so nothing is long-lived | Extra concepts: environment, workload profile |
| VM | Easiest to debug. Just SSH in | You own an OS and its patching |

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
