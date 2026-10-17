$ErrorActionPreference = 'SilentlyContinue'
"=== a4a3 PnP nodes (NCM trial-7) ==="
Get-PnpDevice | Where-Object { $_.InstanceId -like '*PID_A4A3*' } | ForEach-Object {
    "--- $($_.InstanceId)  [Class=$($_.Class) Status=$($_.Status) FriendlyName=$($_.FriendlyName)]"
    $_ | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus','DEVPKEY_Device_Service','DEVPKEY_Device_DriverDesc','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_ConfigFlags' |
        ForEach-Object { "    {0} = {1}" -f $_.KeyName, ($_.Data -join ',') }
}
"=== Net adapters (incl. hidden) ==="
Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'NCM|CDC|RNDIS|changxing60' -or $_.Status -ne 'Disabled' } |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex, MacAddress | Format-Table -AutoSize | Out-String -Width 200
"=== 192.168.77.x IPv4 assigned? ==="
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.77.*' } | Select-Object IPAddress, InterfaceAlias, PrefixOrigin | Format-Table -AutoSize | Out-String -Width 200
"=== Kernel-PnP events last 10 min ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 200 |
    Where-Object { $_.TimeCreated -ge (Get-Date).AddMinutes(-10) } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Format-Table -AutoSize | Out-String -Width 250
"=== Direct reachability from Windows ==="
Test-NetConnection 192.168.77.1 -Port 80 -WarningAction SilentlyContinue | Select-Object ComputerName, RemoteAddress, PingSucceeded, TcpTestSucceeded | Format-List | Out-String
curl.exe -s -m 3 http://192.168.77.1/ 2>&1
