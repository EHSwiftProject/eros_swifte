# 构造样本

本目录下的样本**全部为人工构造**，不是站点的原始响应：或者手写，或者在采集样本基础上修改而成，
用来覆盖站点不方便或无法稳定返回的情况。每个样本在 `../manifest.json` 里都有一条 `source` 为 `constructed` 的记录，
改自采集样本的用 `derivedFrom` 指明来源。

构造样本同样不得含有任何个人信息。结构检查和秘密检查都会扫描本目录（本说明文件只做秘密检查）；只有 `FixtureHygiene.constructedExemptions`
列出的文件可以有意违反其中写明的规则。本机有私有样本时，防泄露检查还会查本目录的全部文件，看有没有只在 `../local/` 里出现的标签名和画廊链接（见 `../README.md`「卫生检查」）。

## 逐文件说明

以下 23 个样本都属于 EH（`site: eh`）。改自采集样本的有 7 个：其中 4 个于 2026-11-05 基于关掉过滤重采的 `eh/` 样本重新生成，只改了下面写明的那一处；`detail-favorited.html` 于 2026-11-06（M1 解析计划 P3）改自同一批的 `eh/gallery/detail.html`，只改了它那一节列出的几处；`uconfig-eros-unselected.html` 与 `uconfig-without-eros.html` 于 2026-11-06（M1 解析计划 P6）改自 `eh/account/uconfig.html`，只换了 profile 选择器里的选项。这 7 个样本其余字节都与来源相同；来源样本写盘前已经去除个人信息。首次采集的那次提交（已被改写掉）里，`list-non-compact.html` 随来源带着 My Tags 着色和过滤条数，现在的版本不再有这些问题。

### `eh/banned.txt`：IP 封禁

- 构造方式：手写。正文恰为站点因请求过多临时封禁 IP 时返回的那句纯文本（「Your IP address has been temporarily banned for excessive pageloads …」），没有 HTML，末尾没有换行。
- 代表：封禁。用于测试「不是 JSON、不含 `<html`、含封禁通知自己的句子（`temporarily banned` 或 `The ban expires in`）」的判定，以及剩余封禁时长的解析。只含 `banned` 一词的正文不算封禁（2026-11-07 M1 收尾修复）。

### `eh/image-509.html`：509 图片页

- 构造方式：复制 `eh/image/page.html`，把 `<img id="img" src="…">` 的 src 换成 `https://ehgt.org/g/509.gif`。
- `derivedFrom`：`eh/image/page.html`
- 代表：图片流量配额用完时，图片页给出的 509 占位图。

### `eh/showpage-509.json`：509（API）

- 构造方式：复制 `eh/api/showpage.json`，把 `i3` 里 img 的 src 换成 `https://ehgt.org/g/509.gif`。原文件的斜杠写成 `\/`，替换后的地址也照这个转义写法；其余字段不变。
- `derivedFrom`：`eh/api/showpage.json`
- 代表：`api.php` 的 `showpage` 返回 509 占位图。

### `eh/http-429.html`：429

- 构造方式：手写，正文为 `<html><body>Too Many Requests</body></html>`；manifest 里 `status` 为 429。
- 代表：被限流时的 HTTP 429 响应。

### `eh/showpage-key-mismatch.json`：Key mismatch

- 构造方式：手写，正文为 `{"error":"Key mismatch"}`。
- 代表：`showpage` 的 showkey 过期或不对时，`api.php` 返回的错误。

### `eh/list-non-compact.html`：非 Compact 列表

- 构造方式：复制 `eh/list/front.html`，把显示模式选择器里的 `selected="selected"` 从 `value="l"`（Compact）移到 `value="t"`（Thumbnail）。
- `derivedFrom`：`eh/list/front.html`
- 代表：首页显示模式不是 Compact。注意只改了选择器，列表本身仍是 Compact 的标记（`itg gltc`），所以只适合用来测试显示模式识别（`ListDisplayMode.detect` 应返回 `.thumbnail`），不能当作真正的缩略图列表样本。

### `eh/list-filtered.html`：被账号过滤过的列表

