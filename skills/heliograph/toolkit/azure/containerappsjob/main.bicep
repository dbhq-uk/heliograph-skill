// =============================================================================
//  containerappsjob/main.bicep - run the heliograph agent as a scheduled
//  Azure Container Apps Job
// =============================================================================
//  BRING YOUR OWN ENVIRONMENT. This creates one Microsoft.App/jobs resource
//  and nothing else: the VNet, subnet and Container Apps Environment already
//  exist in the estate. The environment needs its own dedicated subnet
//  (at least /27), delegated to Microsoft.App/environments - a different
//  delegation from every other host in this PR, and one the environment
//  itself owns rather than this template.
//
//  SCHEDULED, NOT LONG-RUNNING. Unlike ACI or the Web App, this host has no
//  process that sits there polling. Azure starts a fresh container on the
//  cron schedule below, agent.sh runs with --once (poll, run at most one
//  requested step, push, exit), and the container is gone again. Nothing is
//  ever "up" between runs - there is no agent to answer a request pushed
//  between two schedule ticks, only at the next tick.
//
//  THE REPO URL TRAVELS POSITIONALLY, NOT AS REPO_URL, and that is a
//  workaround, not a preference - see the `args` comment below for why.
//
//  THE CHECKOUT IS TRANSIENT, same as every other host: no file share, no
//  storage account. Container Apps Jobs do not offer a persistent volume for
//  a single execution's own /home in the first place, so there is nothing to
//  turn off here the way webapp/main.bicep has to.
// =============================================================================

@description('Name for the job.')
param name string = 'caj-heliograph'

@description('Location. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('Existing VNet. Accepted for parameter parity with the other hosts, but NOT used directly here: the Container Apps Environment (below) already owns the VNet integration, so this template never references vnetName or subnetName itself.')
#disable-next-line no-unused-params
param vnetName string = ''

@description('Existing subnet. See vnetName above: accepted for parity, not used - the environment already integrates with its own subnet.')
#disable-next-line no-unused-params
param subnetName string = ''

@description('Existing Container Apps Environment, VNet-integrated on its own dedicated /27-or-larger subnet delegated to Microsoft.App/environments.')
param containerAppsEnvironmentName string

@description('The transport repo to clone, https:// or git@.')
param repoUrl string

@description('Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote.')
@secure()
param gitToken string = ''

@description('Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty. Getting this wrong looks like a prompt for a username, not an auth error.')
param gitTokenUser string = ''

@description('Image to run.')
param image string = 'ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1'

@description('Arguments for start.sh, and after --, for agent.sh. Defaults to `-- --once`: a Job executes once per schedule tick and must exit, unlike the long-running hosts, so --once is what makes that true rather than agent.sh polling forever inside a single execution.')
param startArgs array = [
  '--'
  '--once'
]

@description('Cron expression (UTC, standard 5-field) for how often a fresh execution starts. Every 15 minutes by default - tune to how quickly a request pushed to the transport repo needs picking up, against the cost of a container starting that often.')
param cronExpression string = '*/15 * * * *'

@description('Seconds before an execution is killed for running too long. Generous by default because a step can genuinely take a long time; agent.sh --once exits on its own well before this once its one poll cycle is done.')
param replicaTimeoutSeconds int = 1800

param cpu string = '1.0'
param memory string = '2Gi'

resource env 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: name
  location: location
  properties: {
    environmentId: env.id
    configuration: {
      triggerType: 'Schedule'
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
      replicaTimeout: replicaTimeoutSeconds
      // 0, not the platform default: a step that fails is a fact for the
      // operator to see in the pushed log, not something to retry silently
      // from a fresh container - a retry would re-poll and could pick up
      // and re-run the SAME request if the failure happened after the poll
      // but before the push updated its state.
      replicaRetryLimit: 0
      secrets: empty(gitToken) ? [] : [
        {
          name: 'git-token'
          value: gitToken
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: image
          // NO `command`, deliberately: unlike ACI's `command` (which
          // REPLACES the image's ENTRYPOINT with no separate args field at
          // all), Container Apps genuinely has both `command` and `args` -
          // closer to Kubernetes than to ACI. Leaving `command` unset keeps
          // the image's own ENTRYPOINT (entrypoint.sh) in force, and `args`
          // below becomes its argv, exactly like Kubernetes leaving `command`
          // unset and setting only `args`.
          //
          // THE URL TRAVELS IN `args`, NOT AS A REPO_URL ENVIRONMENT
          // VARIABLE, and that is the one place this template deliberately
          // differs from every other host in this PR. The published image
          // (ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1) ships an
          // entrypoint.sh that refuses outright whenever REPO_URL is set AND
          // any positional argument is also given - and a Job's whole point
          // is passing `--once`, so REPO_URL and an argument are unavoidable
          // together here, unlike the long-running hosts, which pass no
          // arguments at all in their default configuration. Passing the URL
          // positionally instead avoids that refusal entirely and needs no
          // new image tag - see references/azure.md for the fix that exists
          // for this in a newer entrypoint.sh, not yet published, and for
          // the second option (publish first) this template does not take.
          args: concat([repoUrl], startArgs)
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: concat(
            empty(gitTokenUser) ? [] : [
              {
                name: 'GIT_TOKEN_USER'
                value: gitTokenUser
              }
            ],
            empty(gitToken) ? [] : [
              {
                name: 'GIT_TOKEN'
                secretRef: 'git-token'
              }
            ]
          )
        }
      ]
    }
  }
}

output jobName string = job.name
output triggerCommand string = 'az containerapp job start -g ${resourceGroup().name} -n ${job.name}'
output logsQuery string = 'az containerapp job logs show -g ${resourceGroup().name} -n ${job.name} --container agent --follow'
