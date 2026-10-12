#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TEMPORARY: instrument HTMLTextExtractor.stripElement to print the runtime
pattern bytes and whether the replacement actually changed the text.
Deleted as soon as the root cause is known."""

import io

PATH = "AIHOT/Services/HTMLTextExtractor.swift"
SIG = "    static func stripElement(_ html: String, tag: String) -> String {"
BS = "\\"

with io.open(PATH, "r", encoding="utf-8", newline="") as handle:
    lines = handle.read().split("\n")

start = lines.index(SIG)
end = start
while lines[end] != "    }":
    end += 1

body = [
    SIG,
    "        // TEMP DIAG",
    '        let diagPattern = "<' + BS + "(tag)" + BS + BS + 'b[^>]*>.*?</' + BS + "(tag)>\"",
    "        let diagResult = RegexUtil.replace(",
    "            diagPattern,",
    "            in: html,",
    '            with: "' + BS + 'n",',
    "            options: [.caseInsensitive, .dotMatchesLineSeparators]",
    "        )",
    '        print("DIAG strip tag=" + tag'
    ' + " patternBytes=" + String(describing: Array(diagPattern.utf8))'
    ' + " inLen=" + String(html.count)'
    ' + " outLen=" + String(diagResult.count)'
    ' + " removed=" + String(!diagResult.contains("window.__NEXT_DATA__")))',
    "        return diagResult",
    "    }",
]

lines[start : end + 1] = body

with io.open(PATH, "w", encoding="utf-8", newline="") as handle:
    handle.write("\n".join(lines))

print("patched lines %d-%d" % (start + 1, end + 1))
