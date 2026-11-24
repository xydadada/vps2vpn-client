# vps2vpn carrying traffic for a long while: memory and handles must level
# off. Then in TUN mode, where DNS goes and what IPv6 does.
param([Parameter(Mandatory)][string]$Setup, [string]$Out = 'harsh', [int]$Minutes = 25)
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

function Sample {
  foreach ($p in Get-Process vps2vpn, vps2vpnCore -ErrorAction SilentlyContinue) {
    [pscustomobject]@{
      t = [int]((Get-Date) - $script:t0).TotalSeconds; name = $p.Name
      privateMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1); handles = $p.HandleCount; threads = $p.Threads.Count
    }
  }
}
function Mean($rows, $name, $field) {
  $v = @($rows | Where-Object name -eq $name | ForEach-Object $field)
  if ($v.Count) { ($v | Measure-Object -Average).Average } else { 0 }
}

try {
  Start-Upstream $Out
  Install-App $Setup $Out
  Check (Import-FirstRun) 'subscription imported on first run'
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1 }
  Set-Mode $false $true
  $port = Start-App 'soak'
  Test-Through $port 'soak start'

  $script:t0 = Get-Date
  $end = $script:t0.AddMinutes($Minutes)
  $samples = [System.Collections.Generic.List[object]]::new()
  $requests = 0; $failed = 0; $next = Get-Date
  while ((Get-Date) -lt $end) {
    $jobs = 1..4 | ForEach-Object { Start-Job { param($port, $url) & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -x "http://127.0.0.1:$port" $url } -ArgumentList $port, $script:probeUrl }
    foreach ($code in ($jobs | Wait-Job | Receive-Job)) { $requests++; if ($code -ne '204') { $failed++ } }
    $jobs | Remove-Job
    if ((Get-Date) -ge $next) { Sample | ForEach-Object { $samples.Add($_) }; $next = (Get-Date).AddSeconds(30) }
    Start-Sleep 2
  }
  $samples | Export-Csv (Join-Path $Out 'soak.csv') -NoTypeInformation
  "requests: $requests, failed: $failed"
  Check ($requests -gt 0 -and $failed / [math]::Max(1, $requests) -lt 0.02) "soak: $failed of $requests requests failed"
  Test-AppAlive 'soak end'
  $span = ($samples | Measure-Object t -Maximum).Maximum
  $early = @($samples | Where-Object { $_.t -ge 120 -and $_.t -lt 120 + $span / 4 })
  $late = @($samples | Where-Object { $_.t -ge $span * 3 / 4 })
  foreach ($name in 'vps2vpn', 'vps2vpnCore') {
    $m0 = Mean $early $name privateMB; $m1 = Mean $late $name privateMB
    $h0 = Mean $early $name handles; $h1 = Mean $late $name handles
    "$name private memory $([math]::Round($m0)) -> $([math]::Round($m1)) MB, handles $([math]::Round($h0)) -> $([math]::Round($h1))"
    Check ($m1 -le $m0 * 1.5 + 40) "soak: $name memory levels off ($([math]::Round($m0)) -> $([math]::Round($m1)) MB)"
    Check ($h1 -le $h0 * 1.3 + 100) "soak: $name handles level off ($([math]::Round($h0)) -> $([math]::Round($h1)))"
  }

  # TUN: names resolved by Windows go to vps2vpn, not to the network's DNS server.
  Stop-App
  Set-Mode $true $false
  Start-Process $script:exe | Out-Null
  $tun = Wait-Until 120 { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun|Meta|vps2vpn' } }
  Check $tun 'tun: the adapter is up'
  $nic = Get-LanAdapter
  $lanDns = @((Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses)
  "network DNS servers: $($lanDns -join ', ')"
  & pktmon filter remove | Out-Null
  foreach ($ip in $lanDns) { & pktmon filter add "dns-$ip" -i $ip -p 53 | Out-Null }
  & pktmon start --capture --comp nics --file-name (Join-Path $Out 'dns.etl') | Out-Null
  $names = 1..20 | ForEach-Object { "ci-leak-$(Get-Random)-$_.example.com" }
  foreach ($n in $names) { Resolve-DnsName $n -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue | Out-Null }
  foreach ($n in 'www.gstatic.com', 'www.microsoft.com') { $a = Resolve-DnsName $n -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'A' | Select-Object -First 1; "tun: $n resolves to $($a.IPAddress)" }
  & pktmon stop | Out-Null
  & pktmon format (Join-Path $Out 'dns.etl') -o (Join-Path $Out 'dns.txt') | Out-Null
  $pattern = ($lanDns | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $leaks = @(if ($pattern) { Select-String (Join-Path $Out 'dns.txt') -Pattern $pattern -ErrorAction SilentlyContinue })
  Check ($leaks.Count -le 2) "tun: lookups did not go to the network's own DNS server ($($leaks.Count) packets for 20 names)"
  & pktmon filter remove | Out-Null

  $v6 = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceAlias) metric $($_.RouteMetric)" })
  Note "tun: IPv6 default routes: $(if ($v6) { $v6 -join '; ' } else { 'none' })"
  $code6 = & curl.exe -6 -s -o NUL -w '%{http_code}' --max-time 10 --noproxy '*' 'https://ipv6.google.com/generate_204'
  Note "tun: an IPv6-only request answers '$code6' (the runner has no IPv6 of its own)"
  Test-AppAlive 'tun'
  Stop-App
  Uninstall-App
  Test-NothingLeft 'after uninstall'
} finally {
  & pktmon stop 2>$null | Out-Null
  Finish
}
