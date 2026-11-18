# 解析样本（EHFixtures）

本目录是 `EHFixtures` target：存放 E-Hentai / ExHentai 页面样本，以及加载样本、检查样本卫生的代码。
`EHParsingTests`、`EHNetworkTests`、`EHFixturesTests` 和采集工具（`Tools/FixtureCapture`）依赖它；App 不链接。

## 目录

| 路径 | 内容 |
|---|---|
| `eh/` | 从 e-hentai.org 采集的样本（captured） |
| `ex/` | 从 exhentai.org 采集的样本（captured） |
| `constructed/` | 人工构造的样本（constructed），说明见 `constructed/README.md` |
| `local/` | **私有样本，只存本机、不入库**（git 忽略，只有空的 `.gitkeep` 入库）：个人偏好页面的采集结果，以及它们的索引 `local/manifest.local.json`，见下面「私有样本」 |
| `manifest.json` | 样本索引：每个样本文件一条记录（路径、站点、来源、请求与响应摘要） |
| `Fixtures.swift` | 加载器：`Fixtures.data(_:)`、`Fixtures.string(_:)`、`Fixtures.manifest()` |
| `FixtureManifest.swift` | `manifest.json` 的数据结构 |
| `FixtureHygiene.swift` | 卫生检查 |

`eh/`、`ex/` 里的 `.gitkeep` 只用来让空目录入库（SPM 的 `.copy` 要求目录存在），不是样本。`local/.gitkeep` 同理：`EHFixtures` target 用 `exclude: ["local"]` 把 `local/` 排除在资源包外，SPM 要求被排除的目录存在，否则每次构建都报 warning。

## 两种来源

- **captured（采集）**：采集工具对站点做只读请求后保存的真实响应，写盘前已去除个人信息。
  `manifest.json` 里记录请求方法、URL、状态码、`Content-Type`、`Location`、响应设置的 cookie 名（只记名字，不记值）和采集时间（UTC）。
  `eh/`、`ex/` 下的每个文件都必须有一条 `source` 为 `captured` 的记录。
- **constructed（构造）**：站点不方便或无法稳定返回的情况（错误页、边界情况等），由人手写或在采集样本基础上修改而成。
  只放在 `constructed/` 下，记录里用 `derivedFrom` 指明改自哪个采集样本（如有）。

## 私有样本（本机，不入库）

用户 2026-11-04 决定：个人偏好页面不提交进仓库。涉及两站各 5 个页面：

- `{s}/account/mytags.html`：用户的标签设置；
- `{s}/list/favorites.html`、`{s}/list/favorites-cat0.html`、`{s}/list/favorites-search.html`：用户的收藏；
- `{s}/list/watched.html`：按用户订阅标签得到的结果。

清单写在 `FixtureHygiene.privatePagePaths`（采集工具的 `PrivateFixtures.paths` 就是这一份，2026-11-07 M1 收尾修复从工具挪进 `EHFixtures`）。这些页面照常采集、照常脱敏、照常过写盘前的卫生检查；从它们发现的秘密照样进秘密集合，用来遮蔽其他页面。不同之处只在存放位置：

- 正文写到 `local/<原相对路径>`，例如 `local/eh/list/favorites.html`；
- manifest 条目写进 `local/manifest.local.json`，格式与 `manifest.json` 相同，路径相对样本根目录（`local/eh/…`）。入库的 `manifest.json` 里没有它们的条目。
- `.gitignore` 忽略 `/Packages/ErosKit/Tests/Fixtures/local/`；同时也忽略 `/Packages/ErosKit/Tests/Fixtures/manifest.local.json`，以防有人把本机 manifest 放在根目录。
- 不论替换哪个站点，采集工具写盘时都把这 11 个旧路径（不在 `local/` 下的那份）当作「不得存在」：有就删掉，`manifest.json` 里的旧条目一并去掉，并在输出里列出删了哪些路径。
- 入库路径另有一道守卫（2026-11-07 M1 收尾修复）：`EHFixturesTests` 的 `privatePagesAreNotAtCheckedInPaths` 在 `eh/`、`ex/` 下找到这 11 个路径中的任何一个（不分大小写），或在 `manifest.json` 里见到它们的条目，就失败。不论是工具写的还是手工拷进去的都拦；订阅列表没有结构规则兜底，靠的就是这一条。
- `local/` 不进资源包，`Fixtures.data(_:)` 读不到它，入库测试也不依赖它。它只供以后的里程碑在本机参照真实结构，做可以入库的构造样本。
- `EHFixturesTests` 的卫生扫描（结构检查与已知秘密检查）在 `local/` 有文件时也扫它（从源码树读），没有时不报错。非空守卫只统计入库的 `eh/`、`ex/`，下限是 `Fixtures.minimumCapturedFixtures`（EH 32、EX 26，与计划 Task 14、路线图 M0 退出标准 3 同一组数）。
- 防泄露检查从这里的 mytags、收藏和订阅页面取值，查它们有没有被带进入库文件；`local/` 本身不在被查之列。见下面「卫生检查」。
- 这些页面按设计显示账号的收藏标记和自己的评分、投票，所以结构规则 `favmark`、`accountmark` 对 `local/` 下的文件放行（`FixtureHygiene.isAllowedInPrivatePage`），别处都不放行。