- 构造方式：复制 `eh/list/front.html`（关掉过滤采集的首页），在搜索结果说明 `<div class="searchtext"><p>Found N results. …</p></div>` 里原位加回「`Filtered N galleries from this page. [<a href="https://e-hentai.org/?f_sft=on&amp;f_sfu=on&amp;f_sfl=on">Disable Filters</a>]`」，其中 N 写成遮蔽后的 1。写法照首次采集时站点的原样；**没有**加回任何被过滤的画廊，列表内容与来源相同。
- `derivedFrom`：`eh/list/front.html`
- 代表：账号的标签过滤生效时，列表页多出的那一行和它的 Disable Filters 链接，供 M1 的列表解析测试使用。
- 卫生检查：这是唯一对 `filteredlist` 规则豁免的样本（见 `FixtureHygiene.constructedExemptions`）；条数仍受 `filtered` 规则检查，必须是遮蔽后的形式。

### `eh/login-set-cookie.txt`：论坛登录的 Set-Cookie

- 构造方式：手写，不改自任何样本（没有 `derivedFrom`）。共 5 行，每行一个 `Set-Cookie:` 响应头，依次为 `ipb_member_id`（`1111111`）、`ipb_pass_hash`（32 个 `a`）、`ipb_session_id`（32 个 `a`）、`sk`（遮蔽形式 `aa1aaa11aaa1a1`）和 `ipb_anonlogin=deleted`，都带 `path=/; domain=.e-hentai.org`。`ipb_member_id`、`ipb_pass_hash`、`sk` 带远期的 `expires`（2099 年），`ipb_session_id` 是会话 cookie，`ipb_anonlogin` 带过去的 `expires`（1970 年），表示删除。文件末尾有换行；manifest 里 `status` 为 200，`setCookieNames` 依次为这 5 个名字。
- 代表：用论坛账号密码登录（`forums.e-hentai.org` 的登录表单）成功时响应里的 Set-Cookie，Flutter 的 `UserLoginTransformer` 从中读取 `ipb_member_id`、`ipb_pass_hash`、`sk` 等。用于测试 `SetCookieParser`：逐行解析与把 5 行用 `, ` 连成一个头（`expires` 里也有逗号）解析结果相同，`domain` 为 `.e-hentai.org`，`ipb_anonlogin` 判为删除。

### `eh/list-favorites.html`：收藏页（favorites.php）

- 构造方式：手写，不改自任何入库样本。**结构**照本机私有样本 `local/eh/list/favorites.html`（不入库）：用只打印标签结构、把文字和属性值遮蔽掉的脚本看过它的元素层次，**没有复制其中任何文字**。内容全部编造：画廊 gid 为 900005 到 900001、token 为 `0f0f0f0f05` 到 `0f0f0f0f01`，标题 `Fake Gallery N`，标签 `other:fake tag N`，收藏夹名 `Fake Folder 0` 到 `Fake Folder 9`，日期写成遮蔽形式 `2011-11-11 11:11`，数量和尺寸只用数字 1，其余文字都是 `Fake …`。
- 内容：
  - 页首收藏夹栏 `div.ido > div.nosel`：10 格 `div.fp`，每格依次是数量（1、11、1、111、1、1、1、11、1、1）、图标 `div.i`（title 为收藏夹名）、名称；之后是一个清除浮动的空 div 和「全部收藏」格 `div.fp.fps`（只有文字，没有子 div）。
  - 两个 `.searchnav`：第一格是排序控件（`select`，两项，选中的那项文字含 `Favorited`）；`#uprev` 是 `span`；`#unext` 的 `next=900001-1111111111`（收藏页的游标是「gid-数字」的形状）；显示模式选择器选中 `l`（Compact）。
  - `table.itg gltc` 里 5 行，列与真实收藏页相同：`gl1c`、`gl2c`、`gl3c`、`glfc glfav`（收藏日期两段）、`glfc`（勾选框）；**没有** `gl4c`（收藏页不显示上传者），页数只出现在悬停缩略图里（`11 pages`）。
  - 每行的 `posted_<gid>` 都带 `border-color` 与 `title`（依次为收藏夹 0、3、3、7、9）；900004 的星级 class 为 `ir irb`（账号自己评过分）；900003 的 `div.glfnote` 为 `Note: [favnote]`（备注占位符），其余行的备注 div 为空且 `display:none`；900002 的日期包在 `<s>` 里（已删除的画廊）。标签元素没有 style。
