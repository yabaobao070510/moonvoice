"""用无头浏览器验证演示页真的能跑（不是"看起来能跑"）。

验证项：
  1. 素材解码
  2. 办公室场景：自动运行完成；波形有内容；成品复测响度 ≈ -24 LUFS；削波 = 0；
     时长 ≈ 60 s；结果音频可播放
  3. 上传场景：喂一个本地 WAV 文件，管线跑完
  4. 无 JS 报错；移动端视口无横向溢出；落截图供目检

用法：python demo/_verify.py
"""

from __future__ import annotations

import pathlib
import sys

from playwright.sync_api import sync_playwright

DEMO = pathlib.Path(__file__).resolve().parent
PAGE = DEMO / "index.html"
UPLOAD_FIXTURE = DEMO / "office_before.wav"        # 构建中间物，用它当"用户的录音"
SHOT_DESKTOP = DEMO / "_shot_desktop.png"
SHOT_MOBILE = DEMO / "_shot_mobile.png"
SHOT_FAIL = DEMO / "_shot_fail.png"


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if not UPLOAD_FIXTURE.exists():
        sys.exit("缺少 upload 测试素材（先跑 demo/build_materials.py）")

    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1000, "height": 1200})
        errs: list[str] = []
        pg.on("pageerror", lambda e: errs.append(f"pageerror: {e}"))
        pg.on("console", lambda m: errs.append(f"console.{m.type}: {m.text}") if m.type == "error" else None)
        pg.goto(PAGE.as_uri(), wait_until="load")

        fails: list[str] = []

        def check(name: str, cond: bool, extra: str = "") -> None:
            print(("  [OK] " if cond else "  [!!] ") + name + (f" — {extra}" if extra else ""))
            if not cond:
                fails.append(name)

        try:
            pg.wait_for_function("window.__mv && window.__mv.ready", timeout=30000)
            pg.wait_for_function("window.__mv.warm", timeout=60000)
            pg.wait_for_function("window.__mv.ran.office && window.__mv.ran.office.afterUrl", timeout=90000)
        except Exception:
            print("!! 初始化或办公室场景未完成：")
            print("   __mv =", pg.evaluate("window.__mv || null"))
            print("   status =", pg.inner_text("#status"))
            print("   JS 错误 =", errs[:6])
            pg.screenshot(path=str(SHOT_FAIL), full_page=True)
            raise

        print("== 办公室场景 ==")
        o = pg.evaluate("window.__mv.ran.office")
        check("段数 >= 1", o["segs"] >= 1, f"segs={o['segs']}")
        check("成品响度 ≈ -24 LUFS", abs(o["afterLufs"] + 24) < 1.0, f"afterLufs={o['afterLufs']:.2f}")
        check("削波 = 0", o["clips"] == 0, f"clips={o['clips']}")
        check("成品时长 ≈ 60 s", abs(o["afterDur"] - 60) < 2, f"afterDur={o['afterDur']:.1f}")
        met = pg.inner_text("#metAfter")
        check("成品复测文案在页面上", "复测" in met and "-24" in met, met[:80])

        # 波形真的画了（统计画布上的墨色像素：alpha>0 且 RGB 深色）
        px = pg.evaluate("""() => {
          const f = (id) => { const cv = document.getElementById(id);
            const d = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data;
            let n = 0; for (let i = 0; i < d.length; i += 4) if (d[i+3] > 0 && d[i] < 120) n++; return n; };
          return { before: f('waveBefore'), after: f('waveAfter') }; }""")
        check("原始波形有内容", px["before"] > 40, f"ink px={px['before']}")
        check("成品波形有内容", px["after"] > 40, f"ink px={px['after']}")
        check("波形对照成立（成品墨量>>原始）", px["after"] > px["before"] * 5,
              f"before={px['before']} after={px['after']}")
        pg.screenshot(path=str(SHOT_DESKTOP), full_page=True)

        print("== 上传场景 ==")
        pg.wait_for_timeout(500)
        pg.click('button[data-scn="upload"]')
        pg.wait_for_timeout(300)
        pg.set_input_files("#fileIn", str(UPLOAD_FIXTURE))
        pg.wait_for_function("window.__mv.ran.upload && window.__mv.ran.upload.afterUrl", timeout=90000)
        up = pg.evaluate("window.__mv.ran.upload")
        check("上传管线跑完", up["afterDur"] > 1, f"afterDur={up['afterDur']:.1f}")
        check("上传成品削波 = 0", up["clips"] == 0, f"clips={up['clips']}")

        print("== 收尾截图（办公室 + 展开技能数据表）==")
        pg.click('button[data-scn="office"]')
        pg.wait_for_timeout(500)
        pg.evaluate("document.getElementById('details').open = true")
        pg.wait_for_timeout(200)
        pg.screenshot(path=str(SHOT_DESKTOP), full_page=True)

        print("== 移动端视口 ==")
        pg.set_viewport_size({"width": 390, "height": 900})
        pg.wait_for_timeout(600)
        overflow = pg.evaluate("document.documentElement.scrollWidth - window.innerWidth")
        check("无横向溢出", overflow <= 1, f"overflow={overflow}px")
        pg.screenshot(path=str(SHOT_MOBILE), full_page=True)

        check("无 JS 报错", not errs, "; ".join(errs[:3]) if errs else "")
        b.close()

    print()
    if fails:
        print(f"[FAIL] {len(fails)} 项未过：" + "; ".join(fails))
        sys.exit(1)
    print("[OK] 页面在浏览器里真的跑通了（截图：_shot_desktop.png / _shot_mobile.png）")


if __name__ == "__main__":
    main()
