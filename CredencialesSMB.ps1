$StorageAccount = "safiletestsmb"
$SmbHost        = "$StorageAccount.file.core.windows.net"
$StorageKey     = "kKjxf7BkK267f4yY6Il7qrN5kAvjhOwe3fHmUMrpRs2QmrI96YuHUyxtwmWekxM6knyz9Gf5hxzL+AStfWNCRA==" 

cmd.exe /C "cmdkey /add:`"$StorageAccount.file.core.windows.net`" /user:`"Azure\$StorageAccount`" /pass:`"$StorageKey`""

# --- Verificar ---
cmdkey /list | findstr /i $SmbHost

# --- Prueba de acceso ---
# dir "\\$SmbHost\$ShareName"
