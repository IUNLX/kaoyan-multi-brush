<#
.SYNOPSIS
    建附注 tag → 单独推送 tag → 通过 GitHub API 创建 Release。

.DESCRIPTION
    按《项目规范.md》第五节阶段二第 ⑪ 步执行。

    为什么需要这个脚本：
      · `release.ps1` 只做到 `git push` 为止，**不会**建 tag 与 Release；
      · `git push` **默认不推送 tag**（push.followTags 未设置），必须显式 `git push <remote> <tag>`，
        否则会出现「本地有 tag、远端没有」；
      · 本机没有安装 `gh` CLI，创建 Release 只能走 GitHub REST API，需要从 git 凭据里取 token。

    ⚠️ 本脚本会创建**公开的** GitHub Release。按规范核心原则 5，
       **必须先获得用户明确同意**再运行（`-Yes` 只是跳过脚本自身的二次确认，不代表已获同意）。

.PARAMETER Version
    要发布的版本号。省略则自动取主程序 `考研真题多刷记录.html` 里的 `APP_VERSION`。
    若显式传入且与 `APP_VERSION` 不一致，直接报错中止（发版前必须先同步三处）。

.PARAMETER Title
    Release 标题。省略则用 tag 名（如 `v1.3.2`）。

.PARAMETER Remote
    远端名，默认 origin。

.PARAMETER Branch
    分支，默认 master。

.PARAMETER Yes
    跳过运行前的人工确认（适合**已获用户同意**后的非交互执行）。

.PARAMETER SkipTag
    跳过建 tag 与推送 tag，只创建 Release。
    用于补救「tag 已推送成功、但 Release 建失败」的情况。

.PARAMETER DryRun
    只做检查并打印将要执行的动作，**不建 tag、不推送、不调用 API**。用于安全自测。

.EXAMPLE
    .\release-github.ps1 -DryRun
    演练：检查版本、确认提交已推送、校验 tag 不存在、预览 Release 说明，不产生任何远端改动。

.EXAMPLE
    .\release-github.ps1 -Yes
    正式发布 GitHub Release（需已获用户同意）。

.EXAMPLE
    .\release-github.ps1 -SkipTag -Yes
    tag 已推送但 Release 没建成功时，只补建 Release。
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Title,
    [string]$Remote = 'origin',
    [string]$Branch = 'master',
    [switch]$Yes,
    [switch]$SkipTag,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$HTML = '考研真题多刷记录.html'
$CHANGELOG = 'CHANGELOG.md'

function Write-Step { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "  [X]  $Text" -ForegroundColor Red }

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    # 原生命令写 stderr 在 ErrorActionPreference=Stop 下会被误判为终止性错误，
    # 这里临时降级为 Continue，只以退出码为准。
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
    # ⚠️ 注意：PowerShell 变量名不区分大小写，返回值的接收变量名**不得与任何参数同名**
    # （如 $Remote/$Branch/$Yes/...），否则会抛类型转换错误。这是本项目踩过的坑。
    return [pscustomobject]@{ Code = $code; Output = @($output) }
}

