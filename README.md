# AIHOT 热点榜（iOS 原生 App）

把 [aihot.news](https://aihot.news) 的**热点榜**做成一个 iPhone 原生 App（SwiftUI 重绘，不是在浏览器里打开网页）。
本仓库只做「热点榜」一个板块；「主题」不在范围内。

**没有 Mac 也能跑通**：GitHub Actions 的 macOS runner 负责编译，产出**未签名 IPA**，
你用 AltStore + 免费 Apple ID 就能装到自己的 iPhone 上。

---

## 1. 三步装到手机上

### 第 1 步：把代码放到 GitHub

1. 新建一个 **public** 仓库（public 仓库的 macOS runner 不消耗免费额度），例如 `aihot-hot-ios`。
2. 把本目录所有内容推上去：
   ```bash
   git init
   git add .
   git commit -m "AIHOT 热点榜 iOS"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/aihot-hot-ios.git
   git push -u origin main
   ```
   > 没有 git 环境也没关系：在仓库页面用 **Add file → Upload files**，把整个目录（含隐藏的 `.github` 文件夹）拖进去，GitHub 会保留目录结构。

3. 推上去后打开 **Actions** 标签页，会看到 `iOS Unsigned IPA` 工作流在跑（也可以在 Actions 里点 **Run workflow** 手动触发）。
   跑完（约 3–6 分钟）在 run 页面底部下载 artifact：
   - **`AIHOT-unsigned-ipa`** ← 用这个。未签名包由 AltStore 现场用你的 Apple ID 重新签名，这是常规做法
   - `AIHOT-adhoc-ipa` ← 备用包，**可能不存在**：iphoneos 上的 ad-hoc 签名不是官方支持的组合，CI 里那一步允许失败（失败不影响主包）
   - `test-log` / `build-logs` ← 出错时用来看日志

### 第 2 步：在 Windows 上准备 AltStore

1. 到 [altstore.io](https://altstore.io) 下载 **AltServer**（Windows 版）。
2. 从 **Apple 官网**（不是 Microsoft Store）下载安装 **iTunes** 和 **iCloud for Windows** —— Microsoft Store 版本不能用。
3. iPhone 先用数据线连一次电脑，「信任此电脑」；之后就可以走同一个 Wi-Fi。
4. 运行 AltServer（托盘图标）→ **Install AltStore** → 选你的 iPhone → 输入 Apple ID。
5. iPhone 上：**设置 → 通用 → VPN与设备管理** 里信任你的 Apple ID 证书；
   iOS 16 及以上还要打开 **设置 → 隐私与安全性 → 开发者模式**，然后重启手机。

### 第 3 步：装上这个 App

1. 把下载到的 `.ipa` 弄进 iPhone（iCloud Drive / 文件 App / AirDrop 都行；artifact 是 zip，先在电脑上解压出 `.ipa`）。
2. 打开 iPhone 上的 **AltStore → My Apps → 左上角 `+` → 选择这个 `.ipa`**，输入 Apple ID，等它签名安装完成。
3. 装好了。之后 **AltServer 保持运行 + 手机在同一 Wi-Fi**，AltStore 会自动帮你续签；也可以手动 Refresh。

**免费 Apple ID 的限制**：App 7 天过期需要重新签名、最多同时 3 个自签 App、不能用推送等能力。
本项目零 entitlement、无推送，完全不受影响。

> 不想一直开着电脑，可以换 [SideStore](https://sidestore.io)（同样的 IPA，配对文件 + 本地 VPN，装好后不依赖电脑）。

---

## 2. 这个 App 长什么样

官网是桌面优先的排版，手机上做的是**同一套信息结构的窄屏重排**：

| 官网（/hot） | App |
| --- | --- |
| 左侧导航 + 顶栏 + 底部 tab（精选/日报/模型榜/我的） | 底部栏是 App 自己的五个 tab：**热点 / 收藏 / 模型榜 / 周报 / 设置** |
| 榜单头：过去 48 小时… · 更新时间 · 实时热度 · 怎么算 | 标题下两行说明，「怎么算」按钮在应用内打开官网该页 |
| NO.01–03 大卡（序号/爆新徽章/涨跌/标题/正文/头像行/热度指数） | 3 张全宽卡；正文取 story digest（与官网同源），4 行截断 |
| 头像行「+10 邵猛、Oran Ge 等 7 个来源·16 位参与者」 | 字母头像栈（来源名哈希取色）+「N 个来源 · M 位参与者」 |
| 热度指数大数字 | 有就显示真实热度指数，没有就显示参与者数（**不编造数字**） |
| 「10月12日 10:35 更新」 | 优先用页面文本里的真实时间，取不到就显示「刷新于 …」 |
| NO.04–10 紧凑列表 | 一张卡片内的紧凑行：序号 + 标题 + 摘要 + 指标 |
| 24 小时走势图 | 不做（公开接口没有这项数据） |
| /story/xxx 详情页 | 原生详情页：AI 摘要分段 + 报道节奏图 + 报道时间线（来源/时间/摘要/原文）；右上角书签可收藏这一条 |
| （App 新增）报道节奏 | 把这条的报道按**北京时间**切成时间桶画成柱状图（见下），中间没人跟的时段是空柱子 —— 「正在爆发」和「已经凉了」一眼能分开 |
| 原文链接 | 应用内 `SFSafariViewController` 打开，**默认进系统阅读器模式**（只有正文）；旁边留一个「网页版」入口，抽得不好时点它退回原网页 |
| 详情页右上「对话」 | AI 对话弹窗：多轮、流式；模型读过这条的摘要与时间线，Anthropic 协议下还能联网搜索、读原文（见第 4 节） |
| （App 新增）收藏 | 底部「收藏」tab：按收藏时间倒序、左滑「取消收藏」。详情页是唯一的收藏入口（列表行上刻意不放按钮，避免按钮套在整行的链接里） |
| /leaderboard 模型榜 | 底部「模型榜」tab：综合/编程/科研/专业办公/知识问答五个分类分段切换，30 行（名次/模型/厂商/上线日期/三档价格/评分/覆盖率）；点一行进模型详情页（概览评分与价格、四张领域卡、逐项公开成绩）；页头「N 项评测 · N 家机构 · 更新时间」行右端的「怎么算」和页脚来源回链都通向官网。榜单没有公开 JSON 接口，数据从页面 HTML 解析（解析失败保留旧数据 + 横幅） |
| /weekly、/monthly 周报月报 | 底部「周报」tab：周报/月报分段切换，最新一期全文（标题/综述/分栏条目）+ 往期按月分组（点进看那一期全文）；条目点开走原文（系统阅读器），页头行右端「网页版」与页脚来源回链通向官网。有新一期时 tab 上挂「新」角标（进 tab 看过即消失；新装用户第一次看到某一期不挂）。有公开 JSON 接口（`/api/v1/weeklies`、`/api/v1/monthlies`，带 ETag、`s-maxage=300`），断网显示缓存快照 + 横幅 |

配色 token 全部集中在 `AIHOT/Design/Theme.swift`（近黑底 + 热度橙，深浅色跟随系统），想改风格只改这一个文件。

### 关于「报道节奏」

同一份报道时间线，换个看法：横轴是时间、纵轴是那一格里有几条报道。规则都在
`AIHOT/Services/ReportTimeline.swift`（纯函数，另有 Python 镜像与单测）：

- 粒度三档 —— **15 分钟 / 1 小时 / 1 天**，从细到粗取第一个「不超过 24 根柱子」的。真实数据基本都落在前两档；
- 时间按**北京时间**对齐（和列表里的时间显示同一个口径）；
- **中间没人报道的那几格保留成空柱子** —— 断档本身就是「已经凉了」的信号，删掉等于把结论删掉；
- 只统计接口返回里**带发布时间**的报道；`reportCount` 比实际条数多时（接口只给最近一批），图下面会写明这一点，**不编造数字**；
- 没有发布时间的报道图里不画，但仍然留在下面的文字时间线里；
- 有发布时间的报道少于 2 条、或全挤在同一格里 —— 这一节**不出现**（一根柱子没有可比性）。

---

## 3. 数据来源与接口约定

全部数据来自 AIHOT 的**匿名只读公开接口**，无需注册、无需 Key：

| 用途 | 接口 |
| --- | --- |
| 榜单 10 条 | `GET /api/v1/hot-topics` |
| 详情（AI 摘要 + 报道时间线） | `GET /api/v1/stories/{publicId}` |
| 热度指数/涨跌/爆新（可选补全） | `GET /hot` 页面文本解析 |
| 周报/月报最新一期 + 往期索引 + 单期全文 | `GET /api/v1/weeklies(/latest|/{week})`、`GET /api/v1/monthlies(/latest|/{month})` |

代码里遵守了对方写明的要求：

- 刷新**不快于 60s**（接口的 `s-maxage`），带 `If-None-Match`，未变化时是 304 空体；
  **下拉刷新也一样**：60 秒内的重复下拉不会重新发请求（本地完全没数据时才放宽到 5 秒，保证首屏和重试可用）；
- 429 / 503 读 `Retry-After`，**在它到期前不再发任何请求**，也不并行重试；
- `links.story` 是**给人看的 HTML 地址**，只取末段当 publicId，再请求 `/api/v1/stories/{id}`；旧域名 `aihot.virxact.com` 也照样解析（见 `StoryIDTests`）；
- 未实现推送（对方明确没有 SSE / webhook）。

本地缓存分两层，都是为了「304 时也有内容可展示」：

- **榜单快照**（`SnapshotCache`）→ 冷启动秒开、离线可看；
- **故事正文**（`StoryCache`）→ 详情页正文与报道时间线落盘。没有这一层的话，ETag 跨启动保留而正文只在内存里，会变成「重启后大卡没有正文段落」「同一故事第二次打开没有时间线」这类不崩但错的问题。

**收藏**（`FavoritesStore`）和上面两层不是一回事：它是用户数据，不能丢，所以落在 `UserDefaults`
（键 `aihot.favorites`，存 JSON），**不进 Caches 目录**。因此：

- 系统清理 Caches 时碰不到它；
- App 里的「清除本地缓存」只清 Caches 与 ETag，**不动收藏与对话记录**；清收藏是「设置 → 收藏 → 清空收藏」里的单独动作（会先弹确认）；
- 存的是整条榜单快照而不是只存一个 id，所以条目跌出当天的前 10 名之后，收藏列表照样能离线显示标题与来源。
  代价是快照里的名次会过期 —— 所以收藏列表不显示名次，热度也只在「这条仍在当前榜单里」时才显示，
  拿不到就退回快照里的来源数/参与者数，**不编造数字**。

**对话记录**（`ChatHistoryStore`）是同类的用户数据：存在 Application Support（不在 Caches，
系统清理碰不到），按新闻分会话、**最多保留最近 50 条**（超出淘汰最旧，设置页里写明了这个数）。
「清除本地缓存」同样不动它，清空是「设置 → 对话记录 → 清除对话记录」的单独动作（也会先弹确认）。

### 关于「热度指数」这件事

公开接口**不返回**热度指数、涨跌（↑629%/持平/↓16%）、爆/新徽章、24 小时走势，也不返回头像图片（站内图片走带签名的 `/api/img-proxy`，既不能自己构造也不能长期盗链）。所以：

- **默认**开启「从网页补全热度指数」：额外拉一次 `/hot`，把 HTML 压成纯文本，只认「热度指数」这个文案锚点，只解析前三条；
- 解析失败、或者哪天官网改版 —— 会**整块丢弃**，界面退回接口字段（来源数 / 参与者数），**不会显示错误的数字**；
- 标题会先从文本里剔除，避免标题里的「新」「爆」被误判成徽章；
- 可在 App 的「设置 → 数据」里关掉这项增强。

---

## 4. AI 对话（要自己填 Key）

详情页右上角有个对话按钮：点开就能就**这一条**新闻追问，多轮、流式回复。模型手里有这条的
摘要、来源与报道时间线；**需要时它会自己去联网搜索、或打开某个网页读原文** ——
搜不搜、搜什么由它自己决定（标准工具调用：它提出要调哪个工具，App 去执行，再把结果交回去）。

本 App 不带任何内置额度，用的是**你自己的 Key**，在 **设置 → AI 对话** 里填：

| | Anthropic | OpenAI 兼容 |
| --- | --- | --- |
| 接口地址 | `https://api.anthropic.com`（可改） | 自己填，如 `https://api.deepseek.com/v1` |
| 模型 | `claude-opus-5-5` | 自己填，如 `deepseek-chat` |
| API Key | 你的 Key | 你的 Key |
| 联网搜索 / 读网页 | 可以 | 可以（两边一样） |

联网搜索与读取网页由「设置 → AI 对话 → **搜索工具**」里那**一串**工具提供 —— 五家
（[AnySearch](https://anysearch.com)、[Tavily](https://docs.tavily.com)、
[SerpAPI](https://serpapi.com/search-api)、[Exa](https://exa.ai)、[Serper](https://serper.dev)，
默认 AnySearch 排第一，老用户无感）按你排好的顺序轮流上：**一家失败（Key 无效、超限、网络问题）
自动换下一家，全部失败时报排第一那家的错**。**两条协议走同一条路** —— 工具声明是通用的，
顺序只换「谁来执行」，请求体一行不动：

| 搜索工具 | Key | 能力 | 备注 |
| --- | --- | --- | --- |
| AnySearch | **可选**：留空即用匿名（限速更低），Console 在 anysearch.com | 搜索 + 读网页 | search 给排好的 Markdown；extract 给 JSON 文档字符串。**Key 无效不会退回匿名**（想匿名就把字段清空），链会先换下一家 |
| Tavily | **必填**，Console 在 tavily.com | 搜索 + 读网页 | search 带可选的 `answer` 引用块；extract 直接给 Markdown（`raw_content`） |
| SerpAPI | **必填**（Key 走查询参数） | 仅搜索 | 读网页会被链自动跳过；报错文案里**绝不带**完整请求地址 |
| Exa | **必填**，Console 在 exa.ai | 搜索 + 读网页 | 搜索自带 500 字摘要；读网页最多回 8000 字（超出截断） |
| Serper | **必填**，Console 在 serper.dev | 仅搜索 | 请求最简：`X-API-KEY` 头 + `{"q": …}`；读网页会被链自动跳过 |

几个要知道的点：

- **先点「测试连接」**：它只拉一次模型列表、不产生生成计费，并顺带核对你填的模型名在不在里面。
- **每家旁边都有「测一下」**：用**当前输入框里的 Key** 发一次最小搜索（不点「保存密钥」也能验），
  通了显示「✓ 通了」，不通贴出该家的错误原话。会消耗该家一次搜索额度（AnySearch 匿名免费）。
- **「协议」和「接口地址」必须配套** —— 这是最容易踩的一处：同一家服务商的两条协议**地址不一样**。
  以 DeepSeek 为例，OpenAI 兼容填 `https://api.deepseek.com`（带不带 `/v1` 都行），
  Anthropic 兼容才填 `https://api.deepseek.com/anthropic`。填反了 App 不会含糊其辞：它会
  用另一条协议的解码器认出这是谁家的流，并直接告诉你该把协议改成哪一个。
- **Key 存在系统钥匙串里**（七份：两条协议各一份 + 五家搜索各一份），只在本机、不进备份。
  万一这台设备的签名环境不允许用钥匙串，会退回应用内存储，并**在设置页里明确写出来**。
- **AnySearch 的 Key 填错了不会自动退回匿名**：链会**换下一家**，全部家都失败时才看到它的
  「Key 无效」；想用匿名就把那个字段清空。其余四家同理 —— 报无效就换下一家，
  全部失败时报**排第一那家**的错，先查那家的 Key 或开关，别急着换顺序。
- **顺序与开关即点即存**（↑↓ 换位、开关一拨就写入，重启还在）；必填 Key 没填的家**不参与**
  （行内会标「未填 Key，暂不参与」），Key 要点「保存密钥」才写进钥匙串。
- **对话按新闻自动保存**：同一条新闻的对话存在同一个会话里，杀掉 App 重开还在；
  按最后更新**最多保留最近 50 条**，超出淘汰最旧（设置页里写明）。
  弹窗里的垃圾桶按钮只清**当前这条**；全清是「设置 → 对话记录 → 清除对话记录」（会先弹确认）。
- **每条回答都能单独复制**：每条 AI 回答的气泡右下角都有「复制」按钮，把**这一条**回答
  连同**新闻标题与原文链接**放进剪贴板 —— 粘到哪都带着出处；点完短暂显示「已复制」。
  复制的是那一条，多轮对话里想复制哪条就哪条（流式生成中不显示按钮，出完才有）。
- **回答按 Markdown 排版**：标题、列表、代码块（等宽字体 + 语言标签）、引用、分隔线、
  表格都会正常渲染，行内的**加粗** / `代码` / 链接照旧；流式生成中就开始排版，
  代码块是逐行长出来的。复制按钮拿的是 Markdown 原文，粘出去格式不丢。
- **费用**：模型那边按你所用服务商计费；搜索工具每搜一次、每读一个网页也算一次调用
  （AnySearch 匿名有免费额度；Tavily / SerpAPI / Exa / Serper 按你自己账号的额度计）。
  所以模型在一轮里连搜三次，就是三次搜索的量。
- **一次提问最多跑 5 轮工具**，防止它来回搜个没完。
- **国内网络**：`api.anthropic.com` 直连通常不通，接口地址可以填兼容 Anthropic Messages 协议的
  中转地址。**只支持 https**：iOS 默认不允许明文 HTTP，填 `http://` 会明确报错；真要让某个
  局域网地址走 http，得自己在 `AIHOT/Info.plist` 里加 `NSExceptionDomains` 例外。
- **快 / 深**：默认 `"low"`（手机问答对延迟敏感）。想让它想得更久，改
  `AIChatRequestBuilder.effort`。

## 5. 目录结构

```
project.yml                 XcodeGen 工程定义（改包名/显示名/版本只改这里）
.github/workflows/ios.yml   云编译：跑单测与 UI 测试 + 出两个 IPA + 上传 artifact
tools/make_appicon.py       现场生成 1024 图标（有 Pillow 用 Pillow，没有用标准库）
tools/preflight.py          构建前自检：JSON / plist / 路径引用 / Python 语法
tools/logic_tests.py        纯逻辑镜像测试：用 Python 把解析/ID/时间逻辑跑一遍
                            （和 Swift 单测读同一份夹具，CI 里先于编译执行）
AIHOT/
  Info.plist
  RootView.swift            @main + 底部五 tab（热点/收藏/模型榜/周报/设置）+ 外观（跟随系统/深色/浅色）
  Design/                   Theme.swift（色板）、Components.swift（徽章/头像/骨架屏…）
  Models/                   HotTopics.swift、Story.swift（字段与接口一一对应）、
                            Leaderboard.swift（五个分类 / 榜页一行 / 详情页）、
                            Report.swift（周报/月报：期次、索引条目、分栏条目）
  Services/                 AIHOTAPI（ETag/退避 + 模型榜 HTML + 周报月报 JSON）、HotTopicsStore（节流/离线/补全）、
                            SnapshotCache（榜单快照）、StoryCache（故事正文落盘）、
                            FavoritesStore（收藏落盘，UserDefaults）、
                            StoryID、AppSettings、
                            ReportTimeline（报道节奏分桶，纯函数 + Python 镜像）、
                            HTMLTextExtractor + HotPageEnricher（网页文本增强）、
                            LeaderboardParser（模型榜页面解析，纯函数 + Python 镜像）、
                            LeaderboardStore（模型榜节流/缓存/详情）、
                            ReportPeriod（周报/月报期号与分组，纯函数 + Python 镜像）、
                            ReportStore（周报/月报节流/快照/详情/未读角标）、
                            ReportUnread（Tab 角标的纯判断）、
                            DiagnosticReport（「复制运行诊断」：脱敏后只留接口主机名）
                            SSEParser（流式解析）、AIChatTool（工具调用拼接）、
                            AIChatConfig、AIChatRequestBuilder、AIChatNewsContext、
                            AIChatSecretStore（钥匙串）、AIChatAPI（AI 对话）、
                            AnySearchAPI（联网搜索 / 读网页）、TavilyAPI（联网搜索另一家）、
                            SearchToolChain（五家按用户顺序回退 + 单家 runner 工厂）、
                            SerpAPI / ExaAPI / SerperAPI（另外三家）、
                            ChatHistoryStore（对话按新闻落盘，Application Support）、
                            ChatAnswerCopy（复制回答的文本拼装：正文 + 标题 + 出处链接）、
                            MarkdownBlocks（回答的 Markdown 分块，纯函数 + Python 镜像）
  Features/Common/          SafariView（SFSafariViewController，可选阅读器模式 + WebLinkSheet）
  Features/Hot/             榜单页、大卡、紧凑行、RelativeTime
  Features/Favorites/       收藏列表、收藏行
  Features/Leaderboard/     模型榜列表页（五分类切换）、模型详情页（评分/价格/领域卡/逐项成绩）
  Features/Report/          周报/月报列表页（周报月报切换、最新一期、往期分组）、期次正文渲染、往期详情页
  Features/Story/           详情页（AI 摘要 + 报道节奏图 + 时间线 + 收藏书签 + 对话弹窗）、
                            ReportTimelineChart（Swift Charts 柱状图）、
                            MarkdownBlocksView（回答的 Markdown 分块渲染）
  Features/About/           设置页（原「关于」：外观/AI 对话/数据/缓存/收藏/对话记录/排查/署名）
AIHOTTests/                 夹具驱动的纯逻辑测试（解码/时间/ID解析/网页解析/报道节奏）
AIHOTUITests/               UI 测试（设置页换序与开关持久化；用启动参数重置搜索设置）
```

## 6. 改点什么

| 想改 | 改哪里 |
| --- | --- |
| App 显示名 | `AIHOT/Info.plist` 的 `CFBundleDisplayName` |
| 包名（bundle id） | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`（免费账号下只要全局唯一即可） |
| 版本号 | `project.yml` → `MARKETING_VERSION`；build 号由 CI 用 run number 自动递增，AltStore 才能识别为更新 |
| 配色/字号 | `AIHOT/Design/Theme.swift` |
| 对话用哪家 / 哪个模型 | App 内「设置 → AI 对话」（地址、模型、Key 都在这儿） |
| 对话的「快 / 深」 | `AIChatRequestBuilder.effort`（默认 `low`，偏快） |
| 原文要不要用阅读器 | `AIHOT/Features/Story/StoryDetailView.swift` 的 `WebLinkSheet(url:entersReader:)` —— `entersReader: true` 是进阅读器，「网页版」那个按钮用的是默认的 `false` |
| 报道节奏图长什么样 | `AIHOT/Services/ReportTimeline.swift`（分桶/标签/轴刻度，改完记得同步 `tools/logic_tests.py` 的镜像 9）+ `AIHOT/Features/Story/ReportTimelineChart.swift`（柱子颜色与高度） |
| 图标 | 换掉 `tools/make_appicon.py` 的画法，或自己放一张 1024×1024 PNG 到 `AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` |

> 有 Mac 的话：`brew install xcodegen && python3 tools/make_appicon.py && xcodegen generate && open AIHOT.xcodeproj`，就能在 Xcode 里跑。

## 7. 出问题先看这里

| 现象 | 处理 |
| --- | --- |
| Actions 红了 | 打开失败的 job 看日志；CI 会先跑 `tools/preflight.py`（JSON/plist/路径/Python 语法自检），它报的错都写得很直白；`test-log` artifact 里有单测日志 |
| 想先自检再推 | 本地跑 `python3 tools/preflight.py`（结构自检）和 `python3 tools/logic_tests.py`（解析/时间/ID 逻辑镜像测试），都是只读的 |
| 报找不到 `macos-15` 这个 runner | 把 `.github/workflows/ios.yml` 里两处 `runs-on: macos-15` 改成 `macos-14` |
| 桌面图标空白 | `make_appicon.py` 那一步失败了（不影响功能），看 job 日志 |
| AltStore 装 `unsigned` 报签名相关错误 | 先试 `AIHOT-adhoc-ipa`（可能不存在）；都没有就把报错发出来，我加一版 CI 自签证书的构建 |
| 提示「不受信任的开发者」 | 设置 → 通用 → VPN与设备管理 → 信任证书 |
| 打开就提示网络不可用 | 榜单页会显示离线横幅并展示缓存；检查网络后下拉重试 |
| 下拉刷新像「没反应」 | 这是有意的：60 秒内不重复请求（接口 s-maxage 约定）。等过 60 秒再拉，或直接杀掉重开 |
| 显示「请求过于频繁」 | 碰到接口 429，App 会在 `Retry-After` 到期前不再发请求，等提示的时间过去即可 |
| 对话报 400，且错误里提到 fallback / anthropic-beta | 那是 `AIChatRequestBuilder.enableRefusalFallbacks` 那两行（`fallbacks` + beta 头）没被服务端接受。把它改成 `false` 即可 |
| 对话报「密钥无效或没有权限」 | 检查「设置 → AI 对话」里协议与 Key 是否对得上（模型 Key 与搜索 Key 是分开存的七份） |
| 对话里搜不到东西 / 报「搜索失败」 | 看错误里点名的是**哪一家** —— 全部失败时，报的一定是**排第一**那家的错 → 到「设置 → AI 对话 → 搜索工具」查那家的 Key 与开关。AnySearch：匿名有免费额度，用光了要么换个 Key 要么等，**Key 无效时它不会退回匿名**（把搜索 Key 清空即可继续用匿名）；Tavily / Exa：报「Key 无效或已停用」就换一个 Key，或把它停用让下一家顶上；SerpAPI / Serper 同理（这两家只能搜索） |
| 对话报「没有可用的搜索工具」 | 搜索工具全被停用了，或必填的 Key 都没填（AnySearch 也停用了）。到「设置 → AI 对话 → 搜索工具」启用一家并填好 Key；AnySearch 留空 Key 即用匿名 |
| 对话报「没有能读网页的工具」 | 能读网页的三家（AnySearch / Tavily / Exa）要么停用要么没填 Key —— SerpAPI、Serper 只支持搜索，顶不上。启用其中一家即可（AnySearch 可匿名） |
| 模型反复调同一个工具、或根本不搜 | 工具名/参数写错时它会收到 is_error 并自己重试；若一直如此，把当轮的错误信息发出来（界面会显示接口原话） |
| 对话报「接口地址是 http」 | iOS 默认不允许明文 HTTP。改用 https，或按第 4 节给该地址单独加例外 |
| 对话一直不出字、结束后才一次性冒出来 | 若走的是自己的中转，确认它没有压缩/缓存响应；App 侧已经显式要求 `Accept-Encoding: identity` |
| 对话报「这个地址回的是「X」格式的流，跟「协议」里选的「Y」对不上」 | 地址填成了另一条协议的端点。**改「协议」那一栏**（同一家的两条协议地址不一样：`…/v1` 是 OpenAI 兼容，`…/anthropic` 是 Anthropic 兼容），或把地址换过来 |
| 对话报「接口回的内容不是流式格式，解析不了」或「既不像…也不像…」 | 服务端回了非 SSE 的东西（有些中转站谎报 `Content-Type: text/event-stream`）。提示里带着**接口真正发来的帧数、开头与最后一段原文**，照它查；多半是这个地址根本不是对话端点 |
| 上面那句里的帧数是「共切出 **1** 帧」，而开头是一段完整的 JSON | 那条流没有被空行分开、整条被拼成了一帧（分帧器只认空行）。**先确认装的是最新一版**（早先的版本自身就有这个问题，已修）；升级后仍然如此，那就是链路上有东西把空行吃了（中转/代理/企业网关），换一条网络试试（关掉 VPN/代理） |
| 对话报「接口还没给出回复就断开了」 | 只收到思考块之类的就断了，重试即可；反复出现就换个模型或换个地址 |
| 对话报「连接提前中断，回复可能不完整」 | 这一句只表示**已经出了正文、但收尾标记没来**（网络掐断或中转站不发 `data: [DONE]`）。回复里的内容是真的，只是可能不全 |
| 「测试连接」说模型名不在列表里 | 模型名打错了，或这个 Key 用不了这个模型 |
| App 7 天后打不开 | 免费证书过期，AltServer 开着 + 同 Wi-Fi 让 AltStore 自动续签，或手动 Refresh |
| 任何异常 | 进 App「设置 → 排查 → 复制运行诊断」，把内容发出来：含版本号（可与安装包对应）、系统/机型、各栏目条数与提示、AI 与搜索配置状态；不含 Key，接口地址只留主机名 |
| 热度指数/涨跌不显示 | 页面文本解析没命中（官网改版了）。功能不受影响；改点「设置 → 排查 → 复制热度解析诊断」，那一份带 /hot 页面原文，发出来即可修 |
| 详情页没有「报道节奏」这一节 | 正常：带发布时间的报道少于 2 条、或全挤在同一格里就不画（一条新闻刚开始被报道时就是这样） |
| 阅读器里正文不全 / 少了图片 | 那是系统阅读器对这家站点的抽取结果。点「打开原文」旁边的**「网页版」**，退回站点自己的页面 |

## 8. 许可与署名

- 内容版权归 **AIHOT（北京虚实空际文化科技有限公司）及各原始来源**所有。App 内固定显示「数据来源：AIHOT」并链回官网，保留原始链接。
- AIHOT 条款允许**个人非商业**使用；本 App 仅供自己使用，**请勿公开分发 IPA、不要做公开镜像或商业用途**。
- 本项目不含任何 AIHOT 的代码或数据文件，全部数据在运行时从公开接口获取。

## 9. 验收清单

- [ ] Actions 绿，拿到 IPA
- [ ] AltStore 装成功，图标出现在桌面并能打开
- [ ] 榜单 10 条的顺序与标题和官网 `/hot` 一致
- [ ] 点一条进详情，AI 摘要与官网 `/story/xxx` 一致，报道时间线正常
- [ ] 飞行模式重开 App：显示缓存 + 离线横幅，不白屏
- [ ] 深色/浅色切换正常，大字号下不破版
- [ ] 原文按钮在应用内打开，且**默认是阅读器模式**（纯正文）；点旁边的「网页版」能退回原网页
- [ ] 报道多的 story 能看到「报道节奏」柱状图，断档那几小时是贴着底的空柱子，最高那根和下面那行说明的峰值对得上
- [ ] 报道只有 0–1 条的 story，详情页**不出现**「报道节奏」这一节，页面不破版
- [ ] 底部五个 tab 能切换（设置仍在最后），选中色是热度橙
- [ ] 周报 tab：周报/月报分段都能切，最新一期的标题/综述/分栏条目齐全；老期次没有综述时整节省略、页面不破版
- [ ] 往期按月分组显示，点进去能看那一期全文；条目点开进系统阅读器（原文），「网页版」「数据来源」回链能开网页
- [ ] 断网重开：周报页显示缓存快照 + 横幅不白屏；「清除本地缓存」之后周报快照消失，收藏与对话记录仍在
- [ ] 新一期发布后 tab 上出现「新」角标，进周报 tab 看过即消失；全新安装第一次打开**不**挂角标；切到月报时顶部不会残留「周报暂时取不到」的横幅
- [ ] 冷启动只拉当前分段（周报），切到月报才拉月报
- [ ] 「设置 → 排查 → 复制运行诊断」可复制，内容里有版本号（=安装包 CFBundleVersion）、系统/机型、各栏目条数；**不含任何 Key**，接口地址只有主机名
- [ ] 模型榜五个分类能切换，行数/首名与官网对应页一致；「待核验」价格显示灰字占位，不出现编造的数字
- [ ] 点一行进模型详情：评分/名次/价格/四张领域卡/逐项成绩齐全；断网后重进详情能显示内存里已有的数据
- [ ] 模型榜下拉刷新、断网出缓存 + 横幅；「怎么算」「网页版」和页脚来源回链能开网页
- [ ] 详情页右上角能收藏/取消收藏；收藏列表按收藏时间倒序、左滑「取消收藏」可用；没有收藏时显示空态
- [ ] 杀掉 App 重开，收藏还在；飞行模式下收藏列表仍能显示标题与来源
- [ ] 「设置 → 收藏 → 清空收藏」可用且会先确认；「清除本地缓存」之后收藏仍在
- [ ] 已跌出榜单的收藏不显示热度数字（只显示保存时的来源数/参与者数），不出现别人的数字
- [ ] 设置 → AI 对话 填好地址/模型/Key，点「测试连接」返回「连接正常 · …」
- [ ] 详情页右上角对话按钮能打开弹窗，问一个不需要联网的问题能流式出字
- [ ] （走 Anthropic 时）问一个需要联网的问题，状态行出现「正在联网搜索…」
- [ ] 问一个需要联网的问题（如「这条有后续吗」），状态行出现「正在联网搜索：…」，回答里带来源
- [ ] 把 AnySearch Key 留空也能搜（匿名）
- [ ] 搜索工具调顺序（↑↓）、拨开关后杀掉 App 重开：顺序与开关都还在；升级首启时旧的单选值排第一、其余全默认启用
- [ ] 搜索工具每行「测一下」：Key 正确显示「✓ 通了」；Key 填错贴出该家的错误原话；必填 Key 为空时提示「还没填 Key —— 填好再测」且不发请求；改 Key 后旧结果自动清掉
- [ ] 第一家 Key 填错、第二家正确：问一个需要联网的问题，第二家出结果（**回退真实发生**）；把两家都弄失败，报错点名的是**排第一**那家、后几家的原话不出现
- [ ] 问一个需要打开网页的问题：SerpAPI / Serper 即使排在最前也不被调用（仅搜索的家自动跳过）；只剩它们时给「没有能读网页的工具…」
- [ ] 设置行内提示各就各位：停用的显示「已停用」，必填没 Key 的显示「未填 Key，暂不参与」（橙色），AnySearch 显示「留空即用匿名」
- [ ] 选 Tavily 但没填 Key：Tavily 被自动跳过（不发网络请求），由后面有 Key 的家接上
- [ ] 生成中点「停止」能立刻停下，而且**不**弹错误条
- [ ] 问一轮 → 杀掉 App → 重开，同一条新闻的对话还在；换一条新闻是另一场对话（各存各的）
- [ ] 弹窗垃圾桶只清当前这一条；「设置 → 对话记录 → 清除对话记录」确认后全部清空；「清除本地缓存」之后对话与收藏都还在
- [ ] 每条 AI 回答气泡右下角有「复制」按钮，粘贴出来是「那条回答 + ——《新闻标题》 + 原文链接」，点完短暂显示「已复制」；用户消息和流式生成中的气泡没有按钮
- [ ] 问一个会输出代码块 / 列表 / 表格的问题：回答按块排版（不是原样 `#`、```），代码块等宽字体带语言标签，流式生成中就逐块长出来；复制出的仍是 Markdown 原文
