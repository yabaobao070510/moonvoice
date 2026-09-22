#!/usr/bin/env python3
"""把演示页构建成**单个可双击打开的 HTML**。

内嵌三样东西：
  1. 素材音频（MP3 —— 体积只有 WAV 的 1/20，且真实素材本来就是压缩格式）
  2. 技能 wasm（`moon build --release --target wasm cmd/vad` 的产物）
  3. 最小 WASI 运行时（`wasi_shim.js`，只实现技能实际 import 的 5 个函数）

为什么内嵌而不是引用文件：file:// 下浏览器会拦掉本地 fetch，
而"双击就能用、并且真的在浏览器里跑我们的组件"是这个页面的全部意义。

前置：先跑 `moon build --release --target wasm cmd/vad`，再跑本脚本。
用法：
    python demo/build_page.py
"""

from __future__ import annotations

import base64
import json
import pathlib
import sys

DEMO = pathlib.Path(__file__).resolve().parent
ROOT = DEMO.parent
WASM_DIR = ROOT / "_build" / "wasm" / "release" / "build" / "cmd"
# 三个技能各一个 wasm：页面把它们都跑一遍（全功能展示，不是只跑一个）
SKILLS = ["vad", "resample", "loudness"]
MP3 = DEMO / "before.mp3"
SHIM = DEMO / "wasi_shim.js"
TPL = DEMO / "page_template.html"
OUT = DEMO / "index.html"


def main() -> None:
    for p, how in [(MP3, "python demo/build_before.py <flac 目录> 然后 ffmpeg 转 mp3"),
                   (SHIM, "（仓库自带）")] +                   [(WASM_DIR / k / f"{k}.wasm", f"moon build --release --target wasm cmd/{k}") for k in SKILLS]:
        if not p.exists():
            sys.exit(f"缺少 {p.relative_to(ROOT)}　→ 先执行：{how}")

    b64 = lambda p: base64.b64encode(p.read_bytes()).decode("ascii")

    # shim 包成"求值后返回 makeWASI"的表达式，供模板里 new Function("return ...") 使用
    # 注入**原始源码**的 JS 字符串字面量；模板用 new Function(src + "\nreturn makeWASI;") 求值
    shim_src = json.dumps(SHIM.read_text(encoding="utf-8"))

    html = TPL.read_text(encoding="utf-8")
    html = html.replace("__BEFORE_MP3__", b64(MP3))
    for k in SKILLS:
        html = html.replace(f"__WASM_{k.upper()}__", b64(WASM_DIR / k / f"{k}.wasm"))
    html = html.replace("__SHIM__", shim_src)
    OUT.write_text(html, encoding="utf-8")

    print(f"生成 {OUT.relative_to(ROOT)}")
    total = sum((WASM_DIR / k / f"{k}.wasm").stat().st_size for k in SKILLS)
    print(f"  wasm   {total/1024:.0f} KB（{'+'.join(SKILLS)}）")
    print(f"  素材   {MP3.stat().st_size/1024:.0f} KB (mp3)")
    print(f"  页面   {OUT.stat().st_size/1024:.0f} KB（单文件，双击可开）")


if __name__ == "__main__":
    main()
