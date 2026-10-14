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

在 MoonBit 生态里做过一次全量检索（**2594 个包**的元数据全部扫描 + 人工核对最接近的 7 个包）：

> **没有找到任何做 CIF 解析或对称操作展开的包。**

检索命令、完整命中结果、以及**这个结论的方法学限制**都写在
[`docs/ECOSYSTEM-SCAN.md`](docs/ECOSYSTEM-SCAN.md) 里 —— 我们特意把"关键词检索证明不了什么"
这一点也说清楚了，不做过度主张。

---

## 怎么跑

前置条件：`moon` 在 PATH 里（MoonBit 工具链已安装）。

```powershell
# 跑一个用例
moon run . -- tests/functional/symop-diamond-fd3m.cif

# 第二个参数是出错策略，默认 warn
moon run . -- tests/functional/frac_demo.cif raise     # 出错就停
moon run . -- tests/functional/frac_demo.cif ignore    # 出错静默跳过
```

输出包括：晶格参数、晶胞体积、对称性统计、完整原子列表、以及所有警告。

---

## 支持什么 / 不支持什么

**支持**

- 按 `data_` 切分多个数据块，一块一个结构
- 6 个晶格参数（含 `5.4310(2)` 这种 CIF 误差括号写法）、三斜通用体积公式
- 原子位点表：**按列名找列**（不依赖列顺序）
- **显式对称操作解析与展开**：支持 `-x+y+1/2` 这类写法、`1/3` 与 `2/3` 分数、折回 `[0,1)`、周期性去重
- 化学式自检：解析结果 vs CIF 自带的 `_chemical_formula_sum`
- 警告收集 + 三种出错策略（`ignore` / `warn` / `raise`）
- 非法晶格角度、缺失列、非数字等异常输入都能给出**明确提示且不崩溃**

**不支持（这一版的边界）**

- ❌ **不从空间群编号推导对称操作** —— 只读文件里**显式写出**的操作。
  文件只给 `_symmetry_Int_Tables_number` 而不写操作时，按 `P 1` 处理（会打印提示，但不会展开）
- ❌ 不做占有率（`_atom_site_occupancy`）加权：读了但不参与组成统计
- ❌ 不做 CIF 写入、笛卡尔坐标、化学键、密度、无序结构
- ❌ CIF 数据名按**大小写敏感**匹配（按规范本应不敏感；见已知限制）

---

## 验证

```powershell
python tests\tools\verify.py
```

一条命令跑完 **35 项检查**，逐条打印 `[OK]` / `[FAIL]`。

**期望值的设计原则**：如果期望值由写代码的人自己写，他写错了测试也会通过 ——
那不叫验证，叫自证。所以期望值全部来自**独立来源**：

| 组 | 检查什么 | 期望值来源 |
|---|---|---|
| 1 | 12 个真实 Materials Project 文件 | **文件自带的官方 `_cell_volume` 字段** |
| 2 | 7 个对称展开用例（含 192 条操作） | **pymatgen**（Materials Project 官方工具链） |
| 3 | 4 个合成用例 | **从文件里的 `a` 自算**（立方 V = a³） |
| 4 | 12 个错误用例 | 手写关键词 —— 只有这一组没办法（在测我们自己的报错文案） |

完整说明见 [`VERIFICATION.md`](VERIFICATION.md)。

---

## 目录结构

```
main.mbt                     自研代码（980 行）：对称操作解析与展开、化学式自检、打印、主程序
moon.mod / moon.pkg          模块与包配置
vendor/crystal/              复用的第三方分词层（见下）
tests/functional/            功能用例（含 4 个高对称用例）
tests/errors/                错误用例
tests/tools/verify.py        一键验证脚本
tests/tools/make_symmetry_cases.py  生成高对称用例
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
| `main.mbt` | 980 | 自研（含对称展开全部逻辑、化学式自检、出错策略） |
| `vendor/crystal/` | 1426 | 复用 `IvanAXu/BioSeqs` 的 `crystal.mbt` + `utils.mbt`（Apache-2.0） |

**为什么是"复制文件"而不是普通依赖**：BioSeqs 整包在本项目使用的 MoonBit 工具链下
**编译不通过**（109 处错误，集中在 6 个与晶体学无关的文件）。若硬依赖，
任何人在干净环境里 `moon build` 都会直接失败。

细节（来源、改动记录、已知问题）见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 只有显式对称操作才能展开 | 只给空间群编号的文件按 `P 1` 处理（会打印提示） |
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
