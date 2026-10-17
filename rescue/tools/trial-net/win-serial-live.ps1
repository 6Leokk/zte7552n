function TS { (Get-Date).ToString('HH:mm:ss') }
$ErrorActionPreference = 'Stop'
$portName = $null
$dev = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_0525&PID_A4A3*MI_02*' -and $_.Status -eq 'OK' } | Select-Object -First 1
if ($dev) { $portName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters" -Name PortName -ErrorAction SilentlyContinue).PortName }
if (-not $portName) { Write-Output "$(TS) serial-live: NO COM PORT (device rolled back?)"; exit 1 }
Write-Output "$(TS) serial-live: opening $portName"
$sp = New-Object System.IO.Ports.SerialPort $portName,115200,'None',8,'One'
$sp.NewLine = "`n"; $sp.ReadTimeout = 500; $sp.WriteTimeout = 2000
$sp.Open(); $sp.DtrEnable = $true; $sp.RtsEnable = $true
function SendRecv([string]$cmd, [double]$wait = 1.5) {
    $sp.DiscardInBuffer()
    if ($cmd -ne '') { $sp.Write("$cmd`n") }
    Start-Sleep -Seconds $wait
    Write-Output "---- $(TS) > '$cmd'"
    Write-Output ($sp.ReadExisting() -replace "`r", '')
}
SendRecv '' 0.8
SendRecv 'echo LIVE-ALIVE; ls /run/stay 2>&1' 1.0
SendRecv 'ps | grep -E "httpd|telnetd|udhcpd" | grep -v grep; echo PS-END' 1.5
SendRecv 'netstat -tln; echo TCP-LISTEN-END' 1.5
SendRecv 'netstat -uln; echo UDP-LISTEN-END' 1.5
SendRecv 'cat /proc/net/tcp; echo PROCTCP-END' 1.0
SendRecv 'ls -la /run/www/ /etc/udhcpd.conf 2>&1; echo LS-END' 1.0
SendRecv 'httpd -v -p 192.168.77.1:80 -h /run/www 2>&1; echo HTTPD-RC=$?' 1.5
SendRecv 'telnetd -b 192.168.77.1 -p 23 -l /bin/sh 2>&1; echo TELNETD-RC=$?' 1.5
SendRecv 'netstat -tln; echo TCP-LISTEN2-END' 1.5
SendRecv 'wget -qO- http://192.168.77.1/ 2>&1; echo WGET-RC=$?' 2.0
SendRecv 'grep usb0 /proc/net/dev; echo DEV-END' 1.0
Write-Output "$(TS) serial-live done"
$sp.Close()
