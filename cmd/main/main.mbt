/// ---------------------------------------------------------------
/// 命令行入口
///
/// 跑法：moon run cmd/main -- <CIF 文件路径> [ignore|warn|raise]
/// 例：  moon run cmd/main -- tests/functional/symop-gan-p63mc.cif
///
/// 解析、展开这些"里子活"全在根包（库）里，这里只负责读和打印。
/// ---------------------------------------------------------------

/// 安全读文件：读不了就返回空字符串（不让程序直接崩掉）
fn read_file_safe(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => ""
  }
}

/// 把命令行里的策略字符串转成枚举，认不出来就用默认的 Warn
fn parse_on_error(text : String) -> @lib.OnError {
  if text == "ignore" {
    @lib.Ignore
  } else if text == "raise" {
    @lib.Raise
  } else {
    @lib.Warn
  }
}

/// 程序入口
fn main {
  // 1) 检查命令行参数
  let args = @env.args()
  if args.length() < 2 {
    println("用法：moon run cmd/main -- <CIF 文件路径> [ignore|warn|raise]")
    println("示例：moon run cmd/main -- mp-149.cif")
    println("      moon run cmd/main -- mp-149.cif warn   （出错策略，默认 warn）")
    return
  }
  let path = args[1]
  let on_error = if args.length() >= 3 {
    parse_on_error(args[2])
  } else {
    @lib.Warn
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

  // 4) 交给库解析。策略是 raise 时，库会把错误抛出来，这里接住并报清楚
  let result : @lib.CifResult = try {
    @lib.parse_cif(text, on_error)
  } catch {
    Failure(msg) => {
      println("错误：" + msg)
      return
    }
  }
  println("共找到 " + result.block_count.to_string() + " 个数据块")

  // 5) 一块都没成功 -> 明确报错（对齐 pymatgen 的 "no structures" 行为）
  if result.crystals.length() == 0 {
    println("错误：没有解析出任何结构（文件可能不是有效的 CIF）")
    print_warnings(result.warnings)
    return
  }

  // 6) 逐个打印
  let crystals = result.crystals
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
  print_warnings(result.warnings)
}
