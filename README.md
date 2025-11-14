# Set up a Coric Azure environment

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAndyHerb%2FAzure-Resource-Group%2Fmaster%2FCoric-ARM-Deployment%2FcoricAzureDeploy.json)
[![Visualize the template](http://armviz.io/visualizebutton.png)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FAndyHerb%2FAzure-Resource-Group%2Fmaster%2FCoric-ARM-Deployment%2FcoricAzureDeploy.json)

This template deploys a Coric environment into Azure.
It creates shared resources of storage accounts, virtual networks, network security groups, and administrative virtual machines before creating one environment (Prod, UAT, Sys, Dev, etc.) with the provided number of resource types.

## Deployment prerequisites

Before starting a deployment ensure the subscription satisfies the following requirements:

- The **Microsoft.SqlVirtualMachine** resource provider is registered. The SQL IaaS extension and `Microsoft.SqlVirtualMachine/sqlVirtualMachines` resource are required for the SQL servers deployed by `nested/sqlKeyVault.json`.
- The target region supports the SQL Virtual Machine resource type and API version used by the template (currently `2023-10-01`).

### Register the SQL Virtual Machine resource provider

Run the following PowerShell commands from an authenticated session to verify and register the provider if needed:

```powershell
# Confirm the provider status first
Get-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine |
  Select-Object ProviderNamespace, RegistrationState

# Register the provider when the state is NotRegistered
Register-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine
```

Provider registration is a one-time operation per subscription. After the state transitions to **Registered** the SQL VM resources deployed by this template can be created in any supported region.

### Validate regional availability

`Microsoft.SqlVirtualMachine/sqlVirtualMachines` is not available in every Azure region for every API version. If you are deploying to a new region, confirm support with:

```powershell
Get-AzLocation | Where-Object {
  $_.Providers -contains 'Microsoft.SqlVirtualMachine'
} | Select-Object Location
```

If a region is missing, choose a supported region or wait until Azure makes the resource type available.

## Troubleshooting tips

- If a deployment fails with **NoRegisteredProviderFound** for `Microsoft.SqlVirtualMachine/sqlVirtualMachines`, register the provider as described above and rerun the deployment.
- When re-running a failed deployment, use the same resource group so nested templates can resume idempotently without creating duplicate resources.