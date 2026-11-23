# vps2vpn against real Reality, Hysteria2 and TUIC servers (sing-box on
# loopback): each line carries traffic, and the smart line puts them in the
# order the subscription chose, Reality first when it lists Reality first.
param([Parameter(Mandatory)][string]$Setup, [Parameter(Mandatory)][string]$Tools, [string]$Out = 'harsh')
. (Join-Path $PSScriptRoot 'lib.ps1')
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Tools = (Resolve-Path $Tools).Path
$secret = "ci-$(Get-Random)"
$smart = [char]0x26A1 + ' ' + [string]::new([char[]](0x667A, 0x80FD, 0x7EBF, 0x8DEF))

function Get-Smart($port) {
  $name = [uri]::EscapeDataString($smart)
  try { Invoke-RestMethod "http://127.0.0.1:9090/proxies/$name" -Headers @{ Authorization = "Bearer $secret" } -TimeoutSec 5 } catch { $null }
}
function Use-Subscription($name, $order) {
  Stop-App
  Remove-Item $script:appHome -Recurse -Force -ErrorAction SilentlyContinue
  $lines = @{ R = $script:reality; H = $script:hy2; T = $script:tuic }
  Write-Subscription $name @"
mixed-port: 7890
mode: rule
proxies:
$(($order | ForEach-Object { "  - $($lines[$_])" }) -join "`n")
proxy-groups:
  - {name: Proxy, type: select, proxies: [auto, $($order -join ', ')]}
  - {name: auto, type: fallback, url: 'https://www.gstatic.com/generate_204', interval: 300, proxies: [$($order -join ', ')]}
rules:
  - DOMAIN,cp.cloudflare.com,R
  - DOMAIN,www.msftconnecttest.com,H
  - DOMAIN,connectivitycheck.gstatic.com,T
  - MATCH,Proxy
"@
  $ok = Import-FirstRun "http://127.0.0.1:$($script:subPort)/$name"
  Check $ok "$name`: imported" | Out-Host
  Set-AppPrefs @{ autoRun = $true; takeover = $false; acceptedDisclaimerVersion = 1; smartLines = $true }
  Set-Mode $false $true
  Edit-AppConfig {
    param($c)
    $c.patchClashConfig | Add-Member -Force 'external-controller' '127.0.0.1:9090'
    $c.patchClashConfig | Add-Member -Force secret $secret
  }
  Start-App $name 90
}
function Test-Line($port, $tag, $url, $expect, $what) {
  $before = (Select-String $script:serverLog -Pattern "\[$tag\]" -ErrorAction SilentlyContinue).Count
  $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 25 -x "http://127.0.0.1:$port" $url
  $seen = Wait-Until 5 { (Select-String $script:serverLog -Pattern "\[$tag\]" -ErrorAction SilentlyContinue).Count -gt $before }
  Check ($code -eq $expect -and $seen) "$what`: $url answers $code through the $tag server"
}

