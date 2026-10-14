/// ================================================================
///  CIF -> 对称展开 工具（单文件）
///
///  CIF = Crystallographic Information File，晶体学信息文件
///  它是纯文本，一行一个"字段"，_ 开头的叫关键字，loop_ 下面是表格
///
///  【分工】分词这层"管道活"不重复造轮子，直接复用 vendor/crystal/
///  （从 IvanAXu/BioSeqs 的 crystal.mbt + utils.mbt 原样复制，Apache-2.0）：
///      · 切出 data_ 数据块、认 loop_ 表格、按列名给出干净的表格
///      · 引号感知：'-x, y, -z' 会被当成一个完整的值，引号自动剥掉
///   我们只做它没有的那部分：
///      1. 显式对称操作解析 + 展开成完整晶胞（含折回 [0,1) 与去重）
///      2. 警告收集 + 出错策略（ignore / warn / raise）
///      3. 化学式自检：展开后的组成 vs CIF 自带的 _chemical_formula_sum
///
///  运行方法（在本文件所在目录）：
///    moon run . -- <CIF 文件路径> [ignore|warn|raise]
/// ================================================================

/// ---------------------------------------------------------------
/// 一、数据模型
/// ---------------------------------------------------------------

/// 晶格参数：3 条边长 a/b/c + 3 个夹角 alpha/beta/gamma（单位：度）
struct Lattice {
  a : Double
  b : Double
  c : Double
  alpha : Double
  beta : Double
  gamma : Double
}

/// 一个原子
///   element = 元素符号，如 "Si"。优先取 _atom_site_type_symbol 那一列，
///             没有这一列就从 label 里推（"Si0" -> "Si"）
///   label   = CIF 里给这个原子起的名字，如 "Si0"
///   分数坐标 = 以晶胞的三个边为单位量出来的位置，所以都在 0~1 之间
struct Atom {
  element : String
  label : String
  x : Double
  y : Double
  z : Double
}

/// 一个数据块解析出来的结果
struct Crystal {
  name : String
  lattice : Lattice
  atoms : Array[Atom] // 展开对称性之后的完整晶胞
  asym_count : Int // 不对称单元里的原子数
  symop_count : Int // 用到的显式对称操作个数（0 = 文件里没写，按 P1 处理）
}

/// 化学组成：元素名 + 对应个数
/// 用两个"平行数组"表示，入门版不引入 Map，够用
struct Composition {
  names : Array[String]
  counts : Array[Int]
}

/// 对称操作里的"一个分量"，例如 "-x+y+1/2"
/// 含义是 coef[0]*x + coef[1]*y + coef[2]*z + shift
struct SymComponent {
  coef : Array[Int] // 三个整数系数，分别对应 x / y / z
  shift : Double // 平移常数（一个分数，如 1/2）
}

/// 一条完整的对称操作 = 三个分量（分别给出新的 x / y / z）
struct SymOp {
  parts : Array[SymComponent] // 长度固定为 3
}

/// 出错策略（对齐 pymatgen 的 on_error 参数）
///   Ignore = 出错就跳过这一块，什么都不说
///   Warn   = 出错就记一条警告，程序继续（默认）
///   Raise  = 一遇到错就停下来报错
enum OnError {
  Ignore
  Warn
  Raise
}

/// 圆周率（入门版直接写死，够用）
let pi : Double = 3.141592653589793

/// 化学式配比的容差（对齐 pymatgen 的 comp_tol 默认值 0.01）
let comp_tol : Double = 0.01

/// ---------------------------------------------------------------
/// 二、几何计算
/// ---------------------------------------------------------------

/// 角度 -> 弧度
/// 三角函数（cos 等）只认"弧度"，而 CIF 里的角度写的是"度"，必须先换算
fn to_radian(deg : Double) -> Double {
  deg * pi / 180.0
}

/// 计算晶胞体积（三斜晶胞的通用公式）
///   V = a*b*c*sqrt(1 - cos²α - cos²β - cos²γ + 2·cosα·cosβ·cosγ)
/// 立方、四方、六方、单斜都是它的特例，所以这一个公式就够了
/// 注意：角度不合法（cell_metric ≤ 0）时返回 0，调用方应先检查并给出警告
fn cell_volume(lat : Lattice) -> Double {
  let metric = cell_metric(lat)
  if metric <= 0.0 {
    0.0
  } else {
    lat.a * lat.b * lat.c * metric.sqrt()
  }
}

