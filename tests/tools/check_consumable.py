#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「这个库真的能被外部依赖吗？」——让一个外来模块真实调用本库的公开接口

为什么单独做这么一个检查：
    在 MoonBit 里，一个包只能是「库」或「可执行程序」二选一。
    我们早期整包是 executable，结果**别的 MoonBit 项目在语法上根本
    import 不了它** —— 文件解析得再准，别人也用不上。
    这个检查就是防止那种倒退悄悄发生：它不看解析结果，只看
    「一个外人能不能把库装起来、构造它的类型、调到它的函数」。

做法（不需要先发布到 mooncakes.io）：
    官方支持用 moon.work 工作区把本地模块当依赖（import 里写的
    @version 会被忽略，直接从本地源码解析）。所以我们临时造一个
    消费者模块，让它 import 本库并调用公开接口。

    ⚠️ 消费者模块必须建在**仓库外面**：建在仓库里它就成了我们自己的
       一个包，那就不是"外人"了，检查也就失去意义。

用法：
    python tests/tools/check_consumable.py          跑完自动清理
    python tests/tools/check_consumable.py --keep   保留临时目录，便于人工翻看
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # 仓库根目录
FIXTURE = "tests/functional/spacegroup-gan-186.cif"    # 用一个"只给空间群编号"的用例

# ─────────────────────────────────────────────────────────────────
# 下面是"外来模块"的全部源码。它只用公开接口（pub 的那些）。
# ─────────────────────────────────────────────────────────────────

PROBE_MAIN = r'''/// 外部消费者探针（本文件由 tests/tools/check_consumable.py 生成）
///
/// 它不属于 mbt-crystal 仓库 —— 它是"外人"，靠 moon.work 把 mbt-crystal
/// 当普通依赖来用。这里只碰公开接口，碰不到任何内部实现。
///
/// 跑法：moon run . -- <CIF 文件路径>

fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("用法：moon run . -- <CIF 文件路径>")
    return
  }

  // ① 纯计算接口：给三个边长 + 三个夹角，直接算体积
  let lat : @lib.Lattice = @lib.Lattice::{
    a: 3.18893040,
    b: 3.18893040,
    c: 5.19235725,
    alpha: 90.0,
    beta: 90.0,
    gamma: 120.0,
  }
  println("① cell_volume(六方晶胞) = " + @lib.cell_volume(lat).to_string())

  // ② 查空间群表，再自己把"操作文本"解析成结构体
  let texts = @lib.spacegroup_ops(186)
  println("② spacegroup_ops(186) = " + texts.length().to_string() + " 条操作")
  let ops : Array[@lib.SymOp] = []
  for t in texts {
    let op : @lib.SymOp = @lib.parse_symop(t) catch { _ => @lib.SymOp::{ parts: [] } }
    ops.push(op)
  }

  // ③ 直接解析一份 CIF（路径由命令行传进来，不写死平台相关的路径）
  let text = @fs.read_file_to_string(args[1]) catch {
    _ => ""
  }
  if text == "" {
    println("③ 读不到文件：" + args[1])
    return
  }
  let result : @lib.CifResult = @lib.parse_cif(text, @lib.Warn) catch {
    Failure(msg) => {
      println("③ 解析失败：" + msg)
      return
    }
  }
  println("③ 解析出 " + result.block_count.to_string() + " 个数据块")
  for crystal in result.crystals {
    println(
      "   块 [" +
      crystal.name +
      "]：" +
      crystal.atoms.length().to_string() +
      " 个原子，组成 " +
      @lib.composition_to_string(@lib.composition_of_atoms(crystal.atoms)),
    )
  }
  println("   警告 " + result.warnings.length().to_string() + " 条")

  // ④ 拿②里的操作，把一个原子展开成完整晶胞（自己在外部构造 Atom）
  let asym : Array[@lib.Atom] = [
    @lib.Atom::{ element: "C", label: "C0", x: 0.0, y: 0.0, z: 0.0 },
  ]
  let full = @lib.expand_atoms(asym, ops)
  println(
    "④ expand_atoms(1 个原子 × " +
    ops.length().to_string() +
    " 条操作) = " +
    full.length().to_string() +
    " 个原子",
  )
}
'''

PROBE_PKG = r'''import {
  "moonbitlang/x/fs",
  "moonbitlang/core/env",
  "@MODULE@" @lib,
}

pkgtype(kind: "executable")
'''

PROBE_MOD = r'''name = "probe/consumer"

version = "0.1.0"

preferred_target = "wasm"

// 这个模块的唯一依赖就是本库 —— 它就是个"外来的使用者"
import {
  "@DEP@",
  "@XPKG@",
}
'''

WORKSPACE = r'''// 把"消费者模块"和 mbt-crystal 本体放进同一个工作区，
// 这样 probe 就能把本库当普通依赖用（@version 会被忽略，直接取本地源码）
members = [
  "@ROOT@",
  "probe",
]
'''


