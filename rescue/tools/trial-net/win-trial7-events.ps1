$ErrorActionPreference = 'SilentlyContinue'
$t0 = Get-Date '2026-09-18 05:42:30'; $t1 = Get-Date '2026-09-18 05:49:00'
"=== System log: Dhcp/TCPIP/NDIS/usbncm/NetworkProfile $t0-$t1 ==="
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$t0; EndTime=$t1} -MaxEvents 500 |
    Where-Object { $_.ProviderName -match 'Dhcp|TCPIP|NDIS|Ncm|NetworkProfile|netvsc|usb' } |
    Select-Object TimeCreated, Id, ProviderName, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated | Format-Table -AutoSize | Out-String -Width 250
"=== Microsoft-Windows-Dhcp-Client/Admin ==="
Get-WinEvent -LogName 'Microsoft-Windows-Dhcp-Client/Admin' -MaxEvents 100 |
    Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated | Format-Table -AutoSize | Out-String -Width 250
"=== Microsoft-Windows-NetworkProfile/Operational ==="
Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents 100 |
    Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated | Format-Table -AutoSize | Out-String -Width 250
"=== Microsoft-Windows-NetworkConnectivity/Operational (NCSI) ==="
Get-WinEvent -LogName 'Microsoft-Windows-NetworkConnectivity/Operational' -MaxEvents 200 |
    Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated | Format-Table -AutoSize | Out-String -Width 250
"=== Kernel-PnP full window ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 300 |
    Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated | Format-Table -AutoSize | Out-String -Width 250
