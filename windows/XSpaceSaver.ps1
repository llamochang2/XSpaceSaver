# XSpaceSaver.ps1
# X Space 다시듣기 음성 저장: master_playlist.m3u8 URL -> m4a
# - 조각 경로 불일치(transcode 경로 400) 자동 보정
# - Windows 기본 PowerShell 5.1 + WinForms, 외부 의존성은 ffmpeg만 사용

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# 콘솔 창 숨김. 파싱 오류 시에는 여기까지 오지 않으므로 콘솔에 에러가 남음
try {
    Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
    [void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
} catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Workers  = 8     # 동시 다운로드 수
$MaxRetry = 4     # 조각별 추가 재시도 횟수
$AppTitle = 'X Space 다시듣기 저장'

$script:Busy    = $false
$script:Cancel  = $false
$script:FFmpeg  = $null
$script:LastOut = $null

# ---------- HTTP ----------

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromSeconds(30)
[void]$http.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36')
[void]$http.DefaultRequestHeaders.TryAddWithoutValidation('Referer', 'https://x.com/')

function Pump { [System.Windows.Forms.Application]::DoEvents() }

function Wait-UI([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { Pump; Start-Sleep -Milliseconds 30 }
}

function Wait-Task($task) {
    while (-not $task.IsCompleted) { Pump; Start-Sleep -Milliseconds 30 }
}

function Get-Text([string]$url) {
    $t = $http.GetAsync($url)
    Wait-Task $t
    if ($t.IsFaulted -or $t.IsCanceled) { throw "네트워크 오류: $url" }
    $r = $t.Result
    if (-not $r.IsSuccessStatusCode) { throw ("HTTP {0} 응답" -f [int]$r.StatusCode) }
    $c = $r.Content.ReadAsStringAsync()
    Wait-Task $c
    return $c.Result
}

function Get-Status([string]$url) {
    $t = $http.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    Wait-Task $t
    if ($t.IsFaulted -or $t.IsCanceled) { return 0 }
    $code = [int]$t.Result.StatusCode
    $t.Result.Dispose()
    return $code
}

function Get-Bytes([string]$url) {
    $t = $http.GetByteArrayAsync($url)
    Wait-Task $t
    if ($t.IsFaulted -or $t.IsCanceled) { return $null }
    return ,$t.Result
}

# ---------- URL / 플레이리스트 ----------

function Join-Url([string]$base, [string]$rel) {
    return (New-Object System.Uri((New-Object System.Uri($base)), $rel)).AbsoluteUri
}

function Get-DirUrl([string]$url) {
    $u = $url.Split('?')[0]
    return $u.Substring(0, $u.LastIndexOf('/') + 1)
}

function Remove-BPrefix([string]$url) {
    return $url.Replace('/b/Transcoding/', '/Transcoding/')
}

function Get-BaseLabel([string]$b) {
    $k = 'transcode'
    if ($b -match '/non_transcode/') { $k = 'non_transcode' }
    if ($b -match '/b/Transcoding/') { $k += ' (/b/)' }
    return $k
}

function Get-MediaPlaylist([string]$master) {
    # master면 첫 번째 variant를 따라감. 반환: @(playlist URL, 내용)
    $text = Get-Text $master
    if ($text -notmatch '#EXT-X-STREAM-INF') { return @($master, $text) }

    $variant = $text -split "`r?`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
    if (-not $variant) { throw 'master playlist에 variant 항목이 없습니다.' }

    $u = Join-Url $master $variant
    $last = $null
    foreach ($c in (@($u, (Remove-BPrefix $u)) | Select-Object -Unique)) {
        try { return @($c, (Get-Text $c)) } catch { $last = $_.Exception.Message }
    }
    throw "variant playlist를 불러오지 못했습니다: $last"
}

function Read-Playlist([string]$text) {
    # 헤더 태그 / 세그먼트(태그 + URI) / 꼬리 태그 분리
    $header  = New-Object System.Collections.Generic.List[string]
    $segs    = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) {
            if ($segs.Count -gt 0 -or $pending.Count -gt 0 -or $line -match '^#(EXTINF|EXT-X-PROGRAM-DATE-TIME|EXT-X-DISCONTINUITY)') {
                $pending.Add($line)
            } else {
                $header.Add($line)
            }
        } else {
            $segs.Add([pscustomobject]@{ Tags = $pending.ToArray(); Uri = $line })
            $pending = New-Object System.Collections.Generic.List[string]
        }
    }
    return [pscustomobject]@{ Header = $header.ToArray(); Segments = $segs.ToArray(); Tail = $pending.ToArray() }
}

