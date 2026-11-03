<#
.SYNOPSIS
Starts or stops tagged Azure compute resources across one or more subscriptions.

.DESCRIPTION
Discovers Azure resources using Azure Resource Graph and performs start or
stop operations against resources matching the configured tag.

The runbook is intended for scheduled cost optimisation of non-production,
development, test, and other workloads that do not need to run continuously.

Resources are selected using an explicit tag/value combination.

Default tag:

    AutoPower = true

Only supported resources carrying the matching tag are modified.

SUPPORTED RESOURCE TYPES

Azure Virtual Machines
    Stop operation deallocates the VM to release compute capacity.

Azure Virtual Machine Scale Sets
    Start/stop operations apply to all instances in the tagged scale set.

Azure Kubernetes Service (AKS)
    Start/stop is performed against the AKS cluster itself rather than
    attempting to manipulate the underlying node VMs.

AUTHENTICATION

The runbook authenticates using the Azure Automation Account managed identity.
No stored Azure credentials are required.

MULTIPLE SUBSCRIPTIONS

SubscriptionId is deliberately defined as a string rather than string[] because
Azure Automation handles simple string parameters more reliably.

For multiple subscriptions supply a comma-separated list:

    subscription-guid-1,subscription-guid-2,subscription-guid-3

The runbook converts this internally into an array and Azure Resource Graph
searches all supplied subscriptions in a single query.

RESOURCE SELECTION

Default selection:

    Action       = Stop
    TagName      = AutoPower
    TagValue     = true
    ResourceType = All

ResourceType can optionally restrict execution to:

    VirtualMachine
    VirtualMachineScaleSet
    AksCluster
    All

Resources without the matching tag/value are ignored.

SECURITY / RBAC

The Azure Automation Account managed identity requires:

1. Permission to discover resources in each target subscription.
2. Permission to read resource status.
3. Permission to perform the appropriate start/stop operation.

RBAC should be scoped as narrowly as practical.

.EXAMPLE

SubscriptionId = 00000000-0000-0000-0000-000000000000

Stops all supported resources tagged AutoPower=true in the subscription.

.EXAMPLE

SubscriptionId = 00000000-0000-0000-0000-000000000000,11111111-1111-1111-1111-111111111111
Action         = Start

Starts matching resources across both subscriptions.

.EXAMPLE

SubscriptionId = 00000000-0000-0000-0000-000000000000
ResourceType   = VirtualMachine

Stops only matching Azure Virtual Machines.

.EXAMPLE

SubscriptionId = 00000000-0000-0000-0000-000000000000
ResourceType   = AksCluster
Action         = Stop

Stops only matching AKS clusters.

.NOTES

Runbook:
    Manage-AzureResourcePower

Runtime:
    PowerShell 7.4

Azure Automation packages:
    Az 12.3.0

Authentication:
    Azure Automation Account Managed Identity

Important behaviour:

- VM Stop uses Stop-AzVM -Force and therefore deallocates the VM.
- Already running/stopped resources are skipped where their state can be determined.
- VMSS operations apply to the complete tagged scale set.
- AKS is stopped/started at cluster level, not by manipulating node VMs.
- One failed resource does not prevent remaining resources from being processed.
- The overall runbook job is marked failed if any individual resource operation fails.
- Azure Resource Graph discovers up to 1,000 matching resources per execution.
- App Service is intentionally excluded because stopping an individual Web App
  does not remove the underlying App Service Plan compute charge.
#>

[CmdletBinding()]
param (

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Power action to perform. Default: Stop'
    )]
    [ValidateSet('Start', 'Stop')]
    [string]$Action = 'Stop',

    [Parameter(
        Mandatory = $true,
        HelpMessage = 'One or more subscription IDs. Separate multiple IDs with commas.'
    )]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Azure tag name used to select resources. Default: AutoPower'
    )]
    [ValidateNotNullOrEmpty()]
    [string]$TagName = 'AutoPower',

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Required tag value. Default: true'
    )]
    [ValidateNotNullOrEmpty()]
    [string]$TagValue = 'true',

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Resource type to manage. Default: All'
    )]
    [ValidateSet(
        'All',
        'VirtualMachine',
        'VirtualMachineScaleSet',
        'AksCluster'
    )]
    [string]$ResourceType = 'VirtualMachine'
)

$ErrorActionPreference = 'Stop'
$RunStartTime = Get-Date

#
# SUBSCRIPTION INPUT
#
# Azure Automation receives SubscriptionId as a simple string.
# Convert comma-separated IDs into a clean, unique array for Azure
# Resource Graph, then validate each value before authentication.
#

