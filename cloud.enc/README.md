# 云端副本（GitHub Actions）· 已部署，**当前未启用**

本机那套「国际新闻日报 + 中东官媒日报」管线的云端副本。本机仍是主运行方式；
云端这套是**备好放着**的，你不去点它，它永远不会跑、也不会发任何邮件。

## 目录

```
.github/workflows/mena-daily-cloud.yml   明文（GitHub 必须能解析它）
cloud.enc/
├── payload.bin       管线代码的**加密载荷**（16 个文件：脚本 + 配置）
├── bootstrap.ps1     明文引导脚本：验 HMAC → 解密 → 展开到临时目录
├── pack-cloud.ps1    本地打包工具：把本机代码重新加密成 payload.bin
└── README.md         本文件
```

## 加密是怎么做的

```
payload.bin = magic "DAILYC01"(8) | salt(16) | iv(16) | AES-256-CBC 密文 | HMAC-SHA256(32)
```

- 密钥由 `PBKDF2(口令, salt, 200000 轮)` 派生 64 字节：前 32 字节加密、后 32 字节做 MAC。
- **先验 MAC 再解密**（encrypt-then-MAC）。密文被动过一个字节、或口令不对，都会直接报
  `HMAC mismatch` 退出，绝不会执行来路不明的代码。
- 口令存在仓库 Secret `CLOUD_CODE_KEY`，不在任何文件里。
- 展开后的代码**落盘再按文件执行**（`powershell -File`），刻意不用 `Invoke-Expression`，
  避免被杀软当成"内存里跑加密载荷"。

**它挡得住什么**：`git clone` 下来只看得到密文，`git show` 历史提交也一样。
**它挡不住什么**：能跑这个 workflow 的人必然拿得到那个 Secret（否则 runner 解不开），
所以这是"防路人"而不是"防有心人"。另外 `.github/workflows/*.yml` **无法加密** ——
GitHub 必须解析它才会注册，所以流程骨架、执行哪些步骤、传什么参数都是可见的。

## 启用前的一次性配置

仓库 → Settings：

| 位置 | 名称 | 值 | 必需 |
|---|---|---|---|
| Secrets → Actions | `CLOUD_CODE_KEY` | **解密口令**（打包时用的那一串 32 字符） | ✅ |
| Secrets → Actions | `DAILY_MAIL_PASSWORD` | QQ 邮箱的 **SMTP 授权码**（不是登录密码） | ✅ |
| Variables → Actions | `MAIL_USER` | 发件邮箱，如 `xxxx@qq.com` | ✅ |
| Variables → Actions | `MAIL_TO` | 收件人，逗号分隔；留空则发给 `MAIL_USER` | 可选 |
| Actions → General → Workflow permissions | — | 选 **Read and write**（推密文要用） | ✅ |

> `MAIL_USER` **必须填**，它不只是发件人：`mena-lib.ps1` / `daily.ps1` 还会拿它当
> MyMemory 翻译接口的 `de=` 参数，把配额从匿名 5,000 字符/天提到 50,000。
> 不填的话翻译会大面积失败。

## 怎么试跑（不会发信、不会推密文）

Actions → 左侧选 **「官媒日报·云端（手动·当前未启用）」** → **Run workflow**：

- `no_mail` = ✅ 只采集成稿，不发信
- `no_publish` = ✅ 不推加密缓存页
- `date` 留空 = 北京时间的昨天

跑完在 run 页面底部下载 artifact `daily-<日期>`，里面有日报、归档和完整日志。

## 怎么改代码（改了本机脚本之后）

云端跑的代码是 `payload.bin` 里的那一份，**改了脚本必须重新打包**，否则云端还是旧的：

```powershell
cd I:\WorkSpaceForAI\international\_gha-repo
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloud.enc\pack-cloud.ps1 `
    -Source I:\WorkSpaceForAI\international\Project_NewsEveryday `
    -Key '<你的 CLOUD_CODE_KEY>'
git add cloud.enc/payload.bin
git commit -m 'cloud: 同步管线代码'
git push
```

换口令也是同一条命令（换完记得同步改 Secret）。

## 怎么正式启用

1. 编辑 `.github/workflows/mena-daily-cloud.yml`，取消文件末尾 `schedule:` 那两行的注释
   （GitHub 的 cron 用 **UTC**：`5 16 * * *` = 北京 00:05）。
