$ErrorActionPreference = "Stop"

$yamlDotNetVersion = "15.1.2"

# set 'USERPROFILE' env on Linux
$env:USERPROFILE = if ($env:USERPROFILE) { $env:USERPROFILE } else { '~' }
$env:NUGET_PACKAGES = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { "$($env:USERPROFILE)/.nuget/packages" }
$env:NUGET_PACKAGES = "$($env:NUGET_PACKAGES.TrimEnd('/'))/"

function ThrowOnNativeFailure {
    if (-not $?) {
        throw "Last command failed with code $LASTEXITCODE"
    }
}

function ReplaceVariables {
    param (
        [string] $Value,
        [bool] $UseMinGwPath = $false
    )

    return $Value -replace '\${{\s*(?<key>[^}]+?)\s*}}', {
        $variableName = $_.Groups['key'].Value
        if ($variableName -eq 'github.workspace') {
            $path = (Get-Location).Path
            if ($Value.StartsWith('file://')) {
                $path = $path -replace '\\', '/'
                if (-not $Value.StartsWith('file:///')) {
                    # need tribble slash at start
                    $path = "/$path"
                }

                return $path
            }
            elseif ($UseMinGwPath) {
                $path = $path -replace '(\w):', { "/$($_.Groups[1].Value.ToLowerInvariant())" }
                $path = $path -replace '\\', '/'
                return $path
            }
            else {
                return $path
            }
        }

        return Read-Host -Prompt "Enter value for '$($_.Value)'"
    }
}

function ApplyEnvironmentVariables {
    param (
        $environmentVariables
    )

    if (-not $environmentVariables) {
        return
    }

    foreach ($environmentVariable in $environmentVariables.GetEnumerator()) {
        $value = ReplaceVariables -Value $environmentVariable.Value
        Set-Item -Path Env:\$($environmentVariable.Key) -Value $value
    }
}

function ApplyInputVariables {
    param (
        $inputs
    )

    if (-not $inputs) {
        return
    }

    foreach ($input in $inputs.GetEnumerator()) {
        $value = ReplaceVariables -Value $input.Value
        Set-Item -Path Env:\INPUT_$($input.Key.ToUpperInvariant()) -Value $value
    }
}

function RunScript {
    param (
        [System.Collections.Generic.Dictionary[System.Object, System.Object]] $step
    )

    ApplyEnvironmentVariables($step['env'])

    [string] $script = $step['run']
    if ($script.Contains("git push")) {
        Write-Host "Skipping Git push"
        return
    }

    if ($IsWindows) {
        # don't bind certs volum
        $script = $script -replace "-v /etc/ssl/certs:/etc/ssl/certs:ro ", ""
    }

    if ($IsWindows -and ($step['shell'] -eq 'bash') -and $script.StartsWith("docker")) {
        $step['shell'] = 'pwsh'
        $script = $script -replace '\\"', '`"'
        $script = $script -replace '\\\$', '`$'
        $script = $script -replace '(;|&&)?\s+chmod[ \w\-+/]+', ''
        $script += "; ThrowOnNativeFailure"
    }

    if ($step['shell'] -eq 'bash') {
        $script = ReplaceVariables -Value $script -UseMinGwPath $IsWindows
        $tempDirectory = [System.IO.Path]::GetTempPath()
        $scriptFile = Join-Path -Path $tempDirectory -ChildPath "$([System.Guid]::NewGuid()).sh"
        Set-Content -Path $scriptFile -Value $script
        try {
            $executable = if ($IsWindows) { "$($env:ProgramFiles)\Git\bin\bash.exe" } else { "bash" }
            $process = Start-Process -PassThru -NoNewWindow -FilePath $executable -ArgumentList @('--login', '-i', '--', $scriptFile)
            $handle = $process.Handle # cache handle to allow access to exit code. See https://stackoverflow.com/a/23797762
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw "script in step '$($step['name'])' failed with exit code $($process.ExitCode)"
            }

            $null = $handle
            return
        }
        finally {
            Remove-Item -Path $scriptFile
        }
    }

    if ($step['shell'] -ne 'pwsh') {
        throw "Unsuported shell $($step['shell'])"
    }

    $script = ReplaceVariables -Value $script
    Invoke-Expression -Command $script
}

$oldLocation = Get-Location
Set-Location $PSScriptRoot/..