$SubscriptionIds = @(
    $SubscriptionId.Split(',') |
        ForEach-Object {
            $_.Trim()
        } |
        Where-Object {
            $_ -ne ''
        } |
        Select-Object -Unique
)

if ($SubscriptionIds.Count -eq 0) {
    throw 'No subscription IDs were supplied.'
}

foreach ($CurrentSubscriptionId in $SubscriptionIds) {

    if (
        $CurrentSubscriptionId -notmatch
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ) {
        throw "Invalid subscription ID: $CurrentSubscriptionId"
    }
}

#
# DISPLAY PARAMETERS
#

Write-Output ''
Write-Output '========================================================'
Write-Output 'LA NET - TAGGED AZURE RESOURCE POWER MANAGEMENT'
Write-Output '========================================================'
Write-Output "Started       : $($RunStartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Action        : $Action"
Write-Output "Resource Type : $ResourceType"
Write-Output "Tag           : $TagName=$TagValue"
Write-Output ''
Write-Output 'Subscriptions:'

foreach ($CurrentSubscriptionId in $SubscriptionIds) {
    Write-Output "  - $CurrentSubscriptionId"
}

Write-Output '========================================================'
Write-Output ''

#
# AUTHENTICATION
#
# Disable inherited Az context because Azure Automation sandboxes can
# reuse processes between jobs.
#
# Authenticate using the Automation Account managed identity so no
# credentials need to be stored in the Automation Account.
#

Write-Output 'Authenticating using the Automation Account managed identity...'

Disable-AzContextAutosave -Scope Process | Out-Null

try {

    $LoginResult = Connect-AzAccount `
        -Identity `
        -ErrorAction Stop

    $AzureContext = $LoginResult.Context
}
catch {

    throw "Managed identity authentication failed: $($_.Exception.Message)"
}

if (-not $AzureContext) {
    throw 'Managed identity authentication returned no Azure context.'
}

Write-Output 'Authentication successful.'
Write-Output ''

#
# RESOURCE TYPE FILTER
#
# Convert the friendly ResourceType parameter into Azure Resource Manager
# resource types understood by Azure Resource Graph.
#
# Selecting All still only targets explicitly supported resource types.
# The AutoPower tag filter is applied separately in the Resource Graph query.
#

switch ($ResourceType) {

    'VirtualMachine' {

        $SelectedAzureTypes = @(
            'microsoft.compute/virtualmachines'
        )
    }

    'VirtualMachineScaleSet' {

        $SelectedAzureTypes = @(
            'microsoft.compute/virtualmachinescalesets'
        )
    }

    'AksCluster' {

        $SelectedAzureTypes = @(
            'microsoft.containerservice/managedclusters'
        )
    }

    default {

        $SelectedAzureTypes = @(
            'microsoft.compute/virtualmachines'
            'microsoft.compute/virtualmachinescalesets'
            'microsoft.containerservice/managedclusters'
        )
    }
}

$ResourceTypeFilter = (
    $SelectedAzureTypes |
        ForEach-Object {
            "'$_'"
        }
) -join ', '

#
# BUILD RESOURCE GRAPH QUERY
#
# Escape quotes from user-supplied tag inputs before inserting them into KQL.
#

$EscapedTagName = $TagName.Replace("'", "''")
$EscapedTagValue = $TagValue.Replace("'", "''")

$Query = @"
Resources
| where type in~ ($ResourceTypeFilter)
| where isnotempty(tags['$EscapedTagName'])
| where tostring(tags['$EscapedTagName']) =~ '$EscapedTagValue'
| project
    id,
    name,
    type,
    resourceGroup,
    subscriptionId,
    location
| order by type asc, name asc
"@

#
# RESOURCE DISCOVERY
#
# Query all supplied subscriptions in one Azure Resource Graph request.
#
# This avoids enumerating each subscription and resource type separately
# through individual Az cmdlets.
#
# Only resources matching BOTH a supported resource type and the exact
# tag/value combination are returned.
#

Write-Output 'Searching Azure Resource Graph...'

try {

    $Resources = @(
        Search-AzGraph `
            -Query $Query `
            -Subscription $SubscriptionIds `
            -First 1000 `
            -ErrorAction Stop
    )
}
catch {

    throw "Azure Resource Graph query failed: $($_.Exception.Message)"
}

if ($Resources.Count -eq 0) {

    Write-Output ''
    Write-Output 'No matching resources were found.'
    Write-Output "Required tag : $TagName=$TagValue"
    Write-Output "Resource type: $ResourceType"
    Write-Output ''

    return
}