/// 三斜公式里"根号里面那一坨"：
///   1 - cos²α - cos²β - cos²γ + 2·cosα·cosβ·cosγ
/// 它必须 > 0 才凑得出真实晶胞；≤ 0 说明这组角度物理上不可能
/// （体积会变成虚数，开根号没意义）
/// 单独抽出来是为了能"先检查一下、再决定要不要警告"
fn cell_metric(lat : Lattice) -> Double {
  let ca = @math.cos(to_radian(lat.alpha))
  let cb = @math.cos(to_radian(lat.beta))
  let cg = @math.cos(to_radian(lat.gamma))
  1.0 - ca * ca - cb * cb - cg * cg + 2.0 * ca * cb * cg
}

/// ---------------------------------------------------------------
/// 三、文本小工具（数值 / 化学式 / 元素符号）
///     —— "切行、找 loop_ 表" 这类管道活已交给第四节里 vendor 的
///        分词器，这里只留我们真正用得上的几个
/// ---------------------------------------------------------------

/// 从 CIF 标签里取出元素符号：取开头连续的字母
/// 例："Si0" -> "Si"，"Ga4+" -> "Ga"，"O12" -> "O"
fn element_from_label(label : String) -> String {
  let mut out = ""
  let mut stop = false
  for c in label.iter() {
    if !stop && c.is_ascii_alphabetic() {
      out = out + c.to_string()
    } else {
      stop = true
    }
  }
  out
}

/// 把一串数字字符转成整数（"12" -> 12）
fn digits_to_int(s : String) -> Int {
  let mut n = 0
  for c in s.iter() {
    n = n * 10 + (c.to_int() - 48) // '0' 的字符编码是 48
  }
  n
}

/// 把字符串转成小数，并处理 CIF 的特色写法
/// CIF 会在数字后面用括号标误差，例如 "5.4310(2)" 其实是 5.4310
/// 注意：pymatgen 的 str2float 也是直接把这个括号删掉的，这里保持一致
/// 出错时抛出 Failure 错误（带一句人话说明），由 main 统一捕获
fn parse_number(raw : String) -> Double raise Failure {
  if raw == "?" || raw == "." {
    raise Failure("数值缺失（文件里写的是 \"" + raw + "\"）")
  }
  let text = match raw.split_once("(") {
    Some(pair) => pair.0.to_owned() // 括号后面的误差直接丢掉
    None => raw
  }
  @string.parse_double(text) catch {
    _ => raise Failure("\"" + raw + "\" 不是合法数字")
  }
}

/// 解析原子表里的一个坐标值
/// 单独写一个是为了在失败时说一句更有用的话：
/// 坐标位置读到非数字，十有八九是这一行的字段数和表头对不上
/// （CIF 的表是纯空白分隔、不带列名，多写/少写一个 "." 占位符就会整体错位）
fn parse_coord(raw : String) -> Double raise Failure {
  parse_number(raw) catch {
    _ =>
      raise Failure(
        "坐标位置读到的值是 \"" +
        raw +
        "\"，不是合法数字（最常见的原因：这一行字段数和表头对不上，" +
        "比如多写或少写了一个 \".\" 占位符）",
      )
  }
}

/// 解析 CIF 的化学式写法，得到元素组成
///   "Si2"          -> Si×2
///   "Ga4 N4"       -> Ga×4, N×4
///   "C8 H10 N4 O2" -> C×8, H×10, N×4, O×2
///   "NaCl"         -> Na×1, Cl×1
/// 规则：大写字母开一个新元素，小写字母接到当前元素后面，
///       数字是个数（没写就是 1），其它字符（空格、引号）一律忽略
fn parse_formula(text : String) -> Composition {
  let names : Array[String] = []
  let counts : Array[Int] = []
  let mut symbol = ""
  let mut digits = ""
  for c in text.iter() {
    if c.is_ascii_digit() {
      digits = digits + c.to_string()
    } else if c.is_ascii_uppercase() {
      // 遇到新元素，先把上一个元素结算掉
      if symbol != "" {
        names.push(symbol)
        counts.push(if digits == "" { 1 } else { digits_to_int(digits) })
      }
      symbol = c.to_string()
      digits = ""
    } else if c.is_ascii_lowercase() {
      symbol = symbol + c.to_string() // 接到当前元素后面，如 Cl
    }
    // 其它字符（空格、引号等）直接忽略
  }
  if symbol != "" {
    names.push(symbol)
    counts.push(if digits == "" { 1 } else { digits_to_int(digits) })
  }
  let comp : Composition = { names: names, counts: counts }
  comp
}

