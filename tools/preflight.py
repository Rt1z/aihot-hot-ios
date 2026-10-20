#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建前自检（本地和 GitHub Actions 都会跑）。

目的：把「结构性错误」在编译之前就用一行话说清楚，而不是让 Xcode 报一堆
看不懂的错。检查项：

1. 所有 JSON（测试夹具 + Assets 的 Contents.json）能被解析；
2. Info.plist 是合法 plist，且必需键都在；
3. project.yml / workflow 里引用的路径真实存在（防手滑改路径）；
4. tools/ 下的 Python 脚本语法正确。

用法：python3 tools/preflight.py
"""

import json
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

JSON_FILES = [
    "AIHOT/Assets.xcassets/Contents.json",
    "AIHOT/Assets.xcassets/AccentColor.colorset/Contents.json",
    "AIHOT/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "AIHOTTests/Fixtures/hot-topics.json",
    "AIHOTTests/Fixtures/story.json",
    "AIHOTTests/Fixtures/anysearch-search.json",
    "AIHOTTests/Fixtures/anysearch-error.json",
    "AIHOTTests/Fixtures/tavily-search.json",
    "AIHOTTests/Fixtures/tavily-extract.json",
    "AIHOTTests/Fixtures/story-timeline.json",
    "AIHOTTests/Fixtures/serpapi-search.json",
    "AIHOTTests/Fixtures/serpapi-error.json",
    "AIHOTTests/Fixtures/serper-search.json",
    "AIHOTTests/Fixtures/serper-error.json",
    "AIHOTTests/Fixtures/exa-search.json",
    "AIHOTTests/Fixtures/exa-contents.json",
    "AIHOTTests/Fixtures/exa-error.json",
    "AIHOTTests/Fixtures/report-weekly-latest.json",
    "AIHOTTests/Fixtures/report-weekly-index.json",
    "AIHOTTests/Fixtures/report-weekly-older.json",
    "AIHOTTests/Fixtures/report-monthly-latest.json",
]

PYTHON_FILES = [
    "tools/make_appicon.py",
    "tools/preflight.py",
    "tools/logic_tests.py",
]

REQUIRED_PLIST_KEYS = [
    "CFBundleDisplayName",
    "CFBundleIdentifier",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "CFBundleExecutable",
    "UILaunchScreen",
    "UISupportedInterfaceOrientations",
]

PATH_REFERENCE_SOURCES = [
    "project.yml",
    ".github/workflows/ios.yml",
]

# project.yml 里 sources/excludes/info 的路径，以及 workflow 里直接写出的仓库内路径
PROJECT_PATTERNS = [
    re.compile(r"^\s*-\s*path:\s*([^\s#]+)\s*$"),
    re.compile(r"^\s*path:\s*([^\s#]+)\s*$"),
    re.compile(r"^\s*-\s*([A-Za-z0-9_./-]+\.(?:swift|json|txt|html|plist))\s*$"),
]

WORKFLOW_PATTERNS = [
    re.compile(r"python3\s+(tools/[A-Za-z0-9_./-]+)"),
    re.compile(r"(AIHOT/Info\.plist)"),
]

# 构建期才生成的文件（不进仓库，所以不能拿它去 stat）。
# 这类路径不做「存在性」检查，改由 check_icon_wiring() 比较字符串两侧是否一致。
GENERATED_PATHS = {
    "AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
}

problems = []
checked = []


def fail(message):
    problems.append(message)


def check_json(relative):
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        fail("缺少文件：%s" % relative)
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            json.load(handle)
    except Exception as exc:  # noqa: BLE001
        fail("JSON 解析失败 %s：%s" % (relative, exc))
        return
    checked.append("json %s" % relative)


def check_plist(relative):
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        fail("缺少文件：%s" % relative)
        return
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:  # noqa: BLE001
        fail("plist 解析失败 %s：%s" % (relative, exc))
        return
    for key in REQUIRED_PLIST_KEYS:
        if key not in data:
            fail("Info.plist 缺少必需键：%s" % key)
    checked.append("plist %s" % relative)


def check_python(relative):
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        fail("缺少文件：%s" % relative)
        return
    # 用内建 compile() 只做语法检查：不写 .pyc、没有副作用
    # （py_compile 会写到目标路径旁边，在 /dev/null 之类的位置会失败）
    try:
        with open(path, "r", encoding="utf-8") as handle:
            source = handle.read()
        compile(source, path, "exec")
    except SyntaxError as exc:
        fail("Python 语法错误 %s: 第 %s 行 %s" % (relative, exc.lineno, exc.msg))
    except Exception as exc:  # noqa: BLE001
        fail("读取 Python 文件失败 %s：%s" % (relative, exc))
        return
    checked.append("python %s" % relative)


def referenced_paths():
    """从 project.yml / workflow 里粗略抓出仓库内相对路径。"""
    found = set()

    for source in PATH_REFERENCE_SOURCES:
        path = os.path.join(ROOT, source)
        if not os.path.isfile(path):
            fail("缺少文件：%s" % source)
            continue
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.split("#", 1)[0]
                patterns = PROJECT_PATTERNS if source == "project.yml" else WORKFLOW_PATTERNS
                for pattern in patterns:
                    match = pattern.search(stripped)
                    if match:
                        found.add(match.group(1))

    return found


def check_referenced_paths():
    for relative in sorted(referenced_paths()):
        # xcodegen 生成物、CI 产物，以及构建期才生成的文件
        if relative.startswith(("build", "Payload", "AIHOT.xcodeproj")):
            continue
        if relative in GENERATED_PATHS:
            continue
        full = os.path.join(ROOT, relative)
        if os.path.exists(full):
            checked.append("path %s" % relative)
        else:
            fail("project.yml / workflow 引用了不存在的路径：%s" % relative)


def check_icon_wiring():
    """图标是构建期生成的：生成脚本的默认输出路径，必须和 workflow 里那句
    `test -s` 检查的路径一致，否则会以看不懂的 actool 报错收场。"""
    output = "AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    name = "AppIcon-1024.png"

    script_path = os.path.join(ROOT, "tools", "make_appicon.py")
    workflow_path = os.path.join(ROOT, ".github", "workflows", "ios.yml")

    if os.path.isfile(script_path):
        with open(script_path, "r", encoding="utf-8") as handle:
            script = handle.read()
        if name not in script:
            fail("tools/make_appicon.py 里找不到生成 %s 的痕迹" % name)
        else:
            checked.append("icon generator")
    else:
        fail("缺少文件：tools/make_appicon.py")

    if os.path.isfile(workflow_path):
        with open(workflow_path, "r", encoding="utf-8") as handle:
            workflow = handle.read()
        if output not in workflow:
            fail("workflow 里没有对 %s 的存在性检查（图标没生成时只会得到 actool 的报错）" % output)
        else:
            checked.append("icon guard")
    else:
        fail("缺少文件：.github/workflows/ios.yml")


def main():
    check_plist("AIHOT/Info.plist")
    for relative in JSON_FILES:
        check_json(relative)
    for relative in PYTHON_FILES:
        check_python(relative)
    check_icon_wiring()
    check_referenced_paths()

    print("preflight: 检查了 %d 项" % len(checked))
    if problems:
        print("")
        for problem in problems:
            print("  ✗ %s" % problem)
        print("")
        print("preflight 失败：%d 个问题" % len(problems))
        return 1

    print("preflight 通过：JSON / plist / Python / 路径引用 全部正常")
    return 0


if __name__ == "__main__":
    sys.exit(main())
