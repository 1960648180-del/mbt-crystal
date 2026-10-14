# 第三方代码说明（THIRD-PARTY NOTICES）

本项目的主体代码（`cif.mbt`、`spacegroup_table.mbt`、`cmd/main/`、`moon.pkg`、`moon.mod`）为原创。
`vendor/` 目录下有一部分代码来自第三方，按 Apache-2.0 第 4 条的要求在此声明来源。

---

## 1. 来源

| 项目 | 内容 |
| --- | --- |
| 上游包 | `IvanAXu/BioSeqs`，版本 `0.1.9` |
| 上游文件 | `src/crystal.mbt`（模块名 `Bio.Crystal`）与 `src/utils.mbt` |
| 许可证 | Apache License 2.0 —— 全文见仓库根目录 `LICENSE` |
| 获取途径 | MoonBit 包注册表（`moon add IvanAXu/BioSeqs@0.1.9`） |

## 2. 本项目用了哪几个文件、改了什么

| 文件 | 状态 |
| --- | --- |
| `vendor/crystal/crystal.mbt` | 从上游 `src/crystal.mbt` **原样复制，未修改** |
| `vendor/crystal/utils.mbt` | 从上游 `src/utils.mbt` **原样复制，未修改** |
| `vendor/crystal/moon.pkg` | **本项目自己写的**（上游没有这个文件），只声明 `moonbitlang/core/math` |

> 若今后为消除废弃 API 警告而修改上述两个 `.mbt` 文件，
> 必须按 Apache-2.0 第 4(b) 条在文件内加显著标注，并回来更新本表。

## 3. 为什么是"复制文件"而不是普通的包依赖

`moon add IvanAXu/BioSeqs@0.1.9` 能成功下载（约 14.89 MB、1994 个文件），
但整包在本项目使用的 MoonBit 工具链（`0.1.20260920`）下**编译不通过**：
报 109 处错误，分布在 `mofa2`、`statistics`、`slingshot`、`singscore`、`hmmcopy`、
`factoextra` 六个与晶体学无关的文件里（根因是 `let var = ...` —— `var` 在新版
MoonBit 中已是保留字），外加若干类型不匹配。

如果把它当作正式依赖，任何人在干净环境里执行 `moon build` 都会直接失败，
因此改为只 vendor 其中的 `crystal.mbt` + `utils.mbt` 两个文件
（这两个文件本身是干净的，依赖链也只收敛在这两个文件）。

## 4. 本项目在 vendored 代码之上做了什么

vendored 的 `crystal.mbt` 提供的是**解析层**（切数据块、认 `loop_` 表、按列名取表、
引号感知的分词、晶格/密度/化学键/空间群等结构）。它**不提供**显式对称操作的展开 ——
这正是本项目自己实现的部分，也是 `cif.mbt` 的核心：

- `parse_symop`：把 `-x+y+1/2` 这样的操作字符串解析成 3 组 (整数系数, 平移量)
- `apply_symop`：把操作作用在分数坐标上
- `wrap01`：把结果折回 `[0, 1)`（周期性）
- `has_same_site` / `frac_same`：按周期性去重（`0.0` 与 `0.9999` 视为同一位置）
- `expand_atoms`：把不对称单元展开成完整晶胞

此外 `cif.mbt` 还保留了 vendored 代码没有的能力：警告收集 + 出错策略
（`ignore` / `warn` / `raise`）、化学式自检（与 `_chemical_formula_sum` 对账）。

## 5. 已知遗留问题

- vendored 的两个 `.mbt` 文件带有 **15 条废弃 API 警告**（主要是 `Array::new()`、
  `StringView::to_string` 等上游写法），目前**保持原样未改**，以便"改了哪里"一目了然。
- vendored 的分词器要求**一行字段数 == 表头数**，不等就丢弃该行。手写 CIF 多写或
  少写一个 `.` 占位符会导致后续行整体错位；本项目在坐标解析处加了显式检查与提示
  （见 `cif.mbt` 的 `parse_coord`）。

## 6. 测试数据来源

仓库里的 `mp-149.cif` 与 `mp-reference/` 下的 7 个 CIF 文件，是通过 Materials Project
的 REST API（`https://api.materialsproject.org`）导出的真实结构数据，仅用于本项目的
功能测试与数值比对。

- 选用材料：Si、GaN、AlN、ZnO、Ga₂O₃、SiC、金刚石（C）、BN —— 经典宽禁带材料
- 用途：交叉校验晶胞体积（与 MP 官方 `_cell_volume` 字段逐位比对）
- **许可与署名**：Materials Project 的数据公开发布，采用 **CC BY 4.0**
  （允许使用与再分发，**要求署名**）。本项目据此使用，并在此履行署名义务：
  - **数据来源**：Materials Project —— <https://materialsproject.org>
  - **建议引用**：Jain et al., *Commentary: The Materials Project*,
    APL Materials **1**, 011002 (2013)
