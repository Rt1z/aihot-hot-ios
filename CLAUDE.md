# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An iOS (SwiftUI, min iOS 16) native app that re-renders the **热点榜** section of [aihot.news](https://aihot.news) — 10 rows, no browser. The 「主题」 section is explicitly out of scope. Zero third-party dependencies, zero entitlements (deliberate: the CI output is an *unsigned* IPA side-loaded via AltStore with a free Apple ID, so push/entitlements would break the whole distribution model).

It also has a **练习本** (rule 20): read an article, write your own summary, compare it against the source's 导读, optionally get a deliberately non-rewriting AI critique. Practice entries are user data (Application Support), never cache.

And **外部链接收藏** (rule 21): a WeChat article (or any public web page) can be brought in by auto-detected clipboard, the 收藏 「+」 sheet, a Shortcuts intent, or `aihot://add?url=…`, stored as link + title in the same `FavoritesStore` array as hot topics. Tapping one opens an **inline WKWebView reader** (full text, original styling); the same page offers AI chat and 练一练 based on the fetched body. There is deliberately **no share extension** — see rule 21 for why the free-account/AltStore distribution rules it out.

Development happens on Windows; the build happens on GitHub Actions macOS runners. `README.md` is the user-facing doc (install steps, feature-by-feature官网/App mapping table, troubleshooting) — read it before answering "how do I install / why is X missing" questions.

## Commands

```bash
# Local, no Mac required (read-only, run before pushing):
python3 tools/preflight.py       # JSON / plist / path references / Python syntax / icon wiring
python3 tools/logic_tests.py     # Python mirror of the pure Swift logic, same fixtures
python3 tools/make_appicon.py    # generates AppIcon-1024.png (gitignored, CI does this too)

# On a Mac (or via the CI workflow):
brew install xcodegen && xcodegen generate     # InOut.xcodeproj is generated, never committed
xcodebuild test -project InOut.xcodeproj -scheme InOut \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Single test:
xcodebuild test -project InOut.xcodeproj -scheme InOut \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:InOutTests/EnricherTests/testHeatIsFoundAfterALongDigest
```

`.github/workflows/ios.yml` has two **independent** jobs (`test`, `ipa`) that don't `needs` each other — the IPA is intentionally produced even when unit tests fail, so a red run still yields something installable. `CFBundleVersion` is `github.run_number` supplied on the xcodebuild command line, not from `project.yml`.

### Verifying a change with no Mac

There is no local compiler on the Windows dev box. `preflight.py` + `logic_tests.py` catch structural and pure-logic mistakes only; type errors, SwiftUI problems, regexes and packaging are all found by pushing and reading the run:

```bash
gh run list  --repo Rt1z/aihot-hot-ios --limit 3
gh run watch <id> --repo Rt1z/aihot-hot-ios --exit-status
gh run view  <id> --repo Rt1z/aihot-hot-ios --log-failed | grep -E "error:|XCTAssert"
gh api repos/Rt1z/aihot-hot-ios/actions/runs/<id>/artifacts --jq '.artifacts[] | "\(.name) \(.size_in_bytes)"'
```

A green `Build IPA` is **not** proof the product is right — the `info:` bug above produced green builds for weeks. Inspect the artifact: download `InOut-unsigned-ipa`, read `Payload/InOut.app/Info.plist`, and confirm `CFBundleVersion` equals the run number and the display-name / launch-screen / orientation keys are present. `InOut-adhoc-ipa` is usually absent by design (ad-hoc signing on `iphoneos` is not a supported combination; that step is `continue-on-error`).

## Architecture

**`RootView` is the top level**: it owns `@StateObject HotTopicsStore`, `@StateObject FavoritesStore`, `@StateObject LeaderboardStore`, `@StateObject ReportStore` **and** `@StateObject PracticeStore`, wraps five tabs in a `TabView` (热点 / 周报 / 模型榜 / 收藏 / 设置 — 设置 stays last, iOS convention), and passes the stores down **by constructor injection**. There is deliberately **no `EnvironmentObject` anywhere in this repo** — don't introduce one; sharing is `@StateObject` at the owner + `@ObservedObject` (or plain `let` for pass-through) below, or a `.shared` singleton for stateless services. `InOutUITests` indexes the 设置 tab by position (`boundBy: 4`) — reordering the tabs **before** 设置 (done once already: 周报 moved to slot 2) means syncing that test's comments, but the index only changes if 设置 stops being last.

```
RootView (TabView: 热点 | 周报 | 模型榜 | 收藏 | 设置)
   ├── HotListView          ──> HotTopicsStore ──> AIHOTAPI ──> aihot.news (anonymous read-only)
   │                                │                  └── ETagStore (UserDefaults, survives relaunch)
   │                                ├── SnapshotCache  (Caches/hot-topics.json — cold start + offline)
   │                                ├── StoryCache     (Caches/stories.json — digests & report timelines)
   │                                └── HotPageEnricher <- HTMLTextExtractor <- GET /hot
   ├── ReportTabView        ──> ReportStore ──> AIHOTAPI.weekly*/monthly* ──> /api/v1/week|monthlies
   │        │                        ├── ReportSnapshotCache (Caches/period-reports.json — cold start + offline)
   │        │                        ├── details 内存缓存（期次不可变，不落盘）
   │        │                        ├── itemBodies / itemBodyRejected 内存缓存（条目正文，同理不落盘）
   │        │                        ├── notices 按栏目分开（切到月报不挂「周报取不到」）
   │        │                        ├── lastSeen (UserDefaults/aihot.reports.lastSeen.* — 只算 Tab 角标)
   │        │                        ├── ReportPeriod (期号/区间/往期分组, pure, 镜像 18)
   │        │                        └── ReportItemID / ReportItemBody (条目 id 与正文, pure, 镜像 20)
   │        │  selectedKind（分段控件，管栏目）＋ selectedPeriod（下拉摆在分段控件正下方，管「看哪一期」）
   │        ├── ReportIssueView        （最新一期与详情页共用的正文渲染；分栏标题走 ReportSectionHeader）
   │        ├── ReportItemDetailView   （一条新闻：JSON 字段 + `/items/{id}` 完整正文，取不到就退回导语版）
   │        │        └── ReportItemBodyView <- ReportItemBody.parse(html:) <- store.itemBody(link:)
   │        └── ReportDetailView(kind:entry:)   └── store.report(kind:period:) → /…/{week|month}
   ├── LeaderboardView      ──> LeaderboardStore ──> AIHOTAPI.leaderboardHTML ──> /leaderboard*
   │        │                        ├── LeaderboardCache (Caches/leaderboard-boards.json — boards only,
   │        │                        │    details stay in memory; NO ETag on these pages → 300s/600s throttle)
   │        └── LeaderboardDetailView(slug:)          └── LeaderboardParser (pure, 镜像 17)
   ├── SaveLinkIntent (App Intents / 快捷指令) ──> FavoritesStore.add(link:) + pendingOpenLinkURL
   ├── FavoritesListView    ──> FavoritesStore (UserDefaults/aihot.favorites — USER DATA, one array,
   │        │                    two kinds: .topic = HotTopic snapshot / .link = SavedLink)
   │        ├── 顶部固定入口「练习本」──> PracticeListView ──> PracticeEntryView (read-only)
   │        ├── 右上「+」──> AddLinkSheet ──> SharedLinkURL + LinkTitleService（PasteButton 导入）
   │        ├── SavedLinkDetailView ──> ArticleWebView (WKWebView 全文/原样式/抓标题与正文)
   │        │        ├── AIChatView(subject: .savedLink) ──> AIChatNewsContext.make(link:articleText:)
   │        │        └── PracticeSheet(kind: .savedLink, articleText: 全文)
   │        └── StoryDetailView (pushed) ──> StoryDetailModel; bookmark toggle 是唯一热点收藏入口
   ├── 热点/周报详情页「练一练」──> PracticeSheet (compose → contrast) ──> PracticeStore
   │        │                        ├── Application Support/practice-entries.json + practice-drafts.json
   │        │                        │      （USER DATA：清缓存不碰、不设上限、顺序=数组顺序）
   │        │                        ├── PracticeText / PracticeStats (pure, 镜像 23)
   │        │                        ├── PracticeReviewPrompt (pure, 镜像 23；材料按全文/导读标注)
   │        │                        └── PracticeReviewModel ──> AIChatAPI(includeTools: false)（一次性短请求）
   └── AboutView (= 设置)    ──> hot + favorites + reports stores
```