/// 查某个元素在组成里的个数，没有就返回 0
fn comp_count(comp : Composition, name : String) -> Int {
  let mut i = 0
  while i < comp.names.length() {
    if comp.names[i] == name {
      return comp.counts[i]
    }
    i = i + 1
  }
  0
}

/// 数组里有没有这个字符串
fn array_has(items : Array[String], target : String) -> Bool {
  for item in items {
    if item == target {
      return true
    }
  }
  false
}

/// 数一数原子列表里有多少个指定元素
fn count_of(atoms : Array[Atom], name : String) -> Int {
  let mut n = 0
  for atom in atoms {
    if atom.element == name {
      n = n + 1
    }
  }
  n
}

/// 把原子列表统计成化学组成
/// 只列出出现过的元素，并保持它们首次出现的顺序
fn composition_of_atoms(atoms : Array[Atom]) -> Composition {
  let names : Array[String] = []
  let counts : Array[Int] = []
  for atom in atoms {
    if !array_has(names, atom.element) {
      names.push(atom.element)
      counts.push(count_of(atoms, atom.element))
    }
  }
  let comp : Composition = { names: names, counts: counts }
  comp
}

/// 把化学组成打成可读的字符串，如 "Ga4 N4"
fn composition_to_string(comp : Composition) -> String {
  let mut out = ""
  let mut i = 0
  while i < comp.names.length() {
    if out != "" {
      out = out + " "
    }
    out = out + comp.names[i] + comp.counts[i].to_string()
    i = i + 1
  }
  out
}

/// ---------------------------------------------------------------
/// 四、CIF 文本处理（分词交给 vendor/crystal 里的 BioSeqs 分词器）
///
/// 它已经替我们做完最难的那部分：
///   · 切出 data_ 数据块、认 loop_ 表格、按列名给出干净的表格
///   · 「引号感知」：'-x, y, -z' 这种整体会被当成一个值，引号自动剥掉
///   · 数值后面的误差括号 (2) 也会处理
/// 我们只做两件事：把它的结果翻译成我们的结构，以及保留自己的报错能力
/// ---------------------------------------------------------------

/// 取一个标量关键字的值；文件里没写就返回 None
/// （CifBlock::get_scalar 找不到时返回空串，这里把空串也当作"没找到"）
fn block_scalar(block : @bio.CifBlock, key : String) -> String? {
  let value = block.get_scalar(key)
  if value == "" {
    None
  } else {
    Some(value)
  }
}

/// 取一个标量关键字并转成数字；缺了就报错（带清楚的原因）
fn block_number(block : @bio.CifBlock, key : String) -> Double raise Failure {
  match block_scalar(block, key) {
    Some(raw) => parse_number(raw)
    None => raise Failure("文件里找不到晶格参数 " + key)
  }
}

/// 从数据块里取出六个晶格参数
fn parse_lattice(block : @bio.CifBlock) -> Lattice raise Failure {
  let lat : Lattice = {
    a: block_number(block, "_cell_length_a"),
    b: block_number(block, "_cell_length_b"),
    c: block_number(block, "_cell_length_c"),
    alpha: block_number(block, "_cell_angle_alpha"),
    beta: block_number(block, "_cell_angle_beta"),
    gamma: block_number(block, "_cell_angle_gamma"),
  }
  lat
}

/// 在表头数组里找某一列的下标，找不到返回 -1
fn find_column(headers : Array[String], name : String) -> Int {
  let mut i = 0
  while i < headers.length() {
    if headers[i] == name {
      return i
    }
    i = i + 1
  }
  -1
}

