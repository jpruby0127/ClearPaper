#!/usr/bin/env python3
"""ClearPaper · 可选的高阶 OCR 后端（Xiaomi-OCR-0）

小米开源的 Xiaomi-OCR-0（0.8B，Apache 2.0）能把整页文档解析成结构化
Markdown（表格 OTSL、公式 LaTeX），还支持字段抽取与文档问答。本脚本是
**轻量桥接**：把 PDF / 图片按官方约定送进本机的 OpenAI 兼容推理服务，
把结果拼成一份 .md。

它不在 App 里，也不需要联网：服务只接受 127.0.0.1 / localhost，
默认完全离线。iOS App 内置的拍照 OCR 用的是系统 Vision，零额外体积；
这一档适合桌面 / 服务器上批量做「拍照 → 清晰化 → 结构化整理」。

启动服务（任选其一，见小米官方 README）：
  vllm serve SeerRay-Lab/Xiaomi-OCR-0 --host 127.0.0.1 --port 8000 --max-model-len 16384
  python -m sglang.launch_server --model-path SeerRay-Lab/Xiaomi-OCR-0 \
      --host 127.0.0.1 --port 8000 --context-length 16384
  # 或 Ollama（社区 BF16 GGUF，约 1.8GB）：
  ollama pull longwayxu/xiaomi-ocr-0:bf16

用法：
  python ocr_xiaomi.py 某试卷.pdf                      # 输出 某试卷-OCR.md
  python ocr_xiaomi.py a.png b.png --out 整理.md
  XIAOMI_OCR_LOCAL_URL=http://127.0.0.1:11434/v1 \
  XIAOMI_OCR_MODEL=longwayxu/xiaomi-ocr-0:bf16 \
  python ocr_xiaomi.py 扫描件.pdf
  python ocr_xiaomi.py 表格.pdf --task kie --fields "姓名,学号,总分"

环境变量：XIAOMI_OCR_LOCAL_URL、XIAOMI_OCR_MODEL（与官方 Demo 同名）。
依赖：pymupdf / pillow（本仓库 Python 参考引擎已有），其余全用标准库。
模型权重版权归小米，遵循其仓库 LICENSE；本脚本随 ClearPaper 以 MIT 发布。
"""

import argparse
import base64
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# 官方 demo/server.py 的 DOC_PROMPT，逐字保留
DOC_PROMPT = (
    "Extract all information from the main body of the document image and represent it in markdown format, "
    "ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should "
    "be represented using LATEX format, and the parsing should be organized according to the reading order."
)
KIE_PROMPT = (
    "Extract the following fields from the document image and return a single JSON object. "
    "Fields: {fields}. Use null for fields that are not present."
)
VQA_PROMPT = "Answer the following question about the document image concisely: {question}"

DEFAULT_URL = "http://127.0.0.1:8000/v1"
DEFAULT_MODEL = "SeerRay-Lab/Xiaomi-OCR-0"


def normalize_png(raw: bytes) -> bytes:
    """官方会把每页归一化为 RGB PNG；长边限 2048，避免超出视觉编码像素上界。"""
    from PIL import Image

    im = Image.open(io.BytesIO(raw)).convert("RGB")
    im.thumbnail((2048, 2048))
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def render_pages(path: Path, dpi: int, max_pages: int | None) -> list[bytes]:
    if path.suffix.lower() == ".pdf":
        import fitz  # PyMuPDF

        out = []
        with fitz.open(path) as doc:
            for i, page in enumerate(doc):
                if max_pages and i >= max_pages:
                    break
                pix = page.get_pixmap(dpi=dpi, alpha=False)
                out.append(normalize_png(pix.tobytes("png")))
        return out
    return [normalize_png(path.read_bytes())]


def endpoint_for(base: str) -> str:
    base = base.rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme not in ("http", "https") or parsed.hostname not in (
        "127.0.0.1", "localhost", "::1"
    ):
        raise SystemExit(
            "推理服务必须在本机 loopback（127.0.0.1 / localhost），"
            "本工具不会把文档发到外网。"
        )
    if base.endswith("/chat/completions"):
        return base
    if base.endswith("/v1"):
        return base + "/chat/completions"
    return base + "/v1/chat/completions"


