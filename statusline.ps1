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

# Max subscribers: rate_limits is absent from the API response entirely (upstream bug).
# Show "-" placeholders instead of silently dropping the fields.
$hasRl        = $null -ne $data.rate_limits
$costUsdForRl = if ($null -ne $data.cost.total_cost_usd) { $data.cost.total_cost_usd } else { 0 }
$isMaxNoRl    = (-not $hasRl) -and $modelDisplay -and ($costUsdForRl -eq 0)

# Model prefix
$out = ""
if ($modelDisplay) {
    $modelShort = $modelDisplay -replace ' ', ''
    $modelStr   = if ($effort) { "${modelShort}(${effort})" } else { $modelShort }
    if ($modelId -match 'opus') {
        $out = "${C_AMBER}!${modelStr}${C_RESET}"
    } elseif ($modelId -match 'fable') {
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

# JPY rate cache (weekly refresh via ECB/frankfurter.app)
$jpyCachePath = "$HOME\.claude\jpy_rate.cache"
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
    try {
        $resp    = Invoke-RestMethod -Uri "https://api.frankfurter.app/latest?from=USD&to=JPY"
        $jpyRate = $resp.rates.JPY
        if ($null -ne $jpyRate) {
            "${now}:${jpyRate}" | Set-Content "${jpyCachePath}.tmp"
            Move-Item -Force "${jpyCachePath}.tmp" $jpyCachePath
        }
    } catch {}
}

# Daily cost tracking (¥500/day — ¥10,000/month ÷ 20 business days)
$costUsd = $data.cost.total_cost_usd
if ($null -ne $costUsd -and $null -ne $jpyRate) {
    $budgetCachePath = "$HOME\.claude\cost_budget.cache"
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

    $totalUsd   = $cumulativeUsd + $costUsd
    $totalJpy   = [int]($totalUsd * $jpyRate)
    $sessionJpy = [int]($costUsd  * $jpyRate)

    if ($totalJpy -gt 0) {
        $budgetJpy  = 500
        $pct        = [Math]::Min([int]($totalJpy * 100 / $budgetJpy), 100)
        $filled     = [Math]::Floor($pct / 20)
        $c          = Get-ColorForPct $pct
        $filledBar  = "▰" * $filled
        $emptyBar   = "▱" * (5 - $filled)
        $warn       = if ($pct -ge 100) { "!!" } else { "" }
        $costFmt    = "{0:F2}" -f $totalUsd
        if ($out) { $out += " " }
        $out += "${C_DIM}Cost:${C_RESET}${c}${warn}${filledBar}${C_DIM}${emptyBar}${C_RESET}${c}`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥${sessionJpy}${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥${totalJpy}${C_DIM}/¥500)${C_RESET}"
    }
}

[Console]::Write($out)
