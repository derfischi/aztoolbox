#Requires -Modules Az.Accounts,Az.Automation

param(
    # Add your runbook-specific parameters here
    #

    # Runbook context information such as runbook name, resource group, automation account, and subscription ID (do not modify unless you know what you are doing)
    [Parameter(Mandatory = $false)]
    [hashtable]$RunbookContext = @{
        # Replace the placeholder values with actual runbook context information
        RunbookName           = "<runbook_name>";
        ResourceGroupName     = "<resource_group_name>";
        AutomationAccountName = "<automation_account_name>";
        SubscriptionId        = "<subscription_id>"
    }
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

#region Runbook Configuration

# Set to false to disable runbook concurrency check
$RunbookConcurrencyCheck = $true

#endregion

#region Runbook Lifecycle

function Get-RunbookJobId {
    $jobId = $null
    $privateMetadata = Get-Variable -Name PSPrivateMetadata -ValueOnly -ErrorAction SilentlyContinue
 
    Write-Warning "Current PowerShell version: $($PSVersionTable.PSVersion)"

    if ($null -eq $privateMetadata -and [string]::IsNullOrEmpty($env:PSPrivateMetadata)) {
        Write-Warning "Both `$PSPrivateMetadata and `$env:PSPrivateMetadata are null or empty. Assuming interactive session."
        return "interactive"
    }

    if ($PSVersionTable.PSVersion.Major -eq 5) {
        Write-Warning "Returning JobId from `$PSPrivateMetadata: $($privateMetadata.JobId.Guid)"
        return $privateMetadata.JobId.Guid
    }
 
    if ($PSVersionTable.PSVersion.Major -ne 7) {
        Write-Warning "Unsupported PowerShell version: $($PSVersionTable.PSVersion)"
        return $null
    }

    # For PowerShell 7.x, handle different minor versions separately

    if ($PSVersionTable.PSVersion.Minor -le 1) {
        Write-Warning "PowerShell 7 minor version <= 1, returning `$env:PSPrivateMetadata: ${env:PSPrivateMetadata}"
        return $env:PSPrivateMetadata
    }

    # Not running on a hybrid runbook worker
    if ($env:AZUREPS_HOST_ENVIRONMENT -ne "AzureAutomation/") {
        Write-Warning "Not running on a hybrid runbook worker, returning $($privateMetadata.JobId)"
        return $privateMetadata.JobId
    }

    if ($env:PSPrivateMetadata -ne "System.Collections.Hashtable") {
        Write-Warning "Returning JobId from `$env:PSPrivateMetadata: ${env:PSPrivateMetadata}"
        return $env:PSPrivateMetadata
    }

    Write-Warning "`$env:PSPrivateMetadata is set to ${env:PSPrivateMetadata}"

    if ($PWD -match "HybridWorker") {
        Write-Warning "Trying a workaround to find JobID as this is a HRW"
        
        if ($PSScriptRoot) {
            $parentPath = Split-Path -Parent $PSScriptRoot
        } else {
            $parentPath = $null
        }
        
        Write-Warning "Parent path determined as $parentPath"

        if ($parentPath) {
            $fullPath = $parentPath + "\diags\trace.log"
            Write-Warning "Full path to trace log: $fullPath"
            try {
                $jobId = ((Get-Content $fullPath -ErrorAction Stop | Select-String "jobId") -split 'jobId=')[1] -replace ']', ''
            
            } catch {
                $jobId = $null
            }
        }
    }

    return $jobId
}

function Test-IsRunbookInvokedFromAutomation {
    $currentJobId = Get-RunbookJobId
    if ($currentJobId -eq "interactive") {
        Write-Verbose "Invoked interactively."
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($currentJobId)) {
        Write-Warning "No current job ID found. Assuming interactive execution."
        return $false
    }
    Write-Verbose "Invoked from automation account."
    return $true
}

function Test-RunbookExecution {
    param (
        [Parameter(Mandatory = $true, Position = 0)][string]$Runbook,
        [Parameter(Mandatory = $true, Position = 1)][string]$ResourceGroup,
        [Parameter(Mandatory = $true, Position = 2)][string]$AutomationAccount,
        [Parameter(Mandatory = $true, Position = 3)][string]$SubscriptionId,
        [Parameter(Mandatory = $false)][switch]$RunOnScopeLock
    )

    foreach ($requiredValue in @($Runbook, $ResourceGroup, $AutomationAccount, $SubscriptionId)) {
        if ([string]::IsNullOrWhiteSpace($requiredValue) -or $requiredValue -match '^(?:<[^<>]+>|\$\{.+\})$') {
            throw "RunbookContext contains an empty or unresolved placeholder value."
        }
    }

    Disable-AzContextAutosave -Scope Process | Out-Null
    $azctx = (Connect-AzAccount -Identity -ErrorAction Stop).Context
    $azctx = Set-AzContext -Subscription $SubscriptionId -DefaultProfile $azctx -ErrorAction Stop

    $currentJobId = Get-RunbookJobId
    if ([string]::IsNullOrWhiteSpace($currentJobId)) {
        Write-Warning "No current Automation JobId detected. Skipping lock check."
        return $true
    }

    $activeStates = @("Running", "Queued", "New", "Activating", "Resuming", "Starting", "Stopping")
    $maxAttempts = 5
    $retryDelaySeconds = 2
    $currentJob = $null
    $jobs = @()

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # This job-list check is best-effort, not an atomic lock; simultaneous starts can both pass.
        $jobs = @(Get-AzAutomationJob `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccount `
                -RunbookName $Runbook `
                -DefaultProfile $azctx |
            Where-Object { $_.Status -in $activeStates })

        $currentJob = $jobs | Where-Object { [string]$_.JobId -eq [string]$currentJobId } | Select-Object -First 1
        if (-not $currentJob) {
            $currentJob = Get-AzAutomationJob `
                -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccount `
                -Id $currentJobId `
                -DefaultProfile $azctx `
                -ErrorAction SilentlyContinue
        }

        if ($currentJob) {
            if (-not ($jobs | Where-Object { [string]$_.JobId -eq [string]$currentJob.JobId })) {
                $jobs += $currentJob
            }
            break
        }

        Write-Warning "Lock check attempt ${attempt}/${maxAttempts}: current job '$currentJobId' not visible yet."
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    if (-not $currentJob) {
        $utcNow = (Get-Date).ToUniversalTime()
        $olderVisibleJob = $jobs |
        Where-Object { $_.CreationTime.ToUniversalTime() -lt $utcNow.AddMinutes(-2) } |
        Sort-Object -Property CreationTime, @{ Expression = { [string]$_.JobId } } |
        Select-Object -First 1

        if ($olderVisibleJob) {
            Write-Warning "Lock check denied: current job '$currentJobId' still not visible after retries and older active job '$($olderVisibleJob.JobId)' exists."
            return $false
        }

        Write-Warning "Lock check fallback: current job '$currentJobId' not visible after retries and no older active jobs found. Proceeding."
        return $true
    }

    $currentHybridWorkerRaw = [string]$currentJob.HybridWorker
    $currentHybridWorker = if ([string]::IsNullOrWhiteSpace($currentHybridWorkerRaw)) { $null } else { $currentHybridWorkerRaw.Trim() }
    $jobsInScope = @($jobs)
    $effectiveScope = "runbook-fallback"

    if ($RunOnScopeLock -and $currentHybridWorker) {
        $jobsInScope = @(
            $jobs |
            Where-Object {
                $jobHybridWorkerRaw = [string]$_.HybridWorker
                -not [string]::IsNullOrWhiteSpace($jobHybridWorkerRaw) -and
                $jobHybridWorkerRaw.Trim().Equals($currentHybridWorker, [StringComparison]::OrdinalIgnoreCase)
            }
        )

        if (-not ($jobsInScope | Where-Object { [string]$_.JobId -eq [string]$currentJob.JobId })) {
            $jobsInScope += $currentJob
        }

        $effectiveScope = "hybrid-worker:$currentHybridWorker"
    } elseif ($RunOnScopeLock -and -not $currentHybridWorker) {
        Write-Warning "Lock check scope fallback: RunOnScopeLock is enabled but current job '$currentJobId' has empty HybridWorker. Using runbook-wide lock scope."
    } else {
        Write-Verbose "RunOnScopeLock is disabled. Using runbook-wide lock scope."
    }

    $winner = $jobsInScope |
    Sort-Object -Property CreationTime, @{ Expression = { [string]$_.JobId } } |
    Select-Object -First 1

    $isWinner = [string]$winner.JobId -eq [string]$currentJob.JobId

    if (-not $isWinner) {
        Write-Warning "Lock check denied ($effectiveScope): winner job '$($winner.JobId)' (created $($winner.CreationTime.ToUniversalTime().ToString('o'))) outranks current '$currentJobId'."
        return $false
    }

    Write-Verbose "Lock check passed ($effectiveScope): current job '$currentJobId' is winner among $($jobsInScope.Count) active job(s) in scope."
    return $true
}

#endregion

#region Auxiliary Functions

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level,
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    $ts = (Get-Date).ToUniversalTime().ToString("o")
    $jobId = Get-RunbookJobId
    Write-Output ("[{0}] [{1}] [job:{2}] {3}" -f $ts, $Level, $jobId, $Message)
}

#endregion

#region Runbook Execution

if (Test-IsRunbookInvokedFromAutomation) {
    if (-not ($RunbookConcurrencyCheck -and Test-RunbookExecution `
                $RunbookContext["RunbookName"] `
                $RunbookContext["ResourceGroupName"] `
                $RunbookContext["AutomationAccountName"] `
                $RunbookContext["SubscriptionId"] `
                -RunOnScopeLock)) {
        Write-Warning "Another job instance is already running. Exiting to avoid a trigger race."
        return
    }

    # Uncomment as needed for authentication
    # Connect-MgGraph -Identity -NoWelcome
    # Connect-AzAccount -Identity
}

#
# Put your runbook execution logic here
#

#endregion