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
# 断言（全部以夹具为准）
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
        realistic = "NO.01 爆 ↑ 20%\n标题\n%s\n+10 7 个来源 · 16 位参与者\n160\n热度指数" % long_digest
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
