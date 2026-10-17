$ErrorActionPreference = 'SilentlyContinue'
function TS { (Get-Date).ToString('HH:mm:ss') }
Write-Output "$(TS) watcher start: looking for UsbNcm adapter (trial-8 window ~300s after boot)"
$deadline = (Get-Date).AddSeconds(480)
$firstSeen = $null; $staticSet = $false; $tested = $false
$lastState = ''
while ((Get-Date) -lt $deadline) {
    $ad = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'UsbNcm|NCM Host' } | Select-Object -First 1
    if ($ad) {
        if (-not $firstSeen) {
            $firstSeen = Get-Date
            Write-Output "$(TS) ADAPTER FOUND: Name='$($ad.Name)' Desc='$($ad.InterfaceDescription)' Status=$($ad.Status) ifIndex=$($ad.ifIndex) LinkSpeed=$($ad.LinkSpeed) Mac=$($ad.MacAddress)"
        }
        $ips = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4
        $good = @($ips | Where-Object { $_.IPAddress -like '192.168.77.*' })
        $state = ($ips | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength):$($_.PrefixOrigin)" }) -join ','
        if ($state -ne $lastState) {
            Write-Output "$(TS) STATE status=$($ad.Status) ipv4=[$state]"
            $lastState = $state
        }
        # 15s DHCP grace, then pin a static IP (bypasses any DHCP failure)
        if (-not $staticSet -and $good.Count -eq 0 -and ((Get-Date) - $firstSeen).TotalSeconds -gt 15) {
            Write-Output "$(TS) no 192.168.77.x after 15s — setting STATIC 192.168.77.9/24 on ifIndex $($ad.ifIndex)"
            Set-NetIPInterface -InterfaceIndex $ad.ifIndex -Dhcp Disabled
            New-NetIPAddress -InterfaceIndex $ad.ifIndex -IPAddress 192.168.77.9 -PrefixLength 24 | Out-Null
            $staticSet = $true
            Start-Sleep -Seconds 2
        }
        if (-not $tested -and ($good.Count -gt 0 -or $staticSet)) {
            $tested = $true
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ok = $tcp.ConnectAsync('192.168.77.1', 80).Wait(4000)
            $tcp.Close()
            Write-Output "$(TS) TCP 192.168.77.1:80 connect ok=$ok"
            $body = & curl.exe -s -m 4 http://192.168.77.1/ 2>&1
            Write-Output "$(TS) CURL BODY: $body"
            $ping = Test-Connection 192.168.77.1 -Count 2 -Quiet
            Write-Output "$(TS) PING ok=$ping"
            if ($ok) { Write-Output "$(TS) HTTPD REACHABLE FROM WINDOWS"; break }
            $tested = $false   # keep retesting until success or deadline
        }
    }
    Start-Sleep -Seconds 3
}
Write-Output "$(TS) watcher end (adapter=$(if($firstSeen){'seen'}else{'NEVER SEEN'}) static=$staticSet)"
