// =============================================================================
//  vm/main.bicep - run the heliograph agent on a VM, no container at all
// =============================================================================
//  BRING YOUR OWN NETWORK, as everywhere else in this PR: the VNet and
//  subnet already exist, and this creates a NIC and a VM and nothing else -
//  no data disk, no load balancer, no public IP.
//
//  NO CONTAINER, deliberately. Every other host in this PR runs the shipped
//  Docker image; this one runs git, bash and the transport repo's own
//  start.sh straight on the OS, installed and wired up by cloud-init.sh (in
//  this same directory) at first boot. Read that file for the credential
//  handling and the systemd unit it writes - this bicep file only gets it
//  onto the VM.
//
//  NO INBOUND, same story as ACI: no public IP. Debugging still works
//  without one - `az vm run-command invoke` talks to the VM agent through
//  the control plane, not a direct network path from the operator's
//  machine, so there is nothing to open for it.
//
//  THE CHECKOUT IS TRANSIENT in the same sense as every other host, even
//  though a VM's OS disk is technically persistent: nothing here relies on
//  that persistence surviving. There is no separate data disk, and
//  recreating this VM (a new deployment of this template under the same or
//  a different name) starts cloud-init.sh over from a clean clone. Git is
//  still the only thing meant to survive a rebuild.
// =============================================================================

@description('Name for the VM (also becomes its hostname and NIC/OS-disk name prefix).')
param name string = 'vm-heliograph'

@description('Location. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('Existing VNet.')
param vnetName string

@description('Existing subnet. No delegation needed - a VM NIC is not a delegated workload the way the other three hosts are.')
param subnetName string

@description('The transport repo to clone, https:// or git@.')
param repoUrl string

@description('Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote.')
@secure()
param gitToken string = ''

@description('Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty. Getting this wrong looks like a prompt for a username, not an auth error.')
param gitTokenUser string = ''

@description('VM OS image URN. NOT a container image - this host runs nothing in a container at all, so `image` here means the marketplace image the VM boots from. Kept under the same parameter name as the other hosts\' container image for a reason worth naming rather than hiding: it is the one parameter whose MEANING genuinely changes on this host, not just its value.')
param image string = 'Canonical:ubuntu-24_04-lts:server:latest'

@description('Arguments for start.sh, and after --, for agent.sh. The repo URL is NOT one of these here either, even though this host has no REPO_URL environment variable at all - see cloud-init.sh, which threads repoUrl straight into git clone\'s own argument.')
param startArgs array = []

@description('Accepted for parameter parity with the other hosts in this PR, but NOT actionable here: a VM is sized by vmSize (below), a fixed SKU, not a continuous cpu/memory request the way a container is.')
#disable-next-line no-unused-params
param cpu int = 1

@description('See cpu above: not actionable for this host, kept only for parameter parity.')
#disable-next-line no-unused-params
param memory int = 1

@description('VM size. B1s (1 vCPU, 1 GiB) is the cheapest size that can run bash, git and a small agent loop - this host\'s real equivalent of cpu/memory above.')
param vmSize string = 'Standard_B1s'

@description('Admin username for SSH access - the operator\'s way in for debugging, distinct from the unprivileged "heliograph" user cloud-init.sh creates to run the agent itself.')
param adminUsername string = 'azureuser'

@description('SSH public key for adminUsername. Azure requires either this or a password for a Linux VM; a key is the safer default and the one references/transport.md already recommends over a stored credential.')
param adminSshPublicKey string

var cloudInitTemplate = loadTextContent('cloud-init.sh')
var cloudInitFilled = replace(
  replace(
    replace(
      replace(cloudInitTemplate, '__REPO_URL__', repoUrl),
      '__GIT_TOKEN__', gitToken
    ),
    '__GIT_TOKEN_USER__', gitTokenUser
  ),
  '__START_ARGS__', join(startArgs, ' ')
)

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
  resource subnet 'subnets' existing = {
    name: subnetName
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet::subnet.id }
          privateIPAllocationMethod: 'Dynamic'
          // No publicIPAddress property at all - see the header. Nothing
          // reaches this VM from outside the VNet.
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
      // Cloud-init reads customData on first boot only - this VM is never
      // meant to be reconfigured by re-running a deployment against it, only
      // replaced, exactly like every other host in this PR redeploying
      // rather than mutating in place.
      customData: base64(cloudInitFilled)
    }
    storageProfile: {
      // publisher:offer:sku:version, the ordinary marketplace URN shape
      // (`az vm image list` prints them in this order). A shared-image or
      // custom-image resource ID is not supported by this template - image
      // stays a plain four-field string here, matching every other host's
      // `image` param in shape even though its meaning has changed.
      imageReference: {
        publisher: split(image, ':')[0]
        offer: split(image, ':')[1]
        sku: split(image, ':')[2]
        version: split(image, ':')[3]
      }
      osDisk: {
        createOption: 'FromImage'
        // No separate data disk - see the header. The OS disk is deleted
        // with the VM by default, which is the right default for a host
        // whose whole story is "nothing here needs to survive a rebuild".
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

output vmName string = vm.name
output runCommand string = 'az vm run-command invoke -g ${resourceGroup().name} -n ${vm.name} --command-id RunShellScript --scripts "journalctl -u heliograph -n 100 --no-pager"'