function Get-TotalSeconds($pl) {
    $sec = 0.0
    foreach ($sg in $pl.Segments) {
        foreach ($t in $sg.Tags) {
            if ($t -like '#EXTINF:*') {
                $v = $t.Substring(8).Split(',')[0]
                $sec += [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }
    return $sec
}

function Find-ChunkBase([string]$master, [string]$plUrl, [string]$firstUri) {
    $cands = @()
    foreach ($b in @((Get-DirUrl $plUrl), (Get-DirUrl $master))) {
        $cands += $b
        $cands += (Remove-BPrefix $b)
    }
    foreach ($b in ($cands | Select-Object -Unique)) {
        $code = Get-Status (Join-Url $b $firstUri)
        Write-Log ("  경로 확인 {0}: {1}" -f $code, (Get-BaseLabel $b))
        if ($code -eq 200) { return $b }
    }
    throw '조각 파일 경로를 찾지 못했습니다. 녹음이 삭제됐거나 비공개로 바뀌었을 수 있습니다.'
}

# ---------- 다운로드 ----------

function Save-ChunkRetry([string]$url, [string]$path) {
    for ($a = 1; $a -le $MaxRetry; $a++) {
        if ($script:Cancel) { return $false }
        Wait-UI (1500 * $a)
        $bytes = Get-Bytes $url
        if ($null -ne $bytes) {
            [IO.File]::WriteAllBytes($path, $bytes)
            return $true
        }
    }
    return $false
}

function Save-Chunks([string]$base, $segs, [string]$dir) {
    $failed = New-Object 'System.Collections.Generic.HashSet[int]'
    $total = $segs.Count
    $done = 0
    for ($s = 0; $s -lt $total; $s += $Workers) {
        if ($script:Cancel) { throw '사용자가 중지했습니다.' }
        $e = [Math]::Min($s + $Workers, $total) - 1
        $batch = New-Object System.Collections.Generic.List[object]
        foreach ($i in $s..$e) {
            $u = Join-Url $base $segs[$i].Uri
            $batch.Add([pscustomobject]@{ I = $i; Url = $u; Task = $http.GetByteArrayAsync($u) })
        }
        foreach ($j in $batch) {
            Wait-Task $j.Task
            $path = Join-Path $dir ('{0:D6}.aac' -f $j.I)
            if (-not $j.Task.IsFaulted -and -not $j.Task.IsCanceled) {
                [IO.File]::WriteAllBytes($path, $j.Task.Result)
            } elseif (-not (Save-ChunkRetry $j.Url $path)) {
                [void]$failed.Add($j.I)
                Write-Log ("  조각 {0} 실패, 건너뜀" -f $j.I)
            }
            $done++
            $progress.Value = $done
            $lblStatus.Text = "다운로드 $done / $total"
        }
    }
    return ,$failed
}

function Write-LocalPlaylist([string]$path, $pl, $failed) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($h in $pl.Header) { $lines.Add($h) }
    for ($i = 0; $i -lt $pl.Segments.Count; $i++) {
        if ($failed.Contains($i)) { continue }
        foreach ($t in $pl.Segments[$i].Tags) { $lines.Add($t) }
        $lines.Add(('{0:D6}.aac' -f $i))
    }
    foreach ($t in $pl.Tail) { $lines.Add($t) }
    if (-not $lines.Contains('#EXT-X-ENDLIST')) { $lines.Add('#EXT-X-ENDLIST') }
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
}

# ---------- ffmpeg ----------

function Find-FFmpeg {
    $local = Join-Path $PSScriptRoot 'ffmpeg.exe'
    if (Test-Path $local) { return $local }

    # winget 설치 직후 PATH 반영
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'),
        (Join-Path $env:ProgramFiles 'WinGet\Links\ffmpeg.exe')
    )) {
        if (Test-Path $p) { return $p }
    }

    $pkg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $pkg) {
        $f = Get-ChildItem $pkg -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Invoke-Proc([string]$exe, [string]$argLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 50 }
    $p.WaitForExit()
    Wait-Task $errTask
    return [pscustomobject]@{ Code = $p.ExitCode; Err = $errTask.Result }
}

