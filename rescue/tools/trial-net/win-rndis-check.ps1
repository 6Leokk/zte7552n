$ErrorActionPreference = 'SilentlyContinue'
$ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date '2026-09-18 05:17'); EndTime=(Get-Date '2026-09-18 05:25')}
$ev | Where-Object { $_.ProviderName -match 'Dhcp|NDIS|Kernel-PnP|rndis|Tcpip|usb' } |
    Select-Object TimeCreated, Id, ProviderName, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Sort-Object TimeCreated |
    Format-Table -AutoSize | Out-String -Width 250
"=== RNDIS adapter registry remnants ==="
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}' |
    ForEach-Object { $p = Get-ItemProperty $_.PSPath; if ($p.DriverDesc -match 'RNDIS') { "{0}: {1} | NetCfgInstanceId={2}" -f $_.PSChildName, $p.DriverDesc, $p.NetCfgInstanceId } }
"=== NetCfg instances (all, incl. hidden) ==="
Get-NetAdapter -IncludeHidden | Select-Object Name, InterfaceDescription, Status, ifIndex | Format-Table -AutoSize | Out-String -Width 200
