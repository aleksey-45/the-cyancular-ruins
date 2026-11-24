# B-1 二维光照技术规格

2026-11-24，待审核。实施顺序见 [B-1 实施计划](2026-11-24-render-b1-plan.md)。

## 渲染顺序

1. 世界视口绘制天空、视差背景、地形、水体、精灵和场景内提示。地形、水体和精灵着色器使用各自的法线贴图处理日光与环境光。
2. `LightViewport` 绘制可见的局部灯，输出低分辨率光照纹理。
3. 后期处理先将光照纹理合成到可受光的世界区域，再处理受击、低血量、回溯、加速、桶形畸变、颜色量化和抖动。后期层继续使用 `CanvasLayer 128`。
4. 屏幕 HUD 和界面置于后期画面上方。录像采集根视口。

表现层以 `MatchFrame` 提供对象状态。昼夜数据 `SkyState` 包含环境光颜色、太阳方向和颜色、太阳强度、天空渐变与夜间系数。局部灯集合 `LightSet` 由地图、场景和实体表现提供。局部灯和材质参数由客户端表现层消费。服务器快照继续描述对局状态。

## 对象着色

使用地形、水体和精灵各自的着色器。对齐同一图集像素，地形保留约 1 像素颗粒，角色保留约 2.5 像素颗粒。法线贴图采用 X+/Y+/Z+，RG 解码到 `[-1, 1]`，由单位长度恢复 Z。精灵水平镜像时反转法线 X，旋转和挤压拉伸时保持法线与精灵变换一致。

```glsl
vec2 xy = normal_sample.rg * 2.0 - 1.0;
vec3 n = normalize(vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0))));
float ndotl = max(dot(n, sun_dir), 0.0);
vec3 diffuse = albedo * (ambient + sun_color * sun_strength * ndotl);
vec3 half_vector = normalize(sun_dir + vec3(0.0, 0.0, 1.0));
float shininess = exp2(mix(1.0, 8.0, 1.0 - roughness));
float specular = pow(max(dot(n, half_vector), 0.0), shininess) * spec_strength;
vec3 lit = diffuse + vec3(specular);
```

金属用较强高光和较低粗糙度，木料、石材和羽毛用较弱高光及较高粗糙度。环境色在单个位置应用一次。检查 `CanvasModulate` 与对象着色器交接时有无重复乘色。

精灵着色完成后，使用玩家贴图的眼睛掩码加上自发光颜色。眼睛以局部加色呈现，保持像素边缘。屏幕光晕和全局自发光缓冲留在本期范围外。

## 图集与材质数据

受光图集包括原基色图、`*_normal.png` 和 `*_hint.png`。三张图共用尺寸、帧坐标和边缘留白，使用最近邻过滤，关闭 mipmap。法线以手绘为主，允许用 Laigter 辅助起稿。材质属性使用连续数值，同张图集内可按像素改变材质。

| `*_hint.png` 通道 | 用途 |
| --- | --- |
| R | 高光或反射强度。 |
| G | 玩家眼睛的自发光掩码，其他图集置零。 |
| B | 粗糙度。 |
| A | 预留给边缘光。 |

| 对象 | 贴图和绘制约定 |
| --- | --- |
| 天空与视差 | `sky_gradient.tres` 随昼夜调色板变化，视差背景使用环境色调。保留日照方向和高度数据。局部灯的合成区域排除天空与视差背景。 |
| 地形 | `structure.png`、`structure_normal.png`、`structure_hint.png` 共用 320×320 布局。梯子和铁链共用地形着色器。梯子使用较弱的法线起伏和高光，铁链使用硬边法线和较强的高光。 |
| 水体 | `water_normal.png` 和 `water_hint.png` 与水面资源对齐。保留顶点起伏和水纹，用日光与材质参数计算水面高光。折射、焦散和阴影留待后续。 |
| 玩家 | `player.png`、`player_normal.png`、`player_hint.png` 共用 200×200 帧布局。保留受击闪白、无敌闪烁、变形和残影。身体变形与武器挂点分别处理。 |
| 敌人 | 跳鸟、飞鸟和黑鸟各配法线与材质图。爪和喙用较强高光。时间技能继续使用 `GLOW`，黑鸟白剪影使用 `MASK`，血条和名字走无光照绘制。 |
| 武器与弹丸 | `weapons.png`、`weapons_normal.png`、`weapons_hint.png` 共用布局，区分枪身金属和握把。子弹、箭和榴弹可沿用无光照绘制，激光、爆炸和碎片保留既有特效路径。拾取和换弹提示走场景内 HUD。 |

## 局部灯与后期合成

`LightViewport` 是透明背景的 `SubViewport`，下设 `LightCamera` 和 `LightCanvas`。相机同步世界视口。先比较半分辨率（例如 960×720）和像素分辨率。光照视口绘制径向或锥形有色光斑。

`WorldLight` 记录位置、颜色、半径、强度、衰减和闪烁。灯具按可见范围裁剪及排序，夜间系数乘到亮度。8–16 盏为待测范围，最终上限由实测确定。当前方案的局部灯负责提亮颜色，方向高光来自对象着色器中的日光计算。

后期按世界遮罩或限定合成区域应用光照纹理。合成前确认采样坐标与世界视口一致，避免相机移动或缩放时错位。

```glsl
vec4 base = texture(screen_tex, uv);
vec3 light = texture(light_tex, uv).rgb;
base.rgb += light * (1.0 - base.rgb);
```

## 合批、迁移与调试

- 精灵按 `AtlasStyle` 合批。材质差异写入图集，避免为单个精灵建节点或因材质拆分绘制。地形与水体沿用各自批处理。
- 保留 `WorldCanvas`、`TerrainView`、`WaterSurfaceBatch`、`PostProcess`、动作残影、`Recorder` 和 HUD。新路径通过回归后，移除 `player_color.gdshader`、`player_shade` 和 `WorldCanvas.Pass.PLAYER`。
- 调试输出分别显示法线、高光强度、粗糙度和光照纹理。单独检查玩家眼睛及天空边缘，记录分辨率、可见灯数和帧时间。性能目标为 60 帧/秒。

## 验收

- 对照白天、夜间和镜头移动后的画面，检查方向光及金属、木料与石材的高光差异。
- 检查角色镜像、旋转、挤压拉伸、残影、敌人血条和场景内提示。
- 检查局部灯提亮地面、角色与水体，天空、视差和屏幕 UI 无染色。
- 复验录像输出、暂停和加载界面，运行自动化检查与命名检查。

术语参考 [Godot 子视口](https://docs.godotengine.org/zh-cn/4.4/classes/class_subviewport.html)、[Unity 纹理类型](https://docs.unity3d.com/cn/6000.0/Manual/texture-types.html)、[虚幻引擎材质属性](https://dev.epicgames.com/documentation/zh-cn/unreal-engine/unreal-engine-material-properties)和[后期处理材质](https://dev.epicgames.com/documentation/zh-cn/unreal-engine/post-process-materials-in-unreal-engine)。
