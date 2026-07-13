param(
    [string]$ComputeCostFor,
    [switch]$FetchJpyRate
)

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Shared cache paths
$jpyCachePath    = Join-Path $HOME '.claude/jpy_rate.cache'
$jpyLockPath     = Join-Path $HOME '.claude/jpy_rate.lock'
$jpyFailPath     = Join-Path $HOME '.claude/jpy_rate.fail'
$estCachePath    = Join-Path $HOME '.claude/cost_estimate.cache'
$gaugeCachePath  = Join-Path $HOME '.claude/statusline_gauges.cache'
$budgetCachePath = Join-Path $HOME '.claude/cost_budget.cache'

# Deterministic per-path lock suffix (string GetHashCode is randomized per process on
# PowerShell 7 / .NET Core, so hash with MD5 instead)
function Get-PathLockSuffix($s) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hex = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$s)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
        return $hex.Substring(0, 8)
    } finally { $md5.Dispose() }
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
    # ReadLines streams the file — constant memory even on huge transcripts
    try { $lines = [System.IO.File]::ReadLines($path) } catch { return $null }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $entry -or $entry.type -ne 'assistant') { continue }
        $usage = $entry.message.usage
        if ($null -eq $usage) { continue }
        $model = $entry.message.model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $defaultKey }
        # us.anthropic.claude-*-20250929-v1:0 (Bedrock cross-region), anthropic.claude-*,
        # claude-*@20250929 (Vertex), claude-*-20250929 (API) all normalize to the bare id
        $model = $model -replace '^[a-z]+\.anthropic\.', ''
        $model = $model -replace '^anthropic\.', ''
        $model = $model -replace '@.*$', ''
        $model = $model -replace '-v\d+:\d+$', ''
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

# === Background worker: cost estimate ===
# Start-Job children die with the parent statusline process, so heavy work is
# re-invoked as a detached process (see Start-DetachedWorker below).
if ($ComputeCostFor) {
    $lockPath = Join-Path $HOME ('.claude/cost_estimate.' + (Get-PathLockSuffix $ComputeCostFor) + '.lock')
    try {
        if (Test-Path -LiteralPath $ComputeCostFor) {
            $tm = [long]((Get-Item -LiteralPath $ComputeCostFor).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds
            $val = Get-CostEstimate $ComputeCostFor
            if ($null -ne $val) {
                $keep = @()
                if (Test-Path $estCachePath) {
                    $keep = @(Get-Content $estCachePath -ErrorAction SilentlyContinue |
                        Where-Object { $_ -and ($_ -split '\|', 2)[0] -ne $ComputeCostFor } |
                        Select-Object -Last 7)
                }
                $keep += "$ComputeCostFor|$tm|$val"
                $tmp = "${estCachePath}.tmp.$PID"
                Set-Content -Path $tmp -Value $keep
                Move-Item -Force $tmp $estCachePath
            }
        }
    } finally {
        Remove-Item -Force $lockPath -ErrorAction SilentlyContinue
    }
    exit 0
}

# === Background worker: JPY rate fetch ===
if ($FetchJpyRate) {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY" -TimeoutSec 5
        $rate = $resp.rates.JPY
        if ($null -ne $rate) {
            $tmp = "${jpyCachePath}.tmp.$PID"
            "${now}:${rate}" | Set-Content $tmp
            Move-Item -Force $tmp $jpyCachePath
            Remove-Item -Force $jpyFailPath -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $jpyFailPath -ItemType File -Force > $null
        }
    } catch {
        try { New-Item -Path $jpyFailPath -ItemType File -Force > $null } catch {}
    } finally {
        Remove-Item -Force $jpyLockPath -ErrorAction SilentlyContinue
    }
    exit 0
}

# === Render path ===
$raw  = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $data) { exit 0 }

function Start-DetachedWorker([string[]]$workerArgs) {
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch {}
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')) + $workerArgs
    try { Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden > $null } catch {}
}

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

