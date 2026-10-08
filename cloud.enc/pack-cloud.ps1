<#
.SYNOPSIS
    把云端管线代码打包成**加密载荷**（供公开仓库使用）。

.DESCRIPTION
    产物只有一个二进制文件 payload.bin，格式：
        magic "DAILYC01"(8) | salt(16) | iv(16) | ciphertext | hmac-sha256(32)

    加密：AES-256-CBC / PKCS7，密钥由 PBKDF2(口令, salt, 200000 轮) 派生 64 字节，
          前 32 字节当加密密钥、后 32 字节当 MAC 密钥（encrypt-then-MAC）。
    口令：运行时由 GitHub Secret `CLOUD_CODE_KEY` 提供，不进仓库。

    ⚠ 这是"防路人"级别的保护，不是"防有心人"：能跑这个 workflow 的人
      必然能拿到解密口令（它在 Secret 里）。详见 cloud.enc/README.md。

.PARAMETER Source
    本机工程根目录（含 bin\ 与 _cache\），例如
    I:\WorkSpaceForAI\international\Project_NewsEveryday

.PARAMETER Key
    加密口令。换口令后必须重新打包，并同步更新 GitHub Secret。

.PARAMETER Out
    输出路径，默认与脚本同目录的 payload.bin。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Key,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $PSScriptRoot 'payload.bin' }
$Source = (Resolve-Path $Source).Path

# ── 1) 收集要打包的文件（**不含任何状态/缓存数据**，只有代码与配置）──
$map = [ordered]@{}
foreach ($f in Get-ChildItem (Join-Path $Source 'bin') -File |
                Where-Object { $_.Extension -in @('.ps1', '.js', '.html') }) {
    $map["bin/$($f.Name)"] = $f.FullName
}
foreach ($n in @('mena-intl-rules.json', 'build-digest.mjs', 'digest-encrypt.mjs')) {
    $p = Join-Path $Source "_cache\$n"
    if (-not (Test-Path $p)) { throw "缺少文件：$p" }
    $map["_cache/$n"] = $p
}
if ($map.Count -eq 0) { throw '没有收集到任何文件' }

# ── 2) 在内存里打成 zip ──
$ms = New-Object IO.MemoryStream
$zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
foreach ($k in $map.Keys) {
    $entry = $zip.CreateEntry($k, [IO.Compression.CompressionLevel]::Optimal)
    $es = $entry.Open()
    try {
        $bytes = [IO.File]::ReadAllBytes($map[$k])
        $es.Write($bytes, 0, $bytes.Length)
    } finally { $es.Dispose() }
}
$zip.Dispose()
$plain = $ms.ToArray()
$ms.Dispose()

# ── 3) 派生密钥 + AES-256-CBC 加密 ──
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$salt = New-Object byte[] 16; $rng.GetBytes($salt)
$iv = New-Object byte[] 16;   $rng.GetBytes($iv)

# 用 Rfc2898DeriveBytes 的默认构造（HMAC-SHA1）：.NET Framework 与 .NET 都有，
# 保证加密端与解密端派生出**一模一样**的密钥（指定 HashAlgorithmName 在某些
# 运行时不支持，会导致解不开）。
$kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Key, $salt, 200000)
$km = $kdf.GetBytes(64)
$encKey = New-Object byte[] 32; [Array]::Copy($km, 0, $encKey, 0, 32)
$macKey = New-Object byte[] 32; [Array]::Copy($km, 32, $macKey, 0, 32)

$aes = [Security.Cryptography.Aes]::Create()
$aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
$aes.Key = $encKey; $aes.IV = $iv
$enc = $aes.CreateEncryptor()
$ct = $enc.TransformFinalBlock($plain, 0, $plain.Length)
$enc.Dispose(); $aes.Dispose()

# ── 4) encrypt-then-MAC：对 magic|salt|iv|密文 做 HMAC-SHA256 ──
$magic = [Text.Encoding]::ASCII.GetBytes('DAILYC01')
$hm = New-Object Security.Cryptography.HMACSHA256
$hm.Key = $macKey
$body = New-Object byte[] ($magic.Length + $salt.Length + $iv.Length + $ct.Length)
[Array]::Copy($magic, 0, $body, 0, $magic.Length)
[Array]::Copy($salt, 0, $body, 8, 16)
[Array]::Copy($iv, 0, $body, 24, 16)
[Array]::Copy($ct, 0, $body, 40, $ct.Length)
$mac = $hm.ComputeHash($body)

$final = New-Object byte[] ($body.Length + 32)
[Array]::Copy($body, 0, $final, 0, $body.Length)
[Array]::Copy($mac, 0, $final, $body.Length, 32)
[IO.File]::WriteAllBytes($Out, $final)

"已生成：$Out"
"  文件数   : $($map.Count)"
"  压缩后   : $([math]::Round($plain.Length/1KB,1)) KB"
"  密文载荷 : $([math]::Round($final.Length/1KB,1)) KB"
"  含        : " + (($map.Keys | Sort-Object) -join ', ')
