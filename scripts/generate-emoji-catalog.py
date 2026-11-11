"""Generate the offline catalog from Emoji 16.0, UCD 16.0.0 and CLDR 48.

Inputs in the given directory: emoji-test.txt, UnicodeData.txt, en.xml and zh.xml.
Sources: unicode.org/Public/emoji/16.0/, unicode.org/Public/16.0.0/ucd/,
and github.com/unicode-org/cldr/tree/release-48/common/annotations.
"""
import argparse
from pathlib import Path
from xml.etree import ElementTree

GROUPS = {
    "Smileys & Emotion": "people", "People & Body": "people",
    "Animals & Nature": "nature", "Food & Drink": "food", "Travel & Places": "travel",
    "Activities": "activity", "Objects": "objects", "Symbols": "emoji-symbols", "Flags": "flags",
}
BLOCKS = {
    "greek": [(0x0370, 0x03FF)],
    "math": [(0x2200, 0x22FF)],
    "arrows": [(0x2190, 0x21FF)],
    "currency": [(0x20A0, 0x20CF)],
    "punctuation": [(0x2000, 0x206F), (0x3001, 0x3030)],
    "keyboard": [(0x2318, 0x2318), (0x2324, 0x2327), (0x232B, 0x232B),
                 (0x23CE, 0x23CE), (0x21E7, 0x21E7), (0x238B, 0x238B)],
}
COMMON_NAMES = {
    "β": "希腊小写字母贝塔", "λ": "希腊小写字母兰姆达", "α": "希腊小写字母阿尔法",
    "π": "希腊小写字母派", "Ω": "希腊大写字母欧米伽", "∞": "无穷大 无限",
    "√": "平方根 根号", "∑": "求和 总和", "∫": "积分", "≈": "约等于",
    "≠": "不等于", "≤": "小于等于", "≥": "大于等于",
    "←": "向左箭头", "→": "向右箭头", "↑": "向上箭头", "↓": "向下箭头",
    "€": "欧元", "¥": "日元 人民币", "$": "美元", "£": "英镑", "₿": "比特币",
    "⌘": "Command 命令键", "⌥": "Option 选项键", "⌃": "Control 控制键",
    "⇧": "Shift 大写键", "⎋": "Escape 退出键", "⏎": "Return 回车键",
    "⌫": "Delete 删除键", "…": "省略号", "—": "破折号", "、": "顿号", "。": "句号",
}
EXTRA = {
    "currency": [0x24, 0xA2, 0xA3, 0xA5],
    "math": [0xB1, 0xD7, 0xF7],
    "keyboard": [0x2303, 0x21A9, 0x21E5],
}


def canonical(glyph):
    return glyph.replace("\ufe0f", "")


def annotations(path):
    result = {}
    for item in ElementTree.parse(path).iter("annotation"):
        entry = result.setdefault(canonical(item.attrib["cp"]), {})
        entry["name" if item.get("type") == "tts" else "keywords"] = item.text or ""
    return result


def catalog(source):
    en = annotations(source / "en.xml")
    zh = annotations(source / "zh.xml")
    seen = set()
    group = None
    for line in (source / "emoji-test.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("# group: "):
            group = GROUPS.get(line.removeprefix("# group: "))
        if not group or "; fully-qualified" not in line:
            continue
        codepoints, details = line.split(";", 1)
        glyph = "".join(chr(int(code, 16)) for code in codepoints.split())
        english = en.get(canonical(glyph), {})
        chinese = zh.get(canonical(glyph), {})
        name = details.split("#", 1)[1].strip().split(maxsplit=2)[2]
        seen.add(glyph)
        yield (group, glyph, english.get("name", name), chinese.get("name", ""),
               " ".join((name, english.get("keywords", ""), chinese.get("keywords", ""))))

    ucd = {}
    for line in (source / "UnicodeData.txt").read_text(encoding="utf-8").splitlines():
        code, name, category, *_ = line.split(";")
        if category[0] in "LPS" and not name.startswith("<"):
            ucd[int(code, 16)] = name.title()
    for group, ranges in BLOCKS.items():
        codes = EXTRA.get(group, []) + [code for first, last in ranges for code in range(first, last + 1)]
        for code in codes:
            glyph = chr(code)
            if code in ucd and glyph not in seen:
                seen.add(glyph)
                yield (group, glyph, ucd[code], COMMON_NAMES.get(glyph, ""), "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with args.output.open("w", encoding="utf-8") as output:
        for row in catalog(args.source):
            output.write("\t".join(" ".join(field.split()) for field in row).rstrip("\t") + "\n")


if __name__ == "__main__":
    main()