#
# PRE-FLIGHT RESOURCE INVENTORY
#
# Display every resource selected by the tag query before any start or
# stop operation is performed. This provides a useful audit trail showing
# exactly what the runbook selected for this execution.
#

Write-Output "Found $($Resources.Count) matching resource(s)."
Write-Output ''
Write-Output 'Resources selected for processing:'

foreach ($Resource in $Resources) {

    Write-Output (
        "  - {0} | {1} | {2} | {3}" -f
        $Resource.name,
        $Resource.type,
        $Resource.resourceGroup,
        $Resource.subscriptionId
    )
}

Write-Output ''

#
# RESULT TRACKING
#
# Track successful, skipped and failed operations across all discovered
# resources. Results are retained for the final execution summary.
#

$Succeeded = 0
$Skipped = 0
$Failed = 0

$Results = @()

#
# PROCESS DISCOVERED RESOURCES
#
# Each resource returned by Azure Resource Graph is processed once.
#
# Resources discovered across multiple subscriptions are handled by changing
# the Az context to the resource subscription before invoking its cmdlets.
#

foreach ($Resource in $Resources) {

    $AzureResourceType = ([string]$Resource.type).ToLowerInvariant()

    $DisplayType = $AzureResourceType
    $ResultStatus = ''
    $ResultDetail = ''

    Write-Output '--------------------------------------------------------'
    Write-Output "Resource     : $($Resource.name)"
    Write-Output "Azure Type   : $AzureResourceType"
    Write-Output "Subscription : $($Resource.subscriptionId)"
    Write-Output "Resource RG  : $($Resource.resourceGroup)"
    Write-Output "Location     : $($Resource.location)"

    #
    # RESOURCE ERROR ISOLATION
    #
    # Process each resource independently.
    #
    # A failed operation is recorded without preventing the remaining
    # resources from being processed. The overall job is deliberately
    # failed at the end if one or more individual operations failed.
    #

    try {

        #
        # SET RESOURCE SUBSCRIPTION CONTEXT
        #
        # Resource Graph can return resources from several subscriptions.
        # Switch context before invoking resource-specific cmdlets so each
        # operation is executed against the correct subscription.
        #

        Set-AzContext `
            -SubscriptionId $Resource.subscriptionId `
            -ErrorAction Stop | Out-Null

        switch ($AzureResourceType) {

            #
            # VIRTUAL MACHINE
            #
            # Stop-AzVM deallocates the VM rather than simply shutting down
            # the guest operating system.
            #
            # Deallocation is intentional because this runbook is designed
            # for power and compute cost management.
            #

            'microsoft.compute/virtualmachines' {

                $DisplayType = 'Virtual Machine'

                Write-Output "Resource Type: $DisplayType"

                $VMStatus = Get-AzVM `
                    -ResourceGroupName $Resource.resourceGroup `
                    -Name $Resource.name `
                    -Status `
                    -ErrorAction Stop

                $PowerStateRecord = $VMStatus.Statuses |
                    Where-Object {
                        $_.Code -like 'PowerState/*'
                    } |
                    Select-Object -First 1

                if ($PowerStateRecord) {

                    $PowerState = $PowerStateRecord.Code
                }
                else {

                    $PowerState = 'PowerState/unknown'
                }

                Write-Output "Current State: $PowerState"

                if ($Action -eq 'Stop') {

                    if ($PowerState -eq 'PowerState/deallocated') {

                        $ResultStatus = 'Skipped'
                        $ResultDetail = 'VM is already deallocated.'
                    }
                    else {

                        Write-Output "Stopping and deallocating VM $($Resource.name)..."

                        Stop-AzVM `
                            -ResourceGroupName $Resource.resourceGroup `
                            -Name $Resource.name `
                            -Force `
                            -ErrorAction Stop | Out-Null

                        $ResultStatus = 'Succeeded'
                        $ResultDetail = 'VM deallocation completed.'
                    }
                }
                else {

                    if ($PowerState -eq 'PowerState/running') {

                        $ResultStatus = 'Skipped'
                        $ResultDetail = 'VM is already running.'
                    }
                    else {

                        Write-Output "Starting VM $($Resource.name)..."

                        Start-AzVM `
                            -ResourceGroupName $Resource.resourceGroup `
                            -Name $Resource.name `
                            -ErrorAction Stop | Out-Null

                        $ResultStatus = 'Succeeded'
                        $ResultDetail = 'VM start completed.'
                    }
                }
            }

            #
            # VIRTUAL MACHINE SCALE SET
            #
            # A tagged VMSS is treated as one managed resource.
            #
            # Query the individual VMSS instance states before taking action.
            # Start/stop operations are then applied to the complete scale set.
            #

            'microsoft.compute/virtualmachinescalesets' {

                $DisplayType = 'Virtual Machine Scale Set'

                Write-Output "Resource Type: $DisplayType"
                Write-Output 'Retrieving VMSS instances...'

                $VMSSInstances = @(
                    Get-AzVmssVM `
                        -ResourceGroupName $Resource.resourceGroup `
                        -VMScaleSetName $Resource.name `
                        -InstanceView `
                        -ErrorAction Stop
                )

                if ($VMSSInstances.Count -eq 0) {

                    $ResultStatus = 'Skipped'
                    $ResultDetail = 'VMSS contains no instances.'
                }
                else {

                    $VMSSPowerStates = @(

                        foreach ($Instance in $VMSSInstances) {

                            $InstancePowerStateRecord = $Instance.Statuses |
                                Where-Object {
                                    $_.Code -like 'PowerState/*'
                                } |
                                Select-Object -First 1

                            if ($InstancePowerStateRecord) {

                                $InstancePowerStateRecord.Code
                            }
                            else {

                                'PowerState/unknown'
                            }
                        }
                    )

                    $RunningCount = @(
                        $VMSSPowerStates |
                            Where-Object {
                                $_ -eq 'PowerState/running'
                            }
                    ).Count

                    $StoppedCount = @(
                        $VMSSPowerStates |
                            Where-Object {
                                $_ -eq 'PowerState/stopped' -or
                                $_ -eq 'PowerState/deallocated'
                            }
                    ).Count

                    Write-Output "Instances    : $($VMSSInstances.Count)"
                    Write-Output "Running      : $RunningCount"
                    Write-Output "Stopped      : $StoppedCount"

                    if ($Action -eq 'Stop') {

                        if ($StoppedCount -eq $VMSSInstances.Count) {

                            $ResultStatus = 'Skipped'
                            $ResultDetail = 'All VMSS instances are already stopped.'
                        }
                        else {

                            Write-Output "Stopping VMSS $($Resource.name)..."

                            Stop-AzVmss `
                                -ResourceGroupName $Resource.resourceGroup `
                                -VMScaleSetName $Resource.name `
                                -Force `
                                -ErrorAction Stop | Out-Null

                            $ResultStatus = 'Succeeded'
                            $ResultDetail = 'VMSS stop completed.'
                        }
                    }
                    else {

                        if ($RunningCount -eq $VMSSInstances.Count) {

                            $ResultStatus = 'Skipped'
                            $ResultDetail = 'All VMSS instances are already running.'
                        }
                        else {

                            Write-Output "Starting VMSS $($Resource.name)..."

                            Start-AzVmss `
                                -ResourceGroupName $Resource.resourceGroup `
                                -VMScaleSetName $Resource.name `
                                -ErrorAction Stop | Out-Null

                            $ResultStatus = 'Succeeded'
                            $ResultDetail = 'VMSS start completed.'
                        }
                    }
                }
            }

            #
            # AKS CLUSTER
            #
            # Manage AKS using the cluster-level start/stop operations.
            #
            # Do NOT directly stop the VMSS instances backing AKS node pools.
            # AKS must control the lifecycle of its own underlying compute.
            #

            'microsoft.containerservice/managedclusters' {

                $DisplayType = 'AKS Cluster'

                Write-Output "Resource Type: $DisplayType"

                $AKSCluster = Get-AzAksCluster `
                    -ResourceGroupName $Resource.resourceGroup `
                    -Name $Resource.name `
                    -SubscriptionId $Resource.subscriptionId `
                    -ErrorAction Stop

                $PowerState = [string]$AKSCluster.PowerState.Code

                if (-not $PowerState) {

                    $PowerState = 'Unknown'
                }

                Write-Output "Current State: $PowerState"

                if ($Action -eq 'Stop') {

                    if ($PowerState -eq 'Stopped') {

                        $ResultStatus = 'Skipped'
                        $ResultDetail = 'AKS cluster is already stopped.'
                    }
                    else {

                        Write-Output "Stopping AKS cluster $($Resource.name)..."

                        Stop-AzAksCluster `
                            -ResourceGroupName $Resource.resourceGroup `
                            -Name $Resource.name `
                            -SubscriptionId $Resource.subscriptionId `
                            -Confirm:$false `
                            -ErrorAction Stop | Out-Null

                        $ResultStatus = 'Succeeded'
                        $ResultDetail = 'AKS stop completed.'
                    }
                }
                else {

                    if ($PowerState -eq 'Running') {

                        $ResultStatus = 'Skipped'
                        $ResultDetail = 'AKS cluster is already running.'
                    }
                    else {

                        Write-Output "Starting AKS cluster $($Resource.name)..."

                        Start-AzAksCluster `
                            -ResourceGroupName $Resource.resourceGroup `
                            -Name $Resource.name `
                            -SubscriptionId $Resource.subscriptionId `
                            -Confirm:$false `
                            -ErrorAction Stop | Out-Null

                        $ResultStatus = 'Succeeded'
                        $ResultDetail = 'AKS start completed.'
                    }
                }
            }

            #
            # UNSUPPORTED RESOURCE
            #
            # Defensive fallback. Normally unsupported resource types cannot
            # reach this point because Resource Graph filters them beforehand.
            #

            default {

                $ResultStatus = 'Skipped'
                $ResultDetail = "Unsupported resource type: $AzureResourceType"
            }
        }

        #
        # UPDATE RESULT COUNTERS
        #

        if ($ResultStatus -eq 'Succeeded') {

            $Succeeded++
        }
        elseif ($ResultStatus -eq 'Skipped') {

            $Skipped++
        }

        Write-Output "Result       : $($ResultStatus.ToUpperInvariant())"
        Write-Output "Detail       : $ResultDetail"

        #
        # STORE RESULT
        #
        # ResourceId is retained even though it is not displayed in the
        # summary table. This makes the result data more useful for future
        # logging or troubleshooting enhancements.
        #

        $Results += [pscustomobject]@{
            Name          = $Resource.name
            Type          = $DisplayType
            Subscription  = $Resource.subscriptionId
            ResourceGroup = $Resource.resourceGroup
            ResourceId    = $Resource.id
            Action        = $Action
            Result        = $ResultStatus
            Detail        = $ResultDetail
        }
    }
    catch {

        $Failed++

        $ErrorMessage = $_.Exception.Message

        Write-Output 'Result       : FAILED'
        Write-Output "Error        : $ErrorMessage"

        $Results += [pscustomobject]@{
            Name          = $Resource.name
            Type          = $DisplayType
            Subscription  = $Resource.subscriptionId
            ResourceGroup = $Resource.resourceGroup
            ResourceId    = $Resource.id
            Action        = $Action
            Result        = 'Failed'
            Detail        = $ErrorMessage
        }
    }
}

