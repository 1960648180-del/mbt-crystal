/// ================================================================
///  白盒单元测试
///
///  文件名以 _wbtest.mbt 结尾 = 白盒测试，可以直接调用同一个包里的
///  私有函数（我们的 cell_metric / parse_symop / wrap01 这些函数都没加
///  pub，只有白盒测试能碰它们）。
///
///  这些断言其实就是「手算验证」的代码化 —— 每一条都是可以拿笔算出来的：
///    比如 α=β=γ=60° 时根号里正好是 0.5，
///    比如 -y, x-y, z+1/3 作用在原点得到 (0, 0, 1/3)。
///
///  与 tests/tools/verify.py 的分工：
///    · verify.py      —— 端到端验证（跑真程序、比真文件、对 pymatgen）
///    · 本文件          —— 单元验证（直接调函数、算得快、定位准）
///  两者互补：单元测试挂了你立刻知道是哪个公式错了，
///  端到端挂了你才知道"整体上对不对"。
///
///  运行：moon test
/// ================================================================

/// ---------------------------------------------------------------
/// 测试辅助
///
/// 下面这几个函数把"可能失败"的解析函数包一层：
/// 解析失败时返回一个"绝不可能出现在真实结果里"的哨兵值，
/// 这样断言必然失败（而不是让整个测试文件编译不过）。
/// ---------------------------------------------------------------

fn approx(a : Double, b : Double, tol : Double) -> Bool {
  (a - b).abs() < tol
}

/// 容差取 1e-12：这是双精度浮点在这种量级计算下的合理极限
fn near(a : Double, b : Double) -> Bool {
  approx(a, b, 1.0e-12)
}

fn comp(text : String) -> SymComponent {
  parse_component(text) catch {
    _ => SymComponent::{ coef: [99, 99, 99], shift: 99.0 }
  }
}

fn symop(text : String) -> SymOp {
  parse_symop(text) catch {
    _ => SymOp::{ parts: [] }
  }
}

fn frac(text : String) -> Double {
  parse_fraction(text) catch {
    _ => -999.0
  }
}

fn number(text : String) -> Double {
  parse_number(text) catch {
    _ => -999.0
  }
}

/// 造一个立方晶胞（三个角都是 90°）
fn cubic(a : Double) -> Lattice {
  { a: a, b: a, c: a, alpha: 90.0, beta: 90.0, gamma: 90.0 }
}

/// ---------------------------------------------------------------
/// 一、角度与几何（数学最基础的一段）
/// ---------------------------------------------------------------

test "to_radian：60 度 = pi/3" {
  assert_true(near(to_radian(60.0), 1.0471975511965976))
  assert_true(near(to_radian(90.0), 1.5707963267948966))
  assert_true(near(to_radian(120.0), 2.0943951023931953))
  assert_true(near(to_radian(180.0), 3.141592653589793))
}

test "cell_metric：三个角都是 60 度时，根号里正好是 0.5" {
  // 手算：1 - 3*cos²60 + 2*cos³60 = 1 - 3(0.25) + 2(0.125) = 1 - 0.75 + 0.25 = 0.5
  let lat : Lattice = { a: 3.0, b: 3.0, c: 3.0, alpha: 60.0, beta: 60.0, gamma: 60.0 }
  assert_true(near(cell_metric(lat), 0.5))
}

test "cell_metric：立方晶胞（三个角都是 90 度）= 1" {
  // cos90 = 0，所以 1 - 0 - 0 - 0 + 0 = 1
  assert_true(near(cell_metric(cubic(5.0)), 1.0))
}

test "cell_metric：角度不合法时是负数（体积会变虚数，开根号没意义）" {
  // 三个角都是 170°：cos170 = -0.98481
  //   1 - 3(0.96985) + 2(-0.95511) = 1 - 2.90955 - 1.91022 = -1.8198 < 0
  let lat : Lattice = { a: 5.0, b: 5.0, c: 5.0, alpha: 170.0, beta: 170.0, gamma: 170.0 }
  assert_true(cell_metric(lat) < 0.0)
}

test "cell_volume：立方 a=5.431 时 V = a³ = 160.191478" {
  // 手算：5.431² = 29.495761；29.495761 × 5.431 = 160.19147799
  assert_true(approx(cell_volume(cubic(5.431)), 160.191478, 1.0e-6))
}

