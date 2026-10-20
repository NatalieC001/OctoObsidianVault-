# watch-new-notes.ps1
# Memory & Processing Friendly: Uses 0% CPU and 0% GPU while waiting.
# Wakes up only when you create or save a note in "00-Drop-Notes-Here" and runs process-notes-now.ps1.

$VaultPath = "C:\Users\natal\Documents\OpenOctoFun"
$InboxFolder = Join-Path $VaultPath "00-Drop-Notes-Here"
$ProcessorScript = Join-Path $VaultPath "octo-config\process-notes-now.ps1"

if (-not (Test-Path $InboxFolder)) {
    New-Item -ItemType Directory -Path $InboxFolder -Force | Out-Null
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Watching for new notes in: $InboxFolder" -ForegroundColor Green
Write-Host " Processing used while waiting: 0% CPU / 0% GPU" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Cyan

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $InboxFolder
$watcher.Filter = "*.md"
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true

$action = {
    $filePath = $Event.SourceEventArgs.FullPath
    $fileName = $Event.SourceEventArgs.Name
    Start-Sleep -Seconds 2
    if (-not (Test-Path $filePath)) { return }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] New note saved: $fileName" -ForegroundColor Yellow
    & "C:\Users\natal\Documents\OpenOctoFun\octo-config\process-notes-now.ps1" -InputNotePath $filePath
}

Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Changed" -Action $action | Out-Null

while ($true) {
    Start-Sleep -Seconds 5
}