# 5-segment gauge; emits "filled + C_DIM + empty" (caller wraps with its own color/reset)
function New-Bar($pct) {
    $filled = [Math]::Max(0, [Math]::Min([Math]::Floor($pct / 20), 5))
    return ("▰" * $filled) + $C_DIM + ("▱" * (5 - $filled))
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
$sessionId    = $data.session_id

# Rate limits (0 is a valid value — always compare against $null, never truthiness)
$h5_pct   = if ($null -ne $data.rate_limits.five_hour.used_percentage)  { [int]$data.rate_limits.five_hour.used_percentage }  else { $null }
$h5_reset = $data.rate_limits.five_hour.resets_at
$d7_pct   = if ($null -ne $data.rate_limits.seven_day.used_percentage)  { [int]$data.rate_limits.seven_day.used_percentage }  else { $null }
$d7_reset = $data.rate_limits.seven_day.resets_at
$ctx_pct  = if ($null -ne $data.context_window.used_percentage) { [int]$data.context_window.used_percentage } else { $null }
$cwd      = $data.cwd

# === Gauge fallback cache (Claude Code omits context_window/rate_limits briefly after a mid-session model switch) ===
# Multi-line, keyed by session_id (cwd fallback) so concurrent sessions in the same
# directory never pick up each other's gauges.
$gaugeTtl = 20
$gaugeKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId }
            elseif (-not [string]::IsNullOrWhiteSpace($cwd)) { $cwd }
            else { $null }
$gCtx = ''; $gH5 = ''; $gH5r = ''; $gD7 = ''; $gD7r = ''; $gTs = ''
$gaugeLines = @()
if ($gaugeKey -and (Test-Path $gaugeCachePath)) {
    $gaugeLines = @(Get-Content $gaugeCachePath -ErrorAction SilentlyContinue | Where-Object { $_ })
    $own = $gaugeLines | Where-Object { ($_ -split '\|')[0] -eq $gaugeKey } | Select-Object -First 1
    if ($own) {
        $parts = $own -split '\|'
        if ($parts.Count -eq 7) {
            $gCtx = $parts[1]; $gH5 = $parts[2]; $gH5r = $parts[3]
            $gD7 = $parts[4]; $gD7r = $parts[5]; $gTs = $parts[6]
            $tsVal = 0L
            if ([long]::TryParse($gTs, [ref]$tsVal) -and ($now - $tsVal) -lt $gaugeTtl) {
                if ($null -eq $ctx_pct -and -not [string]::IsNullOrWhiteSpace($gCtx)) { $ctx_pct = [int]$gCtx }
                if ($null -eq $h5_pct -and -not [string]::IsNullOrWhiteSpace($gH5)) {
                    $h5_pct = [int]$gH5
                    $h5_reset = if (-not [string]::IsNullOrWhiteSpace($gH5r)) { [long]$gH5r } else { 0L }
                }
                if ($null -eq $d7_pct -and -not [string]::IsNullOrWhiteSpace($gD7)) {
                    $d7_pct = [int]$gD7
                    $d7_reset = if (-not [string]::IsNullOrWhiteSpace($gD7r)) { [long]$gD7r } else { 0L }
                }
            }
        }
    }
}
if ($gaugeKey -and ($null -ne $ctx_pct -or $null -ne $h5_pct -or $null -ne $d7_pct)) {
    $h5rOut = if ($null -ne $h5_reset -and "$h5_reset") { $h5_reset } else { 0 }
    $d7rOut = if ($null -ne $d7_reset -and "$d7_reset") { $d7_reset } else { 0 }
    # skip the disk write while values are unchanged and the entry is still fresh
    $tsVal2 = 0L
    $entryFresh = [long]::TryParse("$gTs", [ref]$tsVal2) -and (($now - $tsVal2) -lt [Math]::Floor($gaugeTtl / 2))
    $unchanged  = ("$gCtx" -eq "$ctx_pct" -and "$gH5" -eq "$h5_pct" -and "$gH5r" -eq "$h5rOut" -and
                   "$gD7" -eq "$d7_pct" -and "$gD7r" -eq "$d7rOut")
    if (-not ($unchanged -and $entryFresh)) {
        $keep = @($gaugeLines | Where-Object {
            $p = $_ -split '\|'
            $t = 0L
            ($p.Count -eq 7) -and ($p[0] -ne $gaugeKey) -and [long]::TryParse($p[6], [ref]$t) -and (($now - $t) -lt 3600)
        })
        $tmp = "${gaugeCachePath}.tmp.$PID"
        Set-Content -Path $tmp -Value ($keep + "$gaugeKey|$ctx_pct|$h5_pct|$h5rOut|$d7_pct|$d7rOut|$now")
        Move-Item -Force $tmp $gaugeCachePath
    }
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
    $c = Get-ColorForPct $ctx_pct
    if ($out) { $out += " " }
    $out += "${C_DIM}Ctx:${C_RESET}${c}$(New-Bar $ctx_pct)${C_RESET}${c}${ctx_pct}%${C_RESET}"
}

