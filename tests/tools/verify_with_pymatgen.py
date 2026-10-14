"""用 pymatgen 独立复核我们的对称展开结果。

为什么用 pymatgen 当"标准答案"
──────────────────────────────
pymatgen 是 Materials Project 的官方工具链，全球材料计算领域的事实标准，
被引用上万次。它的 CifParser 会自己按显式对称操作把"不对称单元"展开成
完整晶胞 —— 所以拿它的原子数和分数坐标，就能判定我们的实现对不对。

这是**独立验证**：我们没看它的代码，它也不知道我们的存在，
两边如果一致，说明我们的实现没有跑偏。

用法
────
    python tests/tools/verify_with_pymatgen.py

输出应当与下面这几条命令的输出一致：
    moon run . -- tests/functional/sym_demo.cif
    moon run . -- tests/functional/symmetry.cif
    moon run . -- tests/functional/frac_demo.cif
"""

import os
import sys
import warnings

try:
    from pymatgen.io.cif import CifParser
except ImportError:
    print("没装 pymatgen。安装命令：pip install pymatgen")
    sys.exit(1)

# 本脚本放在 tests/tools/ 下，测试文件在 tests/functional/
HERE = os.path.dirname(os.path.abspath(__file__))
FUNCTIONAL = os.path.join(os.path.dirname(HERE), "functional")

CASES = [
    "sym_demo.cif",   # 2 条操作，负坐标要折回
    "symmetry.cif",   # 同上，但用了别名关键字
    "frac_demo.cif",  # 1/3、2/3 分数平移
]

for name in CASES:
    path = os.path.join(FUNCTIONAL, name)
    print("=" * 72)
    if not os.path.exists(path):
        print(f"{name}  ->  找不到文件：{path}")
        continue
    print(name)
    # pymatgen 对"化学式对不上"之类的情况会发警告，这里静音掉，只看结构
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            parser = CifParser(path)
            structures = parser.parse_structures(primitive=False, on_error="warn")
        except Exception as exc:  # noqa: BLE001
            print("  pymatgen 报错:", type(exc).__name__, exc)
            continue

    for s in structures:
        print(f"  pymatgen 展开后原子数 = {len(s)}   组成 = {s.composition}")
        for site in s:
            x, y, z = site.frac_coords
            print(f"    {site.species_string:6s}  {x:.6f}  {y:.6f}  {z:.6f}")

print("=" * 72)
print("对照要点：原子数要相同，坐标要逐条一致（我们按 6 位小数打印）。")
