#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探查：空间群"设置歧义"到底影响多少号、我们的表选的是哪一个

背景（晶体学常识，也是我们这个工具最可能"静默算错"的地方）：
    一个国际编号（IT number, 1~230）有时对应**多个 Hall 设置**：
      · origin choice 1 / 2  —— 常见于 Fd-3m、Fddd、I41/amd 等含反演中心的群
      · 唯一轴选 a / b / c   —— 单斜晶系
      · 菱方轴 / 六方轴      —— R 格子（如 R-3m #166）
    这些设置下的**对称操作列表是不一样的**（有的还差一个原点平移 1/8）。

    我们的 spacegroup_table.mbt 是"每个编号取第一个 Hall 设置"生成的
    （见 tests/tools/gen_spacegroups.py）。如果一个 CIF 只给编号、
    不列操作，而且它用的是**另一个设置**，我们就会拿错的操作去展开 ——
    原子个数可能还对得上，坐标却整体错了，属于最危险的那种错。

这个脚本不修改任何东西，只把"影响范围"和"我们选了哪个"打印出来。

用法：python tests/tools/check_settings.py
"""

import sys

try:
    import spglib
except ImportError:
    print("需要 spglib：pip install spglib")
    sys.exit(2)


def main():
    # 收集：每个 IT 编号 -> 它有哪些 Hall 设置
    by_number = {}
    for hall in range(1, 531 + 1):
        t = spglib.get_spacegroup_type(hall)
        if t is None:
            continue
        by_number.setdefault(t.number, []).append(
            (hall, t.hall_symbol, t.choice, t.international_short)
        )

    ambiguous = {n: v for n, v in by_number.items() if len(v) > 1}
    total_ops = {}
    for n, entries in by_number.items():
        # 我们的生成脚本取的是该编号的第一个 Hall 设置
        first_hall = entries[0][0]
        total_ops[n] = len(spglib.get_symmetry_from_database(first_hall)["rotations"])

    print("=" * 78)
    print("空间群「设置歧义」影响范围")
    print("=" * 78)
    print(f"  1~230 里一共有 {len(by_number)} 个编号有数据")
    print(f"  其中 {len(ambiguous)} 个编号对应**多个设置**（有歧义）")
    print(f"  其余 {len(by_number) - len(ambiguous)} 个编号只有一种设置（一定能对上）")
    print()

    # 按"设置种类"分类，看看到底是哪些类型的歧义
    kinds = {"origin choice": 0, "唯一轴": 0, "菱方/六方": 0, "其他": 0}
    for n, entries in ambiguous.items():
        choices = " ".join((e[2] or "").strip() for e in entries)
        if any(c in choices for c in ("1", "2")) and "b" not in choices:
            kinds["origin choice"] += 1
        elif "b" in choices or "c" in choices or "a" in choices:
            kinds["唯一轴"] += 1
        elif "H" in choices or "R" in choices:
            kinds["菱方/六方"] += 1
        else:
            kinds["其他"] += 1

    print("  歧义的种类：")
    for k, v in kinds.items():
        if v:
            print(f"    {k}：{v} 个编号")
    print()

    print("=" * 78)
    print("逐个看（只列有歧义的）——重点看我们选的那个设置对不对")
    print("=" * 78)
    print(f"  {'编号':<6}{'符号':<12}{'我们选的(第一个)':<26}{'还有哪些设置'}")
    print("  " + "-" * 74)
    for n in sorted(ambiguous):
        entries = ambiguous[n]
        first = entries[0]
        others = " | ".join(
            f"hall {h} choice={c or '-'}" for h, _, c, _ in entries[1:]
        )
        print(
            f"  {n:<6}{first[3]:<12}"
            f"hall {first[0]} choice={first[2] or '-':<10}{others}"
        )

    print()
    print("=" * 78)
    print("最需要盯的几个（对材料计算最常见的）：")
    print("=" * 78)
    for n in (12, 14, 15, 62, 70, 141, 142, 166, 167, 201, 203, 222, 224, 227, 228):
        if n not in by_number:
            continue
        entries = by_number[n]
        sym = entries[0][3]
        first_hall = entries[0][0]
        nops = len(spglib.get_symmetry_from_database(first_hall)["rotations"])
        alt = len(entries) - 1
        flag = "⚠ 多设置" if alt else "  单一设置"
        print(
            f"  {flag}  #{n:<5}{sym:<12}我们取 hall {first_hall}"
            f"（{nops} 条操作），另有 {alt} 个设置"
        )

    print()
    print("结论提示：")
    print("  · 单一设置的编号 = 查表一定对得上，无需担心")
    print("  · 多设置的编号 = 只有文件用的是「和 spglib 第一个 Hall 设置相同」那一套时才对")
    print("    真实 CIF 若声明了别的设置（比如 origin choice 1），我们会静默算错坐标")
    print("  · 缓解办法：这类文件通常**会显式列出对称操作**，而我们是「显式优先」——")
    print("    所以风险主要在「只给编号 + 非标准设置」这种双重条件下")


def orbit(ops, xyz):
    """把对称操作作用在一个分数坐标上，返回去重后的坐标集合"""
    out = []
    for R, t in zip(ops["rotations"], ops["translations"]):
        v = R @ xyz + t
        key = tuple(round(float(c) % 1.0, 6) for c in v)
        if key not in out:
            out.append(key)
    return sorted(out)


def demo():
    """演示：同一份文件内容（同一个编号 + 同一个原子），
    用不同设置算出来的结果**不一样** —— 这就是"静默算错"的来源"""
    print()
    print("=" * 78)
    print("决定性演示：同一份输入，两种设置，结果不同")
    print("=" * 78)

    cases = [
        # (编号, 符号, 原子坐标, 说明)
        (227, "Fd-3m", (0.0, 0.0, 0.0), "origin choice 1 / 2 差别只是原点平移"),
        (166, "R-3m", (0.0, 0.0, 0.0), "六方轴 vs 菱方轴：连原子个数都不一样"),
        (14, "P2_1/c", (0.1, 0.2, 0.3), "单斜唯一轴 b / c / a"),
    ]

    for number, symbol, xyz, note in cases:
        halls = [h for h in range(1, 531) if (spglib.get_spacegroup_type(h) or None) and spglib.get_spacegroup_type(h).number == number]
        ours = halls[0]                     # 我们的表用的就是这个
        print()
        print(f"  #{number} {symbol} —— {note}")
        base = orbit(spglib.get_symmetry_from_database(ours), xyz)
        print(f"    我们取 hall {ours}（{len(base)} 个位置）")
        for h in halls[1:]:
            alt = orbit(spglib.get_symmetry_from_database(h), xyz)
            same = alt == base
            tag = "结果相同（这个设置没影响）" if same else "**结果不同 ✗ 我们会算错**"
            print(f"    hall {h} choice={spglib.get_spacegroup_type(h).choice or '-':<4}"
                  f"（{len(alt)} 个位置）→ {tag}")

    print()
    print("注：")
    print("  · 金刚石那类 origin choice 差异 = 整体平移 1/8，原子个数**恰好看不出错**，")
    print("    属于最难发现的一种；好在物理结构其实等价（只是原点约定不同）。")
    print("  · R 格子（菱方/六方）差异是**真的算错**：个数和坐标都不对。")
    print("  · 单斜唯一轴差异也是真的算错。")
    print("  · 三种都只在「文件只给编号、不列操作」时才会发生 —— 文件若列了操作，")
    print("    我们走「显式优先」，一定用文件自己的那套，绝不会出错。")


if __name__ == "__main__":
    main()
    demo()