/// 找出原子位点表，返回（表头, 数据行）的二元组
/// 正常 CIF 用 _atom_site_label 就能拿到整张表；万一文件里没有 label 列，
/// 就退一步用 _atom_site_fract_x / _atom_site_type_symbol 去找同一张表
/// 注意：这里只要有表头就算找到了。因为"行不完整"会被分词器丢弃，
/// 如果一并要求 rows > 0，就会把"表存在但没一行是完整的"误报成"根本没这张表"
fn find_atom_loop(
  block : @bio.CifBlock,
) -> (Array[String], Array[Array[String]]) {
  let keys : Array[String] = [
    "_atom_site_label",
    "_atom_site_fract_x",
    "_atom_site_type_symbol",
  ]
  for key in keys {
    let (headers, rows) = block.get_loop(key)
    if headers.length() > 0 {
      return (headers, rows)
    }
  }
  ([], [])
}

/// 从数据块里取出原子位点（还只是"不对称单元"）
fn parse_atoms(
  block : @bio.CifBlock,
  warnings : Array[String],
) -> Array[Atom] raise Failure {
  let atoms : Array[Atom] = []
  let (headers, rows) = find_atom_loop(block)
  if headers.length() == 0 {
    return atoms // 文件里根本没找到原子位点表，交给调用方去警告
  }
  // _atom_site_type_symbol 是可选的：有就用它，没有就从 label 推
  let col_symbol = find_column(headers, "_atom_site_type_symbol")
  let col_label = find_column(headers, "_atom_site_label")
  let col_x = find_column(headers, "_atom_site_fract_x")
  let col_y = find_column(headers, "_atom_site_fract_y")
  let col_z = find_column(headers, "_atom_site_fract_z")
  if col_x < 0 || col_y < 0 || col_z < 0 {
    raise Failure("原子位点表缺列：必须有 _atom_site_fract_x / _y / _z")
  }
  if rows.length() == 0 {
    warnings.push("原子位点表只有表头，没有一行完整的数据（每行列数要和表头对得上）")
    return atoms
  }
  for fields in rows {
    let label = if col_label >= 0 && fields.length() > col_label {
      fields[col_label]
    } else {
      ""
    }
    let element = if col_symbol >= 0 && fields.length() > col_symbol {
      element_from_label(fields[col_symbol])
    } else {
      element_from_label(label)
    }
    if element == "" {
      raise Failure("原子位点表里既没有 _atom_site_type_symbol，label 也推不出元素符号")
    }
    let atom : Atom = {
      element: element,
      label: if label == "" { element } else { label },
      x: parse_coord(fields[col_x]),
      y: parse_coord(fields[col_y]),
      z: parse_coord(fields[col_z]),
    }
    atoms.push(atom)
  }
  atoms
}

/// 化学式自检（对齐 pymatgen 的 CifParser.check）
/// 把解析出来的原子组成，和 CIF 自己写的 _chemical_formula_sum 对账
/// 返回 None = 通过；Some(原因) = 不通过
///
/// 检查两条（和 pymatgen 一样）：
///   1. 元素种类必须完全一致（谁都不能少、不能多）
///   2. 相对配比必须一致，例如 CIF 写 "LiFeO" 而结构是 (LiFeO)4，算通过
fn check_composition(block : @bio.CifBlock, atoms : Array[Atom]) -> String? {
  let text = match block_scalar(block, "_chemical_formula_sum") {
    Some(t) => t
    None => return None // 文件里没写这一项，跳过检查
  }
  let expected = parse_formula(text)
  if expected.names.length() == 0 {
    return None // 看不懂这个化学式，跳过检查
  }

  // (1) 元素种类对账
  for name in expected.names {
    if count_of(atoms, name) == 0 {
      return Some("CIF 声称含有元素 " + name + "，但解析出的原子里一个都没有")
    }
  }
  let actual = composition_of_atoms(atoms)
  for name in actual.names {
    if comp_count(expected, name) == 0 {
      return Some("解析出元素 " + name + "，但 CIF 的 _chemical_formula_sum 里没有它")
    }
  }

  // (2) 相对配比对账：ratio = 实际个数 / CIF 声称个数，所有元素应当基本相等
  let mut ratio0 = 0.0
  let mut first = true
  for name in expected.names {
    let want = comp_count(expected, name).to_double()
    let got = count_of(atoms, name).to_double()
    let ratio = got / want
    if first {
      ratio0 = ratio
      first = false
    } else if (ratio - ratio0).abs() > comp_tol {
      return Some(
        "配比不一致：CIF 写的是 " +
        text +
        "，解析出来的组成是 " +
        composition_to_string(actual),
      )
    }
  }
  None
}

