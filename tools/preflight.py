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
    re.compile(r"(AIHOT/Assets\.xcassets/AppIcon\.appiconset/AppIcon-1024\.png)"),
]

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
        # xcodegen 生成物与 CI 产物不在仓库里，跳过
        if relative.startswith(("build", "Payload", "AIHOT.xcodeproj")):
            continue
        full = os.path.join(ROOT, relative)
        if os.path.exists(full):
            checked.append("path %s" % relative)
        else:
            fail("project.yml / workflow 引用了不存在的路径：%s" % relative)


def main():
    check_plist("AIHOT/Info.plist")
    for relative in JSON_FILES:
        check_json(relative)
    for relative in PYTHON_FILES:
        check_python(relative)
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
