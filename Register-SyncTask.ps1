$Action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\azureuser\Desktop\script sincronizacion.ps1" -Source "C:\Windows\Temp" -Destination "\\safiletestsmb.file.core.windows.net\test" -Mode Copy -Exclude "*.tmp,*.bak" -LogPath "C:\Logs\sync-app.log"'

$Trigger = New-ScheduledTaskTrigger -Daily -At 03:00

$Principal = New-ScheduledTaskPrincipal `
  -UserId "SYSTEM" `
  -RunLevel Highest `
  -LogonType ServiceAccount

Register-ScheduledTask `
  -TaskName "SyncToSmbApp" `
  -Action $Action `
  -Trigger $Trigger `
  -Principal $Principal `
  -Description "Sincronización App hacia SMB usando robocopy"