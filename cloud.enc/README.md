# 云端副本（GitHub Actions）· **已启用（每日 02:05）**

> **2026-10-13 变更（本轮）**
> 1. **开启定时**：`schedule: 5 18 * * *`（UTC）= 北京 **02:05**，比本机（00:05）晚两小时；
>    手动 `workflow_dispatch` 照旧可用。
> 2. **加【云端】标记**：邮件主题与两份日报的正文标题都带【云端】（workflow 里设
>    `DAILY_CLOUD_TAG=1`；本机不设 → 一字不变）。用于和本机那份逐条对照。
> 3. ~~**定时那趟不推加密缓存页**：自动追加 `-NoPublish`。~~（**2026-10-25 已改**，
>    见下方「2026-10-25 变更」第 2 条；现在定时也会推"云端自建"的那部分。）
> 4. **口令轮换**：`CLOUD_CODE_KEY` 已重新生成（旧口令在本机已无迹可寻），
>    `payload.bin` 已用新口令重新打包。**必须把新口令同步到仓库 Secret**，
>    两边不一致时云端会在解密步骤报 `HMAC mismatch`。新口令见本机
>    `I:\AIWorkSpace\.dsh-tmp\cloud-code-key-20261013.txt`（建议转存密码管理器后删除该文件）。
> 5. **内联 PowerShell 改用 `shell: pwsh`**（2026-10-13 第一次真跑就撞上）：
>    用 `shell: powershell`（5.1）时，runner 把 `run:` 里的中文写进一个 **UTF-8 无 BOM**
>    的临时 .ps1，5.1 按 GBK 解码 → 中文乱码**吃掉闭合引号** → `ParserError`、整步失败。
>    症状极像"Secret 没配"，**判据是报错类型**：`ParserError` = 编码，`HMAC mismatch` = 口令。
>    管线本身仍以 `powershell.exe`（5.1）执行 —— 只有 workflow 的内联片段用 pwsh。

> **2026-10-25 变更（本轮：云端缓存复用）**
> 1. **本机先跑、云端后跑**：本机 00:05 生成并在 4.5 阶段把
>    `cache-index\<日期>.enc`（URL → 缓存链接的索引，用 `CLOUD_CODE_KEY` 加密）推到 Pages 仓库。
> 2. **云端复用本机缓存**：workflow 传 `-ReuseLocalCache`。云端阶段 3.5 先取本机索引：
>    本机已有正文的条目直接沿用本机「缓存原文」链接；只有「本机没缓存/本机没抓到正文」
>    的条目才自建缓存。**定时那趟不再强制 `-NoPublish`** —— 云端只推自己的那部分，
>    两边数据文件名带随机 token，互不覆盖（`digest-deploy.ps1` 的 reset+全量重灌已实测保留对方文件）。
> 3. **云端不发布索引**：索引以本机为准；否则云端"只含自建条目"的小索引会覆盖本机全量索引。
> 4. **无正文不挂链**：本机/云端都只给 `hasBody=true` 的条目挂「缓存原文」。
> 5. **不需要新 Secret**：索引用 `secrets.CLOUD_CODE_KEY`（与 `payload.bin` 同一个口令）；
>    未配置/口令不一致时云端退回"全部自建"，邮件照发。

本机那套「国际新闻日报 + 中东官媒日报」管线的云端副本。本机仍是主运行方式；
云端这份现在**每天也会跑一趟并发出对照邮件**（PC 关机那晚它照样跑）。

## 目录

```
.github/workflows/mena-daily-cloud.yml   明文（GitHub 必须能解析它）
cloud.enc/
├── payload.bin       管线代码的**加密载荷**（20 个文件：脚本 + 配置）
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
# 口令在 I:\AIWorkSpace\.dsh-tmp\cloud-code-key-20261013.txt 的最后一行（2026-10-13 轮换后的新口令）
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloud.enc\pack-cloud.ps1 `
    -Source I:\WorkSpaceForAI\international\Project_NewsEveryday `
    -Key '<新口令>'
git add cloud.enc/payload.bin
git commit -m 'cloud: 同步管线代码'
git push
```

**打包后建议自检一次**（用同一个口令解回来，确认 18 个文件都在、且带【云端】标记）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cloud.enc\bootstrap.ps1 `
    -Payload .\cloud.enc\payload.bin -Out $env:TEMP\cloud-check -Key '<新口令>'
Select-String -Path $env:TEMP\cloud-check\bin\send-mail.ps1 -Pattern 'DAILY_CLOUD_TAG'
```

换口令也是同一条命令（换完**必须**同步改 Secret，否则云端报 `HMAC mismatch`）。

