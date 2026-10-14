# MoonBit 生态检索报告：这个领域是不是空的？

**检索日期**：2026-10-14
**检索范围**：本机 MoonBit 包索引（`$env:USERPROFILE\.moon\registry\index\user`）
**规模**：**2594 个不重复的包**（2928 条版本记录，2952 个索引文件）

---

## 为什么要做这份检索

"MoonBit 生态里没有人做 CIF 解析和对称操作展开" —— 这是一个**技术主张**，
写进任何材料里都必须拿得出证据，而且必须交代**这个结论有多硬**。

这份文档就是那份证据：给出检索命令、全部命中结果、逐条排除理由，
以及**结论的方法学限制**。

---

## 一、检索命令（可自行重跑）

```powershell
$idx  = "$env:USERPROFILE\.moon\registry\index\user"
$all  = Get-ChildItem $idx -Recurse -File | ForEach-Object {
          [PSCustomObject]@{ F = $_.BaseName; T = (Get-Content $_.FullName -Raw) }
        }
"读入 $($all.Count) 个索引文件"

# 晶体学核心词：加词边界，避免 "specific" 命中 "cif" 这类误报
foreach ($t in @('\bcif\b', 'crystallograph', 'symmetry', '\bsymop\b',
                 'space.?group', 'lattice', 'unit.?cell', 'diffraction',
                 'wyckoff', 'bravais', 'point.?group', 'reciprocal')) {
  $h = @($all | Where-Object { $_.T -match $t })
  "{0,-16} {1,4}   {2}" -f $t, $h.Count, (($h | Select-Object -First 6 -ExpandProperty F) -join ', ')
}
```

> ⚠️ 本机索引**只在你运行 `moon` 命令时联网刷新**，所以它可能滞后几天。
> 本次检索时最新条目是 2026-10-11。
> **不要**用"索引文件数"当包数（一个文件里可能有多行版本记录）。

---

## 二、检索结果

### 完全没有命中的（0 个包）

| 检索词 | 命中 |
|---|---|
| `\bcif\b`（加词边界的 CIF） | **0** |
| `space group` / `spacegroup` | **0** |
| `\bsymop\b` / `symmetric operation` | **0** |
| `wyckoff` / `bravais` / `point group` | **0** |
| `unit cell` / `crystal structure` / `cif file` | **0** |
| `bragg` / `mineral` / `solid state` / `band structure` | **0** |
| `pymatgen` / `vasp` / `phonon` / `\bdft\b` | **0** |

### 有命中的（全部逐条排除）

| 包 | 它其实是什么 | 排除理由 |
|---|---|---|
| `moondiffraction` | 倒易空间衍射 + 粉末谱计算内核 | ✅ **唯一真正的邻居，但互补不冲突**：它自述不是 CIF 解析器；我们做"读结构 + 展开"，它做"从结构算衍射谱" |
| `mooncry` | MoonBit **密码学**原语（MD5/SHA/AES） | 名字像 "moon crystal"，实为 **crypto** |
| `generative_patterns` | 程序化图案 / SVG / 噪声场 | 生成艺术，不是晶体对称 |
| `moonbit-lbm` | D2Q9 格子玻尔兹曼**流体**仿真 | "lattice" 在流体力学里指网格 |
| `moonsmiles` | SMILES 分子式解析、分子性质、相似性 | 处理**分子**，不处理**晶体** |
| `thinfilm_tmm` | 薄膜光学传输矩阵法仿真 | 材料领域，但问题是**光学** |
| `moonbit-thermochem` | 热化学（NASA 多项式、反应焓、火焰温度） | 化学，不是晶体结构 |
| `moonbit-adsorption` | 吸附等温线、固定床穿透曲线 | 化工过程 |
| `moonbit-chemreport` | 化工计算报告层 | 无关 |
| `moonbit-biogeochem` | 海洋生物地球化学箱式模型（NPZD、碳循环） | 无关 |
| `atom` / `rss` / `moonfeed` / `feed_gen` | RSS / **Atom 订阅格式**解析 | "atom" 指订阅格式，不是原子 |
| `displaytext` / `moonetui` | 终端 UI 库 | "cell" 指字符单元格 |

---

## 三、⚠️ 这个结论有多硬：必须说明的方法学限制

**关键词检索证明不了"不存在"。** 最好的反例就在本项目的依赖里：

> `IvanAXu/BioSeqs` 内部**确实**有一个完整的 CIF 解析器（`src/crystal.mbt`，
> 正是本项目 vendor 的那份），但它的**包元数据里既没有 `crystal` 也没有 `cif` 关键词** ——
> 所以上面的扫描**根本扫不到它**。

因此准确的表述是：

> ❌ 不要说："全生态没有任何包涉及 CIF 解析"
>
> ✅ 应该说："**对全生态 2594 个包的元数据做关键词扫描，无命中；并逐一核对了最接近的
> 7 个包。已知的唯一例外是 `BioSeqs` 内部含一个 CIF 解析模块（未被元数据索引），
> 我们已审核其源码。**"

---

## 四、顺带得到的一个更重要的发现

整个"**固体物理 / 材料计算**"方向在 MoonBit 生态里基本是空的：

| 词 | 命中 |
|---|---|
| `dft` | 0 |
| `vasp` | 0 |
| `phonon` | 0 |
| `band structure` | 0 |
| `pymatgen` | 0 |
| `mineral` | 0 |

生态里所有"物理化学向"的包都集中在：**热化学、吸附、薄膜光学、分子（SMILES）、
生物地球化学** —— 全是化学工程 / 生物 / 光学，**没有一个是固体物理或晶体学计算**。

**这既是机会也是警告**：

- **机会**：占的不是"一个功能"的空位，而是**一整个领域的空位**
- **警告**：也可能说明这个生态目前的用户不来自材料领域 —— 没人需求，就没人做

---

## 五、结论

| 问题 | 答案 |
|---|---|
| 有人做 CIF 解析吗？ | 元数据里没有。已知唯一边例是 `BioSeqs` 内部模块（未索引） |
| 有人做对称操作展开吗？ | **没有**（`symop` / `space group` / `wyckoff` / `bravais` 全部 0 命中） |
| 有人做固体/材料计算吗？ | **没有**（`dft` / `vasp` / `phonon` / `pymatgen` 全部 0 命中） |
| 最近的邻居 | `moondiffraction`（衍射计算），**互补** |