/// 解析一个数据块：晶格 + 原子 + 对称展开 + 自检
fn parse_block(
  block : @bio.CifBlock,
  warnings : Array[String],
) -> Crystal raise Failure {
  let lat = parse_lattice(block)
  // 角度不合法时体积会被算成 0，但 0 本身看不出是"算不了"还是"真的是 0"，
  // 所以必须主动说一声，不能让 V=0 静默溜过去（pymatgen 在这里会直接报 Singular matrix）
  if cell_metric(lat) <= 0.0 {
    warnings.push(
      "数据块 [" +
      block.name +
      "] 的晶格角度凑不出真实晶胞（α=" +
      fmt(lat.alpha) +
      "° β=" +
      fmt(lat.beta) +
      "° γ=" +
      fmt(lat.gamma) +
      "°），体积只能算作 0；请检查这三个角度是不是写错了",
    )
  }
  let asym = parse_atoms(block, warnings)
  if asym.length() == 0 {
    warnings.push("数据块 [" + block.name + "] 里没有找到原子位点表（_atom_site_*）")
  }
  // 读文件里显式的对称操作；没有就按 P1 处理（原子原样输出）
  let ops = parse_symops(block, warnings)
  let atoms = if ops.length() > 0 {
    expand_atoms(asym, ops)
  } else {
    asym
  }
  // 化学式自检比的是【展开之后】的完整晶胞
  // （对齐 pymatgen：先按对称性把结构展开，再和 _chemical_formula_sum 对账）
  match check_composition(block, atoms) {
    Some(reason) => {
      warnings.push("数据块 [" + block.name + "] 化学式自检未通过：" + reason)
    }
    None => ()
  }
  let crystal : Crystal = {
    name: block.name,
    lattice: lat,
    atoms: atoms,
    asym_count: asym.length(),
    symop_count: ops.length(),
  }
  crystal
}

/// ---------------------------------------------------------------
/// 五、对称操作（把 CIF 里的不对称单元展开成完整晶胞）
/// ---------------------------------------------------------------

/// 解析 "1/2" / "0.5" / "2" 这样的数字（对称操作里会出现分数）
fn parse_fraction(text : String) -> Double raise Failure {
  match text.split_once("/") {
    Some(pair) => {
      let numerator = @string.parse_double(pair.0) catch {
        _ => raise Failure("\"" + text + "\" 不是合法的分数")
      }
      let denominator = @string.parse_double(pair.1) catch {
        _ => raise Failure("\"" + text + "\" 不是合法的分数")
      }
      if denominator == 0.0 {
        raise Failure("\"" + text + "\" 的分母是 0")
      }
      numerator / denominator
    }
    None =>
      @string.parse_double(text) catch {
        _ => raise Failure("\"" + text + "\" 不是合法数字")
      }
  }
}

/// 解析对称操作里的一个"项"，例如 "x" / "2y" / "z" / "1/2" / "0.5"
/// 返回 (变量下标, 数值)：下标 0/1/2 对应 x/y/z，-1 表示这是常数项
fn parse_term(term : String) -> (Int, Double) raise Failure {
  let mut var_index = -1
  let mut number = ""
  for c in term.iter() {
    if c == 'x' {
      var_index = 0
    } else if c == 'y' {
      var_index = 1
    } else if c == 'z' {
      var_index = 2
    } else {
      number = number + c.to_string()
    }
  }
  let value = if number == "" {
    1.0 // 像 "x" 这种没写系数的，系数就是 1
  } else {
    parse_fraction(number)
  }
  (var_index, value)
}