### 离线导入的论坛资料页（2026-11-05 补）

用户 2026-11-05 决定：论坛资料页（`eh/forum/profile.html`）的真实样本只存本机，也算私有样本（`PrivateFixtures.paths` 共 11 个）。它不由采集工具抓取（论坛对工具返回 403），而是用户在自己已登录的浏览器里把资料页另存为 HTML 源码，再离线导入：

```bash
swift run --package-path Tools/FixtureCapture fixture-capture import <另存的文件> --as eh/forum/profile.html
```

- 照常脱敏（昵称从 `#profilename` 发现并写入本机秘密文件，会话号等论坛密钥遮蔽），过同一道写盘闸门；导入前要求已知用户名和 member id（环境变量或秘密文件）。
- 正文写到 `local/eh/forum/profile.html`，条目写进 `local/manifest.local.json`，条目的 URL 是占位值 `showuser=1111111`；`manifest.json` 与 `eh/forum/` 不变。之后执行 `capture --sites eh` 不会删掉它；再次导入则替换。
- 入库测试用构造样本（解析计划 P6），不用这份真实页面。
- **导入后请删掉浏览器另存的原文件**：它仍含用户名、member id 和会话号。

## 卫生检查

入库的样本不得含有任何个人信息：用户名、member id、apikey、cookie 值、收藏备注、IP 等。`FixtureHygiene` 提供两类检查，
采集工具写盘前和 `EHFixturesTests` 都用同一套；`EHFixturesTests` 另有一道只在本机运行的防泄露检查（第三条）：

- **结构检查**（`structuralViolations`）：不依赖任何秘密，在任何机器上都能跑。查页面里的 `apikey`、`apiuid`、
  登录相关 cookie 值是否已遮蔽，是否出现 `203.0.113.0/24`（文档保留网段）之外的 IPv4，收藏备注是否已替换为占位符，
  以及种子密钥、种子链接和 home.php 的统计数字是否已遮蔽（见下面「种子与 home.php」），标签元素是否还带着 style、
  「Filtered N galleries」和归档余额是否已遮蔽、列表页是否还有「Filtered N galleries」那一行、论坛的会话参数是否已遮蔽、页面是否带着账号的收藏标记，或者账号自己的评分、标签投票、评论投票和评论（见下面「按账号渲染的页面内容」）。
  「已遮蔽」指字母数字只剩 `1`、`a`、`A`。结构检查也扫 `constructed/`（`constructed/README.md` 除外，见下面「README 只做秘密检查」）；按设计要违反某条规则的构造样本只能在
  `FixtureHygiene.constructedExemptions` 里逐个豁免并写明理由（目前有四项：`constructed/eh/list-filtered.html` 的
  `filteredlist`，`constructed/eh/list-favorites.html` 与 `constructed/eh/detail-favorited.html` 的 `favmark` 和 `accountmark`，`constructed/eh/account-mytags.html` 的 `tagstyle`）。这张表由 `EHFixturesTests` 的扫描和采集工具的 `resanitize --constructed` 共用，只对 `constructed/` 下列出的文件和规则生效。
- **秘密检查**（`secretViolations`）：拿本机已知的秘密（采集用的 cookie、member id、用户名）逐一搜索，
  包括 HTML 转义（含 `'` 的几种写法，以及 `&`、`"` 写成十进制字符引用 `&#38;`、`&#34;` 或十六进制 `&#x26;`、`&#x22;` 的写法）、
  百分号编码和 JSON 转义（`/` 转义成 `\/` 与不转义两种）后的写法，**不区分大小写**（数字字符引用与 JSON 不转义 `/` 的写法为 2026-11-05 M1 加固所加）。用户名和 member id
  按词边界和数字边界匹配，紧跟在 `%XX`、JSON 的 `\uXXXX` 等转义后面也算边界。没有秘密的机器上，
  `capturedFixturesContainNoKnownSecrets` 显示为 skipped。秘密检查也扫两份 README（见下），以及仓库里 git 管着或将要加入的全部其他文本文件（与下面防泄露检查同一份清单：测试源码、`docs/`、`Tools/FixtureCapture/targets.json` 等；2026-11-07 M1 收尾修复加，防止用户名、member id、昵称被写进测试或文档），报告写成从仓库根算起、以 `/` 开头的路径，例如 `/docs/…:12: secret:word`。git 列不出仓库时（不是 Mac，或不在检出的仓库里），这条测试显示为 skipped。
