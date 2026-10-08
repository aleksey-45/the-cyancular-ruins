# `.cyrm` v4 地图格式技术规范与实现说明

本文档说明 `.cyrm` v4 二进制地图文件格式、字节结构、子格图集渲染模型以及 Godot 4.7 引擎端的实现方式。

---

## 一、 格式版本对比

| 属性维度 | 旧版 (v3) | 新版 (v4) |
|---|---|---|
| **存储方式** | 纯文本，每格 4 字符十六进制编码 | **二进制封装**：20 字节文件头 + Deflate 压缩数据体 |
| **网格分辨率** | 64px 宏观网格，内部 2×2 形状掩码（32px） | 64px 宏观网格，细分为 **4×4 子格（16px）** |
| **子格描述** | 单一纹理索引 + 4-bit 形状掩码 | 32-bit 独立描述符（纹理 ID + 四通道染色属性） |
| **图层划分** | 单一图层 | **四层结构**（前景 / 场景 / 后景 / 背景） |
| **物理碰撞** | 基于整图构建 | **仅「场景（Scene）」层生成物理碰撞** |

---

## 二、 `.cyrm` v4 二进制文件结构

### 1. 文件头布局（未压缩，固定 20 字节，小端序）

| 字节偏移 | 字段大小 | 字段名称 | 类型 | 说明 |
|---|---|---|---|---|
| 0 | 4 | `magic` | char[4] | 固定 ASCII 字符 `"CYRM"`（十六进制 `43 59 52 4D`） |
| 4 | 1 | `version` | uint8 | 格式主版本号，固定为 `4` |
| 5 | 1 | `compression` | uint8 | 压缩算法标记：`0` = 无压缩，`1` = Deflate (zlib) |
| 6 | 4 | `body_size` | uint32 | **解压后**数据体的总字节数（上限保护 $\le 64\text{ MB}$） |
| 10 | 4 | `body_crc32` | uint32 | **解压后**数据体的 CRC-32 校验码（IEEE 802.3 标准） |
| 14 | 2 | `sub_cols` | uint16 | 16px 子格总列数（必须为 4 的整数倍） |
| 16 | 2 | `sub_rows` | uint16 | 16px 子格总行数（必须为 4 的整数倍） |
| 18 | 1 | `layer_flags` | uint8 | 图层启用位掩码：bit0=前景, bit1=场景, bit2=后景, bit3=背景 |
| 19 | 1 | `reserved` | uint8 | 保留对齐字节，固定为 `0` |
| 20... | - | `body` | byte[] | 数据体载荷（`compression=1` 时为 Deflate 压缩流） |

### 2. 解压后数据体 (Body) 结构

```text
uint16   meta_len           # 元数据文本字节长度
byte[]   meta_utf8          # meta_len 长度的 UTF-8 元数据文本
# 紧随其后按 layer_flags bit0 至 bit3 的启用顺序排布各激活图层数据块
```

元数据文本遵循 `#` 行注释规范：
```text
# 地图配置与说明注释
# player  23 43
# player2 26 9
# enemy fly_bird 30 15
```
> [!NOTE]
> 出生点与敌人生成坐标仍使用 64px 逻辑网格坐标单位，无需换算为子格单位。

### 3. 纹理层数据块（前景 / 场景 / 后景，Kind = 1）

```text
uint8    kind = 1           # 图层类型标识
uint16   palette_count      # 调色板条目数
uint32[] palette_entries    # palette_count 个 32 位描述符（小端序）
uint8    index_width        # 索引宽度（字节数：palette_count <= 256 时为 1，否则为 2）
byte[]   sub_indices        # sub_cols * sub_rows * index_width 字节（行优先索引流）
```
- 索引 0 恒保留为描述符 0（空气，无材质）。

### 4. 背景层数据块（背景，Kind = 2）

```text
uint8    kind = 2           # 图层类型标识
byte[]   bg_rgba            # sub_cols * sub_rows * 4 字节，行优先 RGBA 真彩色流
```

### 5. 子格 32-bit 描述符位域定义

| 位区间 | 字段名称 | 取值范围 | 语义说明 |
|---|---|---|---|
| bit 0..2 | `hue` | 0 ~ 7 | 色相偏移档位（中性档 = 4，对应 0° 偏移） |
| bit 3..5 | `brightness` | 0 ~ 7 | 亮度缩放档位（中性档 = 4，对应 ×1.0） |
| bit 6..8 | `saturation` | 0 ~ 7 | 饱和度缩放档位（中性档 = 4，对应 ×1.0） |
| bit 9..11 | `alpha` | 0 ~ 7 | 不透明度档位（中性档 = 7，对应完全不透明 1.0） |
| bit 12..23 | `texture` | 1 ~ 4095 | 纹理材质 ID（0 为空气） |
| bit 24..31 | `reserved` | 0 | 保留位，固定为 0 |

---

## 三、 象限图集与染色模型

### 1. 象限切片与 352-Tile Atlas 映射
每个 64px 宏观网格包含 4×4 个 16px 子格。子格在局部宏观格内的相对坐标 $(q_x, q_y)$ 决定其采样的象限：
- 渲染系统通过动态图集管理：22 种基础纹理 $\times 16$ 个象限切片，共计预生成 352 块 16px Tile，有效避免了 $2^{16}$ 种形状组合带来的显存膨胀。

### 2. 染色调整公式
色彩调制统一在 HSV 空间下计算：
1. $(H, S, V) = \text{RGB\_to\_HSV}(R, G, B)$
2. $H' = (H + (\text{hue} - 4) \times 15^\circ) \bmod 360^\circ$
3. $S' = \text{clamp}(S \times \text{SAT\_MUL}[\text{saturation}], 0, 1)$
4. $V' = \text{clamp}(V \times \text{BRI\_MUL}[\text{brightness}], 0, 1)$
5. $(R', G', B') = \text{HSV\_to\_RGB}(H', S', V')$
6. $A' = A \times (\text{alpha} / 7)$

---

## 四、 游戏引擎端落地架构 (Godot 4.7)

游戏采用逻辑层与物理碰撞分层的协同方案（`core/sim/map_format_v4.gd` 与 `core/sim/tile_defs.gd`）：

1. **逻辑网格维持 64px**：`MazeGenerator.current_grid` 继续保持 64px 宏观网格尺寸，保证现有的 A* 寻路、视线检测、生成点判定及攀爬/游泳逻辑正常运行。
2. **物理碰撞下沉至 16px**：`MazeGenerator.current_subgrid` 维护 16px 子格数据与生命值表。`CollisionBuilder` 基于 16px 子格构建碰撞体，已被破坏的子格不再生成物理碰撞。
3. **部分破坏机制**：
   - 子弹与爆炸伤害直接作用于 16px 子格（`TileDefs.damage_sub`）。
   - 只有当一个 64px 大格内的全部 16 个子格都被完全摧毁时，才清空上层的宏观网格数据。
4. **时间回溯兼容**：瓦片破坏账本记录 `{sub, hp}` 细粒度数据，支持回溯时对 16px 子格精准还原。