function Invoke-FFmpeg([string]$ff, [string]$playlist, [string]$out) {
    $common = '-hide_banner -loglevel error -y -allowed_extensions ALL'
    $tail = "-i `"$playlist`" -c copy `"$out`""
    # -extension_picky 는 ffmpeg 7.1 이상만 지원 -> 실패 시 옵션 빼고 재시도
    $r = Invoke-Proc $ff "$common -extension_picky 0 $tail"
    if ($r.Code -ne 0 -and $r.Err -match 'extension_picky') {
        $r = Invoke-Proc $ff "$common $tail"
    }
    return $r
}

function Get-UniquePath([string]$path) {
    if (-not (Test-Path $path)) { return $path }
    $dir  = [IO.Path]::GetDirectoryName($path)
    $stem = [IO.Path]::GetFileNameWithoutExtension($path)
    $ext  = [IO.Path]::GetExtension($path)
    $n = 1
    while (Test-Path (Join-Path $dir "$stem`_$n$ext")) { $n++ }
    return (Join-Path $dir "$stem`_$n$ext")
}

# ---------- UI ----------

$font     = New-Object System.Drawing.Font('Malgun Gothic', 9)
$fontBold = New-Object System.Drawing.Font('Malgun Gothic', 12, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppTitle
$form.Font = $font
$form.ClientSize = New-Object System.Drawing.Size(660, 760)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function New-Ctl($type, $x, $y, $w, $h, $text) {
    $c = New-Object "System.Windows.Forms.$type"
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($null -ne $text) { $c.Text = $text }
    return $c
}

$lblTitle = New-Ctl Label 20 12 620 26 $AppTitle
$lblTitle.Font = $fontBold
$lblSub = New-Ctl Label 20 40 620 20 'master_playlist.m3u8 URL로 Space 녹음을 m4a 파일로 저장합니다.'
$form.Controls.AddRange(@($lblTitle, $lblSub))

# 주의사항
$notices = @(
    '다시 듣기(녹음)가 켜진, 이미 끝난 Space만 저장할 수 있습니다. 진행 중인 Space는 저장되지 않습니다.',
    '녹음의 저작권은 호스트와 발언자에게 있습니다. 개인 보관용으로만 사용하고, 재배포·공개 업로드는 허락을 받은 경우에만 합니다.',
    'master URL에는 방송 접근 키가 들어 있습니다. 다른 사람에게 공유하거나 공개된 곳에 올리지 않습니다.',
    '[ffmpeg 설치] 버튼은 winget으로 ffmpeg(무료 오픈소스)을 인터넷에서 내려받아 설치하며, 이때 ffmpeg 라이선스에 동의하게 됩니다.',
    'X의 구조가 바뀌면 동작하지 않을 수 있습니다. 이 프로그램 사용과 결과물에 대한 책임은 사용자에게 있습니다.'
)
$grpNotice = New-Ctl GroupBox 20 68 620 (30 + $notices.Count * 40 + 22) '주의사항 (모두 체크해야 사용할 수 있습니다)'
$checks = @()
for ($i = 0; $i -lt $notices.Count; $i++) {
    $cb = New-Ctl CheckBox 15 (24 + $i * 40) 595 38 $notices[$i]
    $cb.CheckAlign = 'TopLeft'
    $cb.TextAlign = 'TopLeft'
    $grpNotice.Controls.Add($cb)
    $checks += $cb
}
$lblHint = New-Ctl Label 15 (28 + $notices.Count * 40) 590 18 '모든 항목에 체크하면 아래 버튼이 활성화됩니다.'
$lblHint.ForeColor = [System.Drawing.Color]::Firebrick
$grpNotice.Controls.Add($lblHint)
$form.Controls.Add($grpNotice)

$y = $grpNotice.Bottom + 10

# 1단계: ffmpeg
$grpFF = New-Ctl GroupBox 20 $y 620 62 '1단계: ffmpeg 준비'
$lblFF = New-Ctl Label 15 28 400 20 ''
$btnInstall = New-Ctl Button 440 20 165 32 'ffmpeg 설치'
$grpFF.Controls.AddRange(@($lblFF, $btnInstall))
$form.Controls.Add($grpFF)

$y = $grpFF.Bottom + 10

# 2단계: 저장
$grpSave = New-Ctl GroupBox 20 $y 620 180 '2단계: 저장'
$lblUrl  = New-Ctl Label 15 29 90 20 'master URL'
$txtUrl  = New-Ctl TextBox 110 26 495 24 ''
$lblDir  = New-Ctl Label 15 64 90 20 '저장 폴더'
$txtDir  = New-Ctl TextBox 110 61 400 24 ([Environment]::GetFolderPath('Desktop'))
$btnBrowse = New-Ctl Button 515 59 90 27 '찾아보기'
$lblName = New-Ctl Label 15 99 90 20 '파일 이름'
$txtName = New-Ctl TextBox 110 96 495 24 ('space_{0}.m4a' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$btnStart = New-Ctl Button 110 132 160 36 '저장 시작'
$btnStop  = New-Ctl Button 280 132 100 36 '중지'
$btnOpen  = New-Ctl Button 390 132 140 36 '저장 위치 열기'
$grpSave.Controls.AddRange(@($lblUrl, $txtUrl, $lblDir, $txtDir, $btnBrowse, $lblName, $txtName, $btnStart, $btnStop, $btnOpen))
$form.Controls.Add($grpSave)

$y = $grpSave.Bottom + 10

$progress  = New-Ctl ProgressBar 20 $y 620 20 $null
$lblStatus = New-Ctl Label 20 ($y + 24) 620 20 '대기 중'
$txtLog    = New-Ctl TextBox 20 ($y + 48) 620 ($form.ClientSize.Height - $y - 60) ''
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$form.Controls.AddRange(@($progress, $lblStatus, $txtLog))

function Write-Log([string]$m) {
    $txtLog.AppendText($m + "`r`n")
    Pump
}

function Update-UI {
    $all = $true
    foreach ($c in $checks) { if (-not $c.Checked) { $all = $false } }
    $has = [bool]$script:FFmpeg
    $busy = $script:Busy

    if ($has) {
        $lblFF.Text = 'ffmpeg: 설치됨'
        $lblFF.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lblFF.Text = 'ffmpeg: 없음 (오른쪽 버튼으로 설치)'
        $lblFF.ForeColor = [System.Drawing.Color]::Firebrick
    }

    $btnInstall.Enabled = $all -and (-not $has) -and (-not $busy)
    $btnStart.Enabled   = $all -and $has -and ($txtUrl.Text.Trim() -ne '') -and (-not $busy)
    $btnStop.Enabled    = $busy
    $btnOpen.Enabled    = [bool]$script:LastOut -and (-not $busy)
    foreach ($c in @($txtUrl, $txtDir, $txtName, $btnBrowse)) { $c.Enabled = -not $busy }
    foreach ($c in $checks) { $c.Enabled = -not $busy }
    $lblHint.Visible = -not $all
}

function Install-FFmpeg {
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "winget(앱 설치 관리자)을 찾을 수 없습니다.`r`n`r`nMicrosoft Store에서 '앱 설치 관리자'를 설치한 뒤 다시 시도하거나,`r`nffmpeg.exe를 이 프로그램과 같은 폴더에 넣어 주세요.",
            $AppTitle, 'OK', 'Warning')
        return
    }
    $script:Busy = $true
    Update-UI
    try {
        Write-Log 'ffmpeg 설치 시작 (새 창에서 진행됩니다. 창이 닫힐 때까지 기다려 주세요)'
        $lblStatus.Text = 'ffmpeg 설치 중...'
        $p = Start-Process -FilePath $wg.Source -PassThru -ArgumentList @(
            'install', '--id', 'Gyan.FFmpeg', '-e', '--source', 'winget',
            '--accept-source-agreements', '--accept-package-agreements')
        $null = $p.Handle   # ExitCode 조회용 핸들 확보
        while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 200 }

        $script:FFmpeg = Find-FFmpeg
        if ($script:FFmpeg) {
            Write-Log 'ffmpeg 설치 완료'
            $lblStatus.Text = 'ffmpeg 준비 완료'
        } else {
            Write-Log ("ffmpeg을 찾지 못했습니다 (winget 종료 코드 {0}). 프로그램을 다시 실행해 보세요." -f $p.ExitCode)
            $lblStatus.Text = 'ffmpeg 설치 확인 실패'
        }
    } catch {
        Write-Log ("설치 오류: " + $_.Exception.Message)
    } finally {
        $script:Busy = $false
        Update-UI
    }
}