- **防泄露检查**（`localLeakViolations`，规则名 `localleak`；2026-11-06 M1 加，同日修复第 1 轮改为逐文件放行）：防止构造样本、说明文件、测试代码和文档把只有私有样本才看得到的内容带进仓库。构造样本的结构可以照 `local/` 做，内容必须编造。
  - **何时运行**：只在本机 `local/` 下有 `*/account/mytags.html`、`*/list/favorites*.html` 或 `*/list/watched.html` 时运行（`LocalLeakTests` 的 `checkedInFixturesLeakNothingFromLocal`）。CI 和新克隆的仓库没有这些页面，显示为 skipped。
  - **取什么**（四类私有值）：
    - mytags 页面所有 `title` 属性里形如「小写命名空间:标签」的标签名，连同去掉命名空间的标签本身。不以「小写命名空间:」开头的 title（页面自己的提示文字、权重输入框）都不取。
    - mytags 页面标签组选择框（`onchange` 里提到 tagset 的 `select`）里的标签组名，去掉后面的「(标签数)」；站点给新标签组的默认名「Tagset #N」不算。
    - 收藏和订阅列表里的 `/g/<gid>/<token>/` 画廊链接，以及画廊标题（class 含 `glink` 的元素的文本）。
    - 先还原字符引用，再一律转成小写。
    - 私有页面在、却一个标签名、一个链接或一个标题都取不出时，测试直接失败：页面结构可能变了，检查会形同虚设。标签组可以全是默认名。
  - **查哪里**：
    - `constructed/` 下全部文件（含 `constructed/README.md`）、`manifest.json` 和本文件；
    - 仓库里 git 管着或将要加入的全部文本文件（`git ls-files --cached --others --exclude-standard`，含测试源码、`docs/`、`Tools/FixtureCapture/targets.json`），报告里写成从仓库根算起、以 `/` 开头的路径，例如 `/docs/…`；样本目录的 `eh/`、`ex/`、`local/`、`constructed/`、`manifest.json`、`README.md` 已由上一条覆盖，不重复扫；含 NUL 字节的文件（图片）跳过；
    - 不查入库的 `eh/`、`ex/` 采集样本：它们本身就是公开页面，账号相关的收藏标记、评分和投票改由结构规则 `favmark`、`accountmark` 管（见下面「按账号渲染的页面内容」）；也不查 `local/` 本身。
  - **放行什么**（逐文件，2026-11-06 编排者裁定，替换原来的「全局减去公开值」）：
    - 构造样本只放行它在 `manifest.json` 里 `derivedFrom` 所指的那份入库样本（`eh/`、`ex/` 或 `constructed/` 下）里也出现的值。照私有值手写的构造样本（没有 `derivedFrom`，或 `derivedFrom` 指向 `local/`）、两份 README 和 `manifest.json` 一个都不放行。所以私有值碰巧出现在别的入库样本里，也不能照抄进构造样本。
    - 仓库的其他文件同样不放行，只有一个例外：裸标签（不带命名空间的标签本身）只要在某个入库样本里出现过，就当普通词放行。代码和文档免不了用到站点上的常见词；带命名空间的标签名、标签组名、标题和链接照样不放行。
  - **怎么匹配**：
    - 不区分大小写；前后不能紧挨 ASCII 字母或数字，所以更长的标签、别的画廊都不算。`_`、`:`、`/`、引号算边界；紧跟在 `%XX`、`\uXXXX` 等转义后面也算边界。
    - 标签、标签组名和标题也认这些写法：HTML 转义、百分号编码（空格写成 `%20` 或 `+`）、JSON 转义；多词标签的空格还可以写成 `_`（详情页的标签 id）或 `+`（`/tag/` 链接）。
    - 画廊按单独出现的 10 位十六进制 token 认（所以 `gid=…&t=…`、`archiver.php?…&token=…`、脚本里的 `var token`、任何排版的 JSON、`&#47;` 分隔符都算），也按 `<gid>/<token>` 认（`/g/`、`/mpv/` 链接，`/` 写成 `\/`、`%2F`）。token 是 40 位随机值，别的值碰巧等于它的概率可以忽略。
    - 判断「放行」也用这一套匹配。
    - 已知认不出的写法：空格写成 `&nbsp;`、`&#32;`、`%2B` 或 `-`，非 ASCII 字符写成字符引用，`&amp;#039;` 这种双重转义，JS 的 `\xXX` 转义。这些都不是站点或常见编辑器写出来的样子。
  - **取值的函数**：返回私有值本身的集合（`FixtureHygiene.localOnlyTokens`、`localValues`）不是 public，只供 `@testable` 的测试用；对真实数据只能取计数（`localValueCounts`）或交给检查函数，不得对它写 `#expect`，也不得打印它。
  - **报告**：每个命中的行报一条，只有「文件:行: localleak」，不含标签名或链接。命中后把那一行的值换成编造的。

**README 只做秘密检查**：本文件和 `constructed/README.md` 引用了规则原文（示例链接、「Filtered N galleries」这类句子），做结构检查会误报，所以只做秘密检查，不做结构检查（上面的防泄露检查照样查它们，而且不放行任何私有值）。本文件不在资源包里（`EHFixtures` target 排除了它），扫描从源码树读（`FixtureFiles.sourceRoot`）。

