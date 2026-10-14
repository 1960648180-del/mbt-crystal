"""一键验证：用【真实值】对照，而不是我们手写的期望值。

期望值从哪来（越靠前越独立、越可信）
────────────────────────────────────
1. 测试数据自带的官方值
   Materials Project 导出的 CIF 里有一行 `_cell_volume`，那是官方发布的晶胞体积。
   -> 我们算出来的体积必须和它对上。**这个期望值不是我写的，是数据自带的。**

2. 第三方独立实现
   pymatgen 是 Materials Project 的官方工具链，它自己会按对称操作展开结构。
   -> 我们展开出来的原子数和坐标必须和它一致。
   **这个期望值也不是我写的。**

3. 从文件参数自算
   立方晶胞 V = a^3 —— 直接读文件里的 `_cell_length_a` 就能算出期望值。
   用来覆盖我们自己合成的用例。

4. 只有【错误用例的提示文案】是我手写的
   因为那是在测"我们自己的报错信息"，没有第三方可以对照。
   这一部分在下面的 ERROR_CASES 里明确标注出来。

用法
────
    python tests/tools/verify.py

退出码：0 = 全部通过；1 = 有失败
"""

import os
import re
import subprocess
import sys

# ── 让脚本自己就能找到 moon（不依赖你事先配好 PATH）──
os.environ["PATH"] = os.path.expanduser("~/.moon/bin") + os.pathsep + os.environ.get("PATH", "")

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
FUNCTIONAL = os.path.join(TESTS, "functional")
ERRORS = os.path.join(TESTS, "errors")

# ── 统计 ──
passed = 0
failed = 0
failures = []


def ok(label):
    global passed
    passed += 1
    print(f"  [OK]   {label}")


def ng(label, detail=""):
    global failed
    failed += 1
    failures.append(label + ("  ->  " + detail if detail else ""))
    print(f"  [FAIL] {label}" + (f"   ->  {detail}" if detail else ""))


# ── 跑我们的程序，拿到输出 ──
def run_cli(cif_path):
    """跑 moon run cmd/main -- <cif>，返回 stdout+stderr 的合并文本。"""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    p = subprocess.run(
        ["moon", "run", "cmd/main", "--", cif_path],
        cwd=ROOT, env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=180,
    )
    return (p.stdout or "") + (p.stderr or "")


# ── 从我们的输出里抠出各项数字 ──
RE_VOLUME = re.compile(r"V = ([\d.]+)")
RE_ATOM_COUNT = re.compile(r"共 (\d+) 个原子")
RE_SYMOPS = re.compile(r"显式对称操作：(\d+)")
RE_COMPOSITION = re.compile(r"组成：(.+)")
RE_WARNINGS = re.compile(r"警告（(\d+) 条）")
RE_BLOCKS = re.compile(r"共找到 (\d+) 个数据块")
RE_ATOM_ROW = re.compile(r"^  (\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*$", re.M)
RE_CRASH = re.compile(r"Unreachable|panicked|RUNTIME ERROR|Aborted")


def volumes(text):
    return [float(x) for x in RE_VOLUME.findall(text)]


def atom_count(text):
    return [int(x) for x in RE_ATOM_COUNT.findall(text)]


def symop_counts(text):
    return [int(x) for x in RE_SYMOPS.findall(text)]


def composition(text):
    return [x.strip() for x in RE_COMPOSITION.findall(text)]


def warning_count(text):
    m = RE_WARNINGS.search(text)
    return int(m.group(1)) if m else 0


def atom_coords(text):
    """抠出所有原子行的 (x, y, z)，保留 6 位小数。"""
    return [(r[2], r[3], r[4]) for r in RE_ATOM_ROW.findall(text)]


def cell_from_cif(path):
    """读 CIF 里的六个晶格参数，返回 (a, b, c, alpha, beta, gamma)。"""
    raw = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for key in ["a", "b", "c", "alpha", "beta", "gamma"]:
        name = {
            "a": "_cell_length_a", "b": "_cell_length_b", "c": "_cell_length_c",
            "alpha": "_cell_angle_alpha", "beta": "_cell_angle_beta", "gamma": "_cell_angle_gamma",
        }[key]
        m = re.search(re.escape(name) + r"\s+([\d.]+)", raw)
        out[key] = float(m.group(1)) if m else None
    return out


