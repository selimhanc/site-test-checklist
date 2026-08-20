$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($true)
$csv = Import-Csv -LiteralPath "$PSScriptRoot\crawl_report.csv" -Encoding UTF8

$okPages = @($csv | Where-Object { $_.kind -eq 'page' -and $_.status -eq '200' })
$brokenPages = @($csv | Where-Object { $_.kind -eq 'page' -and ($_.status -eq '0' -or [int]$_.status -ge 400) })
$brokenAssets = @($csv | Where-Object { $_.kind -eq 'asset' -and ($_.status -eq '0' -or [int]$_.status -ge 400) })

function New-Item([string]$t, [string]$u, [string]$s, [string]$n) {
    return @{ id = [guid]::NewGuid().ToString('N').Substring(0,10); t = $t; u = $u; s = $s; n = $n }
}

function New-Cat([string]$id, [string]$name, [array]$items) {
    return @{ id = $id; name = $name; items = $items }
}

$categories = [System.Collections.ArrayList]::new()

# Ana sayfalar
$homeItems = @()
foreach ($locale in @('tr','en','ar','de')) {
    $p = $okPages | Where-Object { $_.url -eq "http://185.23.72.228/$locale" } | Select-Object -First 1
    if ($p) { $homeItems += New-Item $p.title $p.url 'pass' 'HTTP 200' }
}
[void]$categories.Add((New-Cat 'home' 'Ana Sayfa (tüm diller)' $homeItems))

# Dil bazlı sayfalar
foreach ($locale in @('tr','en','ar','de')) {
    $items = @()
    foreach ($p in $okPages | Where-Object { $_.url -match "^http://185\.23\.72\.228/$locale/" } | Sort-Object url) {
        $items += New-Item $p.title $p.url 'pass' 'HTTP 200'
    }
    if ($items.Count -gt 0) { [void]$categories.Add((New-Cat "pages-$locale" "@$($locale) - Sayfalar" $items)) }
}

# Kırık linkler: dil değiştirici deseni (çift locale: /tr/tr, /en/tr/bagis vb.)
$localeRe = '(tr|en|ar|de)'
$doubleLocale = @($brokenPages | Where-Object { $_.url -match "^http://185\.23\.72\.228/$localeRe/($localeRe)(/|$)" })
if ($doubleLocale.Count -gt 0) {
    $items = @($doubleLocale | Sort-Object url | ForEach-Object { New-Item $_.url $_.url 'fail' 'HTTP 404 - dil değiştirici linki hatalı URL üretiyor (çift dil kodu)' })
    [void]$categories.Add((New-Cat 'broken-locale' 'Kırık Linkler - Dil Değiştirici (404)' $items))
}

# Diğer kırık linkler
$otherBroken = @($brokenPages | Where-Object { $_ -notin $doubleLocale })
if ($otherBroken.Count -gt 0) {
    $items = @($otherBroken | Sort-Object url | ForEach-Object {
        $note = if ($_.status -eq '0') { 'Bağlantı hatası: ' + $_.note } else { 'HTTP ' + $_.status }
        New-Item $_.url $_.url 'fail' $note
    })
    [void]$categories.Add((New-Cat 'broken-other' 'Kırık Linkler - Diğer (404)' $items))
}

# Eksik assetler
if ($brokenAssets.Count -gt 0) {
    $items = @($brokenAssets | Sort-Object url | ForEach-Object { New-Item $_.url $_.url 'fail' 'HTTP 404 - görsel dosyası sunucuda yok (medya galerisi placeholders?)' })
    [void]$categories.Add((New-Cat 'assets' 'Eksik / Bozuk Assetler (404)' $items))
}

$data = @{ generated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); base = 'http://185.23.72.228'; categories = $categories.ToArray() }
$json = ConvertTo-Json $data -Depth 6 -Compress

$template = Get-Content -LiteralPath "$PSScriptRoot\checklist_template.html" -Raw -Encoding UTF8
$out = $template.Replace('__DEFAULT_DATA__', $json)
[System.IO.File]::WriteAllText("$PSScriptRoot\checklist.html", $out, $utf8)
Write-Output "categories=$($categories.Count) items=$($okPages.Count + $brokenPages.Count + $brokenAssets.Count) -> checklist.html"
