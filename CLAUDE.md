# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An iOS (SwiftUI, min iOS 16) native app that re-renders the **热点榜** section of [aihot.news](https://aihot.news) — 10 rows, no browser. The 「主题」 section is explicitly out of scope. Zero third-party dependencies, zero entitlements (deliberate: the CI output is an *unsigned* IPA side-loaded via AltStore with a free Apple ID, so push/entitlements would break the whole distribution model).

Development happens on Windows; the build happens on GitHub Actions macOS runners. `README.md` is the user-facing doc (install steps, feature-by-feature官网/App mapping table, troubleshooting) — read it before answering "how do I install / why is X missing" questions.

## Commands

```bash
# Local, no Mac required (read-only, run before pushing):
python3 tools/preflight.py       # JSON / plist / path references / Python syntax / icon wiring
python3 tools/logic_tests.py     # Python mirror of the pure Swift logic, same fixtures
python3 tools/make_appicon.py    # generates AppIcon-1024.png (gitignored, CI does this too)

# On a Mac (or via the CI workflow):
brew install xcodegen && xcodegen generate     # AIHOT.xcodeproj is generated, never committed
xcodebuild test -project AIHOT.xcodeproj -scheme AIHOT \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Single test:
xcodebuild test -project AIHOT.xcodeproj -scheme AIHOT \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AIHOTTests/EnricherTests/testHeatIsFoundAfterALongDigest
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

A green `Build IPA` is **not** proof the product is right — the `info:` bug above produced green builds for weeks. Inspect the artifact: download `AIHOT-unsigned-ipa`, read `Payload/AIHOT.app/Info.plist`, and confirm `CFBundleVersion` equals the run number and the display-name / launch-screen / orientation keys are present. `AIHOT-adhoc-ipa` is usually absent by design (ad-hoc signing on `iphoneos` is not a supported combination; that step is `continue-on-error`).

## Architecture

**`RootView` is the top level**: it owns `@StateObject HotTopicsStore` **and** `@StateObject FavoritesStore`, wraps three tabs in a `TabView` (热点 / 收藏 / 设置), and passes both stores down **by constructor injection**. There is deliberately **no `EnvironmentObject` anywhere in this repo** — don't introduce one; sharing is `@StateObject` at the owner + `@ObservedObject` (or plain `let` for pass-through) below, or a `.shared` singleton for stateless services.

```
RootView (TabView: 热点 | 收藏 | 设置)
   ├── HotListView          ──> HotTopicsStore ──> AIHOTAPI ──> aihot.news (anonymous read-only)
   │                                │                  └── ETagStore (UserDefaults, survives relaunch)
   │                                ├── SnapshotCache  (Caches/hot-topics.json — cold start + offline)
   │                                ├── StoryCache     (Caches/stories.json — digests & report timelines)
   │                                └── HotPageEnricher <- HTMLTextExtractor <- GET /hot
   ├── FavoritesListView    ──> FavoritesStore (UserDefaults/aihot.favorites — USER DATA, not cache)
   └── AboutView (= 设置)    ──> both stores
        StoryDetailView (pushed from either tab) owns its own StoryDetailModel; the bookmark
        toggle there is the ONLY place a favorite is created.
```

Each tab's root view owns its own `NavigationStack` (`TabView` outside, one `NavigationStack` per tab — never the reverse).

**The 报道节奏 chart** is a pure-function + thin-view split, on purpose: `ReportTimeline.make(story:)` (Services) turns `Story.reports` into buckets/labels/axis ticks, `ReportTimelineChart` (a `Swift Charts` view, a system framework — no `project.yml` change needed) only draws the `Summary`. Everything except the drawing is covered by XCTest + the Python mirror; see rule 15.

**The AI chat layer** (feature: tap the bubble icon in `StoryDetailView`'s nav bar). The model can ask to call two tools — `web_search` and `read_url` — which the app executes against AnySearch and feeds back; it decides on its own whether to search. Almost all of the risky logic is pure and pinned by tests; the transport is the part nobody can exercise locally.

```
AIChatView (sheet) ──> AIChatModel (@MainActor: owns the bytes.lines loop,
                          │            runs the tool loop, clamps + feeds results back)
                          ├── AppSettings.currentAIChatConfig() ──> AIChatSecretStore (Keychain, 3 accounts)
                          ├── AIChatAPI ──> AIChatRequestBuilder (bodies/headers + tool round-trips)
                          │                    └── AIChatConfig (protocol, base URL, model)
                          └── AnySearchToolRunner ──> AnySearchAPI (JSON-RPC over /mcp)