def official_volume(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"_cell_volume\s+([\d.]+)", raw)
    return float(m.group(1)) if m else None


# ══════════════════════════════════════════════════════════════
# 第 1 组：真实 MP 文件 —— 期望值 = 文件自带的官方 _cell_volume
# ══════════════════════════════════════════════════════════════
def group1_real_data():
    print("\n" + "=" * 78)
    print("第 1 组：真实 Materials Project 数据（期望值 = 文件自带的 _cell_volume）")
    print("=" * 78)
    files = [os.path.join(ROOT, "mp-149.cif")]
    ref_dir = os.path.join(ROOT, "mp-reference")
    if os.path.isdir(ref_dir):
        files += [os.path.join(ref_dir, n) for n in sorted(os.listdir(ref_dir)) if n.endswith(".cif")]
    # 带真实对称操作的高对称用例 + 只给空间群编号的用例
    # （都是真实 MP 数据，自带官方 _cell_volume）
    files += [os.path.join(FUNCTIONAL, n) for n in sorted(os.listdir(FUNCTIONAL))
              if (n.startswith("symop-") or n.startswith("spacegroup-")) and n.endswith(".cif")]

    for path in files:
        name = os.path.basename(path)
        if not os.path.exists(path):
            ng(f"{name}  文件不存在", path)
            continue
        text = run_cli(path)
        if RE_CRASH.search(text):
            ng(name, "程序崩溃")
            continue
        mine = volumes(text)
        ref = official_volume(path)
        w = warning_count(text)
        if not mine:
            ng(name, "没解析出体积")
        elif abs(mine[0] - ref) < 5e-6:
            ok(f"{name:24s} V={mine[0]:<14} 官方={ref:<14} 警告={w}")
        else:
            ng(f"{name:24s} V={mine[0]}", f"官方={ref}  差={abs(mine[0] - ref):.2e}")
        if w != 0 and not name.startswith("spacegroup-"):
            ng(f"{name}  警告数应为 0", f"实际 {w}")
        # 说明：spacegroup-* 的文件里没写对称操作，程序会查表并打印一条提示，
        #       所以这类文件恰好应该有 1 条警告（且只应该是那一条）。
        if name.startswith("spacegroup-") and w != 1:
            ng(f"{name}  警告数应为 1（查表提示）", f"实际 {w}")


# ══════════════════════════════════════════════════════════════
# 第 2 组：对称展开 —— 期望值 = pymatgen 的独立计算结果
# ══════════════════════════════════════════════════════════════
def group2_pymatgen():
    print("\n" + "=" * 78)
    print("第 2 组：对称展开（期望值 = pymatgen 独立计算）")
    print("  —— 含真实高对称用例（8 / 12 / 96 / 192 条操作）与只给空间群编号的用例")
    print("=" * 78)
    try:
        from pymatgen.io.cif import CifParser
    except ImportError:
        ng("pymatgen", "没安装，跳过这一组（pip install pymatgen）")
        return

    import warnings as _w
    cases = ["sym_demo.cif", "symmetry.cif", "frac_demo.cif"]
    cases += sorted(n for n in os.listdir(FUNCTIONAL)
                    if (n.startswith("symop-") or n.startswith("spacegroup-")) and n.endswith(".cif"))
    for name in cases:
        path = os.path.join(FUNCTIONAL, name)
        text = run_cli(path)
        if RE_CRASH.search(text):
            ng(name, "程序崩溃")
            continue
        ours = atom_coords(text)
        n_ours = atom_count(text)

        with _w.catch_warnings():
            _w.simplefilter("ignore")
            try:
                structs = CifParser(path).parse_structures(primitive=False, on_error="warn")
            except Exception as exc:  # noqa: BLE001
                ng(name, f"pymatgen 报错 {type(exc).__name__}")
                continue
        if not structs:
            ng(name, "pymatgen 没给出结构")
            continue
        theirs = [tuple(f"{v:.6f}" for v in site.frac_coords) for site in structs[0]]

        if not n_ours:
            ng(name, "我们没解析出原子")
        elif n_ours[0] != len(theirs):
            ng(f"{name:16s} 原子数不一致", f"我们={n_ours[0]}  pymatgen={len(theirs)}")
        elif sorted(ours) != sorted(theirs):
            ng(f"{name:16s} 坐标不一致", f"我们={sorted(ours)}  pymatgen={sorted(theirs)}")
        else:
            ok(f"{name:16s} 原子数={n_ours[0]}  坐标逐条一致（与 pymatgen）")