- `derivedFrom`：`structure of local/eh/list/favorites.html (not checked in)`（不指向任何入库样本，所以防泄露检查对它不放行任何私有值）。
- 代表：账号自己的收藏页，供 M1 列表解析测试读取收藏夹栏、排序、收藏标记、本人评分、备注和已删除标记。
- 卫生检查：按设计带着收藏标记（`posted_` 的 style 与 title、收藏夹图标 title 与名称都不是默认名）和本人评分（900004 的 `ir irb`），所以在 `FixtureHygiene.constructedExemptions` 里对 `favmark`、`accountmark`（2026-11-07 M1 收尾修复加）豁免；其余规则照常检查，备注必须是占位符 `[favnote]`（`glfnote` 规则）。

### `eh/list-watched.html`：订阅列表（watched）

- 构造方式：手写，不改自任何入库样本。**结构**照本机私有样本 `local/eh/list/watched.html`（不入库），方法同上，没有复制其中任何文字。内容全部编造：gid 900004 到 900001、token `0f0f0f0f04` 到 `0f0f0f0f01`，标题 `Fake Gallery N`，上传者 `Fake Uploader N`，标签 `other:fake tag N` 与 `fake tag 9`。
- 内容：首页同款的 `#toppane`（搜索框）；结果上方是 `p.ip`（一段编造的说明和一个指向 `/mytags` 的链接），**没有** `.searchtext`；两个 `.searchnav`，第一格为空（没有排序控件），`#uprev` 是 `span`，`#unext` 的 `next=900001`，显示模式选中 `l`；`table.itg gltc` 里 4 行，带 `gl4c`（上传者链接与 `11 pages`）；`posted_` 不带 style 与 title。
- `derivedFrom`：`structure of local/eh/list/watched.html (not checked in)`。
- 代表：按订阅标签得到的列表，供 M1 列表解析测试核对条数与游标（4 条、上一页游标为 nil、下一页游标为 `900001`）。

### `eh/list-login-required.html`：「需要登录」页

- 构造方式：手写，不改自任何样本（没有 `derivedFrom`），没有访问站点。正文只有 `<div class="d">` 里的一段「This page requires you to log on.」，没有画廊列表、没有显示模式选择器、没有画廊链接。措辞按 M1 解析审查的记录；**没有真实样本对照**，外层结构是编的。
- 代表：会话在网页端失效、或者匿名打开收藏页、订阅列表等账号页面时，站点返回的「需要登录」页。供 M1 收尾修复（2026-11-07）的列表解析测试确认它抛 `ParseError.loginRequired`，而不是读成空结果。M2 第一次遇到真实页面时换成真实样本，并核对措辞。

### `eh/detail-favorited.html`：已收藏、已评分、已投票的画廊页

- 构造方式：复制入库样本 `eh/gallery/detail.html`，只改下面 5 处，其余字节与来源相同（用脚本逐处替换，并核对每处恰好替换一次）：
  - `#fav` 里加一个子 div：`<div style="background-position:0px -59px"></div>`（收藏夹图标的偏移，按 Flutter 的 `(59 − 2) / 19` 为第 3 个收藏夹）；
  - `#favoritelink` 的文字由 `Add to Favorites` 改为编造的收藏夹名 `Fake Folder 3`（前面的图片不动）；
  - `#rating_image` 的 class 由 `ir` 改为 `ir irr`（星级显示账号自己的评分）；
  - 标签列表里前两个标签链接的 `class=""` 依次改为 `class="tup"`、`class="tdn"`（账号投过赞成票、反对票）；
  - 上传者评论之后的第一条评论：赞成链接的 `style=""` 改为 `style="color:blue"`（账号投过赞成票），并在两个投票链接之后、`div.c4` 结束之前加一个 ` &nbsp; [<a href="#" onclick="edit_comment(<该评论 id>); return false">Edit</a>]`。
