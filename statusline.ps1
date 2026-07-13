param()
$raw  = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $data) { exit 0 }
$now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# === Color Palette (Claude Gradient) ===
$ESC      = [char]0x1b
$C_RESET  = "$ESC[0m"
$C_PURPLE = "$ESC[38;2;167;139;250m"   # model name
$C_GREEN  = "$ESC[38;2;130;180;100m"   # healthy (<60%)
$C_AMBER  = "$ESC[38;2;229;192;123m"   # warning (>=60%) / Opus !
$C_RED    = "$ESC[38;2;224;108;117m"   # critical (>=80%) / Fable !!
$C_DIM    = "$ESC[38;2;92;99;112m"     # labels

function Get-ColorForPct($pct) {
    if ($pct -ge 80) { return $C_RED }
    elseif ($pct -ge 60) { return $C_AMBER }
    else { return $C_GREEN }
}

function Get-ResetHM($ts) {
    $diff = $ts - $now
    if ($diff -le 0) { return "soon" }
    return [DateTimeOffset]::FromUnixTimeSeconds($ts).LocalDateTime.ToString("HH:mm")
}

function Get-ResetDH($ts) {
    $diff = $ts - $now
    if ($diff -le 0) { return "soon" }
    $d = [Math]::Floor($diff / 86400)
    $h = [Math]::Floor(($diff % 86400) / 3600)
    $m = [Math]::Floor(($diff % 3600) / 60)
    if ($d -gt 0) { return "${d}d${h}h" }
    return "${h}h${m}m"
}

# Model info
$modelId      = $data.model.id
$modelDisplay = $data.model.display_name
$effort       = $data.effort.level

# Rate limits
$h5_pct   = if ($null -ne $data.rate_limits.five_hour.used_percentage)  { [int]$data.rate_limits.five_hour.used_percentage }  else { $null }
$h5_reset = $data.rate_limits.five_hour.resets_at
$d7_pct   = if ($null -ne $data.rate_limits.seven_day.used_percentage)  { [int]$data.rate_limits.seven_day.used_percentage }  else { $null }
$d7_reset = $data.rate_limits.seven_day.resets_at
$ctx_pct  = if ($null -ne $data.context_window.used_percentage) { [int]$data.context_window.used_percentage } else { $null }
$cwd      = $data.cwd

# === Gauge fallback cache (Claude Code omits context_window/rate_limits briefly after a mid-session model switch) ===
$gaugeCache = Join-Path $HOME '.claude/statusline_gauges.cache'
$gaugeTtl = 20
if (Test-Path $gaugeCache) {
    $parts = (Get-Content $gaugeCache -Raw).Trim().Split('|')
    if ($parts.Count -eq 7) {
        $gCwd, $gCtx, $gH5, $gH5r, $gD7, $gD7r, $gTs = $parts
        if ($gCwd -eq $cwd -and $cwd -and -not [string]::IsNullOrWhiteSpace($gTs)) {
            $tsVal = 0L
            if ([long]::TryParse($gTs, [ref]$tsVal) -and ($now - $tsVal) -lt $gaugeTtl) {
                if (-not $ctx_pct -and -not [string]::IsNullOrWhiteSpace($gCtx)) { $ctx_pct = [int]$gCtx }
                if (-not $h5_pct -and -not [string]::IsNullOrWhiteSpace($gH5)) {
                    $h5_pct = [int]$gH5
                    $h5_reset = if (-not [string]::IsNullOrWhiteSpace($gH5r)) { [long]$gH5r } else { 0L }
                }
                if (-not $d7_pct -and -not [string]::IsNullOrWhiteSpace($gD7)) {
                    $d7_pct = [int]$gD7
                    $d7_reset = if (-not [string]::IsNullOrWhiteSpace($gD7r)) { [long]$gD7r } else { 0L }
                }
            }
        }
    }
}
if ($cwd -and ($ctx_pct -or $h5_pct -or $d7_pct)) {
    "$cwd|$ctx_pct|$h5_pct|$h5_reset|$d7_pct|$d7_reset|$now" | Set-Content $gaugeCache
}

