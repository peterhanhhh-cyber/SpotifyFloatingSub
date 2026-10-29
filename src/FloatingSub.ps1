#Requires -Version 5.1
<#
    FloatingSub - fancy floating subtitles for Spotify.

    Reads what Spotify is playing from the Windows System Media Transport
    Controls (SMTC) session, fetches time-synced lyrics from LRCLIB, and draws
    an always-on-top, click-through, glassy overlay with a karaoke wipe.

    Runs on the Windows side (WPF needs a Windows desktop). Launch it with
    ./run.sh from WSL.

    Options:
      -SelfTest    print the current track + fetched lyrics and exit (no window)
      -ConfigPath  use an alternate config.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- paths -----

$AppDir = Join-Path $env:LOCALAPPDATA 'SpotifyFloatingSub'
$CacheDir = Join-Path $AppDir 'cache'
$LyricDir = Join-Path $CacheDir 'lyrics'
$ArtDir = Join-Path $CacheDir 'art'
if (-not $ConfigPath) { $ConfigPath = Join-Path $AppDir 'config.json' }

foreach ($d in @($AppDir, $CacheDir, $LyricDir, $ArtDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$LogPath = Join-Path $AppDir 'floatsub.log'
function Write-Log($msg) {
    try {
        $line = '{0}  {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $msg
        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
    } catch { }
}

# --------------------------------------------------------------- config -----

$Defaults = [ordered]@{
    width         = 940
    height        = 180
    lyricFontSize = 30
    nextFontSize  = 17
    metaFontSize  = 13
    showAlbumArt  = $true
    showControls  = $true
    dragMode      = 'hover'
    hotkey        = 'Ctrl+Alt+L'
    hotkeyToggle  = 'Ctrl+Alt+K'
    bottomOffset  = 120
    left          = $null
    top           = $null
    opacity       = 1.0
    panelAlpha    = 0.0
    syncOffsetMs  = 0
    pollMs        = 400
    frameMs       = 33
}

function Get-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }
    if (Test-Path $ConfigPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
            foreach ($k in @($Defaults.Keys)) {
                if ($raw.PSObject.Properties.Name -contains $k -and $null -ne $raw.$k) {
                    $cfg[$k] = $raw.$k
                }
            }
        } catch { Write-Log "config parse failed: $($_.Exception.Message)" }
    }
    $cfg
}

function Save-Config($cfg) {
    try {
        $json = $cfg | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "config save failed: $($_.Exception.Message)" }
}

$Cfg = Get-Config

# ------------------------------------------------------------- win32 --------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
public class Native {
  [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
}
'@

$GWL_EXSTYLE = -20
$WS_EX_TRANSPARENT = 0x00000020
$WM_HOTKEY = 0x0312
$MOD_ALT = 0x0001
$MOD_CONTROL = 0x0002
$MOD_SHIFT = 0x0004
$MOD_WIN = 0x0008

# "Ctrl+Alt+L" -> @{ Mods = 3; Vk = 76 }, or $null if unparseable.
function Parse-Hotkey([string]$spec) {
    $mods = 0; $vk = 0
    foreach ($part in ($spec -split '\+')) {
        switch ($part.Trim().ToUpper()) {
            'CTRL' { $mods = $mods -bor $MOD_CONTROL }
            'CONTROL' { $mods = $mods -bor $MOD_CONTROL }
            'ALT' { $mods = $mods -bor $MOD_ALT }
            'SHIFT' { $mods = $mods -bor $MOD_SHIFT }
            'WIN' { $mods = $mods -bor $MOD_WIN }
            default {
                $p = $part.Trim().ToUpper()
                if ($p -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
                elseif ($p.Length -eq 1) { $vk = [int][char]$p }
            }
        }
    }
    if ($vk -eq 0) { return $null }
    @{ Mods = $mods; Vk = $vk }
}

# ------------------------------------------------------------- winrt --------

$AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($op, $type) {
    $task = $AsTask.MakeGenericMethod($type).Invoke($null, @($op))
    [void]$task.Wait(5000)
    $task.Result
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
# Note the namespace: MediaPlaybackAutoRepeatMode lives in Windows.Media, not
# Windows.Media.Playback (where the SMTC session type lives).
$null = [Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]

$SmtcType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$StreamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]

$Mgr = Await ($SmtcType::RequestAsync()) $SmtcType

# PowerShell 5.1 can't cast WinRT objects (System.__ComObject) to their
# projected interfaces, so AsStreamForRead/DataReader both fail to bind.
# Invoking the method through reflection bypasses the cast entirely.
$AsStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1
} | Select-Object -First 1

function Get-SpotifySession {
    $fallback = $null
    foreach ($s in $Mgr.GetSessions()) {
        $id = $s.SourceAppUserModelId
        if ($id -like '*Spotify*') { return $s }
        if (-not $fallback -and $id -notlike '*System*') { $fallback = $s }
    }
    $fallback
}

# ------------------------------------------------------------ helpers -------

function Get-TrackKey($title, $artist, $album, $duration) {
    $s = '{0}|{1}|{2}|{3}' -f $artist, $title, $album, [int][Math]::Round($duration)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $md5.Dispose() }
}

function Convert-HslToRgb([double]$h, [double]$s, [double]$l) {
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs((($h / 60.0) % 2) - 1))
    $m = $l - $c / 2
    $r = 0.0; $g = 0.0; $b = 0.0
    if ($h -lt 60) { $r = $c; $g = $x }
    elseif ($h -lt 120) { $r = $x; $g = $c }
    elseif ($h -lt 180) { $g = $c; $b = $x }
    elseif ($h -lt 240) { $g = $x; $b = $c }
    elseif ($h -lt 300) { $r = $x; $b = $c }
    else { $r = $c; $b = $x }
    $ri = [int][Math]::Round(($r + $m) * 255)
    $gi = [int][Math]::Round(($g + $m) * 255)
    $bi = [int][Math]::Round(($b + $m) * 255)
    '#FF{0:X2}{1:X2}{2:X2}' -f $ri, $gi, $bi
}

function Get-FallbackAccent($key) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $h = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) }
    finally { $md5.Dispose() }
    Convert-HslToRgb (($h[0] / 255.0) * 360) 0.72 0.62
}

# Lift a colour until its brightest channel reaches $target, so the accent
# always reads against the near-black panel.
function Get-LiftedColor([System.Drawing.Color]$c, [double]$target) {
    $mx = [Math]::Max($c.R, [Math]::Max($c.G, $c.B)) / 255.0
    if ($mx -le 0.02) { return $null }
    $f = $target / $mx
    if ($f -lt 1.0) { $f = 1.0 }
    $ri = [int][Math]::Min(255, [Math]::Round($c.R * $f))
    $gi = [int][Math]::Min(255, [Math]::Round($c.G * $f))
    $bi = [int][Math]::Min(255, [Math]::Round($c.B * $f))
    '#FF{0:X2}{1:X2}{2:X2}' -f $ri, $gi, $bi
}

# --------------------------------------------------------------- lrc --------

function ConvertFrom-Lrc([string]$text) {
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($text -split "`n")) {
        $stamps = [regex]::Matches($line, '\[(\d+):(\d+(?:[.:]\d+)?)\]')
        if ($stamps.Count -eq 0) { continue }
        $txt = ([regex]::Replace($line, '\[[^\]]*\]', '')).Trim()
        foreach ($m in $stamps) {
            $min = [int]$m.Groups[1].Value
            $sec = [double](($m.Groups[2].Value) -replace ':', '.')
            [void]$out.Add([pscustomobject]@{ Time = $min * 60 + $sec; Text = $txt })
        }
    }
    @($out | Sort-Object Time)
}

