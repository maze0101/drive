# Миний Драйв - Google Drive маягийн хувийн файл хадгалах сервер
# Ажиллуулах: start.bat (эсвэл powershell -ExecutionPolicy Bypass -File server.ps1)
#   -Lan   : сүлжээний бусад төхөөрөмж (утас, өөр компьютер)-өөс хандахыг зөвшөөрнө
#   -Https : өөрөө үүсгэсэн гэрчилгээгээр HTTPS ажиллуулна (Администратор эрх шаардлагатай)
#   -Tunnel: Cloudflare Tunnel-ээр интернэтээс хандах нийтийн https холбоос гаргана (cloudflared хэрэгтэй)
param([switch]$Lan, [switch]$Https, [switch]$Tunnel)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.IO.Compression
# .NET Framework-ийн ZipArchive урсгалын Position-ийг уншдаг тул HTTP хариуны урсгалыг ороож бичсэн байтыг тоолно
Add-Type -TypeDefinition @'
using System; using System.IO;
public class MyDriveCountingStream : Stream {
    readonly Stream inner; long pos;
    public MyDriveCountingStream(Stream s) { inner = s; }
    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { return pos; } }
    public override long Position { get { return pos; } set { throw new NotSupportedException(); } }
    public override void Write(byte[] b, int o, int c) { inner.Write(b, o, c); pos += c; }
    public override void Flush() { inner.Flush(); }
    public override int Read(byte[] b, int o, int c) { throw new NotSupportedException(); }
    public override long Seek(long o, SeekOrigin r) { throw new NotSupportedException(); }
    public override void SetLength(long v) { throw new NotSupportedException(); }
}
'@
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $appDir 'config.json'

if (-not (Test-Path -LiteralPath $configPath)) {
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $buf = New-Object byte[] 12; $rng.GetBytes($buf)
    $pw = -join ($buf | ForEach-Object { $chars[$_ % $chars.Length] })
    [ordered]@{
        port     = 8080
        storage  = (Join-Path $appDir 'storage')
        quotaGB  = 200
        user     = 'admin'
        password = $pw
    } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Host "config.json үүсгэлээ. Нэвтрэх нэр: admin  Нууц үг: $pw" -ForegroundColor Yellow
}