# === JPY rate (weekly cache, background refresh via ECB/frankfurter.dev; CC_STATUSLINE_JPY=0 disables) ===
$jpyRate = $null
if ($env:CC_STATUSLINE_JPY -ne '0') {
    $jpyFresh = $false
    if (Test-Path $jpyCachePath) {
        $content = Get-Content $jpyCachePath -Raw
        if ($null -ne $content) {
            $parts = $content.Trim() -split ":", 2
            if ($parts.Count -eq 2) {
                $r = $parts[1] -as [double]
                if ($null -ne $r) {
                    $jpyRate = $r   # a stale rate still beats no rate; refreshed below
                    $cachTs = $parts[0] -as [long]
                    if ($null -ne $cachTs -and ($now - $cachTs) -lt 604800) { $jpyFresh = $true }
                }
            }
        }
    }
    if (-not $jpyFresh) {
        $failAge = 999999
        $lockAge = 999999
        if (Test-Path $jpyFailPath) {
            try { $failAge = ([DateTimeOffset]::UtcNow - (Get-Item $jpyFailPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        if (Test-Path $jpyLockPath) {
            try { $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $jpyLockPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        # back off retries for 1h after a failure (offline/blocked)
        if ($failAge -gt 3600 -and $lockAge -gt 30) {
            try { New-Item -Path $jpyLockPath -ItemType File -Force > $null } catch {}
            Start-DetachedWorker @('-FetchJpyRate')
        }
    }
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
# Always computed in a detached worker — a large transcript must never block a render.
# Cache holds one line per transcript so concurrent sessions don't thrash each other.
$costIsEstimate = $false
if ($null -eq $costUsd -and -not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
    $tMtime = [long]((Get-Item -LiteralPath $transcriptPath).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds

    $cachedMtime = $null; $cachedVal = $null
    if (Test-Path $estCachePath) {
        $own = Get-Content $estCachePath -ErrorAction SilentlyContinue |
            Where-Object { $_ -and ($_ -split '\|')[0] -eq $transcriptPath } | Select-Object -First 1
        if ($own) {
            $p = $own -split '\|', 3
            if ($p.Count -eq 3) { $cachedMtime = $p[1]; $cachedVal = $p[2] }
        }
    }

    if ($cachedMtime -ne "$tMtime") {
        $lockPath = Join-Path $HOME ('.claude/cost_estimate.' + (Get-PathLockSuffix $transcriptPath) + '.lock')
        $lockAge = 999999
        if (Test-Path $lockPath) {
            try { $lockAge = ([DateTimeOffset]::UtcNow - (Get-Item $lockPath).LastWriteTimeUtc).TotalSeconds } catch {}
        }
        if ($lockAge -gt 30) {
            try { New-Item -Path $lockPath -ItemType File -Force > $null } catch {}
            Start-DetachedWorker @('-ComputeCostFor', ('"' + $transcriptPath + '"'))
        }
    }

    # show the last known value while the background refresh catches up;
    # first render of a brand-new transcript just skips the cost segment once
    $ev = $cachedVal -as [double]
    if ($null -ne $ev) {
        $costUsd = $ev
        $costIsEstimate = $true
    }
}

# Daily cost — per-session ledger so concurrent sessions can't inflate the total.
# Cache format: line 1 = date, then "<session_key>|<banked_usd>|<latest_session_usd>".
# NOTE: jpyRate is best-effort (fetched over the network); the $ cost must still
# display even when the JPY conversion is unavailable (offline, blocked host, etc.)
if ($null -ne $costUsd) {
    $curDate    = (Get-Date).ToString("yyyy-MM-dd")
    $sessionKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId }
                  elseif (-not [string]::IsNullOrWhiteSpace($transcriptPath)) { $transcriptPath }
                  else { 'default' }
    $accum  = 0.0
    $last   = 0.0
    $others = @()
    $oldLines = @()
    if (Test-Path $budgetCachePath) { $oldLines = @(Get-Content $budgetCachePath -ErrorAction SilentlyContinue) }
    if ($oldLines.Count -ge 1 -and $oldLines[0] -eq $curDate) {
        foreach ($l in ($oldLines | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $p = $l -split '\|', 3
            if ($p.Count -ne 3) { continue }
            if ($p[0] -eq $sessionKey) {
                $a  = $p[1] -as [double]; if ($null -ne $a)  { $accum = $a }
                $ls = $p[2] -as [double]; if ($null -ne $ls) { $last  = $ls }
            } else {
                $others += $l
            }
        }
    }

    # cost dropped => this session restarted (/clear, resume): bank the previous run
    if ($costUsd -lt $last) { $accum += $last }

    $newLines = @($curDate, "$sessionKey|$accum|$costUsd") + $others
    if (($newLines -join "`n") -ne ($oldLines -join "`n")) {
        $tmp = "${budgetCachePath}.tmp.$PID"
        Set-Content -Path $tmp -Value $newLines
        Move-Item -Force $tmp $budgetCachePath
    }

    $othersSum = 0.0
    foreach ($l in $others) {
        $p = $l -split '\|', 3
        $a  = $p[1] -as [double]; if ($null -ne $a)  { $othersSum += $a }
        $c2 = $p[2] -as [double]; if ($null -ne $c2) { $othersSum += $c2 }
    }

    $totalUsd  = $accum + $costUsd + $othersSum
    $costFmt   = "{0:F2}" -f $totalUsd
    $estPrefix = if ($costIsEstimate -or $isSubscriber) { "~" } else { "" }

    $budgetJpy = 500
    $envBudget = $env:CC_STATUSLINE_BUDGET_JPY -as [int]
    if ($null -ne $envBudget -and $envBudget -ge 0) { $budgetJpy = $envBudget }

    if ($null -ne $jpyRate) {
        $totalJpy   = [long][Math]::Floor($totalUsd * $jpyRate + 0.5)
        $sessionJpy = [long][Math]::Floor($costUsd  * $jpyRate + 0.5)

        if ($totalJpy -gt 0) {
            $totalJpyFmt   = "{0:N0}" -f $totalJpy
            $sessionJpyFmt = "{0:N0}" -f $sessionJpy
            if ($isSubscriber) {
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}~`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${C_GREEN}~¥${totalJpyFmt}${C_DIM})${C_RESET}"
            } elseif ($budgetJpy -gt 0) {
                $budgetJpyFmt = "{0:N0}" -f $budgetJpy
                $pct  = [Math]::Min([int][Math]::Floor($totalJpy * 100 / $budgetJpy), 100)
                $c    = Get-ColorForPct $pct
                $warn = if ($pct -ge 100) { "!!" } else { "" }
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${c}${warn}$(New-Bar $pct)${C_RESET}${c}${estPrefix}`$${costFmt}${C_RESET}${C_DIM}(${C_RESET}${c}¥${sessionJpyFmt}${C_RESET} ${C_DIM}Today:${C_RESET}${c}¥${totalJpyFmt}${C_DIM}/¥${budgetJpyFmt})${C_RESET}"
            } else {
                # budget disabled (CC_STATUSLINE_BUDGET_JPY=0): amounts only, no bar
                if ($out) { $out += " " }
                $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}${estPrefix}`$${costFmt}${C_DIM}(${C_RESET}${C_GREEN}¥${sessionJpyFmt}${C_RESET} ${C_DIM}Today:${C_RESET}${C_GREEN}¥${totalJpyFmt}${C_DIM})${C_RESET}"
            }
        }
    } elseif ($totalUsd -gt 0) {
        # JPY rate not yet cached (offline / blocked / disabled) — show plain $ amount, no bar/budget
        if ($out) { $out += " " }
        $out += "${C_DIM}Cost:${C_RESET}${C_GREEN}${estPrefix}`$${costFmt}${C_RESET}"
    }
}

[Console]::Write($out)