def call_model(png: bytes, prompt: str, url: str, model: str,
               max_tokens: int, timeout: int) -> str:
    endpoint = endpoint_for(url)
    b64 = base64.b64encode(png).decode("ascii")
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url",
                 "image_url": {"url": f"data:image/png;base64,{b64}"}},
                {"type": "text", "text": prompt},
            ],
        }],
        "temperature": 0.0,
        "max_tokens": max_tokens,
        "stream": False,
        "top_p": 0.8,
        "presence_penalty": 0.0,
        "repetition_penalty": 1.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        # 有些服务（如 Ollama）不认 chat_template_kwargs，退一档重试
        if e.code == 400 and "chat_template_kwargs" in detail:
            payload.pop("chat_template_kwargs", None)
            req = urllib.request.Request(
                endpoint, data=json.dumps(payload).encode("utf-8"),
                headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        else:
            raise SystemExit(f"推理服务返回 {e.code}：{detail}")
    except urllib.error.URLError as e:
        raise SystemExit(
            f"连不上本机推理服务（{endpoint}）：{e.reason}\n"
            "先按上方命令启动 vLLM / SGLang / Ollama，或确认端口与模型名。"
        )
    try:
        return body["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError):
        raise SystemExit(f"推理服务返回了意外结构：{json.dumps(body)[:400]}")


def main() -> int:
    ap = argparse.ArgumentParser(description="用本机 Xiaomi-OCR-0 把 PDF / 图片解析成 Markdown")
    ap.add_argument("inputs", nargs="+", type=Path, help="PDF 或图片，可多个")
    ap.add_argument("--out", type=Path, help="输出 .md（默认取第一个输入名）")
    ap.add_argument("--url", default=os.environ.get("XIAOMI_OCR_LOCAL_URL", DEFAULT_URL))
    ap.add_argument("--model", default=os.environ.get("XIAOMI_OCR_MODEL", DEFAULT_MODEL))
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--max-pages", type=int, default=None)
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--task", choices=("document", "kie", "vqa"), default="document")
    ap.add_argument("--fields", default="", help="kie 模式要抽取的字段，逗号分隔")
    ap.add_argument("--question", default="", help="vqa 模式的问题")
    ap.add_argument("--prompt", default="", help="自定义提示词，覆盖内置模板")
    args = ap.parse_args()

    if args.task == "document":
        prompt = args.prompt or DOC_PROMPT
    elif args.task == "kie":
        prompt = args.prompt or KIE_PROMPT.format(fields=args.fields or "all key fields")
    else:
        prompt = args.prompt or VQA_PROMPT.format(question=args.question or "What does it say?")

    out = args.out or args.inputs[0].with_name(args.inputs[0].stem + "-OCR.md")
    sections = [
        "<!-- ClearPaper · Xiaomi-OCR-0 · 本机推理，未上传任何文件 -->",
        f"<!-- model={args.model} task={args.task} -->",
    ]
    total = 0
    for src in args.inputs:
        if not src.exists():
            print(f"跳过（不存在）：{src}", file=sys.stderr)
            continue
        pages = render_pages(src, args.dpi, args.max_pages)
        print(f"{src.name}：{len(pages)} 页", flush=True)
        for i, png in enumerate(pages):
            t0 = time.perf_counter()
            text = call_model(png, prompt, args.url, args.model,
                              args.max_tokens, args.timeout)
            total += 1
            label = f"{src.name} · 第 {i + 1} 页" if len(args.inputs) > 1 or len(pages) > 1 \
                else f"第 {i + 1} 页"
            sections.append(f"## {label}\n\n{text}")
            print(f"  p{i + 1}: {len(text)} 字 · {time.perf_counter() - t0:.1f}s", flush=True)
    if total == 0:
        print("没有可解析的页面", file=sys.stderr)
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n\n".join(sections) + "\n", encoding="utf-8")
    print(f"已写出：{out}（{total} 页）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
