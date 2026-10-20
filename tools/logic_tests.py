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


class ByteLineSplitter:
    """与 Swift 的 SSELineSplitter 一一对应：只认 LF，空行原样交出。

    空行是 SSE 分帧的**唯一**依据，谁把它吞掉，整条流就会被拼成一帧、
    一个事件都认不出来（真机上那句「没有任何回复」就是这么来的）。
    """

    MAXIMUM_LINE_LENGTH = 64 * 1024

    def __init__(self):
        self.buffer = bytearray()

    def consume(self, byte):
        if byte != 0x0A:
            if len(self.buffer) < self.MAXIMUM_LINE_LENGTH:
                self.buffer.append(byte)
            return None
        return self._take()

    def flush(self):
        if not self.buffer:
            return None
        return self._take()

    def _take(self):
        line = self.buffer.decode("utf-8", errors="replace")
        self.buffer = bytearray()
        return line


def split_lines(data):
    """字节 → 行（照 SSELineSplitter 的用法走一遍）。"""
    splitter = ByteLineSplitter()
    lines = []
    for byte in data:
        line = splitter.consume(byte)
        if line is not None:
            lines.append(line)
    line = splitter.flush()
    if line is not None:
        lines.append(line)
    return lines


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


def run_stream_lines(lines, decoder):
    """喂一串**行**，返回正文 / 事件名序列 / 结束原因 / 拼好的工具调用。"""
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

    for line in lines:
        handle(decoder(reader.consume(line)))
    handle(decoder(reader.flush()))

    return {
        "text": "".join(chunks),
        "names": names,
        "stop": stop_reason,
        "tool_calls": accumulate_tool_calls(all_events),
    }


def run_stream(text, decoder):
    """喂一整段 SSE 文本（按 `\n` 切行，与既有用例的读法一致）。"""
    return run_stream_lines(text.split("\n"), decoder)


def run_stream_bytes(data, decoder):
    """同一段流，但入口是**字节**：先过一遍自己的切行器。

    这条链路原来归平台的 `AsyncSequence.lines` 管（本地没法验），现在归我们 ——
    所以它必须和按行喂进去得到同一轮。
    """
    return run_stream_lines(split_lines(data), decoder)


def anysearch_result_text(payload):
    """与 AnySearchAPI.resultText 对应（输入是已解析的 JSON-RPC 响应）。

    失败有**两种**形状，只看顶层 error 会漏掉第一种：
      - 无效 key / 工具自己失败：HTTP 200，顶层无 error，而是 result.isError == True，
        原因在 result.content[0].text 里（实测无效 key 就是这条）；
      - 协议级错误：顶层 error.message。
    """
    error = payload.get("error") or {}
    if error.get("message"):
        raise ValueError("搜索失败：" + error["message"])
    result = payload.get("result") or {}
    content = result.get("content") or []
    text = "\n".join(
        item.get("text") or "" for item in content if item.get("type") == "text"
    ).strip()
    if result.get("isError") is True:
        if "invalid_api_key" in text:
            raise ValueError("AnySearch 的 Key 无效或已停用。可以到「设置 → AI 对话」清空它改用匿名，或换一个 Key")
        raise ValueError("搜索服务拒绝了这次调用" if not text else "搜索失败：" + text)
    if not text:
        raise ValueError("搜索没有返回可用内容")
    return text


def tavily_search_text(payload):
    """与 TavilyAPI.searchText 对应（输入是已解析的 200 响应）。

    results → 模型可读 Markdown：`### {序号}. {标题}\\n{URL}\\n\\n{摘要}`，
    条目之间空行分隔；answer 非空时前置引用块。空结果抛错，绝不回空串。
    """
    if not isinstance(payload, dict):
        raise ValueError("Tavily 返回了看不懂的内容")
    results = payload.get("results") or []
    sections = []
    for item in results:
        if not isinstance(item, dict):
            raise ValueError("Tavily 返回了看不懂的内容")
        title = (item.get("title") or "").strip()
        url = (item.get("url") or "").strip()
        content = (item.get("content") or "").strip()
        if not title and not content:
            continue  # 宁可少抽，不可抽错：空壳条目跳过
        section = "### %d. %s" % (len(sections) + 1, title or url)
        if title and url:
            section += "\n" + url
        if content:
            section += "\n\n" + content
        sections.append(section)
    if not sections:
        raise ValueError("Tavily 没有返回可用内容")
    text = "\n\n".join(sections)
    answer = (payload.get("answer") or "").strip()
    if answer:
        text = "> " + answer + "\n\n" + text
    return text


def tavily_extract_text(payload):
    """与 TavilyAPI.extractText 对应。

    **先查 failed_results**：HTTP 200 也可能带失败条目（Tavily 版的 isError 陷阱，
    规则 13 的教训）——非空必抛，哪怕同时有成功结果。
    """
    if not isinstance(payload, dict):
        raise ValueError("Tavily 返回了看不懂的内容")
    failed = payload.get("failed_results") or []
    if failed:
        first = failed[0] if isinstance(failed[0], dict) else {}
        reason = (first.get("error") or "").strip() or (first.get("message") or "").strip()
        page = (first.get("url") or "").strip()
        if not reason:
            reason = page + " 提取失败" if page else "有页面没能提取"
        raise ValueError("Tavily 提取失败：" + reason)
    results = payload.get("results") or []
    contents = []
    for item in results:
        if not isinstance(item, dict):
            raise ValueError("Tavily 返回了看不懂的内容")
        raw = (item.get("raw_content") or "").strip()
        if raw:
            contents.append(raw)
    if not contents:
        raise ValueError("Tavily 没有返回可用内容")
    return "\n\n".join(contents)


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


def chat_history(messages):
    """与 AIChatModel.history(from:) 对应：逐条带走，只滤掉一个字都没有的。

    它错了不会崩，只会让模型失忆 —— 或者反过来，把用户自己那句话丢掉。
    注意收尾那道闸在 Swift 的 finishStreaming() 里（它会把空气泡删掉），
    所以「一轮什么都没产出」在这里表现为一对连续的 user 消息。
    """
    return [(role, text) for role, text in messages if text != ""]


# 镜像 13：对话会话封顶（ChatHistoryStore.trim）

# 与 ChatHistoryStore.maximumSessions 同步 —— Swift 改了这里也要改。
MAXIMUM_SESSIONS = 50


def trim_sessions(sessions, maximum=MAXIMUM_SESSIONS):
    """与 ChatHistoryStore.trim 对应：只从数组头部（最久没动的）淘汰。

    **绝不按 updatedAt 排序再截**：Swift 的 sort 不稳定，同一秒保存的两条会
    每次漂移（同规则 8 / 收藏的理由）—— 数组顺序才是权威，upsert 已经把
    最近保存的排到了末尾，所以 suffix 就是「保留最近的」。
    """
    if len(sessions) <= maximum:
        return list(sessions)
    return list(sessions[-maximum:])


# 镜像 11：失败原因（AIChatModel.truncationNotice）

PROTOCOL_TITLES = {"anthropic": "Anthropic", "openai": "OpenAI 兼容"}
PROTOCOL_DECODERS = {"anthropic": anthropic_events, "openai": openai_events}


def other_protocol(protocol):
    return "openai" if protocol == "anthropic" else "anthropic"


def scan_stream(text, protocol):
    """与 AIChatModel.consume 的记法对应：切了几帧、认出几个事件、留了哪几段原文。

    留原文的规则是「这一帧什么都没认出来，且 data 非空」，最多 5 段、每段最多 200 字。
    """
    reader = FrameReader()
    decoder = PROTOCOL_DECODERS[protocol]
    frames = 0
    recognized = 0
    samples = []

    def take(frame):
        nonlocal frames, recognized
        if frame is None:
            return
        frames += 1
        events = decoder(frame)
        recognized += len(events)
        if not events and frame["data"] and len(samples) < 5:
            samples.append(frame["data"][:200])

    for line in text.split("\n"):
        take(reader.consume(line))
    take(reader.flush())
    return {"frames": frames, "recognized": recognized, "samples": samples}


def truncation_notice(frame_count, recognized, first_raw_line, samples, had_text, protocol):
    """与 AIChatModel.truncationNotice 对应：一轮「既没等到结束原因、也没等到收尾标记」
    时该说哪句话。

    原来只有一句「连接提前中断，回复可能不完整」，把四种完全不同的故障说成了同一句 ——
    用户照着它什么都查不出来，我们这边也只能猜。侧载的 App 挂不上调试器，
    **这行字就是唯一的诊断信号**，所以它必须说出流里究竟收到了什么。
    """
    titles = PROTOCOL_TITLES
    other = other_protocol(protocol)

    if recognized == 0:
        if frame_count == 0:
            if first_raw_line is None:
                return "接口没有返回任何内容，请稍后重试。"
            return ("接口回的内容不是流式格式，解析不了。请到「设置 → AI 对话」核对接口地址与协议是否配套。"
                    "接口开头是：%s" % first_raw_line)
        if any(PROTOCOL_DECODERS[other]({"event": None, "data": s}) for s in samples):
            return ("这个地址回的是「%s」格式的流，跟「协议」里选的「%s」对不上。"
                    "请把协议改成「%s」，或把接口地址换成「%s」的地址。"
                    % (titles[other], titles[protocol], titles[other], titles[protocol]))
        if not samples:
            return "接口没有返回任何内容，请稍后重试。"
        # 帧数必须带上：流的第一帧（role 分片 / message_start）本来就认不出来，
        # 光看开头分不清「整条流被拼成一帧」和「切了很多帧都不认识」。
        detail = "共切出 %d 帧，开头是：%s" % (frame_count, samples[0])
        if len(samples) > 1:
            detail += "；最后一段是：%s" % samples[-1]
        return ("接口回的内容既不像「%s」也不像「%s」的流式格式（%s）。"
                "请核对接口地址与协议是否配套。" % (titles[protocol], titles[other], detail))

    if not had_text:
        return "接口还没给出回复就断开了，请重试。"
    return "连接提前中断，回复可能不完整。"


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
# 镜像 9：报道节奏（ReportTimeline）
# --------------------------------------------------------------------------
# 与 Swift 的 ReportTimeline.make 一一对应。三档粒度按 allCases 顺序从细到粗试，
# 取第一个装得下的；桶按北京时间对齐；空桶保留；峰值并列取最早。

MAXIMUM_BUCKETS = 24
MAXIMUM_AXIS_LABELS = 5

INTERVALS = ("15m", "hour", "day")