/// 解析对称操作的一个分量，例如 "-x+y+1/2" 或 "1/2+x" 或 "-z"
fn parse_component(text : String) -> SymComponent raise Failure {
  let mut cx = 0
  let mut cy = 0
  let mut cz = 0
  let mut shift = 0.0
  let mut sign = 1.0
  let mut term = ""
  // 末尾补一个 "+"，这样最后一项也能在循环里被统一结算
  for c in (text + "+").iter() {
    if c == '+' || c == '-' {
      if term != "" {
        let (var_index, value) = parse_term(term)
        if var_index < 0 {
          shift = shift + sign * value
        } else {
          let coef = (sign * value).to_int()
          if var_index == 0 {
            cx = cx + coef
          } else if var_index == 1 {
            cy = cy + coef
          } else {
            cz = cz + coef
          }
        }
        term = ""
      }
      sign = if c == '-' { -1.0 } else { 1.0 }
    } else {
      term = term + c.to_string()
    }
  }
  let comp : SymComponent = { coef: [cx, cy, cz], shift: shift }
  comp
}

/// 解析一整条对称操作，例如 "x, 1/2-y, 1/2+z"
fn parse_symop(text : String) -> SymOp raise Failure {
  let parts : Array[SymComponent] = []
  for piece in text.to_lower().split(",") {
    parts.push(parse_component(piece.trim().to_owned()))
  }
  if parts.length() != 3 {
    raise Failure(
      "对称操作应该有 3 段（x, y, z），但 \"" +
      text +
      "\" 被拆成了 " +
      parts.length().to_string() +
      " 段",
    )
  }
  let op : SymOp = { parts: parts }
  op
}

/// 找出显式对称操作所在的 loop_ 关键字
/// 兼容 _symmetry_equiv_pos_as_xyz 和 _space_group_symop_operation_xyz
/// （以及个别文件在结尾多带一个下划线的写法）
fn find_symop_key(block : @bio.CifBlock) -> String? {
  let bases : Array[String] = [
    "_symmetry_equiv_pos_as_xyz",
    "_space_group_symop_operation_xyz",
  ]
  for key in block.keys() {
    for base in bases {
      if key.has_prefix(base) {
        let (headers, _) = block.get_loop(key)
        if headers.length() > 0 {
          return Some(key)
        }
      }
    }
  }
  None
}

/// 把一批「对称操作字符串」解析成结构体，同时数一下有几条解析失败
fn parse_symop_texts(texts : Array[String]) -> (Array[SymOp], Int) {
  let ops : Array[SymOp] = []
  let mut failed = 0
  for text in texts {
    let parsed : SymOp? = Some(parse_symop(text)) catch {
      _ => None
    }
    match parsed {
      Some(op) => ops.push(op)
      None => failed = failed + 1
    }
  }
  (ops, failed)
}

/// 读数据块里**显式写出**的对称操作（从 loop_ 表里读）
/// 文件里没写就返回空数组，交给上层去查空间群表
fn parse_explicit_symops(
  block : @bio.CifBlock,
  warnings : Array[String],
) -> Array[SymOp] {
  let key = match find_symop_key(block) {
    Some(k) => k
    None => return []
  }
  let (headers, rows) = block.get_loop(key)
  let col = find_column(headers, key)
  if col < 0 {
    return []
  }
  if rows.length() == 0 {
    warnings.push("对称操作表（" + key + "）只有表头，没有一行完整的数据")
    return []
  }
  // 分词器已经帮我们把引号剥掉了，所以 row[col] 直接就是 "-x, y, -z" 这样的干净文本
  let texts : Array[String] = []
  let mut missed = 0
  for row in rows {
    if row.length() > col {
      texts.push(row[col])
    } else {
      missed = missed + 1
    }
  }
  let (ops, failed) = parse_symop_texts(texts)
  let bad = failed + missed
  if bad > 0 {
    warnings.push(
      "有 " +
      bad.to_string() +
      " 条对称操作解析失败，已跳过（其余 " +
      ops.length().to_string() +
      " 条仍生效）",
    )
  }
  ops
}