违规报告只包含文件、规则名和行号，从不包含匹配到的值。

采集工具去除个人信息时不另写规则，直接用检查自己的匹配结果：`violatingCaptures(ofRule:in:)` 给出结构规则判为违规的捕获范围，`secretMatches(of:in:)` 给出秘密的每处出现及其编码形式（`encodedForms(of:)` 的下标）。检查标出什么，采集工具就改什么。

### 种子与 home.php（2026-11-04 补）

第 2 次采集发现这几处原有规则管不到，于是加了 6 条结构规则（`announce` 为修复第 2 轮从 `tracker` 拆出）。遮蔽都用 `mask()`（数字 → `1`、小写 → `a`、大写 → `A`），长度、字符类别和页面结构不变。URL 里的 `/` 写成 JSON 的 `\/`、`%2F`、`&#47;` 或 `&#x2F;` 时同样命中；路径段的值一直取到下一个分隔符，所以里面多了 `_`、`-` 之类也照样命中。

| rule | 位置 | 遮蔽什么 | 是否另作为秘密全站搜索 |
|---|---|---|---|
| `torrentkey` | home.php「Your current key is:」后面的值（实测在 `<span style="font-weight:bold">` 里；词之间可以是任意空白，冒号可省，前面最多跳过 2 个标签和 `&nbsp;`、`&#160;`） | 账号的种子密钥 | 是（literal），但只收至少 8 个字符、只含 ASCII 字母和数字、并且含数字或首字符之后还有大写字母的值；其余的（多半是普通词，不论在哪个标签里）只就地遮蔽 |
| `torrentlink` | 种子弹窗的个人下载链接 `/get/<n>/<段>/<uid>-<key>/<info hash>.torrent`（也认 `/torrent/`），以及 `ehtracker.org`（可带端口）上带个人段的 announce `…/[<n>/]<uid>-<key>/announce` | `uid` 与 `key`，分别遮蔽，`-` 保留 | 是（uid 为 numeric，是凭据时不写进秘密文件；key 为 literal）；短于 5 位的 uid、短于 8 个字符的 key 只就地遮蔽 |
| `tracker` | `ehtracker.org`（可带端口）上 `/<n>/announce` 里的数字（后面可以跟个人段）；两种下载链接 `/get/` 后的 `<n>` 与 `<段>` | 这串数字与紧跟的密钥段 | 密钥段是（literal，至少 8 个字符）；数字至少 5 位，且只有在本次运行的所有页面里都不是 gid 时才是（numeric） |
| `homestats` | home.php 里每个「`<h2>` 标题（里面可以有标签）之后、下一个标题之前的第一个 class 含 `homebox` 的 div（中间可以夹别的元素）」起的区块，**Image Limits 除外**，到下一个标题或页脚为止；元素文本中的每个数字，后面紧跟单位字母也算 | 数字 → `1` | 否，只就地遮蔽 |
| `trackerurl` | `ehtracker.org`（可带端口，可以没有路径）URL 的每个路径段、每个 query 值（没有 `=` 的项整体算一个值，`?=` 这种空名字后面的值也算）和 `#` 之后的 fragment（整体算一段，`/` 也在里面）（fail-closed 兜底） | 只检查、不遮蔽：除 `get`、`torrent`、`announce` 和 `<40 位十六进制>.torrent` 外，每段、每个值都必须已遮蔽，否则采集工具拒绝写盘、交给人看 | 否 |
| `announce` | 别的 host 上的 `/<n>/announce`、`/<n>/<uid>-<key>/announce`、`/<uid>-<key>/announce` | 这些数字与 key | **否**，只就地遮蔽：`/2024/announce`、`/5/announce` 这类普通链接要是进了秘密集合，年份、页数会被全站改成 1 |

