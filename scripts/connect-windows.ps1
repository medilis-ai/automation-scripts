<#
Interactive helper for connecting to a hailth.ai GCP VM from a Windows
machine via IAP, as an alternative to installing/configuring IAP
Desktop. Mirrors scripts/connect-mac.sh — see docs/connect-from-mac.md
for the equivalent manual walkthrough (same idea, different client).

Usage: right-click -> Run with PowerShell, or from a PowerShell prompt:
  .\scripts\connect-windows.ps1
#>

$ErrorActionPreference = "Stop"

# Defensive: on some PowerShell/gcloud-SDK combinations, a native
# command's stderr output gets turned into an error record that
# $ErrorActionPreference = "Stop" above then escalates into a
# terminating error -- even past a `2>$null` redirect on the call site,
# confirmed on a real run where gcloud.ps1's own internal call into
# python.exe leaked a PERMISSION_DENIED this way. $false restores the
# older, simpler behavior (a non-zero native exit code is just that,
# not an escalated error) wherever this variable exists; the real,
# always-effective fix is still wrapping any gcloud call that's
# expected to sometimes fail in try/catch, see Test-Access below.
$PSNativeCommandUseErrorActionPreference = $false

$ProjectId = "hailth-radiology"
$RdpPort = 3389

$TunnelProcess = $null
$TempRdpFile = $null
function Cleanup {
    if ($TunnelProcess -and -not $TunnelProcess.HasExited) {
        Stop-Process -Id $TunnelProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($TempRdpFile -and (Test-Path $TempRdpFile)) {
        Remove-Item $TempRdpFile -Force -ErrorAction SilentlyContinue
    }
}

try {

# ---------------------------------------------------------------------------
# Step 1 - make sure gcloud is installed
# ---------------------------------------------------------------------------
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: gcloud (the Google Cloud CLI) is not installed." -ForegroundColor Red

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget isn't available either, so this script can't install it for you." -ForegroundColor Red
        Write-Host "Install it manually: https://cloud.google.com/sdk/docs/install-sdk#windows -- then re-run this script."
        exit 1
    }

    $reply = Read-Host "Install gcloud now via winget? [y/N]"
    if ($reply -match '^[Yy]') {
        winget install --id Google.CloudSDK -e --accept-package-agreements --accept-source-agreements
        if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
            Write-Host "gcloud was installed but isn't on PATH yet in this window. Close this PowerShell window, open a new one, and re-run this script." -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Host "Can't continue without gcloud. Exiting." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Arrow-key menu: pass an array of labels, get back the chosen index
# ---------------------------------------------------------------------------
function Select-Menu {
    param([string[]]$Options)

    $idx = 0
    $count = $Options.Count

    function Draw {
        for ($i = 0; $i -lt $count; $i++) {
            if ($i -eq $idx) {
                Write-Host "> $($Options[$i])" -ForegroundColor Black -BackgroundColor White
            } else {
                Write-Host "  $($Options[$i])"
            }
        }
    }

    Draw
    while ($true) {
        $key = [System.Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow" { $idx = ($idx - 1 + $count) % $count }
            "DownArrow" { $idx = ($idx + 1) % $count }
            "Enter" {
                return $idx
            }
        }
        [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop - $count)
        Draw
    }
}

# Whether this account can read a given VM's support-account secret --
# in this project's IAM model, that permission and IAP tunnel access are
# always granted together per person/group, so it's a reliable stand-in
# for "can this person actually use this VM," without requiring
# compute.viewer (which is project-wide) to also imply real access, and
# without actually capturing/exposing the secret's content just to test
# for it.
function Test-Access([string]$VmName) {
    # try/catch, not just checking $LASTEXITCODE, because a real
    # PERMISSION_DENIED here can surface as a terminating error (see the
    # note on $PSNativeCommandUseErrorActionPreference above) rather
    # than just a non-zero exit code -- without this, Test-Access
    # correctly detecting "no access" on any VM crashed the whole
    # script instead of just returning $false. Confirmed on a real run.
    try {
        gcloud secrets versions access latest --secret="$VmName-support-login" --project=$ProjectId 2>$null | Out-Null
    } catch {
        return $false
    }
    return $LASTEXITCODE -eq 0
}

# ---------------------------------------------------------------------------
# Step 2 - log in, if not already
# ---------------------------------------------------------------------------
$activeAccount = (gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null)

if ($activeAccount) {
    Write-Host "Already logged in as: $activeAccount"
} else {
    Write-Host ""
    Write-Host "You need to sign in with your Google account first."
    $choice = Select-Menu -Options @(
        "Open a browser window to sign in (recommended)",
        "Show a code to enter on another device (no browser)"
    )
    Write-Host ""

    if ($choice -eq 0) {
        gcloud auth login
    } else {
        gcloud auth login --no-launch-browser
    }

    $activeAccount = (gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null)
    if (-not $activeAccount) {
        Write-Host "ERROR: login didn't complete. Re-run the script and try again." -ForegroundColor Red
        exit 1
    }
}

gcloud config set project $ProjectId -q | Out-Null

# ---------------------------------------------------------------------------
# Step 3 - list VMs, let the user pick one
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Fetching VM list for project $ProjectId..."
$vmLines = gcloud compute instances list --project=$ProjectId --format="value(name,zone,status)"
if (-not $vmLines) {
    Write-Host "No VMs found (or you don't have compute.viewer on this project)." -ForegroundColor Red
    exit 1
}

Write-Host "Checking which of these you actually have access to..."
$vms = @()
$labels = @()
foreach ($line in $vmLines) {
    $parts = $line -split "`t"
    $vms += [PSCustomObject]@{ Name = $parts[0]; Zone = $parts[1]; Status = $parts[2] }
    $accessLabel = if (Test-Access $parts[0]) { "access: yes" } else { "access: no" }
    $labels += ("{0,-22} {1,-26} [{2,-11}] [{3}]" -f $parts[0], $parts[1], $parts[2], $accessLabel)
}

Write-Host ""
Write-Host "Pick a server (use the arrow keys, then Enter):"
$selectedIndex = Select-Menu -Options $labels
$vm = $vms[$selectedIndex]
Write-Host ""
Write-Host "Selected: $($vm.Name) ($($vm.Zone)) -- currently $($vm.Status)"

if (-not (Test-Access $vm.Name)) {
    Write-Host "ERROR: you don't have access to '$($vm.Name)' (no permission on its credentials)." -ForegroundColor Red
    Write-Host "Ask whoever manages the project to grant you access, or pick a different server."
    exit 1
}

# ---------------------------------------------------------------------------
# Step 4 - start it if it's off
# ---------------------------------------------------------------------------
if ($vm.Status -ne "RUNNING") {
    $reply = Read-Host "This server is switched off. Start it now? [y/N]"
    if ($reply -notmatch '^[Yy]') {
        Write-Host "Can't open a tunnel to a server that isn't running. Exiting." -ForegroundColor Red
        exit 1
    }
    # $(...) around every property access below is load-bearing: "--zone=$vm.Zone"
    # (no subexpression) stringifies the whole $vm object and appends ".Zone"
    # as literal text afterward -- PowerShell only does plain $variable
    # expansion, not member access, inside a token that mixes literal text
    # with a variable reference. Confirmed the hard way: it produced
    # --zone=@{Name=dicom-gateway; Zone=us-east5-a; Status=TERMINATED}.Zone
    gcloud compute instances start $($vm.Name) --zone=$($vm.Zone) --project=$ProjectId

    Write-Host ""

    # One minute is a reasonable estimate for a stopped Windows VM to
    # finish booting -- used only to drive the progress bar's
    # percentage. The loop itself keeps polling the VM's actual status
    # past that estimate if it hasn't even reached RUNNING yet (that's
    # the GCE-level power-on event, not "Windows is ready") -- otherwise
    # it'd be easy to walk straight into a doomed tunnel attempt against
    # a VM that isn't even up yet.
    $estSeconds = 60
    $pollInterval = 10
    $barWidth = 30
    $elapsed = 0
    Write-Host "Waiting for $($vm.Name) to come up..."
    while ($true) {
        $currentStatus = gcloud compute instances describe $($vm.Name) --zone=$($vm.Zone) --project=$ProjectId --format="value(status)" 2>$null
        if (-not $currentStatus) { $currentStatus = "UNKNOWN" }

        if ($currentStatus -eq "RUNNING" -and $elapsed -ge $estSeconds) {
            $pct = 100
        } else {
            $pct = [math]::Floor($elapsed * 100 / $estSeconds)
            if ($pct -gt 99) { $pct = 99 }
        }

        $filled = [math]::Floor($pct * $barWidth / 100)
        $bar = ("#" * $filled) + ("-" * ($barWidth - $filled))
        Write-Host -NoNewline ("`r  [{0}] {1,3}%  status: {2,-12}" -f $bar, $pct, $currentStatus)

        if ($currentStatus -eq "RUNNING" -and $elapsed -ge $estSeconds) {
            Write-Host ""
            break
        }

        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }
    Write-Host "  Done."
}

# ---------------------------------------------------------------------------
# Step 5 - fetch this VM's credentials (access was already confirmed
# right after picking it, above -- this is the real fetch, not a second
# access check, though it's kept guarded the same way in case access
# was revoked in between)
# ---------------------------------------------------------------------------
$secretId = "$($vm.Name)-support-login"
Write-Host ""
Write-Host "Fetching this server's credentials ($secretId)..."

try {
    $secretJson = gcloud secrets versions access latest --secret=$secretId --project=$ProjectId 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $secretJson) { throw "access denied" }
} catch {
    Write-Host "ERROR: you don't have permission to view the credentials for '$($vm.Name)'." -ForegroundColor Red
    Write-Host "Ask whoever manages the project to grant you access, or pick a different server."
    exit 1
}
Write-Host "Credentials retrieved."

# The secret's value is JSON: {"username":"support","password":"..."}.
# ConvertFrom-Json is a real, spec-compliant JSON parser -- first choice
# whenever the secret parses cleanly (correctly handles \uXXXX escapes
# like &, same as any standard parser would). Only falls back to a
# tolerant manual extraction if the secret itself is malformed (seen at
# least once on this project -- a stray invalid backslash that also
# means the VM's own boot script, which parses this the same strict
# way, likely failed to actually set that password).
$vmUsername = $null
$vmPassword = $null
try {
    $creds = $secretJson | ConvertFrom-Json
    $vmUsername = $creds.username
    $vmPassword = $creds.password
} catch {
    Write-Host ""
    Write-Host "NOTE: this secret isn't valid JSON (likely a stray backslash in the" -ForegroundColor Yellow
    Write-Host "password) -- the VM's own boot script parses it the same strict way" -ForegroundColor Yellow
    Write-Host "and may have failed to actually set this password. Extracting the raw" -ForegroundColor Yellow
    Write-Host "value anyway; if login fails, that's the likely reason." -ForegroundColor Yellow
    Write-Host ""
    if ($secretJson -match '"username"\s*:\s*"((?:[^"\\]|\\.)*)"') { $vmUsername = $matches[1] }
    if ($secretJson -match '"password"\s*:\s*"((?:[^"\\]|\\.)*)"') { $vmPassword = $matches[1] }
}

if (-not $vmUsername -or -not $vmPassword) {
    Write-Host "ERROR: couldn't find username/password fields in the secret value for '$($vm.Name)'." -ForegroundColor Red
    Write-Host "Check the raw value in the Secret Manager Console ($secretId) -- it may be malformed."
    exit 1
}

# ---------------------------------------------------------------------------
# Step 6 - pick a free local port, start the tunnel, copy the password
# ---------------------------------------------------------------------------
function Test-PortFree([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect("127.0.0.1", $Port)
        $client.Close()
        return $false  # something answered -> port is taken
    } catch {
        return $true
    }
}

$localPort = 13389
while (-not (Test-PortFree -Port $localPort)) {
    $localPort++
}

Write-Host ""
Write-Host "Opening the tunnel to $($vm.Name)..."
# The SDK's bin folder ships both gcloud.cmd and gcloud.ps1. Plain
# "gcloud ..." calls elsewhere in this script work fine regardless of
# which one that resolves to, because PowerShell runs a resolved .ps1
# directly as a script -- no file association involved. Start-Process
# launches an external OS process instead, via Windows' own file
# association, and that association for .ps1 is "open in a text
# editor," not "execute" (a deliberate Windows default, to stop .ps1
# files running just by being opened) -- so if Get-Command happens to
# hand back the .ps1 path here, Start-Process opens it in Notepad
# instead of running it. Ask for "gcloud.cmd" specifically, by name, to
# sidestep the ambiguity entirely rather than depend on which one a
# bare "gcloud" resolves to.
$gcloudCmd = Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue
if (-not $gcloudCmd) {
    Write-Host "ERROR: found 'gcloud' but not 'gcloud.cmd' specifically -- can't safely launch the tunnel as a background process." -ForegroundColor Red
    exit 1
}
$gcloudPath = $gcloudCmd.Source
$TunnelProcess = Start-Process -FilePath $gcloudPath -ArgumentList @(
    "compute", "start-iap-tunnel", $vm.Name, $RdpPort,
    "--local-host-port=localhost:$localPort",
    "--zone=$($vm.Zone)",
    "--project=$ProjectId"
) -PassThru -WindowStyle Hidden

Write-Host "Waiting for it to come up..."
$tunnelUp = $false
for ($i = 0; $i -lt 30; $i++) {
    if ($TunnelProcess.HasExited) {
        Write-Host "ERROR: the tunnel process exited early." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-PortFree -Port $localPort)) {
        $tunnelUp = $true
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $tunnelUp) {
    Write-Host "ERROR: tunnel didn't come up within 30 seconds." -ForegroundColor Red
    exit 1
}

# mstsc.exe (Windows' built-in Remote Desktop client) opens straight
# from a .rdp file with the server address and username pre-filled --
# no custom URI scheme needed here, unlike the Mac side. Only the
# password still needs pasting: there's no field for it in a plain .rdp
# file, and putting it there in plaintext isn't something to do even if
# there were.
$TempRdpFile = Join-Path $env:TEMP "hailth-$($vm.Name).rdp"
@"
full address:s:localhost:$localPort
username:s:$vmUsername
"@ | Set-Content -Path $TempRdpFile -Encoding ASCII

Set-Clipboard -Value $vmPassword
$vmPassword = $null

Write-Host ""
Write-Host "================================================================"
Write-Host " Connecting to: $($vm.Name)"
Write-Host "================================================================"
try {
    Start-Process -FilePath "mstsc.exe" -ArgumentList $TempRdpFile
    Write-Host ""
    Write-Host " Remote Desktop should be opening now."
    Write-Host " Password: copied to your clipboard -- just paste it"
    Write-Host ""
    Write-Host " Command used: mstsc.exe `"$TempRdpFile`""
} catch {
    Write-Host ""
    Write-Host " Couldn't launch mstsc.exe automatically -- do it manually:"
    Write-Host "   1. Open Remote Desktop Connection"
    Write-Host "   2. Computer:  localhost:$localPort"
    Write-Host "   3. Username:  $vmUsername"
    Write-Host "   4. Password:  copied to your clipboard -- just paste it"
}

Write-Host ""
Write-Host " Leave THIS window open while you're connected -- press Ctrl+C"
Write-Host " here, or just close the window, when you're done to disconnect."
Write-Host "================================================================"
Write-Host ""

Wait-Process -Id $TunnelProcess.Id

} finally {
    Cleanup
}