/// 文件里**没有**显式列出对称操作时，按空间群编号查表
/// 表在 spacegroup_table.mbt，由 tests/tools/gen_spacegroups.py 从 spglib 的数据库生成
fn symops_from_spacegroup_number(
  block : @bio.CifBlock,
  warnings : Array[String],
) -> Array[SymOp] {
  let names : Array[String] = [
    "_symmetry_Int_Tables_number",
    "_space_group_IT_number",
    "_symmetry_space_group_IT_number",
  ]
  for name in names {
    match block_scalar(block, name) {
      Some(_) => {
        let number = ((block_number(block, name)) catch { _ => 0.0 }).to_int()
        if number >= 1 && number <= 230 {
          let (ops, failed) = parse_symop_texts(spacegroup_ops(number))
          if ops.length() > 0 {
            let mut msg = "文件里没有列出对称操作，改按空间群编号 " +
              number.to_string() +
              " 查表得到 " +
              ops.length().to_string() +
              " 条操作"
            if failed > 0 {
              msg = msg + "（另有 " + failed.to_string() + " 条查表结果解析失败）"
            }
            warnings.push(msg)
            return ops
          }
        }
      }
      None => ()
    }
  }
  []
}

/// 读数据块里的对称操作
/// 优先用文件里显式列出的；没有就按空间群编号查表
/// 两条路都没拿到就返回空数组（调用方按 P1 处理）
fn parse_symops(
  block : @bio.CifBlock,
  warnings : Array[String],
) -> Array[SymOp] {
  let explicit = parse_explicit_symops(block, warnings)
  if explicit.length() > 0 {
    return explicit
  }
  symops_from_spacegroup_number(block, warnings)
}

/// 把一个对称操作用在分数坐标上，得到新的分数坐标
fn apply_symop(
  op : SymOp,
  x : Double,
  y : Double,
  z : Double,
) -> (Double, Double, Double) {
  let src = [x, y, z]
  let out : Array[Double] = []
  for part in op.parts {
    let mut v = part.shift
    let mut i = 0
    while i < 3 {
      v = v + part.coef[i].to_double() * src[i]
      i = i + 1
    }
    out.push(v)
  }
  (out[0], out[1], out[2])
}

/// 把分数坐标折回 [0, 1)
/// 例：-0.25 -> 0.75，1.25 -> 0.25
fn wrap01(v : Double) -> Double {
  let mut x = v
  while x < 0.0 {
    x = x + 1.0
  }
  while x >= 1.0 {
    x = x - 1.0
  }
  // -1e-16 这类浮点噪声折一圈会变成 0.9999999999999999，这里擦干净
  if x > 1.0 - 1.0e-9 {
    x = 0.0
  }
  x
}

/// 两个分数坐标在容差内是不是"同一个位置"（按周期性比，0 和 0.9999 算近）
fn frac_same(a : Double, b : Double, tol : Double) -> Bool {
  let mut d = (a - b).abs()
  if d > 1.0 - tol {
    d = 1.0 - d
  }
  d < tol
}

/// 展开出来的原子里，是否已经有同种元素在同一个位置
fn has_same_site(
  atoms : Array[Atom],
  x : Double,
  y : Double,
  z : Double,
  element : String,
  tol : Double,
) -> Bool {
  for atom in atoms {
    if atom.element == element &&
      frac_same(atom.x, x, tol) &&
      frac_same(atom.y, y, tol) &&
      frac_same(atom.z, z, tol) {
      return true
    }
  }
  false
}

/// 用对称操作把"不对称单元"里的原子展开成完整晶胞，并去掉重复位置
/// 容差取 1e-4（对齐 pymatgen 的 site_tolerance 默认值，单位是分数坐标）
fn expand_atoms(asym : Array[Atom], ops : Array[SymOp]) -> Array[Atom] {
  let tol = 1.0e-4
  let out : Array[Atom] = []
  for atom in asym {
    for op in ops {
      let (x, y, z) = apply_symop(op, atom.x, atom.y, atom.z)
      let wx = wrap01(x)
      let wy = wrap01(y)
      let wz = wrap01(z)
      if !(has_same_site(out, wx, wy, wz, atom.element, tol)) {
        let a : Atom = {
          element: atom.element,
          label: atom.label,
          x: wx,
          y: wy,
          z: wz,
        }
        out.push(a)
      }
    }
  }
  out
}

