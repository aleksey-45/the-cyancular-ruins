# STATE 编码资料与采用方案

## 资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Riot：[VALORANT Server Performance](https://playvalorant.com/en-us/news/dev/how-we-got-to-the-best-performing-valorant-servers-since-launch/) | 属性比较重复执行会随连接数放大，先检查数据准备和比较次数 |
| Epic：[Fortnite Improvements](https://www.unrealengine.com/tech-blog/unreal-engine-improvements-for-fortnite-battle-royale)、[Iris Introduction](https://dev.epicgames.com/documentation/unreal-engine/introduction-to-iris-in-unreal-engine)、[Iris Components](https://dev.epicgames.com/documentation/en-us/unreal-engine/components-of-iris-in-unreal-engine) | 捕获归编码器所有的状态、共享公共准备，再按连接筛选和编码 |
| Unity Netcode 1.10：[Manage Serialization Costs](https://docs.unity3d.com/Packages/com.unity.netcode@1.10/manual/optimization/manage-serialization-costs.html)、[ForcePreSerialize](https://docs.unity3d.com/Packages/com.unity.netcode@1.10/api/Unity.NetCode.GhostSendSystemData.html#Unity_NetCode_GhostSendSystemData_ForcePreSerialize) | 多连接共享序列化准备；预计算是否划算仍取决于实体与接收者数量 |
| Quake III：[msg.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/qcommon/msg.c) | 单层字段变化位图与数值编码，避免为了差分重复比较整个对象 |
| Godot 4.7.1：[dictionary.cpp](https://github.com/godotengine/godot/blob/4.7.1-stable/core/variant/dictionary.cpp)、[stream_peer.cpp](https://github.com/godotengine/godot/blob/4.7.1-stable/core/io/stream_peer.cpp) | 嵌套 Variant 比较和细粒度写入有实际工作，边界复制须按所有权分析；不能仅凭调用次数断言每次都重分配 |

## 可参考的判断

公共数据只捕获、隔离和准备一次，私有状态按 peer 处理。差分比较按字段完成，避免区块、实体、记录、字段四层完整比较。持续变化字段可以直接编码；低频属性与生命周期仍有差分价值。

接收者 ACK 不同，公共状态相同也不能无条件复用整包差分。内部共享只读记录与对外隔离是不同要求；为历史完整性保留的边界复制不能一并删除。

## 当前采用

- 一批广播持有独立公共 world/time，own 按 peer 捕获；公共差分按共同基线身份和角色表复用。
- 每个连接保留独立序列号、ACK 与基线。公共状态无需逐 peer 完整比较。
- 字段只比较一次；弹丸位置和行程直接写，低频字段差分，创建/移除显式编码。
- 内部共享未变化记录，返回快照与历史隔离，防止调用方修改污染基线。
- 公共事件一次编码和压缩，再提交多个连接。

没有实现预测数值残差的三基线压缩或大型兴趣管理。协议见[联机系统](netplay.md)，单 peer 与整批指标的统计口径见[性能观测](low_overhead_performance.md)。