try {
    # ---------- 0. 环境检查 ----------
    if ($DryRun) { Write-Step '0/8 环境检查（DryRun 演练模式，不会产生任何远端改动）' }
    else { Write-Step '0/8 环境检查' }

    if (-not (Test-Path '.git')) { throw '当前目录不是 Git 仓库根目录，请在 kaoyan-multi-brush 目录下运行。' }
    if (-not (Test-Path $HTML)) { throw "未找到主程序 $HTML，请确认在项目根目录运行。" }
    if (-not (Test-Path $CHANGELOG)) { throw "未找到 $CHANGELOG。" }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '未找到 node，无法执行版本校验。' }
    Write-Ok '位于项目根目录，node 可用'

    $remoteUrl = (Invoke-Git -GitArgs @('remote', 'get-url', $Remote)).Output -join ''
    Write-Ok "远端 $Remote -> $remoteUrl"

    $slugMatch = [regex]::Match($remoteUrl, 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\s*$')
    if (-not $slugMatch.Success) { throw "无法从远端地址解析出 owner/repo：$remoteUrl" }
    $owner = $slugMatch.Groups[1].Value
    $repo = $slugMatch.Groups[2].Value
    Write-Ok "GitHub 仓库：$owner/$repo"

    # ---------- 1. 确定版本号 ----------
    Write-Step '1/8 确定版本号'
    $htmlText = [System.IO.File]::ReadAllText((Resolve-Path $HTML).Path, [System.Text.Encoding]::UTF8)
    $verMatch = [regex]::Match($htmlText, "var\s+APP_VERSION\s*=\s*'([^']*)'")
    $appVersion = ''
    if ($verMatch.Success) { $appVersion = $verMatch.Groups[1].Value }

    if ($Version) {
        if ($appVersion -and $Version -ne $appVersion) {
            throw "传入的 -Version $Version 与主程序 APP_VERSION($appVersion) 不一致。发版前必须先按《项目规范.md》第四节同步三处。"
        }
        $targetVersion = $Version
    }
    else {
        if (-not $appVersion) { throw '未能从主程序读取 APP_VERSION，请用 -Version 显式指定。' }
        $targetVersion = $appVersion
    }
    if ($targetVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "版本号「$targetVersion」不是完整的 主.次.修订 三段式。"
    }
    Write-Ok "目标版本：v$targetVersion"

    # ---------- 2. 版本一致性校验 ----------
    Write-Step '2/8 版本一致性校验（node check-version.mjs）'
    & node check-version.mjs
    if ($LASTEXITCODE -ne 0) { throw '版本校验未通过，已中止。请按《项目规范.md》修正后重试。' }

    # ---------- 3. 确认待发布提交已推送 ----------
    Write-Step '3/8 确认提交已推送'
    $ahead = (Invoke-Git -GitArgs @('log', "$Remote/$Branch..$Branch", '--oneline')).Output |
             Where-Object { $_ -and "$_".Trim() }
    if ($ahead) {
        Write-Err '本地仍有未推送的提交——tag 必须指向已推送到 GitHub 的提交：'
        $ahead | ForEach-Object { Write-Err "    $_" }
        throw '请先按《项目规范.md》阶段二完成推送（release.ps1 -Push），再运行本脚本。'
    }
    $headFull = (Invoke-Git -GitArgs @('rev-parse', 'HEAD')).Output -join ''
    $headShort = "$headFull".Trim().Substring(0, 7)
    Write-Ok "$Remote/$Branch 已是最新，HEAD = $headShort"

    # ---------- 4. 检查 tag ----------
    Write-Step '4/8 检查 tag'
    $tagName = "v$targetVersion"
    $localTag = (Invoke-Git -GitArgs @('rev-parse', '-q', '--verify', "refs/tags/$tagName") -AllowFail).Code -eq 0
    $remoteTagRaw = (Invoke-Git -GitArgs @('ls-remote', '--tags', $Remote, "refs/tags/$tagName") -AllowFail).Output -join ''
    $remoteTag = "$remoteTagRaw".Trim().Length -gt 0

    if ($SkipTag) {
        if (-not $remoteTag) { throw "指定了 -SkipTag，但远端不存在 tag $tagName，无法只建 Release。" }
        Write-Ok "已指定 -SkipTag：跳过建 tag 与推送，直接建 Release"
    }
    elseif ($localTag -or $remoteTag) {
        $where = @()
        if ($localTag) { $where += '本地' }
        if ($remoteTag) { $where += '远端' }
        Write-Err "tag $tagName 已存在（$($where -join '、')）。"
        Write-Warn '按规范禁止版本号回退、禁止为同一批改动重复发版，本脚本不会覆盖已存在的 tag。'
        Write-Warn '若只是 Release 漏建，改用：  .\release-github.ps1 -SkipTag'
        Write-Warn '若确实要重发，请先与用户确认，再手动删除：'
        Write-Host "    git tag -d $tagName" -ForegroundColor Cyan
        Write-Host "    git push $Remote :refs/tags/$tagName" -ForegroundColor Cyan
        throw 'tag 已存在，已中止。'
    }
    else {
        Write-Ok "tag $tagName 尚不存在，可以创建"
    }

    # ---------- 5. 生成 Release 说明 ----------
    Write-Step '5/8 生成 Release 说明'
    $cl = [System.IO.File]::ReadAllText((Resolve-Path $CHANGELOG).Path, [System.Text.Encoding]::UTF8)
    $esc = [regex]::Escape($targetVersion)
    $sec = [regex]::Match($cl, "(?ms)^##\s*\[$esc\][^\r\n]*\r?\n(.*?)(?=^##\s|\z)")
    $notes = ''
    if ($sec.Success) {
        $notes = $sec.Groups[1].Value -replace '(?s)\r?\n---\s*$', ''
        $notes = $notes.Trim()
    }
    if (-not $notes) {
        Write-Warn "CHANGELOG 中未找到 v$targetVersion 的区段，将使用占位说明。"
        $notes = "版本 v$targetVersion 的发布说明见 CHANGELOG.md。"
    }
    else {
        Write-Ok "已从 CHANGELOG 提取 v$targetVersion 的发布说明（$($notes.Length) 字符）"
    }
    $notes += "`n`n---`n`n**完整变更**：见 [CHANGELOG.md](https://github.com/$owner/$repo/blob/$Branch/CHANGELOG.md)"

    if ($Title) { $releaseTitle = $Title } else { $releaseTitle = $tagName }

    # ---------- 6. 确认 ----------
    Write-Step '6/8 确认'
    Write-Host '  将要执行：'
    $n = 1
    if (-not $SkipTag) {
        Write-Host "    $n) git tag -a $tagName $headShort"
        $n++
        Write-Host "    $n) git push $Remote $tagName        # git push 默认不带 tag，必须显式推"
        $n++
    }
    else {
        Write-Host '    （-SkipTag：跳过建 tag 与推送）'
    }
    Write-Host "    $n) POST https://api.github.com/repos/$owner/$repo/releases"
    Write-Host ''
    Write-Host "  版本：v$targetVersion    提交：$headShort    标题：$releaseTitle"
    Write-Host '  Release 说明预览（前 12 行）：'
    ($notes -split "`n" | Select-Object -First 12) | ForEach-Object { Write-Host "    $_" }

    if ($DryRun) {
        Write-Step '演练结束（DryRun）'
        Write-Ok '未创建 tag、未推送、未调用 API。去掉 -DryRun 即可正式执行。'
        exit 0
    }

    if (-not $Yes) {
        $ans = Read-Host '  确认创建 tag 并发布 GitHub Release？(y/N)'
        if ($ans -notmatch '^[yY]') {
            Write-Warn '已取消，未做任何改动。'
            exit 0
        }
    }

    # ---------- 7. 建 tag 并推送 ----------
    if ($SkipTag) {
        Write-Step '7/8 建 tag 并推送（已跳过）'
    }
    else {
        Write-Step '7/8 建 tag 并推送'
        Invoke-Git -GitArgs @('tag', '-a', $tagName, $headShort, '-m', "发布 $tagName") | Out-Null
        Write-Ok "已创建附注 tag $tagName -> $headShort"

        # 关键：git push 默认不推送 tag，必须显式推送，否则远端没有这个 tag
        $tagPush = Invoke-Git -GitArgs @('push', $Remote, $tagName) -AllowFail
        $tagPush.Output | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" }
        if ($tagPush.Code -ne 0) {
            Write-Err 'tag 推送失败。tag 已在本地创建，可稍后手动重推：'
            Write-Host "    git push $Remote $tagName" -ForegroundColor Cyan
            throw 'tag 推送失败，已中止（未创建 Release）。'
        }
        Write-Ok "tag $tagName 已推送到 $Remote"
    }

    # ---------- 8. 创建 GitHub Release ----------
    Write-Step '8/8 创建 GitHub Release'

    # 从 git 凭据取 token。本机 credential.helper=manager，凭据存在 Windows 凭据管理器。
    # 临时凭据输入文件放在系统临时目录，用完立即删除（不落在仓库里）。
    $credFile = Join-Path ([System.IO.Path]::GetTempPath()) ('kym_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($credFile, "protocol=https`r`nhost=github.com`r`n`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $credOut = & cmd /c "git credential fill < `"$credFile`" 2>&1"
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue

    $token = ($credOut | Where-Object { "$_" -like 'password=*' } | Select-Object -First 1) -replace '^password=', ''
    if (-not $token) {
        Write-Err '未能从 git 凭据中取到 token。'
        Write-Warn '请先在普通终端成功推送一次（登录 Git 凭据管理器），或配置 PAT，详见《项目规范.md》7.9 节。'
        Write-Warn "tag $tagName 已推送；之后可运行  .\release-github.ps1 -SkipTag  补建 Release。"
        exit 1
    }
    Write-Ok '已从 git 凭据取得 token'

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $payload = @{
        tag_name   = $tagName
        name       = $releaseTitle
        body       = $notes
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Method Post `
            -Uri "https://api.github.com/repos/$owner/$repo/releases" `
            -Headers @{
                Authorization = "Bearer $token"
                Accept        = 'application/vnd.github+json'
                'User-Agent'  = 'kaoyan-multi-brush-release'
            } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) `
            -ContentType 'application/json; charset=utf-8'
    }
    catch {
        Write-Err "创建 Release 失败：$($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
        Write-Warn "tag $tagName 已推送成功，但 Release 未创建。"
        Write-Warn '排查后可重跑：  .\release-github.ps1 -SkipTag'
        exit 1
    }

    Write-Step '发布完成'
    Write-Ok "tag：$tagName -> $headShort"
    Write-Ok "Release：$($resp.html_url)"
    Write-Host ''
    exit 0
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    Write-Host "`n已中止。规范见《项目规范.md》。`n" -ForegroundColor Yellow
    exit 1
}
