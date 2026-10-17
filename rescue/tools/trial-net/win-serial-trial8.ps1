function TS { (Get-Date).ToString('HH:mm:ss') }
$ErrorActionPreference = 'SilentlyContinue'
Write-Output "$(TS) serial: waiting for VID_0525&PID_A4A3 MI_02 COM port..."
$portName = $null
$deadline = (Get-Date).AddSeconds(420)
while ((Get-Date) -lt $deadline -and -not $portName) {
    $dev = Get-PnpDevice -Class Ports | Where-Object { $_.InstanceId -like 'USB\VID_0525&PID_A4A3*MI_02*' -and $_.Status -eq 'OK' } | Select-Object -First 1
    if ($dev) {
        $portName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters" -Name PortName).PortName
    }
    if (-not $portName) { Start-Sleep -Seconds 2 }
}
if (-not $portName) { Write-Output "$(TS) serial: NO COM PORT FOUND"; exit 1 }
Write-Output "$(TS) serial: opening $portName @115200"
$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort $portName,115200,'None',8,'One'
$sp.NewLine = "`n"; $sp.ReadTimeout = 500; $sp.WriteTimeout = 2000
$sp.Open()
$sp.DtrEnable = $true; $sp.RtsEnable = $true
function SendRecv([string]$cmd, [double]$wait = 1.2) {
    $sp.DiscardInBuffer()
    if ($cmd -ne '') { $sp.Write("$cmd`n") }
    Start-Sleep -Seconds $wait
    $out = $sp.ReadExisting()
    Write-Output "---- $(TS) > '$cmd'"
    Write-Output ($out -replace "`r", '')
}
SendRecv '' 0.8
SendRecv 'echo SERIAL-ALIVE' 1.0
SendRecv 'touch /run/stay; echo STAY-OK' 1.0
SendRecv 'ifconfig usb0' 1.0
SendRecv 'grep usb0 /proc/net/dev' 0.8
SendRecv 'cat /run/udhcpd.leases; echo LEASES-END' 0.8
SendRecv 'cat /proc/net/arp; echo ARP-END' 0.8
SendRecv 'netstat -rn' 0.8
SendRecv 'dmesg | tail -25' 1.5
Write-Output "$(TS) serial session done — /run/stay pinned, device stays in Linux; reboot -f via telnet/serial when finished"
$sp.Close()
