$ErrorActionPreference = 'SilentlyContinue'
"=== PnP properties of a4a2 nodes ==="
Get-PnpDevice | Where-Object { $_.InstanceId -like '*PID_A4A2*' } | ForEach-Object {
    "--- $($_.InstanceId)  [Class=$($_.Class) Status=$($_.Status)]"
    $_ | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus','DEVPKEY_Device_Service','DEVPKEY_Device_DriverDesc','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_DriverVersion','DEVPKEY_Device_ConfigFlags' |
        ForEach-Object { "    {0} = {1}" -f $_.KeyName, ($_.Data -join ',') }
}
"=== Kernel-PnP configuration log 05:17-05:25 ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 400 |
    Where-Object { $_.TimeCreated -ge (Get-Date '2026-09-18 05:17') -and $_.TimeCreated -le (Get-Date '2026-09-18 05:25') } |
    Select-Object TimeCreated, Id, @{n='Msg';e={($_.Message -split '\r?\n')[0]}} |
    Format-Table -AutoSize | Out-String -Width 250
"=== DriverStore RNDIS/NCM packages ==="
Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Filter 'rndis*' | Select-Object -ExpandProperty Name
Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Filter '*ncm*' | Select-Object -ExpandProperty Name
Get-ChildItem C:\Windows\INF -Filter 'rndis*' | Select-Object -ExpandProperty Name
"=== usbser for reference (ACM bound fine) ==="
Get-PnpDevice | Where-Object { $_.InstanceId -like '*PID_A4A2*MI_02*' } | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_Service' | ForEach-Object { "Service=$($_.Data)" }