- **home.php 覆盖的块**：Image Limits 以外的全部区块。现在的页面是 EHTracker（上传量、下载量、比率、Torrent Completes、Gallery Completes、Seedmins）；Total GP Gained（四项 GP，含 GP from Hentai@Home）；Toplists（H@H 排行名次：Past Year、Past Month、Yesterday）；Moderation Power（当前值和全部分项，连「capped at」后面的上限也遮蔽）。以后站点新增的区块默认也遮蔽。排行榜是公开的，凭名次能反查账号；GP 总数、种子统计和 Moderation 分项能缩小范围，拿不准的一律遮蔽。
- **不遮蔽**：Image Limits 块的 current、limit 和重置花费（重置花费随当前用量变化，不能识别账号；M6 的 home 解析器要用）；属性里的数字（如 `toplist.php?tl=31`、`width:40%`、颜色值）；`&#039;` 这类字符引用和 `%XX`；夹在单词里的数字；种子的 info hash（公开）；画廊 gid 与 token。`torrents.php?u=` 里的是 member id，由 member id 秘密遮蔽。
- **另一道检查**：`HomePageCheck`（`HomePageCheck.swift`）不用上面的正则，自己去掉脚本、样式、注释、标签、字符引用和 `203.0.113.x` 替身后，查 `*/account/home.html` 在 Image Limits 之外的元素文本：只许出现 `1`。采集工具写盘前对每个 home.php 跑它，不通过就拒写，并提示页面结构可能变了；`EHFixturesTests` 的 `capturedHomePagesShowNoUnmaskedNumbers` 用它查入库样本，还没有这个样本时显示为 skipped。
- **2026-11-05 M1 加固**：
  - `trackerurl`：query 里没有 `=` 的项（`?<key>`、`&<key>`、`&amp;<key>`）整体当作值来判，`#` 之后的 fragment 也当作一段来判；没有路径的 `ehtracker.org?…` 同样检查。`&amp;`、`&#47;` 这类字符引用仍然只算分隔符。
  - `torrentkey` 的收录：只有至少 8 个字符、只含 ASCII 字母和数字，并且含数字、或首字符之后还有大写字母的值，才作为秘密全站搜索。以前紧挨 `<span>`/`<strong>`/`<b>` 的值也收，但加粗的普通词（如「Downloads」「Unavailable」）会落进同一个标签，被误当成密钥、全站替换，所以删掉了这一条。条件里加上「首字符之后有大写字母」，是因为随机密钥一个数字都不含的概率约有 17%（10 位、大小写字母加数字），只看「含数字」会漏收这些密钥。现在只剩全小写、或只有首字母大写的纯字母密钥会漏收，概率约 0.03%。不收的值照旧就地遮蔽。
- **announce 里那串数字**：它与两种下载链接 `/get/` 后面的数字相同，不是 member id，也不是目标画廊的 gid；它比目标画廊和 Parent 的 gid 都小，种子发布时间也早于画廊，很可能是种子最初所在的旧版画廊的 gid（公开值）。但离线无法证实，排除不了因人而异，所以按「每个用户各不相同」保守遮蔽。它只有在本次运行的所有页面（正文、URL、`Location`）里都没有当过 gid（`/g/<gid>/`、`/mpv/<gid>/`、`/s/<key>/<gid>-<n>`、`gid=`、`"gid":`）时，才作为 numeric 秘密全站搜索；当过 gid 的只就地遮蔽，因为画廊没有旧版时这个数字就是本画廊的 gid，全站替换会把列表、详情页和 manifest 里的 gid 一起改掉。

### 按账号渲染的页面内容（2026-11-05 补）

Task 11 首次采集的那次提交（已被改写掉）漏遮了三处：页面本身是公开的，但站点按账号的设置渲染了它们。