# ══════════════════════════════════════════════════════════════
# 第 3 组：合成用例 —— 期望值 = 从文件参数自算（立方 V = a^3）
# ══════════════════════════════════════════════════════════════
def group3_self_computed():
    print("\n" + "=" * 78)
    print("第 3 组：合成用例（期望值 = 从文件里的 a 自算，立方 V = a^3）")
    print("=" * 78)
    # 只挑晶格是立方的那些用例
    cases = ["two_blocks.cif", "nodata.cif", "mp-crlf.cif", "check_pass.cif"]
    for name in cases:
        path = os.path.join(FUNCTIONAL, name)
        text = run_cli(path)
        if RE_CRASH.search(text):
            ng(name, "程序崩溃")
            continue
        mine = volumes(text)
        cell = cell_from_cif(path)
        is_cubic = (
            abs(cell["a"] - cell["b"]) < 1e-9 and abs(cell["a"] - cell["c"]) < 1e-9
            and all(abs(cell[k] - 90.0) < 1e-6 for k in ("alpha", "beta", "gamma"))
        )
        if not is_cubic:
            ng(name, "不是立方晶胞，本组不适用")
            continue
        expect = cell["a"] ** 3
        # two_blocks.cif 有两个块、a 不同，所以只比第一个块的期望值
        if abs(mine[0] - expect) < 5e-6:
            ok(f"{name:24s} V={mine[0]:<14} a^3={expect:.6f}")
        else:
            ng(f"{name:24s} V={mine[0]}", f"a^3={expect:.6f}  差={abs(mine[0]-expect):.2e}")


# ══════════════════════════════════════════════════════════════
# 第 4 组：错误用例 —— 只验"不崩溃 + 提示里含关键词"
#         ⚠️ 这一组的期望关键词是【手写】的（没有第三方可对照）
# ══════════════════════════════════════════════════════════════
ERROR_CASES = {
    "01-empty.cif": "文件是空的",
    "02-only-comments.cif": "没有 data_ 行",
    "03-missing-param.cif": "找不到晶格参数 _cell_length_c",
    "04-not-a-number.cif": "不是合法数字",
    "05-question-mark.cif": "数值缺失",
    "06-dot.cif": "数值缺失",
    "07-illegal-angle.cif": "凑不出真实晶胞",
    "08-bad-coord.cif": "坐标位置读到的值是",
    "09-missing-column.cif": "原子位点表缺列",
    "10-short-row.cif": "只有表头",
    "11-upper-key.cif": "找不到晶格参数 _cell_length_a",
    "12-bracket.cif": "没有找到原子位点表",
}


def group4_errors():
    print("\n" + "=" * 78)
    print("第 4 组：错误用例（期望关键词是手写的 —— 没有第三方可以对照）")
    print("=" * 78)
    for name in sorted(ERROR_CASES):
        path = os.path.join(ERRORS, name)
        if not os.path.exists(path):
            ng(f"{name:24s} 文件不存在", path)
            continue
        text = run_cli(path)
        if RE_CRASH.search(text):
            ng(f"{name:24s} 程序崩溃")
            continue
        key = ERROR_CASES[name]
        if key in text:
            ok(f"{name:24s} 不崩溃，提示含『{key}』")
        else:
            ng(f"{name:24s} 提示里没有『{key}』")


# ══════════════════════════════════════════════════════════════
def main():
    print("═" * 78)
    print("一键验证 —— 期望值全部来自真实来源（官方字段 / pymatgen / 自算）")
    print("═" * 78)
    group1_real_data()
    group2_pymatgen()
    group3_self_computed()
    group4_errors()
    print("\n" + "═" * 78)
    total = passed + failed
    print(f"结果：{total} 项检查，通过 {passed}，失败 {failed}")
    if failures:
        print("\n失败清单：")
        for f in failures:
            print("  - " + f)
    print("═" * 78)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
