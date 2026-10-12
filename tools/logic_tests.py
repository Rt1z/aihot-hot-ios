#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
纯逻辑镜像测试：用 Python 把 App 里那几段「纯函数」逻辑原样重写一遍，
拿**同一份夹具**跑一遍断言。

为什么需要它：本项目最难验证的部分是「把 /hot 页面文本解析出热度指数/涨跌/徽章」
以及 story id 解析 —— 这些是正则和窗口逻辑，编译器查不出对错。Xcode 单测在
模拟器里跑，环境因素多；这个脚本在 macOS runner 上用 Python 直接执行，几十毫秒
出结果，而且能在推送前就告诉你「模式和夹具到底匹配不匹配」。

注意：这是**镜像**，不是权威实现。权威实现是 Swift 那几份文件；两边不一致时
以 Swift 为准，然后回来修这里。断言值全部来自夹具本身，不复制我的人工推演。

用法：python3 tools/logic_tests.py
"""

import datetime
import json
import os
import re
import sys
from urllib.parse import urlsplit

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 与 Swift 保持一致的可调参数（HotPageEnricher）
BADGE_LINE_LIMIT = 40
BEIJING = datetime.timezone(datetime.timedelta(hours=8))

_passed = 0
_failed = []


def check(condition, label):
    global _passed
    if condition:
        _passed += 1
    else:
        _failed.append(label)


def check_eq(actual, expected, label):
    check(actual == expected, "%s（实际 %r，期望 %r）" % (label, actual, expected))


# --------------------------------------------------------------------------
# 镜像 1：HTMLTextExtractor
# --------------------------------------------------------------------------

BLOCK_TAG_CLOSERS = (
    "br|/p|/div|/li|/ul|/ol|/dl|/dd|/h[1-6]|/section|/article|/header|/footer"
    "|/tr|/td|/th|/table|/main|/nav|/aside|/head|/title|/body|/html|/figure"
    "|/figcaption|/blockquote|/pre|/form|/time"
)

NAMED_ENTITIES = {
    "&nbsp;": " ",
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": '"',
    "&#39;": "'",
    "&apos;": "'",
    "&middot;": "·",
    "&hellip;": "…",
    "&mdash;": "—",
    "&ndash;": "–",
    "&times;": "×",
    "&laquo;": "«",
    "&raquo;": "»",
}


def strip_element(html, tag):
    return re.sub(
        r"<%s\b[^>]*>.*?</%s>" % (tag, tag),
        "\n",
        html,
        flags=re.IGNORECASE | re.DOTALL,
    )


def decode_entities(text):
    # 先解数字实体（对应 Swift 的倒序替换）
    def numeric(match):
        digits = match.group(2)
        value = int(digits, 16) if match.group(1) else int(digits, 10)
        try:
            return chr(value)
        except (ValueError, OverflowError):
            return match.group(0)

    text = re.sub(r"&#(x?)([0-9A-Fa-f]+);", numeric, text)
    for entity, replacement in NAMED_ENTITIES.items():
        text = text.replace(entity, replacement)
    return text


def plain_text(html):
    text = html
    for tag in ("script", "style", "noscript", "svg", "template"):
        text = strip_element(text, tag)
    text = re.sub(r"<!--.*?-->", "\n", text, flags=re.DOTALL)
    # 与 Swift 一致：源码里的换行/缩进只是排版，不是语义换行，
    # 先整体折叠成单个空格，之后只由块级标签决定断行。
    # 少了这一步，<span>爆</span> 与 <span>↑ 629%</span> 之间的换行
    # 会把徽章拆到两行，涨跌整块丢失。
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"<(%s)[^>]*>" % BLOCK_TAG_CLOSERS, "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]*>", " ", text)
    text = decode_entities(text)
    lines = [line.strip() for line in text.splitlines()]
    return "\n".join(line for line in lines if line)


# --------------------------------------------------------------------------
# 镜像 2：HotPageEnricher
# --------------------------------------------------------------------------


def parse_updated_text(text):
    match = re.search(r"([0-9]{1,2}月[0-9]{1,2}日\s*[0-9]{1,2}:[0-9]{2})\s*更新", text)
    return match.group(1).strip() if match else None


def parse_heat(block):
    # 热度数字排在卡片最后（标题 → 正文 → 来源行 → 数字 → 热度指数），
    # 离序号可能有几百字，所以**不设距离窗口**：块的边界由下一个序号界定，
    # 块内取**最后一处**匹配。
    matches = list(re.finditer(r"([0-9][0-9,]{0,6})\s*[\r\n\s]*热度指数", block))
    if not matches:
        return None
    return int(matches[-1].group(1).replace(",", ""))


def parse_badges(block):
    lines = [line.strip() for line in block.splitlines()]
    first_line = next((line for line in lines if line), "")
    head = first_line[:BADGE_LINE_LIMIT]
    if not head:
        return None, False, False

    delta = None
    delta_location = None

    up = re.search(r"↑\s*([0-9]{1,4})\s*%", head)
    if up:
        delta = ("up", int(up.group(1)))
        delta_location = up.start()

    down = re.search(r"↓\s*([0-9]{1,4})\s*%", head)
    if down and (delta_location is None or down.start() < delta_location):
        delta = ("down", int(down.group(1)))
        delta_location = down.start()

    flat = re.search(r"持平", head)
    if flat and (delta_location is None or flat.start() < delta_location):
        delta = ("flat", None)

    is_breakout = re.search(r"爆", head) is not None
    is_new = re.search(r"新上榜", head) is not None or re.search(r"(^|[^最])新($|[^上])", head) is not None
    return delta, is_breakout, is_new


def parse_rank_infos(text):
    # 与 Swift 一致：抓两位数字，NO.10 不能被读成 NO.01
    markers = list(re.finditer(r"NO\.?\s*0?([0-9]{1,2})(?![0-9])", text))
    best = {}
    for index, marker in enumerate(markers):
        rank = int(marker.group(1))
        if rank > 3:
            continue
        block_start = marker.end()
        if index + 1 < len(markers):
            block_end = markers[index + 1].start()
        else:
            block_end = min(len(text), block_start + 4000)
        if block_end <= block_start:
            continue
        block = text[block_start:block_end]

        heat = parse_heat(block)
        delta, is_breakout, is_new = parse_badges(block)
        info = {"rank": rank, "heat": heat, "delta": delta, "is_breakout": is_breakout, "is_new": is_new}

        existing = best.get(rank)
        if existing is None:
            best[rank] = info
        else:
            score_new = (1 if heat is not None else 0) + (1 if delta is not None else 0)
            score_old = (1 if existing["heat"] is not None else 0) + (1 if existing["delta"] is not None else 0)
            if score_new > score_old:
                best[rank] = info
    return best


def parse_page(text, excluding_titles=()):
    body = text
    for title in excluding_titles:
        if len(title) >= 6:
            body = body.replace(title, "\n")
    updated = parse_updated_text(body)
    ranks = parse_rank_infos(body)
    if updated is None and not ranks:
        return None
    return {"updated": updated, "ranks": ranks}


# --------------------------------------------------------------------------
# 镜像 3：StoryID
# --------------------------------------------------------------------------


def public_id(link):
    if not link:
        return None
    segments = [segment for segment in urlsplit(link).path.split("/") if segment]
    if not segments:
        return None
    candidate = segments[-1].strip()
    if len(candidate) < 8 or candidate.lower() == "story":
        return None
    if not re.fullmatch(r"[0-9A-Za-z._-]+", candidate):
        return None
    return candidate


# --------------------------------------------------------------------------
# 镜像 4：RelativeTime（北京时间）
# --------------------------------------------------------------------------


def parse_iso(value):
    tz = datetime.timezone.utc
    if "." in value:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=tz)
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=tz)


def relative_time(when, now):
    seconds = (now - when).total_seconds()
    if seconds < 60:
        return "刚刚"
    if seconds < 3600:
        return "%d 分钟前" % int(seconds // 60)
    if seconds < 86400:
        return "%d 小时前" % int(seconds // 3600)
    if seconds < 86400 * 30:
        return "%d 天前" % int(seconds // 86400)
    local = when.astimezone(BEIJING)
    if local.year == now.astimezone(BEIJING).year:
        return "%d月%d日" % (local.month, local.day)
    return "%d年%d月%d日" % (local.year, local.month, local.day)


def absolute_short(when):
    local = when.astimezone(BEIJING)
    return "%d月%d日 %02d:%02d" % (local.month, local.day, local.hour, local.minute)


# --------------------------------------------------------------------------
# 镜像 6：SSE 分帧 + 两家协议的解码
# --------------------------------------------------------------------------


def split_field(line):
    if ":" not in line:
        return line, ""
    field, _, value = line.partition(":")
    if value.startswith(" "):
        value = value[1:]  # 规范：最多剥掉一个前导空格
    return field, value


class FrameReader:
    """与 Swift 的 SSEFrameReader 一一对应。"""

    def __init__(self):
        self.event = None
        self.data = []

    def consume(self, raw_line):
        line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
        if line == "":
            return self.flush()
        if line.startswith(":"):
            return None  # 注释/心跳
        field, value = split_field(line)
        if field == "event":
            self.event = value
        elif field == "data":
            self.data.append(value)
        return None

    def flush(self):
        if not self.data and self.event is None:
            return None
        frame = {"event": self.event, "data": "\n".join(self.data)}
        self.event = None
        self.data = []
        return frame


def anthropic_events(frame):
    """与 AnthropicSSEDecoder.decode 对应：**一帧可能产出多个事件**。"""
    if frame is None:
        return []
    try:
        payload = json.loads(frame["data"])
    except ValueError:
        return []

    kind = payload.get("type")
    if kind == "content_block_delta":
        delta = payload.get("delta") or {}
        dtype = delta.get("type")
        if dtype == "text_delta":
            text = delta.get("text") or ""
            return [("text", text)] if text else []
        if dtype == "thinking_delta":
            return [("thinking", None)]
        if dtype == "input_json_delta":
            index = payload.get("index")
            fragment = delta.get("partial_json") or ""
            if index is None or not fragment:
                return []
            return [("tool_args", (index, fragment))]
        return []  # signature_delta / citations_delta
    if kind == "content_block_start":
        block = payload.get("content_block") or {}
        index = payload.get("index")
        if block.get("type") == "tool_use" and index is not None:
            return [("tool_started", (index, block.get("id"), block.get("name")))]
        return []
    if kind == "message_delta":
        reason = (payload.get("delta") or {}).get("stop_reason")
        return [("stop_reason", reason)] if reason else []
    if kind == "message_stop":
        return [("done", None)]
    if kind == "error":
        failure = payload.get("error") or {}
        return [("error", failure.get("message") or "流式响应里出现了一个错误")]
    return []


def openai_events(frame):
    if frame is None:
        return []
    data = frame["data"]
    if data == "[DONE]":
        return [("done", None)]
    try:
        payload = json.loads(data)
    except ValueError:
        return []

    failure = payload.get("error") or {}
    if failure.get("message"):
        return [("error", failure["message"])]

    choices = payload.get("choices") or []
    if not choices:
        return []
    choice = choices[0]
    delta = choice.get("delta") or {}

    events = []
    for call in delta.get("tool_calls") or []:
        index = call.get("index") or 0
        function = call.get("function") or {}
        name = function.get("name")
        if name:
            events.append(("tool_started", (index, call.get("id"), name)))
        elif call.get("id"):
            events.append(("tool_started", (index, call.get("id"), None)))
        if function.get("arguments"):
            events.append(("tool_args", (index, function["arguments"])))
    if events:
        return events

    finish = choice.get("finish_reason")
    if finish:
        return [("stop_reason", finish)]
    content = delta.get("content")
    if content:
        return [("text", content)]
    if delta.get("reasoning_content"):
        return [("thinking", None)]
    return []


def accumulate_tool_calls(events):
    """与 AIChatToolCallAccumulator 对应：按 index 把分片拼成完整调用。"""
    order = []
    calls = {}

    def slot(index):
        if index not in calls:
            order.append(index)
            calls[index] = {"id": None, "name": None, "args": ""}
        return calls[index]

    for kind, value in events:
        if kind == "tool_started":
            index, call_id, name = value
            call = slot(index)
            if call_id:
                call["id"] = call_id
            if name:
                call["name"] = name
        elif kind == "tool_args":
            index, fragment = value
            slot(index)["args"] += fragment

    result = []
    for index in sorted(order):
        call = calls[index]
        if call["name"]:  # 没有名字的半截数据丢掉
            result.append((index, call["id"], call["name"], call["args"]))
    return result


def run_stream(text, decoder):
    """喂一整段 SSE 文本，返回正文 / 事件名序列 / 结束原因 / 拼好的工具调用。"""
    reader = FrameReader()
    chunks = []
    names = []
    stop_reason = None
    all_events = []

    def handle(events):
        nonlocal stop_reason
        for event in events:
            all_events.append(event)
            names.append(event[0])
            if event[0] == "text":
                chunks.append(event[1])
            elif event[0] == "stop_reason":
                stop_reason = event[1]

    for line in text.split("\n"):
        handle(decoder(reader.consume(line)))
    handle(decoder(reader.flush()))

    return {
        "text": "".join(chunks),
        "names": names,
        "stop": stop_reason,
        "tool_calls": accumulate_tool_calls(all_events),
    }


def anysearch_result_text(payload):
    """与 AnySearchAPI.resultText 对应（输入是已解析的 JSON-RPC 响应）。"""
    error = payload.get("error") or {}
    if error.get("message"):
        raise ValueError("搜索失败：" + error["message"])
    content = (payload.get("result") or {}).get("content") or []
    text = "\n".join(
        item.get("text") or "" for item in content if item.get("type") == "text"
    ).strip()
    if not text:
        raise ValueError("搜索没有返回可用内容")
    return text


def normalize_base_url(raw):
    """与 AIChatConfig.normalizedBaseURL 对应：只去掉末尾斜杠，绝不自动补 /v1。"""
    text = raw.strip()
    while text.endswith("/"):
        text = text[:-1]
    if not text:
        return None
    parts = urlsplit(text)
    if parts.scheme not in ("http", "https"):
        return None
    if not parts.netloc:
        return None
    return text


def contextual_turns(turns, news_context):
    """与 AIChatRequestBuilder.contextualTurns 对应：资料并进第一条 user 消息。"""
    for index, (role, text) in enumerate(turns):
        if role == "user":
            result = list(turns)
            result[index] = (role, news_context + "\n\n---\n\n" + text)
            return result
    return list(turns)


def ai_news_context(item, story, prefetched_digest=None, limit=6000, max_reports=8):
    """与 AIChatNewsContext.make 对应。只断言关键性质，不追求逐字节一致。"""
    story = story or {}
    lines = ["【这条热点】"]
    lines.append("标题：" + (story.get("title") or item.get("title") or ""))
    lines.append("当前排名：第 %d 位" % item["rank"])

    source = (item.get("source") or {}).get("name")
    if source:
        lines.append("来源：" + source)

    counts = []
    if item.get("sourceCount"):
        counts.append("%d 个来源" % item["sourceCount"])
    if item.get("participantCount"):
        counts.append("%d 位参与者" % item["participantCount"])
    if counts:
        lines.append("规模：" + " · ".join(counts))

    if item.get("latestAt"):
        lines.append("最近报道：" + absolute_short(parse_iso(item["latestAt"])) + "（北京时间）")
    if story.get("firstReportAt"):
        lines.append("首次报道：" + absolute_short(parse_iso(story["firstReportAt"])) + "（北京时间）")

    links = item.get("links") or {}
    story_links = story.get("links") or {}
    original = links.get("original") or story_links.get("original")
    if original:
        lines.append("原文链接：" + original)
    aihot_link = links.get("aihot") or story_links.get("aihot")
    if aihot_link:
        lines.append("站内页：" + aihot_link)

    digest = story.get("digest") or prefetched_digest
    if digest:
        lines.append("")
        lines.append("【AI 摘要】")
        for paragraph in digest.split("\n"):
            if paragraph.strip():
                lines.append(paragraph.strip())

    reports = story.get("reports") or []
    if reports:
        lines.append("")
        lines.append("【报道时间线】")
        for report in reports[:max_reports]:
            parts = []
            if report.get("publishedAt"):
                parts.append(absolute_short(parse_iso(report["publishedAt"])))
            name = (report.get("source") or {}).get("name")
            if name:
                parts.append(name)
            if report.get("title"):
                parts.append(report["title"])
            if parts:
                lines.append("- " + " · ".join(parts))
            if report.get("summary"):
                lines.append("  " + report["summary"])

    lines.append("")
    lines.append("以上是 App 里已有的资料。请据此回答我下面的问题。")

    text = "\n".join(lines)
    if len(text) > limit:
        text = text[:limit] + "\n…（资料过长，已截断）"
    return text


# --------------------------------------------------------------------------
# 断言（全部以夹具为准）
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------


def fixture_text(name):
    with open(os.path.join(ROOT, "AIHOTTests", "Fixtures", name), "r", encoding="utf-8") as handle:
        return handle.read()


def fixture_json(name):
    with open(os.path.join(ROOT, "AIHOTTests", "Fixtures", name), "r", encoding="utf-8") as handle:
        return json.load(handle)


def run():
    print("== 镜像 1/2：/hot 页面文本 → 热度指数、涨跌、徽章 ==")
    text = fixture_text("hot-page.txt")
    page = parse_page(text)
    check(page is not None, "文本夹具应能解析出结果")
    if page:
        check_eq(page["updated"], "10月12日 10:35", "更新时间")
        check_eq(sorted(page["ranks"]), [1, 2, 3], "只解析前三条")
        first = page["ranks"].get(1, {})
        check_eq(first.get("heat"), 143, "NO.01 热度")
        check_eq(first.get("delta"), ("up", 629), "NO.01 涨跌")
        check_eq(first.get("is_breakout"), True, "NO.01 爆")
        second = page["ranks"].get(2, {})
        check_eq(second.get("heat"), 90, "NO.02 热度")
        check_eq(second.get("delta"), ("flat", None), "NO.02 持平")
        third = page["ranks"].get(3, {})
        check_eq(third.get("heat"), 77, "NO.03 热度")
        check_eq(third.get("delta"), ("down", 16), "NO.03 涨跌")
        check(4 not in page["ranks"] and 10 not in page["ranks"], "4–10 名不解析")

        # 真实页面的正文是一整段几百字，热度数字排在正文之后。
        # 夹具里 NO.01 的正文已按真实长度写；这里再补一个显式的长文用例。
        long_digest = "正文。" * 300
        realistic = "NO.01 爆 ↑ 20%%\n标题\n%s\n+10 7 个来源 · 16 位参与者\n160\n热度指数" % long_digest
        check_eq(parse_page(realistic)["ranks"][1]["heat"], 160, "长正文之后仍能取到热度指数")

    print("== 镜像 1/2：HTML → 纯文本 → 同样的解析 ==")
    html = fixture_text("hot-page.html")
    extracted = plain_text(html)
    check("热度指数" in extracted, "提取文本包含「热度指数」")
    check("NO.01" in extracted, "提取文本包含序号")
    check("143" in extracted, "提取文本包含热度数字")
    check("window.__NEXT_DATA__" not in extracted, "script 内容被剔除")
    check("font-weight" not in extracted, "style 内容被剔除")
    check("<" not in extracted, "不残留标签")
    check("·" in extracted and "&middot;" not in extracted, "HTML 实体被解码")

    html_page = parse_page(extracted)
    check(html_page is not None, "HTML 夹具端到端可解析")
    if html_page:
        check_eq(html_page["updated"], "10月12日 10:35", "HTML 更新时间")
        check_eq(html_page["ranks"].get(1, {}).get("heat"), 143, "HTML NO.01 热度")
        check_eq(html_page["ranks"].get(1, {}).get("delta"), ("up", 629), "HTML NO.01 涨跌")
        check_eq(html_page["ranks"].get(1, {}).get("is_breakout"), True, "HTML NO.01 爆")
        check_eq(html_page["ranks"].get(2, {}).get("delta"), ("flat", None), "HTML NO.02 持平")

    print("== 镜像 2：失败即放弃 / 不误判 ==")
    check(parse_page("首页\n最新动态\n登录\n注册") is None, "无关页面返回 None")
    check(parse_page("NO.01 爆\n某条标题\n+43 个来源 65 新上榜\n继续往下\n")["ranks"][1]["heat"] is None,
          "没有「热度指数」锚点时不猜数字")
    fake_title = "新模型发布：某公司推出新架构"
    titled = parse_page("NO.01 持平\n%s\n内容\n120\n热度指数" % fake_title, excluding_titles=[fake_title])
    check_eq(titled["ranks"][1]["is_new"], False, "标题里的「新」不算徽章")
    check_eq(titled["ranks"][1]["heat"], 120, "剔除标题后仍能取到热度")
    next_line = parse_page("NO.01\n新上榜 ↑ 12%\n某条标题\n88\n热度指数")
    check_eq(next_line["ranks"][1]["is_new"], True, "徽章换行后仍能识别")
    check_eq(next_line["ranks"][1]["delta"], ("up", 12), "换行后的涨跌")
    check_eq(next_line["ranks"][1]["heat"], 88, "换行后的热度")
    ten = parse_page("NO.01 爆\n第一条标题\n50\n热度指数\nNO.10 持平\n第十条标题\n10\n热度指数")
    check_eq(ten["ranks"][1]["heat"], 50, "NO.10 不能被当成 NO.01")
    check(10 not in ten["ranks"], "第 10 名不产出热度")

    print("== 镜像 3：links.story → publicId ==")
    check_eq(public_id("https://aihot.news/story/9ce2c8e5-8fa1-4763-b493-ddec042860cc"),
             "9ce2c8e5-8fa1-4763-b493-ddec042860cc", "新域名")
    check_eq(public_id("https://aihot.virxact.com/story/244f781e-a578-4493-804d-4b4cfa063ea3"),
             "244f781e-a578-4493-804d-4b4cfa063ea3", "旧域名")
    check_eq(public_id("https://aihot.news/story/ba1d5ac2-160e-4d9d-ae98-63405a9bb3f3?utm=1#t"),
             "ba1d5ac2-160e-4d9d-ae98-63405a9bb3f3", "带 query 与 fragment")
    check(public_id("https://aihot.news/hot") is None, "非 story 路径被拒")
    check(public_id("https://aihot.news/") is None, "根路径被拒")
    check(public_id("https://aihot.news/story/story") is None, "story 占位被拒")
    check(public_id(None) is None and public_id("") is None, "空值被拒")
    check(public_id("not a url") is None, "非法字符串被拒")

    print("== 镜像 4：时间显示（北京时间） ==")
    now = parse_iso("2026-10-12T10:00:00Z")
    check_eq(relative_time(now - datetime.timedelta(seconds=5), now), "刚刚", "5 秒前")
    check_eq(relative_time(now - datetime.timedelta(seconds=300), now), "5 分钟前", "5 分钟前")
    check_eq(relative_time(now - datetime.timedelta(hours=3), now), "3 小时前", "3 小时前")
    check_eq(relative_time(now - datetime.timedelta(days=2), now), "2 天前", "2 天前")
    check_eq(relative_time(parse_iso("2026-08-01T04:00:00Z"), now), "8月1日", "同年更早")
    check_eq(relative_time(parse_iso("2025-08-01T04:00:00Z"), now), "2025年8月1日", "跨年")
    check_eq(relative_time(now + datetime.timedelta(seconds=120), now), "刚刚", "未来时间不炸")
    check_eq(absolute_short(parse_iso("2026-10-12T02:35:00Z")), "10月12日 10:35", "北京时间格式")

    print("== 镜像 5：夹具 JSON 的字段与解码假设 ==")
    hot = fixture_json("hot-topics.json")
    check_eq(hot["count"], len(hot["items"]), "count 与 items 一致")
    check_eq([item["rank"] for item in hot["items"]], [1, 2, 3], "rank 顺序")
    check_eq(len({item["id"] for item in hot["items"]}), 3, "id 唯一")
    first_item = hot["items"][0]
    for required in ("rank", "id", "title", "source", "links", "sourceCount", "participantCount", "sourceNames", "latestAt"):
        check(required in first_item, "字段存在：%s" % required)
    check_eq(len(first_item["sourceNames"]), 7, "sourceNames 条数")
    check_eq(first_item["participantCount"], 16, "participantCount")
    check_eq(first_item["latestAt"], "2026-10-12T01:40:20.000Z", "带毫秒的时间戳（解码器必须能吃）")
    for item in hot["items"]:
        check(public_id(item["links"]["story"]) is not None, "每条 story 链接都能取出 id")

    story = fixture_json("story.json")["story"]
    paragraphs = [p.strip() for p in story["digest"].split("\n") if p.strip()]
    check_eq(len(paragraphs), 3, "digest 段落数")
    check_eq(len(story["reports"]), 1, "reports 条数")
    check_eq(story["reports"][0]["source"]["name"], "IT之家·人工智能", "报道来源名")
    check_eq(story["reports"][0]["links"]["original"], "https://www.ithome.com/1/011/720.htm", "报道原文链接")
    check_eq(story["status"], "active", "story 状态")
    for report in story["reports"]:
        check("id" in report, "report.id 是必需字段（模型里非可选）")

    print("")
    print("== 镜像 6：SSE 分帧与协议解码（含工具调用）==")
    anthropic = run_stream(fixture_text("anthropic-sse.txt"), anthropic_events)
    check_eq(anthropic["text"], "我先查一下有没有后续。", "Anthropic 拼出的正文")
    check_eq(anthropic["names"].count("thinking"), 1, "thinking_delta 只点亮状态，不进正文")
    check_eq(anthropic["stop"], "tool_use", "Anthropic 结束原因：要跑工具")
    check_eq(anthropic["tool_calls"],
             [(2, "toolu_01A", "web_search", '{"query":"Karpathy LLM 认知鸿沟 后续"}')],
             "Anthropic 把 input_json_delta 分片拼回完整参数")
    check_eq(anthropic["names"][-1], "done", "Anthropic 以 message_stop 收尾")

    openai = run_stream(fixture_text("openai-sse.txt"), openai_events)
    check_eq(openai["text"], "我先查一下有没有后续。", "OpenAI 拼出的正文")
    check_eq(openai["names"].count("thinking"), 1, "reasoning_content 只点亮状态")
    check_eq(openai["stop"], "tool_calls", "OpenAI 结束原因：要跑工具")
    check_eq(openai["tool_calls"],
             [(0, "call_01A", "web_search", '{"query":"Karpathy LLM 认知鸿沟 后续"}')],
             "OpenAI 的工具调用拼成与 Anthropic 相同的形状")
    check_eq(openai["names"][-1], "done", "OpenAI 以 [DONE] 收尾")

    def drain(lines, decoder):
        reader = FrameReader()
        out = []
        for line in lines:
            out.extend(decoder(reader.consume(line)))
        out.extend(decoder(reader.flush()))
        return out

    def a(*lines):
        return drain(list(lines) + [""], anthropic_events)

    def o(*lines):
        return drain(list(lines) + [""], openai_events)

    check_eq(drain(['data: {"type":"message_stop"}\r', ""], anthropic_events),
             [("done", None)], "CRLF 行尾也能分帧")
    check_eq(a('data: {"type":"content_block_delta",',
               'data: "delta":{"type":"text_delta","text":"hi"}}'),
             [("text", "hi")], "多行 data 拼接后仍是合法 JSON")
    check_eq(a(": ping", "event: ping", 'data: {"type":"ping"}'),
             [], "注释行 / event 行 / ping 都不产出事件")
    check_eq(len(a('data:  {"type":"message_stop"}')), 1, "只剥一个前导空格")
    check_eq(a('data: {"type":"content_block_start","index":0,'
               '"content_block":{"type":"fallback","from":{"model":"a"}}}'),
             [], "未知 content_block 类型被静默跳过，不抛错")
    check_eq(a('data: {"type":"message_start","message":{}}'),
             [], "message_start 不产出事件（换模型时会有第二个）")
    check_eq(a('data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'),
             [("error", "Overloaded")], "error 帧把接口原话带出来")
    check_eq(a('data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"半句"}}'),
             [("text", "半句")], "没有 message_stop 的截断也要保住正文")
    check_eq(a('data: {"type":"content_block_start","index":1,'
               '"content_block":{"type":"tool_use","id":"t1","name":"read_url"}}'),
             [("tool_started", (1, "t1", "read_url"))], "Anthropic 的 tool_use 块")

    for reason in ("refusal", "pause_turn", "max_tokens"):
        check_eq(a('data: {"type":"message_delta","delta":{"stop_reason":"%s"}}' % reason),
                 [("stop_reason", reason)], "结束原因 %s 要能带出来" % reason)

    check_eq(accumulate_tool_calls([
        ("tool_args", (0, '{"a":')),
        ("tool_started", (0, "id1", "read_url")),
        ("tool_args", (0, "1}")),
    ]), [(0, "id1", "read_url", '{"a":1}')], "名字与参数乱序到也能拼对")
    check_eq(accumulate_tool_calls([("tool_args", (0, "{}"))]), [],
             "只有参数没有名字的半截数据丢掉")
    check_eq(accumulate_tool_calls([("tool_started", (1, "b", "read_url")),
                                    ("tool_started", (0, "a", "web_search"))]),
             [(0, "a", "web_search", ""), (1, "b", "read_url", "")], "按 index 排序")

    check_eq(o("data: [DONE]"), [("done", None)], "[DONE] 收尾")
    check_eq(o('data: {"choices":[{"delta":{"content":null,"reasoning_content":"想了想"},'
               '"finish_reason":null}]}'),
             [("thinking", None)], "content 为 null 而 reasoning_content 有值：不抛、也不出正文")
    check_eq(o('data: {"choices":[{"delta":{"content":null},"finish_reason":"length"}]}'),
             [("stop_reason", "length")], "finish_reason=length 要带出来")
    check_eq(o('data: {"choices":[{"delta":{"content":"x"}}]}'),
             [("text", "x")], "没有 [DONE]、流自然结束也算完，正文不丢")
    check_eq(o('data: {"error":{"message":"Invalid API key"}}'),
             [("error", "Invalid API key")], "OpenAI 侧错误也要带原话")

    print("== 镜像 7：AI 对话的地址归一化与资料拼接 ==")
    check_eq(normalize_base_url("https://api.anthropic.com/"), "https://api.anthropic.com",
             "去掉末尾斜杠")
    check_eq(normalize_base_url("https://api.deepseek.com/v1"), "https://api.deepseek.com/v1",
             "不自动补、也不删 /v1")
    check_eq(normalize_base_url("https://relay.example.com/anthropic/v1/"),
             "https://relay.example.com/anthropic/v1", "带路径的地址原样保留")
    check(normalize_base_url("api.anthropic.com") is None, "没有 scheme 被拒")
    check(normalize_base_url("ftp://example.com") is None, "非 http(s) 被拒")
    check(normalize_base_url("   ") is None, "空串被拒")
    check(normalize_base_url("https://") is None, "没有主机名被拒")

    hot = fixture_json("hot-topics.json")["items"][0]
    story = fixture_json("story.json")["story"]
    context = ai_news_context(hot, story)

    check(story["title"] in context, "有 story 时用 story 的标题")
    check(hot["title"] in ai_news_context(hot, None), "没有 story 时退回榜单标题")
    check("第 %d 位" % hot["rank"] in context, "排名在")
    check("%d 个来源" % hot["sourceCount"] in context, "来源数在")
    check("%d 位参与者" % hot["participantCount"] in context, "参与者数在")
    check(hot["links"]["original"] in context, "原文链接必须原样出现（web_fetch 只能抓对话里出现过的 URL）")
    check(hot["links"]["aihot"] in context, "站内页链接在")
    check(story["digest"].split("\n")[0].strip() in context, "摘要第一段在")
    check(story["reports"][0]["title"] in context, "报道时间线的标题在")
    check(absolute_short(parse_iso(hot["latestAt"])) in context, "时间用绝对格式")
    check(not any(w in context for w in ("小时前", "天前", "分钟前", "刚刚")),
          "不带相对时间（每轮都在变，会打断缓存前缀）")
    check_eq(context, ai_news_context(hot, story), "确定性：同样输入两次结果一致")

    truncated = ai_news_context(hot, story, limit=300)
    check(len(truncated) < 400 and "已截断" in truncated, "超长要截断并留下标记")

    turns = [("user", "这条为什么火？"), ("assistant", "因为同时被多人转引。"), ("user", "还有后续吗？")]
    merged = contextual_turns(turns, context)
    check_eq(len(merged), 3, "轮数不变")
    check(merged[0][1].startswith(context), "资料并进第一条 user 消息")
    check_eq(merged[0][1].split("\n\n---\n\n")[-1], "这条为什么火？", "原问题保留在资料后面")
    check_eq(merged[1], ("assistant", "因为同时被多人转引。"), "助手那轮原样不动")
    check_eq(merged[2][1], "还有后续吗？", "后续轮次不动")
    check_eq(contextual_turns([("assistant", "x")], context), [("assistant", "x")],
             "没有 user 轮时不乱并")

    print("")
    print("== 镜像 8：AnySearch 响应解析 ==")
    anysearch = fixture_json("anysearch-search.json")
    text = anysearch_result_text(anysearch)
    check(text.startswith("## Search Results"), "取到的是排好的 Markdown，可直接给模型")
    check("https://karpathy.bearblog.dev/year-in-review-2025/" in text,
          "结果里带 URL（模型据此再调 read_url）")
    check_eq(anysearch_result_text({"result": {"content": [{"type": "text", "text": "  x  "}]}}),
             "x", "去掉首尾空白")

    def raises(func, label, needle=""):
        try:
            func()
        except ValueError as exc:
            check(needle in str(exc), label)
            return
        check(False, label + "（应当抛错但没有）")

    raises(lambda: anysearch_result_text({"error": {"message": "Invalid key"}}),
           "JSON-RPC error 要抛错并带原话", "Invalid key")
    raises(lambda: anysearch_result_text({"result": {"content": []}}),
           "空结果要抛错，而不是回一个空串")

    print("镜像测试：通过 %d 项" % _passed)
    if _failed:
        print("")
        for item in _failed:
            print("  ✗ %s" % item)
        print("")
        print("失败 %d 项" % len(_failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