# Max subscribers: rate_limits is absent from the API response entirely (upstream bug).
# Show "-" placeholders instead of silently dropping the fields.
$hasRl        = $null -ne $data.rate_limits
$costUsd      = $data.cost.total_cost_usd

# Determine subscriber status:
# cost.total_cost_usd is no longer always 0 for subscription plans (Pro/Max).
# We classify as subscriber if hasRl is true OR if hasRl is false but none of the 4 billed env vars are present.
$isSubscriber = $hasRl -or (
    [string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_BEDROCK) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_VERTEX) -and
    [string]::IsNullOrEmpty($env:CLAUDE_CODE_USE_FOUNDRY)
)

$isMaxNoRl    = (-not $hasRl) -and $modelDisplay -and $isSubscriber

# Model prefix
$out = ""
if ($modelDisplay) {
    $modelShort = $modelDisplay -replace ' ', ''
    $modelStr   = if ($effort) { "${modelShort}(${effort})" } else { $modelShort }
    if ($modelId -cmatch 'opus') {
        $out = "${C_AMBER}!${modelStr}${C_RESET}"
    } elseif ($modelId -cmatch 'fable') {
        $out = "${C_RED}!!${modelStr}${C_RESET}"
    } else {
        $out = "${C_PURPLE}${modelStr}${C_RESET}"
    }
}

if ($null -ne $h5_pct) {
    $rst = Get-ResetHM $h5_reset
    $c   = Get-ColorForPct $h5_pct
    if ($out) { $out += " " }
    $out += "${C_DIM}Session:${C_RESET}${c}${h5_pct}%${C_DIM}(${rst})${C_RESET}"
} elseif ($isMaxNoRl) {
    if ($out) { $out += " " }
    $out += "${C_DIM}Session:-${C_RESET}"
}
if ($null -ne $d7_pct) {
    $rst = Get-ResetDH $d7_reset
    $c   = Get-ColorForPct $d7_pct
    if ($out) { $out += " " }
    $out += "${C_DIM}Week:${C_RESET}${c}${d7_pct}%${C_DIM}(${rst})${C_RESET}"
} elseif ($isMaxNoRl) {
    if ($out) { $out += " " }
    $out += "${C_DIM}Week:-${C_RESET}"
}
if ($null -ne $ctx_pct) {
    $filled     = [Math]::Max(0, [Math]::Min([Math]::Floor($ctx_pct / 20), 5))
    $filledBar  = "▰" * $filled
    $emptyBar   = "▱" * (5 - $filled)
    $c          = Get-ColorForPct $ctx_pct
    if ($out) { $out += " " }
    $out += "${C_DIM}Ctx:${C_RESET}${c}${filledBar}${C_DIM}${emptyBar}${C_RESET}${c}${ctx_pct}%${C_RESET}"
}

# JPY rate cache (weekly refresh via ECB/frankfurter.dev)
$jpyCachePath = Join-Path $HOME '.claude/jpy_rate.cache'
$jpyRate = $null
if (Test-Path $jpyCachePath) {
    $content = Get-Content $jpyCachePath -Raw
    if ($null -ne $content) {
        $parts = $content.Trim() -split ":", 2
        $cachTs = $parts[0] -as [long]
        if ($parts.Count -eq 2 -and $null -ne $cachTs -and ($now - $cachTs) -lt 604800) {
            $jpyRate = $parts[1] -as [double]
        }
    }
}
if ($null -eq $jpyRate) {
    $jpyLockPath = Join-Path $HOME '.claude/jpy_rate.lock'
    $lockAge = 999999
    if (Test-Path $jpyLockPath) {
        try {
            $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $jpyLockPath).LastWriteTimeUtc).TotalSeconds
        } catch {}
    }
    if ($lockAge -gt 30) {
        try { New-Item -Path $jpyLockPath -ItemType File -Force > $null } catch {}
        Start-Job -ScriptBlock {
            param($cachePath, $lockPath, $nowSec)
            try {
                $resp = Invoke-RestMethod -Uri "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY" -TimeoutSec 5
                $rate = $resp.rates.JPY
                if ($null -ne $rate) {
                    "${nowSec}:${rate}" | Set-Content "${cachePath}.tmp"
                    Move-Item -Force "${cachePath}.tmp" $cachePath
                }
            } catch {} finally {
                Remove-Item -Force $lockPath -ErrorAction SilentlyContinue
            }
        } -ArgumentList $jpyCachePath, $jpyLockPath, $now > $null
    }
}