function Start-Save {
    $script:Busy = $true
    $script:Cancel = $false
    Update-UI
    $txtLog.Clear()
    $progress.Value = 0
    $work = $null
    try {
        $master = $txtUrl.Text.Trim().Trim('"')
        if ($master -notmatch '^https?://') { throw 'URL 형식이 올바르지 않습니다. https:// 로 시작하는 master URL을 넣어 주세요.' }
        $outDir = $txtDir.Text.Trim()
        if (-not (Test-Path $outDir)) { throw '저장 폴더가 없습니다.' }
        $name = $txtName.Text.Trim()
        if (-not $name) { $name = 'space_{0}.m4a' -f (Get-Date -Format 'yyyyMMdd_HHmmss') }
        if (-not $name.ToLower().EndsWith('.m4a')) { $name += '.m4a' }
        $out = Get-UniquePath (Join-Path $outDir $name)

        Write-Log '[1/4] 플레이리스트 확인'
        $mp = Get-MediaPlaylist $master
        $pl = Read-Playlist $mp[1]
        if ($pl.Segments.Count -eq 0) { throw '조각 목록이 비어 있습니다. 진행 중이거나 녹음이 없는 Space일 수 있습니다.' }
        $sec = Get-TotalSeconds $pl
        Write-Log ("  조각 {0}개, 약 {1}분 {2}초" -f $pl.Segments.Count, [int][Math]::Floor($sec / 60), [int]($sec % 60))

        Write-Log '[2/4] 조각 경로 탐색'
        $base = Find-ChunkBase $master $mp[0] $pl.Segments[0].Uri

        Write-Log '[3/4] 조각 다운로드'
        $work = Join-Path ([IO.Path]::GetTempPath()) ('xspace_' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $work)
        $progress.Maximum = $pl.Segments.Count
        $failed = Save-Chunks $base $pl.Segments $work
        if ($failed.Count -eq $pl.Segments.Count) { throw '모든 조각 다운로드에 실패했습니다.' }

        Write-Log '[4/4] m4a로 합치기'
        $lblStatus.Text = 'm4a로 합치는 중...'
        $local = Join-Path $work 'local.m3u8'
        Write-LocalPlaylist $local $pl $failed
        $r = Invoke-FFmpeg $script:FFmpeg $local $out
        if ($r.Code -ne 0) { throw ("ffmpeg 실패:`r`n" + $r.Err) }

        $script:LastOut = $out
        Write-Log "완료: $out"
        if ($failed.Count -gt 0) { Write-Log ("  누락된 조각 {0}개 (해당 구간 끊김)" -f $failed.Count) }
        $lblStatus.Text = '저장 완료'
        $txtName.Text = 'space_{0}.m4a' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        [void][System.Windows.Forms.MessageBox]::Show("저장했습니다.`r`n$out", $AppTitle, 'OK', 'Information')
    } catch {
        $msg = $_.Exception.Message
        Write-Log "오류: $msg"
        $lblStatus.Text = '실패'
        [void][System.Windows.Forms.MessageBox]::Show($msg, $AppTitle, 'OK', 'Error')
    } finally {
        if ($work -and (Test-Path $work)) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
        $script:Busy = $false
        Update-UI
    }
}

# ---------- 이벤트 ----------

foreach ($cb in $checks) { $cb.Add_CheckedChanged({ Update-UI }) }
$txtUrl.Add_TextChanged({ Update-UI })
$btnInstall.Add_Click({ Install-FFmpeg })
$btnStart.Add_Click({ Start-Save })
$btnStop.Add_Click({ $script:Cancel = $true; $lblStatus.Text = '중지하는 중...' })
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.SelectedPath = $txtDir.Text
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtDir.Text = $d.SelectedPath }
})
$btnOpen.Add_Click({
    if ($script:LastOut -and (Test-Path $script:LastOut)) {
        Start-Process explorer.exe "/select,`"$($script:LastOut)`""
    }
})
$form.Add_FormClosing({ $script:Cancel = $true })

$script:FFmpeg = Find-FFmpeg
Update-UI

try {
    [void]$form.ShowDialog()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show("예상하지 못한 오류: " + $_.Exception.Message, $AppTitle, 'OK', 'Error')
} finally {
    $http.Dispose()
}