| rule | 位置 | 处理 |
|---|---|---|
| `tagstyle` | class 含 `gt`、`gtl`、`gtw`、`gtb` 的标签元素上的 inline `style`（class 带不带引号都算，如 `class=gt`）：列表页和排行页按 My Tags 给标签着色（color、border-color、background），详情页给部分标签加 opacity | **整段删除 style 属性**，元素和 `title` 保留。只换颜色不够：有没有 style 本身就说明这个标签在不在 My Tags 里。检查时只要带 style 就违规（fail-closed） |
| `filtered` | 列表页「Filtered N galleries from this page」里的 N（按账号的标签过滤算出）；词之间可以是空白、`&nbsp;`、`&#160;`、`&#xA0;` 或标签 | 数字 → `1`；「Found about N results」不动（只取决于搜索词和已入库的 uconfig 设置） |
| `funds` | 归档弹窗「Current Funds」那一段里的 GP 与 Credits 余额（EX 不显示）；两个词之间、冒号前后可以是空白、`&nbsp;`、`&#160;`、`&#xA0;`；标签自成一段时取下一段；范围到下一个 `</p>`，中间夹着 `<p`、`<div>`、`<br>` 等标签也不截断；只有后面再也没有 `</p>` 时，才到下一个 `<p`、`</div>` 或文末为止 | 数字 → `1`，千分位保留；段落之后的下载花费是画廊的，不动（畸形页面里落进范围的下载花费会一起遮蔽） |
| `filteredlist` | 与 `filtered` 同一行，N 遮蔽与否都算 | **只检查、不处理**：入库或本机的采集样本里出现这一行就拒写、测试失败（fail-closed），只能关掉过滤重采，见下 |
| `forumkey` | 恰好 32 位十六进制的论坛参数值，出现在三类位置：<br>1. URL query 里的 `s`、`k`、`auth_key`、`md5check`（前面是 `?`、`&`、`&amp;` 或 `;`）；<br>2. 脚本或 JSON 里给这些名字，以及页面脚本的 `ipb_var_s`、`ipb_md5_check`、`secure_hash`、`session_id` 赋的值（`= "…"`、`: "…"`、`['…'] = '…'`，JSON 转义的引号也算）；<br>3. 名为 `s`、`k`、`auth_key`、`md5check` 的 hidden input 的 `value`。<br>它们是 IPB 论坛页面链接、脚本与表单里的会话号、登出密钥和校验值，离线导入的论坛页面会带着它们 | 数字 → `1`、字母 → `a`/`A`，参数名、引号和 `&`、`&amp;` 保留。采集工具还会把发现的值作为本次运行的 literal 秘密，在全部页面里搜索其他写法（百分号编码等），但**不写进秘密文件**：会话号和登出密钥是令牌。`auth_key`、`md5check` 由会员的 login key 派生，不随会话变化 |
| `favmark` | 账号的收藏标记：<br>1. 列表行 `posted_<gid>` 元素上的 `style` 或 `title`（收藏过的画廊，日期带收藏夹的颜色和名字）；<br>2. 详情页 `#fav` 里的任何内容（收藏夹图标）；<br>3. 详情页 `#favoritelink` 的文字不是「Add to Favorites」；<br>4. 收藏弹窗的 `favdel` 选项（只有已收藏才出现）；<br>5. 收藏夹名不是站点默认的「Favorites 0」到「Favorites 9」（或已遮蔽）：uconfig 的 `favorite_<n>` 输入框、收藏弹窗的名字、收藏夹图标（`class="i"`）的 title 和 favorites.php 上紧跟其后的名字、favorites.php 的 `fav<n>` 选项 | **只检查、不处理**（2026-11-06 M1 加）：入库样本出现就拒写、测试失败，换一个不在收藏里的目标或以后再采。`local/` 下的私有页面按设计带着这些标记，放行；按设计要显示收藏状态的构造样本（如 P3 的 `detail-favorited.html`、P2 的收藏列表）要在 `constructedExemptions` 里逐个豁免并写明理由。采集当时两站入库样本 0 处 |
| `accountmark` | 账号自己的痕迹（收藏以外）：<br>1. 星级元素的 class 含 `irr`、`irg`、`irb` 或 `iry`（本人评分；只有 `ir` 是平均分）；<br>2. class 为 `tup` 或 `tdn` 的元素（`#taglist` 里本人投过票的标签链接）；<br>3. `comment_vote_up_<n>`、`comment_vote_down_<n>` 带非空 `style`（本人投过票的评论）；<br>4. 出现 `edit_comment(`（本人评论的 Edit 链接） | **只检查、不处理**（2026-11-07 M1 收尾修复加，审查 tooling I-2）：入库样本出现就拒写、测试失败，换一个本人没评分、没投票、没评论的目标或以后再采。`local/` 下的私有页面放行；按设计要显示这些状态的构造样本（`detail-favorited.html`、`list-favorites.html`）在 `constructedExemptions` 里逐个豁免。加规则时两站入库样本 0 处。账号作为上传者或评论者、名字被遮蔽后出现在公开页面里也要拒写【用户决定 2026-11-07】；规则尚未加，须在下一次 `capture` 之前做完（见路线图 M2「M1 遗留输入」） |

**2026-11-05 M1 加固**：
- `tagstyle` 也认没有引号的 class（`class=gt`，取到空白或 `>` 为止）。
- `funds` 也认 `Current&nbsp;Funds`、`Current&#160;Funds` 这类写法。后面再也没有 `</p>` 时，范围到下一个 `<p`、`</div>` 或文末；范围里最后一个数字后面没有标签，也照样判。
- 新增 `forumkey`，排在规则表末尾（`filteredlist` 之后）。

另外查过、确认不是按账号渲染的：评分星的 `div.ir` style（画廊平均分，没有用户自己打分的 irr/irg/irb 类）、缩略图 `glthumb` 和图片的尺寸 style、「(Disowned)」等标签的 opacity、`title="ns:tag"`（公开标签名）。收藏标记（posted 日期上的边框与收藏夹名）和用户评分在这批样本里没有出现；如果以后出现，同样要处理。

**列表页关掉过滤采集（2026-11-05，用户决定）**：被 My Tags 隐藏的画廊不会出现在列表里，站点为了凑满一页会往后补。拿每页首尾的 gid 或翻页链接去不带过滤地请求同一范围，多出来的就是被过滤的画廊，取它们标签的交集就能推出用户隐藏了哪些标签；只遮 N 堵不住（复审 N1）。所以采集工具请求列表页时带上页面里「Disable Filters」链接的参数 `f_sft=on&f_sfu=on&f_sfl=on`（两站一致；只是请求参数，不改网站设置），manifest 里这些页面的 `url` 也带着它们。2026-11-04 那次出现这一行的是两站各 9 个列表页：front、front-next、front-seek、category、search、search-advanced、popular、tag、uploader；toplist、search-empty、以图搜图结果页和本机的 favorites、watched 都没有，照旧请求，以后哪一页出现了，`filteredlist` 会让写盘被拒。测试解析器读这一行用构造样本 `constructed/eh/list-filtered.html`（只对它豁免 `filteredlist`）。

规则加严以后，一般不必重采：`fixture-capture resanitize` 会用当前规则离线重处理已写好的样本（见 `Tools/FixtureCapture/README.md`）。`filteredlist` 是例外，带这一行的列表页只能重采。