pure & tested:  SSEParser (bytes→lines→frames + both decoders) · AIChatTool (call accumulator)
                AIChatNewsContext (prompt material) · AIChatConfig/AIChatRequestBuilder
                AIChatModel.history (跨轮历史：空消息剔除 + 纯追加)
                AIChatModel.truncationNotice (一轮什么都没认出来时说哪句话)
```

### Rules that will bite you if you don't know them

**1. The upstream request contract is non-negotiable.** aihot.news publishes a `s-maxage` of 60s and the code honors it unconditionally: `HotTopicsStore.refresh()` throttles to 60s (5s only while `items.isEmpty`, so first launch and retry still work), and 429/503 `Retry-After` is stored in `nextAllowedAt` so *no* request is sent before it expires, with no parallel retries. Digest fetches are strictly serial for the same reason. There is deliberately no `force:` parameter on `refresh()` — don't add one.

**2. ETags persist, body caches do not — this asymmetry causes a whole bug class.** `ETagStore` lives in UserDefaults (survives everything); `SnapshotCache`/`StoryCache` live in the Caches directory (the system can purge them). A bare `304` therefore does *not* mean "I have the content". Every 304 path must fall back to the disk cache and, when that's empty, re-fetch with `ignoreCache: true`:
- `HotTopicsStore.performFetch()` → `.notModified` with empty `items` → `performFetchIgnoringETag()`
- `refreshDigests()` / `fetchStoryIgnoringCache(id:)`

Symptom if you get this wrong: "detail page loses its report timeline on second open", "big cards lose their body text after relaunch" — broken but not crashing, so tests won't catch it.

**3. Enrichment is all-or-nothing, and it never invents numbers.** The public API returns no 热度指数 / 涨跌 / 爆·新 badges / avatars. `HotPageEnricher` scrapes them out of `/hot` text, but only anchored on literal 文案 like 「热度指数」, and any failure returns `nil` so the UI silently falls back to API fields (source count / participant count). Existing titles are stripped from the text first so 「新」/「爆」 inside a title can't be misread as a badge. When tweaking regexes, the guiding principle in the source is *宁可少抽，不可抽错*. CSS class names are intentionally not used — only visible copy — so a Tailwind reshuffle doesn't break it.

**4. The Python logic tests are a mirror, not an authority.** `tools/logic_tests.py` re-implements the same parsing / `StoryID` / `RelativeTime` logic and runs against the *same* `AIHOTTests/Fixtures/*` files as the XCTest suite. It exists because the trickiest code (regex + window logic) is invisible to the compiler and this runs in milliseconds without a simulator. **If you change the Swift logic, mirror the change there or the mirror silently diverges.** Assertions must be derived from the fixture contents, not from reasoning about what the value "should" be.

   It also **cannot validate the Swift string literals themselves**, and that blind spot is not theoretical: `HTMLTextExtractor.stripElement` had its closing tag written `"</\\(tag)>"` (doubled backslash) instead of `"</\(tag)>"`. At runtime that pattern became `</` + `\s` + `cript>`, matched nothing, and silently left every `<script>`/`<style>` body in the extracted text — while the Python mirror, which uses the correct `</%s>`, stayed 74/74 green. When Swift and the mirror disagree, **Swift is the authority**; the mirror is either wrong or blind. Regexes here are dense (`"<\(tag)\\b..."` legitimately mixes a one-backslash interpolation with a two-backslash `\b`), so read the bytes (`sed -n 'Np' file | od -c`) rather than trusting the eye.

**5. `Fixture.url()` calls `XCTFail` when a fixture is missing** rather than skipping. Keep it that way — a skipped test is a false green.

**6. Favorites are user data, not cache.** `FavoritesStore` persists to `UserDefaults` (`AppSettings.favoritesKey` = `aihot.favorites`), never to the Caches directory — Caches gets purged and losing a user's saved list is a bug. Two consequences that must not regress: `HotTopicsStore.clearCache()` (labelled 清除本地缓存) clears only Caches + ETags + in-memory dicts and **must never touch favorites**; and favorites have **no cap** (unlike `StoryCache.maximumEntries = 300`) — silently dropping user data is worse than unbounded growth. Encoding failure must leave the previous blob intact rather than writing an empty array.

**7. A favorite is a snapshot, so its `rank` is stale — never use it to look anything up.** `HotTopicsStore.enrichmentInfo(for:)` resolves **by rank**, so passing a favorited topic straight in would show whatever is currently at that rank — someone else's 热度指数. The 收藏 row may only show a live number after matching the favorite's `id` against the current list and using *that* item's rank (see `FavoritesListView.liveHeatInfo`); when the id is no longer listed, fall back to the snapshot's source/participant counts. Favorite rows also deliberately show no rank at all. This is the 「不编造数字」 rule applied to a stale snapshot.

**8. Order favorites by array position, not by sorting.** `FavoritesStore.items` is maintained newest-first by insertion, and `load()` returns the stored order untouched. Don't "simplify" it to `sorted(by: favoritedAt)` — Swift's `sort` is not stable, so two favorites saved in the same second would swap places on every relaunch. `FavoritesStoreTests.testOrderSurvivesReloadWhenTimestampsTie` pins this.

**9. The AI client must NOT reuse `AIHOTAPI`'s session, and must keep `Accept-Encoding: identity`.** `AIHOTAPI`'s session is 15s idle / 30s total, sized for one-shot JSON. A thinking, web-searching chat turn easily exceeds 30s, so reusing it kills every request in a way that looks like "the API is broken". `AIChatAPI` builds its own configuration (90s idle / 600s resource). The explicit `identity` encoding matters for a second reason: URLSession otherwise asks for gzip and decompresses transparently, and that buffering layer is the classic cause of "the SSE doesn't stream, it all arrives at the end".

**10. Two protocols, two implementations — never one wrapped in the other.** Anthropic (`/v1/messages`) and OpenAI-compatible (`/chat/completions`) have genuinely different wire formats, and **tool use is where they diverge most**: Anthropic wants `tool_use` / `tool_result` content blocks with matching ids, OpenAI-compatible wants `tool_calls` on the assistant message plus separate `role: "tool"` messages whose `function.arguments` is the **raw JSON string** (not an object). The Anthropic side must follow Anthropic's own shapes; do **not** route Claude through an OpenAI-compatible shim. All of it lives in `AIChatRequestBuilder` plus the two decoders, as named constants and small pure builders with comments, because none of it can be exercised locally. `AIChatRequestBuilder.enableRefusalFallbacks` remains the documented one-line escape hatch (see README §4/§7).

**11. The news material goes in the FIRST USER MESSAGE, never only in `system`.** Two reasons: the model can only hand `read_url` a URL it has actually **seen**, so the original-article link has to be in a message (not just in `system`); and keeping it in the first user turn keeps `system`/`tools` byte-stable and `messages` append-only, so the cached prefix survives the whole conversation. `AIChatNewsContext` also uses **absolute** times only — `RelativeTime.relative` ("3 小时前") changes every turn and would break that prefix.

**12. Tool blocks live inside ONE turn; history stays text-only.** A turn may contain several tool round-trips and those are echoed in full (Anthropic: `tool_use` + a matching `tool_result`; OpenAI: `tool_calls` + `role:"tool"`). But once the turn ends, only the assistant's **text** is kept and the next turn sends text-only history. This is load-bearing, not laziness: the preserved-thinking history check only validates `thinking` blocks you actually replay, so replaying none keeps the feature outside that check's blast radius — and the tool blocks we do echo are ones **we** assembled from the stream (`AIChatToolCallAccumulator`), so they cannot carry a mismatched signature. `testAnthropicHistoryIsTextOnlyAndCarriesContextInFirstUserTurn` pins the history shape; the two round-trip shapes have their own tests. A turn is capped at 5 tool rounds (`AIChatModel.maximumToolRounds`) — every round costs money.

**13. AnySearch: JSON-RPC, optional auth, and two failure shapes that look nothing alike.** `POST https://api.anysearch.com/mcp`, method `tools/call`, tools `search` / `extract`. The response is **plain JSON, not SSE** — `result.content[0].text`. The `Authorization: Bearer` header is **optional** (anonymous works, lower rate limits), which is why the settings UI says "clear the field to go back to anonymous".

Failure comes back in **two** shapes and only checking one of them shipped a silent bug:
- **Invalid key / the tool itself failing: HTTP is still `200`.** There is *no* top-level `error`; the failure is `result.isError == true` and the reason is in `result.content[0].text` (a bad key returns exactly `{"result":{"content":[{"text":"invalid_api_key\nInvalid API key."}],"isError":true}}`). `resultText` **must** check `isError` — without it the string `invalid_api_key / Invalid API key.` was handed to the model as a *successful* search result, the carefully-worded "Key 无效或已停用" message in the 401/403 branch never appeared, and the user just saw the model flounder. The 401/403 branch is now only a fallback; nothing observed actually goes through it.
- Protocol-level errors (bad params): top-level `error.message`.

The old test used a **hand-written** `{"error":{"message":"Invalid API key"}}` payload — a shape the server never sends — which is exactly why the bug stayed green. Pin the parser against the **real captured bytes** (`AIHOTTests/Fixtures/anysearch-search.json` for success, `anysearch-error.json` for the bad-key shape); when a fixture is a guess rather than a capture, say so.

`search` and `extract` do **not** return the same kind of text: `search` gives model-ready Markdown (title + URL + summary) that goes back as a `tool_result` unparsed, but `extract` gives a **JSON document string** (`{"url":…,"title":…,"content":"…"}`, newlines escaped) which currently also goes back unparsed (the model copes; unwrapping it would be the optimisation). Results are clamped before going to the model (`AIChatToolResult.maximumCharacters`, 8000) because `extract` can return 50k characters from one page.

**14. 原文走系统阅读器，且**必须**配一个逃生口 —— 不要为它引入 WKWebView.** `SFSafariViewController` 是唯一实现：`SafariView.entersReader`（默认 `false`）映射到 `Configuration.entersReaderIfAvailable`。它是*尽力而为*——页面自己支持阅读器才进得去，不支持就照常显示，所以打开它不会比关掉更差；真正的风险是**支持阅读器但抽得不好**的页面，而 SFSafariViewController 里能不能退出阅读器不由我们决定。所以详情页「打开原文」旁边那个「网页版」按钮不是装饰，是唯一的回退路径，删掉它就把用户困住了。WKWebView **完全做不到**阅读器模式，换成它只会丢掉功能、还要自己接分享/返回，别再提这条路。哪个入口进阅读器由调用方决定：`WebLinkSheet(url:entersReader:)` 里的 `entersReader`，同一个链接的两种打开方式靠 `id` 上的 `#reader` 后缀区分（否则 SwiftUI 认为「还是那一个」，点「网页版」不会重新弹）。aihot.news 是网页应用、没有正文，那个入口永远走网页。

**15. 报道节奏图的一切数字都出自纯函数 `ReportTimeline`，它是被镜像的那类逻辑.** `ReportTimeline.make(story:)` 不读 `Date()`（窗口由数据自己的最早/最新一条决定），所以同一条 story 永远得到同样的图，能被夹具钉住。`ReportTimelineChart` 只负责把 `Summary` 画出来，**不允许**在里面分桶、算刻度或改标签。三条不变量：桶按**北京时间**对齐（与 `RelativeTime` 同一口径，否则「哪一天」会按 UTC 切）；`count == 0` 的空桶要留着（断档本身就是结论）；**桶数 ≤ 24**——x 轴是按标签分类的轴，重名会被合并成一根柱子，而 ≤ 24 恰好保证标签不可能重复。轴刻度只能整数除法 `i * (n - 1) / 4`，**绝不能引入 `round()`**：Python 是银行家舍入、Swift 是四舍五入，`n = 25` 时两边会挑出不同的刻度。改这里就要同步改 `tools/logic_tests.py` 的「镜像 9」，两边读同一份夹具 `AIHOTTests/Fixtures/story-timeline.json`（`story.json` 只有 1 条报道、且被 `len(reports) == 1` 钉着，不能拿来用）。

**16. 「连接提前中断，回复可能不完整」只留给「真有正文、只是收尾标记没来」，别把它当成万能兜底.** 这句话原来被四种完全不同的故障共用：协议与地址不配套（另一条协议的流被本协议的解码器读到，一个事件都认不出来）、服务端回了非 SSE 的东西却谎报 `Content-Type: text/event-stream`、一帧都没收到、以及只收到思考块就断了。前三种与「连接中断」毫无关系，用户照着一句话什么都查不出来 —— 侧载的 App 挂不上调试器，**界面上那行字就是唯一的诊断信号**，所以 `AIChatModel.consume` 会把「切了几帧、认出几个事件、前 5 段认不出来的原文」记进 `StreamedRound`，由纯函数 `AIChatModel.truncationNotice` 分情况说话：拿**另一条协议的解码器**认出样本时直接点名该换哪条协议（这是最值钱的一条，`AIChatModelTests` 用两份 SSE 夹具双向钉住），否则把接口真正发来的**帧数**和头尾两段原文贴出来。**帧数不能省**：流的第一帧（OpenAI 的 `role` 分片、Anthropic 的 `message_start`）按协议本来就不产出事件、必然落在样本里，所以只贴开头等于什么都没说 —— 「共切出 1 帧」和「共切出 40 帧」是两种完全不同的故障。新增失败分支时把话说清楚、并把原文带上，不要退回一句兜底；`tools/logic_tests.py` 的「镜像 11」与 Swift 用例读同一份夹具。

**17. SSE 的行由 `SSELineSplitter` 自己切，**绝不**改用 `bytes.lines`.** 空行是 SSE 分帧的**唯一**依据 —— `SSEFrameReader` 只有见到空行才交出一帧 —— 而 `AsyncSequence.lines` 怎么处理行尾不在我们手里（它把 CR、NEL、LS、PS 都当行尾，空行留不留是实现细节）。空行一旦在路上被吞掉，整条流会被拼成**一帧**：拼起来的 JSON 解不出来 → 每个事件都认不出来 → 真机上就是「没有任何回复」加一句看不懂的提示，而**全部夹具用例仍然全绿** —— 因为它们都是自己按 `\n` 切好行再喂给分帧器的，恰好绕开了出事的那一段（与规则 4 里 `stripElement` 那个盲点同一类问题：本地能测的那半段永远是对的）。所以 `AIChatModel.consume` 现在是 `for try await byte in bytes` + `SSELineSplitter`（只认 LF，`\r` 仍旧由分帧器剥）。`SSEParserTests` 两头都钉住：逐字节的 `SSELineSplitter` 用例、以及「夹具的**字节**走一遍 == 按行喂一遍」的端到端用例（`testFixtureBytesProduceTheSameRoundAsItsLines`）；改这里时同步 `tools/logic_tests.py` 的 `ByteLineSplitter` 与镜像 6 的断言（两份夹具都跑）。

### Project file conventions

- **Never add `info:` to a target in `project.yml`.** XcodeGen's `info.path` means "generate a plist *at* this path", not "use this file as the base". With it set, XcodeGen overwrites `AIHOT/Info.plist` with its own defaults and every hand-written key is lost — that silently shipped an app named `AIHOT` instead of `AI 热点榜`, with no `UILaunchScreen` (letterboxed on modern iPhones), rotatable to landscape, and with `CFBundleVersion` frozen at `1` so AltStore could never detect an update. The target sets `INFOPLIST_FILE: AIHOT/Info.plist` in `settings` instead, which is why the committed plist is the real one and why `preflight`'s check of it is meaningful. `CFBundleVersion` must stay `$(CURRENT_PROJECT_VERSION)` so the CI run-number override lands.
- `AIHOT.xcodeproj` is generated by XcodeGen and gitignored. **Never edit it.** `project.yml`'s `sources: - path: AIHOT` is a directory, so new `.swift` files under `AIHOT/` are picked up automatically with no project edit.
- Where to change what: display name → `AIHOT/Info.plist` `CFBundleDisplayName`; bundle id / `MARKETING_VERSION` → `project.yml`; colors, spacing, fonts → `AIHOT/Design/Theme.swift` (`Theme` / `Metrics` / `Typography` are the only place these belong).
- `AIHOT/Info.plist` is excluded from `sources` in `project.yml` — don't remove that exclude.
- `AIHOTTests` is hosted (`TEST_HOST` / `BUNDLE_LOADER`) and uses `@testable import AIHOT`; `ENABLE_TESTABILITY` is Debug-only.

### Coding conventions

- Comments and all UI copy are **Chinese**, matching the website's wording. Code identifiers and commit messages stay in the surrounding style.
- Decode every date with `JSONDecoder.aihot` / `AIHOTDate`. Foundation's built-in `.iso8601` strategy **rejects** the fractional seconds the API actually sends (`2026-10-12T01:40:20.000Z`) — that's the entire reason the custom strategy exists.
- **The encoders are asymmetric with the decoders**: `JSONEncoder.aihot` writes ISO8601 **without** fractional seconds, so any `Date` that round-trips through it (favorites, snapshots) comes back truncated to the whole second. Write round-trip assertions with second precision, and do **not** "fix" it by adding `.withFractionalSeconds` — that encoder is shared with the snapshot format.
- `@MainActor` types (`HotTopicsStore`, `FavoritesStore`, `StoryDetailModel`) cannot be touched from a nonisolated synchronous test method — that's a *compile error*, not a warning. Annotate the individual test methods `@MainActor` rather than the whole `XCTestCase` subclass, because marking the class also makes `setUp`/`tearDown` main-actor-isolated overrides of nonisolated superclass methods.
- All displayed times are Beijing time via `RelativeTime` (`Asia/Shanghai`, `zh_Hans_CN`), even if the device is elsewhere.
- API model fields stay `Optional` liberally (`Source.name`, etc.) so one malformed item can't blank the whole list on decode.
- `RegexUtil` exists so no regex library gets added; prefer it over pulling in a dependency.
- There is no networking in tests, and no fixtures are ever written back — the whole test suite is pure/offline.
- The mirror in `tools/logic_tests.py` also covers the SSE line splitter + frame reader + both protocol decoders (against `AIHOTTests/Fixtures/anthropic-sse.txt` / `openai-sse.txt`, the same bytes the Swift tests read — 镜像 6 asserts the byte path and the line path land on the same round), the tool-call accumulator, the AnySearch response parsing (against `anysearch-search.json`), the AI base-URL normalisation, the news-context builder, the 报道节奏 bucketing (镜像 9, against `story-timeline.json`), the cross-turn history filter (镜像 10, `AIChatModel.history`), and the failure wording (镜像 11, `AIChatModel.truncationNotice`). That is the only pre-CI signal for the trickiest logic, so **run it before pushing**. What it cannot cover stays in Swift tests: the actual request bodies (Python can't build them), the tool round-trip shapes, and the secret store (a fake backend).
- Secrets never go in `@AppStorage`/`@AppStorage`-like paths: the API key lives in the Keychain (`AIChatSecretStore`), with a deliberate UserDefaults fallback **that the UI must disclose**. Two error codes to keep apart: `errSecItemNotFound (-25300)` means "nothing saved yet" (never a failure, and treating it as one writes an empty value on first launch), while something like `errSecMissingEntitlement (-34018)` is a real failure and triggers the fallback.

### Attribution constraints (product, not just legal)

Content is © AIHOT and its original sources; the terms allow personal non-commercial use only. The in-app source footer, the link back to aihot.news, and the original-article links are requirements, not decoration — don't remove them. `links.story` is an HTML URL for humans: only its last path segment may be used as a `publicId` to call `/api/v1/stories/{id}`, never the URL itself (`StoryID`, which also tolerates the legacy `aihot.virxact.com` host).