function Get-CostEstimate($path) {
    $priceTable = @{
        'claude-opus-4-8'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-opus-4-7'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-opus-4-6'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-opus-4-5'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-opus-4-1'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-opus-4-0'   = @{ In = 5.00;  Out = 25.00; CWrite = 6.25;  CRead = 0.50 }
        'claude-sonnet-5'   = @{ In = 3.00;  Out = 15.00; CWrite = 3.75;  CRead = 0.30 }
        'claude-sonnet-4-6' = @{ In = 3.00;  Out = 15.00; CWrite = 3.75;  CRead = 0.30 }
        'claude-sonnet-4-5' = @{ In = 3.00;  Out = 15.00; CWrite = 3.75;  CRead = 0.30 }
        'claude-sonnet-4-0' = @{ In = 3.00;  Out = 15.00; CWrite = 3.75;  CRead = 0.30 }
        'claude-haiku-4-5'  = @{ In = 1.00;  Out = 5.00;  CWrite = 1.25;  CRead = 0.10 }
        'claude-fable-5'    = @{ In = 10.00; Out = 50.00; CWrite = 12.50; CRead = 1.00 }
        'claude-mythos-5'   = @{ In = 10.00; Out = 50.00; CWrite = 12.50; CRead = 1.00 }
    }
    $defaultKey = 'claude-sonnet-5'
    $total = 0.0
    $lines = $null
    try { $lines = Get-Content -LiteralPath $path -ErrorAction Stop } catch { return $null }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $entry -or $entry.type -ne 'assistant') { continue }
        $usage = $entry.message.usage
        if ($null -eq $usage) { continue }
        $model = $entry.message.model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $defaultKey }
        $model = $model -replace '^anthropic\.', ''
        $model = $model -replace '@.*$', ''
        $model = $model -replace '-\d{8}$', ''
        $rate = $priceTable[$model]
        if ($null -eq $rate) { $rate = $priceTable[$defaultKey] }
        $inTok  = if ($null -ne $usage.input_tokens) { [double]$usage.input_tokens } else { 0.0 }
        $outTok = if ($null -ne $usage.output_tokens) { [double]$usage.output_tokens } else { 0.0 }
        $cwTok  = if ($null -ne $usage.cache_creation_input_tokens) { [double]$usage.cache_creation_input_tokens } else { 0.0 }
        $crTok  = if ($null -ne $usage.cache_read_input_tokens) { [double]$usage.cache_read_input_tokens } else { 0.0 }
        $total += ($inTok * $rate.In + $outTok * $rate.Out + $cwTok * $rate.CWrite + $crTok * $rate.CRead) / 1000000
    }
    return $total
}

# transcript_path fallback: some Claude Code versions/auth paths omit transcript_path
# from the statusLine hook JSON. Locate the most recently modified transcript in the
# project-specific directory (derived from cwd, same convention Claude Code itself uses)
# as a best-effort substitute.
$transcriptPath = $data.transcript_path
if ([string]::IsNullOrWhiteSpace($transcriptPath) -and -not [string]::IsNullOrWhiteSpace($cwd)) {
    $projDir = Join-Path $HOME (".claude/projects/" + ($cwd -replace '/', '-'))
    if (Test-Path -LiteralPath $projDir) {
        $latest = Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latest) { $transcriptPath = $latest.FullName }
    }
}