$conf = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$root = [IO.Path]::GetFullPath($conf.storage).TrimEnd('\')
# Хогийн сав, жижиг зураг, тохиргооны өгөгдөл хадгалах газар (хадгалах хавтасны хажууд)
$metaDir = if ($conf.metaDir) { [IO.Path]::GetFullPath($conf.metaDir).TrimEnd('\') } else { $root + '-meta' }

$cfg = @{
    Root       = $root
    Trash      = Join-Path $metaDir 'trash'
    Thumbs     = Join-Path $metaDir 'thumbs'
    MetaFile   = Join-Path $metaDir 'meta.json'
    QuotaBytes = [long]$conf.quotaGB * 1GB
    User       = [string]$conf.user
    Password   = [string]$conf.password
    IndexPath  = Join-Path $appDir 'index.html'
    Lan        = [bool]$Lan
    Port       = [int]$conf.port
}
foreach ($d in $cfg.Root, $cfg.Trash, $cfg.Thumbs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# Бүх хүсэлтийн дунд хуваалцах төлөв. Дотоод хүснэгтүүдийг зөвхөн Invoke-Locked дотор өөрчилнө.
$state = [hashtable]::Synchronized(@{
    Used   = 0L
    Stars  = @{}                              # зам -> $true
    Recent = New-Object Collections.ArrayList # @{ path; time }
    Shares = @{}                              # token -> @{ token; path; expires; created }
    Trash  = @{}                              # id -> @{ id; name; orig; deleted; size; isDir }
    Fails  = @{}                              # IP -> @{ count; until }
})

# Үндсэн скрипт болон хүсэлт бүрийн runspace хоёуланд нь ашиглах функцууд
$lib = {
    function Invoke-Locked([scriptblock]$Body) {
        [Threading.Monitor]::Enter($state.SyncRoot)
        try { . $Body } finally { [Threading.Monitor]::Exit($state.SyncRoot) }
    }
    function Get-DirSize([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return 0L }
        $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($s) { [long]$s } else { 0L }
    }
    function Save-Meta {
        Invoke-Locked {
            $o = [ordered]@{
                stars  = @($state.Stars.Keys)
                recent = @($state.Recent)
                shares = @($state.Shares.Values)
                trash  = @($state.Trash.Values)
            }
            $tmp = $cfg.MetaFile + '.tmp'
            [IO.File]::WriteAllText($tmp, (ConvertTo-Json $o -Depth 5), (New-Object Text.UTF8Encoding $false))
            if ([IO.File]::Exists($cfg.MetaFile)) { [IO.File]::Replace($tmp, $cfg.MetaFile, [NullString]::Value) } else { [IO.File]::Move($tmp, $cfg.MetaFile) }
        }
    }
    function Get-Rel([string]$Full) {
        if ($Full.Length -le $cfg.Root.Length) { return '' }
        $Full.Substring($cfg.Root.Length + 1).Replace('\', '/')
    }
    function Resolve-SafePath([string]$Rel) {
        if ($null -eq $Rel) { $Rel = '' }
        $Rel = $Rel.Replace('/', '\').TrimStart('\')
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($cfg.Root, $Rel)).TrimEnd('\')
        if ($full -ne $cfg.Root -and -not $full.StartsWith($cfg.Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Зөвшөөрөгдөөгүй зам'
        }
        $full
    }
    function Test-SafeName([string]$Name) {
        -not [string]::IsNullOrWhiteSpace($Name) -and $Name -ne '.' -and $Name -ne '..' -and
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0
    }
    function Test-Under([string]$P, [string]$Base) {
        $P -eq $Base -or $P.StartsWith($Base + '/', [StringComparison]::OrdinalIgnoreCase)
    }
    # Нэр солих / зөөх үед од, хуваалцах холбоос, сүүлд нээсэн жагсаалтыг шинэ зам руу шилжүүлнэ.
    # $New хоосон бол (хогийн сав руу зөөсөн) тэдгээрийг арилгана.
    function Update-MetaPaths([string]$Old, [string]$New) {
        Invoke-Locked {
            foreach ($k in @($state.Stars.Keys)) {
                if (Test-Under $k $Old) {
                    $state.Stars.Remove($k)
                    if ($New) { $state.Stars[$New + $k.Substring($Old.Length)] = $true }
                }
            }
            for ($i = $state.Recent.Count - 1; $i -ge 0; $i--) {
                $r = $state.Recent[$i]
                if (Test-Under $r.path $Old) {
                    if ($New) { $r.path = $New + $r.path.Substring($Old.Length) } else { $state.Recent.RemoveAt($i) }
                }
            }
            foreach ($s in @($state.Shares.Values)) {
                if (Test-Under $s.path $Old) {
                    if ($New) { $s.path = $New + $s.path.Substring($Old.Length) } else { $state.Shares.Remove($s.token) }
                }
            }
            Save-Meta
        }
    }
    function Add-Used([long]$Delta) {
        Invoke-Locked { $state.Used = [Math]::Max(0L, [long]$state.Used + $Delta) }
    }
    function Remove-TrashItems($Ids) {
        foreach ($id in @($Ids)) {
            $t = $state.Trash[[string]$id]
            if (-not $t) { continue }
            $p = Join-Path $cfg.Trash $t.id
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
            Invoke-Locked { $state.Trash.Remove($t.id) }
            Add-Used (-[long]$t.size)
        }
        Save-Meta
    }
    function Remove-ExpiredTrash {
        $limit = (Get-Date).AddDays(-30)
        $old = @(@(Invoke-Locked { @($state.Trash.Values) }) | Where-Object { [DateTime]::Parse($_.deleted) -lt $limit } | ForEach-Object { $_.id })
        if ($old.Count) { Remove-TrashItems $old }
    }
}
. $lib

# Хадгалсан төлөвийг ачаалах
if (Test-Path -LiteralPath $cfg.MetaFile) {
    $m = Get-Content -LiteralPath $cfg.MetaFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($s in @($m.stars)) { if ($s) { $state.Stars[[string]$s] = $true } }
    foreach ($r in @($m.recent)) { if ($r) { [void]$state.Recent.Add(@{ path = [string]$r.path; time = [string]$r.time }) } }
    foreach ($s in @($m.shares)) {
        if ($s) { $state.Shares[[string]$s.token] = @{ token = [string]$s.token; path = [string]$s.path; expires = [string]$s.expires; created = [string]$s.created } }
    }
    foreach ($t in @($m.trash)) {
        if ($t -and (Test-Path -LiteralPath (Join-Path $cfg.Trash $t.id))) {
            $state.Trash[[string]$t.id] = @{ id = [string]$t.id; name = [string]$t.name; orig = [string]$t.orig; deleted = [string]$t.deleted; size = [long]$t.size; isDir = [bool]$t.isDir }
        }
    }
}
# Бүртгэлгүй үлдсэн хогийн савны хавтсуудыг (жишээ нь сервер гэнэт унтарсан үед) бүртгэлд буцааж оруулна
foreach ($d in Get-ChildItem -LiteralPath $cfg.Trash -Directory -Force) {
    if ($state.Trash.ContainsKey($d.Name)) { continue }
    $inner = Get-ChildItem -LiteralPath $d.FullName -Force | Select-Object -First 1
    if (-not $inner) { Remove-Item -LiteralPath $d.FullName -Force; continue }
    $state.Trash[$d.Name] = @{
        id = $d.Name; name = $inner.Name; orig = $inner.Name; deleted = $d.CreationTime.ToString('o')
        size = (Get-DirSize $inner.FullName); isDir = [bool]$inner.PSIsContainer
    }
}
Save-Meta
Write-Host 'Ашигласан хэмжээг тооцоолж байна...'
$state.Used = (Get-DirSize $cfg.Root) + (Get-DirSize $cfg.Trash)
Remove-ExpiredTrash

# Хүсэлт бүрийг тусдаа runspace дээр ажиллуулна (том файл татах үед бусад нь гацахгүй)
$handler = {
    $ErrorActionPreference = 'Stop'
    $req = $ctx.Request
    $res = $ctx.Response

    function Send-Json($obj, [int]$code = 200) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5 -Compress))
        $res.StatusCode = $code
        $res.ContentType = 'application/json; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    function Send-Html([int]$code, [string]$msg) {
        $html = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Миний Драйв</title>' +
            '<body style="font:16px system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0;padding:16px;text-align:center">' +
            [Net.WebUtility]::HtmlEncode($msg) + '</body>'
        $bytes = [Text.Encoding]::UTF8.GetBytes($html)
        $res.StatusCode = $code
        $res.ContentType = 'text/html; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    function Get-DiskFree { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($cfg.Root))).AvailableFreeSpace }
    function Send-Items($items) {
        $arr = @($items | Where-Object { $null -ne $_ })
        Send-Json @{ items = $arr; used = [long]$state.Used; quota = $cfg.QuotaBytes; diskFree = (Get-DiskFree) }
    }
    function Read-Body {
        $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        try { $sr.ReadToEnd() } finally { $sr.Close() }
    }
    function Read-JsonBody {
        $t = Read-Body
        if ($t) { $t | ConvertFrom-Json } else { New-Object psobject }
    }
    function Get-ItemInfo($fi) {
        $rel = Get-Rel $fi.FullName
        [ordered]@{
            name     = $fi.Name
            path     = $rel
            isDir    = [bool]$fi.PSIsContainer
            size     = if ($fi.PSIsContainer) { 0 } else { $fi.Length }
            modified = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            starred  = $state.Stars.ContainsKey($rel)
        }
    }
    function Get-FreeName([string]$Dir, [string]$Name) {
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Dir, $Name)))) { return $Name }
        $base = [IO.Path]::GetFileNameWithoutExtension($Name); $ext = [IO.Path]::GetExtension($Name)
        for ($i = 1; ; $i++) {
            $n = "$base ($i)$ext"
            if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Dir, $n)))) { return $n }
        }
    }
    function Move-Any([string]$Src, [string]$Dst) {
        if ([IO.Directory]::Exists($Src)) {
            # Зөвхөн том/жижиг үсэг өөрчлөх үед Directory.Move шууд ажилладаггүй
            if ($Src -eq $Dst) { $tmp = $Src + '.' + [guid]::NewGuid().ToString('N'); [IO.Directory]::Move($Src, $tmp); $Src = $tmp }
            [IO.Directory]::Move($Src, $Dst)
        } else { [IO.File]::Move($Src, $Dst) }
    }

    $textExt = '.txt', '.md', '.json', '.js', '.ts', '.css', '.html', '.htm', '.xml', '.csv', '.tsv', '.log', '.ps1', '.bat', '.cmd',
        '.py', '.java', '.c', '.cpp', '.h', '.cs', '.go', '.rs', '.php', '.rb', '.sh', '.yml', '.yaml', '.ini', '.cfg', '.conf', '.sql'
    $types = @{
        '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.bmp' = 'image/bmp'
        '.svg' = 'image/svg+xml'; '.mp4' = 'video/mp4'; '.m4v' = 'video/mp4'; '.webm' = 'video/webm'; '.ogv' = 'video/ogg'
        '.mp3' = 'audio/mpeg'; '.wav' = 'audio/wav'; '.ogg' = 'audio/ogg'; '.m4a' = 'audio/mp4'; '.flac' = 'audio/flac'; '.aac' = 'audio/aac'
        '.pdf' = 'application/pdf'
    }

    # Файл илгээх. Range дэмждэг тул видеог гүйлгэж үзэх боломжтой.
    function Send-File([string]$File, [bool]$Inline) {
        $ext = [IO.Path]::GetExtension($File).ToLower()
        $res.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } elseif ($textExt -contains $ext) { 'text/plain; charset=utf-8' } else { 'application/octet-stream' }
        $res.AddHeader('X-Content-Type-Options', 'nosniff')
        if ($ext -eq '.svg') { $res.AddHeader('Content-Security-Policy', 'sandbox') }
        $disp = if ($Inline) { 'inline' } else { 'attachment' }
        $res.AddHeader('Content-Disposition', "$disp; filename*=UTF-8''" + [Uri]::EscapeDataString([IO.Path]::GetFileName($File)))
        $res.AddHeader('Accept-Ranges', 'bytes')
        $fs = [IO.File]::OpenRead($File)
        try {
            $len = $fs.Length; $start = 0L; $end = $len - 1
            $range = $req.Headers['Range']
            if ($len -gt 0 -and $range -match '^bytes=(\d*)-(\d*)$') {
                if ($Matches[1]) {
                    $start = [long]$Matches[1]
                    if ($Matches[2]) { $end = [Math]::Min([long]$Matches[2], $len - 1) }
                } elseif ($Matches[2]) { $start = [Math]::Max(0L, $len - [long]$Matches[2]) }
                if ($start -gt $end) {
                    $res.StatusCode = 416
                    $res.AddHeader('Content-Range', "bytes */$len")
                    return
                }
                $res.StatusCode = 206
                $res.AddHeader('Content-Range', "bytes $start-$end/$len")
            }
            $count = $end - $start + 1
            $res.ContentLength64 = $count
            if ($start -eq 0 -and $count -eq $len) { $fs.CopyTo($res.OutputStream, 1MB) }
            else {
                $fs.Position = $start
                $buf = New-Object byte[] (1MB)
                while ($count -gt 0) {
                    $n = $fs.Read($buf, 0, [int][Math]::Min($buf.Length, $count))
                    if ($n -le 0) { break }
                    $res.OutputStream.Write($buf, 0, $n)
                    $count -= $n
                }
            }
        } finally { $fs.Close() }
    }

    # Хавтас / олон файлыг ZIP болгон шууд урсгалаар илгээнэ
    function Send-Zip($Fulls, [string]$ZipName) {
        $store = '.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4', '.m4v', '.webm', '.mkv', '.mov', '.avi', '.mp3', '.m4a', '.aac', '.flac',
            '.zip', '.rar', '.7z', '.gz', '.docx', '.xlsx', '.pptx', '.pdf'
        $res.ContentType = 'application/zip'
        $res.SendChunked = $true
        $res.AddHeader('Content-Disposition', "attachment; filename*=UTF-8''" + [Uri]::EscapeDataString($ZipName))
        $zip = New-Object IO.Compression.ZipArchive((New-Object MyDriveCountingStream $res.OutputStream), [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($full in $Fulls) {
                $base = if ($full -eq $cfg.Root) { $full } else { [IO.Path]::GetDirectoryName($full) }
                $all = if ([IO.Directory]::Exists($full)) {
                    @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue)
                } else { @(Get-Item -LiteralPath $full -Force) }
                foreach ($fi in $all) {
                    $rel = $fi.FullName.Substring($base.Length).TrimStart('\').Replace('\', '/')
                    if (-not $rel) { continue }
                    if ($fi.PSIsContainer) { [void]$zip.CreateEntry($rel + '/'); continue }
                    if ($fi.Name -like '*.uploading') { continue }
                    $lvl = if ($store -contains $fi.Extension.ToLower()) { [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Fastest }
                    $e = $zip.CreateEntry($rel, $lvl)
                    try { $e.LastWriteTime = [DateTimeOffset]$fi.LastWriteTime } catch {}
                    $es = $e.Open()
                    $fs = [IO.File]::OpenRead($fi.FullName)
                    try { $fs.CopyTo($es, 1MB) } finally { $fs.Close(); $es.Close() }
                }
            }
        } finally { $zip.Dispose() }
    }

    # Зургийн жижиг хувилбар (thumbnail) үүсгэж кэшлэнэ
    function Get-Thumb([string]$File) {
        $fi = Get-Item -LiteralPath $File
        $md5 = [Security.Cryptography.MD5]::Create()
        $key = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$File|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)")) | ForEach-Object { $_.ToString('x2') })
        $out = Join-Path $cfg.Thumbs "$key.jpg"
        if (Test-Path -LiteralPath $out) { return $out }
        $img = $null; $bmp = $null; $g = $null
        try {
            $img = [Drawing.Image]::FromFile($File)
            if ($img.PropertyIdList -contains 0x0112) {
                switch ($img.GetPropertyItem(0x0112).Value[0]) {
                    3 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate180FlipNone) }
                    6 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone) }
                    8 { $img.RotateFlip([Drawing.RotateFlipType]::Rotate270FlipNone) }
                }
            }
            $scale = [Math]::Min(1.0, 400.0 / [Math]::Max($img.Width, $img.Height))
            $w = [Math]::Max(1, [int]($img.Width * $scale)); $h = [Math]::Max(1, [int]($img.Height * $scale))
            $bmp = New-Object Drawing.Bitmap $w, $h
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.Clear([Drawing.Color]::White)
            $g.DrawImage($img, 0, 0, $w, $h)
            $codec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
            $ep = New-Object Drawing.Imaging.EncoderParameters 1
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, [long]82)
            $tmp = "$out.$([guid]::NewGuid().ToString('N')).tmp"
            $bmp.Save($tmp, $codec, $ep)
            try { [IO.File]::Move($tmp, $out) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            $out
        } catch { $null }
        finally { foreach ($x in $g, $bmp, $img) { if ($x) { $x.Dispose() } } }
    }

    function Get-ShareBase {
        $u = $req.Url
        $h = $u.Host
        if (($h -eq 'localhost' -or $h -eq '127.0.0.1') -and $cfg.Lan) {
            $a = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
                Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($a) { $h = $a.Address.ToString() }
        }
        "$($u.Scheme)://${h}:$($u.Port)"
    }

    try {
        # Query-г UTF-8-аар өөрсдөө задлах (HttpListener нь ANSI ашиглаж кирилл эвддэг)
        $q = @{}
        foreach ($pair in $req.Url.Query.TrimStart('?').Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $v = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
            $q[[Uri]::UnescapeDataString($kv[0])] = $v
        }

        $route = $req.Url.AbsolutePath
        $method = $req.HttpMethod
        $ip = $req.RemoteEndPoint.Address.ToString()
        # Туннелээр ирсэн хүсэлт бүгд 127.0.0.1-ээс ирдэг тул жинхэнэ IP-г Cloudflare-ийн толгойноос авна
        if ([Net.IPAddress]::IsLoopback($req.RemoteEndPoint.Address) -and $req.Headers['CF-Connecting-IP']) { $ip = $req.Headers['CF-Connecting-IP'] }

        # Хуваалцсан холбоос: нууц үггүйгээр нээгдэнэ
        if ($route.StartsWith('/s/') -and $method -eq 'GET') {
            $sh = $state.Shares[$route.Substring(3)]
            if ($sh -and $sh.expires -and [DateTime]::Parse($sh.expires) -lt (Get-Date)) { $sh = $null }
            $full = if ($sh) { Resolve-SafePath $sh.path }
            if ($full -and [IO.File]::Exists($full)) {
                $ext = [IO.Path]::GetExtension($full).ToLower()
                Send-File $full ($q['dl'] -ne '1' -and ($types.ContainsKey($ext) -or $textExt -contains $ext))
            } elseif ($full -and [IO.Directory]::Exists($full)) {
                Send-Zip @($full) ([IO.Path]::GetFileName($full) + '.zip')
            } else {
                Send-Html 404 'Холбоос хүчингүй эсвэл хугацаа нь дууссан байна.'
            }
            return
        }

        # Нэвтрэлт шалгах (Basic). 10 удаа буруу оролдвол тухайн IP-г 15 минут хаана.
        $fail = $state.Fails[$ip]
        if ($fail -and $fail.until -and $fail.until -gt (Get-Date)) {
            Send-Json @{ error = 'Хэт олон удаа буруу оролдлоо. 15 минутын дараа дахин оролдоно уу.' } 429
            return
        }
        $auth = $req.Headers['Authorization']
        # config.json-д нууц үг хоосон бол нэвтрэлтгүйгээр нээлттэй
        $ok = -not $cfg.Password
        if (-not $ok -and $auth -and $auth.StartsWith('Basic ')) {
            try {
                $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth.Substring(6)))
                $i = $dec.IndexOf(':')
                $ok = $i -ge 0 -and $dec.Substring(0, $i) -ceq $cfg.User -and $dec.Substring($i + 1) -ceq $cfg.Password
            } catch {}
        }
        if (-not $ok) {
            if ($auth) {
                Invoke-Locked {
                    $f = $state.Fails[$ip]
                    if (-not $f -or ($f.until -and $f.until -le (Get-Date))) { $f = @{ count = 0; until = $null }; $state.Fails[$ip] = $f }
                    $f.count++
                    if ($f.count -ge 10) { $f.until = (Get-Date).AddMinutes(15); $f.count = 0 }
                }
            }
            $res.StatusCode = 401
            $res.AddHeader('WWW-Authenticate', 'Basic realm="MyDrive", charset="UTF-8"')
            return
        }
        if ($fail) { Invoke-Locked { $state.Fails.Remove($ip) } }

        switch ("$method $route") {
            'GET /' {
                $bytes = [IO.File]::ReadAllBytes($cfg.IndexPath)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            'GET /api/list' {
                $dir = Resolve-SafePath $q['path']
                if (-not [IO.Directory]::Exists($dir)) { Send-Json @{ error = 'Хавтас олдсонгүй' } 404; return }
                Send-Items (Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -notlike '*.uploading' } | ForEach-Object { Get-ItemInfo $_ })
            }
            'GET /api/search' {
                $term = ([string]$q['q']).Trim() -replace '[\*\?]', ''
                $found = if ($term) {
                    Get-ChildItem -LiteralPath $cfg.Root -Recurse -Force -Filter "*$term*" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notlike '*.uploading' } | Select-Object -First 300 | ForEach-Object { Get-ItemInfo $_ }
                }
                Send-Items $found
            }
            'GET /api/recent' {
                $out = foreach ($e in @(Invoke-Locked { @($state.Recent) })) {
                    $full = try { Resolve-SafePath $e.path } catch { $null }
                    if ($full -and $full -ne $cfg.Root -and (Test-Path -LiteralPath $full)) {
                        $it = Get-ItemInfo (Get-Item -LiteralPath $full -Force)
                        $it.opened = $e.time
                        $it
                    }
                }
                Send-Items $out
            }
            'GET /api/starred' {
                $out = foreach ($p in @(Invoke-Locked { @($state.Stars.Keys) })) {
                    $full = try { Resolve-SafePath $p } catch { $null }
                    if ($full -and $full -ne $cfg.Root -and (Test-Path -LiteralPath $full)) { Get-ItemInfo (Get-Item -LiteralPath $full -Force) }
                }
                Send-Items $out
            }
            'GET /api/trash' {
                Remove-ExpiredTrash
                $out = foreach ($t in @(Invoke-Locked { @($state.Trash.Values) })) {
                    [ordered]@{
                        name = $t.name; path = $t.id; id = $t.id; isDir = [bool]$t.isDir; size = [long]$t.size
                        modified = ([DateTime]::Parse($t.deleted)).ToString('yyyy-MM-dd HH:mm'); orig = $t.orig; starred = $false
                    }
                }
                Send-Items $out
            }
            'POST /api/touch' {
                $b = Read-JsonBody
                $full = Resolve-SafePath ([string]$b.path)
                if ($full -ne $cfg.Root -and (Test-Path -LiteralPath $full)) {
                    $p = Get-Rel $full
                    Invoke-Locked {
                        for ($i = $state.Recent.Count - 1; $i -ge 0; $i--) { if ($state.Recent[$i].path -eq $p) { $state.Recent.RemoveAt($i) } }
                        $state.Recent.Insert(0, @{ path = $p; time = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
                        while ($state.Recent.Count -gt 50) { $state.Recent.RemoveAt(50) }
                        Save-Meta
                    }
                }
                Send-Json @{ ok = $true }
            }
            'POST /api/star' {
                $b = Read-JsonBody
                Invoke-Locked {
                    foreach ($p in @($b.paths)) {
                        $rel = Get-Rel (Resolve-SafePath ([string]$p))
                        if (-not $rel) { continue }
                        if ($b.on) { $state.Stars[$rel] = $true } else { $state.Stars.Remove($rel) }
                    }
                    Save-Meta
                }
                Send-Json @{ ok = $true }
            }
            'PUT /api/upload' {
                # Хавтас байршуулахад дэд хавтсууд path-д ирнэ, байхгүй бол үүсгэнэ
                $relDir = [string]$q['path']
                foreach ($seg in ($relDir -split '/' | Where-Object { $_ })) {
                    if (-not (Test-SafeName $seg)) { Send-Json @{ error = 'Хавтасны нэр буруу' } 400; return }
                }
                $dir = Resolve-SafePath $relDir
                if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
                $name = $q['name']
                if (-not (Test-SafeName $name)) { Send-Json @{ error = 'Файлын нэр буруу' } 400; return }
                $len = $req.ContentLength64
                if ($len -lt 0) { Send-Json @{ error = 'Файлын хэмжээ тодорхойгүй' } 411; return }
                $target = [IO.Path]::Combine($dir, $name)
                if ([IO.Directory]::Exists($target)) { Send-Json @{ error = 'Ижил нэртэй хавтас байна' } 409; return }
                $existing = if ([IO.File]::Exists($target)) { (Get-Item -LiteralPath $target -Force).Length } else { 0 }
                if ([long]$state.Used - $existing + $len -gt $cfg.QuotaBytes) { Send-Json @{ error = "Багтаамж ($($cfg.QuotaBytes / 1GB) GB) хүрэлцэхгүй" } 507; return }
                if ($len -gt (Get-DiskFree)) { Send-Json @{ error = 'Дискэнд зай хүрэлцэхгүй' } 507; return }
                $tmp = "$target.$([guid]::NewGuid().ToString('N')).uploading"
                $fs = [IO.File]::Create($tmp)
                $copied = $false
                try { $req.InputStream.CopyTo($fs, 1MB); $copied = $true }
                finally {
                    $fs.Close()
                    if (-not $copied) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                }
                if ((Get-Item -LiteralPath $tmp).Length -ne $len) {
                    Remove-Item -LiteralPath $tmp -Force
                    Send-Json @{ error = 'Байршуулалт тасарсан' } 400; return
                }
                Move-Item -LiteralPath $tmp -Destination $target -Force
                Add-Used ($len - $existing)
                Send-Json @{ ok = $true }
            }
            'GET /api/download' {
                $file = Resolve-SafePath $q['path']
                if (-not [IO.File]::Exists($file)) { Send-Json @{ error = 'Файл олдсонгүй' } 404; return }
                Send-File $file ($q['inline'] -eq '1')
            }
            'GET /api/thumb' {
                $file = Resolve-SafePath $q['path']
                if (-not [IO.File]::Exists($file)) { Send-Json @{ error = 'Файл олдсонгүй' } 404; return }
                $res.AddHeader('Cache-Control', 'private, max-age=604800')
                $t = if (@('.jpg', '.jpeg', '.png', '.gif', '.bmp') -contains [IO.Path]::GetExtension($file).ToLower()) { Get-Thumb $file }
                if ($t) { Send-File $t $true } else { Send-File $file $true }
            }
            'POST /api/zip' {
                $data = $null
                foreach ($pair in (Read-Body).Split('&')) {
                    $kv = $pair.Split('=', 2)
                    if ($kv[0] -eq 'data' -and $kv.Count -eq 2) { $data = [Net.WebUtility]::UrlDecode($kv[1]) }
                }
                $b = $data | ConvertFrom-Json
                $fulls = @(foreach ($p in @($b.paths)) { $f = Resolve-SafePath ([string]$p); if (Test-Path -LiteralPath $f) { $f } })
                if (-not $fulls.Count) { Send-Html 404 'Файл олдсонгүй'; return }
                $name = if ($fulls.Count -eq 1 -and $fulls[0] -ne $cfg.Root) { [IO.Path]::GetFileName($fulls[0]) } else { 'Миний Драйв' }
                Send-Zip $fulls "$name.zip"
            }
            'POST /api/mkdir' {
                $dir = Resolve-SafePath $q['path']
                if (-not (Test-SafeName $q['name'])) { Send-Json @{ error = 'Хавтасны нэр буруу' } 400; return }
                $t = [IO.Path]::Combine($dir, $q['name'])
                if (Test-Path -LiteralPath $t) { Send-Json @{ error = 'Ийм нэртэй зүйл аль хэдийн байна' } 409; return }
                [void][IO.Directory]::CreateDirectory($t)
                Send-Json @{ ok = $true; path = (Get-Rel $t) }
            }
            'POST /api/rename' {
                $item = Resolve-SafePath $q['path']
                if ($item -eq $cfg.Root) { Send-Json @{ error = 'Үндсэн хавтсыг өөрчлөх боломжгүй' } 400; return }
                if (-not (Test-Path -LiteralPath $item)) { Send-Json @{ error = 'Олдсонгүй' } 404; return }
                $newName = $q['newName']
                if (-not (Test-SafeName $newName)) { Send-Json @{ error = 'Нэр буруу' } 400; return }
                $newFull = [IO.Path]::Combine([IO.Path]::GetDirectoryName($item), $newName)
                if ($newFull -ceq $item) { Send-Json @{ ok = $true }; return }
                if ($newFull -ne $item -and (Test-Path -LiteralPath $newFull)) { Send-Json @{ error = 'Ийм нэртэй зүйл аль хэдийн байна' } 409; return }
                Move-Any $item $newFull
                Update-MetaPaths (Get-Rel $item) (Get-Rel $newFull)
                Send-Json @{ ok = $true }
            }
            'POST /api/move' {
                $b = Read-JsonBody
                $dest = Resolve-SafePath ([string]$b.dest)
                if (-not [IO.Directory]::Exists($dest)) { Send-Json @{ error = 'Очих хавтас олдсонгүй' } 404; return }
                $errors = New-Object Collections.ArrayList
                foreach ($p in @($b.paths)) {
                    try {
                        $src = Resolve-SafePath ([string]$p)
                        if ($src -eq $cfg.Root -or -not (Test-Path -LiteralPath $src)) { continue }
                        if ($dest -eq $src -or $dest.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Хавтсыг өөрийн дотор зөөх боломжгүй' }
                        if ([IO.Path]::GetDirectoryName($src) -eq $dest) { continue }
                        $target = [IO.Path]::Combine($dest, (Get-FreeName $dest ([IO.Path]::GetFileName($src))))
                        Move-Any $src $target
                        Update-MetaPaths (Get-Rel $src) (Get-Rel $target)
                    } catch { [void]$errors.Add("$(([string]$p).Split('/')[-1]): $($_.Exception.Message)") }
                }
                Send-Json @{ ok = $true; errors = @($errors) }
            }
            'POST /api/delete' {
                # Хогийн сав руу зөөнө
                $b = Read-JsonBody
                $ids = New-Object Collections.ArrayList
                foreach ($p in @($b.paths)) {
                    $src = Resolve-SafePath ([string]$p)
                    if ($src -eq $cfg.Root -or -not (Test-Path -LiteralPath $src)) { continue }
                    $isDir = [IO.Directory]::Exists($src)
                    $size = if ($isDir) { Get-DirSize $src } else { (Get-Item -LiteralPath $src -Force).Length }
                    $id = [guid]::NewGuid().ToString('N')
                    $tdir = Join-Path $cfg.Trash $id
                    [void][IO.Directory]::CreateDirectory($tdir)
                    $name = [IO.Path]::GetFileName($src)
                    try { Move-Any $src ([IO.Path]::Combine($tdir, $name)) }
                    catch { Remove-Item -LiteralPath $tdir -Recurse -Force -ErrorAction SilentlyContinue; throw "$name`: $($_.Exception.Message)" }
                    $rel = Get-Rel $src
                    $entry = @{ id = $id; name = $name; orig = $rel; deleted = (Get-Date).ToString('o'); size = [long]$size; isDir = $isDir }
                    Invoke-Locked { $state.Trash[$id] = $entry }
                    Update-MetaPaths $rel $null
                    [void]$ids.Add($id)
                }
                Send-Json @{ ok = $true; ids = @($ids) }
            }
            'POST /api/restore' {
                $b = Read-JsonBody
                $errors = New-Object Collections.ArrayList
                foreach ($id in @($b.ids)) {
                    $t = $state.Trash[[string]$id]
                    if (-not $t) { continue }
                    try {
                        $src = [IO.Path]::Combine($cfg.Trash, $t.id, $t.name)
                        $parentRel = if ($t.orig.Contains('/')) { $t.orig.Substring(0, $t.orig.LastIndexOf('/')) } else { '' }
                        $parent = Resolve-SafePath $parentRel
                        [void][IO.Directory]::CreateDirectory($parent)
                        Move-Any $src ([IO.Path]::Combine($parent, (Get-FreeName $parent $t.name)))
                        Remove-Item -LiteralPath (Join-Path $cfg.Trash $t.id) -Recurse -Force
                        Invoke-Locked { $state.Trash.Remove($t.id) }
                    } catch { [void]$errors.Add("$($t.name): $($_.Exception.Message)") }
                }
                Save-Meta
                Send-Json @{ ok = $true; errors = @($errors) }
            }
            'POST /api/purge' {
                $b = Read-JsonBody
                $ids = if ($b.all) { @(Invoke-Locked { @($state.Trash.Keys) }) } else { @($b.ids) }
                Remove-TrashItems $ids
                Send-Json @{ ok = $true }
            }
            'GET /api/share' {
                $rel = Get-Rel (Resolve-SafePath $q['path'])
                $sh = Invoke-Locked {
                    $found = $null
                    foreach ($s in @($state.Shares.Values)) {
                        if ($s.path -ne $rel) { continue }
                        if ($s.expires -and [DateTime]::Parse($s.expires) -lt (Get-Date)) { $state.Shares.Remove($s.token); Save-Meta }
                        else { $found = $s }
                    }
                    $found
                }
                $out = $null
                if ($sh) {
                    $out = @{ token = $sh.token; expires = $sh.expires; expiresText = if ($sh.expires) { ([DateTime]::Parse($sh.expires)).ToString('yyyy-MM-dd HH:mm') } else { '' } }
                }
                $warn = if (-not $cfg.Lan) { 'Сервер зөвхөн энэ компьютер дээр нээлттэй байна. Бусад хүн холбоосыг нээхийн тулд start.bat -Lan гэж ажиллуулна уу.' } else { '' }
                Send-Json @{ share = $out; base = (Get-ShareBase); warn = $warn }
            }
            'POST /api/share' {
                $b = Read-JsonBody
                $full = Resolve-SafePath ([string]$b.path)
                if ($full -eq $cfg.Root -or -not (Test-Path -LiteralPath $full)) { Send-Json @{ error = 'Олдсонгүй' } 404; return }
                $rel = Get-Rel $full
                $bytes = New-Object byte[] 16
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
                $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
                $days = [int]$b.days
                $entry = @{
                    token   = $token
                    path    = $rel
                    expires = if ($days -gt 0) { (Get-Date).AddDays($days).ToString('o') } else { '' }
                    created = (Get-Date).ToString('o')
                }
                Invoke-Locked {
                    foreach ($s in @($state.Shares.Values)) { if ($s.path -eq $rel) { $state.Shares.Remove($s.token) } }
                    $state.Shares[$token] = $entry
                    Save-Meta
                }
                Send-Json @{ ok = $true }
            }
            'POST /api/unshare' {
                $b = Read-JsonBody
                $rel = Get-Rel (Resolve-SafePath ([string]$b.path))
                Invoke-Locked {
                    foreach ($s in @($state.Shares.Values)) { if ($s.path -eq $rel) { $state.Shares.Remove($s.token) } }
                    Save-Meta
                }
                Send-Json @{ ok = $true }
            }
            default {
                Send-Json @{ error = 'Олдсонгүй' } 404
            }
        }
    }
    catch {
        try { Send-Json @{ error = $_.Exception.Message } 500 } catch {}
    }
    finally {
        try { $res.Close() } catch {}
    }
}
$requestScript = "param(`$ctx, `$cfg, `$state)`n" + $lib.ToString() + "`n" + $handler.ToString()
$scanScript = "param(`$cfg, `$state)`n" + $lib.ToString() + "`n" + {
    $s = (Get-DirSize $cfg.Root) + (Get-DirSize $cfg.Trash)
    Invoke-Locked { $state.Used = $s }
}.ToString()