/// ---------------------------------------------------------------
/// 六、打印结果
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
fn print_report(crystal : Crystal) -> Unit {
  let lat = crystal.lattice
  let atoms = crystal.atoms
  println("──────── 晶格参数（单位：Å / 度） ────────")
  println("  a      = " + fmt(lat.a))
  println("  b      = " + fmt(lat.b))
  println("  c      = " + fmt(lat.c))
  println("  alpha  = " + fmt(lat.alpha) + " 度  = " + fmt(to_radian(lat.alpha)) + " 弧度")
  println("  beta   = " + fmt(lat.beta) + " 度  = " + fmt(to_radian(lat.beta)) + " 弧度")
  println("  gamma  = " + fmt(lat.gamma) + " 度  = " + fmt(to_radian(lat.gamma)) + " 弧度")
  println("")
  println("──────── 晶胞体积 ────────")
  println("  V = " + fmt(cell_volume(lat)) + " Å³")
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
  println("  组成：" + composition_to_string(composition_of_atoms(atoms)))
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

/// ---------------------------------------------------------------
/// 七、主程序
/// ---------------------------------------------------------------

/// 安全读文件：读不了就返回空字符串（不让程序直接崩掉）
fn read_file_safe(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => ""
  }
}

/// 把命令行里的策略字符串转成枚举，认不出来就用默认的 Warn
fn parse_on_error(text : String) -> OnError {
  if text == "ignore" {
    Ignore
  } else if text == "raise" {
    Raise
  } else {
    Warn
  }
}

/// 程序入口
fn main {
  // 1) 检查命令行参数
  let args = @env.args()
  if args.length() < 2 {
    println("用法：moon run . -- <CIF 文件路径> [ignore|warn|raise]")
    println("示例：moon run . -- mp-149.cif")
    println("      moon run . -- mp-149.cif warn   （出错策略，默认 warn）")
    return
  }
  let path = args[1]
  let on_error = if args.length() >= 3 {
    parse_on_error(args[2])
  } else {
    Warn
  }

  // 2) 文件不存在 -> 明确提示
  if !(@fs.path_exists(path)) {
    println("错误：找不到文件 -> " + path)
    return
  }

  // 3) 读文件失败 -> 明确提示
  let text = read_file_safe(path)
  if text == "" {
    println("错误：文件是空的，或者没有权限读取 -> " + path)
    return
  }

  // 4) 交给 vendor 进来的分词器切数据块 -> 逐块解析
  let warnings : Array[String] = []
  let mut blocks = @bio.parse_cif(text)
  if blocks.length() == 0 {
    // CIF 规范要求文件里有 data_ 行，但手写的文件常会漏掉。
    // 补一行再解析一次，让它仍能被当成一个匿名数据块处理（更宽容）
    let retry = @bio.parse_cif("data_unnamed\n" + text)
    if retry.length() > 0 {
      warnings.push("文件里没有 data_ 行，按单个匿名数据块处理")
      blocks = retry
    }
  }
  println("共找到 " + blocks.length().to_string() + " 个数据块")

  let crystals : Array[Crystal] = []
  for block in blocks {
    try {
      let crystal = parse_block(block, warnings)
      crystals.push(crystal)
    } catch {
      Failure(msg) => {
        let full = "数据块 [" + block.name + "] 解析失败：" + msg
        match on_error {
          Raise => {
            println("错误：" + full)
            return
          }
          Warn => warnings.push(full)
          Ignore => ()
        }
      }
    }
  }

  // 5) 一块都没成功 -> 明确报错（对齐 pymatgen 的 "no structures" 行为）
  if crystals.length() == 0 {
    println("错误：没有解析出任何结构（文件可能不是有效的 CIF）")
    print_warnings(warnings)
    return
  }

  // 6) 逐个打印
  let n = crystals.length()
  let mut i = 0
  while i < n {
    let crystal = crystals[i]
    if n > 1 {
      println("")
      println(
        "════════ 数据块 " +
        (i + 1).to_string() +
        "/" +
        n.to_string() +
        "：" +
        crystal.name +
        " ════════",
      )
    }
    print_report(crystal)
    i = i + 1
  }
  print_warnings(warnings)
}