test "cell_volume：立方 a=5 时 V = 125" {
  assert_true(near(cell_volume(cubic(5.0)), 125.0))
}

test "cell_volume：角度不合法时返回 0（让调用方能发现异常）" {
  let lat : Lattice = { a: 5.0, b: 5.0, c: 5.0, alpha: 170.0, beta: 170.0, gamma: 170.0 }
  assert_true(near(cell_volume(lat), 0.0))
}

/// ---------------------------------------------------------------
/// 二、对称操作的"文本 → 数字"
/// ---------------------------------------------------------------

test "parse_fraction：分数、小数、整数都要认" {
  assert_true(near(frac("1/2"), 0.5))
  assert_true(near(frac("1/3"), 0.3333333333333333))
  assert_true(near(frac("2/3"), 0.6666666666666666))
  assert_true(near(frac("2"), 2.0))
  assert_true(near(frac("0.5"), 0.5))
}

test "parse_fraction：分母为 0 时不能悄悄算出个乱七八糟的数" {
  // 期望它失败 —— 拿哨兵值 -999 判定
  assert_true(near(frac("1/0"), -999.0))
}

test "parse_component：-x+y+1/2 拆成「系数 -1、+1、0，平移 1/2」" {
  let c = comp("-x+y+1/2")
  assert_eq(c.coef[0], -1)
  assert_eq(c.coef[1], 1)
  assert_eq(c.coef[2], 0)
  assert_true(near(c.shift, 0.5))
}

test "parse_component：平移写在前面也要认（1/2+x）" {
  let c = comp("1/2+x")
  assert_eq(c.coef[0], 1)
  assert_eq(c.coef[1], 0)
  assert_eq(c.coef[2], 0)
  assert_true(near(c.shift, 0.5))
}

test "parse_component：省略系数的变量，系数是 1 而不是 0" {
  // 这是最容易写错的地方："x" 的系数必须当成 1
  let c = comp("x")
  assert_eq(c.coef[0], 1)
  assert_eq(c.coef[1], 0)
  assert_eq(c.coef[2], 0)
  assert_true(near(c.shift, 0.0))
}

test "parse_component：纯变量（z）" {
  let c = comp("z")
  assert_eq(c.coef[0], 0)
  assert_eq(c.coef[1], 0)
  assert_eq(c.coef[2], 1)
  assert_true(near(c.shift, 0.0))
}

test "parse_component：只有平移，没有变量（1/2）" {
  let c = comp("1/2")
  assert_eq(c.coef[0], 0)
  assert_eq(c.coef[1], 0)
  assert_eq(c.coef[2], 0)
  assert_true(near(c.shift, 0.5))
}

test "parse_symop：一条完整操作应当拆成 3 段" {
  let op = symop("-y, x-y, z+1/3")
  assert_eq(op.parts.length(), 3)
  // 第 1 段：-y  -> 系数 (0, -1, 0)，平移 0
  assert_eq(op.parts[0].coef[1], -1)
  // 第 3 段：z+1/3 -> 系数 (0, 0, 1)，平移 1/3
  assert_eq(op.parts[2].coef[2], 1)
  assert_true(near(op.parts[2].shift, 0.3333333333333333))
}

/// ---------------------------------------------------------------
/// 三、对称操作的"数字 → 坐标"
/// ---------------------------------------------------------------

test "apply_symop：三重轴作用在原点，得到 (0, 0, 1/3)" {
  // 手算：把 x=y=z=0 代进 (-y, x-y, z+1/3)
  //   第1段 -0 = 0；第2段 0-0 = 0；第3段 0+1/3 = 1/3
  let op = symop("-y, x-y, z+1/3")
  let (x, y, z) = apply_symop(op, 0.0, 0.0, 0.0)
  assert_true(near(x, 0.0))
  assert_true(near(y, 0.0))
  assert_true(near(z, 0.3333333333333333))
}

test "apply_symop：倒反中心 (-x, -y, -z) 作用在 (0.25, 0.5, 0.75)" {
  let op = symop("-x, -y, -z")
  let (x, y, z) = apply_symop(op, 0.25, 0.5, 0.75)
  assert_true(near(x, -0.25))
  assert_true(near(y, -0.5))
  assert_true(near(z, -0.75))
}

