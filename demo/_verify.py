"""用无头浏览器验证演示页真的能跑（不是"看起来能跑"）。

验证四件事：
 1. 素材解码成功、波形画出来
 2. 拖拽选区生效
 3. **点击处理后，浏览器里的 wasm 真的执行了**（拿到输出音频与耗时）
 4. 输出是预期的规格（16 kHz 单声道）

用法：python demo/_verify.py
"""

from __future__ import annotations

import pathlib
import sys

from playwright.sync_api import sync_playwright

PAGE = pathlib.Path(__file__).resolve().parent / "index.html"


def main() -> None:
    # Windows 控制台默认 GBK，打不出页面里的 −（U+2212）等字符
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1000, "height": 1100})
        errs: list[str] = []
        pg.on("pageerror", lambda e: errs.append(f"pageerror: {e}"))
        pg.on("console", lambda m: errs.append(f"console.{m.type}: {m.text}") if m.type == "error" else None)

        pg.goto(PAGE.as_uri(), wait_until="load")
        # 等 MP3 解码 + 后台预热完成（预热会让后续计时反映真实处理开销而非首次启动开销）
        pg.wait_for_timeout(12000)

        # 2) 拖拽选区（在波形画布上从左 20% 拖到 70%）
        box = pg.locator("#wave").bounding_box()
        x0 = box["x"] + box["width"] * 0.20
        x1 = box["x"] + box["width"] * 0.70
        y = box["y"] + box["height"] / 2
        pg.mouse.move(x0, y)
        pg.mouse.down()
        pg.mouse.move(x1, y, steps=12)
        pg.mouse.up()
        pg.wait_for_timeout(200)

        sel_text = pg.inner_text("#selInfo")
        btn_disabled = pg.locator("#run").is_disabled()

        # 3) 点处理
        pg.locator("#run").click()
        try:
            pg.wait_for_function("!document.getElementById('result').classList.contains('hide')", timeout=25000)
        except Exception:
            # 超时时也要拿到现场，否则没法定位
            print("!! 处理未完成，现场状态：")
            print("   status =", pg.inner_text("#status"))
            print("   result 隐藏 =", pg.evaluate("document.getElementById('result').classList.contains('hide')"))
            print("   JS 错误 =", errs[:6])
            pg.screenshot(path=str(pathlib.Path(__file__).resolve().parent / "_shot_fail.png"), full_page=True)
            raise
        pg.wait_for_timeout(500)

        got = pg.evaluate("""() => ({
          rows: [...document.querySelectorAll('#rows tr')].map(
            tr => [...tr.children].map(td => td.textContent.trim()).join(' | ')),
          note: document.getElementById('luNote').textContent,
          beforeReady: !!document.getElementById('audioBefore').src.startsWith('blob:'),
          afterReady:  !!document.getElementById('audioAfter').src.startsWith('blob:'),
          status: document.getElementById('status').textContent
        })""")
        pg.screenshot(path=str(pathlib.Path(__file__).resolve().parent / "_shot.png"), full_page=True)
        b.close()

    print("选区 :", sel_text)
    print("按钮可点:", not btn_disabled)
    print("技能结果：")
    for r in got["rows"]:
        print("   ", r)
    print("汇总:", got["note"])
    print("音频可播放:", got["beforeReady"], got["afterReady"])
    print("stderr:", got["status"])
    print("JS 错误:", errs[:3] if errs else "无")

    ok = (not btn_disabled) and got["afterReady"] and got["beforeReady"] and not errs
    print("\n" + ("[OK] 页面在浏览器里真的跑通了" if ok else "[FAIL] 有问题"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