Each tab's root view owns its own `NavigationStack` (`TabView` outside, one `NavigationStack` per tab — never the reverse).

**The 报道节奏 chart** is a pure-function + thin-view split, on purpose: `ReportTimeline.make(story:)` (Services) turns `Story.reports` into buckets/labels/axis ticks, `ReportTimelineChart` (a `Swift Charts` view, a system framework — no `project.yml` change needed) only draws the `Summary`. Everything except the drawing is covered by XCTest + the Python mirror; see rule 15.

**The AI chat layer** (feature: tap the bubble icon in `StoryDetailView`'s nav bar, or the toolbar in an imported article). The model can ask to call two tools — `web_search` and `read_url`. `AIChatToolRouter` executes them: **search** goes to Tencent Cloud 元宝搜索 (`SearchPro`, TC3-signed), **read** goes to an in-app `WebPageReader` (`URLSession` + `HTMLTextExtractor`, not through Tencent). The result is fed back; it decides on its own whether to search. Almost all of the risky logic is pure and pinned by tests; the transport is the part nobody can exercise locally. Sessions persist per story/link (below).

```
AIChatView (sheet, sessionKey = HotTopic.id) ──> AIChatModel (@MainActor: byte loop + SSELineSplitter,
                          │            runs the tool loop, clamps + feeds results back,
                          │            restores the session at init, persists in finishStreaming())
                          ├── ChatHistoryStore (Application Support/chat-sessions.json — user data, 50-session cap)
                          ├── AppSettings.currentAIChatConfig() ──> AIChatSecretStore (Keychain, 4 slots:
                          │        2 chat protocols + Tencent SecretId/SecretKey)
                          ├── AIChatAPI ──> AIChatRequestBuilder (bodies/headers + tool round-trips)
                          │                    └── AIChatConfig (protocol, base URL, model)
                          └── makeToolRouter() ──> AIChatToolRouter (one credential snapshot per send)
                                     ├── TencentWSARunner ──> TencentWSAAPI (SearchPro, TC3-HMAC-SHA256)
                                     │        └── TencentWSASignature (pure, 镜像 25)
                                     └── WebPageReader (read_url: URLSession + HTMLTextExtractor;
                                               不经过腾讯云；公众号风控页明确报错)

pure & tested:  SSEParser (bytes→lines→frames + both decoders) · AIChatTool (call accumulator)
                AIChatNewsContext (prompt material) · AIChatConfig/AIChatRequestBuilder
                AIChatModel.history (跨轮历史：空消息剔除 + 纯追加)
                AIChatModel.truncationNotice (一轮什么都没认出来时说哪句话)
                ChatHistoryStore.trim (封顶 50：数组顺序即淘汰权威，绝不排序)
                TencentWSASignature (TC3-HMAC-SHA256 — 镜像 25) · TencentWSAResponseParser
                WebPageReader (HTML → 纯文本，clamp 到 8000；复用 SharedLinkURL 的公开主机校验)
                ChatAnswerCopy (复制回答的文本拼装：正文 + 标题 + 出处链接)
                MarkdownBlocks.parse (回答的 Markdown 分块 — 镜像 16；渲染在 MarkdownBlocksView，
                  流式中也走分块：出字是 70ms 一批不是逐字，分块器也没有半截语法的失败态)
                LeaderboardParser.parseBoard/parseDetail (模型榜页面解析 — 镜像 17，规则 18)
                ReportPeriod.title/rangeText/groupByMonth (周报/月报的期号文案、区间与往期分组 — 镜像 18)
                ReportItemBody.parse + ReportItemID.id (条目站内页正文与 id 抽取 — 镜像 20)
                ReportUnread.isUnread (Tab 角标：只看期号，任一侧缺失不算未读 — 镜像 19)
                DiagnosticReport.hostOnly (运行诊断的地址脱敏：只留 scheme://主机[:端口] — 镜像 19)
```

### Rules that will bite you if you don't know them

**1. The upstream request contract is non-negotiable.** aihot.news publishes a `s-maxage` of 60s and the code honors it unconditionally: `HotTopicsStore.refresh()` throttles to 60s (5s only while `items.isEmpty`, so first launch and retry still work), and 429/503 `Retry-After` is stored in `nextAllowedAt` so *no* request is sent before it expires, with no parallel retries. Digest fetches are strictly serial for the same reason. There is deliberately no `force:` parameter on `refresh()` — don't add one.

**2. ETags persist, body caches do not — this asymmetry causes a whole bug class.** `ETagStore` lives in UserDefaults (survives everything); `SnapshotCache`/`StoryCache` live in the Caches directory (the system can purge them). A bare `304` therefore does *not* mean "I have the content". Every 304 path must fall back to the disk cache and, when that's empty, re-fetch with `ignoreCache: true`:
- `HotTopicsStore.performFetch()` → `.notModified` with empty `items` → `performFetchIgnoringETag()`
- `refreshDigests()` / `fetchStoryIgnoringCache(id:)`

Symptom if you get this wrong: "detail page loses its report timeline on second open", "big cards lose their body text after relaunch" — broken but not crashing, so tests won't catch it.

**3. Enrichment is all-or-nothing, and it never invents numbers.** The public API returns no 热度指数 / 涨跌 / 爆·新 badges / avatars. `HotPageEnricher` scrapes them out of `/hot` text, but only anchored on literal 文案 like 「热度指数」, and any failure returns `nil` so the UI silently falls back to API fields (source count / participant count). Existing titles are stripped from the text first so 「新」/「爆」 inside a title can't be misread as a badge. When tweaking regexes, the guiding principle in the source is *宁可少抽，不可抽错*. CSS class names are intentionally not used — only visible copy — so a Tailwind reshuffle doesn't break it.

**4. The Python logic tests are a mirror, not an authority.** `tools/logic_tests.py` re-implements the same parsing / `StoryID` / `RelativeTime` logic and runs against the *same* `InOutTests/Fixtures/*` files as the XCTest suite. It exists because the trickiest code (regex + window logic) is invisible to the compiler and this runs in milliseconds without a simulator. **If you change the Swift logic, mirror the change there or the mirror silently diverges.** Assertions must be derived from the fixture contents, not from reasoning about what the value "should" be.

   It also **cannot validate the Swift string literals themselves**, and that blind spot is not theoretical: `HTMLTextExtractor.stripElement` had its closing tag written `"</\\(tag)>"` (doubled backslash) instead of `"</\(tag)>"`. At runtime that pattern became `</` + `\s` + `cript>`, matched nothing, and silently left every `<script>`/`<style>` body in the extracted text — while the Python mirror, which uses the correct `</%s>`, stayed 74/74 green. When Swift and the mirror disagree, **Swift is the authority**; the mirror is either wrong or blind. Regexes here are dense (`"<\(tag)\\b..."` legitimately mixes a one-backslash interpolation with a two-backslash `\b`), so read the bytes (`sed -n 'Np' file | od -c`) rather than trusting the eye.

**5. `Fixture.url()` calls `XCTFail` when a fixture is missing** rather than skipping. Keep it that way — a skipped test is a false green.

**6. Favorites are user data, not cache.** `FavoritesStore` persists to `UserDefaults` (`AppSettings.favoritesKey` = `aihot.favorites`), never to the Caches directory — Caches gets purged and losing a user's saved list is a bug. Two consequences that must not regress: `HotTopicsStore.clearCache()` (labelled 清除本地缓存) clears only Caches + ETags + in-memory dicts and **must never touch favorites**; and favorites have **no cap** (unlike `StoryCache.maximumEntries = 300`) — silently dropping user data is worse than unbounded growth. Encoding failure must leave the previous blob intact rather than writing an empty array.

**Chat history is user data too** (`ChatHistoryStore`, Application Support/`chat-sessions.json`, keyed by `HotTopic.id`) — not Caches (purgeable), not UserDefaults (sessions grow to MB scale). `clearCache()` must not touch it; 「清除对话记录」 deletes only that one file, behind its own confirmation. It **does** have a cap (unlike favorites): `maximumSessions = 50`, oldest evicted first — but a *disclosed* cap written into the settings-page footer is not the silent data loss this rule forbids, so **changing the number means updating that footer too**. Eviction order is array position (upsert = remove + append, `trim` = `suffix(50)`), never a sort — same reason as rule 8. A whole-file decode failure yields an empty store instead of per-item salvage: a deliberate divergence from `FavoritesStore` (stored messages are our own shape; a corrupt file can only mean the file broke, and guessing a partial conversation is worse than starting fresh). `AIChatModel.finishStreaming()` persists (success/error/cancel all pass through it) and `reset()` deletes the session — garbage can never resurrect a cleared conversation.

**7. A favorite is a snapshot, so its `rank` is stale — never use it to look anything up.** `HotTopicsStore.enrichmentInfo(for:)` resolves **by rank**, so passing a favorited topic straight in would show whatever is currently at that rank — someone else's 热度指数. The 收藏 row may only show a live number after matching the favorite's `id` against the current list and using *that* item's rank (see `FavoritesListView.liveHeatInfo`); when the id is no longer listed, fall back to the snapshot's source/participant counts. Favorite rows also deliberately show no rank at all. This is the 「不编造数字」 rule applied to a stale snapshot.

**8. Order favorites by array position, not by sorting.** `FavoritesStore.items` is maintained newest-first by insertion, and `load()` returns the stored order untouched. Don't "simplify" it to `sorted(by: favoritedAt)` — Swift's `sort` is not stable, so two favorites saved in the same second would swap places on every relaunch. `FavoritesStoreTests.testOrderSurvivesReloadWhenTimestampsTie` pins this.

**9. The AI client must NOT reuse `AIHOTAPI`'s session, and must keep `Accept-Encoding: identity`.** `AIHOTAPI`'s session is 15s idle / 30s total, sized for one-shot JSON. A thinking, web-searching chat turn easily exceeds 30s, so reusing it kills every request in a way that looks like "the API is broken". `AIChatAPI` builds its own configuration (90s idle / 600s resource). The explicit `identity` encoding matters for a second reason: URLSession otherwise asks for gzip and decompresses transparently, and that buffering layer is the classic cause of "the SSE doesn't stream, it all arrives at the end".

**10. Two protocols, two implementations — never one wrapped in the other.** Anthropic (`/v1/messages`) and OpenAI-compatible (`/chat/completions`) have genuinely different wire formats, and **tool use is where they diverge most**: Anthropic wants `tool_use` / `tool_result` content blocks with matching ids, OpenAI-compatible wants `tool_calls` on the assistant message plus separate `role: "tool"` messages whose `function.arguments` is the **raw JSON string** (not an object). The Anthropic side must follow Anthropic's own shapes; do **not** route Claude through an OpenAI-compatible shim. All of it lives in `AIChatRequestBuilder` plus the two decoders, as named constants and small pure builders with comments, because none of it can be exercised locally. `AIChatRequestBuilder.enableRefusalFallbacks` remains the documented one-line escape hatch (see README §4/§7).

**11. The news material goes in the FIRST USER MESSAGE, never only in `system`.** Two reasons: the model can only hand `read_url` a URL it has actually **seen**, so the original-article link has to be in a message (not just in `system`); and keeping it in the first user turn keeps `system`/`tools` byte-stable and `messages` append-only, so the cached prefix survives the whole conversation. `AIChatNewsContext` also uses **absolute** times only — `RelativeTime.relative` ("3 小时前") changes every turn and would break that prefix.

**12. Tool blocks live inside ONE turn; history stays text-only.** A turn may contain several tool round-trips and those are echoed in full (Anthropic: `tool_use` + a matching `tool_result`; OpenAI: `tool_calls` + `role:"tool"`). But once the turn ends, only the assistant's **text** is kept and the next turn sends text-only history. This is load-bearing, not laziness: the preserved-thinking history check only validates `thinking` blocks you actually replay, so replaying none keeps the feature outside that check's blast radius — and the tool blocks we do echo are ones **we** assembled from the stream (`AIChatToolCallAccumulator`), so they cannot carry a mismatched signature. `testAnthropicHistoryIsTextOnlyAndCarriesContextInFirstUserTurn` pins the history shape; the two round-trip shapes have their own tests. A turn is capped at 5 tool rounds (`AIChatModel.maximumToolRounds`) — every round costs money.

**13. 联网搜索只有一个后端：腾讯云元宝搜索（SearchPro）；TC3 签名是最容易写错的部分.** 五家搜索工具与回退链已删除（设置里的顺序/开关也不再存在）。现在的分工是：`web_search` → 腾讯云元宝搜索；`read_url` → App 内 `WebPageReader`。几条必须守住的线：
- **接口契约**：`POST https://wsa.tencentcloudapi.com/`，`X-TC-Action: SearchPro`，`X-TC-Version: 2025-05-08`。没有简单 API Key —— 用腾讯云的 **SecretId + SecretKey** 做 TC3-HMAC-SHA256 签名。
- **签名的两个致命细节**：① 规范请求串里 `CanonicalHeaders` 本身以 `\n` 结尾，拼接时**还要再多一个 `\n`**（官方示例的 `7019a55…` 规范串哈希就是按这个形状算的；少一个换行会静默签错）；② `Date` 必须取 **UTC+0** 的日期，`X-TC-Timestamp` 与服务器时间相差超过 5 分钟会报签名过期。参与签名的头部是 `content-type;host;x-tc-action`（值统一小写）。`TencentWSASignature` 是纯函数，Swift 用例钉住官方示例的 `35e9…`（请求体哈希）与 `7019…`（规范串哈希），镜像 25 用固定测试密钥对照同一套 HMAC 链。
- **响应是「数组里装 JSON 字符串」**：`Response.Pages` 是 `[String]`，每个元素还要再解一次；**单条坏数据只跳过那一条**，不让整次搜索失败。错误信封是 `Response.Error{Code,Message}`，HTTP 200 也可能带错误 —— 先查 Error 再解析 Pages。鉴权类错误（`AuthFailure.*`）必须给出「去设置核对 SecretId/SecretKey、确认账号已开通元宝搜索」的可执行文案，并附 `RequestId`；限频/配额、服务不可用分开说。
- **元宝搜索没有读网页接口**：`read_url` 由 `WebPageReader` 在 App 内用 URLSession 抓取（复用 `SharedLinkURL.normalized` 的公开 http/https 边界，2 MB 上限），再用 `HTMLTextExtractor` 压成纯文本，`AIChatToolResult.clamp` 截到 8000。公众号会落到 `wappoc_appmsgcaptcha`，这种情况明确报错（让用户去 App 内阅读器完成验证），**不要拿验证页文字冒充正文**。
- **凭据与设置**：`AIChatSecretStore` 共四份（两条对话协议 + 腾讯 SecretId/SecretKey），默认 Keychain、写失败时降级到应用内并**在设置页明说**。「测试搜索」用当前草稿发一次真实 `SearchPro`（消耗一次额度），错误原文直接显示。
- **夹具纪律**：`tencent-wsa-search.json` 是按**官方 API 文档的示例响应**改写的（我们没有可用的腾讯云密钥，无法真实调用），测试注释里必须写明「不是个人抓取」；`tencent-wsa-error.json` 用的是文档里的鉴权失败形状。不要把「手写 payload 上钉绿」当成真实链路已验证。
- **不要再把五家搜索工具/回退链加回来**：工具声明与执行者无关，换一家只该换 `AIChatToolRouter` 里的执行者，不应改请求体。

**14. 两件事分开：原文链接走系统阅读器；导入文章用内嵌 WKWebView.** 
- **热点/周报的原文链接**仍然只走 `SFSafariViewController`：`SafariView.entersReader`（默认 `false`）映射到 `Configuration.entersReaderIfAvailable`。它是*尽力而为*——页面自己支持阅读器才进得去，不支持就照常显示，所以打开它不会比关掉更差；真正的风险是**支持阅读器但抽得不好**的页面，而 SFSafariViewController 里能不能退出阅读器不由我们决定。所以「打开原文」旁边那个「网页版」按钮不是装饰，是唯一的回退路径，删掉它就把用户困住了。**不要把这些链接改成 WKWebView**：它完全做不到阅读器模式，换成它只会丢掉功能、还要自己接分享/返回。哪个入口进阅读器由调用方决定：`WebLinkSheet(url:entersReader:)` 里的 `entersReader`，同一个链接的两种打开方式靠 `id` 上的 `#reader` 后缀区分（否则 SwiftUI 认为「还是那一个」，点「网页版」不会重新弹）。aihot.news 是网页应用、没有正文，那个入口永远走网页。
- **收藏里的导入文章**是另一回事：微信对普通 URLSession 请求返回风控验证页，只有真正的浏览器能拿到全文，而产品要求「进入文章即显示全文、尽量保持原样式」。所以 `SavedLinkDetailView` 内嵌一个 WKWebView 直接打开原文（`ArticleWebView`），它同时负责读回真实标题与正文纯文本（供 AI 对话/练习）。系统阅读器仍留在菜单里（「在阅读器打开 / 在 Safari 打开」）作为逃生口。**风控验证页不能盖错误遮罩**：用户需要在页面上完成验证，遮住就没法操作；此时只给一行提示，并把正文置空（不要让练习/对话拿验证页文字当文章）。**页面自动发起的自定义协议跳转必须静默取消**：小红书这类页面一载入就用 JS 往 `xhsdiscover://…` 上跳，若无条件交给系统就会立刻弹「在『小红书』中打开？」，把用户从阅读器里带走（`ArticleNavigationPolicy`，单测钉住）。只有 `WKNavigationType.linkActivated`（用户真的点了链接）才 `UIApplication.open`；`target=_blank` 也一样，非 http(s) 不塞进 WebView。阅读器的底色必须跟随 App 主题：WKWebView 设为非不透明、`backgroundColor`/`scrollView.backgroundColor`/`underPageBackgroundColor` 都用 `Theme.background`，公众号页面的容器背景置为透明，并把 WebView 铺到屏幕底部。**不要注入 `body{background:#fff}`** —— 深色模式下那会在正文上下露出一块白底，和底部安全区形成色差。

**15. 报道节奏图的一切数字都出自纯函数 `ReportTimeline`，它是被镜像的那类逻辑.** `ReportTimeline.make(story:)` 不读 `Date()`（窗口由数据自己的最早/最新一条决定），所以同一条 story 永远得到同样的图，能被夹具钉住。`ReportTimelineChart` 只负责把 `Summary` 画出来，**不允许**在里面分桶、算刻度或改标签。三条不变量：桶按**北京时间**对齐（与 `RelativeTime` 同一口径，否则「哪一天」会按 UTC 切）；`count == 0` 的空桶要留着（断档本身就是结论）；**桶数 ≤ 24**——x 轴是按标签分类的轴，重名会被合并成一根柱子，而 ≤ 24 恰好保证标签不可能重复。轴刻度只能整数除法 `i * (n - 1) / 4`，**绝不能引入 `round()`**：Python 是银行家舍入、Swift 是四舍五入，`n = 25` 时两边会挑出不同的刻度。改这里就要同步改 `tools/logic_tests.py` 的「镜像 9」，两边读同一份夹具 `InOutTests/Fixtures/story-timeline.json`（`story.json` 只有 1 条报道、且被 `len(reports) == 1` 钉着，不能拿来用）。

**16. 「连接提前中断，回复可能不完整」只留给「真有正文、只是收尾标记没来」，别把它当成万能兜底.** 这句话原来被四种完全不同的故障共用：协议与地址不配套（另一条协议的流被本协议的解码器读到，一个事件都认不出来）、服务端回了非 SSE 的东西却谎报 `Content-Type: text/event-stream`、一帧都没收到、以及只收到思考块就断了。前三种与「连接中断」毫无关系，用户照着一句话什么都查不出来 —— 侧载的 App 挂不上调试器，**界面上那行字就是唯一的诊断信号**，所以 `AIChatModel.consume` 会把「切了几帧、认出几个事件、前 5 段认不出来的原文」记进 `StreamedRound`，由纯函数 `AIChatModel.truncationNotice` 分情况说话：拿**另一条协议的解码器**认出样本时直接点名该换哪条协议（这是最值钱的一条，`AIChatModelTests` 用两份 SSE 夹具双向钉住），否则把接口真正发来的**帧数**和头尾两段原文贴出来。**帧数不能省**：流的第一帧（OpenAI 的 `role` 分片、Anthropic 的 `message_start`）按协议本来就不产出事件、必然落在样本里，所以只贴开头等于什么都没说 —— 「共切出 1 帧」和「共切出 40 帧」是两种完全不同的故障。新增失败分支时把话说清楚、并把原文带上，不要退回一句兜底；`tools/logic_tests.py` 的「镜像 11」与 Swift 用例读同一份夹具。

**17. SSE 的行由 `SSELineSplitter` 自己切，**绝不**改用 `bytes.lines`.** 实测（CI，iOS 模拟器）：平台的 `AsyncSequence.lines` **把空行整个丢掉** —— 喂 `"data: a\n\ndata: b\n\n"` 交出 `["data: a", "data: b"]`（`SSEParserTests.testPlatformLineSplitterDropsBlankLinesWhichIsWhyWeDoNotUseIt` 就是那把尺子）。而空行是 SSE 分帧的**唯一**依据（`SSEFrameReader` 只有见到空行才交出一帧），所以后果是固定的：整条流被拼成**一帧** → 拼起来的 JSON 解不出来 → 每个事件都认不出来 → 真机上「一个字都没有」加一句看不懂的提示。最坑的是**全部夹具用例仍然全绿** —— 它们都是自己按 `\n` 切好行再喂给分帧器的，恰好绕开了出事的那一段（与规则 4 里 `stripElement` 那个盲点同一类问题：本地能测的那半段永远是对的；真机上给用户看的那半段没人测过）。所以 `AIChatModel.consume` 是 `for try await byte in bytes` + `SSELineSplitter`（只认 LF，`\r` 仍旧由分帧器剥）。`SSEParserTests` 两头都钉住：逐字节的 `SSELineSplitter` 用例、以及「夹具的**字节**走一遍 == 按行喂一遍」的端到端用例（`testFixtureBytesProduceTheSameRoundAsItsLines`）；改这里时同步 `tools/logic_tests.py` 的 `ByteLineSplitter` 与镜像 6 的断言（两份夹具都跑）。**推论**：凡是把「字节流 → 行」交给平台的地方，都值得像这样量一次再写用例。

**18. 模型榜没有公开 JSON 接口，页面解析的锚点规则与夹具纪律.** `/leaderboard*` 的数据只在 SSR HTML 里（开源版 4.0 起模型榜被移出框架，`/openapi-v1.json` 也没有对应操作），所以 `LeaderboardParser` 是第二个「从网页文本抽数据」的解析器（第一个是 `HotPageEnricher`，第三个是周报条目正文 `ReportItemBody`，见规则 19），但锚点纪律不同：**榜页行/字段锚 `data-slug`、可见文案、`href`，不锚 Tailwind class；详情页的逐项成绩（BEHIND THE SCORE）例外——必须锚字段级 class**（`text-[13.5px] font-semibold text-ink` 等），因为名字前可能有字母徽章（如 P），盲切文本会把徽章当成名字（Python 原型上验证过的真坑）。class 锚点有改版风险，由三份 2026-10-20 的真实抓取夹具（`leaderboard-overall/coding/detail.html`）钉住——**改版时测试会红，一眼可见**；分数/价格会随站点更新漂移，断言的是解析器对这份字节的行为，不是对「今天的官网」。解析失败（零行/无 `<h1>`）返回 nil，上层静默降级到缓存或横幅，宁可少抽不可抽错。价格一律保留**展示原文** String（「待核验」→ nil），不转数字。榜页 `s-maxage`≈300/600 且**没有 ETag** —— 节流 300s（榜）/600s（详情），不做条件请求（做了也没用，还会撞上规则 2 的 304-无正文坑）。镜像 17 读同一批夹具；两个只在 Swift 侧咬人的正则坑已由镜像当场抓出并双侧修复：字符类 `[·]` 会吃换行（要写 `[^\n·]`）、非贪婪 `(.+?)` 会带尾随空格（捕获后要 trim）。

**19. 周报/月报与模型榜相反：有 JSON 接口、有 ETag，但 304 坑一模一样.** `/api/v1/weeklies|monthlies`（`/latest`、全量索引、`/{week|month}` 六个端点）是正经 REST：匿名只读、`s-maxage=300`、**带真 ETag** —— 所以走 `getJSON`、节流 300s（本地为空放宽 5s），并按规则 2 在 latest / index / 详情**三条路径各留** `ignoreCache: true` 兜底（ETag 在 UserDefaults 跨启动保留、快照在 Caches 会被清，漏一条就是「周报页永远空」）。`ReportStore.performFetch` 里 **latest 与 index 两个请求独立成败**（一个挂不拖垮另一个：index 成了 latest 挂了时往期照常能点）；索引全量无分页，页面上要**剔掉与 latest 同期号的那条**（往期不重复列最新一期）。已发布期次不可变 → 详情内存永久缓存、不落盘。字段纪律：老期次（夹具实测 2026-W30、2026-09）的 `overview` 与 `sections[].summary` 真的是 `null` → 除 `Item.title` 外**全 Optional**，nil 整块省略不留占位；`sections[].label` 原样渲染（老期是主题句、新期是分类名，不归一化）；`periodStart/periodEnd` 是 `yyyy-MM-dd` **展示原文** String 不转 Date，换算全部交给纯函数 `ReportPeriod`（镜像 18）—— 同一条数据永远得到同一行文案，也不引入日历/时区依赖；`generatedAt`/`publishedAt` 是带毫秒 ISO8601 → `JSONDecoder.aihot`（快照 round-trip 断言必须**秒精度**，encoder 不写小数秒）。条目点开走**原文**（阅读器，规则 14），站内 `links.aihot` 永远走网页（网页应用没有正文）；期的「网页版」回链 = `links.aihot`，详情页必须总有一个可点的 URL（缺了就退栏目页）。页脚署名/回链同样是硬要求（同模型榜的 `attributionFooter` 逻辑）。夹具四份真实抓取（`report-weekly-latest/index/older.json`、`report-monthly-latest.json`，匿名无 Key）；`report-weekly-older.json` 就是「null 字段」的回归钉。Tab 角标与冷启动：`ReportUnread.isUnread(latest:lastSeen:)` 只看期号（已发布期次不可变），**任一侧缺失都不算未读** —— 新装用户的基线由 `ReportStore.observeLatest` 在第一次看到某一期时补上，不会一打开就挂「新」；`markSeen` 只在 `ReportTabView` **真正可见**时调用（TabView 不销毁视图，否则在别的 Tab 里收到的角标检查结果会被顺手清掉）。`lastSeen` 存 UserDefaults（`aihot.reports.lastSeen.<kind>`），与内容缓存分开 —— 清缓存不该把「已读」清掉。角标检查 `checkForNewReports()` 是**独立的一条路径**：只拉 `/latest`、用自己的 300s 节流（不占 Tab 的完整刷新窗口），失败完全安静；冷启动只拉当前分段（`loadIfNeeded(kind:)`），月报等用户切过去再拉。横幅也按栏目分开（`notices[kind]`）：切到月报时不该还挂着「周报暂时取不到」。`ReportStore.clearCache()` 由设置页「清除本地缓存」与 `HotTopicsStore.clearCache()` 一起调：清快照/内存（含 `details` 与条目正文三件套）/节流时间戳、**保留 `states`**（界面不白屏），收藏与对话照旧不碰（规则 6）；ETag 仍由 `ETagStore.shared.clear()` 的全前缀清掉，这里不重复。镜像 18 曾当场抓出 Swift 侧 `rangeText` 跨年分支把原始 `yyyy-MM-dd` 直接透出（文档/计划都写的点分 `2025.12.29`）——又一个「镜像不是权威，但比没有强」的例子。**两个切换各管一件事，别混**：分段控件（`selectedKind`）管**栏目** —— 最新一期、往期列表、下拉里的期次全是同一栏；分段控件**正下方**的下拉管「**看哪一期**」（`selectedPeriod`，nil = 最新一期）—— 列出当前栏的期次（「最新一期」+ 往期各期，按月分组），选中往期就把上方正文**就地换成那一期**（`store.report(kind:period:)`；往期不可变、内存永久缓存，回看不打网络）。取数由 `.task(id: issueSelectionKey)` 驱动，key 是 `栏目|期号` —— 切栏目时选择重置回最新一期且旧任务随之取消（期号是栏目内的：周报 W41 与月报 2026-09 不是一回事），返回后还要核对栏目/期号没变才落状态（await 期间切走的那份结果是过期的）。下拉只在往期非空时出现；往期列表照旧保留（按月分组、点行 push 详情页）。由此保留一条会咬人的约束：详情页取数必须用 `ReportEntry.kind`（`week`/`month` 谁非 nil 就是谁），**不要拿 `selectedKind` 去猜** —— 索引条目自带栏目，猜错就是拿周报的期号打月报端点。

**条目详情页有网络请求，但每条只发一次.** 上半是周报 JSON 里已有的字段（标题/来源/`publishedAt`/`summary`，那个 summary 就是官网的「AI 导读」）；下半是**完整正文**，来自站内页 `/items/{id}`：这一页**没有 JSON 接口**（`/api/v1/items/*` 全 404），结构化载荷是 React Router 的 turbo-stream（实测 2026-10-21，`__NEXT_DATA__` 不存在），只能整页抓 HTML，由纯函数 `ReportItemBody` 从**唯一锚点** `<div class="prose">` 取块（镜像 20；这是第三个「从网页文本抽数据」的解析器，夹具纪律同规则 18）。三条铁律：
1. **id 取自 `links.aihot` 的路径末段，且上一段必须是 `items`**（`ReportItemID`）—— 否则 `/weekly/2026-W42` 的末段 8 个字符、全在合法字符集里，会被当成条目 id 发出去；绝不能拿 HTML 地址本身去请求（同 `StoryID`）。
2. **失败面是静默的**：没链接 / 页面认不出 / 断网，三种都退回「AI 导读 + 打开原文」那一版，详情页的骨架屏只在**真的在取**的时候出现（`isLoadingBody`），既没取到也没在取就整块省略 —— 宁可少显示，不显示半个页面。噪声过滤只认三种**通用**形态（全空、一个字母数字都没有、`[[…]]` 模板变量），**不照着某一家的中文文案写死**：夹具里「收听文章」是被断言为「必须留着」的，硬编码就是猜（规则 18 的 `宁可少滤，不可滤错`）。
3. **缓存口径**：这一页 `s-maxage=599` **没有 ETag**（规则 2 的 304 坑不存在，也别去做条件请求），而**已发布的条目不可变** → 成功与「认不出正文」都永久内存记住（`itemBodies` / `itemBodyRejected`），同一个 id 一个会话里只打一次网络；只有失败留 5 秒地板等重试，外加全局 `Retry-After` 闸门照旧。`clearCache()` 连这三个字典一起清。

**行内片段（`inlineRuns`）的结算纪律**：`<a>`/`<b>`/`<strong>` 的**开标签与闭标签都是结算点** —— 只在闭合处结算会把锚点前面那段普通文字吸进链接（google 夹具 42 个锚点几乎每段都中招：整句变成链接色）。结算时 `flush()` **只折叠空白、不裁剪两端**（片段之间的分隔空格是页面上的真实文字，裁掉就把词粘在一起 —— xai 夹具的 `<strong>Grok</strong> 支持聊天…` 就是回归钉：期望「Grok 支持」而非「Grok支持」）；只有整组片段的**两端**各裁一次（`trimBlockEdges`，HTML 缩进不是内容）。`href` 只认绝对 http/https：`#footnote-1` 这类页内锚点在我们这里没有落点，带进渲染层只会变成点不开的死链接（文字照常保留）。渲染侧（`ReportItemBodyView`）**必须**给链接片段显式 `piece.foregroundColor = Theme.accent` —— `Text` 上的 `.foregroundColor(Theme.textPrimary)` 会盖掉「靠 tint 渲染出来的链接色」，不上色的话链接与正文一模一样、根本看不出哪里能点。google 夹具的验收口径：42 个锚点 → 42 个离散的链接片段，零个超过 60 字符的链接片段。

「打开原文」走阅读器、「网页版」走 `links.aihot`（规则 14）都留在这一页里，条目行本身只负责推入它；正文里的**行内链接**由 `.environment(\.openURL, …)` 改写成同一个口径 —— aihot/aihot.virxact.com 主机永远走网页，其余进阅读器（`OpenURLAction` 返回 `.handled`，别把链接丢给系统 Safari）。

**20. 练习本是用户数据；AI 点评是教练，不是代笔.** 「练一练」把「读完写总结」做成闭环：写作 → 保存 → 对照原文 →（可选）AI 点评。几条必须守住的线：
- **存储**：`PracticeStore` 落 `Application Support/practice-entries.json` 与 `practice-drafts.json`（用户数据，同 `ChatHistoryStore` 的理由），`clearCache()` 绝不碰；**不设上限**（每条约 1 KB，用户亲手写的东西不该被自动淘汰），也不进 UserDefaults。顺序的权威是**数组顺序**（新记录插到头部），绝不按 `createdAt` 排序（同规则 8）。整文件解码失败按空处理；编码失败保留旧文件。
- **历史只读**：回看页不提供编辑，「再练一次」生成新记录。保存后在同一 sheet 里「返回修改」会更新**同一条**记录，且文字一变就把旧 AI 点评作废（点评针对的是另一份总结）。
- **模式切换不丢内容、不自动拆分**：自由写 ↔ 三段式只在**目标模式为空**时搬运，两边都写过就互不覆盖（`PracticeText.transferring`，镜像 23）。机械拆出来的结构不是用户的结构。
- **草稿按文章自动保存**：按 `article.draftKey`（来源+id）去重，800ms 防抖；工具栏关闭与 `onDisappear` 各自兜底一次（下滑关闭不经过按钮）；保存成正式记录时删除草稿。
- **点评是教练不是代笔**：`PracticeReviewPrompt`（纯函数，镜像 23）只允许四件事 —— 覆盖度、准确性、一个追问、不重写不夸奖。材料超过 8000 字在字符边界截断并**明确告诉模型后文省略了**（不说的话它会把「没看到」误判成「用户漏写」）。热点条目只有导读，`basis` 必须写「导读」并存进点评快照，**不许假装看过全文**；周报条目有正文时才是「全文」。材料永远不放 system，只放第一条 user 消息（同规则 11 的理由）。
- **点评请求是精简的一次性请求**：`AIChatAPI.streamChat(includeTools: false)` → 不带 tools、不带 thinking、`max_tokens` 降到 2000/1500（`AIChatRequestBuilder` 里两个 review 常量）。流式读取仍走 `SSELineSplitter` **逐字节**消费（规则 17），绝不用 `bytes.lines`。结果作为 `PracticeReviewSnapshot` 存进记录，之后离线也能看；失败只影响这一条点评，记录照常保存。
- **文章快照只存导读，不存全文**：全文可能上万字符且能重新取；「再练一次」的基准退回导读（快照里一定有）。所以重练周报条目时不会再有「全文」基准 —— 这是已知取舍，别为它引入正文落盘。
- **统计按北京时间切天**：`PracticeStatsCalculator` 用 `Asia/Shanghai`、一周从周一开始；今天还没写就从昨天起算（白天不该显示断签）。纯函数、`now` 由调用方传入；镜像 23 两边钉住。
- **入口不新增 Tab**：iOS 的 `TabView` 最多平铺 5 个，第 6 个会被收进「更多」。所以入口是热点/周报两个详情页工具栏的「练一练」+ 收藏 tab 顶部固定一行「练习本」（收藏为空时也在）。
- `InOutUITests/PracticeFlowUITests` 走的是真榜单，**需要网络**；拉不到榜时 `XCTSkip`，不让离线环境变成假红。

**21. 外部链接收藏：入口是手动粘贴 / 快捷指令 / URL Scheme，**不要**加分享扩展.** 公众号文章或任意公开网页通过三条路进收藏：收藏页「+」表单（可粘贴）、快捷指令 intent、`aihot://add?url=…`。**不做启动/回前台自动探测剪贴板** —— 这条已按产品要求删除，不要加回来。几条必须守住的线：
- **不要加 Share Extension。** 当前分发模型是免费 Apple ID + AltStore：扩展与主 App 跨进程传数据只能靠 App Group，而免费 Personal Team 对 App Group 的支持不可靠，AltStore 重签名很可能直接拒签、把安装搞坏；而且 Apple 不支持从分享扩展拉起宿主 App（`NSExtensionContext.open` 只对 Today/iMessage 扩展有效，responder-chain 那套在 iOS 18+ 会被系统拒绝）。要改这条，先改分发模型（付费账号），别在本仓库里偷偷加 entitlement。
- **链接校验是安全边界**：`SharedLinkURL.normalized` 只收公开的 http/https；拒绝 localhost、`.local`、私有/保留 IPv4（含 100.64/10、198.18/15、192.0.0.0/24）、链路本地 IPv6、裸主机名与带 userinfo 的 URL；长度上限 2048，剥掉 fragment。规则改一处就要同步镜像 24 与 `SavedLinkTests`。
- **从一段文字里捞链接**：`SharedLinkURL.firstURL(in:)` 必须排除全角标点（`？！，。；、`）与尾随 ASCII 标点 —— 微信/文章里复制出来常常是「链接：https://…？详情见原文」。这个坑在镜像 24 上当场抓出过一次（Swift 与 Python 两边都漏了 `？`）。
- **剪贴板只在用户点按钮时读，且必须用系统 PasteButton。** 没有自动探测、没有后台轮询。`AddLinkSheet` 的「从剪贴板读取」用 SwiftUI `PasteButton(payloadType: String.self)`（系统视为明确用户意图，不弹 iOS 16 的二次「允许粘贴」）。**不要**程序化读 `UIPasteboard.string` —— 既会弹授权，也是隐私问题。
- **快捷指令入口只有一条**：`SaveLinkIntent`（App Intents）+ `InOutAppShortcuts`，语义是「收藏链接并打开这篇文章」。它运行在 App 自己的进程里，不需要 App Group；`openAppWhenRun = true`，收藏后把 URL 写进 `AppSettings.pendingOpenLinkURL` 并发 `.aihotOpenLink`，**成功不返回对话框**（`some IntentResult`，不是 `ProvidesDialog`）。`RootView` 在启动 / 回前台 / 收到通知三个时机消费（另有 0.5s 补查：冷启动时 Intent 的 perform 可能比 RootView 晚，只发通知会漏），切到收藏并把 URL 通过 binding 交给 `FavoritesListView`，后者用 `navigationDestination(isPresented:)` 自动 push 文章详情。`aihot://add` 也走同一条路径（收藏并打开）；`aihot://favorites` 只切 tab。快捷指令参数用 `String` 而不是 `URL`：分享输入常常是文本，`URL` 会在动作校验阶段就失败。不要把它做成分享扩展。
- **URL Scheme 契约**：只认 `aihot://add`（host 必须正好是 `add`，其它路由忽略）；内层 URL 走同一套 `normalized`；`title` 可选（调用方要 percent-encode）。`RootView.onOpenURL` 只做三件事：`SavedLinkImporter.importLink` → 切到收藏 tab → 没带标题就异步 `LinkTitleService` 抓一次再原地更新。导入逻辑抽在 `SavedLinkImporter` 是为了能单测 —— UI 测试进程没有 TCC 权限去打开另一个 App，scheme 的端到端没法可靠地写成 XCUITest（试过，`Request is not trusted`）。
- **数据模型**：`FavoritesStore.Favorite` 有 `kind`（`.topic` / `.link`），老数据没有 `kind` 时按「有 topic 就是 topic」推断 —— 这条迁移不能回退，否则升级后收藏全丢。两种收藏共用**一个数组的顺序**（新的在前），不按时间排序（同规则 8）；链接按规范化 URL 去重。链接只存 `url + title`，**不显示热度/排名**（它不是榜单条目）。
- **标题的取法**：普通站点先走 `LinkTitleFetcher`（URLSession）；公众号对普通请求会重定向到 `wappoc_appmsgcaptcha` 验证页（实测），必须落到 `LinkTitleWebFetcher`（隐藏 WKWebView，15 秒上限，同时只允许一个请求）。解析顺序：`og:title`（两种属性顺序）→ 非通用 `<title>`（`LinkTitleParser.isGenericTitle` 过滤「微信公众平台」等）→ 公众号模板里的 `msg_title`。取不到返回 nil，上层用「微信公众号文章」或域名兜底，**绝不编造标题**。打开文章后，若当前标题**仍是兜底值**才用页面真实标题自动补上 —— 用户手改过的标题不能被覆盖。夹具 `link-title.html` 是手写的（测试注释已标明），不是抓取。
- **内嵌阅读器**：`SavedLinkDetailView` 用 `ArticleWebView`（规则 14）。加载完成后从 `#js_content`（退回 `article`/`main`/`body`）取 `innerText` 存作 `articleText`（上限 20k），供 AI 对话与练习；公众号页面注入 CSS 藏掉站点顶栏/底栏/二维码。微信风控页（`wappoc_appmsgcaptcha`）只给提示、不盖遮罩、不把验证页文字当正文。
- **AI 对话与练习**：`AIChatSubject` 把「热点」与「导入文章」统一成会话 key + system + newsContext；文章的资料由 `AIChatNewsContext.make(link:articleText:)` 拼（链接原样出现，正文截断到 6000）。练习用 `PracticeArticle.Kind.savedLink`，`articleText` 没取到前「练一练」保持禁用。
- **UI 用例**：`SavedLinkUITests` 覆盖手动添加、自动抓标题、文章内 AI 对话/练一练；`SaveAndOpenLinkUITests` 覆盖快捷指令的「收藏并打开」消费路径。涉及网络的断言在拿不到内容时 `XCTSkip`。

### Project file conventions

- **Never add `info:` to a target in `project.yml`.** XcodeGen's `info.path` means "generate a plist *at* this path", not "use this file as the base". With it set, XcodeGen overwrites `InOut/Info.plist` with its own defaults and every hand-written key is lost — that silently shipped an app with a default display name instead of `InOut`, with no `UILaunchScreen` (letterboxed on modern iPhones), rotatable to landscape, and with `CFBundleVersion` frozen at `1` so AltStore could never detect an update. The target sets `INFOPLIST_FILE: InOut/Info.plist` in `settings` instead, which is why the committed plist is the real one and why `preflight`'s check of it is meaningful. `CFBundleVersion` must stay `$(CURRENT_PROJECT_VERSION)` so the CI run-number override lands.
- `InOut.xcodeproj` is generated by XcodeGen and gitignored. **Never edit it.** `project.yml`'s `sources: - path: InOut` is a directory, so new `.swift` files under `InOut/` are picked up automatically with no project edit (same for `InOutUITests/` under its own target).
- **`InOutUITests` is a real XCUITest target** (`bundle.ui-testing`, `testTargetName: InOut`, no TEST_HOST) whose cases pin what unit tests and the mirror structurally *cannot* see: the practice round trip (hot detail → 练一练 → save → 收藏 tab 里的练习本), adding an external link by hand (收藏 → + → URL → save → 列表出现), automatic title fetching, the imported-article reader with AI chat and 练一练, and the shortcut's save-and-open path (pending link → 收藏 → auto-pushed article). The practice and article cases need live network, so they `XCTSkip` when content doesn't load. The scheme's test action includes both `InOutTests` and `InOutUITests`, so plain `xcodebuild test -scheme InOut` runs them. There is **no launch-argument reset anymore** (the search-provider order/toggle UI was removed), so UI tests must tolerate whatever settings the simulator already has. The one launch argument left is `uitests-open-link=<url>` (`InOutApp.init`), which seeds a favorite plus `AppSettings.pendingOpenLinkURL` to pin the shortcut's save-and-open path; it must not touch the Keychain.
- Where to change what: display name → `InOut/Info.plist` `CFBundleDisplayName`; bundle id / `MARKETING_VERSION` → `project.yml`; colors, spacing, fonts → `InOut/Design/Theme.swift` (`Theme` / `Metrics` / `Typography` are the only place these belong).
- `InOut/Info.plist` is excluded from `sources` in `project.yml` — don't remove that exclude.
- `InOutTests` is hosted (`TEST_HOST` / `BUNDLE_LOADER`) and uses `@testable import InOut`; `ENABLE_TESTABILITY` is Debug-only.
- The app/project was renamed to **InOut**, but `PRODUCT_BUNDLE_IDENTIFIER` stays `dev.local.aihot.hot` and the URL scheme stays `aihot://` **on purpose**: the bundle id keeps existing installs (收藏 / 练习本 / 对话 / Keychain 凭据) upgrading in place, and the scheme keeps shortcuts users already built working. Don't "tidy" either one without an explicit product decision. `AIHOTAPI` / `AIHOTDate` keep their names because they refer to the upstream aihot.news service, and all 「内容版权归 AIHOT」 attribution copy must stay verbatim.

### Coding conventions

- Comments and all UI copy are **Chinese**, matching the website's wording. Code identifiers and commit messages stay in the surrounding style.
- Decode every date with `JSONDecoder.aihot` / `AIHOTDate`. Foundation's built-in `.iso8601` strategy **rejects** the fractional seconds the API actually sends (`2026-10-12T01:40:20.000Z`) — that's the entire reason the custom strategy exists.
- **The encoders are asymmetric with the decoders**: `JSONEncoder.aihot` writes ISO8601 **without** fractional seconds, so any `Date` that round-trips through it (favorites, snapshots) comes back truncated to the whole second. Write round-trip assertions with second precision, and do **not** "fix" it by adding `.withFractionalSeconds` — that encoder is shared with the snapshot format.
- `@MainActor` types (`HotTopicsStore`, `FavoritesStore`, `StoryDetailModel`) cannot be touched from a nonisolated synchronous test method — that's a *compile error*, not a warning. Annotate the individual test methods `@MainActor` rather than the whole `XCTestCase` subclass, because marking the class also makes `setUp`/`tearDown` main-actor-isolated overrides of nonisolated superclass methods.
- All displayed times are Beijing time via `RelativeTime` (`Asia/Shanghai`, `zh_Hans_CN`), even if the device is elsewhere.
- API model fields stay `Optional` liberally (`Source.name`, etc.) so one malformed item can't blank the whole list on decode.
- `RegexUtil` exists so no regex library gets added; prefer it over pulling in a dependency.
- There is no networking in tests, and no fixtures are ever written back — the whole test suite is pure/offline.
- The mirror in `tools/logic_tests.py` also covers the SSE line splitter + frame reader + both protocol decoders (against `InOutTests/Fixtures/anthropic-sse.txt` / `openai-sse.txt`, the same bytes the Swift tests read — 镜像 6 asserts the byte path and the line path land on the same round), the tool-call accumulator, the AI base-URL normalisation, the news-context builder, the 报道节奏 bucketing (镜像 9, against `story-timeline.json`), the cross-turn history filter (镜像 10, `AIChatModel.history`), the failure wording (镜像 11, `AIChatModel.truncationNotice`), the chat-session cap (镜像 13, `ChatHistoryStore.trim` — evict direction pinned), the Tencent Cloud 元宝搜索 signature + response parsing (镜像 25, `TencentWSASignature` / `TencentWSAResponseParser` — mirrors `TencentWSATests`, reads `tencent-wsa-search.json` / `tencent-wsa-error.json`; the search fixture is derived from the official doc example, not a capture), and the chat-answer Markdown block splitting (镜像 16, `MarkdownBlocks.parse` — mirrors `MarkdownBlocksTests`, reads `chat-markdown.md`; the Swift file's header comment is the authoritative list of deliberate non-CommonMark deviations), and the leaderboard page parsing (镜像 17, `LeaderboardParser.parseBoard`/`parseDetail` — mirrors `LeaderboardParserTests`, reads the three `leaderboard-*.html` fixtures; see rule 18), the 周报/月报 period keys / range text / month grouping / entry→栏目归属 (镜像 18, `ReportPeriod.title`/`rangeText`/`groupByMonth` + `ReportEntry.kind` — mirrors `ReportPeriodTests` + the decoding assumptions of `ReportDecodingTests`, reads the four `report-*.json` fixtures; see rule 19), and the diagnostics address redaction + tab badge predicate (镜像 19, `DiagnosticReport.hostOnly` / `ReportUnread.isUnread` — mirrors `DiagnosticReportTests` / `ReportUnreadTests`; the redaction is a **security boundary**, because API base URLs may carry credentials in their query string), and the 周报/月报 item-page body parsing + item-id extraction (镜像 20, `ReportItemBody.parse` / `ReportItemID.id` — mirrors `ReportItemBodyTests`, reads the four `report-item-*.html` fixtures; see rule 19), the practice-book rules (镜像 23, `PracticeText.transferring` / `PracticeStatsCalculator` / `PracticeReviewPrompt` / `ReportItemBody.plainText(blocks:)` — mirrors `PracticeLogicTests`; no fixtures, these are pure text rules; see rule 20), and the external-link rules (镜像 24, `SharedLinkURL.normalized` / `firstURL` / `SharedLinkInput.parse` / `LinkTitleParser` incl. generic-title filtering and `msg_title` / legacy `Favorite` kind inference — mirrors `SavedLinkTests` / `FavoritesStoreTests`, reads `link-title.html`; see rule 21). That is the only pre-CI signal for the trickiest logic, so **run it before pushing**. What it cannot cover stays in Swift tests: the actual request bodies (Python can't build them), the tool round-trip shapes, the secret store (a fake backend), `ChatHistoryStore`'s disk IO (the mirror only covers the pure `trim`), and the `ReportItemDetailView` body-loading state machine (a `@State` + `.task` race can only be seen by tapping) — and what neither layer sees (taps landing, settings surviving a relaunch) is pinned by `InOutUITests`, so a red UI job is a real product bug, not flake, unless proven otherwise.
- Secrets never go in `@AppStorage`/`@AppStorage`-like paths: the API key lives in the Keychain (`AIChatSecretStore`), with a deliberate UserDefaults fallback **that the UI must disclose**. Two error codes to keep apart: `errSecItemNotFound (-25300)` means "nothing saved yet" (never a failure, and treating it as one writes an empty value on first launch), while something like `errSecMissingEntitlement (-34018)` is a real failure and triggers the fallback.

### Attribution constraints (product, not just legal)

Content is © AIHOT and its original sources; the terms allow personal non-commercial use only. The in-app source footer, the link back to aihot.news, and the original-article links are requirements, not decoration — don't remove them. `links.story` is an HTML URL for humans: only its last path segment may be used as a `publicId` to call `/api/v1/stories/{id}`, never the URL itself (`StoryID`, which also tolerates the legacy `aihot.virxact.com` host).
