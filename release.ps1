<#
.SYNOPSIS
    版本校验 → 暂存 → 提交；只有显式加 -Push 才推送到 GitHub。

.DESCRIPTION
    按《版本更新规范.md》第四节执行。任何一步失败立即中止，不会提交、不会推送。

    **默认只提交到本地，不推送**（阶段一·累积）。这是刻意的安全默认值：
    规范要求「推送前必须先征得用户同意」，默认不联网就不会因忘记加参数而误推。
    需要推送时显式加 -Push（阶段二·发版）。

.PARAMETER Message
    提交信息，格式遵循规范第五节，例如：
      .\release.ps1 "feat: 试卷总时间改为可填写"

.PARAMETER Push
    显式请求推送到远端。**只在已获得用户同意后使用。** 不加此参数时脚本永不联网。

.PARAMETER Branch
    目标分支，默认 master。

.PARAMETER Remote
    远端名，默认 origin（https://github.com/IUNLX/kaoyan-multi-brush）。

.PARAMETER Yes
    跳过提交前的人工确认（适合熟练后使用）。**注意：-Yes 不会触发推送**，推送仍须显式 -Push。

.EXAMPLE
    .\release.ps1 "fix: 修复导出乱码"
    只提交到本地（阶段一），不推送。

.EXAMPLE
    .\release.ps1 "feat: 本批改动汇总" -Push
    提交并推送到 GitHub（阶段二，需已获用户同意）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [string]$Branch = 'master',
    [string]$Remote = 'origin',
    [switch]$Push,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# 规范第九节：禁止提交的文件
$ForbiddenPatterns = @(
    [pscustomobject]@{ Pattern = '\.lnk$';         Reason = '本机快捷方式，属个人环境文件' },
    [pscustomobject]@{ Pattern = '~\$.*\.xlsx$';   Reason = 'Excel 临时文件' },
    [pscustomobject]@{ Pattern = '\.bak$';         Reason = '备份文件' },
    [pscustomobject]@{ Pattern = '\.backup$';      Reason = '备份文件' }
)

function Write-Step { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [OK] $Text"   -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  [!]  $Text"   -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "  [X]  $Text"   -ForegroundColor Red }

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    # 原生命令写 stderr（如 git push 的进度）在 ErrorActionPreference=Stop 下会被误判为
    # 终止性错误，这里临时降级为 Continue，只以退出码为准。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0 -and -not $AllowFail) {
        $joined = ($output | ForEach-Object { "    $_" }) -join "`n"
        throw "git $($GitArgs -join ' ') 执行失败（退出码 $code）`n$joined"
    }
    return [pscustomobject]@{ Code = $code; Output = @($output) }
}

