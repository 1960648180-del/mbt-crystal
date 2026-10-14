"""生成「空间群编号 → 对称操作」查找表（MoonBit 源码）。

为什么需要它
────────────
本项目目前只支持 CIF 里**显式写出**的对称操作。但真实世界里很多 CIF
（部分论文补充材料、部分数据库导出）**只给一个空间群编号**，不列操作。
那种文件拿过来跑，工具不会展开 —— 这一层就是把缺口补上。

数据从哪来
──────────
spglib 的空间群数据库。国际编号（1~230）在数据库里可能对应多个 Hall 设置，
这里每个编号取**第一个**（即默认/标准设置），这与 CIF 里
`_symmetry_Int_Tables_number` 的通常含义一致。

输出
────
`spacegroup_table.mbt`：一个 `spacegroup_ops(number : Int) -> Array[String]` 函数，
返回该空间群的对称操作字符串（形如 `"-y,x-y,z+1/3"`），可以直接交给
`cif.mbt` 里已有的 `parse_symop` 解析 —— 不重复实现解析逻辑。

用法
────
    python tests/tools/gen_spacegroups.py            # 生成
    python tests/tools/gen_spacegroups.py --dry-run  # 只看统计，不写文件
"""

import os
import sys
from fractions import Fraction

try:
    import spglib
except ImportError:
    print("没装 spglib。安装：pip install spglib")
    raise SystemExit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "spacegroup_table.mbt")

# 写入前的大小保护：超过这个字符数就不写，先让人看一眼
MAX_CHARS = 600_000


def fmt_row(row, trans):
    """把一行（3 个系数 + 一个平移量）写成 CIF 风格的表达式，例如 -y+1/3"""
    parts = []
    for j, c in enumerate(row):
        if c == 0:
            continue
        var = "xyz"[j]
        if c == 1:
            parts.append("+" + var)
        elif c == -1:
            parts.append("-" + var)
        else:
            parts.append(f"+{c}{var}")

    frac = Fraction(float(trans)).limit_denominator(12)
    if frac != 0:
        sign = "+" if frac > 0 else "-"
        num, den = abs(frac.numerator), frac.denominator
        parts.append(sign + (str(num) if den == 1 else f"{num}/{den}"))

    s = "".join(parts)
    if not s:
        return "0"
    return s[1:] if s[0] == "+" else s


def ops_to_strings(hall_number):
    """取某个 Hall 设置的全部对称操作，转成 'a,b,c' 形式的字符串列表"""
    data = spglib.get_symmetry_from_database(hall_number)
    if data is None:
        return []
    out = []
    for rot, trans in zip(data["rotations"], data["translations"]):
        rows = [fmt_row(rot[i], trans[i]) for i in range(3)]
        out.append(",".join(rows))
    return out


def main():
    dry_run = "--dry-run" in sys.argv

    # 每个国际编号取第一个 Hall 编号（默认设置）
    first_hall = {}
    for hall in range(1, 531):
        t = spglib.get_spacegroup_type(hall)
        if t is None:
            continue
        first_hall.setdefault(t.number, hall)

    numbers = sorted(first_hall)
    print(f"国际编号覆盖：{len(numbers)} 个（应为 230）")

    table = {}
    total_ops = 0
    for n in numbers:
        ops = ops_to_strings(first_hall[n])
        table[n] = ops
        total_ops += len(ops)

    biggest = max(table.items(), key=lambda kv: len(kv[1]))
    print(f"对称操作总数：{total_ops}")
    print(f"最多的一个群：#{biggest[0]}  有 {len(biggest[1])} 条操作")
    print(f"平均每个群：{total_ops / len(numbers):.1f} 条")
    print(f"操作字符串平均长度：{sum(len(o) for ops in table.values() for o in ops) / total_ops:.1f} 字符")

    # 生成 MoonBit 源码
    lines = []
    lines.append("/// ================================================================")
    lines.append("///  「空间群编号 → 对称操作」查找表")
    lines.append("///")
    lines.append("///  ⚠️ 本文件由 tests/tools/gen_spacegroups.py 自动生成，请勿手工修改。")
    lines.append("///")
    lines.append("///  数据来源：spglib 的空间群数据库（每个国际编号取默认 Hall 设置）")
    lines.append("///  用途：当 CIF 只给了空间群编号、没有显式列出对称操作时，按编号查这张表。")
    lines.append("///  返回值是 CIF 风格的字符串（形如 \"-y,x-y,z+1/3\"），交给 parse_symop 解析。")
    lines.append("/// ================================================================")
    lines.append("")
    lines.append("/// 按国际编号（1~230）取对称操作字符串；未知编号返回空数组")
    lines.append("fn spacegroup_ops(number : Int) -> Array[String] {")
    lines.append("  match number {")
    for n in numbers:
        ops = table[n]
        body = ", ".join('"' + o + '"' for o in ops)
        lines.append(f"    {n} => [{body}]")
    lines.append("    _ => []")
    lines.append("  }")
    lines.append("}")
    text = "\n".join(lines) + "\n"

    print(f"\n生成源码大小：{len(text):,} 字符  （约 {len(text) / 1024:.0f} KB）")
    print(f"行数：{len(lines):,}")

    if len(text) > MAX_CHARS:
        print(f"\n⚠️ 超过保护上限 {MAX_CHARS:,} 字符，**没有写文件**。")
        print("   请先决定：是接受这个体积，还是只收录常用空间群。")
        return 1

    if dry_run:
        print("\n（--dry-run：只统计，没有写文件）")
        return 0

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"\n已写入：{os.path.relpath(OUT, ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
