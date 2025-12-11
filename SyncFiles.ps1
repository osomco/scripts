<#
.SYNOPSIS
  Sincroniza/copias archivos desde un repositorio local hacia un share SMB usando robocopy.
  No maneja credenciales ni programación; solo operación de copia.

.PARAMETER Source
  Carpeta origen local (p.ej. C:\Data)

.PARAMETER Destination
  Share SMB destino (p.ej. \\StorageAccount.file.core.windows.net\Share\Carpeta)

.PARAMETER Mode
  Tipo de copia: Copy (incremental) | Mirror (reflejo /MIR). Por defecto: Copy

.PARAMETER Exclude
  Patrones a excluir (ej. *.tmp,*.bak). Separar por coma.

.PARAMETER LogPath
  Ruta del log (p.ej. C:\Logs\sync-smb.log). Por defecto: C:\Logs\Sync-ToSmb.log

.NOTES
  - Requiere que la identidad que ejecuta el script tenga acceso al share (AD/cmdkey/sesión de servicio).
  - Probado en Windows Server 2019/2022 y Windows 10/11.
#>

param(
  [Parameter(Mandatory=$true)][string]$Source,
  [Parameter(Mandatory=$true)][string]$Destination,
  [ValidateSet('Copy','Mirror')][string]$Mode = 'Copy',
  [string]$Exclude = '',
  [string]$LogPath = 'C:\Logs\Sync-ToSmb.log'
)

function Ensure-Directory { param([string]$Path)
    if (-not (Test-Path -Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}
function Write-Info { param([string]$Msg) Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Msg" -ForegroundColor Cyan }
function Write-Err  { param([string]$Msg) Write-Error $Msg }

# --- Validaciones básicas ---
if (-not (Test-Path -Path $Source)) { Write-Err "El origen no existe: $Source"; exit 1 }
if ($Destination -notmatch '^\\\\') { Write-Err "El destino debe ser una ruta UNC SMB (\\Servidor\Share\Carpeta). Valor: $Destination"; exit 1 }
Ensure-Directory (Split-Path -Path $LogPath -Parent)

# --- Chequeo de accesibilidad al share completo ---
try {
    Write-Info "Validando acceso al share: $Destination"
    Get-ChildItem -Path $Destination -ErrorAction Stop | Out-Null
} catch {
    Write-Err "No se pudo acceder al share ($Destination). Verifica conectividad, credenciales y SMB (TCP 445)."; exit 1
}

# --- Flags de robocopy ---
$flags = @('/R:3','/W:5','/MT:16','/FFT','/Z','/NP','/TEE')
if ($Mode -eq 'Mirror') { $flags += '/MIR' } else { $flags += '/E' }

# --- Exclusiones por patrón ---
if ($Exclude) {
    foreach ($pat in ($Exclude.Split(',') | ForEach-Object { $_.Trim() })) {
        if ($pat) { $flags += "/XF"; $flags += $pat }
    }
}

# --- Log ---
$flags += "/LOG:$LogPath"

# --- Ejecutar ---
Write-Info "Iniciando sincronización ($Mode)"
$cmd = @('robocopy', $Source, $Destination) + $flags
Write-Info ("Comando: " + ($cmd -join ' '))
$proc = Start-Process -FilePath $cmd[0] -ArgumentList ($cmd[1..($cmd.Length-1)]) -Wait -PassThru
$exitCode = $proc.ExitCode

if ($exitCode -le 7) {
    Write-Info "Sincronización finalizada correctamente. ExitCode=$exitCode. Log: $LogPath"
} else {
    Write-Err "Robocopy devolvió ExitCode=$exitCode (Error). Revisa el log: $LogPath"
    exit $exitCode
}