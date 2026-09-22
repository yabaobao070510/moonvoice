#!/usr/bin/env python3
"""把演示页构建成**单个可双击打开的 HTML**。

内嵌三样东西：
  1. 场景素材（office_before.mp3 —— 真实录音，见 build_materials.py）
  2. 三个技能的 wasm（`moon build --release --target wasm cmd/<skill>` 的产物）
  3. 最小 WASI 运行时（`wasi_shim.js`，只实现技能实际 import 的 5 个函数）

为什么内嵌而不是引用文件：file:// 下浏览器会拦掉本地 fetch，
而"双击就能用、并且真的在浏览器里跑我们的组件"是这个页面的全部意义。

前置：
    python demo/build_materials.py          # 从原始素材生成嵌入用 MP3
    moon build --release --target wasm cmd/vad
    moon build --release --target wasm cmd/resample
    moon build --release --target wasm cmd/loudness
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
SKILLS = ["vad", "resample", "loudness"]
MP3S = {"OFFICE": DEMO / "office_before.mp3"}
SHIM = DEMO / "wasi_shim.js"
TPL = DEMO / "page_template.html"
OUT = DEMO / "index.html"


def main() -> None:
    missing = [(p, "python demo/build_materials.py") for p in MP3S.values() if not p.exists()]
    missing += [(p, "moon build --release --target wasm cmd/%s" % p.parent.name) for p in
                (WASM_DIR / k / f"{k}.wasm" for k in SKILLS) if not p.exists()]
    if missing:
        for p, how in missing:
            print(f"缺少 {p.relative_to(ROOT)}　→ 先执行：{how}")
        sys.exit(1)

    b64 = lambda p: base64.b64encode(p.read_bytes()).decode("ascii")

    shim_src = json.dumps(SHIM.read_text(encoding="utf-8"))
    html = TPL.read_text(encoding="utf-8")
    for name, p in MP3S.items():
        html = html.replace(f"__{name}_MP3__", b64(p))
    for k in SKILLS:
        html = html.replace(f"__WASM_{k.upper()}__", b64(WASM_DIR / k / f"{k}.wasm"))
    html = html.replace("__SHIM__", shim_src)

    for token in ["__OFFICE_MP3__", "__SHIM__"] + [f"__WASM_{k.upper()}__" for k in SKILLS]:
        if token in html:
            sys.exit(f"占位符未替换：{token}（模板与构建脚本不同步？）")

    OUT.write_text(html, encoding="utf-8")

    print(f"生成 {OUT.relative_to(ROOT)}")
    total = sum((WASM_DIR / k / f"{k}.wasm").stat().st_size for k in SKILLS)
    print(f"  wasm   {total/1024:.0f} KB（{'+'.join(SKILLS)}）")
    print(f"  素材   {sum(p.stat().st_size for p in MP3S.values())/1024:.0f} KB（{len(MP3S)} 个场景 mp3）")
    print(f"  页面   {OUT.stat().st_size/1024:.0f} KB（单文件，双击可开）")


if __name__ == "__main__":
    main()
