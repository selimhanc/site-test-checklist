$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$base = 'http://185.23.72.228'
$start = "$base/tr"
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$handler.MaxAutomaticRedirections = 10
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36')

$visited = @{}          # url -> status
$queue = New-Object System.Collections.Queue
$queue.Enqueue($start)
$maxPages = 300
$depth = 0

function Normalize-Url([string]$u, [string]$pageUrl) {
    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    $u = $u.Trim()
    if ($u -match '^(mailto:|tel:|javascript:|data:|#)') { return $null }
    $u = $u -split '#', 2 | Select-Object -First 1
    try {
        $uri = [Uri]::new($u)
        if (-not $uri.IsAbsoluteUri) {
            $baseUri = [Uri]::new($pageUrl)
            $uri = [Uri]::new($baseUri, $u)
        }
        if ($uri.Host -ne '185.23.72.228' -and $uri.Host -ne 'localhost' -and $uri.Host -notmatch '^(www\.)?185\.23\.72\.228$') { return $null }
        $uri = [Uri]::new($uri.Scheme + '://' + $uri.Host + $uri.AbsolutePath)
        return $uri.AbsoluteUri
    } catch { return $null }
}

$regex = [regex]'href\s*=\s*["'']([^"'']+)["'']'
$assetRegex = [regex]'(?:src|href)\s*=\s*["'']([^"'']+\.(?:css|js|png|jpg|jpeg|webp|svg|gif|ico|woff2?))["'']'

$pages = @{}   # url -> html (kept minimal)
$report = [System.Collections.ArrayList]::new()

while ($queue.Count -gt 0 -and $visited.Count -lt $maxPages) {
    $url = $queue.Dequeue()
    if ($visited.ContainsKey($url)) { continue }
    $visited[$url] = 'pending'
    try {
        $resp = $client.GetAsync($url).Result
        $code = [int]$resp.StatusCode
        $finalUrl = $resp.RequestMessage.RequestUri.AbsoluteUri
        if ($code -ge 400) {
            [void]$report.Add([pscustomobject]@{ kind='page'; url=$url; status=$code; title=''; note='HTTP hatası'; finalUrl=$finalUrl })
            $visited[$url] = $code
            continue
        }
        $ct = $resp.Content.Headers.ContentType
        $isHtml = $ct -and $ct.MediaType -match 'html'
        if ($isHtml) {
            $html = $resp.Content.ReadAsStringAsync().Result
            $title = ''
            $m = [regex]::Match($html, '<title[^>]*>(.*?)</title>', [Text.RegularExpressions.RegexOptions]::Singleline)
            if ($m.Success) { $title = $m.Groups[1].Value.Trim() }
            $pages[$url] = @{ html=$html; status=$code; title=$title }
            [void]$report.Add([pscustomobject]@{ kind='page'; url=$url; status=$code; title=$title; note=''; finalUrl=$finalUrl })
            foreach ($m2 in $regex.Matches($html)) {
                $nu = Normalize-Url $m2.Groups[1].Value $url
                if ($nu -and -not $visited.ContainsKey($nu) -and -not ($queue.ToArray() -contains $nu)) {
                    $queue.Enqueue($nu)
                }
            }
        } else {
            [void]$report.Add([pscustomobject]@{ kind='asset'; url=$url; status=$code; title=''; note=$ct.MediaType; finalUrl=$finalUrl })
            $visited[$url] = $code
        }
    } catch {
        [void]$report.Add([pscustomobject]@{ kind='page'; url=$url; status=0; title=''; note=$_.Exception.Message; finalUrl='' })
        $visited[$url] = 'error'
    }
}

# Check assets referenced from each page
$assets = @{}
foreach ($kv in $pages.GetEnumerator()) {
    $html = $kv.Value.html
    foreach ($m3 in $assetRegex.Matches($html)) {
        $au = Normalize-Url $m3.Groups[1].Value $kv.Key
        if ($au -and -not $assets.ContainsKey($au)) {
            $assets[$au] = $true
            try {
                $r = $client.GetAsync($au).Result
                [void]$report.Add([pscustomobject]@{ kind='asset'; url=$au; status=[int]$r.StatusCode; title=''; note=if($r.Content.Headers.ContentType){$r.Content.Headers.ContentType.MediaType}else{''}; finalUrl=$r.RequestMessage.RequestUri.AbsoluteUri })
            } catch {
                [void]$report.Add([pscustomobject]@{ kind='asset'; url=$au; status=0; title=''; note='ERROR'; finalUrl='' })
            }
        }
    }
}

$report | Sort-Object url | Export-Csv -Path "$PSScriptRoot\crawl_report.csv" -NoTypeInformation -Encoding UTF8
Write-Output "PAGES_FOUND=$($pages.Count)"
Write-Output "TOTAL_URLS=$($report.Count)"
Write-Output "--- pages ---"
$pages.GetEnumerator() | Sort-Object Key | ForEach-Object { Write-Output ("{0} | {1} | {2}" -f $_.Value.status, $_.Value.title, $_.Key) }