- `derivedFrom`：`eh/gallery/detail.html`
- 代表：账号已收藏、已评分、给标签和评论投过票的画廊页，供 M1 详情解析测试读取收藏夹序号与名称、本人评分、标签投票、评论投票与可编辑。注意站点上「能编辑」的通常是自己的评论、不会同时出现投票链接，这里为了一条评论同时覆盖两种标记，把两者放在了一起。
- 卫生检查：按设计带着收藏标记（`#fav` 里有内容、`#favoritelink` 不是 `Add to Favorites`）和本人的评分、标签投票、评论投票与 Edit 链接（`ir irr`、`tup`、`tdn`、`style="color:blue"`、`edit_comment(`），所以在 `FixtureHygiene.constructedExemptions` 里对 `favmark`、`accountmark`（2026-11-07 M1 收尾修复加）豁免；其余规则照常检查。

### `eh/detail-thumbs-normal.html`：旧版小缩略图（`div.gdtm`）

- 构造方式：手写，不改自任何入库样本，也不照本机私有样本。**结构**照 Flutter `gallery_detail_parser.dart` 读取的旧版小缩略图写法：`#gdt > div.gdtm > div[style] > a > img`。M0 样本只有现站点的 `#gdt > a > div` 一种，所以这种写法没有真实样本可对照。
- 内容：4 格，都属于编造的画廊 900001，共用一张编造的拼图 `https://ehgt.org/m/111111/900001-00.jpg`。第 N 格：内层 div 的 style 为 `width:100px; height:(140+N)px`，背景偏移 `-(N−1)×100px`（依次为 0、100、200、300）；链接 `https://e-hentai.org/s/0f0f0f0f0f/900001-N`；`img` 的 `alt` 为两位数页码（`01`…`04`），title 为 `Page N: 0N.jpg`。
- `derivedFrom`：`structure of #gdt > div.gdtm in the Flutter gallery_detail_parser.dart (no fixture)`（不指向任何入库样本）。
- 代表：旧版小缩略图，供 M1 详情解析测试确认 4 格都读成 `.sprite`，偏移依次为上面的构造值。

### `eh/detail-thumbs-large.html`：旧版大缩略图（`div.gdtl`）

- 构造方式：手写，同上，**结构**照 Flutter 读取的旧版大缩略图写法：`#gdt > div.gdtl > a > img`，每页一张图。
- 内容：4 格，属于画廊 900001。第 N 格的链接为 `https://e-hentai.org/s/0f0f0f0f0f/900001-N`，`img` 的 `alt` 为两位数页码；src 为 `https://ehgt.org/0f/0f/<40 位 0f…0N>-111111-<宽>-<高>-jpg_l.jpg`，宽高依次为 1000×1400、1100×1500、1200×1600、1300×1700（Flutter 按 `-` 切开后取倒数第 3、2 段为原图宽高）。
- `derivedFrom`：`structure of #gdt > div.gdtl in the Flutter gallery_detail_parser.dart (no fixture)`。
- 代表：旧版大缩略图，供 M1 详情解析测试确认 4 格都读成 `.single`，原图尺寸为上面的构造值。

### `eh/account-mytags.html`：My Tags 页（mytags）