# Index of the last line starting at or before $pos, or -1 if $pos precedes
# the first line. Binary search so long lyric sheets stay cheap per frame.
function Find-ActiveLine($lines, [double]$pos) {
    $lo = 0; $hi = $lines.Count - 1; $best = -1
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        if ($lines[$mid].Time -le $pos) { $best = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    $best
}

# ------------------------------------------------------- lyrics worker ------

$Sync = [hashtable]::Synchronized(@{
        Req   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Res   = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
        Stop  = $false
    })

$WorkerScript = {
    param($sync, $lyricDir)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $hdr = @{ 'Lrclib-Client' = 'SpotifyFloatingSub v0.1 (https://github.com/local/SpotifyFloatingSub)' }

    # LRCLIB serves its JSON as a bare "application/json" with no charset, and
    # PowerShell 5.1's Invoke-RestMethod reads that as permission to decode the
    # body as Latin-1. Every UTF-8 multi-byte character then arrives as one
    # character per byte - a Chinese line comes back as three times as many
    # pieces of mojibake, which is what "no Chinese subtitles" looks like from
    # the outside. So fetch the bytes and decode them as UTF-8 ourselves.
    #
    # Invoke-WebRequest rather than WebClient because it still honours
    # -TimeoutSec, and -UseBasicParsing to keep the IE parsing engine (and its
    # possible first-run dialog) out of a background runspace.
    function Get-LrcJson([string]$url, $headers) {
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 12 -UseBasicParsing
        [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    }

    while (-not $sync.Stop) {
        $req = $null
        if (-not $sync.Req.TryDequeue([ref]$req)) {
            Start-Sleep -Milliseconds 100
            continue
        }
        $key = $req.Key
        if ($sync.Res.ContainsKey($key)) { continue }

        $hit = $null
        try {
            $url = 'https://lrclib.net/api/get?track_name={0}&artist_name={1}&album_name={2}&duration={3}' -f `
                [uri]::EscapeDataString($req.Title), [uri]::EscapeDataString($req.Artist), `
                [uri]::EscapeDataString($req.Album), [int][Math]::Round($req.Duration)
            $hit = Get-LrcJson $url $hdr
        } catch { }

        $q = [uri]::EscapeDataString(('{0} {1}' -f $req.Artist, $req.Title))

        if (-not $hit) {
            # No exact match at all -> fuzzy search, preferring anything timed.
            try {
                $hits = @(Get-LrcJson "https://lrclib.net/api/search?q=$q" $hdr | Where-Object { $_ })
                if ($hits.Count -gt 0) {
                    $synced = @($hits | Where-Object { $_.syncedLyrics })
                    $hit = if ($synced.Count -gt 0) { $synced[0] } else { $hits[0] }
                }
            } catch { }
        } elseif (-not $hit.syncedLyrics) {
            # Exact match, but unsynced. /api/get matches on album as well, so a
            # timed copy filed under a different album is invisible to it - and
            # without timings there is no wipe. Look for one that also agrees on
            # duration, using the same +/-2s rule /api/get applies, so a live or
            # cover version can't win and drag the wipe onto the wrong recording.
            try {
                $same = @(Get-LrcJson "https://lrclib.net/api/search?q=$q" $hdr | Where-Object {
                        $_ -and $_.syncedLyrics -and $_.duration -and
                        [Math]::Abs([double]$_.duration - [double]$req.Duration) -le 2.0 })
                if ($same.Count -gt 0) { $hit = $same[0] }
            } catch { }
        }

        $payload = @{
            Key          = $key
            Found        = $false
            Instrumental = $false
            Synced       = $null
            Plain        = $null
        }
        if ($hit) {
            $payload.Found = $true
            $payload.Instrumental = [bool]$hit.instrumental
            $payload.Synced = $hit.syncedLyrics
            $payload.Plain = $hit.plainLyrics
        }

        $json = $payload | ConvertTo-Json -Compress -Depth 4
        try {
            [System.IO.File]::WriteAllText((Join-Path $lyricDir "$key.json"), $json,
                (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        [void]$sync.Res.TryAdd($key, $json)
    }
}

$Runspace = [runspacefactory]::CreateRunspace()
$Runspace.ApartmentState = 'MTA'
$Runspace.ThreadOptions = 'ReuseThread'
$Runspace.Open()
$Runspace.SessionStateProxy.SetVariable('sync', $Sync)

$Worker = [powershell]::Create()
$Worker.Runspace = $Runspace
[void]$Worker.AddScript($WorkerScript).AddArgument($Sync).AddArgument($LyricDir)
$WorkerHandle = $Worker.BeginInvoke()

function Get-LyricsRecord($key) {
    $json = $null
    if ($Sync.Res.TryGetValue($key, [ref]$json)) {
        try { return ($json | ConvertFrom-Json) } catch { return $null }
    }
    $f = Join-Path $LyricDir "$key.json"
    if (Test-Path $f) {
        try {
            $json = [System.IO.File]::ReadAllText($f)
            [void]$Sync.Res.TryAdd($key, $json)
            return ($json | ConvertFrom-Json)
        } catch { return $null }
    }
    return $null
}

function Request-Lyrics($key, $title, $artist, $album, $duration) {
    if ($Sync.Res.ContainsKey($key)) { return }
    if (Test-Path (Join-Path $LyricDir "$key.json")) { return }
    $Sync.Req.Enqueue([pscustomobject]@{
            Key = $key; Title = $title; Artist = $artist; Album = $album; Duration = $duration
        })
}

# ------------------------------------------------------------ artwork -------

function Get-Artwork($thumbRef, $key) {
    $metaPath = Join-Path $ArtDir "$key.json"
    $pngPath = Join-Path $ArtDir "$key.png"

    # A cache entry is only good if the artwork came down with it; otherwise
    # (e.g. an earlier run failed mid-way) re-fetch rather than serve a stub.
    if ((Test-Path $metaPath) -and (Test-Path $pngPath)) {
        try {
            $m = [System.IO.File]::ReadAllText($metaPath) | ConvertFrom-Json
            return [pscustomobject]@{ Accent = $m.Accent; Png = $pngPath }
        } catch { }
    }

    $accent = $null
    $bytes = $null
    try {
        $ras = Await ($thumbRef.OpenReadAsync()) $StreamType
        $net = $AsStreamForRead.Invoke($null, @($ras))
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms)
        $bytes = $ms.ToArray()
        $ms.Dispose(); $net.Dispose()
        # $ras is a WinRT __ComObject with no callable Dispose from PowerShell;
        # let the RCW finalizer handle it.
    } catch {
        Write-Log "artwork read failed: $($_.Exception.Message)"
    }

    if ($bytes -and $bytes.Length -gt 0) {
        try {
            [System.IO.File]::WriteAllBytes($pngPath, $bytes)
        } catch { $pngPath = $null }

        try {
            $bmps = New-Object System.IO.MemoryStream(, $bytes)
            $bmp = [System.Drawing.Bitmap]::FromStream($bmps)
            $w = $bmp.Width; $h = $bmp.Height
            $step = [Math]::Max(1, [int][Math]::Floor([Math]::Min($w, $h) / 48))
            $best = $null; $bestScore = -1.0
            for ($y = 0; $y -lt $h; $y += $step) {
                for ($x = 0; $x -lt $w; $x += $step) {
                    $c = $bmp.GetPixel($x, $y)
                    $mx = [Math]::Max($c.R, [Math]::Max($c.G, $c.B))
                    if ($mx -eq 0) { continue }
                    $mn = [Math]::Min($c.R, [Math]::Min($c.G, $c.B))
                    $sat = ($mx - $mn) / [double]$mx
                    # favour vivid *and* reasonably bright pixels
                    $score = $sat * $sat * ($mx / 255.0)
                    if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
                }
            }
            if ($best) { $accent = Get-LiftedColor $best 0.74 }
            $bmp.Dispose(); $bmps.Dispose()
        } catch {
            Write-Log "palette failed: $($_.Exception.Message)"
        }
    }

    if (-not $accent) { $accent = Get-FallbackAccent $key }
    $png = $null
    if (Test-Path $pngPath) { $png = $pngPath }
    try {
        $m = @{ Accent = $accent } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($metaPath, $m, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    [pscustomobject]@{ Accent = $accent; Png = $png }
}

# ------------------------------------------------------------ selftest ------

if ($SelfTest) {
    # PowerShell 5.1 writes console output in the legacy ANSI codepage, so any
    # CJK lyric prints as '?' - which makes a perfectly good lookup look like a
    # failure. Force UTF-8 on the way out. (The overlay window is unaffected;
    # this is only about what the terminal shows.)
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

    Write-Host ''
    Write-Host 'FloatingSub self-test' -ForegroundColor Cyan
    Write-Host ('  config   : {0}' -f $ConfigPath)
    Write-Host ('  cache    : {0}' -f $CacheDir)

    # --- LRC parsing + line lookup, no network or playback needed ---
    $fx = ConvertFrom-Lrc "[00:08.47] first line`n[00:13.02] second line`n[01:02.50] third line`n"
    $checks = @(
        @{ n = 'parses 3 lines'; ok = ($fx.Count -eq 3) },
        @{ n = 'mm:ss.xx -> seconds'; ok = ([Math]::Abs($fx[0].Time - 8.47) -lt 0.001) },
        @{ n = 'handles >1 minute'; ok = ([Math]::Abs($fx[2].Time - 62.5) -lt 0.001) },
        @{ n = 'keeps line text'; ok = ($fx[1].Text -eq 'second line') },
        @{ n = 'before first line -> -1'; ok = ((Find-ActiveLine $fx 5.0) -eq -1) },
        @{ n = 'inside line 1 -> 0'; ok = ((Find-ActiveLine $fx 10.0) -eq 0) },
        @{ n = 'exact hit -> that line'; ok = ((Find-ActiveLine $fx 13.02) -eq 1) },
        @{ n = 'after last -> 2'; ok = ((Find-ActiveLine $fx 999.0) -eq 2) }
    )
    $bad = @($checks | Where-Object { -not $_.ok })
    if ($bad.Count -eq 0) {
        Write-Host ('  lrc core : {0}/{0} checks passed' -f $checks.Count) -ForegroundColor Green
    } else {
        Write-Host ('  lrc core : FAILED -> {0}' -f (($bad | ForEach-Object { $_.n }) -join '; ')) -ForegroundColor Red
    }

    $s = Get-SpotifySession
    if (-not $s) {
        Write-Host '  session  : NONE - start Spotify and play something.' -ForegroundColor Yellow
        $Worker.Stop(); $Runspace.Close()
        exit 1
    }
    $tl = $s.GetTimelineProperties()
    $info = $s.GetPlaybackInfo()
    $p = Await ($s.TryGetMediaPropertiesAsync()) $PropsType
    $dur = ($tl.EndTime - $tl.StartTime).TotalSeconds

    Write-Host ('  app      : {0}' -f $s.SourceAppUserModelId)
    Write-Host ('  track    : {0} - {1}' -f $p.Artist, $p.Title)
    Write-Host ('  album    : {0}' -f $p.AlbumTitle)
    Write-Host ('  status   : {0}   pos={1:n1}s  dur={2:n1}s' -f $info.PlaybackStatus, $tl.Position.TotalSeconds, $dur)

    $key = Get-TrackKey $p.Title $p.Artist $p.AlbumTitle $dur
    Write-Host ('  key      : {0}' -f $key)

    $art = Get-Artwork $p.Thumbnail $key
    Write-Host ('  accent   : {0}   art={1}' -f $art.Accent, $(if ($art.Png) { 'yes' } else { 'no' }))

    $rec = Get-LyricsRecord $key
    if (-not $rec) {
        Write-Host '  lyrics   : fetching...' -ForegroundColor DarkGray
        Request-Lyrics $key $p.Title $p.Artist $p.AlbumTitle $dur
        for ($i = 0; $i -lt 60 -and -not $rec; $i++) {
            Start-Sleep -Milliseconds 250
            $rec = Get-LyricsRecord $key
        }
    }

    if (-not $rec) { Write-Host '  lyrics   : request still pending' -ForegroundColor Yellow }
    elseif (-not $rec.Found) { Write-Host '  lyrics   : NOT FOUND on LRCLIB' -ForegroundColor Yellow }
    elseif ($rec.Instrumental) { Write-Host '  lyrics   : instrumental track' -ForegroundColor Yellow }
    elseif (-not $rec.Synced) { Write-Host ('  lyrics   : plain only ({0} chars)' -f $rec.Plain.Length) -ForegroundColor Yellow }
    else {
        $lines = ConvertFrom-Lrc $rec.Synced
        Write-Host ('  lyrics   : {0} synced lines' -f $lines.Count) -ForegroundColor Green
        $now = $tl.Position.TotalSeconds
        $shown = 0
        foreach ($l in $lines) {
            if ($l.Time -ge ($now - 6)) {
                $mark = if ($l.Time -le $now) { '>' } else { ' ' }
                Write-Host ('    {0} [{1,7:n2}]  {2}' -f $mark, $l.Time, $l.Text)
                $shown++
                if ($shown -ge 6) { break }
            }
        }
    }
    Write-Host ''
    $Sync.Stop = $true
    $Worker.Stop(); $Runspace.Close()
    exit 0
}

# ---------------------------------------------------------------- ui --------

$W = [int]$Cfg.width
$H = [int]$Cfg.height
$FS = [int]$Cfg.lyricFontSize
$NFS = [int]$Cfg.nextFontSize
$MFS = [int]$Cfg.metaFontSize
$Pad = 22
$Margin = 28
$ArtSize = 88
$ArtGap = 20
$BtnSize = 30
$PlaySize = 40
$BtnGap = 4
$BtnLead = 16
# Shuffle, prev, play/pause, next, repeat - the play button is the wide one.
$CtrlW = (4 * $BtnSize) + $PlaySize + (4 * $BtnGap)
# The controls only appear while the panel is interactive, but their width is
# always reserved - otherwise the lyric text would jump sideways every time the
# pointer crossed the panel.
$BtnBox = if ($Cfg.showControls) { $CtrlW + $BtnLead } else { 0 }
$TextW = $W - (2 * $Margin) - (2 * $Pad) - $ArtSize - $ArtGap - $BtnBox

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" Width="$W" Height="$H" Opacity="$($Cfg.opacity)">
  <Grid Margin="$Margin">
    <Border x:Name="Panel" CornerRadius="20" Padding="$Pad,18" BorderThickness="1">
      <Border.Effect>
        <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.9" Color="#000000"/>
      </Border.Effect>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="ArtFrame" Grid.Column="0" Width="$ArtSize" Height="$ArtSize"
                CornerRadius="14" Margin="0,0,$ArtGap,0" VerticalAlignment="Center"
                Background="#1AFFFFFF">
          <Border.Effect>
            <DropShadowEffect BlurRadius="16" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
          </Border.Effect>
          <Image x:Name="ArtImage" Stretch="UniformToFill"/>
        </Border>
        <StackPanel x:Name="TextStack" Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="MetaText" FontSize="$MFS" FontWeight="SemiBold"
                     Foreground="#8CFFFFFF" FontFamily="Segoe UI"
                     HorizontalAlignment="Center" MaxWidth="$TextW"
                     TextTrimming="CharacterEllipsis"/>
          <Grid x:Name="LyricRow" Margin="0,2,0,0">
            <TextBlock x:Name="LyricBase" FontSize="$FS" FontWeight="Bold" FontFamily="Segoe UI"
                       Foreground="#40FFFFFF" HorizontalAlignment="Center"
                       MaxWidth="$TextW" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="LyricFill" FontSize="$FS" FontWeight="Bold" FontFamily="Segoe UI"
                       HorizontalAlignment="Center" MaxWidth="$TextW"
                       TextTrimming="CharacterEllipsis"/>
          </Grid>
          <TextBlock x:Name="NextText" FontSize="$NFS" FontFamily="Segoe UI"
                     Foreground="#59FFFFFF" HorizontalAlignment="Center"
                     MaxWidth="$TextW" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel x:Name="BtnRow" Grid.Column="2" VerticalAlignment="Center"
                    Margin="$BtnLead,0,0,0" Opacity="0" IsHitTestVisible="False">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <Border x:Name="BtnShuffle" Width="$BtnSize" Height="$BtnSize" Background="Transparent">
              <Grid>
                <Path x:Name="IcoShuffle" Stroke="#B3FFFFFF" StrokeThickness="1.5"
                      StrokeLineJoin="Round" Width="16" Height="16" Stretch="None"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Data="M2,4.5 H5 L10.5,11.5 H14 M11.6,9.4 L14,11.5 L11.6,13.6 M2,11.5 H5 L10.5,4.5 H14 M11.6,2.4 L14,4.5 L11.6,6.6"/>
                <Ellipse x:Name="DotShuffle" Width="3.5" Height="3.5" Fill="#FF1ED760"
                         HorizontalAlignment="Center" VerticalAlignment="Bottom"
                         Margin="0,0,0,1" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <Border x:Name="BtnPrev" Width="$BtnSize" Height="$BtnSize" Background="Transparent">
              <Path Fill="#FFFFFFFF" Width="16" Height="16" Stretch="None"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Data="M3,4 H5 V12 H3 Z M13,4 L6,8 L13,12 Z"/>
            </Border>
            <Border x:Name="BtnPlay" Width="$PlaySize" Height="$PlaySize" CornerRadius="20"
                    Background="#FFFFFFFF" Margin="$BtnGap,0,$BtnGap,0">
              <Grid Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Path x:Name="IcoPlay" Fill="#FF121212" Stretch="None"
                      Data="M5,3.4 L13.2,8 L5,12.6 Z"/>
                <Path x:Name="IcoPause" Fill="#FF121212" Stretch="None" Visibility="Collapsed"
                      Data="M4.6,3.4 H7.2 V12.6 H4.6 Z M8.8,3.4 H11.4 V12.6 H8.8 Z"/>
              </Grid>
            </Border>
            <Border x:Name="BtnNext" Width="$BtnSize" Height="$BtnSize" Background="Transparent">
              <Path Fill="#FFFFFFFF" Width="16" Height="16" Stretch="None"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Data="M3,4 L10,8 L3,12 Z M11,4 H13 V12 H11 Z"/>
            </Border>
            <Border x:Name="BtnRepeat" Width="$BtnSize" Height="$BtnSize" Background="Transparent">
              <Grid>
                <Path x:Name="IcoRepeat" Stroke="#B3FFFFFF" StrokeThickness="1.5"
                      StrokeLineJoin="Round" Width="16" Height="16" Stretch="None"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Data="M4,5.5 H11 V10.5 H4 Z"/>
                <Path x:Name="IcoRepeatArrow" Stroke="#B3FFFFFF" StrokeThickness="1.5"
                      StrokeLineJoin="Round" Width="16" Height="16" Stretch="None"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Data="M11.4,3.5 L13.8,5.5 L11.4,7.5"/>
                <Ellipse x:Name="DotRepeat" Width="3.5" Height="3.5" Fill="#FF1ED760"
                         HorizontalAlignment="Center" VerticalAlignment="Bottom"
                         Margin="0,0,0,1" Visibility="Collapsed"/>
              </Grid>
            </Border>
          </StackPanel>
          <Grid Margin="0,7,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="PosText" Grid.Column="0" FontSize="11" FontFamily="Segoe UI"
                       Foreground="#8CFFFFFF" VerticalAlignment="Center"/>
            <Grid x:Name="ProgTrack" Grid.Column="1" Height="3" Margin="7,0,7,0" VerticalAlignment="Center">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="0*"/>
                <ColumnDefinition Width="1*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="ProgFill" Grid.Column="0" Background="#F2FFFFFF" CornerRadius="1.5"/>
              <Border x:Name="ProgRest" Grid.Column="1" Background="#3DFFFFFF" CornerRadius="1.5"/>
            </Grid>
            <TextBlock x:Name="DurText" Grid.Column="2" FontSize="11" FontFamily="Segoe UI"
                       Foreground="#8CFFFFFF" VerticalAlignment="Center"/>
          </Grid>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$Win = [Windows.Markup.XamlReader]::Parse($xaml)

$Panel = $Win.FindName('Panel')
$ArtFrame = $Win.FindName('ArtFrame')
$ArtImage = $Win.FindName('ArtImage')
$MetaText = $Win.FindName('MetaText')
$LyricRow = $Win.FindName('LyricRow')
$LyricBase = $Win.FindName('LyricBase')
$LyricFill = $Win.FindName('LyricFill')
$NextText = $Win.FindName('NextText')
$TextStack = $Win.FindName('TextStack')
$BtnRow = $Win.FindName('BtnRow')
$BtnShuffle = $Win.FindName('BtnShuffle')
$BtnPrev = $Win.FindName('BtnPrev')
$BtnPlay = $Win.FindName('BtnPlay')
$BtnNext = $Win.FindName('BtnNext')
$BtnRepeat = $Win.FindName('BtnRepeat')
$IcoShuffle = $Win.FindName('IcoShuffle')
$IcoPlay = $Win.FindName('IcoPlay')
$IcoPause = $Win.FindName('IcoPause')
$IcoRepeat = $Win.FindName('IcoRepeat')
$IcoRepeatArrow = $Win.FindName('IcoRepeatArrow')
$DotShuffle = $Win.FindName('DotShuffle')
$DotRepeat = $Win.FindName('DotRepeat')
$PosText = $Win.FindName('PosText')
$DurText = $Win.FindName('DurText')
$ProgTrack = $Win.FindName('ProgTrack')
$ProgFill = $Win.FindName('ProgFill')
$ProgRest = $Win.FindName('ProgRest')

# Brushes are built here rather than in XAML: GradientBrush.GradientStops does not
# resolve reliably through XamlReader + FindName, and the karaoke wipe needs
# mutable stops anyway.
function New-Stop([string]$hex, [double]$offset) {
    New-Object System.Windows.Media.GradientStop(
        [System.Windows.Media.ColorConverter]::ConvertFromString($hex), $offset)
}
function New-Solid([string]$hex) {
    New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}
function New-Gradient([double]$x1, [double]$y1, [double]$x2, [double]$y2, $stops) {
    # GradientBrush.GradientStops is null on a default-constructed brush - the
    # collection has to be built up front and handed to the constructor.
    $col = New-Object System.Windows.Media.GradientStopCollection
    foreach ($s in $stops) { [void]$col.Add($s) }
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.GradientStops = $col
    $b.StartPoint = New-Object System.Windows.Point($x1, $y1)
    $b.EndPoint = New-Object System.Windows.Point($x2, $y2)
    $b
}

# The panel's own alpha is separate from Window.Opacity: this way the glass
# behind the text can be see-through while the text itself stays fully opaque.
# (Window.Opacity fades text and panel together.)
$PanelA = [int][Math]::Round(([Math]::Max(0.0, [Math]::Min(1.0, [double]$Cfg.panelAlpha))) * 255)
$Panel.Background = New-Gradient 0 0 1 1 @(
    (New-Stop ('#{0:X2}0A0A10' -f $PanelA) 0.0),
    (New-Stop ('#{0:X2}180A20' -f $PanelA) 1.0))

# With the fill gone the panel's drop shadow has nothing to sit behind - it
# would be cast by the 1px border alone, leaving a blurred rectangle outline
# floating in mid-air. Drop it and shadow the text instead, which is what
# actually needs separating from whatever is behind it.
#
# This is deferred until after the lyric brushes exist, so that the unsung
# colour can be raised at the same time. See the see-through block below.

$EdgeBrush = New-Gradient 0 0 1 1 @((New-Stop '#803DF2C0' 0.0), (New-Stop '#223DF2C0' 1.0))
$Panel.BorderBrush = $EdgeBrush
$EdgeStops = $EdgeBrush.GradientStops

# Stops [0],[1] are the sung (accent) span and [2],[3] the unsung span; [1]
# and [2] meet to form the moving boundary of the karaoke wipe.
$FillBrush = New-Gradient 0 0 1 0 @(
    (New-Stop '#FF3DF2C0' 0.0),
    (New-Stop '#FF3DF2C0' 0.0),
    (New-Stop '#40FFFFFF' 0.0),
    (New-Stop '#40FFFFFF' 1.0))
$LyricFill.Foreground = $FillBrush
$FillStops = $FillBrush.GradientStops

$Glow = New-Object System.Windows.Media.Effects.DropShadowEffect
$Glow.BlurRadius = 14
$Glow.ShadowDepth = 0
$Glow.Opacity = 0.55
$Glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#3DF2C0')
$LyricFill.Effect = $Glow

# ---- see-through mode -----------------------------------------------------
#
# Every alpha below is tuned to dim text *into* a dark panel. With the panel
# transparent there is nothing to dim into, so those colours read as "almost
# invisible" over light content - the sung lyric survives (it is opaque accent)
# while the unsung half of the same line vanishes. So: drop the border, which
# would otherwise float as a bare rounded outline, raise the dim alphas towards
# opaque, and put the job of separating text from the desktop onto a shadow.
if ($PanelA -le 5) {
    $Panel.Effect = $null
    $Panel.BorderThickness = 0

    $TextShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $TextShadow.BlurRadius = 14
    $TextShadow.ShadowDepth = 0
    $TextShadow.Opacity = 1.0
    $TextShadow.Color = [System.Windows.Media.Colors]::Black
    $TextStack.Effect = $TextShadow

    $Unsung = New-Solid '#C4FFFFFF'
    $LyricBase.Foreground = $Unsung
    $FillStops[2].Color = $Unsung.Color
    $FillStops[3].Color = $Unsung.Color
    $MetaText.Foreground = New-Solid '#B8FFFFFF'
    $NextText.Foreground = New-Solid '#A6FFFFFF'

    # The icons and the progress bar are white-on-transparent too, so they need
    # the same halo - raising their alpha cannot help, since white on white is
    # invisible at any opacity.
    $CtrlShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $CtrlShadow.BlurRadius = 8
    $CtrlShadow.ShadowDepth = 0
    $CtrlShadow.Opacity = 0.9
    $CtrlShadow.Color = [System.Windows.Media.Colors]::Black
    $BtnRow.Effect = $CtrlShadow

    # The times and the bar's unfilled remainder sit at ~55% and ~24% white,
    # which is legible against a dark panel and all but gone against paper.
    $PosText.Foreground = New-Solid '#E6FFFFFF'
    $DurText.Foreground = New-Solid '#E6FFFFFF'
    $ProgFill.Background = New-Solid '#FFFFFFFF'
    $ProgRest.Background = New-Solid '#80FFFFFF'
}

$Slide = New-Object System.Windows.Media.TranslateTransform
$LyricRow.RenderTransform = $Slide

if (-not $Cfg.showAlbumArt) { $ArtFrame.Visibility = 'Collapsed' }

# ---- state ----------------------------------------------------------------

$S = @{
    Key        = $null
    Title      = ''
    Artist     = ''
    Album      = ''
    Duration   = 0.0
    Status     = 'Closed'
    AnchorPos  = 0.0
    AnchorWall = [DateTime]::UtcNow
    Lines      = @()
    ActiveIdx  = -1
    Accent     = '#FF3DF2C0'
    ArtKey     = $null
    Playing    = $false
    Shuffle    = $false
    Repeat     = 'None'
    PosLabel   = ''
    DurLabel   = ''
    Interactive = ($Cfg.dragMode -eq 'always')
    # $null = follow dragMode, $true = pinned grabbable by the hotkey.
    ForceInteractive = $null
    Dragging   = $false
    DpiX       = 0.0
    DpiY       = 0.0
}

function Set-Accent([string]$hex) {
    if (-not $hex) { return }
    $S.Accent = $hex
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $FillStops[0].Color = $c
    $FillStops[1].Color = $c
    $Glow.Color = $c
    $dim = [System.Windows.Media.Color]::FromArgb(0x22, $c.R, $c.G, $c.B)
    $bright = [System.Windows.Media.Color]::FromArgb(0x80, $c.R, $c.G, $c.B)
    $EdgeStops[0].Color = $bright
    $EdgeStops[1].Color = $dim
}

function Set-Interactive([bool]$on) {
    $S.Interactive = $on
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $ex = [Native]::GetWindowLong($h, $GWL_EXSTYLE)
    if ($on) { $ex = $ex -band (-bnot $WS_EX_TRANSPARENT) }
    else { $ex = $ex -bor $WS_EX_TRANSPARENT }
    [void][Native]::SetWindowLong($h, $GWL_EXSTYLE, $ex)
    # A move cursor is the only cue that the panel can be grabbed, since the
    # window has no chrome at all.
    try { $Panel.Cursor = if ($on) { [System.Windows.Input.Cursors]::SizeAll } else { $null } } catch { }
    # Opacity rather than Visibility: the controls' width stays reserved either
    # way, so the lyric line never shifts when they fade in.
    try {
        $BtnRow.Opacity = if ($on) { 1.0 } else { 0.0 }
        $BtnRow.IsHitTestVisible = $on
    } catch { }
    Write-Log ("interactive={0}" -f $on)
}

# GetCursorPos hands back raw screen pixels; WPF positions everything in DIPs.
# VisualTreeHelper.GetDpi gives the exact factor WPF itself used to convert,
# so this stays correct whatever DPI awareness the host process has.
function Set-DpiScale {
    try {
        $d = [System.Windows.Media.VisualTreeHelper]::GetDpi($Win)
        $S.DpiX = [double]$d.DpiScaleX
        $S.DpiY = [double]$d.DpiScaleY
    } catch { $S.DpiX = 1.0; $S.DpiY = 1.0 }
    if ($S.DpiX -le 0) { $S.DpiX = 1.0 }
    if ($S.DpiY -le 0) { $S.DpiY = 1.0 }
}

function Test-CursorOnPanel {
    if (-not $Win.IsLoaded) { return $false }
    if ($S.DpiX -le 0) { Set-DpiScale }
    $pt = New-Object POINT
    if (-not [Native]::GetCursorPos([ref]$pt)) { return $false }
    $x = $pt.X / $S.DpiX
    $y = $pt.Y / $S.DpiY
    try { $o = $Panel.TranslatePoint((New-Object System.Windows.Point(0, 0)), $Win) }
    catch { return $false }
    # A little slack: the panel is a thin strip, and the cursor has to cross
    # the transparent margin around it to get there.
    $slack = 8
    $l = $Win.Left + $o.X - $slack
    $t = $Win.Top + $o.Y - $slack
    ($x -ge $l -and $x -le ($l + $Panel.ActualWidth + 2 * $slack) -and
     $y -ge $t -and $y -le ($t + $Panel.ActualHeight + 2 * $slack))
}

# Keeps the window reachable. DragMove will happily park the panel half off the
# screen, and a floating window with no taskbar button is then very hard to get
# back - so pin the whole panel inside the desktop (all monitors, not just the
# primary work area, so a second monitor still works).
function Get-ClampedPos([double]$l, [double]$t) {
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vr = $vl + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vb = $vt + [System.Windows.SystemParameters]::VirtualScreenHeight
    $maxL = [Math]::Max($vl, $vr - $W)
    $maxT = [Math]::Max($vt, $vb - $H)
    New-Object System.Windows.Point(
        [Math]::Max($vl, [Math]::Min($l, $maxL)),
        [Math]::Max($vt, [Math]::Min($t, $maxT)))
}

# Decides whether the window should accept the mouse right now, and only pokes
# the ex-style when the answer changes.
function Update-Interactive {
    if ($S.Dragging) { return }
    if ($null -ne $S.ForceInteractive) { $want = [bool]$S.ForceInteractive }
    elseif ($Cfg.dragMode -eq 'always') { $want = $true }
    elseif ($Cfg.dragMode -eq 'hotkey') { $want = $false }
    else { $want = Test-CursorOnPanel }
    # Faded out with Ctrl+Alt+K means gone; don't leave an invisible window
    # swallowing clicks.
    if ($Win.Opacity -le 0.01) { $want = $false }
    if ($want -ne $S.Interactive) { Set-Interactive $want }
}

function Set-IdleLine([string]$text) {
    $LyricBase.Text = $text
    $LyricFill.Text = $text
    $FillStops[1].Offset = 1.0
    $FillStops[2].Offset = 1.0
}

# ---- controls -------------------------------------------------------------

$CtrlGreen = New-Solid '#FF1ED760'
$CtrlDim = New-Solid '#B3FFFFFF'

function Set-CtrlActive($path, [bool]$on) {
    $path.Stroke = if ($on) { $CtrlGreen } else { $CtrlDim }
}

# Mirrors the transport bar in the Spotify client: shuffle, prev, play/pause,
# next, repeat, with the same colour language (green + a dot when shuffle is on,
# green for any repeat mode, a dot only for repeat-one).
function Update-Controls {
    if (-not $Cfg.showControls) { return }
    try {
        if ($S.Playing) { $IcoPlay.Visibility = 'Collapsed'; $IcoPause.Visibility = 'Visible' }
        else { $IcoPlay.Visibility = 'Visible'; $IcoPause.Visibility = 'Collapsed' }

        Set-CtrlActive $IcoShuffle $S.Shuffle
        $DotShuffle.Visibility = if ($S.Shuffle) { 'Visible' } else { 'Collapsed' }

        $repOn = ($S.Repeat -ne 'None')
        Set-CtrlActive $IcoRepeat $repOn
        Set-CtrlActive $IcoRepeatArrow $repOn
        $DotRepeat.Visibility = if ($S.Repeat -eq 'Track') { 'Visible' } else { 'Collapsed' }
    } catch { Write-Log "controls: $($_.Exception.Message)" }
}

function Format-Time([double]$t) {
    if ($t -lt 0) { $t = 0 }
    $s = [int][Math]::Floor($t)
    '{0}:{1:00}' -f [int]($s / 60), ($s % 60)
}

# Elapsed and total either side of the bar, as Spotify draws them.
function Update-Progress([double]$pos) {
    if (-not $Cfg.showControls) { return }
    try {
        $p = Format-Time $pos
        if ($p -ne $S.PosLabel) { $S.PosLabel = $p; $PosText.Text = $p }
        $d = Format-Time $S.Duration
        if ($d -ne $S.DurLabel) { $S.DurLabel = $d; $DurText.Text = $d }

        $frac = if ($S.Duration -gt 0) { $pos / $S.Duration } else { 0.0 }
        if ($frac -lt 0) { $frac = 0.0 } elseif ($frac -gt 1) { $frac = 1.0 }
        # The inner parens around each value are load-bearing: `,` binds tighter
        # than `-`, so without them `1.0 - $frac, $type` parses as
        # `1.0 - @($frac, $type)` and fails with "Object[] has no op_Subtraction".
        $ProgTrack.ColumnDefinitions[0].Width =
            New-Object System.Windows.GridLength(($frac), [System.Windows.GridUnitType]::Star)
        $ProgTrack.ColumnDefinitions[1].Width =
            New-Object System.Windows.GridLength((1.0 - $frac), [System.Windows.GridUnitType]::Star)
    } catch {
        Write-Log ('progress: {0} @line {1}: {2} (frac={3}/{4})' -f $_.Exception.Message,
            $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim(),
            $frac, $(if ($null -eq $frac) { 'null' } else { $frac.GetType().Name }))
    }
}

# ---- transport ------------------------------------------------------------

# Every one of these is a request, not a command: SMTC returns false if the
# session does not support the action, so log the answer rather than assuming.
function Invoke-Transport([string]$what) {
    try {
        $sess = Get-SpotifySession
        if (-not $sess) { Write-Log "transport ${what}: no active session"; return }
        $info = $sess.GetPlaybackInfo()

        switch ($what) {
            'shuffle' {
                $on = if ($null -ne $info.IsShuffleActive) { [bool]$info.IsShuffleActive } else { $false }
                $op = $sess.TryChangeShuffleActiveAsync(-not $on)
            }
            'prev' { $op = $sess.TrySkipPreviousAsync() }
            'play' { $op = $sess.TryTogglePlayPauseAsync() }
            'next' { $op = $sess.TrySkipNextAsync() }
            'repeat' {
                # Cycles the way the Spotify client does: off -> all -> one -> off
                $T = [Windows.Media.MediaPlaybackAutoRepeatMode]
                $mode = switch ("$($info.AutoRepeatMode)") {
                    'None' { $T::List }
                    'List' { $T::Track }
                    default { $T::None }
                }
                $op = $sess.TryChangeAutoRepeatModeAsync($mode)
            }
        }
        $ok = Await $op ([bool])
        Write-Log ("transport {0}: accepted={1}" -f $what, $ok)
        Update-Playback
    } catch { Write-Log "transport ${what} failed: $($_.Exception.Message)" }
}

# ---- track change ---------------------------------------------------------

function Update-Track($title, $artist, $album, $duration, $thumbRef) {
    $key = Get-TrackKey $title $artist $album $duration
    if ($key -eq $S.Key) { return }

    $S.Key = $key
    $S.Title = $title; $S.Artist = $artist; $S.Album = $album
    $S.Duration = $duration
    $S.Lines = @()
    $S.ActiveIdx = -1

    $meta = if ($artist) { '{0}  -  {1}' -f $title, $artist } else { $title }
    $MetaText.Text = $meta

    Set-IdleLine '...'
    $NextText.Text = ''

    if ($thumbRef -and $Cfg.showAlbumArt) {
        $art = Get-Artwork $thumbRef $key
        Set-Accent $art.Accent
        if ($art.Png) {
            try {
                $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                $bi.BeginInit()
                $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bi.UriSource = New-Object System.Uri($art.Png)
                $bi.EndInit()
                $bi.Freeze()
                $ArtImage.Source = $bi
            } catch { Write-Log "art load failed: $($_.Exception.Message)"; $ArtImage.Source = $null }
        }
    } else {
        Set-Accent (Get-FallbackAccent $key)
    }

    $rec = Get-LyricsRecord $key
    if ($rec) { Apply-Lyrics $rec } else { Request-Lyrics $key $title $artist $album $duration }
}

function Apply-Lyrics($rec) {
    if (-not $rec.Found) {
        Set-IdleLine $S.Title
        $NextText.Text = 'no lyrics found on LRCLIB'
        $S.Lines = @()
        return
    }
    if ($rec.Instrumental) {
        Set-IdleLine $S.Title
        $NextText.Text = '~ instrumental ~'
        $S.Lines = @()
        return
    }
    if ($rec.Synced) {
        $S.Lines = ConvertFrom-Lrc $rec.Synced
        if ($S.Lines.Count -gt 0) { $S.ActiveIdx = -1; return }
    }
    # Only unsynced lyrics exist, so there is nothing to wipe against. Show
    # the track itself rather than an arbitrary static line from the sheet.
    Set-IdleLine $S.Title
    if ($rec.Plain) { $NextText.Text = 'no synced lyrics for this track' }
    else { $NextText.Text = 'no lyrics found on LRCLIB' }
    $S.Lines = @()
}

# ---- render ---------------------------------------------------------------

$Fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(240))
$Rise = New-Object System.Windows.Media.Animation.DoubleAnimation(7.0, 0.0, [TimeSpan]::FromMilliseconds(300))

function Show-Line([int]$idx) {
    $lines = $S.Lines
    if ($idx -lt 0 -or $idx -ge $lines.Count) { return }
    $t = $lines[$idx].Text
    $LyricBase.Text = $t
    $LyricFill.Text = $t
    if ($idx + 1 -lt $lines.Count) { $NextText.Text = $lines[$idx + 1].Text } else { $NextText.Text = '' }
    $LyricRow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $Fade)
    $Slide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $Rise)
}

$PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds([int]$Cfg.pollMs)

# Between polls the position is interpolated locally, which is smoother than
# SMTC's update granularity. So re-anchor only on a real discontinuity - a seek,
# or a play/pause transition ($force). Now that the measured value is corrected
# for its age (see Get-PlaybackPosition) it is accurate to well under a frame,
# so this threshold only has to tell a seek from ordinary jitter.
$CLOCK_JUMP = 0.35

# SMTC's TimelineProperties.Position is a step function: it is only refreshed
# every few seconds, and in between it keeps reporting the value from the last
# refresh. LastUpdatedTime records when that value was true, so adding the age
# turns it into the position *now*. Without this the clock re-anchored to a
# reading up to ~4.5s stale and snapped the lyrics backwards on every poll -
# which is exactly what "slightly out of sync" looks like.
function Get-PlaybackPosition($tl, [string]$status) {
    $p = $tl.Position.TotalSeconds
    if ($status -eq 'Playing') {
        $age = ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds
        # A nonsense age means a clock/session hiccup; ignoring it is better
        # than jumping the lyrics somewhere arbitrary.
        if ($age -ge 0 -and $age -le 30) { $p += $age }
    }
    # Subtracted, not added: this is the playback clock, and the line shown is
    # the last one whose timestamp has passed. Making the clock read earlier
    # makes every line appear later, which is the direction you want when the
    # lyrics are running ahead of the singing.
    $p - ([double]$Cfg.syncOffsetMs / 1000.0)
}

function Sync-Clock([double]$measured, [double]$rate, [bool]$force) {
    $pred = $S.AnchorPos + ([DateTime]::UtcNow - $S.AnchorWall).TotalSeconds * $rate
    if ($force -or [Math]::Abs($measured - $pred) -gt $CLOCK_JUMP) {
        $S.AnchorPos = $measured
        $S.AnchorWall = [DateTime]::UtcNow
    }
}

# A function rather than an inline handler so the transport buttons can force a
# refresh the moment they are clicked, instead of waiting out the poll interval.
function Update-Playback {
    try {
        $sess = Get-SpotifySession
        if (-not $sess) {
            if ($S.Key -ne $null) {
                $S.Key = $null; $S.Lines = @(); $S.ActiveIdx = -1
                $S.Playing = $false
                $S.PosLabel = ''; $S.DurLabel = ''
                Update-Controls
                $MetaText.Text = ''
                Set-IdleLine 'Spotify is not playing'
                $NextText.Text = ''
                $ArtImage.Source = $null
                $PosText.Text = ''; $DurText.Text = ''
            }
            return
        }

        $tl = $sess.GetTimelineProperties()
        $info = $sess.GetPlaybackInfo()
        $p = Await ($sess.TryGetMediaPropertiesAsync()) $PropsType

        $dur = ($tl.EndTime - $tl.StartTime).TotalSeconds
        $status = $info.PlaybackStatus.ToString()
        $pos = Get-PlaybackPosition $tl $status

        $prevKey = $S.Key
        Update-Track $p.Title $p.Artist $p.AlbumTitle $dur $p.Thumbnail

        $prevStatus = $S.Status
        $S.Status = $status
        $S.Playing = ($status -eq 'Playing')
        # IsShuffleActive and AutoRepeatMode are nullable; absent means the
        # session does not report them, which is not the same as "off".
        $S.Shuffle = ($null -ne $info.IsShuffleActive -and [bool]$info.IsShuffleActive)
        $S.Repeat = if ($null -eq $info.AutoRepeatMode) { 'None' } else { "$($info.AutoRepeatMode)" }
        Update-Controls

        $rate = if ($status -eq 'Playing') { 1.0 } else { 0.0 }
        # A track change is a discontinuity in its own right. On a short track
        # the step can be small enough to slip under CLOCK_JUMP, so say so
        # rather than relying on the threshold to notice.
        Sync-Clock $pos $rate ($prevStatus -ne $status -or $prevKey -ne $S.Key)

        if ($S.Lines.Count -eq 0 -and $S.Key) {
            $rec = Get-LyricsRecord $S.Key
            if ($rec) { Apply-Lyrics $rec }
        }
    } catch {
        Write-Log ('poll: {0} @line {1}: {2}' -f $_.Exception.Message,
            $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
}

$PollTimer.Add_Tick({ Update-Playback })

$FrameTimer = New-Object System.Windows.Threading.DispatcherTimer
$FrameTimer.Interval = [TimeSpan]::FromMilliseconds([int]$Cfg.frameMs)

$FrameTimer.Add_Tick({
        try {
            $rate = if ($S.Status -eq 'Playing') { 1.0 } else { 0.0 }
            $pos = $S.AnchorPos + ([DateTime]::UtcNow - $S.AnchorWall).TotalSeconds * $rate
            if ($pos -lt 0) { $pos = 0.0 }
            if ($S.Duration -gt 0) { $pos = [Math]::Min($pos, $S.Duration) }

            # The progress bar runs off the interpolated clock, so it moves
            # smoothly rather than stepping once every few seconds.
            Update-Progress $pos

            if ($S.Lines.Count -eq 0) { return }

            $idx = Find-ActiveLine $S.Lines $pos
            if ($idx -ne $S.ActiveIdx) {
                $S.ActiveIdx = $idx
                if ($idx -ge 0) { Show-Line $idx }
            }

            if ($idx -ge 0) {
                $start = $S.Lines[$idx].Time
                if ($idx + 1 -lt $S.Lines.Count) { $end = $S.Lines[$idx + 1].Time }
                else { $end = $S.Duration }
                $span = $end - $start
                $prog = if ($span -gt 0.15) { ($pos - $start) / $span } else { 1.0 }
                if ($prog -lt 0) { $prog = 0 } elseif ($prog -gt 1) { $prog = 1 }
                $FillStops[1].Offset = $prog
                $FillStops[2].Offset = $prog
            }
        } catch {
            Write-Log ('frame: {0} @line {1}: {2}' -f $_.Exception.Message,
                $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
        }
    })

# ---- window chrome --------------------------------------------------------

$Win.Add_SourceInitialized({
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
        Set-DpiScale
        Set-Interactive $S.Interactive

        # HwndSourceHook returns IntPtr and takes 'handled' by ref. The
        # scriptblock must emit exactly one IntPtr - returning $true/$false
        # throws on the first message and takes the whole app down.
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
        $src.AddHook([System.Windows.Interop.HwndSourceHook] {
                param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
                if ($msg -eq $WM_HOTKEY) {
                    $id = [int]$wParam
                    try {
                        if ($id -eq 1) {
                            # Two-state: pin the panel grabbable, or hand it
                            # back to the hover test. Pinning is what makes it
                            # draggable in 'hotkey' mode, and what lets you grab
                            # it in 'hover' mode without racing the cursor poll.
                            if ($null -eq $S.ForceInteractive) { $S.ForceInteractive = $true }
                            else { $S.ForceInteractive = $null }
                            Update-Interactive
                        }
                        elseif ($id -eq 2) {
                            # Hide() would end the ShowDialog modal loop and
                            # quit the app, so fade to fully transparent.
                            if ($Win.Opacity -gt 0.01) { $Win.Opacity = 0.0 }
                            else { $Win.Opacity = [double]$Cfg.opacity }
                            Update-Interactive
                        }
                    } catch { Write-Log "hotkey: $($_.Exception.Message)" }
                    $handled.Value = $true
                }
                [IntPtr]::Zero
            })

        # Registration fails if another app already owns the combo, which is
        # otherwise invisible - so say so rather than silently doing nothing.
        foreach ($hk in @(@{ id = 1; spec = $Cfg.hotkey; what = 'pin draggable' },
                @{ id = 2; spec = $Cfg.hotkeyToggle; what = 'fade in/out' })) {
            $p = Parse-Hotkey $hk.spec
            if (-not $p) {
                Write-Log ("hotkey '{0}' ({1}) could not be parsed" -f $hk.spec, $hk.what)
                continue
            }
            $ok = [Native]::RegisterHotKey($h, $hk.id, $p.Mods, $p.Vk)
            if (-not $ok) {
                Write-Log ("hotkey '{0}' ({1}) is already taken by another app" -f $hk.spec, $hk.what)
            }
        }
    })

# ---- transport buttons ----------------------------------------------------

if ($Cfg.showControls) {
    # Border + Path rather than Button: no template to fight with, and the
    # glyphs are plain geometry so there is no icon-font fallback to go wrong.
    $ctrl = @(
        @{ el = $BtnShuffle; act = 'shuffle'; base = 'Transparent'; hover = '#26FFFFFF' }
        @{ el = $BtnPrev; act = 'prev'; base = 'Transparent'; hover = '#26FFFFFF' }
        @{ el = $BtnPlay; act = 'play'; base = '#FFFFFFFF'; hover = '#D9FFFFFF' }
        @{ el = $BtnNext; act = 'next'; base = 'Transparent'; hover = '#26FFFFFF' }
        @{ el = $BtnRepeat; act = 'repeat'; base = 'Transparent'; hover = '#26FFFFFF' })
    foreach ($c in $ctrl) {
        $c.el.Cursor = [System.Windows.Input.Cursors]::Hand
        $c.el.Tag = $c
        $c.el.Add_MouseEnter({ $args[0].Background = New-Solid $args[0].Tag.hover })
        $c.el.Add_MouseLeave({ $args[0].Background = New-Solid $args[0].Tag.base })
        $c.el.Add_MouseLeftButtonUp({ Invoke-Transport $args[0].Tag.act })
    }
}

$Win.Add_MouseLeftButtonDown({
        if (-not $S.Interactive) { return }
        # A click on the transport row is a click on a button, not the start of
        # a drag - without this the panel would slide out from under the cursor.
        if ($BtnRow.IsMouseOver) { return }
        $S.Dragging = $true
        try {
            $Win.DragMove()
            $p = Get-ClampedPos $Win.Left $Win.Top
            $Win.Left = $p.X; $Win.Top = $p.Y
            $Cfg.left = [int]$p.X
            $Cfg.top = [int]$p.Y
            Save-Config $Cfg
        } catch { Write-Log "drag: $($_.Exception.Message)" }
        finally {
            # DragMove pumps messages, and once the cursor is over the desktop
            # rather than the panel the hover poll would make the window
            # click-through mid-drag. Hold it interactive until the drag ends.
            $S.Dragging = $false
            Update-Interactive
        }
    })

# The window is click-through by default, so it sees no mouse events at all and
# has to poll for the cursor instead of using MouseEnter/MouseLeave.
$HoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$HoverTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$HoverTimer.Add_Tick({
        try { Update-Interactive }
        catch { Write-Log "hover: $($_.Exception.Message)" }
    })

$Win.Add_Closed({
        try {
            $Cfg.left = [int]$Win.Left
            $Cfg.top = [int]$Win.Top
            Save-Config $Cfg
        } catch { }
        $Sync.Stop = $true
        try { $Worker.Stop(); $Runspace.Close() } catch { }
    })

# ---- place + run ----------------------------------------------------------

$wa = [System.Windows.SystemParameters]::WorkArea
if ($null -ne $Cfg.left) { $WantedL = [double]$Cfg.left }
else { $WantedL = [Math]::Round($wa.Left + ($wa.Width - $W) / 2) }
if ($null -ne $Cfg.top) { $WantedT = [double]$Cfg.top }
else { $WantedT = [Math]::Round($wa.Bottom - $H - [double]$Cfg.bottomOffset) }
$StartPos = Get-ClampedPos $WantedL $WantedT
$Win.Left = $StartPos.X
$Win.Top = $StartPos.Y

Write-Log ("start: {0}x{1} at ({2},{3})  bottomOffset={4}  workArea.Bottom={5}  dragMode={6}  panelAlpha={7}  syncOffsetMs={8}  controls={9}" -f `
        $W, $H, $Win.Left, $Win.Top, $Cfg.bottomOffset, $wa.Bottom, $Cfg.dragMode, $Cfg.panelAlpha, $Cfg.syncOffsetMs, $Cfg.showControls)

if ($Cfg.dragMode -eq 'hover') { $HoverTimer.Start() }
$PollTimer.Start()
$FrameTimer.Start()
[void]$Win.ShowDialog()

$Sync.Stop = $true
try { $Worker.Stop(); $Runspace.Close() } catch { }
Write-Log 'exit'