## 本机秘密文件 `.fixture-secrets.local`

位于仓库根目录，由采集工具写入，权限 0600，**已被 `.gitignore` 忽略，绝不入库**。用途：采集结束后，
即使不再设置 cookie 环境变量，测试也能在本机复查样本里没有这些秘密。

- 内容：除采集时发现的值外，也存用户名（`EH_USERNAME`，word）与 member id（`EH_IPB_MEMBER_ID`，numeric），这样不带 `op run` 也能离线扫描与导入；登录令牌（pass hash、igneous、sk、hath_perks、star、yay、iq、cf_clearance、cf_duid）仍然不存。带凭据运行 `fixture-capture capture` 或 `resanitize` 时，缺的这两行会补进文件。
- 格式：每行 `<kind><TAB><value>`，`kind` 为 `numeric`、`word`、`literal` 之一；`#` 开头的行和空行忽略。含换行或制表符的值写不进这种格式，不写整段；采集工具会把多行备注的每一行另记为一条。
- 采集工具先写同目录的临时文件 `.fixture-secrets.local.<UUID>.tmp`（0600）再改名覆盖，`.gitignore` 用 `/.fixture-secrets.local*` 一并忽略。没有可保存的秘密时既不创建也不覆盖这个文件。
- 测试按 `#filePath` 向上找到仓库根再读取它；在 git worktree 里运行时，找的是**该 worktree 根目录**下的
  `.fixture-secrets.local`。设置环境变量 `EH_FIXTURE_SECRETS_FILE` 可改用其他路径。
- 设置了 `EH_FIXTURE_SECRETS_FILE` 但文件不存在，或者秘密文件存在却读不出任何秘密时，`localSecretsFileIsUsable`
  会直接失败，避免秘密检查悄悄被跳过；失败消息只给出路径。
- 秘密也可以直接来自环境变量（`EH_IPB_MEMBER_ID`、`EH_USERNAME`、`EH_IPB_PASS_HASH` 等，见 `FixtureHygiene.credentialEnvironmentKinds`）。
- 秘密检查只在 Mac 上用 `swift test` 运行时生效：在模拟器上或经 `xcodebuild` 运行时，shell 里的 `EH_*`、
  `EH_FIXTURE_SECRETS_FILE` 不会传给测试进程。

## 采集记录

采集工具：`Tools/FixtureCapture`（`fixture-capture capture`），一次一个站点；只读请求，限频由工具负责。抽查人：Task 11 实施者（Claude），编排者复核。下面不写任何个人信息。

### 本批样本（2026-11-05 重采）

- **采集时间**：2026-11-05 凌晨（JST，UTC+9），EH 约 02:02，EX 约 02:03–02:04。manifest 的 `capturedAt` 用 UTC，对应 2026-11-04 17:02–17:04。
- **配置编号**：Flutter 版在账号里自动建的 Eros-FE 配置，在 EH 上是 **4** 号，在 EX 上是 **2** 号。采集工具用 `EH_SP` 选配置，这个变量两站共用，所以两站是分开采的：先用 `EH_SP=4` 跑 `--sites eh`，再用 `EH_SP=2` 跑 `--sites ex`。工具每次只替换本站的样本，另一站的保留。
- **站点显示设置**：两站的这个配置都是 **Compact**（首页列表 `itg gltc`），「Always use the Multi-Page Viewer」都是 **Nope**（所以画廊页缩略图链到 `/s/` 图片页）。画廊页缩略图区 `#gdt` 的 class 是 `gt200`。EX 的这两项是用户采集前自己在站点上设的；工具和采集者都没有改过站点设置。
- **列表页关掉过滤采集**（用户决定）：两站各 9 个列表页（front、front-next、front-seek、category、search、search-advanced、popular、tag、uploader）的请求都带 `f_sft=on&f_sfu=on&f_sfl=on`。入库样本里没有「Filtered N galleries」这一行。
- **结果**：EH 37 个样本，其中 32 个入库，5 个在 `local/eh/`；EX 31 个，其中 26 个入库，5 个在 `local/ex/`。只存本机的是个人偏好页面：`account/mytags`、`list/favorites`、`list/favorites-cat0`、`list/favorites-search`、`list/watched`。
- **跳过的样本**：
  - `{eh,ex}/gallery/content-warning.html`：挑选画廊时，在请求预算内没遇到内容警告页（`targets.json` 的 `contentWarningGallery` 为 null）。
  - 论坛资料页：M0 计划不采（首次试采时 `forums.e-hentai.org` 返回 403）。
- **H@H 主机**：两站都有两种形状，都不是 IP。
  - `<label>.hath.network`：一层，没有端口；
  - `<label>.<label>.hath.network:<port>`：两层，端口不是 443。
  
  同一类页面两种都可能出现，取决于分到哪个节点。`/s/` 图片页、showpage 的 `i3`、imagedispatch 的 `i` 都见过两层的。
