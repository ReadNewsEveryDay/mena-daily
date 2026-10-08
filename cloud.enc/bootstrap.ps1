<#
.SYNOPSIS
    在 runner 上解密并展开云端管线代码（配合 pack-cloud.ps1 使用）。

.DESCRIPTION
    读取 cloud.enc/payload.bin，用环境变量 CLOUD_CODE_KEY 解密，**先验 HMAC 再解密**
    （encrypt-then-MAC，密文被改动就直接报错退出，绝不执行来路不明的代码），
    然后解压到指定目录。

    刻意不做 Invoke-Expression：解出来的代码是**落盘后按文件执行**的，
    与正常脚本无异，避免被杀软当成"内存里跑加密载荷"的可疑行为。

    ⚠ 本脚本必须保持 **纯 ASCII**：PowerShell 5.1 读无 BOM 的 UTF-8 脚本会按 GBK 解码，
      中文注释可能吃掉后面的引号导致语法错误（本项目踩过）。说明文字放在 README.md。

.PARAMETER Payload
    payload.bin 路径，默认与本脚本同目录。

.PARAMETER Out
    展开目录，默认 $env:RUNNER_TEMP\cloud。

.PARAMETER Key
    解密口令；留空则读环境变量 CLOUD_CODE_KEY。
#>
[CmdletBinding()]
param(
    [string]$Payload = '',
    [string]$Out = '',
    [string]$Key = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($Payload)) { $Payload = Join-Path $PSScriptRoot 'payload.bin' }
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) 'cloud'
}
if ([string]::IsNullOrWhiteSpace($Key)) { $Key = $env:CLOUD_CODE_KEY }
if ([string]::IsNullOrWhiteSpace($Key)) { throw 'Missing decryption key: set env CLOUD_CODE_KEY (or pass -Key).' }
if (-not (Test-Path $Payload)) { throw "Payload not found: $Payload" }

$all = [IO.File]::ReadAllBytes($Payload)
if ($all.Length -lt 40 + 32) { throw 'Payload is too short / truncated.' }
$magic = [Text.Encoding]::ASCII.GetBytes('DAILYC01')
for ($i = 0; $i -lt 8; $i++) { if ($all[$i] -ne $magic[$i]) { throw 'Bad payload magic - not a pack-cloud.ps1 file?' } }

$salt = New-Object byte[] 16; [Array]::Copy($all, 8, $salt, 0, 16)
$iv   = New-Object byte[] 16; [Array]::Copy($all, 24, $iv, 0, 16)
$ctLen = $all.Length - 40 - 32
$ct   = New-Object byte[] $ctLen; [Array]::Copy($all, 40, $ct, 0, $ctLen)
$mac  = New-Object byte[] 32;    [Array]::Copy($all, $all.Length - 32, $mac, 0, 32)

$kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Key, $salt, 200000)
$km = $kdf.GetBytes(64)
$encKey = New-Object byte[] 32; [Array]::Copy($km, 0, $encKey, 0, 32)
$macKey = New-Object byte[] 32; [Array]::Copy($km, 32, $macKey, 0, 32)

# Verify HMAC before touching the ciphertext (constant-time compare).
# NOTE: copy into a fresh array instead of $all[0..N] - PowerShell range indexing
# on a large byte[] boxes every element (slow and memory hungry).
$hm = New-Object Security.Cryptography.HMACSHA256
$hm.Key = $macKey
$signed = New-Object byte[] ($all.Length - 32)
[Array]::Copy($all, 0, $signed, 0, $signed.Length)
$calc = $hm.ComputeHash($signed)
$diff = 0
for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $mac[$i]) }
if ($diff -ne 0) { throw 'HMAC mismatch: wrong key, or the payload was modified.' }

$aes = [Security.Cryptography.Aes]::Create()
$aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
$aes.Key = $encKey; $aes.IV = $iv
$dec = $aes.CreateDecryptor()
$plain = $dec.TransformFinalBlock($ct, 0, $ct.Length)
$dec.Dispose(); $aes.Dispose()

if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Write the plaintext zip next to (not inside) the target dir, extract, then remove it.
$zipTmp = Join-Path ([IO.Path]::GetTempPath()) ('cloud-' + [guid]::NewGuid().ToString('N') + '.zip')
[IO.File]::WriteAllBytes($zipTmp, $plain)
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($zipTmp, $Out)
} finally {
    Remove-Item $zipTmp -Force -ErrorAction SilentlyContinue
}

$n = (Get-ChildItem $Out -Recurse -File | Measure-Object).Count
Write-Host "Decrypted and extracted $n files to $Out"
Get-ChildItem $Out -Recurse -File | ForEach-Object { Write-Host ("  " + $_.FullName.Substring($Out.Length + 1)) }