try {
    $workingDirectory = Read-Host -Prompt "Set Working Directory. Default $(Get-Location)"
    if ($workingDirectory) {
        $workingDirectory = [System.IO.Path]::GetFullPath($workingDirectory)
        if (-not (Test-Path $workingDirectory)) {
            $null = New-Item $workingDirectory -ItemType Directory
        }

        Set-Location $workingDirectory
    }

    $env:GITHUB_WORKSPACE = (Get-Location).Path

    $yamlDotNetAssemblyPath = "$($env:NUGET_PACKAGES)/yamldotnet/$yamlDotNetVersion/lib/netstandard2.1/YamlDotNet.dll"
    if (-not (Test-Path -Path $yamlDotNetAssemblyPath)) {
        $tempDirectory = [System.IO.Path]::GetTempPath()
        dotnet new console --name NuGetRestorer --output $tempDirectory
        ThrowOnNativeFailure

        dotnet add "$tempDirectory/NuGetRestorer.csproj" package YamlDotNet --version $yamlDotNetVersion
        ThrowOnNativeFailure

        Remove-Item "$tempDirectory/NuGetRestorer.csproj"
    }

    Add-Type -AssemblyName $yamlDotNetAssemblyPath

    if (-not (Test-Path -Path ".git")) {
        $branch = Read-Host -Prompt "Checkout branch: Default: [main]"
        $branch = if ($branch) { $branch } else { 'main' }
        Write-Host "Cloning from git" -ForegroundColor DarkYellow
        git clone $gitUrl --branch $branch --single-branch .
        ThrowOnNativeFailure
    }
    else {
        $oldGitConfig = Get-Content -Raw ".git/config" -Encoding utf8
    }

    $workflowFiles = Get-ChildItem -Path '.github/workflows'
    $choiceIndex = 1
    $decision = $Host.UI.PromptForChoice("workflow", "What workflow to run?", ($workflowFiles | ForEach-Object { "&$(($choiceIndex++)) - $($_.Name)" }), 0)
    $workflowFile = $workflowFiles[$decision]

    $deserializer = (New-Object -TypeName 'YamlDotNet.Serialization.DeserializerBuilder').Build()
    $workflowFileContent = Get-Content -Raw -Path $workflowFile
    $workflow = $deserializer.Deserialize($workflowFileContent)

    Write-Host "Selected workflow '$($workflow['name'])'" -ForegroundColor DarkYellow
    $jobs = $workflow["jobs"]
    foreach ($job in $jobs.Values) {
        Write-Host "Start job '$($job['name'])'" -ForegroundColor DarkYellow
        ApplyEnvironmentVariables($job['env'])

        $steps = $job['steps']
        foreach ($step in $steps) {
            Write-Host "Start step '$($step['name'])'" -ForegroundColor DarkYellow
            $uses = $step['uses']
            if ($uses -like 'actions/checkout@*') {
                if (-not (Test-Path -Path ".git")) {
                    $branch = Read-Host -Prompt "Checkout branch: Default: [main]"
                    $branch = if ($branch) { $branch } else { 'main' }
                    Write-Host "Cloning from git" -ForegroundColor DarkYellow
                    git clone $gitUrl --branch $branch --single-branch .
                    ThrowOnNativeFailure
                }

                $env:GITHUB_REF = $(git symbolic-ref HEAD)
                $env:GITHUB_REF_NAME = $(git symbolic-ref --short HEAD)
                $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
                $env:GITHUB_REF_TYPE = 'branch'
                $env:GITHUB_SHA = $(git rev-parse HEAD)
            }
            elseif ($uses -like 'docker/login-action@*') {
                # skip
            }
            elseif ($uses -like 'actions/cache*') {
                # skip
            }
            elseif ($uses -like 'actions/setup-dotnet@*') {
                # skip
            }
            elseif ($uses -like 'actions/setup-java@*') {
                # skip
            }
            elseif ($uses -like 'actions/setup-python@*') {
                # skip
            }
            elseif (-not $uses) {
                RunScript($step)
            }
            else {
                throw "Unknown 'uses' in step: $uses"
            }
        }
    }
}
finally {
    if ($oldGitConfig) {
        Set-Content -Path ".git/config" -Value $oldGitConfig -Encoding utf8
    }

    Set-Location $oldLocation

    if ($workingDirectory) {
        $decision = $Host.UI.PromptForChoice("Delete Working Directory '$workingDirectory'?", '', @('&Yes', '&No'), 1)
        if ($decision -eq 0) {
            Remove-Item -Path $workingDirectory -Recurse
        }
    }
}
