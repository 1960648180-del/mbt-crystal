/// ---------------------------------------------------------------
/// 打印（属于"展示层"，所以放在 CLI 包里而不是库里）
///
/// 库只做计算、只吐数据；把数据排版成给人看的文字是命令行程序的事。
/// 这样别人把库嵌进自己的程序时，不会被我们的排版风格绑架。
/// ---------------------------------------------------------------

/// 把小数转成字符串（保留 6 位后四舍五入，末尾多余的 0 会自动省掉）
/// 纯粹为了打印整齐，不影响任何计算
/// 为什么从 4 位提到 6 位：原来会把 1/3 打成 0.3333，
/// 而 pymatgen 打的是 0.333333 —— 两边一比就显得我们"算不准"
fn fmt(x : Double) -> String {
  (@double.round(x * 1000000.0) / 1000000.0).to_string()
}

/// 在左边补 '0' 直到长度够（右边补位用内置的 pad_end）
/// 例：pad_zeros_left("1", 3) -> "001"
fn pad_zeros_left(s : String, width : Int) -> String {
  let mut out = s
  while out.length() < width {
    out = "0" + out
  }
  out
}

/// 分数坐标按"固定 6 位小数"打印（对齐 pymatgen 的 %.6f 风格）
/// 和 fmt 的区别：fmt 会省掉末尾的 0（0.1 打成 "0.1"），
/// 这个一定会补齐 6 位（0.1 打成 "0.100000"）——
/// 好处是坐标列宽度一致，也能直接和 pymatgen 的输出并排对比
fn fmt_frac(x : Double) -> String {
  let neg = x < 0.0
  let v = if neg { -x } else { x }
  let scaled = @double.round(v * 1000000.0)
  let whole = (scaled / 1000000.0).floor()
  let frac = (scaled - whole * 1000000.0).to_int()
  let sign = if neg { "-" } else { "" }
  sign + whole.to_int().to_string() + "." + pad_zeros_left(frac.to_string(), 6)
}

/// 整齐地打印一个结构的晶格参数、体积、原子列表
fn print_report(crystal : @lib.Crystal) -> Unit {
  let lat = crystal.lattice
  let atoms = crystal.atoms
  println("──────── 晶格参数（单位：Å / 度） ────────")
  println("  a      = " + fmt(lat.a))
  println("  b      = " + fmt(lat.b))
  println("  c      = " + fmt(lat.c))
  println("  alpha  = " + fmt(lat.alpha) + " 度  = " + fmt(@lib.to_radian(lat.alpha)) + " 弧度")
  println("  beta   = " + fmt(lat.beta) + " 度  = " + fmt(@lib.to_radian(lat.beta)) + " 弧度")
  println("  gamma  = " + fmt(lat.gamma) + " 度  = " + fmt(@lib.to_radian(lat.gamma)) + " 弧度")
  println("")
  println("──────── 晶胞体积 ────────")
  println("  V = " + fmt(@lib.cell_volume(lat)) + " Å³")
  println("")
  println("──────── 对称性 ────────")
  if crystal.symop_count > 0 {
    println("  显式对称操作：" + crystal.symop_count.to_string() + " 个")
    println("  不对称单元：" + crystal.asym_count.to_string() + " 个原子")
    println("  → 展开成完整晶胞：" + atoms.length().to_string() + " 个原子")
  } else {
    println("  文件里没有写对称操作，按 P1 处理（原子原样输出）")
  }
  println("")
  println("──────── 原子列表 ────────")
  println("  共 " + atoms.length().to_string() + " 个原子")
  println("  组成：" + @lib.composition_to_string(@lib.composition_of_atoms(atoms)))
  println("  label      elem   x          y          z")
  for atom in atoms {
    let row = atom.label.pad_end(11, ' ') +
      atom.element.pad_end(7, ' ') +
      fmt_frac(atom.x).pad_end(12, ' ') +
      fmt_frac(atom.y).pad_end(12, ' ') +
      fmt_frac(atom.z)
    println("  " + row)
  }
}

/// 把所有攒下来的警告一次性打出来
fn print_warnings(warnings : Array[String]) -> Unit {
  if warnings.length() == 0 {
    return
  }
  println("")
  println("──────── 警告（" + warnings.length().to_string() + " 条） ────────")
  for w in warnings {
    println("  ⚠ " + w)
  }
}