$scheme = if ($Https) { 'https' } else { 'http' }
if ($Https) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '-Https горимд Администратор эрхээр ажиллуулна уу (start.bat дээр баруун товч > Run as administrator).' }
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'MyDrive' -and $_.NotAfter -gt (Get-Date).AddDays(7) } | Select-Object -First 1
    if (-not $cert) {
        Write-Host 'HTTPS гэрчилгээ үүсгэж байна...'
        $cert = New-SelfSignedCertificate -DnsName @($env:COMPUTERNAME, 'localhost') -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'MyDrive' -NotAfter (Get-Date).AddYears(5)
    }
    netsh http delete sslcert "ipport=0.0.0.0:$($cfg.Port)" | Out-Null
    netsh http add sslcert "ipport=0.0.0.0:$($cfg.Port)" "certhash=$($cert.Thumbprint)" 'appid={3f8b9c1e-6a2d-4e57-9b1a-1c2d3e4f5a6b}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HTTPS гэрчилгээг порттой холбож чадсангүй.' }
}

$listener = New-Object Net.HttpListener
$hostName = if ($Lan) { '+' } else { 'localhost' }
$listener.Prefixes.Add("${scheme}://${hostName}:$($cfg.Port)/")
# Нэвтрэлтийг өөрсдөө шалгана (хуваалцсан холбоос нууц үггүй нээгдэх ёстой)
$listener.AuthenticationSchemes = [Net.AuthenticationSchemes]::Anonymous
$listener.IgnoreWriteExceptions = $true
$listener.Start()

$pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
$pool.Open()
$jobs = New-Object Collections.ArrayList
function Start-Job2([string]$Script, [object[]]$Arguments) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$jobs.Add(@{ ps = $ps; h = $ps.BeginInvoke() })
}
function Clear-Jobs {
    foreach ($j in @($jobs)) {
        if ($j.h.IsCompleted) {
            try { [void]$j.ps.EndInvoke($j.h) } catch {}
            $j.ps.Dispose(); $jobs.Remove($j)
        }
    }
}

$url = "${scheme}://localhost:$($cfg.Port)/"
Write-Host "Миний Драйв ажиллаж байна: $url" -ForegroundColor Green
if ($Lan) {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { Write-Host "  Сүлжээнээс: ${scheme}://$($_.Address):$($cfg.Port)/" -ForegroundColor Green }
}
if ($Https) { Write-Host 'Өөрөө үүсгэсэн гэрчилгээ тул хөтөч анхааруулга гаргана: "Advanced > Proceed" дарж үргэлжлүүлнэ.' -ForegroundColor Yellow }
Write-Host "Хадгалах газар: $($cfg.Root)   Багтаамж: $($conf.quotaGB) GB"
Write-Host 'Зогсоохдоо Ctrl+C дарна.'
Start-Process $url

$tunnelProc = $null
if ($Tunnel) {
    $cf = @((Get-Command cloudflared -ErrorAction SilentlyContinue).Source,
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $cf) {
        Write-Host 'cloudflared олдсонгүй. Суулгах: winget install Cloudflare.cloudflared' -ForegroundColor Red
    } else {
        Write-Host 'Интернэтийн холбоос үүсгэж байна...'
        $tunnelLog = Join-Path $metaDir 'tunnel.log'
        Remove-Item -LiteralPath $tunnelLog -Force -ErrorAction SilentlyContinue
        # HttpListener зөвхөн localhost нэртэй хүсэлт хүлээж авдаг тул Host толгойг localhost болгоно
        $cfArgs = @('tunnel', '--no-autoupdate', '--url', $url, '--http-host-header', 'localhost')
        if ($Https) { $cfArgs += '--no-tls-verify' }
        $tunnelProc = Start-Process -FilePath $cf -ArgumentList $cfArgs -RedirectStandardError $tunnelLog -WindowStyle Hidden -PassThru
        $publicUrl = $null
        for ($i = 0; $i -lt 60 -and -not $publicUrl -and -not $tunnelProc.HasExited; $i++) {
            Start-Sleep -Milliseconds 500
            $log = Get-Content -LiteralPath $tunnelLog -Raw -ErrorAction SilentlyContinue
            if ($log -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $publicUrl = $Matches[0] }
        }
        if ($publicUrl) {
            Set-Clipboard -Value $publicUrl
            Write-Host ''
            Write-Host "  Интернэтийн холбоос: $publicUrl" -ForegroundColor Cyan
            Write-Host '  (clipboard руу хуулсан - Ctrl+V дарж явуулна уу)' -ForegroundColor Cyan
            Write-Host "  Нэвтрэх нэр: $($cfg.User)   Нууц үг: config.json дотор" -ForegroundColor Cyan
            Write-Host '  Анхаар: энэ холбоос сервер асах бүрт өөрчлөгдөнө.' -ForegroundColor Yellow
            Write-Host ''
        } else {
            Write-Host "Туннель үүсгэж чадсангүй. Дэлгэрэнгүй: $tunnelLog" -ForegroundColor Red
        }
    }
}

$lastScan = Get-Date
try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) {
            # Гаднаас (Explorer-ээр) өөрчилсөн файлуудыг тооцохын тулд 10 минут тутам дахин тоолно
            if (((Get-Date) - $lastScan).TotalMinutes -ge 10) {
                $lastScan = Get-Date
                Start-Job2 $scanScript @($cfg, $state)
            }
            Clear-Jobs
        }
        Start-Job2 $requestScript @($task.Result, $cfg, $state)
        Clear-Jobs
    }
}
finally {
    if ($tunnelProc -and -not $tunnelProc.HasExited) { Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue }
    $listener.Stop(); $listener.Close(); $pool.Close()
}