test "apply_symop：恒等操作 (x, y, z) 不改变坐标" {
  let op = symop("x, y, z")
  let (x, y, z) = apply_symop(op, 0.125, 0.375, 0.625)
  assert_true(near(x, 0.125))
  assert_true(near(y, 0.375))
  assert_true(near(z, 0.625))
}

test "wrap01：把任何数折回 [0, 1)" {
  assert_true(near(wrap01(-0.25), 0.75))
  assert_true(near(wrap01(-0.10), 0.90))
  assert_true(near(wrap01(1.25), 0.25))
  assert_true(near(wrap01(1.0), 0.0))
  assert_true(near(wrap01(0.3), 0.3))
}

/// ---------------------------------------------------------------
/// 四、周期性去重（这一段是最容易出错、也最值得测的）
/// ---------------------------------------------------------------

test "frac_same：周期性地看，0 和 0.99995 是同一个位置" {
  assert_true(frac_same(0.0, 0.99995, 1.0e-4))
  assert_true(frac_same(0.0, 0.00005, 1.0e-4))
  assert_true(frac_same(0.75, 0.75005, 1.0e-4))
}

test "frac_same：隔得远的不能算同一个位置" {
  assert_true(!frac_same(0.0, 0.5, 1.0e-4))
  assert_true(!frac_same(0.0, 0.999, 1.0e-4))
  assert_true(!frac_same(0.1, 0.2, 1.0e-4))
}

test "expand_atoms：1 个原子 × 3 条操作 = 3 个位置（手算可验）" {
  let ops : Array[SymOp] = [
    symop("x, y, z"),
    symop("-y, x-y, z+1/3"),
    symop("-x+y, -x, z+2/3"),
  ]
  let asym : Array[Atom] = [{ element: "M", label: "M1", x: 0.0, y: 0.0, z: 0.0 }]
  let out = expand_atoms(asym, ops)
  assert_eq(out.length(), 3)
}

test "expand_atoms：三条一样的操作，只应当留下 1 个原子" {
  // 这是去重逻辑最直接的检验：不做去重就会输出 3 个重复原子
  let ops : Array[SymOp] = [symop("x, y, z"), symop("x, y, z"), symop("x, y, z")]
  let asym : Array[Atom] = [{ element: "M", label: "M1", x: 0.1, y: 0.2, z: 0.3 }]
  assert_eq(expand_atoms(asym, ops).length(), 1)
}

test "expand_atoms：2 条操作互为镜像，应当留下 2 个原子" {
  let ops : Array[SymOp] = [symop("x, y, z"), symop("-x, y, -z")]
  let asym : Array[Atom] = [{ element: "Na", label: "Na1", x: 0.25, y: 0.0, z: 0.10 }]
  let out = expand_atoms(asym, ops)
  assert_eq(out.length(), 2)
  // 第 2 个原子应当是 (-0.25, 0, -0.10) 折回后的 (0.75, 0, 0.90)
  assert_true(near(out[1].x, 0.75))
  assert_true(near(out[1].y, 0.0))
  assert_true(near(out[1].z, 0.90))
}

test "expand_atoms：空的不对称单元 → 空结果（不能崩）" {
  let ops : Array[SymOp] = [symop("x, y, z")]
  let asym : Array[Atom] = []
  assert_eq(expand_atoms(asym, ops).length(), 0)
}

/// ---------------------------------------------------------------
/// 五、文本与数值解析
/// ---------------------------------------------------------------

test "parse_number：CIF 的误差括号 5.4310(2) 表示 5.4310" {
  assert_true(near(number("5.4310(2)"), 5.4310))
  assert_true(near(number("5.43(2"), 5.43))
  assert_true(near(number("5.43()"), 5.43))
}

test "parse_number：? 和 . 表示这一项没有，不能当成 0" {
  // 期望失败 —— 哨兵值 -999
  assert_true(near(number("?"), -999.0))
  assert_true(near(number("."), -999.0))
  assert_true(near(number("abc"), -999.0))
}