> ⚠ **换口令还要改本机的索引口令**：`cache-index\<日期>.enc` 用的是同一个
> `CLOUD_CODE_KEY`（SHA-256 后当密钥）。把新口令写进
> `Project_NewsEveryday\_cache\cloud-code-key.txt`（最后一行，32 字符），
> 否则本机索引仍用旧口令加密，云端解不开 → 退回"全部自建"（邮件照发，只是更慢）。
> 已发布的旧索引不用重做；换口令后新生成的索引才用新口令。

## 已启用的状态 / 怎么停

- **定时**：北京 02:05（`5 18 * * *` UTC），每天跑一趟，**发对照邮件**。
- **本机照常跑**（北京 00:05）。两边刻意错开两小时：本机先把索引和数据推上去，
  云端 02:05 才能复用。云端只推"自己自建"的那部分（文件名带随机 token），
  `digest-deploy.ps1` 实测会保留对方已有的 `data\*`；不会互相顶掉。
- **想停掉云端定时**：把 workflow 里 `schedule:` 那两行注释回去即可（手动触发仍可用）。
- **副作用/边界，知情即可**：
  1. 云端邮件的「缓存原文」= 本机已缓存的链接 + 云端自建链接；**没抓到正文的条目仍然没有**；
  2. 本机当天没跑成 / 索引没推上去时，云端会退回"全部自建"（邮件照发，但抓正文更慢）；
  3. 两边共用同一个 `MAIL_USER`，MyMemory 翻译配额（5 万字符/天）按它算，可能相互抢；
     撞了只是部分标题不翻译，不影响发信。真要彻底避免，就让云端隔天跑。

### 第一次真跑记录（2026-10-13 · run #4 · `workflow_dispatch` 试跑）

- 触发参数：`no_mail=true, no_publish=true` —— 只验证"采集 → 成稿"，**不发信、不推缓存页**。
- 结果：**全部步骤 success**，耗时约 22 分钟（国际 93 s ＋ 中东 1262 s）。
- 产物：`daily-2026-10-12`（939 KB：`reports` 2 ＋ `logs` 1 ＋ `archive` 4 ＋ `archive-mena/raw` 60）。
- 验证到两件事：① 加密载荷解得开（新口令 + Secret 正确）；
  ② **【云端】标记生效** —— 两份日报标题为
  `# 中东官媒每日信息清单【云端】 · 2026-10-12` 与 `# 官媒国际新闻日报【云端】 · 2026-10-12（周一）`。
- 首跑还撞上一个坑（已修，见上文第 5 条）：**内联 PowerShell 用 `shell: powershell`（5.1）时中文被按 GBK 解码 → `ParserError`**。
- ⚠ **该次试跑的条目数不能当"云端惩罚"用**：日期是 10-12，而本机那份 10-12 日报是 **22 小时前**采的，
  列表页翻页 + 目标日过滤会刷掉大量条目（中东 94 vs 258、国际 98 vs 148 的差距主要来自这个）。
  干净的对照只能看**同一天、相隔 2 小时**的两趟（本机 00:05 / 云端 02:05）。

## 已知限制（来自探针在真实 runner 上的实测，不是推测）

出口 IP 是 Azure 机房段（实测 `130.131.204.201`、`48.211.211.35`）。两次运行、
两个不同 runner，结果**高度一致**：

| 类别 | 结果 |
|---|---|
| 中东 HTTP 通道（17 项） | 15 项 OK；**NNA（黎巴嫩）稳定被 Cloudflare 403**；APS（总统）稳定取到空页面 |
| 中东浏览器通道（9 项） | 探针初测（2026-10-08）：MENA / IRNA / Arab News 通过；SABA、INA、Al-Sabah、SUNA、MAP 被拦；Ahram 摇摆。<br>**2026-10-13 真跑（run #4）实测更新**：只有 **Arab News（19 条）与 IRNA（20 条）通过**；**MENA、Ahram、SABA、INA、Al-Sabah、SUNA、MAP 共 7 家"三轮均被 Cloudflare 拦截，放弃该源"**（MENA 已不再稳定通过） |
| 国内官媒对照组（10 项） | 8 项 OK；**中新网 403** |

也就是说：**不挂代理的话，中东日报会稳定少掉约 1/4–3/10 的条目**，缺失集中在
伊拉克 / 苏丹 / 摩洛哥 / 也门 / 黎巴嫩。这是 IP 信誉问题，不是代码问题 ——
同一个浏览器、同一份代码，从本机家宽跑就全通。

> ⚠ 2026-10-25 的「复用本机缓存」**只解决缓存页，不解决条目缺失**：
> 云端采不到的源，本机缓存里也没有对应条目可复用。要补条目，只能接代理（见下节）。

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