# === Fallback cost estimate (Claude Code omits cost.total_cost_usd for Azure/Bedrock/Vertex-routed sessions) ===
$costIsEstimate = $false
if ($null -eq $costUsd -and -not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
    $estCachePath = Join-Path $HOME '.claude/cost_estimate.cache'
    $tMtime = [long]((Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds

    $cachedPath = $null; $cachedMtime = $null; $cachedVal = $null
    if (Test-Path $estCachePath) {
        $c = Get-Content $estCachePath -Raw
        if ($null -ne $c) {
            $parts = $c.Trim() -split '\|', 3
            if ($parts.Count -eq 3) { $cachedPath, $cachedMtime, $cachedVal = $parts }
        }
    }

    if ($cachedPath -eq $transcriptPath -and $cachedMtime -eq "$tMtime" -and -not [string]::IsNullOrWhiteSpace($cachedVal)) {
        $estVal = $cachedVal -as [double]
    } else {
        $estVal = Get-CostEstimate $transcriptPath
        if ($null -ne $estVal) {
            "$transcriptPath|$tMtime|$estVal" | Set-Content "${estCachePath}.tmp"
            Move-Item -Force "${estCachePath}.tmp" $estCachePath
        }
    }
    if ($null -eq $estVal) { $estVal = 0 }
    $costUsd = $estVal
    $costIsEstimate = $true
}

# Daily cost tracking (¥500/day — ¥10,000/month ÷ 20 business days)
# NOTE: jpyRate is best-effort (fetched over the network); the $ cost must still
# display even when the JPY conversion is unavailable (offline, blocked host, etc.)
if ($null -ne $costUsd) {
    $budgetCachePath = Join-Path $HOME '.claude/cost_budget.cache'
    $curDate         = (Get-Date).ToString("yyyy-MM-dd")
    $cumulativeUsd   = 0.0
    $lastSessionUsd  = 0.0

    if (Test-Path $budgetCachePath) {
        $budgetContent = Get-Content $budgetCachePath -Raw
        if ($null -ne $budgetContent) {
            $parts = $budgetContent.Trim() -split ":", 3
            if ($parts.Count -eq 3 -and $parts[0] -eq $curDate) {
                $cu = $parts[1] -as [double]; if ($null -ne $cu) { $cumulativeUsd  = $cu }
                $ls = $parts[2] -as [double]; if ($null -ne $ls) { $lastSessionUsd = $ls }
            }
        }
    }

    if ($costUsd -lt $lastSessionUsd) { $cumulativeUsd += $lastSessionUsd }
    "${curDate}:${cumulativeUsd}:${costUsd}" | Set-Content "${budgetCachePath}.tmp"
    Move-Item -Force "${budgetCachePath}.tmp" $budgetCachePath

    $totalUsd  = $cumulativeUsd + $costUsd
    $costFmt   = "{0:F2}" -f $totalUsd
    $estPrefix = if ($costIsEstimate -or $isSubscriber) { "~" } else { "" }

    if ($null -ne $jpyRate) {
        $totalJpy   = [int]($totalUsd * $jpyRate)
        $sessionJpy = [int]($costUsd  * $jpyRate)

        if ($totalJpy -gt 0) {
            $totalJpyFmt   = "{0:N0}" -f $totalJpy
            $sessionJpyFmt = "{0:N0}" -f $sessionJpy
            if ($isSubscriber) {
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}~`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${C_GREEN}~¥${totalJpyFmt}${C_DIM})${C_RESET}"
            } else {
                $budgetJpy  = 500
                $pct        = [Math]::Min([int]($totalJpy * 100 / $budgetJpy), 100)
                $filled     = [Math]::Floor($pct / 20)
                $c          = Get-ColorForPct $pct
                $filledBar  = "▰" * $filled
                $emptyBar   = "▱" * (5 - $filled)
                $warn       = if ($pct -ge 100) { "!!" } else { "" }
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${c}${warn}${filledBar}${C_DIM}${emptyBar}${C_RESET}${c}${estPrefix}`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥${sessionJpyFmt}${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥${totalJpyFmt}${C_DIM}/¥500)${C_RESET}"
            }
        }
    } elseif ($totalUsd -gt 0) {
        # JPY rate not yet cached (offline / blocked) — show plain $ amount, no bar/budget
        if ($out) { $out += " " }
        $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}${estPrefix}`$${costFmt}${C_RESET}"
    }
}

[Console]::Write($out)
