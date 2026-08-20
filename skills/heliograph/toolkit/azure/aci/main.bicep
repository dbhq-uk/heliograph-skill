// =============================================================================
//  aci/main.bicep - run the heliograph agent as a VNet-injected container group
// =============================================================================
//  BRING YOUR OWN NETWORK. This creates the container group and nothing else:
//  the VNet and subnet already exist in the estate, which keeps the change to
//  "run this container" rather than "let us build you a network".
//
//  The subnet must be delegated to Microsoft.ContainerInstance/containerGroups.
//  ACI will not deploy into one that is not, and the error names the delegation.
//
//  NO INBOUND. There is no public IP and no exposed port. The container needs
//  egress to the git host and nothing else, which is the whole security story:
//  nothing can reach it, it reaches out.
//
//  THE CHECKOUT IS TRANSIENT. No file share, no storage account, no mount. Git
//  is the persistence: a captured log lives on local disk only for the seconds
//  between the capture finishing and the push landing. If the group is deleted
//  mid-run the answer is to run the step again.
// =============================================================================

@description('Name for the container group.')
param name string = 'aci-heliograph'

@description('Location. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('Existing VNet this container group joins.')
param vnetName string

@description('Existing subnet, delegated to Microsoft.ContainerInstance/containerGroups.')
param subnetName string

@description('The transport repo to clone, https:// or git@.')
param repoUrl string

@description('Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote.')
@secure()
param gitToken string = ''

@description('Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty. Getting this wrong looks like a prompt for a username, not an auth error.')
param gitTokenUser string = ''

@description('Image to run.')
param image string = 'ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1'

@description('Arguments for start.sh, and after --, for agent.sh. The repo URL is NOT one of these: it travels as REPO_URL.')
param startArgs array = []

@description('The image\'s entrypoint, needed only because ACI has no args field. Change it if you change the image.')
param entrypoint string = '/usr/local/bin/entrypoint.sh'

param cpu int = 1

@description('Memory in GB. Named `memory`, not `memoryInGB`, to match the parameter name every other host template in this PR uses.')
param memory int = 1

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
  resource subnet 'subnets' existing = {
    name: subnetName
  }
}

resource group 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: name
  location: location
  properties: {
    osType: 'Linux'
    // OnFailure, not Always: `stop: yes` in agent/request is a clean exit and
    // must stay stopped. Always would restart an agent the far side just asked
    // to stop, and it would keep restarting it.
    restartPolicy: 'OnFailure'
    subnetIds: [
      { id: vnet::subnet.id }
    ]
    containers: [
      {
        name: 'agent'
        properties: {
          image: image
          // ACI's `command` REPLACES the image's ENTRYPOINT. It is
          // Kubernetes-style `command`, not `args`, and ACI has no `args`
          // field at all. Both mistakes were made here and both crash-looped:
          //   command: [repoUrl]   -> exec: "https://github.com/...": not found
          //   command: ['--check'] -> exec: "--check": not found
          // So the entrypoint has to be named explicitly whenever an argument
          // is passed, and an empty startArgs must leave `command` empty so the
          // image's own ENTRYPOINT runs untouched.
          command: empty(startArgs) ? [] : concat([entrypoint], startArgs)
          resources: {
            requests: {
              cpu: cpu
              memoryInGB: memory
            }
          }
          // secureValue keeps the token out of the template, out of deployment
          // history and out of `az container show`. It is still readable by
          // anyone who can already read the container group's own definition.
          environmentVariables: concat([
            {
              name: 'REPO_URL'
              value: repoUrl
            }
          ], empty(gitTokenUser) ? [] : [
            {
              name: 'GIT_TOKEN_USER'
              value: gitTokenUser
            }
          ], empty(gitToken) ? [] : [
            {
              name: 'GIT_TOKEN'
              secureValue: gitToken
            }
          ])
        }
      }
    ]
  }
}

output containerGroupName string = group.name
output logsCommand string = 'az container logs -g ${resourceGroup().name} -n ${group.name}'
