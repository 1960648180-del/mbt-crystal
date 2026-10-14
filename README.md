# mbt-crystal

[![CI](https://github.com/1960648180-del/mbt-crystal/actions/workflows/ci.yml/badge.svg)](https://github.com/1960648180-del/mbt-crystal/actions/workflows/ci.yml)

用 [MoonBit](https://www.moonbitlang.com/) 写的 CIF 晶体结构工具：

> **读取 CIF 里显式写出的对称操作，把「不对称单元」展开成完整晶胞。**

---

## 这是什么

CIF（Crystallographic Information File）是晶体学领域的标准文本格式。真实的 CIF 通常**只列出不对称单元里的几个原子**，再给出**一串对称操作**；要得到完整晶胞，必须把这些操作作用到每个原子上，并去掉重复位置。

这个工具就做这一件事 —— 但**把正确性做成可核验的**：

| 材料 | 空间群 | 文件里写的对称操作 | 不对称单元 | → 展开后 | 晶胞体积 | MP 官方值 |
|---|---|---|---|---|---|---|
| C（金刚石） | Fd-3m | **192 条** | 1 个原子 | **8** 个原子 | 45.146352 | 45.14635157 ✓ |
| SiC | F-43m | 96 条 | 2 个 | **8** 个 | 82.53977 | 82.53976981 ✓ |
| GaN | P6₃mc | 12 条 | 2 个 | **4** 个 | 45.728323 | 45.72832355 ✓ |
| Ga₂O₃ | C2/m | 8 条 | 5 个 | **20** 个 | 211.467526 | 211.46752568 ✓ |

> 金刚石那一行是真正的考验：**192 条对称操作作用在 1 个原子上，正确结果是 8 个不同位置**
> —— 其余 184 个全是重复。周期性去重逻辑必须精确压成 8 个。

---

## 为什么会有这个项目

在 MoonBit 生态里做过全量检索（**2952 个包**的元数据全部扫描 + 人工核对最接近的 7 个包）：

> **没有找到任何做 CIF 解析或对称操作展开的包。**

生态快照（2026-10-11，从官方注册表索引实测，不是搜索得来的）：
**2952 个包 / 853 位发布者 / 17709 条版本记录**；
**最近 30 天新增 527 个包（+17.9%），最近 90 天新增 1337 个（+45.3%）** ——
也就是说生态正处在高速扩张期，现在进入正是时候。

检索命令、完整命中结果、以及**这个结论的方法学限制**都写在
[`docs/ECOSYSTEM-SCAN.md`](docs/ECOSYSTEM-SCAN.md) 里 —— 我们特意把"关键词检索证明不了什么"
这一点也说清楚了，不做过度主张。

---

## 怎么跑

前置条件：`moon` 在 PATH 里（MoonBit 工具链已安装）。

```powershell
# 跑一个用例
moon run cmd/main -- tests/functional/symop-diamond-fd3m.cif

# 第二个参数是出错策略，默认 warn
moon run cmd/main -- tests/functional/frac_demo.cif raise     # 出错就停
moon run cmd/main -- tests/functional/frac_demo.cif ignore    # 出错静默跳过
```

输出包括：晶格参数、晶胞体积、对称性统计、完整原子列表、以及所有警告。

---

## 当作库来用

根包**就是库**（不是可执行程序），所以别的 MoonBit 项目可以直接依赖它：

```
// moon.mod —— 发布到 mooncakes.io 之后即可这样依赖
import {
  "1960648180-del/mbt-crystal@0.1.0",
}
```

> 目前**尚未发布**到 mooncakes.io，所以在线安装还不行；
> 想在本地当依赖用，可以看 `tests/tools/check_consumable.py` ——
> 它就是用一个 `moon.work` 工作区把本库当普通依赖引入的完整例子。

```moonbit
// 你的代码
let result : @lib.CifResult = @lib.parse_cif(text, @lib.Warn) catch {
  Failure(msg) => {
    println("解析失败：" + msg)
    return
  }
}
println(result.block_count) // 文件里有几个数据块
for crystal in result.crystals {
  println(crystal.atoms.length()) // 展开后的原子数
  println(@lib.cell_volume(crystal.lattice))
  println(
    @lib.composition_to_string(@lib.composition_of_atoms(crystal.atoms)),
  )
}
println(result.warnings.length()) // 警告不会让程序罢工，都攒在这儿
```

公开接口一共 **9 个函数 + 7 个类型**，完整清单见
[`pkg.generated.mbti`](pkg.generated.mbti)（由 `moon info` 生成，也是别人
`moon add` 之后看到的"门面"）：

| 函数 | 用途 |
|---|---|
| `parse_cif(text, on_error)` | 解析 CIF 文本 → `CifResult`（结构 + 数据块数 + 警告） |
| `cell_volume(lattice)` | 三斜通用晶胞体积 |
| `expand_atoms(asym, ops)` | 用对称操作展开成完整晶胞（含周期性去重） |
| `spacegroup_ops(number)` | 按国际编号查 230 个空间群的对称操作 |
| `parse_symop(text)` | 解析一条操作文本（如 `"x, 1/2-y, 1/2+z"`） |
| `composition_of_atoms` / `composition_to_string` | 组成统计与可读化 |
| `cell_metric` / `to_radian` | 根号里那一坨（用来判断角度是否合法）/ 角度转弧度 |

> **为什么这件事值得专门做**：MoonBit 里一个包只能是【库】或【可执行程序】
> 二选一。早期整包标了 executable，结果**别的项目在语法上根本 import 不了它** ——
> 解析得再准，别人也用不上。现在根包是库、CLI 挪到 `cmd/main`，两边都不牺牲。
> `tests/tools/check_consumable.py` 会在**仓库外面**造一个消费者模块来守住这条线，
> CI 每次都跑 —— 防的是哪天又悄悄退回成"只有自己能跑"。

---

## 支持什么 / 不支持什么

**支持**

- 按 `data_` 切分多个数据块，一块一个结构
- 6 个晶格参数（含 `5.4310(2)` 这种 CIF 误差括号写法）、三斜通用体积公式
- 原子位点表：**按列名找列**（不依赖列顺序）
- **对称操作解析与展开**：支持 `-x+y+1/2` 这类写法、`1/3` 与 `2/3` 分数、折回 `[0,1)`、周期性去重
- **两条获取对称操作的路径**：
  1. 用文件里**显式写出**的操作
  2. 文件只给空间群编号时，按 `_symmetry_Int_Tables_number`（1~230）**查内置表**得到操作
     （表由 spglib 的空间群数据库生成，覆盖全部 230 个空间群、共 4425 条操作；
     从 spglib 生成 → 用我们的解析器解析 → 与 pymatgen 的展开结果逐条对照，全部通过）
- 化学式自检：解析结果 vs CIF 自带的 `_chemical_formula_sum`
- 警告收集 + 三种出错策略（`ignore` / `warn` / `raise`）
- 非法晶格角度、缺失列、非数字等异常输入都能给出**明确提示且不崩溃**
- **可作为库被依赖**：根包是库，公开 9 个函数 + 7 个类型；命令行程序在 `cmd/main` 单独成包

**不支持（这一版的边界）**

- ❌ 不做占有率（`_atom_site_occupancy`）加权：读了但不参与组成统计
- ❌ 不做 CIF 写入、笛卡尔坐标、化学键、密度、无序结构
- ❌ CIF 数据名按**大小写敏感**匹配（按规范本应不敏感；见已知限制）

---

## 验证

```powershell
python tests\tools\verify.py
```

一条命令跑完 **37 项检查**，逐条打印 `[OK]` / `[FAIL]`。

**期望值的设计原则**：如果期望值由写代码的人自己写，他写错了测试也会通过 ——
那不叫验证，叫自证。所以期望值全部来自**独立来源**：

| 组 | 检查什么 | 期望值来源 |
|---|---|---|
| 1 | 13 个真实 Materials Project 文件 | **文件自带的官方 `_cell_volume` 字段** |
| 2 | 8 个对称展开用例（含 192 条操作、含只给空间群编号的） | **pymatgen**（Materials Project 官方工具链） |
| 3 | 4 个合成用例 | **从文件里的 `a` 自算**（立方 V = a³） |
| 4 | 12 个错误用例 | 手写关键词 —— 只有这一组没办法（在测我们自己的报错文案） |

另有一条线由单独的脚本守着 —— 「这个库真的能被外部依赖吗」：

```powershell
python tests\tools\check_consumable.py
```

它会在**仓库外面**（否则就不叫"外人"了）造一个小模块，`import` 本库、
构造它的公开类型、调用 4 个公开接口并校对结果（5 项检查）。

完整说明见 [`VERIFICATION.md`](VERIFICATION.md)。

---

## 目录结构

```
moon.pkg                     根包配置 —— 本包是【库】，别人可以 import
cif.mbt                      库主体：数据模型、几何、CIF 适配、对称操作解析与展开、公开 API
spacegroup_table.mbt         空间群查找表（230 个群 / 4425 条操作，脚本生成，请勿手改）
cif_wbtest.mbt               白盒单元测试（35 条，moon test 直接跑）
cmd/main/                    命令行程序（单独成包，只负责读参数、读文件、打印）
pkg.generated.mbti           对外公开接口清单（moon info 生成；上游生态惯例是提交进仓库）
vendor/crystal/              复用的第三方分词层（见下）
tests/functional/            功能用例（含 4 个高对称用例 + 1 个只给空间群编号的用例）
tests/errors/                错误用例
tests/tools/verify.py        一键验证脚本（37 项）
tests/tools/check_consumable.py  在仓库外验证"别人真的能用这个库"
tests/tools/make_symmetry_cases.py  生成高对称用例
tests/tools/gen_spacegroups.py      生成空间群查找表
mp-149.cif, mp-reference/    真实 Materials Project 数据（用于交叉校验）
docs/ECOSYSTEM-SCAN.md       生态检索证据
VERIFICATION.md              验证报告
THIRD_PARTY_NOTICES.md       第三方代码与数据来源
LICENSE                      Apache-2.0
```

---

## 代码归属（哪些是自研，哪些是复用）

**分工**：分词这层"管道活"不重复造轮子，解析交给第三方；**对称操作展开是自研的**。

| 部分 | 行数 | 归属 |
|---|---|---|
| `cif.mbt` + `spacegroup_table.mbt` | 1160 | 自研（对称展开全部逻辑、化学式自检、出错策略、对外 API） |
| `cmd/main/` | 186 | 自研（命令行入口与排版；库本身不打印任何东西） |
| `vendor/crystal/` | 1426 | 复用 `IvanAXu/BioSeqs` 的 `crystal.mbt` + `utils.mbt`（Apache-2.0） |

**为什么是"复制文件"而不是普通依赖**：BioSeqs 整包在本项目使用的 MoonBit 工具链下
**编译不通过**（109 处错误，集中在 6 个与晶体学无关的文件）。若硬依赖，
任何人在干净环境里 `moon build` 都会直接失败。

细节（来源、改动记录、已知问题）见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 空间群表用「默认设置」 | 同一编号在数据库里可能对应多个设置（origin choice / 轴变换）；我们取标准设置，这与 CIF 里 `_symmetry_Int_Tables_number` 的通常含义一致 |
| 占有率不参与组成统计 | 按整数数原子 |
| CIF 数据名大小写敏感 | 按规范本应不敏感；我们的实现和复用的分词器都是精确匹配 |
| 第三方分词器的一个弱点 | 某一行字段数与表头数不等时，该行被丢弃且**后续行整体错位**。我们已在坐标处加了显式检查，但极端情况下仍可能静默出错（详见 `THIRD_PARTY_NOTICES.md`） |
| vendor 代码带 15 条废弃 API 警告 | 保持原样未改，以便"改了哪里"一目了然（后续计划修掉） |

---

## 数据来源与署名

`mp-149.cif` 与 `mp-reference/` 下的 CIF 是通过 **Materials Project** REST API 导出的真实结构数据，
仅用于功能测试与数值比对。

> **数据来源**：Materials Project —— <https://materialsproject.org>
> **许可证**：CC BY 4.0（允许使用与再分发，**要求署名**）。本项目在此履行署名义务。
> **建议引用**：Jain et al., *Commentary: The Materials Project*,
> APL Materials **1**, 011002 (2013).

`tests/functional/symop-*.cif` 由 `tests/tools/make_symmetry_cases.py` 生成：
拿上述真实结构，用 spglib 找回对称性，再写出带完整显式对称操作的 CIF。

## 许可证

Apache License 2.0（见 [`LICENSE`](LICENSE)）。
