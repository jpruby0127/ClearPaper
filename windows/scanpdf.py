#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ClearPaper for Windows — 把扫描/拍照 PDF 变成打印级清晰 A4。

用法：
    ClearPaper.bat 文件.pdf [更多.pdf ...]      或把 PDF 拖到 ClearPaper.bat 上

输出：与原文件同目录的 "<名字>-清晰版.pdf"；若原目录不可写，则落到
      %USERPROFILE%\\Documents\\试卷清晰版\\。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)


def _utf8():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass


def _out_path(src):
    base = os.path.splitext(os.path.basename(src))[0]
    return os.path.join(os.path.dirname(os.path.abspath(src)), base + "-清晰版.pdf")


def _fallback_dir():
    home = os.path.expanduser("~")
    d = os.path.join(home, "Documents", "试卷清晰版")
    try:
        os.makedirs(d, exist_ok=True)
        return d
    except Exception:
        d = os.path.join(HERE, "输出")
        os.makedirs(d, exist_ok=True)
        return d


def _summary(dec):
    tags = []
    if dec.get("geometry_bad"):
        tags.append("修正页面尺寸")
    if dec.get("has_frame"):
        tags.append("去除扫描黑框")
    if dec.get("notes_canvas"):
        tags.append("裁除备忘录白边")
    if dec.get("show_through"):
        tags.append("抑制背面透印")
    return "、".join(tags) if tags else "常规扫描"


def main(argv=None):
    _utf8()
    args = [a for a in (argv if argv is not None else sys.argv[1:]) if a]
    if not args or args[0] in ("-h", "--help", "/?"):
        print("用法：把 PDF 拖到 ClearPaper.bat 上，或：")
        print("      ClearPaper.bat 文件.pdf [更多.pdf]")
        return 0

    try:
        import engine
    except Exception as e:
        print("引擎加载失败：", e)
        return 2

    ok = fail = 0
    for src in args:
        src = src.strip().strip('"')
        if not os.path.isfile(src):
            print("跳过（找不到文件）：%s" % src)
            fail += 1
            continue
        base = os.path.splitext(os.path.basename(src))[0]
        if base.endswith("-清晰版"):
            print("跳过（已经是清晰版）：%s" % os.path.basename(src))
            continue

        out = _out_path(src)
        print("\n处理：%s" % os.path.basename(src))
        try:
            res = engine.process_pdf(src, out,
                                     progress=lambda m: print("  ·", m),
                                     overwrite=False)
        except PermissionError:
            out = os.path.join(_fallback_dir(), base + "-清晰版.pdf")
            print("  原目录不可写，改存到：%s" % out)
            try:
                res = engine.process_pdf(src, out,
                                         progress=lambda m: print("  ·", m),
                                         overwrite=True)
            except Exception as e:
                print("  失败：%s" % e)
                fail += 1
                continue
        except Exception as e:
            print("  失败：%s" % e)
            fail += 1
            continue

        if res.get("status") == "skip":
            print("  未处理：%s" % res.get("detail", ""))
            continue

        print("  判断：%s" % _summary(res.get("decisions", {})))
        print("  完成：%s 页 A4 · 纸面 %s mm · %.2f MB · 用时 %ss"
              % (res["pages"], res["sheet_width_mm"],
                 res["output_bytes"] / 1e6, res["seconds"]))
        print("  输出：%s" % res["out"])
        ok += 1

    print("\n全部完成：成功 %d，失败 %d" % (ok, fail))
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