try {
  Start-Upstream $Out
  $root = Join-Path $script:work 'sing-box-server'
  Expand-Archive (Join-Path $Tools 'sing-box.zip') $root -Force
  $sb = (Get-ChildItem $root -Recurse -Filter 'sing-box.exe' | Select-Object -First 1).FullName
  $uuid = (& $sb generate uuid).Trim()
  $password = (& $sb generate rand 16 --hex).Trim()
  $keys = & $sb generate reality-keypair
  $private = (($keys | Select-String 'PrivateKey') -split ':\s*')[1].Trim()
  $public = (($keys | Select-String 'PublicKey') -split ':\s*')[1].Trim()
  $pem = (& $sb generate tls-keypair ci.test) -join "`n"
  $key = Join-Path $root 'key.pem'; $cert = Join-Path $root 'cert.pem'
  [regex]::Match($pem, '-----BEGIN PRIVATE KEY-----[\s\S]+?-----END PRIVATE KEY-----').Value | Set-Content $key -Encoding ascii
  [regex]::Match($pem, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----').Value | Set-Content $cert -Encoding ascii
  $script:serverLog = Join-Path $Out 'sing-box-server.log'
  $config = Join-Path $root 'server.json'
  @{
    log = @{ level = 'info'; output = $script:serverLog; timestamp = $true }
    inbounds = @(
      @{ type = 'vless'; tag = 'reality-in'; listen = '127.0.0.1'; listen_port = 24431; users = @(@{ uuid = $uuid; flow = 'xtls-rprx-vision' })
         tls = @{ enabled = $true; server_name = 'www.microsoft.com'; reality = @{ enabled = $true; handshake = @{ server = 'www.microsoft.com'; server_port = 443 }; private_key = $private; short_id = @('0123abcd') } } },
      @{ type = 'hysteria2'; tag = 'hy2-in'; listen = '127.0.0.1'; listen_port = 24432; users = @(@{ password = $password })
         tls = @{ enabled = $true; alpn = @('h3'); certificate_path = $cert; key_path = $key } },
      @{ type = 'tuic'; tag = 'tuic-in'; listen = '127.0.0.1'; listen_port = 24433; users = @(@{ uuid = $uuid; password = $password }); congestion_control = 'bbr'
         tls = @{ enabled = $true; alpn = @('h3'); certificate_path = $cert; key_path = $key } }
    )
    outbounds = @(@{ type = 'direct'; tag = 'direct' })
  } | ConvertTo-Json -Depth 10 | Set-Content $config -Encoding utf8
  & $sb check -c $config
  Check ($LASTEXITCODE -eq 0) 'the sing-box server config is valid'
  $server = Start-Tracked $sb @('run', '-c', $config)
  Check (Wait-Until 20 { Get-Listener 24431 }) 'the Reality server listens'

  $script:reality = "{name: R, type: vless, server: 127.0.0.1, port: 24431, uuid: $uuid, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: www.microsoft.com, client-fingerprint: chrome, reality-opts: {public-key: $public, short-id: 0123abcd}}"
  $script:hy2 = "{name: H, type: hysteria2, server: 127.0.0.1, port: 24432, password: $password, sni: ci.test, skip-cert-verify: true, alpn: [h3]}"
  $script:tuic = "{name: T, type: tuic, server: 127.0.0.1, port: 24433, uuid: $uuid, password: $password, sni: ci.test, skip-cert-verify: true, alpn: [h3], congestion-controller: bbr}"
  Install-App $Setup $Out

  foreach ($case in @(
      @{ name = 'tcp-first.yaml'; order = @('R', 'H', 'T'); first = 'R'; label = 'tcp_first on (Reality listed first)' },
      @{ name = 'quic-first.yaml'; order = @('H', 'T', 'R'); first = 'H'; label = 'tcp_first off (QUIC listed first)' })) {
    $port = Use-Subscription $case.name $case.order
    Test-Line $port 'reality-in' 'http://cp.cloudflare.com/generate_204' '204' "$($case.label), Reality"
    Test-Line $port 'hy2-in' 'http://www.msftconnecttest.com/connecttest.txt' '200' "$($case.label), Hysteria2"
    Test-Line $port 'tuic-in' 'http://connectivitycheck.gstatic.com/generate_204' '204' "$($case.label), TUIC"
    Wait-Until 60 { $script:g = Get-Smart $port; $script:g -and $script:g.all } | Out-Null
    $group = $script:g
    if ($group) {
      "smart line ($($case.label)): $($group.all -join ' > '), now $($group.now)"
      Check ($group.all[0] -eq $case.first) "$($case.label): the smart line tries $($case.first) first ($($group.all -join ' > '))"
      Wait-Until 60 { $script:g = Get-Smart $port; $script:g.now } | Out-Null
      Check ($script:g.now -eq $case.first) "$($case.label): the smart line is on $($case.first) (now $($script:g.now))"
    } else { Check $false "$($case.label): the smart line group is there" }
    Test-AppAlive $case.label
  }
  Stop-App
  Uninstall-App
  Test-NothingLeft 'after uninstall'
} finally {
  Finish
}
