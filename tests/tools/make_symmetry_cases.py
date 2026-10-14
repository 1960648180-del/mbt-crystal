"""生成"带真实对称操作"的测试用例。

为什么需要这个
──────────────
Materials Project 导出的 CIF 全部是 `P 1`，对称操作只有一条 `'x, y, z'`。
也就是说：在我们补上这个脚本之前，**"多条对称操作"从来没有被真实验证过** ——
而真实的晶体学文件（COD、ICSD、论文补充材料）通常写出完整的对称操作，
可能有 8 条、12 条、96 条甚至 192 条。

做法
────
拿 `mp-reference/` 里已有的真实结构（它们本身是 P1，对称信息丢了），
用 spglib 把对称性**找回来**，再用 CifWriter 写出**带完整显式对称操作**的 CIF。

产物 = 真实材料 + 真实对称操作，放在 `tests/functional/` 下，文件名以 `symop-` 开头。

期望值
──────
**这个脚本不写死期望值。** 对照由 `verify.py` 现场调 pymatgen 算一遍来完成 ——
期望值来自第三方独立实现，不是我们自己写的数。

用法
────
    python tests/tools/make_symmetry_cases.py
"""

import os
import sys

try:
    from pymatgen.io.cif import CifParser, CifWriter
except ImportError as exc:
    print("导入 pymatgen 失败：", exc)
    print("安装命令：pip install pymatgen")
    sys.exit(1)

# ⚠️ pymatgen 在不同版本里这个类名的大小写不一样：
#     新版：SpacegroupAnalyzer（小写 g）
#     旧版：SpaceGroupAnalyzer
# 两种都试一下，免得因为版本差异直接挂掉。
try:
    from pymatgen.symmetry.analyzer import SpacegroupAnalyzer
except ImportError:
    from pymatgen.symmetry.analyzer import SpaceGroupAnalyzer as SpacegroupAnalyzer

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
ROOT = os.path.dirname(TESTS)
REF_DIR = os.path.join(ROOT, "mp-reference")
OUT_DIR = os.path.join(TESTS, "functional")

# 覆盖不同对称复杂度的真实材料
CASES = [
    # 源文件（真实 MP 导出，P1）        产物文件名                      预期空间群
    ("Ga2O3-C2_m.cif",            "symop-ga2o3-c2m.cif",       "C2/m  —— 单斜、带 C 面心 + 螺旋轴"),
    ("GaN-P6_3mc.cif",            "symop-gan-p63mc.cif",       "P6_3mc —— 六方、带 1/3 和 2/3 平移"),
    ("SiC-F-43m.cif",             "symop-sic-f43m.cif",        "F-43m —— 立方、面心 + 四重反轴"),
    ("C-Fd-3m.cif",               "symop-diamond-fd3m.cif",    "Fd-3m —— 金刚石型，对称操作最多"),
]

SYMPREC = 1e-3  # 找对称性的容差。太松会认错群，太紧会找不到。


def main():
    if not os.path.isdir(REF_DIR):
        print(f"找不到 {REF_DIR}")
        return 1

    print("=" * 76)
    print("生成带真实对称操作的测试用例")
    print("=" * 76)

    for src_name, dst_name, note in CASES:
        src = os.path.join(REF_DIR, src_name)
        dst = os.path.join(OUT_DIR, dst_name)
        if not os.path.exists(src):
            print(f"  [跳过] {src_name} 不存在")
            continue

        struct = CifParser(src).parse_structures(primitive=False, on_error="warn")[0]
        sga = SpacegroupAnalyzer(struct, symprec=SYMPREC)
        sym = sga.get_symmetry_operations()
        conv = sga.get_conventional_standard_structure()

        CifWriter(conv, symprec=SYMPREC).write_file(dst)

        # 核对一下：写出来的文件里到底列了几条对称操作
        in_ops = False
        n_written = 0
        for line in open(dst, encoding="utf-8").read().splitlines():
            s = line.strip()
            if s == "loop_":
                in_ops = False
            elif s == "_symmetry_equiv_pos_as_xyz":
                in_ops = True
            elif in_ops and "'" in s:
                n_written += 1

        print(f"  [写好] {dst_name}")
        print(f"         {note}")
        print(f"         检出空间群 = {sga.get_space_group_symbol()} "
              f"(#{sga.get_space_group_number()})，"
              f"对称操作 {len(sym)} 条（文件里写了 {n_written} 条），"
              f"常规胞原子数 {len(conv)}")

    print("\n" + "=" * 76)
    print("提示：这些文件的期望展开结果不写在这里 —— 由 verify.py 用 pymatgen 现场对照。")
    print("=" * 76)
    return 0


if __name__ == "__main__":
    sys.exit(main())
