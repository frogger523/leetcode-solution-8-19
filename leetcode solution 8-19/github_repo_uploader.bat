@echo off
setlocal
set "GITHUB_UPLOAD_SCRIPT=%~f0"
pushd "%~dp0" >nul
if errorlevel 1 (
    echo Could not open the folder containing this script.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$content = Get-Content -LiteralPath $env:GITHUB_UPLOAD_SCRIPT -Raw; $marker = '#__POWERSHELL_BELOW__'; $index = $content.LastIndexOf($marker); if ($index -lt 0) { throw 'Embedded PowerShell section not found.' }; & ([scriptblock]::Create($content.Substring($index + $marker.Length)))"
set "SCRIPT_EXIT=%ERRORLEVEL%"
popd

if not "%SCRIPT_EXIT%"=="0" (
    echo.
    echo The upload did not complete. See the error above.
)

echo.
pause
exit /b %SCRIPT_EXIT%

#__POWERSHELL_BELOW__

$ErrorActionPreference = 'Stop'
$sourceDirectory = (Get-Location).Path
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ("github-repo-uploader-" + [guid]::NewGuid().ToString('N'))
$stagingDirectory = Join-Path $workDirectory 'selected-files'
$cloneDirectory = Join-Path $workDirectory 'repository'
$repoCreated = $false
$fullRepoName = $null

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Program,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Read-RequiredValue {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    do {
        $value = Read-Host $Prompt
        $value = ([Convert]::ToString($value)).Trim()
        if (-not $value) {
            Write-Host 'A value is required.' -ForegroundColor Yellow
        }
    } until ($value)
    return $value
}

try {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is not installed or is not on PATH. Install it from https://cli.github.com/"
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or is not on PATH.'
    }

    Write-Host 'Checking GitHub authentication...'
    Invoke-NativeCommand -Program 'gh' -Arguments @('auth', 'status')

    Write-Host ''
    Write-Host 'This creates a GitHub repository with README.md and a GPL-3.0 license.' -ForegroundColor Cyan
    $repoName = Read-RequiredValue 'Repository name (NAME or OWNER/NAME)'
    $normalizedRepoName = $repoName -replace '\s+', '-'
    if ($normalizedRepoName -ne $repoName) {
        Write-Host "GitHub repository name: $normalizedRepoName" -ForegroundColor Yellow
        $repoName = $normalizedRepoName
    }
    $description = Read-Host 'Repository description (optional)'

    do {
        $visibilityInput = Read-Host 'Visibility [public/private] (default: public)'
        $visibilityInput = ([Convert]::ToString($visibilityInput)).Trim().ToLowerInvariant()
        if (-not $visibilityInput) {
            $visibility = 'public'
        }
        elseif ($visibilityInput -in @('public', 'private')) {
            $visibility = $visibilityInput
        }
        else {
            $visibility = $null
            Write-Host 'Enter public or private.' -ForegroundColor Yellow
        }
    } until ($visibility)

    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    $uploadCount = 0

    Write-Host ''
    Write-Host 'Enter one file or folder at a time. Relative paths use:' -ForegroundColor Cyan
    Write-Host "  $sourceDirectory"
    Write-Host 'Files go in the repository root; folders keep their folder name.'
    Write-Host 'Press Enter on a blank line when finished.'

    while ($true) {
        $enteredPath = Read-Host 'File/folder path'
        $enteredPath = ([Convert]::ToString($enteredPath)).Trim()
        if (-not $enteredPath) {
            break
        }

        if (($enteredPath.StartsWith('"') -and $enteredPath.EndsWith('"')) -or
            ($enteredPath.StartsWith("'") -and $enteredPath.EndsWith("'"))) {
            $enteredPath = $enteredPath.Substring(1, $enteredPath.Length - 2)
        }

        try {
            $item = Get-Item -LiteralPath $enteredPath -Force -ErrorAction Stop
        }
        catch {
            Write-Host "Not found: $enteredPath" -ForegroundColor Yellow
            continue
        }

        if ($item.Name -ieq '.git') {
            Write-Host 'The .git metadata folder cannot be uploaded.' -ForegroundColor Yellow
            continue
        }
        if (-not $item.PSIsContainer -and $item.Name -in @('README.md', 'LICENSE')) {
            Write-Host "$($item.Name) is generated automatically; choose a different file." -ForegroundColor Yellow
            continue
        }

        $destination = Join-Path $stagingDirectory $item.Name
        if (Test-Path -LiteralPath $destination) {
            Write-Host "A selected item named '$($item.Name)' is already staged. Rename one of them first." -ForegroundColor Yellow
            continue
        }

        Write-Host "Staging $($item.FullName)..."
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force

        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $destination -Directory -Force -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq '.git' } |
                Remove-Item -Recurse -Force
        }

        $uploadCount++
    }

    if ($uploadCount -eq 0) {
        $continueWithoutFiles = Read-Host 'No files were selected. Create the README/license-only repository? [y/N]'
        $continueWithoutFiles = ([Convert]::ToString($continueWithoutFiles)).Trim()
        if ($continueWithoutFiles -notmatch '^(?i)y(?:es)?$') {
            throw 'Cancelled before creating the repository.'
        }
    }

    Write-Host ''
    Write-Host "Creating $visibility repository '$repoName'..." -ForegroundColor Cyan
    $createArguments = @(
        'repo', 'create', $repoName,
        '--description', $description,
        "--$visibility",
        '--add-readme',
        '--license', 'gpl-3.0'
    )
    Invoke-NativeCommand -Program 'gh' -Arguments $createArguments
    $repoCreated = $true

    $fullRepoName = & gh repo view $repoName --json nameWithOwner --jq '.nameWithOwner'
    $fullRepoName = ([Convert]::ToString($fullRepoName)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $fullRepoName) {
        throw 'The repository was created, but its full GitHub name could not be determined.'
    }

    Write-Host ''
    Write-Host 'Cloning the new repository and adding the selected files...'
    Invoke-NativeCommand -Program 'gh' -Arguments @('repo', 'clone', $fullRepoName, $cloneDirectory)

    Get-ChildItem -LiteralPath $stagingDirectory -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $cloneDirectory -Recurse -Force
    }

    Invoke-NativeCommand -Program 'git' -Arguments @('-C', $cloneDirectory, 'add', '--all')

    & git -C $cloneDirectory diff --cached --quiet
    $hasChanges = ($LASTEXITCODE -eq 1)
    if ($LASTEXITCODE -gt 1) {
        throw 'Git could not inspect the staged files.'
    }

    if ($hasChanges) {
        $gitName = & git -C $cloneDirectory config user.name
        $gitName = ([Convert]::ToString($gitName)).Trim()
        if (-not $gitName) {
            $gitName = Read-RequiredValue 'Git commit author name'
            Invoke-NativeCommand -Program 'git' -Arguments @('-C', $cloneDirectory, 'config', 'user.name', $gitName)
        }

        $gitEmail = & git -C $cloneDirectory config user.email
        $gitEmail = ([Convert]::ToString($gitEmail)).Trim()
        if (-not $gitEmail) {
            $gitEmail = Read-RequiredValue 'Git commit author email'
            Invoke-NativeCommand -Program 'git' -Arguments @('-C', $cloneDirectory, 'config', 'user.email', $gitEmail)
        }

        Invoke-NativeCommand -Program 'git' -Arguments @('-C', $cloneDirectory, 'commit', '-m', 'Add project files')
        Invoke-NativeCommand -Program 'git' -Arguments @('-C', $cloneDirectory, 'push', 'origin', 'HEAD')
    }
    else {
        Write-Host 'There were no new file changes to commit.' -ForegroundColor Yellow
    }

    $repoUrl = & gh repo view $fullRepoName --json url --jq '.url'
    $repoUrl = ([Convert]::ToString($repoUrl)).Trim()
    if ($LASTEXITCODE -ne 0) {
        $repoUrl = "https://github.com/$fullRepoName"
    }

    Write-Host ''
    Write-Host 'Done!' -ForegroundColor Green
    Write-Host "Repository: $repoUrl"
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.ScriptLineNumber) {
        $errorSource = ([Convert]::ToString($_.InvocationInfo.Line)).Trim()
        Write-Host "Embedded PowerShell line $($_.InvocationInfo.ScriptLineNumber): $errorSource" -ForegroundColor DarkGray
    }
    if ($repoCreated) {
        $createdLabel = if ($fullRepoName) { $fullRepoName } else { $repoName }
        Write-Host "The GitHub repository '$createdLabel' was created, but the upload did not finish." -ForegroundColor Yellow
        Write-Host 'It was not deleted automatically.' -ForegroundColor Yellow
    }
    exit 1
}
finally {
    if (Test-Path -LiteralPath $workDirectory) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