def floor_bucket(when, interval):
    """对齐到所属桶的起点（北京时间）。对应 Swift 的 floor(_:interval:)。"""
    local = when.astimezone(BEIJING)
    if interval == "15m":
        return local.replace(minute=local.minute // 15 * 15, second=0, microsecond=0)
    if interval == "hour":
        return local.replace(minute=0, second=0, microsecond=0)
    return local.replace(hour=0, minute=0, second=0, microsecond=0)


def advance_bucket(when, interval):
    if interval == "15m":
        return when + datetime.timedelta(minutes=15)
    if interval == "hour":
        return when + datetime.timedelta(hours=1)
    return when + datetime.timedelta(days=1)


def bucket_starts(first, last, interval):
    end = floor_bucket(last, interval)
    starts = []
    cursor = floor_bucket(first, interval)
    while cursor <= end and len(starts) < 400:
        starts.append(cursor)
        cursor = advance_bucket(cursor, interval)
    return starts


def bucket_label(start, interval):
    local = start.astimezone(BEIJING)
    if interval == "day":
        return "%d月%d日" % (local.month, local.day)
    return "%02d:%02d" % (local.hour, local.minute)


def axis_labels(labels):
    """桶数多于 5 个时挑 5 个刻度：下标 i * (n - 1) / 4。

    只用整数除法 —— 绝不能用 round()：Python 的 round() 是银行家舍入、
    Swift 的 rounded() 是四舍五入，n = 25 时两边会挑出不同的刻度。
    """
    count = len(labels)
    if count <= MAXIMUM_AXIS_LABELS:
        return list(labels)
    indices = []
    for step in range(MAXIMUM_AXIS_LABELS):
        index = step * (count - 1) // (MAXIMUM_AXIS_LABELS - 1)
        if not indices or indices[-1] != index:
            indices.append(index)
    return [labels[index] for index in indices]


def report_timeline(story):
    """story 字典 → 节奏图数据；桶数不足 2 个时返回 None（与 Swift 一致）。"""
    dated = sorted(
        parse_iso(report["publishedAt"])
        for report in (story.get("reports") or [])
        if report.get("publishedAt")
    )
    if len(dated) < 2:
        return None
    first, last = dated[0], dated[-1]

    interval = INTERVALS[-1]
    starts = []
    for candidate in INTERVALS:
        interval = candidate
        starts = bucket_starts(first, last, candidate)
        if len(starts) <= MAXIMUM_BUCKETS:
            break
    if len(starts) < 2:
        return None

    counts = [0] * len(starts)
    for when in dated:
        index = None
        for position, start in enumerate(starts):
            if start <= when:  # 正好踩在边界上的报道算进右边那一桶
                index = position
            else:
                break
        if index is not None:
            counts[index] += 1

    maximum = max(counts)
    peak_index = counts.index(maximum)  # 并列取最早

    buckets = [
        {
            "start": start,
            "label": bucket_label(start, interval),
            "count": counts[position],
            "is_peak": position == peak_index,
            "is_newest": position == len(counts) - 1,
        }
        for position, start in enumerate(starts)
    ]

    cutoff = last - datetime.timedelta(seconds=86400)
    return {
        "interval": interval,
        "buckets": buckets,
        "peak": buckets[peak_index],
        "total_timestamped": len(dated),
        "last_24_hour_count": len([when for when in dated if when >= cutoff]),
        "axis_labels": axis_labels([bucket["label"] for bucket in buckets]),
        "truncated": (story.get("reportCount") or 0) > len(dated),
    }


# --------------------------------------------------------------------------
# 镜像 14：SerpAPI / Serper / Exa 三家响应解析（与三个新 Service 对应）
# --------------------------------------------------------------------------
# 输入都是「已解析的 200 响应」。三家线格式各不相同，解析规则与 Swift 逐条对应；
# 错误详情提取也在这里 —— 三家的错误信封互不相同（单字段 error / 顶层 message /
# 信封 error 字符串），`AIChatAPI.problemMessage` 只认得 Serper 那种。


def _search_sections(items, provider):
    """三家共用的结果拼装：`### {序号}. {标题}\n{URL}\n\n{摘要}`。

    标题就是链接时不重复印 URL（SerpAPI 真夹具第 1 条就是这样）；
    条目字段可容缺，零条抛错，绝不回空串。
    """
    sections = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError(provider + " 返回了看不懂的内容")
        title = (item.get("title") or "").strip()
        link = (item.get("link") or item.get("url") or "").strip()
        snippet = (item.get("snippet") or item.get("text") or "").strip()
        if not title and not link and not snippet:
            continue  # 空壳条目跳过
        heading = title or link
        section = "### %d. %s" % (len(sections) + 1, heading)
        if link and link != heading:
            section += "\n" + link
        if snippet:
            section += "\n\n" + snippet
        sections.append(section)
    if not sections:
        raise ValueError(provider + " 没有返回可用内容")
    return "\n\n".join(sections)


def serpapi_search_text(payload):
    """与 SerpAPI.searchText 对应。

    **先查顶层 error**（200 也可能带报错），再解析 organic_results；snippet 容缺。
    """
    if not isinstance(payload, dict):
        raise ValueError("SerpAPI 返回了看不懂的内容")
    error = (payload.get("error") or "").strip()
    if error:
        raise ValueError("SerpAPI 报错：" + error)
    organic = payload.get("organic_results")
    if organic is not None and not isinstance(organic, list):
        raise ValueError("SerpAPI 返回了看不懂的内容")
    return _search_sections(organic or [], "SerpAPI")


def serper_search_text(payload):
    """与 SerperAPI.searchText 对应。

    防御性查顶层 error / message（200 带报错的形状没抓过，文档不可达）：
    error 先查；零条时 message 比「没有内容」更能说明原因。
    """
    if not isinstance(payload, dict):
        raise ValueError("Serper 返回了看不懂的内容")
    error = (payload.get("error") or "").strip()
    if error:
        raise ValueError("Serper 报错：" + error)
    organic = payload.get("organic")
    if organic is not None and not isinstance(organic, list):
        raise ValueError("Serper 返回了看不懂的内容")
    try:
        return _search_sections(organic or [], "Serper")
    except ValueError as exc:
        if "没有返回可用内容" not in str(exc):
            raise
        message = (payload.get("message") or "").strip()
        if message:
            raise ValueError("Serper 报错：" + message)
        raise


def exa_search_text(payload):
    """与 ExaAPI.searchText 对应：results[] → 同款 Markdown；先查顶层 error（防御）。"""
    if not isinstance(payload, dict):
        raise ValueError("Exa 返回了看不懂的内容")
    error = (payload.get("error") or "").strip()
    if error:
        raise ValueError("Exa 报错：" + error)
    results = payload.get("results")
    if results is not None and not isinstance(results, list):
        raise ValueError("Exa 返回了看不懂的内容")
    return _search_sections(results or [], "Exa")


def exa_contents_text(payload):
    """与 ExaAPI.contentsText 对应。

    **先查 statuses[]**：HTTP 200 也可能有失败条目（Tavily failed_results 的
    同款陷阱，规则 13 的教训）——非空必抛，哪怕同时有成功结果；然后拼
    results[].text（每条 trim 后非空才收），零条抛错。
    """
    if not isinstance(payload, dict):
        raise ValueError("Exa 返回了看不懂的内容")
    statuses = payload.get("statuses")
    if isinstance(statuses, list):
        failed = []
        for entry in statuses:
            if not isinstance(entry, dict):
                continue
            status = (entry.get("status") or "").strip().lower()
            if status and status != "success":
                failed.append(entry)
        if failed:
            first = failed[0]
            reason = (first.get("error") or "").strip()
            page = (first.get("id") or "").strip()
            status = (first.get("status") or "").strip()
            detail = reason
            if not detail and page:
                detail = page + " 提取失败"
            if not detail:
                detail = "状态：" + status if status else "有页面没能提取"
            raise ValueError("Exa 提取失败：" + detail)
    results = payload.get("results")
    if results is not None and not isinstance(results, list):
        raise ValueError("Exa 返回了看不懂的内容")
    contents = []
    for item in results or []:
        if not isinstance(item, dict):
            continue
        text = (item.get("text") or "").strip()
        if text:
            contents.append(text)
    if not contents:
        raise ValueError("Exa 没有返回可用内容")
    return "\n\n".join(contents)


def serpapi_top_error(payload):
    """SerpAPI 错误体是**单字段** `{"error": "…"}`（problemMessage 认不出这种信封）。"""
    if not isinstance(payload, dict):
        return None
    error = payload.get("error")
    if isinstance(error, str) and error.strip():
        return error.strip()
    return None


def serper_error_detail(payload):
    """Serper 错误体是顶层 `{"message": …}` —— problemMessage 认得的形状，
    这里镜像它的取法（信封 error.message 优先，顶层 message 其次）。"""
    if not isinstance(payload, dict):
        return None
    envelope = payload.get("error")
    if isinstance(envelope, dict):
        message = envelope.get("message")
        if isinstance(message, str) and message.strip():
            return message.strip()
    message = payload.get("message")
    if isinstance(message, str) and message.strip():
        return message.strip()
    return None


def exa_top_error(payload):
    """Exa 错误信封 `{requestId, error, tag}` 里 error 是**字符串**（不是对象）。"""
    if not isinstance(payload, dict):
        return None
    error = payload.get("error")
    if isinstance(error, str) and error.strip():
        return error.strip()
    return None


# --------------------------------------------------------------------------
# 镜像 15：搜索工具的顺序规范化与回退选择
# --------------------------------------------------------------------------
# 两张能力表是与 Swift `AppSettings.SearchToolProvider` 的**镜像契约**
# （规则 4：Swift 是权威，这里照抄；改了那边不改这边，镜像会安静地错）。

SEARCH_PROVIDERS = ["anySearch", "tavily", "serpapi", "exa", "serper"]
SEARCH_SUPPORTS_READ_URL = {
    "anySearch": True, "tavily": True, "serpapi": False, "exa": True, "serper": False,
}
SEARCH_REQUIRES_KEY = {
    "anySearch": False, "tavily": True, "serpapi": True, "exa": True, "serper": True,
}


def eligible_providers(order, disabled, keys, tool):
    """与 `SearchToolChain.eligibleProviders` 对应。

    停用跳过 → read_url 跳过不支持读网页的家 → 必填 Key 空白跳过；
    AnySearch 不要求 Key（空 Key **保留**，匿名合法）。保持用户顺序。
    """
    needs_read_url = tool == "read_url"
    eligible = []
    for provider in order:
        if provider in disabled:
            continue
        if needs_read_url and not SEARCH_SUPPORTS_READ_URL[provider]:
            continue
        if SEARCH_REQUIRES_KEY[provider]:
            if not (keys.get(provider) or "").strip():
                continue
        eligible.append(provider)
    return eligible


def normalize_search_order(stored, legacy_single_raw):
    """与 `AppSettings.normalizeSearchToolOrder` 对应。

    stored 非 nil：丢未知、首次出现去重、缺的追加到末尾（前向兼容）；
    stored 为 nil（从没 reorder 过）：旧单选值排第一再补齐；`[]` 自愈为规范顺序。
    """
    seen = set()
    order = []

    def append(provider):
        if provider in seen:
            return
        seen.add(provider)
        order.append(provider)

    if stored is not None:
        for raw in stored:
            if raw in SEARCH_PROVIDERS:
                append(raw)
    elif legacy_single_raw in SEARCH_PROVIDERS:
        append(legacy_single_raw)
    for provider in SEARCH_PROVIDERS:
        append(provider)
    return order


def normalize_disabled(stored):
    """与 `AppSettings.normalizeSearchToolDisabled` 对应：nil = 全启用；丢未知、去重。"""
    if stored is None:
        return set()
    return {raw for raw in stored if raw in SEARCH_PROVIDERS}


# --------------------------------------------------------------------------
# 镜像 16：回答的 Markdown 分块（MarkdownBlocks.parse）
# --------------------------------------------------------------------------
# 与 Swift `MarkdownBlocks` 对应（规则 4：Swift 是权威，取舍清单在 Swift 文件头）。
# 同一份夹具 `chat-markdown.md` 两边都读。块用 dict 表示，键名与断言一一对应。

MD_LIST_ITEM_RE = re.compile(r"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$")
MD_HEADING_RE = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$")
MD_RULE_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})$")
MD_QUOTE_RE = re.compile(r"^ {0,3}>(.*)$")