2. **停掉本机的计划任务**「官媒国际新闻日报」：
   `Disable-ScheduledTask -TaskName '官媒国际新闻日报'`
   两边都会往仓库 `main` 推当天密文，同时跑会互相顶掉（后推的失败）。

## 已知限制（来自探针在真实 runner 上的实测，不是推测）

出口 IP 是 Azure 机房段（实测 `130.131.204.201`、`48.211.211.35`）。两次运行、
两个不同 runner，结果**高度一致**：

| 类别 | 结果 |
|---|---|
| 中东 HTTP 通道（17 项） | 15 项 OK；**NNA（黎巴嫩）稳定被 Cloudflare 403**；APS（总统）稳定取到空页面 |
| 中东浏览器通道（9 项） | **MENA / IRNA / Arab News 稳定通过**；**SABA、INA、Al-Sabah、SUNA、MAP 稳定被拦**（等到 82 秒仍挑战页）；Ahram 摇摆（1/2） |
| 国内官媒对照组（10 项） | 8 项 OK；**中新网 403** |

也就是说：**不挂代理的话，中东日报会稳定少掉约 1/4–3/10 的条目**，缺失集中在
伊拉克 / 苏丹 / 摩洛哥 / 也门 / 黎巴嫩。这是 IP 信誉问题，不是代码问题 ——
同一个浏览器、同一份代码，从本机家宽跑就全通。

另外两点平台差异：

- **无头 vs 有头**：本机用 `--offscreen`（有头、窗口移出屏幕），Cloudflare 更放行；
  runner 没有交互式桌面，所以云端设 `MENA_CDP_HEADLESS=1` 走无头。
  实测能过的那 3 家，无头同样能过。
- **证书链**：ONA / TAP 的证书链不完整。Windows 的 schannel 会用系统证书库补齐，
  本机与 Windows runner 都没问题；但**若将来换 Linux runner**，curl/OpenSSL 补不上，
  会报「CA 不受信」——需要给这两个源加 `-k`（`mena-lib.ps1` 的 `Get-UrlContent`
  已有 `-Insecure` 开关，只是 `Collect-Html` 没传）。

## 最后一步：接代理（等你需要时再做）

要让被拦的 5 家站恢复，只有换出口 IP。**建议只给这 5 家走代理**，其余直连，省流量。

改动就一处：解密展开后的 `bin/cdp-fetch.js`（源文件在
`Project_NewsEveryday\bin\cdp-fetch.js`）拼 Chrome 参数的地方，加：

```js
if (process.env.CHROME_PROXY) args.push('--proxy-server=' + process.env.CHROME_PROXY);
```

然后 workflow 里加 `CHROME_PROXY`（放 Secret），改完**记得重新打包**。

⚠ **带账号密码的代理不能这么做**：Chrome 的 `--proxy-server` 不认 URL 里的用户名密码，
需要额外用 CDP 的 `Fetch.enable` + `Fetch.authRequired` 事件回填凭据。
这部分**没有实现**。另外要选**粘性会话**（同一家站的列表页和文章页用同一个 IP），
因为 `cf_clearance` 是绑 IP 的。

选代理前建议先用探针验证它真的有用：`probe/gha-reachability` 分支上那套探针就是干这个的
（把代理配上跑一遍，看那 5 家能不能过）。市面上不少"住宅代理"实际是机房段，跑了才知道。

## 别踩的坑

- **别把 `mail-secret.clixml` 传上来**：DPAPI 密文换机器解不开，而且它是本机绑定的。
- **别把 `mail-config.json` 提交进仓库**：workflow 每次运行时在临时目录现生成。
- 云端与本机**不要同时跑**（都推 `main`）。
- 这个仓库是**公开**的；`payload.bin` 是密文，但**旧提交里的明文代码可能仍在 GitHub 服务端
  以"不可达对象"形式短时间存在**。要彻底清除只能删除仓库重建（那会中断 60 天内的
  「缓存原文」链接，除非把 `data/` 一并重新上传）。
- 私有仓库的 Windows runner 分钟数按 **2 倍**计，30 分钟/天约 1,800 分钟/月，
  接近 GitHub Free 的 2,000 分钟上限 —— 那时更适合换 Linux runner。
