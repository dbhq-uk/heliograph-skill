// =============================================================================
//  webapp/main.bicep - run the heliograph agent as a Web App for Containers
// =============================================================================
//  BRING YOUR OWN. This creates one Microsoft.Web/sites resource and nothing
//  else: the VNet, subnet and App Service Plan already exist in the estate.
//  The plan is a fourth bring-your-own beyond the three every other host in
//  this PR takes, because a Web App has nowhere to run without one - see
//  references/azure.md for why that plan has to be Basic tier or above.
//
//  The subnet must be delegated to Microsoft.Web/serverFarms. This is
//  REGIONAL VNET INTEGRATION, which is outbound-only: it gives the app egress
//  into the VNet (and, from there, onward to the internet), not an inbound
//  path. The app still gets its own public https://<name>.azurewebsites.net
//  endpoint regardless - closing that needs a private endpoint, which is
//  extra estate infrastructure this template deliberately does not add. See
//  references/azure.md for the full trade-off against ACI's true no-inbound
//  story.
//
//  THE CHECKOUT IS TRANSIENT, same as every other host: no file share, no
//  storage account, no mount. WEBSITES_ENABLE_APP_SERVICE_STORAGE is turned
//  off below for exactly this reason - left on, App Service mounts a
//  persistent Azure Files share at /home on every Linux container app, which
//  would let a checkout survive a restart. That is the opposite of what
//  every other host in this PR does, so it is turned off here to match them:
//  git is the persistence, not the platform.
// =============================================================================

@description('Name for the web app (must be globally unique - becomes <name>.azurewebsites.net).')
param name string

@description('Location. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('Existing VNet this app integrates with.')
param vnetName string

@description('Existing subnet, delegated to Microsoft.Web/serverFarms.')
param subnetName string

@description('Existing Linux App Service Plan, Basic tier or above (Free/Shared do not support VNet integration or Always On).')
param planName string

@description('The transport repo to clone, https:// or git@.')
param repoUrl string

@description('Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote.')
@secure()
param gitToken string = ''

@description('Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty. Getting this wrong looks like a prompt for a username, not an auth error.')
param gitTokenUser string = ''

@description('Image to run.')
param image string = 'ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1'

@description('Arguments for start.sh, and after --, for agent.sh. The repo URL is NOT one of these: it travels as REPO_URL. Space-joined into the container\'s Startup Command, so no argument here may itself contain a space.')
param startArgs array = []

@description('Accepted for parameter parity with the other hosts in this PR, but NOT actionable here: a Web App has no per-container cpu/memory request. Sizing comes entirely from the App Service Plan\'s own SKU (planName above), so change the plan to change this app\'s resources.')
#disable-next-line no-unused-params
param cpu int = 1

@description('See cpu above: not actionable for this host, kept only for parameter parity.')
#disable-next-line no-unused-params
param memory int = 1

resource plan 'Microsoft.Web/serverfarms@2023-12-01' existing = {
  name: planName
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
  resource subnet 'subnets' existing = {
    name: subnetName
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: plan.id
    // Regional VNet Integration: outbound only, as the header explains.
    virtualNetworkSubnetId: vnet::subnet.id
    // Route ALL outbound traffic through the VNet, not just RFC1918-bound
    // traffic. Without this, only calls to addresses inside the VNet's own
    // range go through the integration and everything else (the git host)
    // takes the platform's normal public egress - which defeats the point
    // of handing this template a subnet at all.
    vnetRouteAllEnabled: true
    siteConfig: {
      // DOCKER|<image>, not just <image>: linuxFxVersion's prefix is how App
      // Service tells a single-container deployment apart from a Docker
      // Compose one, which uses a different prefix and a different syntax
      // entirely.
      linuxFxVersion: 'DOCKER|${image}'
      // The image's ENTRYPOINT is never touched here - unlike ACI, App
      // Service's Startup Command is appended as CMD/arguments to whatever
      // the image already declares, not a replacement for it. So, unlike
      // both ACI templates, this needs no explicit entrypoint path: an empty
      // startArgs leaves appCommandLine empty and the image's own
      // ENTRYPOINT runs with no arguments, exactly like REPO_URL alone on
      // ACI. See references/azure.md for how this was confirmed by hand.
      appCommandLine: join(startArgs, ' ')
      // Keeps the container running with no inbound HTTP traffic. Web Apps
      // idle out and unload the container after ~20 minutes without a
      // request when this is off - fatal for a loop whose whole job is to
      // sit there polling git with nothing to serve. Needs Basic tier or
      // above, which is why planName's description says so.
      alwaysOn: true
      appSettings: concat([
        {
          name: 'REPO_URL'
          value: repoUrl
        }
        {
          // See the header: turns off the persistent Azure Files /home
          // mount every Linux container Web App gets by default, so the
          // checkout stays exactly as transient as it is on every other
          // host in this PR.
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
      ], empty(gitTokenUser) ? [] : [
        {
          name: 'GIT_TOKEN_USER'
          value: gitTokenUser
        }
      ], empty(gitToken) ? [] : [
        {
          // App settings have no secureValue field the way ACI's
          // environmentVariables do. This still keeps the token out of the
          // bicep template and its deployment history, but - exactly like
          // ACI's secureValue caveat - anyone who can read this site's own
          // configuration (`az webapp config appsettings list`) can read it
          // back in plain text.
          name: 'GIT_TOKEN'
          value: gitToken
        }
      ])
    }
  }
}

output siteName string = site.name
output logsCommand string = 'az webapp log tail -g ${resourceGroup().name} -n ${site.name}'