def read_module_info():
    """从仓库的 moon.mod 里读出模块名和 moonbitlang/x 的版本，避免写死"""
    with open(os.path.join(ROOT, "moon.mod"), encoding="utf-8") as f:
        text = f.read()
    m = re.search(r'^name\s*=\s*"([^"]+)"', text, re.M)
    if not m:
        print("!! 读不出 moon.mod 里的模块名")
        sys.exit(2)
    module = m.group(1)
    x = re.search(r'"(moonbitlang/x)@([0-9][^"]*)"', text)
    x_dep = f"{x.group(1)}@{x.group(2)}" if x else "moonbitlang/x"
    version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
    return module, (version.group(1) if version else "0.1.0"), x_dep


def main():
    keep = "--keep" in sys.argv
    module, version, x_dep = read_module_info()
    root_abs = ROOT.replace("\\", "/")

    workdir = tempfile.mkdtemp(prefix="mbt-crystal-consumer-")
    probe = os.path.join(workdir, "probe")
    os.makedirs(probe, exist_ok=True)

    try:
        # 先确认它真的在仓库外面（否则这个检查就是自欺）
        try:
            inside = os.path.commonpath(
                [os.path.abspath(workdir), os.path.abspath(ROOT)]
            ) == os.path.abspath(ROOT)
        except ValueError:
            # 跨盘符（比如仓库在 D:、临时目录在 C:）→ 只可能是外面
            inside = False
        if inside:
            print("!! 临时目录落在仓库里了，这个检查会失去意义")
            sys.exit(2)

        with open(os.path.join(workdir, "moon.work"), "w", encoding="utf-8") as f:
            f.write(WORKSPACE.replace("@ROOT@", root_abs))
        with open(os.path.join(probe, "moon.pkg"), "w", encoding="utf-8") as f:
            f.write(PROBE_PKG.replace("@MODULE@", module))
        with open(os.path.join(probe, "moon.mod"), "w", encoding="utf-8") as f:
            f.write(
                PROBE_MOD.replace("@DEP@", f"{module}@{version}").replace("@XPKG@", x_dep)
            )
        with open(os.path.join(probe, "main.mbt"), "w", encoding="utf-8") as f:
            f.write(PROBE_MAIN)

        print("=" * 78)
        print("可被外部依赖吗？（消费者模块建在仓库外面）")
        print("=" * 78)
        print(f"  被依赖的模块：{module}@{version}")
        print(f"  消费者模块：  {os.path.join(workdir, 'probe')}")

        env = dict(os.environ)
        env["GIT_TERMINAL_PROMPT"] = "0"
        p = subprocess.run(
            ["moon", "run", ".", "--", os.path.join(ROOT, FIXTURE)],
            cwd=probe, env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=600,
        )
        out = (p.stdout or "") + (p.stderr or "")

        # 只看"程序自己打出来的"几行，编译警告不参与判断
        # （注意：先 strip 再判断，所以匹配的是去掉缩进后的样子）
        def keep_line(ln):
            s = ln.strip()
            return (
                s.startswith(("①", "②", "③", "④"))
                or s.startswith("块 [")
                or s.startswith("警告 ")
            )

        lines = [ln.strip() for ln in out.splitlines() if keep_line(ln)]
        print("\n  消费者程序输出：")
        for ln in lines:
            print("    " + ln)

        passed = 0
        failed = 0

        def chk(label, cond, detail=""):
            nonlocal passed, failed
            if cond:
                passed += 1
                print(f"  [OK]   {label}")
            else:
                failed += 1
                print(f"  [FAIL] {label}" + (f"   ->  {detail}" if detail else ""))

        joined = "\n".join(lines)
        chk("编译通过并跑起来了", p.returncode == 0 and len(lines) > 0,
            f"退出码 {p.returncode}")
        chk("① 能构造 Lattice 并算出体积 45.7283",
            "45.7283" in joined)
        chk("② 能调用 spacegroup_ops(186) 得到 12 条",
            "12 条操作" in joined)
        chk("③ 能调用 parse_cif 解析出 Ga2 N2 / 4 个原子",
            "Ga2 N2" in joined and "4 个原子" in joined)
        chk("④ 能构造 Atom 并调用 expand_atoms",
            "expand_atoms" in joined and "= 2 个原子" in joined)

        print("\n" + "=" * 78)
        print(f"结果：{passed + failed} 项检查，通过 {passed}，失败 {failed}")
        print("=" * 78)
        if failed and len(lines) == 0:
            print("\n（一句话都没打出来，下面是完整输出，便于排查）")
            print(out[-2000:])
        return 1 if failed else 0
    finally:
        if keep:
            print(f"\n（临时目录已保留：{workdir}）")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