- 构造方式：手写，不改自任何入库样本。**结构**照本机私有样本 `local/eh/account/mytags.html`（不入库）：用白名单遮蔽脚本看过它的元素层次（只显示标签名、属性名、id 与 class 里的结构性前缀和标点，其余文字、属性值、数字一律替换），另用只输出真假的脚本核对过几处写法，**没有复制其中任何文字或值**。站点脚本函数名里，`do_tagset_rename()`、`change_tagset(this.value)` 是核对过的；`do_tagset_delete()` 来自 Flutter `mytags_parser.dart`（本机两站样本都没有删除按钮，按钮放在改名按钮旁边是推测）；其余函数名与控件名凡是没有核对过的都写成 `fake_…`，只有 Flutter `request.dart` 会提交的 `tagset_action`、`tagset_name`、`usertag_action`、`tagname_new`、`tagwatch_new`、`taghide_new`、`tagcolor_new`、`tagweight_new`、`usertag_target` 照它写。
- 内容（全部编造）：
  - 页面脚本 `var apiuid = 1111111;`、`var apikey = "a1a1a1a1a1a1a1a1a1a1";`（遮蔽形式）。
  - `#tagset_outer`：第一个 div 是改名与删除两个按钮（`onclick` 分别为 `do_tagset_rename()`、`do_tagset_delete()`）；第二个 div 是两个隐藏输入和 tagset 选择器 `select[onchange=change_tagset(this.value)]`，两项为 `9100001`「Fake Set 1 (2)」、`9100002`「Fake Set 2 (3)」（选中）；之后是启用勾选框、取色按钮、tagset 颜色输入框、保存按钮和一个空 div。
  - `#usertags_outer`：先是新增标签用的 `usertag_0`（`tagname_new` 输入框等，不是标签），再是 3 行 `usertag_<id>`，每行 7 个 div：`a > div#tagpreview_<id>.gt`（title 为标签全名、style 为编造的颜色）、`#tagwatch_<id>`、`#taghide_<id>`、取色按钮、`#tagcolor_<id>`、`#tagweight_<id>`、`div#selector_<id>`。三行依次为：9000001 `artist:fake artist`（关注、不隐藏、颜色为空、权重 10）；9000002 `female:fake tag`（隐藏、颜色 `#3377CC`、权重 -5）；9000003 `other:fake tag 3`（都不勾、颜色 `#AA11FF`、权重 25）。
  - 之后是批量操作区 `#usertags_mass`。
- `derivedFrom`：`structure of local/eh/account/mytags.html (not checked in)`（不指向任何入库样本，所以防泄露检查对它不放行任何私有值）。
- 代表：账号自己的 My Tags 页，供 M1 mytags 解析测试读取 tagset、标签、关注与隐藏、颜色、权重、apiuid、apikey 和能否删除 tagset（2 个 tagset、3 个标签，各字段等于上面的构造值，能删除）。
- 卫生检查：标签预览带着颜色 style（真实页面就是这样画账号的标签的，采集工具会把它删掉），所以在 `FixtureHygiene.constructedExemptions` 里对 `tagstyle` 豁免；apikey、apiuid 等其余规则照常检查，必须是遮蔽形式。注意采集工具的 `resanitize --constructed` 仍会按 `tagstyle` 删掉这些 style（豁免只作用于检查）；解析器的颜色取自 `#tagcolor_<id>` 输入框，不受影响。

### `eh/uconfig-eros-unselected.html`：有 Eros-FE profile 但未选中的设置页

- 构造方式：复制入库样本 `eh/account/uconfig.html`（字节级复制，保留 BOM），只把 `select[name=profile_set]` 里的选项整段换成编造的三项：`<option value="1" selected="selected">Fake Default</option><option value="5">Eros-FE</option><option value="6">Fake Other</option>`。用脚本替换，并核对替换处之前、之后的字节都与来源相同。
- `derivedFrom`：`eh/account/uconfig.html`
- 代表：账号已有名为 `Eros-FE` 的 profile（5 号）但当前选中的是另一个（1 号），供 M1 解析测试与网络 N7「选用已有的 Eros-FE profile」测试使用。编号都是编造的；名称不带 `(Default)` 后缀（两站入库样本的默认 profile 名都不带）。设置表单与来源完全相同。

### `eh/uconfig-without-eros.html`：没有 Eros-FE profile 的设置页

- 构造方式：同上，选项换成两项：`<option value="1" selected="selected">Fake Default</option><option value="6">Fake Other</option>`。
- `derivedFrom`：`eh/account/uconfig.html`
- 代表：账号没有 `Eros-FE` profile，供网络 N7「创建 Eros-FE profile」测试使用。

### `eh/forum-profile.html`：论坛资料页