try {
    # ---------- 0. 环境检查 ----------
    Write-Step '0/6 环境检查'

    if (-not (Test-Path '.git')) {
        throw '当前目录不是 Git 仓库根目录，请在 kaoyan-multi-brush 目录下运行本脚本。'
    }
    if (-not (Test-Path '考研真题多刷记录.html')) {
        throw '未找到主程序 考研真题多刷记录.html，请确认在项目根目录运行。'
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw '未找到 node，无法执行版本校验。请先安装 Node.js。'
    }
    Write-Ok '位于项目根目录，node 可用'

    $remoteUrl = (Invoke-Git -GitArgs @('remote', 'get-url', $Remote)).Output -join ''
    Write-Ok "远端 $Remote -> $remoteUrl"

    $trackedLnk = (Invoke-Git -GitArgs @('ls-files', '--', '*.lnk')).Output | Where-Object { $_ }
    if ($trackedLnk) {
        Write-Warn '以下快捷方式仍被 Git 跟踪，建议执行 git rm --cached 取消跟踪：'
        $trackedLnk | ForEach-Object { Write-Warn "  $_" }
    }

    # ---------- 1. 版本一致性校验 ----------
    Write-Step '1/6 版本一致性校验（node check-version.mjs）'
    & node check-version.mjs
    if ($LASTEXITCODE -ne 0) {
        throw '版本校验未通过，已中止。请按《版本更新规范.md》修正后重试。'
    }

    # ---------- 2. 检查有无改动 ----------
    Write-Step '2/6 检查待提交改动'
    $porcelain = (Invoke-Git -GitArgs @('status', '--porcelain')).Output | Where-Object { $_ }
    if (-not $porcelain) {
        throw '工作区没有任何改动，无需发布。'
    }

    # ---------- 3. 暂存并复核 ----------
    Write-Step '3/6 暂存文件'
    Invoke-Git -GitArgs @('add', '-A') | Out-Null

    $statusLines = (Invoke-Git -GitArgs @('diff', '--cached', '--name-status')).Output |
                   Where-Object { $_ -and "$_".Trim() }
    if (-not $statusLines) {
        throw '暂存后没有文件，已中止。'
    }

    $staged = @()
    foreach ($line in $statusLines) {
        $parts = "$line" -split "`t"
        if ($parts.Count -lt 2) { continue }
        $staged += [pscustomobject]@{
            Status = $parts[0]
            Path   = $parts[$parts.Count - 1]   # 重命名取新路径
        }
    }

    Write-Host '  将要提交的文件：'
    $staged | ForEach-Object { Write-Host ("    {0,-3} {1}" -f $_.Status, $_.Path) }

    $violations = @()
    foreach ($item in $staged) {
        if ($item.Status -like 'D*') { continue }   # 删除禁止文件属清理动作，放行
        foreach ($rule in $ForbiddenPatterns) {
            if ($item.Path -match $rule.Pattern) {
                $violations += "    - $($item.Path)  （$($rule.Reason)）"
            }
        }
    }
    if ($violations.Count -gt 0) {
        Write-Err '暂存区包含规范禁止提交的文件：'
        $violations | ForEach-Object { Write-Err $_ }
        throw '已中止。请执行 git restore --staged <文件> 移除后再发布。'
    }
    Write-Ok "共 $($staged.Count) 个文件，未发现违规新增"

    $headBefore = (Invoke-Git -GitArgs @('rev-parse', '--short', 'HEAD')).Output -join ''

    # ---------- 4. 确认 ----------
    Write-Step '4/6 确认提交'
    Write-Host "  当前 HEAD：$headBefore"
    Write-Host '  提交信息：'
    ($Message -split "`n") | ForEach-Object { Write-Host "    $_" }

    if (-not $Yes) {
        $target = if ($Push) { "提交并推送到 $Remote/$Branch" } else { '提交到本地（本次不推送）' }
        $answer = Read-Host "  确认$target ？(y/N)"
        if ($answer -notmatch '^[yY]') {
            Invoke-Git -GitArgs @('reset') | Out-Null
            Write-Warn '已取消，暂存区已复位，未做任何提交与推送。'
            exit 0
        }
    }

    # ---------- 5. 提交 ----------
    Write-Step '5/6 提交'
    Invoke-Git -GitArgs @('commit', '-m', $Message) | Out-Null
    $headAfter = (Invoke-Git -GitArgs @('rev-parse', '--short', 'HEAD')).Output -join ''
    Write-Ok "已提交：$headAfter"

    # ---------- 6. 推送（仅在显式 -Push 时执行）----------
    if (-not $Push) {
        Write-Step '6/6 已提交到本地（未推送）'

        $pendingRaw = (Invoke-Git -GitArgs @('rev-list', '--count', "$Remote/$Branch..$Branch") -AllowFail).Output -join ''
        $pending = "$pendingRaw".Trim()
        if (-not $pending) { $pending = '?' }

        Write-Ok "已提交：$headAfter"
        Write-Warn "按规范未推送：$Remote/$Branch 当前落后 $pending 个提交。"
        Write-Host '  这批改动会与后续改动合并为同一个版本（累积期间不改 APP_VERSION）。' -ForegroundColor Yellow
        Write-Host '  获得用户同意后再发版推送：' -ForegroundColor Yellow
        Write-Host '    .\release.ps1 "<发版提交信息>" -Push' -ForegroundColor Cyan
        Write-Host "  或直接：  git push $Remote $Branch" -ForegroundColor Cyan
        Write-Host ''
        exit 0
    }

    Write-Step '6/6 推送到 GitHub'
    $push = Invoke-Git -GitArgs @('push', $Remote, $Branch) -AllowFail
    $push.Output | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" }

    if ($push.Code -ne 0) {
        Write-Err '推送失败（提交已在本地完成，未推送）。'
        Write-Warn '常见原因与处理见《版本更新规范.md》第 6.4 节。'
        exit 1
    }

    $ahead = (Invoke-Git -GitArgs @('log', "$Remote/$Branch..$Branch", '--oneline')).Output |
             Where-Object { $_ -and "$_".Trim() }
    if ($ahead) {
        Write-Err "推送后本地仍领先 $Remote/$Branch，未完成："
        $ahead | ForEach-Object { Write-Err "    $_" }
        exit 1
    }

    $webBase = ($remoteUrl -replace '^git@([^:]+):', 'https://$1/' -replace '\.git\s*$', '').Trim()
    Write-Step '发布完成'
    Write-Ok "已推送到 $Remote/$Branch"
    Write-Ok "提交：$headAfter"
    Write-Host "`n  查看提交：$webBase/commit/$headAfter" -ForegroundColor Cyan
    Write-Host "  提交历史：$webBase/commits/$Branch`n" -ForegroundColor Cyan
    exit 0
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host "`n发布已中止。规范见《版本更新规范.md》。`n" -ForegroundColor Yellow
    exit 1
}