- **以图搜图**：EH 用 `https://upld.e-hentai.org/image_lookup.php`；EX 用 `https://exhentai.org/upld/image_lookup.php`（带 `Referer`），Flutter 版用的 `upld.exhentai.org` 在试采时返回 403。两站的跳转都返回 302，`Location` 指向同站的 `/?f_shash=…&fs_from=…`。跳转后的结果页显示「Similarity Scan was disabled for this search」和「No hits found」，是一个没有命中的页面。
- **种子弹窗**：个人种子链接 EH 上是 `ehtracker.org/get/…`，EX 上是 `exhentai.org/torrent/…`。各路径段和 announce 段都已遮蔽，只保留公开的 40 位 info hash。

### 采集 UA 与 WebKit UA（2026-11-05 补）

本批样本用 Chrome 桌面 UA 采集。App 的请求会改用本机 WebKit 的 UA；用 iPhone 的 WebKit UA 比对过两站的列表、详情、图片页，结构一致，唯一差异是 WebKit 页面多出 `meta[name=viewport]`（已知差异，解析器不依赖），详见 `docs/notes/webkit-ua-structure.md`。

以后重采时，把 `EH_USER_AGENT` 设为 App 调试页显示的 WebKit UA（与 App 收到的页面一致），并把所用 UA 记进采集记录。`capture` 的默认 UA 这次不改。

### 首次采集的问题与这次重采

首次采集的样本（已被改写掉的那次提交）漏了三类与账号相关的信息，是事后复审发现的：

1. 列表页和排行页的标签按 My Tags 着色（`gt*` 元素的 `style`，以及详情页标签的 opacity），能看出用户关注和隐藏了哪些标签；
2. 「Filtered N galleries from this page」里的条数 N；
3. 归档弹窗「Current Funds」里的 GP 和 Credits 余额。

而且遮掉 N 也不够：被过滤的画廊不会出现在列表里，拿同一范围不带过滤的页面一比，就能推出用户隐藏了哪些标签。

这次用新规则把两站都重采了一遍：

- 采集工具去掉 `gt*` 元素的 style，遮蔽过滤条数和余额；
- 列表页带 Disable Filters 参数采集；
- `filteredlist` 规则规定，任何入库样本只要出现 Filtered 行就拒收。只有构造样本 `constructed/eh/list-filtered.html` 豁免这条规则。

### 抽查结论

- **范围**：两站全部 58 个入库样本，加上 7 个构造样本、`manifest.json` 和本机 `local/` 下的 10 个页面。逐个打开看过的有：
  - `{eh,ex}/account/uconfig.html`、`eh/account/home.html`；
  - `{eh,ex}/popup/favorites.html`、`{eh,ex}/popup/torrents.html`、`{eh,ex}/popup/archiver.html`；
  - `local/{eh,ex}/list/favorites.html`、`local/{eh,ex}/account/mytags.html`。
- **新增的检查项**：
  - 带 `style` 的 `gt*` 元素 0 个，`radial-gradient` 0 处；
  - 详情页 `#taglist` 里没有 style，也没有 opacity；
  - 入库样本里没有 Filtered 行；
  - EH 归档页的 Current Funds（GP、Credits）已遮蔽，EX 归档页本来就没有余额栏。
- **其余检查项**：
  - 种子密钥、个人种子链接、tracker 段，以及 home 页的 H@H 排名和 GP 都已遮蔽；
  - apikey、apiuid 已遮蔽；
  - 收藏备注是空的，收藏夹名是默认名，排除上传者列表是空的；
  - 没有外部 IP；
  - 页面里的邮箱只有广告商的公开联系地址，以及列表里其他用户公开的上传者名；
  - 评分星都是普通的 `ir`，没有本人评分的着色；
  - 有两位上传者在所有页面里都显示为半透明，开过滤时的旧样本里也一样：这只能排除过滤开关的影响，不能排除按账号渲染；原因待 M1 查，如需对比匿名页面，先征得用户同意（已列入仓库根 README 的 M0 遗留事项）；
    - **M1 离线核对结论**（2026-11-06，解析计划 P2，只做了统计，没有联网，也没有对比匿名页面）：
      - 29 个入库列表页共有 790 个上传者 div（`td.gl4c` 的第一个 div），其中 23 个带 opacity；
      - 这 23 个里，15 个没有链接，文字是站点标签「(Disowned)」；
      - 另外 8 个有链接，只涉及 2 位上传者，在两站各页都显示为半透明，上面说的「两位上传者」就是它们；
      - 用户确认自己在 EH 和 EX 上都没有屏蔽或排除过上传者，因此判为站点的公开状态，样本不用改，具体原因没有查；
      - 列表解析器只按结构判断：上传者 div 带 opacity 就算 `isUploaderDimmed`，有没有链接都一样；
  - 采集用的 cookie、member id 和用户名，按原文和各种编码形式都没有出现。
- **结论**：没有发现漏网的个人信息。