def _md_is_table_separator(line):
    trimmed = line.strip()
    if "|" not in trimmed or "-" not in trimmed:
        return False
    stripped = trimmed.replace("|", "").replace(":", "")
    return bool(stripped) and all(ch in " \t-" for ch in stripped)


def _md_table_cells(line):
    body = line
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    return [cell.strip() for cell in body.split("|")]


def markdown_blocks(text):
    """与 Swift `MarkdownBlocks.parse` 对应。"""
    lines = [raw[:-1] if raw.endswith("\r") else raw for raw in text.split("\n")]

    blocks = []
    paragraph = []
    items = []
    quote_lines = []

    def flush_paragraph():
        if paragraph:
            blocks.append({"type": "paragraph", "text": "\n".join(paragraph)})
            paragraph.clear()

    def flush_list():
        if items:
            blocks.append({"type": "list", "items": list(items)})
            items.clear()

    def flush_quote():
        if quote_lines:
            blocks.append({"type": "quote", "text": "\n".join(quote_lines)})
            quote_lines.clear()

    def flush_all():
        flush_paragraph()
        flush_list()
        flush_quote()

    index = 0
    while index < len(lines):
        line = lines[index]
        trimmed = line.strip()

        if not trimmed:
            flush_all()
            index += 1
            continue

        # 1) 围栏代码块
        if trimmed.startswith("```"):
            flush_all()
            info = trimmed[3:].strip()
            parts = [part for part in re.split(r"[ \t]+", info) if part]
            language = parts[0] if parts else ""
            body = []
            index += 1
            while index < len(lines):
                inner = lines[index].strip()
                if inner.startswith("```") and all(ch in " \t" for ch in inner[3:]):
                    index += 1
                    break
                body.append(lines[index])
                index += 1
            code = "\n".join(body).strip("\n")
            blocks.append({"type": "code", "language": language, "body": code})
            continue

        # 2) ATX 标题
        match = MD_HEADING_RE.match(line)
        if match:
            flush_all()
            blocks.append({
                "type": "heading",
                "level": len(match.group(1)),
                "text": match.group(2),
            })
            index += 1
            continue

        # 3) 分隔线
        if MD_RULE_RE.match(trimmed):
            flush_all()
            blocks.append({"type": "rule"})
            index += 1
            continue

        # 4) 引用
        match = MD_QUOTE_RE.match(line)
        if match:
            flush_paragraph()
            flush_list()
            content = match.group(1)
            if content.startswith(" "):
                content = content[1:]
            quote_lines.append(content)
            index += 1
            continue
        flush_quote()

        # 5) 表格：表头以 | 开头，且下一行是分隔行
        if (trimmed.startswith("|")
                and index + 1 < len(lines)
                and _md_is_table_separator(lines[index + 1])):
            flush_all()
            header = _md_table_cells(trimmed)
            index += 2
            rows = []
            while index < len(lines) and "|" in lines[index]:
                rows.append(_md_table_cells(lines[index].strip()))
                index += 1
            width = len(header)
            normalized = []
            for row in rows:
                if len(row) >= width:
                    normalized.append(row[:width])
                else:
                    normalized.append(row + [""] * (width - len(row)))
            blocks.append({"type": "table", "header": header, "rows": normalized})
            continue

        # 6) 列表项（有序号连排时重编：源码「1. 1. 1.」→ 1、2、3）
        match = MD_LIST_ITEM_RE.match(line)
        if match:
            flush_paragraph()
            indent, marker, item_text = match.group(1), match.group(2), match.group(3)
            level = min(sum(4 if ch == "\t" else 1 for ch in indent) // 2, 3)
            number = int(marker[:-1]) if marker[0].isdigit() else None
            if number is not None and items and items[-1]["number"] is not None:
                number = items[-1]["number"] + 1
            items.append({"level": level, "number": number, "text": item_text})
            index += 1
            continue

        # 7) 列表续行：列表开着 + 有缩进 → 并进最后一项（只吃缩进行）
        if items and (line.startswith(" ") or line.startswith("\t")):
            flush_paragraph()
            previous = items.pop()
            items.append({
                "level": previous["level"],
                "number": previous["number"],
                "text": previous["text"] + "\n" + line,
            })
            index += 1
            continue

        # 8) 顶格新行断开列表
        flush_list()

        # 9) 段落
        paragraph.append(line)
        index += 1

    flush_all()
    return blocks


# --------------------------------------------------------------------------
# 镜像 17：模型榜页面解析（LeaderboardParser）
# --------------------------------------------------------------------------
# 与 Swift `LeaderboardParser` 对应（规则 4：Swift 是权威）。榜单没有公开 JSON
# 接口，数据只在 SSR HTML 里；三份夹具（综合榜/编程榜/详情页）两边都读。
# 行/字段的锚点与 Swift 版一致：data-slug、可见文案、详情页字段级 class 锚。

LB_ROW_RE = re.compile(r'<tr data-slug="([^"]+)"[^>]*>(.*?)</tr>', re.S)
LB_MAIN_RE = re.compile(r"<main[^>]*>(.*?)</main>", re.S)
LB_CATEGORY_HEADINGS = ("编程", "科研", "专业办公", "知识问答", "真人盲选")
LB_HEADING_TO_CATEGORY = {
    "编程": "coding",
    "科研": "reasoning",
    "专业办公": "professional",
    "知识问答": "knowledge",
}


def lb_collapse_spaces(text):
    return re.sub(r"\s+", " ", text)


def lb_main(html):
    match = LB_MAIN_RE.search(html)
    return match.group(1) if match else html


def lb_parse_row(slug, row_html):
    link = re.search(r"<a[^>]*>(.*?)</a>", row_html, re.S)
    if not link:
        return None
    name = lb_collapse_spaces(plain_text(link.group(1)).strip())
    if not name:
        return None

    lines = [line.strip() for line in plain_text(row_html).split("\n") if line.strip()]
    if not lines:
        return None
    try:
        rank = int(lines[0])
    except ValueError:
        return None
    if not 1 <= rank <= 99:
        return None

    released = eval_count = coverage = None
    prices = []
    score = None
    for line in lines:
        if released is None and re.fullmatch(r"\d{4}-\d{2}-\d{2}", line):
            released = line
        if eval_count is None:
            m = re.search(r"(\d+) 项评测", line)
            if m:
                eval_count = int(m.group(1))
        if coverage is None:
            m = re.search(r"覆盖 (\d+) ?%", line)
            if m:
                coverage = int(m.group(1))
        if line.startswith("¥") and len(prices) < 3:
            prices.append(line)
        if score is None:
            m = re.match(r"^([\d.]+)  ?覆盖", line)
            if m:
                score = float(m.group(1))

    provider = None
    if len(lines) > 1:
        parts = [p.strip() for p in re.split(r" {2,}", lines[1]) if p.strip()]
        if parts and parts[0] == name and len(parts) > 1:
            provider = parts[1]

    return {
        "rank": rank,
        "slug": slug,
        "name": name,
        "provider": provider,
        "released": released,
        "eval_count": eval_count,
        "coverage": coverage,
        "cache_price": prices[0] if len(prices) > 0 else None,
        "input_price": prices[1] if len(prices) > 1 else None,
        "output_price": prices[2] if len(prices) > 2 else None,
        "score": score,
    }


def lb_parse_board(html, category):
    main = lb_main(html)
    models = []
    for match in LB_ROW_RE.finditer(main):
        model = lb_parse_row(match.group(1), match.group(2))
        if model is not None:
            models.append(model)
    if not models:
        return None

    text = plain_text(main)
    eval_total = institutions = updated = None
    header = re.search(r"(\d+) 项评测 · (\d+) 家机构 · (\d{1,2}/\d{1,2} \d{2}:\d{2}) 更新", text)
    if header:
        eval_total = int(header.group(1))
        institutions = int(header.group(2))
        updated = header.group(3)
    return {
        "category": category,
        "eval_total": eval_total,
        "institutions": institutions,
        "updated": updated,
        "models": models,
    }


def lb_parse_detail(html):
    main = lb_main(html)
    title = re.search(r"<h1[^>]*>(.*?)</h1>", main, re.S)
    if not title:
        return None
    name = lb_collapse_spaces(plain_text(title.group(1)).strip())
    if not name:
        return None

    text = plain_text(main)
    provider = released = updated = None
    meta = re.search(r"^([^\n·]+) · (\d{4}-\d{2}-\d{2}) 发布 · (\d{1,2}/\d{1,2} \d{2}:\d{2}) 更新$",
                     text, re.M)
    if meta:
        provider = meta.group(1).strip()
        released = meta.group(2) + " 发布"
        updated = meta.group(3)

    overall_score = overall_rank = coverage = None
    score_line = re.search(
        r"AIHOT 评分 · 综合\s+([\d.]+) 分\s+综合第 (\d+) 名[^\d]*评测覆盖 (\d+) ?%", text)
    if score_line:
        overall_score = float(score_line.group(1))
        overall_rank = int(score_line.group(2))
        coverage = int(score_line.group(3))

    context_window = None
    m = re.search(r"上下文窗口\s+(\S+ Token)", text)
    if m:
        context_window = m.group(1)

    input_price = output_price = cache_price = original_usd = None
    price = re.search(
        r"API 输入 / 输出 · 每百万 Token\s+(¥\S+) / (\S+)\s+缓存 (¥\S+)[^$]*原价 (.+?) 厂商官方价格",
        text)
    if price:
        input_price, output_price, cache_price, original_usd = price.groups()
        original_usd = original_usd.strip()

    cards = []
    for anchor in re.finditer(r'<a[^>]*href="/leaderboard/category/(\w+)"[^>]*>(.*?)</a>', main, re.S):
        body = plain_text(anchor.group(2))
        if "AIHOT 评分" not in body:
            continue
        m = re.search(r"AIHOT 评分\s+([\d.]+) 分\s+第 (\d+) 名\s+(\d+) 项评测 · 覆盖 (\d+) ?%", body)
        if not m:
            continue
        cards.append({
            "category": anchor.group(1),
            "score": float(m.group(1)),
            "rank": int(m.group(2)),
            "eval_count": int(m.group(3)),
            "coverage": int(m.group(4)),
        })

    groups = []
    marker = main.find("BEHIND THE SCORE")
    section = main[marker:] if marker >= 0 else ""
    tokens = re.finditer(
        r'(<h3[^>]*>.*?</h3>)|(<li class="card[^"]*"[^>]*>.*?</li>)', section, re.S)
    current = None
    for token in tokens:
        if token.group(1):
            heading_text = lb_collapse_spaces(plain_text(token.group(1)).strip())
            m = re.match(r"^(编程|科研|专业办公|知识问答|真人盲选) ([\d.]+) ?(\d+) 项$", heading_text)
            if not m:
                continue
            current = {
                "heading": m.group(1),
                "category": LB_HEADING_TO_CATEGORY.get(m.group(1)),
                "score": float(m.group(2)),
                "eval_count": int(m.group(3)),
                "items": [],
            }
            groups.append(current)
            continue
        if current is None:
            continue
        raw = token.group(2)
        name_m = re.search(r'text-\[13\.5px\] font-semibold text-ink">([^<]+)</span>', raw)
        if not name_m:
            continue
        benchmark_name = lb_collapse_spaces(plain_text(name_m.group(1)).strip())

        source = None
        source_m = re.search(r'<small class="text-\[11px\] text-ink-4">(.*?)</small>', raw, re.S)
        if source_m:
            value = lb_collapse_spaces(plain_text(source_m.group(1)).strip())
            source = value or None

        score_text = None
        score_m = re.search(
            r'mono block text-\[19px\] font-medium leading-tight text-ink">([^<]+)</span>', raw)
        if score_m:
            score_text = score_m.group(1).strip() or None

        converted = None
        converted_m = re.search(r"折算分(.*?)</span></span>", raw, re.S)
        if converted_m:
            value = lb_collapse_spaces(plain_text(converted_m.group(1)).strip())
            converted = value or None

        current["items"].append({
            "name": benchmark_name,
            "source": source,
            "score_text": score_text,
            "converted": converted,
        })

    return {
        "name": name,
        "provider": provider,
        "released": released,
        "updated": updated,
        "overall_score": overall_score,
        "overall_rank": overall_rank,
        "coverage": coverage,
        "context_window": context_window,
        "input_price": input_price,
        "output_price": output_price,
        "cache_price": cache_price,
        "original_usd": original_usd,
        "cards": cards,
        "groups": groups,
    }


# --------------------------------------------------------------------------
# 镜像 18：周报/月报的期号、区间与往期分组（ReportPeriod）
# --------------------------------------------------------------------------
# 与 Swift `ReportPeriod` 对应（规则 4：Swift 是权威）。日期只做 yyyy-MM-dd 的
# 字符串切分，不构造日期对象 —— 与 Swift 同一信条：不引入日历/时区依赖。

REPORT_WEEK_KEY_RE = re.compile(r"^(\d{4})-W(\d{1,2})$")
REPORT_MONTH_KEY_RE = re.compile(r"^(\d{4})-(\d{2})$")
REPORT_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")


def report_title(period_key):
    match = REPORT_WEEK_KEY_RE.match(period_key)
    if match:
        week = int(match.group(2))
        if 1 <= week <= 53:
            return "%s 年第 %d 周" % (match.group(1), week)
    match = REPORT_MONTH_KEY_RE.match(period_key)
    if match:
        month = int(match.group(2))
        if 1 <= month <= 12:
            return "%s 年 %d 月" % (match.group(1), month)
    return None


def report_date_parts(text):
    match = REPORT_DATE_RE.match(text)
    if not match:
        return None
    year, month, day = match.group(1), match.group(2), match.group(3)
    if not (1 <= int(month) <= 12) or not (1 <= int(day) <= 31):
        return None
    return {"full": "%s.%s.%s" % (year, month, day),
            "month_day": "%s.%s" % (month, day), "year": year}


def report_range_text(start, end):
    if start is None or end is None:
        return None
    s = report_date_parts(start)
    e = report_date_parts(end)
    if s is None or e is None:
        return None
    if s["year"] == e["year"]:
        return "%s – %s" % (s["month_day"], e["month_day"])
    return "%s – %s" % (s["full"], e["full"])


def report_group_by_month(entries):
    order = []
    buckets = {}
    leftovers = []
    for entry in entries:
        start = entry.get("periodStart")
        parts = report_date_parts(start) if start is not None else None
        if parts is None:
            leftovers.append(entry)
            continue
        key = start[:7]                      # "2026-10"
        if key not in buckets:
            buckets[key] = []
            order.append(key)
        buckets[key].append(entry)

    groups = []
    for key in order:
        pieces = key.split("-")
        if len(pieces) == 2:
            title = "%s 年 %d 月" % (pieces[0], int(pieces[1]))
        else:
            title = "其它"
        groups.append({"title": title, "entries": buckets[key]})
    if leftovers:
        groups.append({"title": "其它", "entries": leftovers})
    return groups


# --------------------------------------------------------------------------
# 断言（全部以夹具为准）
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------


def fixture_text(name):
    with open(os.path.join(ROOT, "AIHOTTests", "Fixtures", name), "r", encoding="utf-8") as handle:
        return handle.read()


def fixture_bytes(name):
    with open(os.path.join(ROOT, "AIHOTTests", "Fixtures", name), "rb") as handle:
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

    # 切行：字节 → 行。空行是 SSE 分帧的**唯一**依据，所以这一组是承重的 ——
    # 原来这段归平台的 `AsyncSequence.lines` 管（空行怎么处理是它的实现细节），
    # 现在归自己的 SSELineSplitter。
    check_eq(split_lines(b"data: a\n\ndata: b\n\n"), ["data: a", "", "data: b", ""],
             "切行器不许吞空行（吞了整条流会被拼成一帧、一个事件都认不出来）")
    check_eq(split_lines(b"data: x"), ["data: x"], "末尾没有换行的那一行也要交出来")
    check_eq(split_lines(b""), [], "什么都不喂就不该产出幻影空行")
    check_eq(split_lines(b"\n"), [""], "单个换行就是一行空行")
    check_eq(split_lines(b"data: x\r\n\r\n"), ["data: x\r", "\r"], "CRLF 的 \\r 留给分帧器剥")

    for name, decoder in (("anthropic-sse.txt", anthropic_events),
                          ("openai-sse.txt", openai_events)):
        data = fixture_bytes(name)
        check_eq(run_stream_bytes(data, decoder), run_stream(data.decode("utf-8"), decoder),
                 "%s：按字节切行与按行喂必须得到同一轮" % name)
        # 夹具以单个换行结尾：按行切会多出一个幻影空行，切行器不产出它，帧本身不变。
        check_eq(split_lines(data) + [""], data.decode("utf-8").split("\n"),
                 "%s：切出来的行 = 夹具自己的行（只差结尾那个幻影空行）" % name)

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

    # 无效 key 的真实形状：HTTP 200 + result.isError，顶层没有 error。
    # 曾经漏查 isError，于是这段错误文案被当成搜索结果喂给了模型。
    bad_key = fixture_json("anysearch-error.json")
    check_eq((bad_key.get("result") or {}).get("isError"), True,
             "夹具钉住的无效 key 响应：HTTP 200，靠 result.isError 表示失败")
    check("error" not in bad_key, "这个形状里顶层没有 error —— 只查 error 的写法会漏掉它")
    raises(lambda: anysearch_result_text(bad_key),
           "无效 key 要抛错，不能把错误文案当搜索结果", "Key 无效")
    raises(lambda: anysearch_result_text(
        {"result": {"content": [{"type": "text", "text": "boom"}], "isError": True}}),
        "其它 isError 也要抛错并带原话", "boom")
    raises(lambda: anysearch_result_text(
        {"result": {"content": [], "isError": True}}),
        "isError 而且没给原因时也要抛错", "拒绝了")
    check_eq(anysearch_result_text(
        {"result": {"content": [{"type": "text", "text": "ok"}], "isError": False}}),
        "ok", "isError 明确为 false 时照常返回")

    print("")
    print("== 镜像 9：报道节奏（分桶 / 峰值 / 轴刻度）==")
    timeline_story = fixture_json("story-timeline.json")["story"]
    timeline = report_timeline(timeline_story)
    check(timeline is not None, "夹具应当能画出节奏图")
    if timeline:
        check_eq(timeline["interval"], "hour", "10 小时跨度走「1 小时」档")
        check_eq([bucket["label"] for bucket in timeline["buckets"]],
                 ["06:00", "07:00", "08:00", "09:00", "10:00", "11:00", "12:00", "13:00", "14:00", "15:00"],
                 "桶是逐小时连续的")
        check_eq([bucket["count"] for bucket in timeline["buckets"]], [2, 2, 2, 0, 0, 0, 3, 2, 1, 2], "每桶报道数")
        check_eq([bucket["label"] for bucket in timeline["buckets"] if bucket["count"] == 0],
                 ["09:00", "10:00", "11:00"], "断档那几小时的 0 值桶要留着，不能被删掉")
        check_eq(len({bucket["label"] for bucket in timeline["buckets"]}), len(timeline["buckets"]),
                 "标签不能重复（x 轴按标签分类，重名会被合并成一根柱子）")
        check_eq(timeline["peak"]["label"], "12:00", "峰值桶")
        check_eq(timeline["peak"]["count"], 3, "峰值条数")
        check_eq(len([bucket for bucket in timeline["buckets"] if bucket["is_peak"]]), 1, "并列时只标最早的一个")
        check_eq([bucket["label"] for bucket in timeline["buckets"] if bucket["is_newest"]],
                 ["15:00"], "只有最新那一桶是 isNewest")
        check_eq(timeline["total_timestamped"], 14, "没有 publishedAt 的那条不进图")
        check_eq(sum(bucket["count"] for bucket in timeline["buckets"]), 14, "桶里加起来等于有时间的条数")
        check_eq(timeline["last_24_hour_count"], 14, "整条流只跨 10 小时，都在最新一条之后 24 小时内")
        check_eq(timeline["axis_labels"], ["06:00", "08:00", "10:00", "12:00", "15:00"], "轴刻度均匀且含首尾")
        check_eq(timeline["truncated"], True, "接口说 43 条、图上只有 14 条：要说明被截断")

    check(report_timeline({}) is None, "没有任何报道：不画")
    check(report_timeline({"reports": [{"publishedAt": "2026-10-12T00:00:00.000Z"}]}) is None,
          "只有 1 条有时间的报道：不画（一根柱子没有可比性）")
    check(report_timeline({"reports": [{"publishedAt": None}]}) is None, "有报道但都没有时间：不画")
    check(report_timeline({"reports": [
        {"publishedAt": "2026-10-12T03:00:00.000Z"},
        {"publishedAt": "2026-10-12T03:05:00.000Z"},
    ]}) is None, "两条落在同一个 15 分钟桶里：画不出节奏，不画")

    # 15 分钟这一档（夹具走的是「1 小时」，这里补上）
    quarter = report_timeline({"reports": [
        {"publishedAt": "2026-10-12T00:05:00.000Z"},
        {"publishedAt": "2026-10-12T00:20:00.000Z"},
        {"publishedAt": "2026-10-12T00:35:00.000Z"},
    ]})
    check(quarter is not None, "半小时内的三条也能画")
    if quarter:
        check_eq(quarter["interval"], "15m", "半小时跨度走「15 分钟」档")
        check_eq([bucket["label"] for bucket in quarter["buckets"]], ["08:00", "08:15", "08:30"],
                 "对齐到 15 分钟边界（北京时间）")
        check_eq([bucket["count"] for bucket in quarter["buckets"]], [1, 1, 1], "每桶一条")
        check_eq(quarter["peak"]["label"], "08:00", "三个桶并列时峰值取最早")

    # 跨度大要降档。用的是 2020 年的数据：实现里一旦读了「当前时间」，这里就会退化成空窗口。
    daily = report_timeline({"reports": [
        {"publishedAt": "2020-01-01T00:00:00.000Z"},
        {"publishedAt": "2020-01-02T16:00:00.000Z"},
        {"publishedAt": "2020-01-04T08:00:00.000Z"},
    ]})
    check(daily is not None, "跨多天也要能画")
    if daily:
        check_eq(daily["interval"], "day", "跨度大就降档到「每天」")
        check_eq([bucket["label"] for bucket in daily["buckets"]],
                 ["1月1日", "1月2日", "1月3日", "1月4日"], "按北京时间的「天」切")
        check_eq([bucket["count"] for bucket in daily["buckets"]], [1, 0, 1, 1], "没报道的那天留着空桶")
        check_eq(daily["peak"]["label"], "1月1日", "并列取最早")
        check_eq(daily["last_24_hour_count"], 1, "只有最后一条在最新一条之后 24 小时内")
        check_eq(daily["axis_labels"], ["1月1日", "1月2日", "1月3日", "1月4日"], "不足 5 个刻度就全显示")

    print("")
    print("== 镜像 10：跨轮历史（AIChatModel.history）==")
    check_eq(chat_history([]), [], "还没说话时历史是空的")
    check_eq(chat_history([("user", "为什么火？")]), [("user", "为什么火？")],
             "第一轮就带这一句问题")
    check_eq(chat_history([("user", "为什么火？"), ("assistant", "被多人转引。"), ("user", "还有后续吗？")]),
             [("user", "为什么火？"), ("assistant", "被多人转引。"), ("user", "还有后续吗？")],
             "第二问带上了第一问和第一答，顺序与角色都不变")
    check_eq(chat_history([("user", "为什么火？"), ("assistant", ""), ("user", "再试一次")]),
             [("user", "为什么火？"), ("user", "再试一次")],
             "一个字都没有的消息要剔除，前后内容一条不少")
    check_eq(chat_history([("user", "为什么火？"), ("user", "再试一次")]),
             [("user", "为什么火？"), ("user", "再试一次")],
             "一轮什么都没产出时是一对连续的 user 消息，两条都要留（按角色去重会丢掉用户的问题）")

    # 纯追加：第 N 轮的历史必须以第 N-1 轮为前缀 —— 提示词缓存前缀能活过整场对话的前提。
    history_first = chat_history([("user", "a")])
    history_second = chat_history([("user", "a"), ("assistant", "b"), ("user", "c")])
    history_third = chat_history(history_second + [("assistant", "d"), ("user", "e")])
    check_eq(history_second[:len(history_first)], history_first, "第二轮的历史以第一轮为前缀")
    check_eq(history_third[:len(history_second)], history_second, "第三轮的历史以第二轮为前缀")
    check_eq(len(history_third), 5, "纯追加，长度正好是 5")

    print("")
    print("== 镜像 11：失败原因（AIChatModel.truncationNotice）==")
    # 这一条全线都是「用错协议」的复现：把一家的流喂给另一家的解码器，一个事件都认不出来。
    # 真机上这就是「没有任何回复 + 连接提前中断」。夹具用的是同一份夹具文件，
    # 与 AIChatModelTests 里那两条用例读的是同样的字节。
    cross_anthropic = scan_stream(fixture_text("anthropic-sse.txt"), "openai")
    cross_openai = scan_stream(fixture_text("openai-sse.txt"), "anthropic")

    check_eq(cross_anthropic["recognized"], 0, "Anthropic 的帧不该被 OpenAI 兼容的解码器认出来")
    check_eq(cross_openai["recognized"], 0, "OpenAI 兼容的帧不该被 Anthropic 的解码器认出来")

    # 承重的一条：留下的原文必须**足够选出正确的那条协议**，否则这句提示就是白说。
    check(any(PROTOCOL_DECODERS["anthropic"]({"event": None, "data": s})
              for s in cross_anthropic["samples"]),
          "Anthropic 的样本里要有一段能被 Anthropic 解码器认出（否则点不出名）")
    check(any(PROTOCOL_DECODERS["openai"]({"event": None, "data": s})
              for s in cross_openai["samples"]),
          "OpenAI 兼容的样本里要有一段能被 OpenAI 兼容解码器认出")

    notice = truncation_notice(cross_anthropic["frames"], cross_anthropic["recognized"],
                               None, cross_anthropic["samples"], False, "openai")
    check("Anthropic" in notice, "选错了协议要点名该换成哪条：" + notice)
    check("连接提前中断" not in notice, "协议错配不该说成「连接提前中断」")

    notice = truncation_notice(cross_openai["frames"], cross_openai["recognized"],
                               None, cross_openai["samples"], False, "anthropic")
    check("OpenAI 兼容" in notice, "反方向同样要点名：" + notice)
    check("连接提前中断" not in notice, "反方向也不该说成「连接提前中断」")

    # 三条兜底分支：各说各的，都不许再说「连接提前中断」。
    notice = truncation_notice(0, 0, None, [], False, "openai")
    check_eq(notice, "接口没有返回任何内容，请稍后重试。", "一帧一行都没有 → 直说没内容")

    notice = truncation_notice(0, 0, "<!DOCTYPE html><html>…", [], False, "openai")
    check("<!DOCTYPE html>" in notice and "不是流式" in notice,
          "回的不是 SSE（有些中转站谎报 Content-Type）→ 把开头原文贴出来：" + notice)
    check("连接提前中断" not in notice, "非 SSE 不该说成「连接提前中断」")

    notice = truncation_notice(3, 0, None, ['{"hello":"world"}'], False, "openai")
    check('{"hello":"world"}' in notice, "两条协议都认不出来时也要贴出原文：" + notice)
    check("共切出 3 帧" in notice, "帧数要带上：光看开头分不清「拼成一帧」和「多帧都不认识」：" + notice)
    check("连接提前中断" not in notice, "认不出来 ≠ 连接中断")

    # 留了好几段样本时头尾都要贴：只贴第一段，看到的永远是那一帧本来就认不出来的
    # 「结构帧」（role 分片），等于什么都没说。
    notice = truncation_notice(
        12, 0, None,
        ['{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}',
         '{"choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}'],
        False, "openai")
    check("共切出 12 帧" in notice, "帧数：" + notice)
    check('"role":"assistant"' in notice, "开头那段：" + notice)
    check("最后一段是" in notice and '{"index":0,"delta":{"content":""}' in notice,
          "结尾那段（往往才是关键）：" + notice)

    notice = truncation_notice(4, 3, None, [], False, "openai")
    check("还没给出回复" in notice, "只收到思考块就断了 → 根本没有「回复」可谈：" + notice)

    # 真有正文、只是收尾标记没来：这句老话是给这种情况留的，别一起删掉。
    check_eq(truncation_notice(12, 12, None, [], True, "openai"),
             "连接提前中断，回复可能不完整。",
             "有正文、只是收尾标记没来 → 保留原话")

    print("")
    print("== 镜像 12：Tavily 响应解析 ==")
    # 两份夹具都是真抓的 200 响应；断言从抓到的字节推导（查询词、条数、trim 后长度）。
    tavily_search = fixture_json("tavily-search.json")
    check_eq(tavily_search.get("query"), "Karpathy 认知鸿沟", "夹具里的查询词")
    check_eq(len(tavily_search.get("results") or []), 5, "抓到 5 条结果")
    search_text = tavily_search_text(tavily_search)
    check(search_text.startswith("### 1. Karpathy 主帖"), "第 1 条标题进 Markdown")
    check("https://www.cnblogs.com/gyc567/p/19848269" in search_text, "条目里带 URL")
    check("### 5. 75%人口未接触LLM" in search_text, "抓到的最后一条")
    check(not search_text.startswith(">"), "answer 是 null，不该出现引用块")

    # answer 非空时前置引用块（夹具里是 null，合成体钉格式）
    check(tavily_search_text(
        {"answer": "一句话结论", "results": [{"title": "T", "url": "https://e.com", "content": "C"}]}
    ).startswith("> 一句话结论"), "answer 非空 → 引用块前置")

    tavily_extract = fixture_json("tavily-extract.json")
    check_eq(tavily_extract.get("failed_results"), [], "夹具里没有失败条目")
    check_eq(len(tavily_extract.get("results") or []), 1, "extract 抓的是单个页面")
    extract_text = tavily_extract_text(tavily_extract)
    check(extract_text.startswith("[# karpathy](/)"), "raw_content 本身是 Markdown，原样交给模型")
    # 夹具里 raw_content 是 11418 字、末尾带 3 个空白（…Strap in.\n\n ），
    # strip 之后 11415 —— 与 Swift 测试里的 count 断言同一个数。
    check_eq(len(extract_text), 11415, "trim 之后的长度（11418 会红，尾部有 3 个空白）")

    # 非空 failed_results 必须抛（HTTP 200 也可能部分失败 —— Tavily 版的 isError 陷阱）
    raises(lambda: tavily_extract_text(
        {"results": [{"url": "https://ok.com", "raw_content": "正文"}],
         "failed_results": [{"url": "https://bad.com", "error": "fetch failed"}]}),
        "failed_results 非空要抛错并带原话（连同成功结果一起也抛）", "fetch failed")
    raises(lambda: tavily_extract_text(
        {"results": [], "failed_results": [{"url": "https://bad.com"}]}),
        "认不出原因也要点名页面", "bad.com")

    raises(lambda: tavily_search_text({"query": "x", "results": [], "answer": None}),
           "零结果要抛错，而不是回空串", "没有返回可用内容")
    raises(lambda: tavily_extract_text({"results": [], "failed_results": []}),
           "extract 零结果同样抛错")
    raises(lambda: tavily_search_text("not json"), "非对象（解码失败）要抛错")
    raises(lambda: tavily_extract_text("not json"), "extract 同样")

    print("")
    print("== 镜像 13：对话会话封顶（ChatHistoryStore.trim）==")
    # 55 条合成数据 → 恰好留 50，淘汰最旧的 5 条。
    # 方向钉死：误淘汰最新会**静默丢掉用户刚问完的对话**，而且没人会报错。
    synth = [{"key": "key-%02d" % i, "updated_at": i} for i in range(55)]
    trimmed = trim_sessions(synth)
    check_eq(len(trimmed), 50, "封顶 50 条")
    check_eq([s["key"] for s in trimmed],
             ["key-%02d" % i for i in range(5, 55)],
             "淘汰最旧的 5 条（数组头部），保留的顺序不变")
    check_eq(trim_sessions(synth[:50]), synth[:50],
             "恰好 50 条时原样返回，不重排")
    check(trim_sessions([]) == [], "空的照样是空的")

    print("")
    print("== 镜像 14：SerpAPI / Serper / Exa 响应解析 ==")
    # 四份成功夹具 + 三份错误夹具都是真抓的字节；断言全部从字节推导。
    # `raises` 是镜像 8 处定义的闭包（ValueError + 可选原话），这里继续用。

    serpapi_search = fixture_json("serpapi-search.json")
    sp_organic = serpapi_search.get("organic_results") or []
    check_eq(len(sp_organic), 9, "SerpAPI 夹具抓到 9 条 organic_results")
    check_eq(sum(1 for item in sp_organic if item.get("snippet")), 7,
             "其中 7 条有 snippet（2 条容缺）")
    sp_text = serpapi_search_text(serpapi_search)
    check(sp_text.startswith("### 1. https://news.qq.com/rain/a/20251209A04T2S00"),
          "第 1 条 title==link，直接当标题")
    check_eq(sp_text.count("https://news.qq.com/rain/a/20251209A04T2S00"), 1,
             "title 就是链接时只出现一次（不标题一行再加链接一行）")
    check("### 3. Karpathy：80 亿人被AI 认知鸿沟分成四个层级" in sp_text, "第 3 条标题")
    check("No information is available for this page." in sp_text, "第 2 条抓到的 snippet 原文")
    check_eq(sp_text.count("### "), 9, "9 条一条不能丢（含 2 条没 snippet 的）")
    # 200 带顶层 error 的分支没有免费触发的办法（合成）
    raises(lambda: serpapi_search_text(
        {"error": "Your account has run out of searches.", "organic_results": []}),
        "200 带顶层 error 要抛错并带原话", "run out of searches")
    raises(lambda: serpapi_search_text({"organic_results": []}),
           "零结果要抛错，而不是回空串", "没有返回可用内容")
    raises(lambda: serpapi_search_text("not json"), "非对象要抛错")

    serper_search = fixture_json("serper-search.json")
    sr_organic = serper_search.get("organic") or []
    check_eq(len(sr_organic), 10, "Serper 夹具抓到 10 条 organic")
    check_eq(sum(1 for item in sr_organic if item.get("snippet")), 10, "10 条全有 snippet")
    sr_text = serper_search_text(serper_search)
    check(sr_text.startswith("### 1. Berryxia.AI on X"), "第 1 条标题")
    check("认知鸿沟一次性说透" in sr_text, "第 1 条抓到的 snippet 原文")
    check("### 10. Karpathy：LLM 能力认知鸿沟正扩大为漏斗" in sr_text, "最后一条（第 10 条）")
    check_eq(sr_text.count("### "), 10, "10 条一条不能丢")
    check("6 months ago" not in sr_text,
          "`date` 字段（真值 '6 months ago'）不解析、不进输出")
    # 防御分支（200 带报错的形状没抓过，合成）
    raises(lambda: serper_search_text(
        {"error": "quota exceeded", "organic": []}),
        "200 带顶层 error 要抛错并带原话", "quota exceeded")
    raises(lambda: serper_search_text(
        {"organic": [], "message": "insufficient credits"}),
        "零条时 message 比「没有内容」更能说明原因", "insufficient credits")
    raises(lambda: serper_search_text({"organic": []}),
           "零结果要抛错", "没有返回可用内容")
    raises(lambda: serper_search_text("not json"), "非对象要抛错")

    exa_search = fixture_json("exa-search.json")
    ex_results = exa_search.get("results") or []
    check_eq(len(ex_results), 5, "Exa 搜索夹具抓到 5 条 results")
    check_eq([len(item.get("text") or "") for item in ex_results], [500] * 5,
             "maxCharacters: 500 实测生效：每条 text 恰 500 字")
    ex_text = exa_search_text(exa_search)
    check(ex_text.startswith("### 1. Karpathy 主帖：从我的时间线来看"), "第 1 条标题")
    check("https://www.cnblogs.com/gyc567/p/19848269" in ex_text, "条目里带 URL")
    check("第一部分" in ex_text, "第 1 条抓到的 text 原文")
    check("### 5. Karpathy：对 LLM 能力的共识" in ex_text, "最后一条（第 5 条）")
    check_eq(ex_text.count("### "), 5, "5 条一条不能丢")
    raises(lambda: exa_search_text(
        {"error": "billing issue", "results": [{"title": "T"}]}),
        "200 带顶层 error 要抛错（合成）", "billing issue")
    raises(lambda: exa_search_text({"results": []}),
           "零结果要抛错", "没有返回可用内容")
    raises(lambda: exa_search_text("not json"), "非对象要抛错")

    exa_contents = fixture_json("exa-contents.json")
    check_eq(len(exa_contents.get("results") or []), 1, "读网页夹具是单个页面")
    check_eq(exa_contents.get("statuses"),
             [{"id": "https://karpathy.bearblog.dev/year-in-review-2025/",
               "status": "success", "source": "cached"}],
             "statuses 全 success（id 就是 URL）—— 不该触发提取失败")
    ct_text = exa_contents_text(exa_contents)
    check(ct_text.startswith("2025 LLM Year in Review – karpathy"),
          "正文原样返回，不套标题块")
    check(ct_text.endswith("Strap in."), "抓到的正文结尾")
    check_eq(len(ct_text), 10689,
             "请求了 8000、实测回了 10689 —— 从字节推导（clamp 在 Swift 侧兜底）")
    # statuses 失败分支没有免费触发的办法（合成）—— Tavily failed_results 的同款陷阱
    raises(lambda: exa_contents_text(
        {"results": [{"url": "https://ok.com", "text": "正文"}],
         "statuses": [{"id": "https://bad.com", "status": "failure"}]}),
        "HTTP 200 有失败 statuses 要抛错并点名页面", "bad.com")
    raises(lambda: exa_contents_text(
        {"results": [{"url": "https://ok.com", "text": "正文"}],
         "statuses": [{"id": "https://bad.com", "status": "failure", "error": "fetch failed"}]}),
        "有原话优先用原话", "fetch failed")
    raises(lambda: exa_contents_text({"results": [], "statuses": []}),
           "没正文要抛错", "没有返回可用内容")
    raises(lambda: exa_contents_text("not json"), "非对象要抛错")

    # 三份错误夹具的形状与详情提取（文案本身由 Swift 测试钉；镜像只钉形状与提取）
    sp_error = fixture_json("serpapi-error.json")
    check_eq(sorted(sp_error.keys()), ["error"], "SerpAPI 错误体是单字段 error")
    check((serpapi_top_error(sp_error) or "").startswith("Invalid API key."),
          "单字段原话提取得到完整一句")
    check("api_key=" not in (serpapi_top_error(sp_error) or ""),
          "原话本身不含查询串片段 —— 带出原话不等于带出 Key")
    sr_error = fixture_json("serper-error.json")
    check_eq(sr_error, {"message": "Unauthorized.", "statusCode": 403},
             "Serper 错误体：文档不可达，形状全靠错 Key 探针抓的这 44 字节")
    check_eq(serper_error_detail(sr_error), "Unauthorized.",
             "顶层 message 提取（problemMessage 认得的形状）")
    ex_error = fixture_json("exa-error.json")
    check_eq(sorted(ex_error.keys()), ["error", "requestId", "tag"],
             "Exa 错误信封三件套")
    check((exa_top_error(ex_error) or "").startswith("Invalid API key."),
          "信封里 error 是字符串，直接提取")
    check_eq(ex_error.get("tag"), "INVALID_API_KEY",
             "tag 是诊断信息，不参与状态码分支")
    check_eq(serper_error_detail({"error": {"message": "嵌套信封"}}), "嵌套信封",
             "problemMessage 式的信封优先（合成）")

    print("")
    print("== 镜像 15：搜索工具的顺序规范化与回退选择 ==")
    # 规范化（与 AppSettings 的两个纯函数对应）
    check_eq(normalize_search_order(None, "tavily"),
             ["tavily", "anySearch", "serpapi", "exa", "serper"],
             "升级首启：旧单选值排第一，其余按声明顺序补齐")
    check_eq(normalize_search_order(None, None), SEARCH_PROVIDERS, "没旧值就是规范顺序")
    check_eq(normalize_search_order(None, "bogus"), SEARCH_PROVIDERS,
             "旧值非法（将来枚举变了）也退回规范顺序")
    check_eq(normalize_search_order(["serper", "anySearch", "bogus", "serper"], "tavily"),
             ["serper", "anySearch", "tavily", "serpapi", "exa"],
             "丢未知、首次出现去重、缺的追加到末尾；legacy 只在 stored 为 nil 时才看")
    check_eq(normalize_search_order([], "tavily"), SEARCH_PROVIDERS,
             "空数组自愈为规范顺序，不读旧键")
    check_eq(normalize_disabled(None), set(), "没动过开关 = 全启用")
    check_eq(normalize_disabled(["serpapi", "bogus", "serpapi"]), {"serpapi"},
             "丢未知、去重")

    # 回退选择（与 SearchToolChain.eligibleProviders 对应）
    full_keys = {"tavily": "k", "serpapi": "k", "exa": "k", "serper": "k"}
    check_eq(eligible_providers(SEARCH_PROVIDERS, set(), full_keys, "web_search"),
             SEARCH_PROVIDERS, "全启用、Key 都填了：五家全上、保持用户顺序")
    check_eq(eligible_providers(SEARCH_PROVIDERS, set(), full_keys, "read_url"),
             ["anySearch", "tavily", "exa"],
             "read_url 自动跳过只搜索的两家（能力矩阵 ✗）")
    check_eq(eligible_providers(SEARCH_PROVIDERS, {"serper"}, full_keys, "web_search"),
             ["anySearch", "tavily", "serpapi", "exa"], "停用的跳过")
    check_eq(eligible_providers(["serpapi", "anySearch"], set(), {"serpapi": "   "}, "web_search"),
             ["anySearch"], "必填 Key 是空白 = 没填 = 不参与")
    check_eq(eligible_providers(["anySearch"], set(), {}, "web_search"),
             ["anySearch"], "AnySearch 空 Key 保留（匿名合法，不能被必填过滤误杀）")
    check_eq(eligible_providers(SEARCH_PROVIDERS, set(SEARCH_PROVIDERS), full_keys, "web_search"),
             [], "全停用 → 一个可试的家都没有（走「没有可用的搜索工具」）")
    check_eq(eligible_providers(["serpapi", "serper"], set(), full_keys, "read_url"),
             [], "只剩只搜索的家时 read_url 无解（走「没有能读网页的工具」）")

    print("")
    print("== 镜像 16：回答的 Markdown 分块（MarkdownBlocks.parse）==")
    md = fixture_text("chat-markdown.md")
    blocks = markdown_blocks(md)
    check_eq(len(blocks), 9, "夹具切出 9 块")
    check_eq(blocks[0], {"type": "heading", "level": 2, "text": "这条为什么火"}, "H2 标题")
    check_eq(blocks[1],
             {"type": "paragraph", "text": "先看**三个信号**，再看 `热度指数` 的变化："},
             "段落：行内标记原样保留")
    list_one = blocks[2]
    check_eq(list_one["type"], "list", "无序列表块")
    check_eq(len(list_one["items"]), 4, "四个列表项（含一个嵌套）")
    check_eq([item["level"] for item in list_one["items"]], [0, 0, 1, 0], "嵌套项缩进层级")
    check(all(item["number"] is None for item in list_one["items"]), "无序项没有序号")
    check_eq(list_one["items"][0]["text"], "厂商放出了[实测数据](https://example.com/demo)",
             "行内链接原样保留")
    list_two = blocks[3]
    check_eq([item["number"] for item in list_two["items"]], [1, 2, 3],
             "三个「1.」连排重编成 1、2、3")
    code = blocks[4]
    check_eq(code["language"], "python", "代码块语言")
    check_eq(code["body"],
             "def heat(rank):\n    # 没有热度指数时退回参与者数\n    return rank or 0",
             "代码块正文逐行保留（含缩进与注释行）")
    check_eq(blocks[5],
             {"type": "quote", "text": "引用一段：热度按 60 秒缓存，**不重复请求**。"},
             "引用剥掉 >")
    check_eq(blocks[6], {"type": "rule"}, "分隔线")
    check_eq(blocks[7]["header"], ["来源", "参与者", "走向"], "表头三列")
    check_eq(len(blocks[7]["rows"]), 2, "表格两行数据")
    check_eq(blocks[7]["rows"][0], ["官方博客", "12", "↑"], "第一行数据")
    check_eq(blocks[8],
             {"type": "paragraph", "text": "结论：**别只看名次**，报道节奏更诚实。"},
             "收尾段落")

    # 边界（字面输入，期望即字面推导）
    check_eq(markdown_blocks("```swift\nlet a = 1"),
             [{"type": "code", "language": "swift", "body": "let a = 1"}],
             "没闭合的围栏算到文末（回答被截断时不吞正文）")
    check_eq(markdown_blocks("#标题"), [{"type": "paragraph", "text": "#标题"}],
             "# 后没空格不是标题")
    check_eq(markdown_blocks("> 甲\n>\n> 乙"),
             [{"type": "quote", "text": "甲\n\n乙"}], "连续引用合并、空引用行保留")
    check_eq(markdown_blocks("a | b\n---"),
             [{"type": "paragraph", "text": "a | b"}, {"type": "rule"}],
             "没有前导 | 的「a | b」+「---」不是表格")
    check_eq(markdown_blocks(""), [], "空文没有块")

    print("")
    print("== 镜像 17：模型榜页面解析（LeaderboardParser）==")
    # 断言全部从三份夹具字节推导（与 AIHOTTests/LeaderboardParserTests.swift 一致）。
    board = lb_parse_board(fixture_text("leaderboard-overall.html"), "overall")
    check(board is not None, "综合榜解析成功")
    if board:
        check_eq(len(board["models"]), 30, "综合榜 30 行")
        check_eq(board["eval_total"], 35, "页头 35 项评测")
        check_eq(board["institutions"], 7, "页头 7 家机构")
        check_eq(board["updated"], "10/20 09:12", "页头更新时间")
        first = board["models"][0]
        check_eq(first["rank"], 1, "首行名次 1")
        check_eq(first["slug"], "claude-opus-5-5", "首行 slug")
        check_eq(first["name"], "Claude Opus 5.5", "首行模型名")
        check_eq(first["provider"], "Anthropic", "首行厂商")
        check_eq(first["released"], "2026-09-22", "首行上线日期")
        check_eq(first["eval_count"], 34, "首行 34 项评测")
        check_eq(first["coverage"], 96, "首行覆盖 96%")
        check_eq(first["cache_price"], "¥1.34", "首行缓存价")
        check_eq(first["input_price"], "¥26.72", "首行输入价")
        check_eq(first["output_price"], "¥133.61", "首行输出价")
        check_eq(first["score"], 73.8, "首行评分 73.8")
        last = board["models"][29]
        check_eq(last["rank"], 30, "末行名次 30")
        check_eq(last["slug"], "claude-sonnet-5", "末行 slug")
        check_eq(last["score"], 59.1, "末行评分 59.1")
        muse = next((m for m in board["models"] if m["slug"] == "muse-wonder-full"), None)
        check(muse is not None, "muse-wonder-full 在榜")
        if muse:
            # 页面上是「待核验」→ 三档价格都是 nil，不编数字
            check(muse["cache_price"] is None and muse["input_price"] is None
                  and muse["output_price"] is None, "待核验 → 三档价格全 nil")
            check_eq(muse["score"], 70.3, "待核验行仍有评分 70.3")

    coding = lb_parse_board(fixture_text("leaderboard-coding.html"), "coding")
    check(coding is not None, "编程榜解析成功")
    if coding:
        check_eq(len(coding["models"]), 30, "编程榜 30 行")
        check_eq(coding["eval_total"], 9, "编程榜页头 9 项评测")
        check_eq(coding["institutions"], 3, "编程榜页头 3 家机构")
        cfirst = coding["models"][0]
        check_eq(cfirst["slug"], "claude-opus-5-5", "编程榜首行 slug")
        check_eq(cfirst["eval_count"], 8, "编程榜首行 8 项评测")
        check_eq(cfirst["coverage"], 86, "编程榜首行覆盖 86%")
        check_eq(cfirst["score"], 74.3, "编程榜首行评分 74.3")
        check_eq(coding["models"][29]["slug"], "gpt-5-6-luna", "编程榜末行 slug")
        check_eq(coding["models"][29]["score"], 59.2, "编程榜末行评分 59.2")

    detail = lb_parse_detail(fixture_text("leaderboard-detail.html"))
    check(detail is not None, "详情页解析成功")
    if detail:
        check_eq(detail["name"], "Claude Opus 5.5", "详情 h1")
        check_eq(detail["provider"], "Anthropic", "详情厂商")
        check_eq(detail["released"], "2026-09-22 发布", "详情发布行")
        check_eq(detail["updated"], "10/20 09:12", "详情更新时间")
        check_eq(detail["overall_score"], 73.8, "综合评分 73.8")
        check_eq(detail["overall_rank"], 1, "综合第 1 名")
        check_eq(detail["coverage"], 96, "评测覆盖 96%")
        check_eq(detail["context_window"], "100万 Token", "上下文窗口原文")
        check_eq(detail["input_price"], "¥26.72", "详情输入价")
        check_eq(detail["output_price"], "¥133.61", "详情输出价")
        check_eq(detail["cache_price"], "¥1.34", "详情缓存价")
        check_eq(detail["original_usd"], "$4 / $20", "原价原文")
        check_eq(len(detail["cards"]), 4, "四张领域卡")
        dcoding = next((c for c in detail["cards"] if c["category"] == "coding"), None)
        check(dcoding is not None, "编程卡在")
        if dcoding:
            check_eq(dcoding["score"], 74.3, "编程卡评分")
            check_eq(dcoding["rank"], 1, "编程卡名次")
            check_eq(dcoding["eval_count"], 8, "编程卡 8 项评测")
            check_eq(dcoding["coverage"], 86, "编程卡覆盖 86%")
        know = next((c for c in detail["cards"] if c["category"] == "knowledge"), None)
        check(know is not None and know["rank"] == 5, "知识问答卡第 5 名")

        check_eq(len(detail["groups"]), 5, "五个成绩分组")
        total_items = sum(len(g["items"]) for g in detail["groups"])
        check_eq(total_items, 35, "逐项共 35 项（35 项评测对得上页头）")
        gcoding = next((g for g in detail["groups"] if g["category"] == "coding"), None)
        check(gcoding is not None, "编程分组在")
        if gcoding:
            check_eq(gcoding["heading"], "编程", "编程分组标题")
            check_eq(gcoding["score"], 74.3, "编程分组分")
            check_eq(gcoding["eval_count"], 8, "编程分组 8 项")
            check_eq(len(gcoding["items"]), 8, "编程分组 8 行")
            first_item = gcoding["items"][0]
            check_eq(first_item["name"], "ProgramBench", "ProgramBench 名字")
            check_eq(first_item["source"], "Vals AI 旧型号作答 12%", "ProgramBench 出处")
            check_eq(first_item["score_text"], "18.5%", "ProgramBench 原始成绩")
            check_eq(first_item["converted"], "108.1", "ProgramBench 折算分")
        blind = next((g for g in detail["groups"] if g["heading"] == "真人盲选"), None)
        check(blind is not None and blind["category"] is None, "真人盲选不在分类榜里（category nil）")
        if blind:
            check_eq(len(blind["items"]), 1, "盲选 1 项")
            check_eq(blind["items"][0]["name"], "Arena Text", "盲选项目名")
            check_eq(blind["items"][0]["score_text"], "1,508.2", "盲选成绩原文（千分位保真）")
        gknow = next((g for g in detail["groups"] if g["category"] == "knowledge"), None)
        check(gknow is not None, "知识问答分组在")
        if gknow:
            # 名字前有字母徽章（P）的条目：名字不能被劈成徽章
            bullshit = next((b for b in gknow["items"] if "BullshitBench" in b["name"]), None)
            check(bullshit is not None, "BullshitBench 在知识问答组")
            if bullshit:
                check_eq(bullshit["name"], "BullshitBench v2", "字母徽章不进名字")
                check_eq(bullshit["source"], "BullshitBench", "BullshitBench 出处")
                check_eq(bullshit["score_text"], "62.0%", "BullshitBench 成绩")
        gpro = next((g for g in detail["groups"] if g["category"] == "professional"), None)
        check(gpro is not None, "专业办公分组在")
        if gpro:
            harvey = next((b for b in gpro["items"] if b["name"].startswith("Harvey")), None)
            check(harvey is not None, "Harvey 在专业办公组")
            if harvey:
                check_eq(harvey["converted"], "至多 55.1", "折算分带「至多」前缀")

    # 边界
    check(lb_parse_board("", "overall") is None, "空 HTML 无榜")
    check(lb_parse_board("<html><body>完全不是榜单</body></html>", "overall") is None,
          "非榜单页无行 → nil")
    check(lb_parse_detail("") is None, "空 HTML 无详情")
    check(lb_parse_detail("<html><body><h1>只有名字</h1></body></html>") is not None,
          "只有 h1 也能出详情（其余字段全 nil，UI 各自显灰）")

    print("")
    print("== 镜像 18：周报/月报的期号、区间与往期分组（ReportPeriod）==")
    # 断言全部从四份夹具字节推导（与 AIHOTTests/ReportDecodingTests.swift、
    # ReportPeriodTests.swift 一致）。解码假设（可选性、小数秒）一并钉在这里：
    # Python 读同一份 JSON，null → None 与 Swift 的 nil 对齐。

    # --- 最新一期周报 ---
    wk = fixture_json("report-weekly-latest.json")
    check_eq(wk["schemaVersion"], 1, "周报信封 schemaVersion 1")
    r = wk["report"]
    check_eq(r["week"], "2026-W42", "latest 周报是 2026-W42")
    check(r.get("month") is None, "周报没有 month 键")
    check_eq(r["periodStart"], "2026-10-12", "periodStart 展示原文")
    check_eq(r["periodEnd"], "2026-10-18", "periodEnd 展示原文")
    check_eq(r["generatedAt"], "2026-10-19T02:00:16.671Z", "generatedAt 带小数秒")
    check(r["overview"] is not None, "新期次有 overview")
    check_eq(r["links"]["aihot"], "https://aihot.news/weekly/2026-W42", "期回链 links.aihot")
    check_eq(r["attribution"]["name"], "AIHOT", "署名")
    check_eq([s["label"] for s in r["sections"]],
             ["模型发布/更新", "产品发布/更新", "行业动态", "论文研究"], "分栏标签原样")
    check_eq([len(s["items"]) for s in r["sections"]], [7, 4, 6, 3], "四栏条数")
    check(all(s["summary"] is not None for s in r["sections"]), "新期次四个 summary 都在")
    first = r["sections"][0]["items"][0]
    check_eq(first["title"], "Google 发布 Gemini 4 Argon：面向复杂工程与科研任务的前沿模型",
             "首条标题")
    check_eq(first["source"]["name"], "Google Blog：AI（RSS）", "首条来源")
    check(first["links"]["original"].startswith("https://blog.google/"), "首条有原文链接")
    check_eq(first["publishedAt"], "2026-10-13T16:00:00.000Z", "publishedAt 带小数秒")

    # --- 周报索引 ---
    idx = fixture_json("report-weekly-index.json")
    check_eq(idx["schemaVersion"], 1, "索引信封 schemaVersion 1")
    check_eq(idx["count"], 12, "索引 count 12")
    check_eq(len(idx["items"]), 12, "索引 12 条")
    ids = [(e.get("week") or e.get("month")) for e in idx["items"]]
    check_eq(len(set(ids)), 12, "期号唯一（NavigationLink 不串页）")
    check_eq(ids[0], "2026-W42", "首条最新")
    check_eq(ids[-1], "2026-W31", "末条最旧")
    check_eq(idx["items"][0]["periodStart"], "2026-10-12", "首条区间起点")
    check_eq(idx["items"][-1]["periodStart"], "2026-07-27", "末条区间起点")
    check(all(e["links"] and e["links"].get("aihot") for e in idx["items"]),
          "每条往期都有 links.aihot（网页版契约）")
    check(all(e.get("headline") for e in idx["items"]), "每条往期都有 headline")

    # --- 老期次的 null（可选性的回归钉） ---
    old = fixture_json("report-weekly-older.json")["report"]
    check_eq(old["week"], "2026-W30", "老期次 2026-W30")
    check(old["overview"] is None, "老期次 overview 是 null → Swift nil")
    check_eq(len(old["sections"]), 5, "老期次 5 栏")
    check_eq([s["label"] for s in old["sections"]], [
        "开源模型性能逼近前沿，闭源商业模式承压",
        "AI安全事件频发：自主智能体攻破生产环境",
        "端侧与具身智能模型加速落地",
        "AI办公与创作工具全面升级",
        "AI基础设施与训练效率创新",
    ], "老期次 label 是主题句（原样渲染，不归一化）")
    check(old["sections"][4]["summary"] is None, "末栏 summary null")
    check(old["sections"][0]["summary"] is not None, "首栏 summary 在")
    check_eq([len(s["items"]) for s in old["sections"]], [4, 4, 4, 4, 4], "老期次各栏 4 条")
    check("\n" in old["sections"][0]["items"][0]["summary"], "摘要原文带换行（透传不压缩）")

    # --- 月报（钉 month 键） ---
    mo = fixture_json("report-monthly-latest.json")["report"]
    check(mo.get("week") is None, "月报没有 week 键")
    check_eq(mo["month"], "2026-09", "月报 2026-09")
    check_eq(mo["periodStart"], "2026-09-01", "月报起点")
    check_eq(mo["periodEnd"], "2026-09-30", "月报终点")
    check_eq(mo["generatedAt"], "2026-10-01T11:48:32.108Z", "月报 generatedAt 带小数秒")
    check_eq(mo["links"]["aihot"], "https://aihot.news/monthly/2026-09", "月报期回链")
    check_eq([s["label"] for s in mo["sections"]],
             ["模型发布/更新", "产品发布/更新", "行业动态", "论文研究", "技巧与观点"], "月报分栏")
    check_eq(sum(1 for s in mo["sections"] if s["summary"] is None), 4,
             "月报四个 summary 是 null")
    check(mo["sections"][0]["summary"] is not None, "月报首栏 summary 在")

    # --- ReportPeriod.title ---
    check_eq(report_title("2026-W42"), "2026 年第 42 周", "周报期号 → 中文标题")
    check_eq(report_title("2026-W07"), "2026 年第 7 周", "补零周号剥掉前导零")
    check_eq(report_title("2026-W1"), "2026 年第 1 周", "周号位数不限")
    check_eq(report_title("2026-W53"), "2026 年第 53 周", "53 周边界合法")
    check_eq(report_title("2026-09"), "2026 年 9 月", "月报期号 → 中文标题")
    check_eq(report_title("2026-12"), "2026 年 12 月", "12 月边界合法")
    check(report_title("2026-W54") is None, "没有第 54 周")
    check(report_title("2026-W0") is None, "没有第 0 周")
    check(report_title("2026-13") is None, "没有第 13 个月")
    check(report_title("2026-00") is None, "没有第 0 个月")
    check(report_title("W42") is None, "缺年份认不出")
    check(report_title("2026/09") is None, "斜杠格式认不出")
    check(report_title("banana") is None, "乱码认不出（界面退回原文）")

    # --- ReportPeriod.rangeText ---
    check_eq(report_range_text("2026-10-12", "2026-10-18"), "10.12 – 10.18", "同年区间 MM.dd")
    check_eq(report_range_text("2026-09-01", "2026-09-30"), "09.01 – 09.30", "补零两位")
    check_eq(report_range_text("2025-12-29", "2026-01-04"), "2025.12.29 – 2026.01.04",
             "跨年补年份")
    check(report_range_text(None, "2026-10-18") is None, "起点缺失 → nil")
    check(report_range_text("2026-10-12", None) is None, "终点缺失 → nil")
    check(report_range_text(None, None) is None, "两端都缺 → nil")
    check(report_range_text("2026-10", "2026-10-18") is None, "半截日期认不出 → nil")
    check(report_range_text("2026-10-12", "2026-13-01") is None, "13 月不合法 → nil")
    check(report_range_text("2026-10-12", "2026-10-32") is None, "32 日不合法 → nil")

    # --- ReportPeriod.groupByMonth（拿索引夹具当真实输入） ---
    groups = report_group_by_month(idx["items"])
    check_eq([g["title"] for g in groups],
             ["2026 年 10 月", "2026 年 9 月", "2026 年 8 月", "2026 年 7 月"],
             "分组标题按接口顺序（不排序）")
    check_eq([len(g["entries"]) for g in groups], [2, 4, 5, 1], "各组条数")
    flat = [e for g in groups for e in g["entries"]]
    check_eq(len(flat), len(idx["items"]), "不丢不重")
    check_eq(set(e["week"] for e in flat), set(ids), "条目集合与输入一致")

    mixed = [
        {"week": "2026-W41", "periodStart": "2026-10-05"},
        {"week": "2026-W01", "periodStart": None},
        {"week": "2026-W02", "periodStart": "not-a-date"},
        {"week": "2026-W42", "periodStart": "2026-10-12"},
    ]
    mg = report_group_by_month(mixed)
    check_eq([g["title"] for g in mg], ["2026 年 10 月", "其它"],
             "缺 periodStart 的条目归到末尾「其它」组")
    check_eq([e["week"] for e in mg[0]["entries"]], ["2026-W41", "2026-W42"],
             "同月内保持输入顺序")
    check_eq([e["week"] for e in mg[1]["entries"]], ["2026-W01", "2026-W02"],
             "缺失与非法都进「其它」")
    check(report_group_by_month([]) == [], "空输入 → 空分组")

    print("")
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