- 构造方式：手写，不改自任何样本（论坛资料页的真实样本要等用户另存后由工具计划 T8 导入 `local/`，且不入库）。**结构**照 Flutter `user_profile_parser.dart` 的选择器：`#profilename` 的文本是昵称，它之后第二个兄弟元素的第一个 `img` 是头像。外层的 `#ipbwrapper`、`table.ipbtable` 等是按 IPB 论坛的常见写法编的，没有真实页面对照。
- 内容（全部编造）：`<div id="profilename">Fake Nickname</div>`，接着一个 `<br />`，再接 `<div><img src="uploads/av-1111111.jpg" … /></div>`（相对路径，文件名里的数字是遮蔽形式的 1111111），之后是一个 `div.postdetails`「Fake Group」和右侧一栏编造的文字。
- `derivedFrom`：`selectors of the Flutter user_profile_parser.dart (no fixture)`（不指向任何入库样本）。
- 代表：论坛资料页，供 M1 解析测试确认昵称为 `Fake Nickname`、头像为 `https://forums.e-hentai.org/uploads/av-1111111.jpg`。

### `eh/api-rategallery.json`：评分答复

- 构造方式：手写，不改自任何入库样本。字段取自 Flutter 对 `api.php` 该方法答复的用法，第一次真实写操作（经用户同意，M3/M6）后换成真实样本。
- 内容（全部编造）：`{"rating_avg":3.5,"rating_usr":4,"rating_cnt":12,"rating_width":56}`。
- `derivedFrom`：`fields of the Flutter api.php use (no fixture)`（不指向任何入库样本）。
- 代表：`rategallery` 的答复，供 M1 解析测试读出平均分 3.5、用户评分 4、人数 12。

### `eh/api-votecomment.json`：评论投票答复

- 构造方式：手写，不改自任何入库样本。字段取自 Flutter 对 `api.php` 该方法答复的用法，第一次真实写操作（经用户同意，M3/M6）后换成真实样本。
- 内容（全部编造）：`{"comment_id":1,"comment_score":5,"comment_vote":1}`。
- `derivedFrom`：`fields of the Flutter api.php use (no fixture)`（不指向任何入库样本）。
- 代表：`votecomment` 的答复，供 M1 解析测试读出评论 1、分数 5、投票 1。

### `eh/api-taggallery.json`：标签投票答复

- 构造方式：手写，不改自任何入库样本。字段取自 Flutter 对 `api.php` 该方法答复的用法，第一次真实写操作（经用户同意，M3/M6）后换成真实样本。
- 内容（全部编造）：`tagpane` 是一个 `#taglist` 里的表格，两行：命名空间 `fakeone` 与 `faketwo`，各一个标签 `fake tag 1`、`fake tag 2`（均为实线框、无投票）。
- `derivedFrom`：`fields of the Flutter api.php use (no fixture)`（不指向任何入库样本）。
- 代表：`taggallery` 的答复，供 M1 解析测试确认读出 2 组、各 1 个标签。

### `eh/api-setusertag.json`：设置自定义标签答复

- 构造方式：手写，不改自任何入库样本。字段取自 Flutter 对 `api.php` 该方法答复的用法，第一次真实写操作（经用户同意，M3/M6）后换成真实样本。
- 内容（全部编造）：`{"result":"ok"}`。
- `derivedFrom`：`fields of the Flutter api.php use (no fixture)`（不指向任何入库样本）。
- 代表：`setusertag` 的成功答复，供 M1 解析测试确认不抛错。

### `eh/api-error.json`：错误答复

- 构造方式：手写，不改自任何入库样本。字段取自 Flutter 对 `api.php` 该方法答复的用法，第一次真实写操作（经用户同意，M3/M6）后换成真实样本。
- 内容（全部编造）：`{"error":"Fake error"}`。
- `derivedFrom`：`fields of the Flutter api.php use (no fixture)`（不指向任何入库样本）。
- 代表：任何 `api.php` 方法的失败答复，供 M1 解析测试确认 6 个方法都抛 `APIError.server("Fake error")`。
