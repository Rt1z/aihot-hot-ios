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
| 左侧导航 + 顶栏 + 底部 tab（精选/日报/模型榜/我的） | 去掉，只留导航栏大标题「AI 热点榜」+ 右上「关于」 |
| 榜单头：过去 48 小时… · 更新时间 · 实时热度 · 怎么算 | 标题下两行说明，「怎么算」按钮在应用内打开官网该页 |
| NO.01–03 大卡（序号/爆新徽章/涨跌/标题/正文/头像行/热度指数） | 3 张全宽卡；正文取 story digest（与官网同源），4 行截断 |
| 头像行「+10 邵猛、Oran Ge 等 7 个来源·16 位参与者」 | 字母头像栈（来源名哈希取色）+「N 个来源 · M 位参与者」 |
| 热度指数大数字 | 有就显示真实热度指数，没有就显示参与者数（**不编造数字**） |
| 「10月12日 10:35 更新」 | 优先用页面文本里的真实时间，取不到就显示「刷新于 …」 |
| NO.04–10 紧凑列表 | 一张卡片内的紧凑行：序号 + 标题 + 摘要 + 指标 |
| 24 小时走势图 | 不做（公开接口没有这项数据） |
| /story/xxx 详情页 | 原生详情页：AI 摘要分段 + 报道时间线（来源/时间/摘要/原文） |
| 原文链接 | 应用内 `SFSafariViewController` 打开 |

配色 token 全部集中在 `AIHOT/Design/Theme.swift`（近黑底 + 热度橙，深浅色跟随系统），想改风格只改这一个文件。

---

## 3. 数据来源与接口约定

全部数据来自 AIHOT 的**匿名只读公开接口**，无需注册、无需 Key：

| 用途 | 接口 |
| --- | --- |
| 榜单 10 条 | `GET /api/v1/hot-topics` |
| 详情（AI 摘要 + 报道时间线） | `GET /api/v1/stories/{publicId}` |
| 热度指数/涨跌/爆新（可选补全） | `GET /hot` 页面文本解析 |

代码里遵守了对方写明的要求：

- 刷新**不快于 60s**（接口的 `s-maxage`），带 `If-None-Match`，未变化时是 304 空体；
  **下拉刷新也一样**：60 秒内的重复下拉不会重新发请求（本地完全没数据时才放宽到 5 秒，保证首屏和重试可用）；
- 429 / 503 读 `Retry-After`，**在它到期前不再发任何请求**，也不并行重试；
- `links.story` 是**给人看的 HTML 地址**，只取末段当 publicId，再请求 `/api/v1/stories/{id}`；旧域名 `aihot.virxact.com` 也照样解析（见 `StoryIDTests`）；
- 未实现推送（对方明确没有 SSE / webhook）。

本地缓存分两层，都是为了「304 时也有内容可展示」：

- **榜单快照**（`SnapshotCache`）→ 冷启动秒开、离线可看；
- **故事正文**（`StoryCache`）→ 详情页正文与报道时间线落盘。没有这一层的话，ETag 跨启动保留而正文只在内存里，会变成「重启后大卡没有正文段落」「同一故事第二次打开没有时间线」这类不崩但错的问题。

### 关于「热度指数」这件事

公开接口**不返回**热度指数、涨跌（↑629%/持平/↓16%）、爆/新徽章、24 小时走势，也不返回头像图片（站内图片走带签名的 `/api/img-proxy`，既不能自己构造也不能长期盗链）。所以：

- **默认**开启「从网页补全热度指数」：额外拉一次 `/hot`，把 HTML 压成纯文本，只认「热度指数」这个文案锚点，只解析前三条；
- 解析失败、或者哪天官网改版 —— 会**整块丢弃**，界面退回接口字段（来源数 / 参与者数），**不会显示错误的数字**；
- 标题会先从文本里剔除，避免标题里的「新」「爆」被误判成徽章；
- 可在 App 的「关于 → 数据」里关掉这项增强。

---

## 4. 目录结构

```
project.yml                 XcodeGen 工程定义（改包名/显示名/版本只改这里）
.github/workflows/ios.yml   云编译：跑单测 + 出两个 IPA + 上传 artifact
tools/make_appicon.py       现场生成 1024 图标（有 Pillow 用 Pillow，没有用标准库）
tools/preflight.py          构建前自检：JSON / plist / 路径引用 / Python 语法
tools/logic_tests.py        纯逻辑镜像测试：用 Python 把解析/ID/时间逻辑跑一遍
                            （和 Swift 单测读同一份夹具，CI 里先于编译执行）
AIHOT/
  Info.plist
  RootView.swift            @main + 外观（跟随系统/深色/浅色）
  Design/                   Theme.swift（色板）、Components.swift（徽章/头像/骨架屏…）
  Models/                   HotTopics.swift、Story.swift（字段与接口一一对应）
  Services/                 AIHOTAPI（ETag/退避）、HotTopicsStore（节流/离线/补全）、
                            SnapshotCache（榜单快照）、StoryCache（故事正文落盘）、
                            StoryID、AppSettings、
                            HTMLTextExtractor + HotPageEnricher（网页文本增强）
  Features/Hot/             榜单页、大卡、紧凑行、RelativeTime
  Features/Story/           详情页（AI 摘要 + 时间线）
  Features/About/           关于/设置/署名
AIHOTTests/                 夹具驱动的纯逻辑测试（解码/时间/ID解析/网页解析）
```

## 5. 改点什么

| 想改 | 改哪里 |
| --- | --- |
| App 显示名 | `AIHOT/Info.plist` 的 `CFBundleDisplayName` |
| 包名（bundle id） | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`（免费账号下只要全局唯一即可） |
| 版本号 | `project.yml` → `MARKETING_VERSION`；build 号由 CI 用 run number 自动递增，AltStore 才能识别为更新 |
| 配色/字号 | `AIHOT/Design/Theme.swift` |
| 图标 | 换掉 `tools/make_appicon.py` 的画法，或自己放一张 1024×1024 PNG 到 `AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` |

> 有 Mac 的话：`brew install xcodegen && python3 tools/make_appicon.py && xcodegen generate && open AIHOT.xcodeproj`，就能在 Xcode 里跑。

## 6. 出问题先看这里

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
| App 7 天后打不开 | 免费证书过期，AltServer 开着 + 同 Wi-Fi 让 AltStore 自动续签，或手动 Refresh |
| 热度指数/涨跌不显示 | 页面文本解析没命中（官网改版了）。功能不受影响；进 App「关于 → 排查 → 复制诊断信息」，把内容发出来即可修 |

## 7. 许可与署名

- 内容版权归 **AIHOT（北京虚实空际文化科技有限公司）及各原始来源**所有。App 内固定显示「数据来源：AIHOT」并链回官网，保留原始链接。
- AIHOT 条款允许**个人非商业**使用；本 App 仅供自己使用，**请勿公开分发 IPA、不要做公开镜像或商业用途**。
- 本项目不含任何 AIHOT 的代码或数据文件，全部数据在运行时从公开接口获取。

## 8. 验收清单

- [ ] Actions 绿，拿到 IPA
- [ ] AltStore 装成功，图标出现在桌面并能打开
- [ ] 榜单 10 条的顺序与标题和官网 `/hot` 一致
- [ ] 点一条进详情，AI 摘要与官网 `/story/xxx` 一致，报道时间线正常
- [ ] 飞行模式重开 App：显示缓存 + 离线横幅，不白屏
- [ ] 深色/浅色切换正常，大字号下不破版
- [ ] 原文按钮在应用内打开