test "element_from_label：从标签里取出元素符号" {
  assert_eq(element_from_label("Si0"), "Si")
  assert_eq(element_from_label("O12"), "O")
  assert_eq(element_from_label("Ga4+"), "Ga")
  assert_eq(element_from_label("Cl1"), "Cl")
}

test "parse_formula：化学式 → 元素计数" {
  let c = parse_formula("Ga4 O6")
  assert_eq(comp_count(c, "Ga"), 4)
  assert_eq(comp_count(c, "O"), 6)
  // 省略个数时按 1 算
  let c2 = parse_formula("NaCl")
  assert_eq(comp_count(c2, "Na"), 1)
  assert_eq(comp_count(c2, "Cl"), 1)
  // 没出现过的元素是 0
  assert_eq(comp_count(c2, "H"), 0)
}

test "to_radian 与 cell_metric 配合：六方格子的根号项" {
  // 六方 a=b, γ=120°：1 - cos²90 - cos²90 - cos²120 + 2·cos90·cos90·cos120
  //                = 1 - 0 - 0 - 0.25 + 0 = 0.75
  let lat : Lattice = { a: 3.18893, b: 3.18893, c: 5.19236, alpha: 90.0, beta: 90.0, gamma: 120.0 }
  assert_true(near(cell_metric(lat), 0.75))
  // 手算：3.18893² × 5.19236 × √0.75 ≈ 45.728
  assert_true(approx(cell_volume(lat), 45.7283, 1.0e-3))
}

/// ---------------------------------------------------------------
/// 六、空间群编号查表
///
/// 表在 spacegroup_table.mbt，由 tests/tools/gen_spacegroups.py 从 spglib
/// 的空间群数据库自动生成。下面这几条测试不看具体数值，而是检查**表的自洽性** ——
/// 这类检查能拓住脚本生成时对不上的格式。
/// ---------------------------------------------------------------

test "spacegroup_ops：230 个国际编号全部有数据" {
  let mut missing = 0
  let mut i = 1
  while i <= 230 {
    if spacegroup_ops(i).length() == 0 {
      missing = missing + 1
    }
    i = i + 1
  }
  assert_eq(missing, 0)
}

test "spacegroup_ops：几组已知的操作条数" {
  assert_eq(spacegroup_ops(1).length(), 1) // P1，只有恒等操作
  assert_eq(spacegroup_ops(2).length(), 2) // P-1，加倒反中心
  assert_eq(spacegroup_ops(186).length(), 12) // P6_3mc（GaN）
  assert_eq(spacegroup_ops(225).length(), 192) // Fm-3m
  assert_eq(spacegroup_ops(227).length(), 192) // Fd-3m（金刚石）
}

test "spacegroup_ops：未知编号返回空数组" {
  assert_eq(spacegroup_ops(0).length(), 0)
  assert_eq(spacegroup_ops(231).length(), 0)
}

test "spacegroup_ops：每条操作都必须含恒等操作 (x,y,z)" {
  // 群论上的硬要求：对称操作集合必然包含恒等操作。
  // 哪张表缺了它，说明表本身生成错了。
  let mut bad = 0
  let mut n = 1
  while n <= 230 {
    let mut has_identity = false
    for text in spacegroup_ops(n) {
      if text == "x,y,z" {
        has_identity = true
      }
    }
    if !has_identity {
      bad = bad + 1
    }
    n = n + 1
  }
  assert_eq(bad, 0)
}

test "spacegroup_ops：全部 230 个群的每一条操作都能被 parse_symop 解析" {
  // 对生成表最强的一条检验：表里只要有一个字符串格式不对，这里就会挂。
  // 同时也验证了两代代码能接上（生成的表 → 已有的解析器）。
  let mut bad = 0
  let mut wrong_parts = 0
  let mut total = 0
  let mut n = 1
  while n <= 230 {
    for text in spacegroup_ops(n) {
      total = total + 1
      let parsed : SymOp? = Some(parse_symop(text)) catch {
        _ => None
      }
      match parsed {
        Some(op) => if op.parts.length() != 3 { wrong_parts = wrong_parts + 1 }
        None => bad = bad + 1
      }
    }
    n = n + 1
  }
  assert_eq(bad, 0)
  assert_eq(wrong_parts, 0)
  assert_true(total > 4000) // 全表应当有四千多条操作
}