#
# DETAILED RESULTS
#

Write-Output ''
Write-Output '========================================================'
Write-Output 'RESOURCE RESULTS'
Write-Output '========================================================'

$FormattedResults = $Results |
    Sort-Object Type, Name |
    Format-Table `
        Name,
        Type,
        Action,
        Result,
        Detail `
        -AutoSize |
    Out-String

Write-Output $FormattedResults

#
# RESOURCE TYPE SUMMARY
#
# Provide a quick breakdown of the resource types selected during the job.
#

Write-Output 'RESOURCE TYPE SUMMARY'

$Results |
    Group-Object Type |
    Sort-Object Name |
    ForEach-Object {
        Write-Output "  $($_.Name): $($_.Count)"
    }

#
# FINAL EXECUTION SUMMARY
#

$RunEndTime = Get-Date
$RunDuration = $RunEndTime - $RunStartTime
$DurationSeconds = [math]::Round($RunDuration.TotalSeconds, 1)

Write-Output ''
Write-Output '========================================================'
Write-Output 'POWER MANAGEMENT COMPLETE'
Write-Output '========================================================'
Write-Output "Started       : $($RunStartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Completed     : $($RunEndTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Duration      : $DurationSeconds seconds"
Write-Output ''
Write-Output "Action        : $Action"
Write-Output "Resource Type : $ResourceType"
Write-Output "Tag           : $TagName=$TagValue"
Write-Output "Subscriptions : $($SubscriptionIds.Count)"
Write-Output ''
Write-Output "Discovered    : $($Resources.Count)"
Write-Output "Succeeded     : $Succeeded"
Write-Output "Skipped       : $Skipped"
Write-Output "Failed        : $Failed"
Write-Output '========================================================'
Write-Output ''

#
# FINAL JOB STATUS
#
# Individual failures do not stop processing of remaining resources.
# However, deliberately fail the Automation job here if any resource failed
# so monitoring and alerting can identify an incomplete scheduled execution.
#

if ($Failed -gt 0) {

    throw "$Failed resource power operation(s) failed. Review the job output."
}