# 渲染管线与视觉形变

本文档介绍游戏的视口分层、摄像机控制、地形与水体图集生成机制，以及基于补间的角色挤压拉伸形变效果。

---

## 一、 渲染管线分层架构

### 1. 独立视口渲染 (`SubViewport`)
- 游戏世界内的所有实体（地形瓦片、玩家、敌人、子弹及掉落物）均渲染在 `Level0` 的 `WorldViewport`（`SubViewport`）内。
- 根视口负责采集玩家原始输入并转发至子视口。
- 全局后处理组件 `PostProcess`（[`core/present/post_process.gd`](../../core/present/post_process.gd)）挂载于主视口画布层，负责整体像素化缩放适配、角色倒地时的全屏去色、时间加速与回溯模式下的屏幕特效滤镜，以及低血屏幕边缘暗角。`set_health_ratio(hp, max_hp)` 按实际最大 HP 归一化强度，HP 恢复后强度平滑降至零；低血心跳音效受阈值与冷却控制，不会逐帧重启。单机与联机表现循环都更新该强度。

### 2. 摄像机系统 (`core/present/camera_2d.gd`)
- 首次绑定目标时初始化无抖动基准位置；之后以相机当前位置为锚点，用 `GridPathfinder.anchor_to_nearest()` 取环形地图最近副本，按 `cam_deadzone` 死区、`cam_smooth_x/y` 指数系数与 `cam_y_bias` 平滑跟随。
- 最终画面位置为基准位置 `+ shake_offset`；`get_base_global_position()` 只返回基准位置，武器瞄准换算不受震动影响。震屏只保留当前仍有效的较强振幅与较长持续时间；联机爆炸按爆心到本地角色的环形距离计算震幅，并按弹丸 ID 去重。
- 冲刺残影在本地按 `is_charge`、远端按同步姿态约每 `0.06s` 生成一次，复用 `AfterImage.spawn()`，冲刺结束停止。

---

## 二、 瓦片与水体图集生成 (`core/sim/terrain_atlas.gd`)

为了确保主菜单背景所渲染的世界与实际对局世界在视觉上保持一致，图集生成逻辑集中于 `TerrainAtlas`：

### 1. 16px 墙体象限图集 (`make_wall_tileset`)
- 将原始 32px 材质砖块拆分为 4×4 的 8×8 象限，通过最近邻采样放大 2 倍至 16×16 像素，生成由 16 列（象限）× 22 行（材质纹理）共计 352 个切片组成的 `TileSet`。
- 铺贴时，每个 16px 子格根据其在 64px 大格中的局部坐标偏移（$0 \sim 3$）索引对应象限，配合 3×3 环形平铺实现接缝处的画面无缝连续。

### 2. 水体图集 (`make_water_tileset`)
- 水体瓦片使用 0-based 图集索引 `WATER_BODY_BRICK = 20`，水面合批采样使用 `WATER_SURFACE_BRICK = 21`；`water_brick_image(ts, brick)` 的缓存键为 `(ts, brick)`，不同用途不会串图。
- 根据 2×2 形状掩码生成 16 种水体切片形态。水面动态起伏由 `water_surface.gdshader` 着色器驱动。

### 3. 天空背景清屏色
- `TerrainAtlas.SKY_COLOR`（`#B0E5F6`）为全局世界天空背景色的统一定义，对局初始化与主菜单背景均使用该颜色清屏。

---

## 三、 补间挤压拉伸形变 (`SquashStretch`)

表现层组件 `SquashStretch`（[`scenes/effects/squash_stretch.gd`](../../scenes/effects/squash_stretch.gd)）挂载于玩家实体、远端玩家镜像及各类敌人上，通过微调精灵节点缩放（`animator.scale`）提供动作弹性质感。

### 1. 数学模型
- 形变由两部分构成：滞空形变 `_air`（由垂直速度 `velocity.y` 逐帧计算）与动态脉冲形变 `_impulse`（起跳、冲刺、受击或落地瞬间触发，通过指数衰减逐步恢复基准值 0）。
- 缩放变形幅度上限由常量 `squash_amount = 0.06`（±6%）严格限制，仅改变视觉贴图缩放，不改变物理碰撞盒尺寸。

### 2. 落地挤压触发条件
- 角色落地瞬间，通过着地标记 `is_on_floor()` 且触地前的垂直速度 `vel_y > land_min_vy`（默认阈值 220.0 px/s）触发。
- 角色在水中下沉或沿梯子下滑时，垂直速度会被物理逻辑吸收，此时传入 `tick()` 的垂直速度置为 0，防止常规移动误触发落地挤压。

### 3. 联机远端镜像兼容
- 远端镜像同样挂载该组件，直接从服务端广播的快照速度向量中推导形变，无需新增网络同步字段。
- 倒地状态下自动设置 `suppressed = true` 抑制形变，防止角色旋转 90 度后发生不自然的横向拉伸。
