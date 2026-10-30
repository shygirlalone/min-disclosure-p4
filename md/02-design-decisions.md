# 关键设计决策记录

> 记录"为什么这么做"以及"什么方案被否决了、为什么"。这些理由在写论文时直接可用。

---

## 协作约定：动手前先报计划（2026-10-17）

> 这不是设计决策，是工作方式的约定。放在最前面，是为了每次动手前都能看到。

- **开始任何一块工作之前，先报计划**：准备做什么、大致怎么做、会动哪些文件。
- **报完再动手**；做到一半发现范围变了，重新报一次，不要悄悄扩大。
- 这条不替代「上机操作须单独确认」——ssh、编译、碰交换机上别人的程序，仍然要另外征得同意。

---

## D1. ★ 全部逻辑放 Egress，不做 Ingress/Egress 混合

### 决策

整个协议实现（指标采集、量化、上报生成、标签解析与校验、动作执行、状态机）**全部收敛到单一 egress control block**。

### 理由

一条 TNA 硬约束：

> **TNA 不支持同一个 extern 实例（Register）被 Ingress 和 Egress 共用。**

而队列深度**只有 egress 能读**（在 egress intrinsic metadata 里）。于是任何"egress 测、ingress 决策"的设计都会立刻撞上寄存器无法共享的问题。绕开它有两条路，但**风险完全不同**：

| 手段 | pipe 归属 | 结论 |
|---|---|---|
| `resubmit`（重走本 pipe 的 ingress parser） | **同一 pipe** | ✅ 安全。你上次 INT 项目的 `reg_S` 两遍读写就是靠它闭环的 |
| `bypass_egress` + `RECIRC_PORT` | **可能落到另一个 MAU pipe** | ❌ 寄存器 per-pipe，状态分裂 |

**你上次踩的坑是第二条** —— `INT/wzc_p4/include/headers.p4:118-126` 的注释是原始实测记录：

```
// Use Resubmit instead of bypass_egress + RECIRC_PORT for recirculation:
//   bypass_egress recirc lands on a different MAU pipe, and Tofino registers are
//   per-pipe, so reg_S would be "read on the traffic pipe, written on the recirc
//   pipe" and the state splits (measured: S froze on the traffic pipe).
//   Resubmit returns to the original ingress buffer, guaranteeing the second pass
//   stays on the same pipe, closing the read/write loop.
```

> **勘误**：本文档第一版把这条写反了，写成「被迫引入 Resubmit 或跨 pipe recirc」并列。
> 正确的是：**Resubmit 是受害者们的解药，recirc 才是病因。**

### Egress 单 block 的能力核对

| 需求 | Egress 能否满足 |
|---|---|
| 读队列深度 | ✅ `deq_qdepth`（待上机验证字段名） |
| 读全局时间戳 | ✅ `egress_intrinsic_metadata_from_parser_t.global_tstamp` —— **你已经在用** |
| 插上报头 | ✅ **你现有的 INT 遥测就是 egress 插 shim header 的**，模式已验证 |
| 解析并消费标签包 | ✅ egress parser 解析 → egress control 写寄存器 → `drop_ctl` 丢弃 |
| 执行动作（设优先级 / ECN / 丢弃） | ✅ 都是 egress 原生动作 |
| 状态机 + 标签缓存寄存器 | ✅ 单 block 单 pipe，无跨 pipe 状态分裂 |

### 收益

一次性消除三类风险：**跨 pipe recirc、CPU port、Ingress/Egress 寄存器共享**。

（注意 **Resubmit 不在这个列表里 —— 它不是风险**。本设计不用它，只是因为没有必要：
所有读-改-写都在同一次 `RegisterAction` 里做完，不需要第二遍。如果上机后发现某个量
确实绕不开，用 Resubmit 补第二遍是**可行且安全**的降级路径。）

### 代价与后续

Week1 不支持需要 ingress 的动作（"换路径"）。这本来就不在 Week1 范围内。

**Week2 若要做 ingress 动作**，届时用下面这个模式（**注意：不是共享寄存器**）：标签包在 ingress 解析后**继续转发**给 egress，egress 再解析一次。**标签包本身充当两个 block 的同步载体**，两个 block 各持有独立寄存器实例，值由同一个包驱动到一致。

---

## D2. 上报包不自己生成，搭在本来就要去服务器的数据包上

### 决策

越过阈值时，直接在**当前这个数据包**上插入 `ctx_report_t` 头（EtherType `0x5555`），随包发往服务器。

### 理由

1. 你的原始需求原话就是"就在数据包上面加这个协议，发给服务器"。
2. **绕开 Tofino CPU port 编号因平台而异的不确定性**。检索到的取值有 `192`（Tofino-1 DUAL_PIPE）、`320`（WEDGE100BF32X）、`0`（纯 Tofino-2）、`2`/`64`（Tofino model）——**不是常量**。走 CPU port 还需要 bfruntime 配合 pktin/pktout 配置，而你现有工作流里没有这条链路。
3. **零新风险**：不需要端口重定向，不需要新配置，复用你已验证的 egress 插头模式。

### 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 发到 CPU port | 编号不确定 + 需要 pktin/pktout 链路 + 调试成本高。**记入 Week2 备选** |
| 专门生成一个上报包 | egress 生成新包能力受限，且需要额外的包头栈构造 |

### 已知局限

上报依赖"有数据包在流动"。**但队列拥塞时必然有流量**，所以实际不构成问题。若某条流长时间无包，`ctx_id` 的跨越检测本来也无从触发。

---

## D3. P4 端不算 CRC

### 决策

`crc16` 字段在 P4 侧填 0，校验完整实现在 Python 侧（`proto/crc16.py` + 服务器 agent）。

### 理由

你的 `mau.resources.log` 显示 **Hash Dist Unit 已 100% 占用**（3 个 `CRCPolynomial` × 2 HashDist = 6/6）。再加 CRC 计算无处可放。

### 为什么这在安全性上站得住

这**恰好最贴合论文的威胁模型**：

- **上行报告**是交换机自己的网络上下文（不是服务器的私有状态），本来就在服务器侧解析 → CRC 在服务器侧校验是自然的。
- **下行标签**的重放/乱序保护由 **epoch + sequence** 提供，**不依赖 CRC**。CRC 只是 placeholder，用于暴露"非法标签拒绝"实验里的一类错误。
- **真实加密**（HMAC/截断 MAC）在 Tofino 上极贵，属于设计章节的讨论，不是 Week1 的实现目标。

---

## D4. ★ 16-bit tick 回绕必须防

### 问题

沿用你现有约定 `tick = global_tstamp[31:16]`，1 tick = 65.536 µs，因此：

```
65536 ticks × 65.536 µs = 4.2949 秒  →  每 4.295 秒回绕一次
```

### 后果（如果按直觉写）

| 直觉写法 | 实际后果 |
|---|---|
| `expiry` 存绝对 deadline，比较 `now <= deadline` | 回绕瞬间所有标签被判定为"未过期"或"已过期"，**标签随机失效** |
| `epoch`（`bit<8>`）无符号比较 `new > cached` | `epoch` 从 255 回绕到 0 时，**旧标签被误判为新标签而接受**（重放攻击面） |

### 强制规则

| 规则 | 正确写法 |
|---|---|
| **R1** | `expiry` 存**相对当前 tick 的偏移**；判过期用 `(int16_t)(now + expiry - now) < 0`。相对偏移 + 有符号差值天然免疫回绕；`expiry == 0xFFFF` 特判为永不过期 |
| **R2** | `epoch` 用 `(int8_t)(new - cached) > 0`；同 epoch 内 `sequence` 用 `(int32_t)(seq - cached) > 0` |

**两条规则必须在上机验证时用边界用例覆盖**（`epoch 255→0` 和 `expiry` 跨 tick 回绕点）。这是最容易被忽略、又最难在上机后调试的一类 bug。

---

## D5. 上报本身也遵守最小披露

### 决策

`ctx_report_t` 只携带 **4 bit 的 `ctx_id`（0–15 等级）**，绝不出现 19-bit 原始队列深度。

唯一例外是 `diag_value`（16 bit），且被 `flags.DIAG_PRESENT` **显式门控**。

> ⚠️ **v0.4（D28，2026-10-23）起 `diag_value` / `DIAG_PRESENT` 已从线格式删除**，
> 本条只剩历史意义：D28 的压缩理由之一正是「这些常量/诊断字段本就不承载信息，
> 却每个都要占一次 egress 写头和 stage」。等级三指标的最小披露原则不变。

### 理由

如果上报协议把原始队列深度发给服务器，那就只是"把字段换了个方向暴露"，论文的核心主张会自相矛盾。

把 `diag_value` 门控起来，正好对应贡献 1 里"是否对该流启动短时诊断"这个动作 —— **只有诊断动作被授权时，才允许携带接近原始的信息**。这使上报协议和最小披露理论自洽。

---

## D6. `ctx_tolerance` —— 用极小披露代价换掉状态机震荡

### 决策

`action_label_t` 带 `context_id`（4 bit）+ `ctx_tolerance`（4 bit），标签只在 `abs(cur_ctx - context_id) <= tol` 时有效。

### 理由

若做**精确绑定**，当 `ctx_id` 在阈值边界附近抖动时：标签失效 → 发报告 → 新标签 → 又抖动 → 再失效…… 状态机在 `ARMED`/`REPORTED` 间震荡，**控制流量爆炸**。

容差把"精确绑定"放宽为"邻域绑定"。代价只是多 4 bit 的声明（且声明的是"容差"而非任何私有状态），收益是状态机稳定。

**这个 trade-off 本身可以写进论文的 Pareto frontier 讨论**：披露粒度 vs 控制稳定性。

---

## D7. Week1 用 CRC16 占位而非真实加密

### 决策

Week1 不做 HMAC/加密，`crc16` 占位，字段格式与最终版完全一致。

### 理由

1. Tofino 上做 HMAC/SHA 极贵，会吃掉大量 stage 和 SRAM（Hash Dist Unit 已 100%）。
2. `epoch + sequence` 已提供重放/乱序保护，足以支撑"非法/过期/乱序标签拒绝"实验。
3. 字段格式先固定，将来替换校验位**不需要改协议**（CRC16 和截断 HMAC-16 都是 16 bit）。

### 后续

加密部分作为**设计章节**讨论，说明：如何在保持动作级最小披露的前提下保护决策信息本身（你的原始笔记里写的"可以加个【加密】来保护决策信息"）。

---

## D8. Week1 不支持通配流标签（`flow_id == 0xFFFF`）

### 决策

`flow_id = 0xFFFF` 的标签直接拒收（`REJECT_FLOW_SCOPE`）。

### 理由

标签寄存器的槽位是 `flow_id & 0x7` 的**直接映射**（8 个槽）。一次寄存器写
只能落到一个槽位，**无法向 8 个槽扇出**。要支持通配只有两条路：

1. 服务器下发 8 次（协议层不动，但控制流量 ×8）；
2. 改成二级索引（标签寄存器 + 一张流→标签的间接表）。

两条都是 Week2 的事。Week1 的服务器本来就只回应「某个流的报告」，
天然就是单流标签，不受影响。

---

## D9. ★ 用「arm 世代号」实现「把寄存器清空」

### 需求原文

> 「……就把寄存器清空，直到收到服务器发来的新标签。」

### 问题

字面实现要写 8 个标签槽位。但数据面的 4 次寄存器访问已经排满
（`reg_cfg` / `reg_label` / `reg_ctx_last` / `reg_sm`），第 5 次就是超预算。

### 决策

不真去写，改用**世代号**：

- `reg_sm` 里有 4 bit 的 `arm_gen`，**每次离开 ARMED 就 +1**（唯一出口，见
  `sm_action` 末尾那个 `if`，放在那里是为了保证以后加分支也不会漏）。
- 每条标签被缓存时，把自己当时的 `arm_gen` 写进 `reg_label` 的 bit57..60。
- 执行功能前要求两个世代号**相等**。

于是状态一离开 ARMED，**所有**已缓存标签的世代号立刻全部对不上 ——
效果与「清空」完全等价，且**一次额外访问都不花**。

### 与字面实现的差别（论文里要讲清楚）

| | 字面清空 | 世代号 |
|---|---|---|
| 寄存器内容 | 真的变成 0 | 内容还在，只是「失效」 |
| 可观测性 | dump 出来是 0 | dump 出来还能看到旧值 |
| 占用 | 8 次写 = 超预算 | 0（复用已有的 4 bit） |
| 语义 | 完全等价 | **完全等价**（判定条件就是「世代号相等」） |

「内容还在」这一点在安全上不构成差别：执行路径唯一的闸门就是世代号相等，
旧值永远走不到执行分支。反而是调试时还能看到旧值，更好排查。

---

## D10. ★ 阈值是「等级阈值」，不是原始值的阈值

### 问题

需求原文说「阈值是我们手动自己设定」。但如果直接拿原始队列深度（19 bit）
去比阈值，会有两个问题：

1. 阈值随硬件单位变（`deq_qdepth` 到底是 cell 还是字节，上机才知道，见 V8）
2. 原始值本身就不该离开交换机 —— 它是要被量化的东西

### 决策

两级分离：

| 层 | 是什么 | 谁定 | 在哪 |
|---|---|---|---|
| **量化等级** `ctx_id` | 原始值 → 0..15 档。**这是唯一离开交换机的信息** | range table（编译期桶边界） | P4 `quantize_queue` 表 |
| **阈值** `th_*` | 哪一档算「不符合要求」 | **我们手设，控制面随时可改** | `reg_cfg` |

判据：

```
QUEUE  : ctx >= th_queue
LOAD   : ctx >= th_load
PATH   : ctx <  th_path      ← 越高越好，方向反过来
```

**触发条件是「不符合要求」这个布尔量的翻转**，不是「等级变了」。
这正是需求原文的语义，而且顺带获得两个好处：

- **冷启动不误报**：等级变化会在第一个包上触发（寄存器全 0），布尔翻转不会。
- **抖动免疫**：在阈值附近来回抖 = 布尔量没翻 = 不发报告。

### 已知代价

阈值的分辨率被桶边界限制 —— 只能选「第 N 档」，不能任意设一个原始值。
要更细就把桶切细（改 `const entries`），协议层零改动。

---

## D11. ★ `last_metric` 必须**每流**，不能放全局 `reg_sm`

### 决策

`last_metric`（本流最近一次发生跨越的指标）存放在 `reg_ctx_last`
（每流一格）而不是 `reg_sm`（全局一格）。

### 理由（这是一次真 bug 的复盘）

标签要做「上下文绑定」判定，需要知道「服务器是看着哪个指标的哪一档发的
这张标签」。第一版把它放在全局 `reg_sm` 里，因为 `reg_sm` 在标签路径上
反正只要访问一次。结果：

> **B 流的标签会拿 A 流上报的上下文去校验。**

A 流上报过，`last_metric` 就非 0，于是 B 流的标签被当成「有上下文可比」，
再拿 A 流的 ctx 去比 —— 跨流污染。单流测试全绿，第二个流一进来才暴露。

### 为什么改放 `reg_ctx_last` 反而更省

`reg_ctx_last` 在数据面本来就要被 rmw 一次。把 `last_metric` 和三个 ctx
打进同一格（加宽到 32 bit），**数据面访问次数不变**；而标签路径因此
只需**一次只读**就能同时拿到「三个 live ctx」和「last_metric」——
于是 ctx 绑定判定重新变回**纯运算**，可以排在所有写操作之前。
这是最不容易出错的结构。

### 顺带定下的取舍

只保留「**当前** ctx 落在标签容差窗内」这一条判据，**不**要求「上报时的
ctx 也在窗内」。后者的值记不下来（上报与否由 `reg_sm` 的状态与冷却决定，
而 `reg_sm` 排在 `reg_ctx_last` **之后**访问，步骤 4 无从得知本包会不会真
上报）。若按「最近一次跨越」去记，等标签期间上下文一抖就会把记录冲掉，
反而误拒合法标签。

只留一条，判错的方向也是安全的：**拒收 → 退回纯转发**，正是文档里定义的
安全默认。

---

## D12. ★ 寄存器 entry 宽度必须服从 sALU 的 8/16/32 位限制

### 问题

初版把 `reg_sm` / `reg_cfg` / `reg_label` 都设计成 `bit<64>` 单字。上机前
对照 TNA 的 sALU 规格才发现这**编译不过**：

> `Wide operations not supported in stateful alu`

TNA 的 sALU 只有 8 / 16 / 32 位三种运算宽度。寄存器 entry 只允许：

- `bit<8>` / `bit<16>` / `bit<32>` 标量，或
- **恰好两个同类型字段组成的 struct**（本设计叫 `pair32_t`，两个 `bit<32>`）

### 决策

> **每个寄存器要么是 32 位单字，要么是 `pair32_t`；
> 且任何字段都不得横跨 bit31 / bit32 分界。**

第二条同样重要：跨字的切片 sALU 做不了。它比第一条更阴险 —— **编译能过，
但取出来的字段值永远不对**，只有上机比对才能发现。

### 带来的连锁改动

| 寄存器 | 改前 | 改后 | 为什么 |
|---|---|---|---|
| `reg_sm` | `bit<64>` | `pair32_t` | lo = 状态/冷却/待发/世代号，hi = 报告序号。天然落在分界两侧 |
| `reg_cfg` | `bit<64>` | `bit<32>` | 阈值降到 5 位后放得下（D14） |
| `reg_ctx_last` | `bit<8>` × 16 | `bit<32>` × 8 | 三个 ctx 打包 + last_metric + init 挤进一格（D11） |
| `reg_label` | `bit<64>` | `bit<32>` | 去掉 queue_id / action_id（D14） |
| `reg_label_seq` | `bit<64>` | `pair32_t` | lo = sequence，hi = epoch |

### 怎么守住的

（历史）当时本地没有 bf-p4c，曾靠离线检查（`_parked/test_p4_consistency.py`
与 `tests/`）逐字段守住。**这些文件已于 2026-10-17 随参考模型一并删除**；
现在由 `bf-p4c` 编译（宽 entry / 宽 operand 直接报错）和上机 `dump_registers` 把关。

---

## D13. ★ `report_seq` 在寄存器里只存 16 位

### 问题

`reg_sm` 的 `sm_ra` 要一次性把 **event + arm_gen + state_after + report_seq**
全部从 `out_v` 带出来 —— 因为 `out_v` 是 `RegisterAction` 唯一的出口，而
`peek()` 回读在硬件上是同包第二次访问，违约。

若 `report_seq` 保留 32 位，`out_v` 会被顶到 **42 位**，超出 sALU / PHV
的可靠宽度。

### 决策

> 线上字段 `report_seq` **仍是 32 位**；但寄存器里只存 **16 位**。
> `out_v` 因此降到 26 位有效宽度。

代价：每 65536 次上报回绕一次。按冷却 100 ms 算，最快也要 **1.8 小时**
才绕一圈 —— 服务器用**有符号差值**判新旧即可，与 `epoch`（256 回绕）的处理
完全相同（D4 规则 R2）。

### 为什么不是别的做法

- 再拆一个寄存器存 seq：多一次 SALU 访问，预算不允许（§3.3 的 4 次已排满）
- 干脆不要 seq：上报就无法去重/排序，服务器的策略层用不了

---

## D14. ★ 阈值降到 5 位；`reg_label` 去掉 `queue_id` / `action_id`

> ⚠️ **2026-10-24 注：本节的 5 位 `reg_cfg` 布局已被 D28 取代**
> （改成 4×8 位字节对齐：`[7:0]`/`[15:8]`/`[23:16]`/`[31:24]`）。
> 以下内容保留为决策历史；**当前布局以 `md/01` §3 与 `p4/min_disc.p4` 为准**。

两个改动同源：**都是为了把寄存器压进 32 位**（D12）。

### 阈值 5 位（0..31）

阈值是**等级阈值**（D10），比较的是量化后的 `ctx_id ∈ [0,15]`。所以：

| 取值 | 语义 |
|---|---|
| `0..15` | 有效阈值 |
| `16..31` | 等价于「该指标永不判违规」 |
| `31`（`CFG_TH_DISABLED`） | 规范写法 —— `ctx >= 31` 对 `ctx ∈ [0,15]` 恒假 |

三个阈值各 5 位 = 15 位，加上 `path_avail`（4 位），`reg_cfg` 一共只用了
19 位，从 64 位降到 32 位绰绰有余。

> **实现注意**：读取时必须用 `CFG_TH_MASK`（5 位）而不是 `0xFFFF`。用宽掩码
> 会把相邻字段一起圈进来，阈值变成巨大数、`ctx >= th` 恒假，该指标
> **永远不报** —— 数据面上完全静默，只是「什么都没发生」。
> 早期的离线参考模型里已经踩过一次（该模型已于 2026-10-17 删除）。

### `reg_label` 去掉 `queue_id` / `action_id`

- 线上协议**不变**：`action_label_t` 的字段表（§2）照旧带这两个字段
- 但寄存器**不缓存它们**。理由：它们只服务于 `QUEUE_REDIRECT` /
  `RATE_LIMIT`，而这两个功能**本就不在 Week1 白名单内**
  （`WEEK1_FUNCTIONS = {NOOP, PRIORITY_SET, DROP, ECN_MARK}`）
- 缓存它们会把 `reg_label` 顶过 32 位，而这些位在 Week1 里一次也用不到

**Week1 的执行路径只需要四样东西**：`function_id` / `priority` /
`deadline` / (`valid` + arm 世代号) —— 正好 29 位。

> 顺带定下一条**拒收规则**：`priority` 在寄存器里只有 4 位，而线上是 8 位。
> 超过 `PRIORITY_MAX`(15) 的标签**直接拒收**，不静默截断 ——
> 截断会把 0x12 变成 0x2，动作强度凭空掉一档，而这种错在硬件上完全看不出来。
> 拒收则退回纯转发，是文档里定义的安全默认。

---

## D15. ★ 标签路径上「序列号校验」必须排在「转 ARMED」之前

### 问题

标签路径第 4 组有三处寄存器写：

```
⑧ reg_label_seq[slot]  epoch / sequence 单调性（防重放）
⑨ reg_sm               转 ARMED，取出 arm 世代号
⑩ reg_label[slot]      写入标签，盖上世代号
```

**⑧ 与 ⑨ 谁在前？** 直觉上「先改状态、再记序号」更顺（序号是状态机的一部分），
初版就是这么写的。但它有后果：

`sm` 的写操作一旦执行就**必然**把状态改成 `ARMED`。于是当 ⑨ 排在 ⑧ 前面时，
一条**重放 / epoch 回退**的标签会：

1. 先把交换机推进 `ARMED`
2. 再被序列号校验拒绝

结果：**交换机凭空进入「已武装」态，而根本没有任何合法标签。**

### 为什么这个 bug 特别难发现

它**不留任何痕迹**：

- `accepted == False` —— 调用方看到的返回值完全正常
- `reg_label` 没被改写 —— 缓存里确实是空的
- 只有 `reg_sm` 的 `state` 字段悄悄从 `1`(REPORTED) 或 `3`(STALE) 变成了 `2`(ARMED)

而且 `ARMED` 意味着「执行动作的闸门是开的」。虽然 `reg_label.valid` 是 0、
`label_gen` 也对不上，动作实际不会执行（还有第三重保险），但**状态机已经
和「校验不过就什么都不做」的设计原则矛盾了** —— 这一条本是论文安全性论证的
基础。

### 决策

> **⑧ 排在 ⑨ 之前：序列号校验是唯一可能让整条标签被拒的写操作，
> 它必须先跑。**

这样「校验不过 → 一次寄存器都不写」才真正成立。⑧ 之后的失败只会留下
`reg_label_seq` 被推进 —— 那是**有意**的，否则同一个标签就能被反复重放。

对应 P4：`seq_ra.execute()` 写在 `sm_label_ra.execute()` 之前。

### 回归测试的一个坑（值得单独记）

第一版回归测试是**空转**的，写法是「ARMED → ctx 越界 → REPORTED → 重放」。
问题在于：ctx 越界之后，`live_ctx` 已经不等于标签里的 `context_id` 了，
于是重放时**先在 ⑦ (ctx 绑定) 就被拦下**，根本走不到 ⑧/⑨ —— 无论两者
谁先谁后，测试都通过。

正确写法是让状态走 `ARMED → (deadline 到期) → STALE`：这条路上 **ctx 一直
不变**，重放时 ⑦ 会通过，才真正压到序列号校验那一行。
见 `test_replay_rejected_label_does_not_arm`。

> **教训**：写「顺序不能颠倒」这类测试时，必须**断言拒绝原因**
> （`assert "重放" in v.reason`）。只断言 `not accepted`，测试很容易在
> 更早的分支上就满足了，看起来是绿的，实际什么都没测。

---

## D16. `FUNC_PRIORITY_SET` 在 egress 里做不到 —— 队列只能由 ingress 选

### 问题

`md/01` 的动作表把 `PRIORITY_SET` 标成「执行位置 = **egress**」，
`min_disc.p4` 也就照着写：

```p4
eg_intr_oprt_md.qid = (bit<5>)meta.label_priority;
```

**首次真编译直接报错**（2026-10-07）：

```
error: Field qid is not a member of structure
       struct egress_intrinsic_metadata_for_output_port_t
```

### 证据

`tofino1_base.p4` 里 `QueueId_t` 总共只出现两次：

| 位置 | 所在结构 | 语义 |
|---|---|---|
| L139 | `ingress_intrinsic_metadata_for_tm_t.qid` | **ingress 写** → TM 据此入队。**唯一的选择点** |
| L268 | `egress_intrinsic_metadata_t.egress_qid` | **只读**：「本包从哪个队列被服务」 |

而 `egress_intrinsic_metadata_for_output_port_t` 里**根本没有 qid** ——
整个结构只有两个 IEEE 1588 位（`capture_tstamp_on_tx` / `update_delay_on_tx`）。

**队列在入队那一刻（ingress→TM）就定了，egress 无从更改。**

### 决策

> **队列选择是 ingress 动作，与 D1「全部逻辑放 Egress」直接冲突
> → `PRIORITY_SET` 按 Week1 范围记入 Week2**（与 `QUEUE_REDIRECT` /
> `RATE_LIMIT` 同一类）。

P4 里保留一个**空分支**，只为标记「本包确实执行了 PRIORITY_SET」——
该事实已由 `meta.exec_func` 承载；不改任何包头字节。

### 为什么当时模型侧不用改（历史记录）

`PacketOutcome` 本来就只记 `execute_function` / `execute_priority`，
**从不模拟队列变化**。也就是说模型与 P4 在这里没有分歧 —— 变的只是
「这个动作有没有可观测效果」。（该模型已于 2026-10-17 删除。）

### 连带

- `md/01-protocol-spec.md` 动作表的「执行位置」列：`PRIORITY_SET` 由
  `egress` 改为 `Week2 / ingress`（**只改注释列，字段表与位宽零改动**，
  所以不触发「改协议的固定顺序」那条链）
- Week1 剩两个动作 `DROP` / `ECN_MARK` 在 egress 都成立
  （`drop_ctl` / 改 `diffserv`）

---

## D17. ★★ RegisterAction 里只能做 2 次比较 —— 「把逻辑全写进 RegisterAction」的架构不成立

### 问题

初版把**完整逻辑**写进 `RegisterAction` 的 `apply()`：
`ctx_ra`（三指标阈值翻转判定）、`sm_ra`（状态机）、`seq_ra`（防重放单调性）。

### 首次真编译的实测结果（2026-10-07）

```
error: RegisterAction seq_ra.apply needs 7 comparisons; only 2 possible
error: RegisterAction can't support local var MyEgress.crossed
error: RegisterAction can't support local var MyEgress.mid
error: RegisterAction can't support local var MyEgress.cur
error: RegisterAction can't support local var MyEgress.cprev
error: Can't assign to crossed in RegisterAction
Compiler Bug: ...: recursion failure      ← 编译器自己崩了，错误列表不完整
```

sALU 上三条硬限：

1. **每个 RegisterAction 至多 2 次比较**
2. **不许声明局部变量**
3. **不许给局部变量赋值**

| Action | 需要的比较 | 局部变量 | 结果 |
|---|---|---|---|
| `cfg_ra` / `lbl_ra` / `live_ra`（纯读，`out_v = v`） | 0 | 0 | ✅ |
| `ctx_ra` 三指标翻转判定 | ~10 | ~15 | ❌ |
| `sm_ra` 状态机 | ~15 | 有 | ❌ |
| `seq_ra` 防重放 | **7** | 有 | ❌ |

**结论：读侧没问题，决策侧整个不成立。**

### 参照程序怎么绕开的（`wzc_p4/datasettest.p4`）

它的 RegisterAction 清一色只有一次算术，**一次比较都没有**：

```p4
void apply(inout bit<16> v, out bit<16> out_v) {
    out_v = meta.curr_ts - v;    // 只做算术
}
```

三个配套手法：

1. **算术留在 sALU**（加减不受限），**比较推给 range table** ——
   作者注释原话「区间判断表（range table 替代寄存器减法）」：
   ```p4
   table cycle_table {
       key = { meta.curr_ts_sub_S : range; }
       const entries = { (T .. 0xFFFF) : do_update(); }
   }
   ```
   TCAM 并行匹配，**没有比较数限制**。
2. **谓词经 PHV 送进下一个 RegisterAction** ——
   `do_update()` 只写 `meta.update = 1`，后面 `if (meta.update == 1)` 再决定。
3. **同一寄存器既要读又要写 → Resubmit 跑第二遍**，注释原话：
   ```
   // (reg_S 每包只能读写一次, 故第一遍读、第二遍写 S+=T)
   ```

### 待定：两条改法

| | **A. 多表流水线** | **B. 照抄参照程序** |
|---|---|---|
| 做法 | 状态拆成多个单一用途寄存器；每级 RegisterAction 只做本寄存器的极简 RMW；谓词由前一级 range table 算好、经 PHV 送进来 | read 一遍 → range table 判 → Resubmit 写第二遍 |
| 代价 | 寄存器变多、SALU 访问次数上升，要重排 D12 预算 | 每包多一次 resubmit，吞吐需实测 |
| 先例 | 无 | `datasettest.p4` 已验证 |

**两条都会动 D1 与 `md/01` 的访问预算表，须先定案再动手。**

### 为什么 83 项离线测试一个都没抓到

因为测试仿的是**行为**（给定 ctx 与阈值，该不该上报），
而这是一条**资源模型**约束（sALU 能做几次比较）。
行为对、资源超 —— 只有真编译器能发现。

这正好划出了 V0 那条「本地唯一的编译替代品」的边界：
**正则 + 行为测试能保证「写的东西是一致的」，保证不了「写的东西是编得过的」。**

---

## D18. ★★ D17 的解法：A 路（多表流水线）—— 「判断出门，差事员只搬运」

> **本文取代 D17「待定」一节，并把 D9 里「数据面 4 次访问已排满」一条作废（见下文代价）。**

### 一句话原则

D17 暴露的限制是：**差事员（RegisterAction）那支笔最多比两次大小、还不许起名字（局部变量）。**

解法不是让他变得聪明，而是**不让他动脑**：

> **进小黑板之前，所有判断都已经在门外做完了。差事员只干两件事：
> 把门外的结论搬进去、把里面的旧值搬出来。**

「门外」有三个地方：

| 判断类型 | 搬到哪儿 | 为什么可以 |
|---|---|---|
| **比大小**（等级 ≥ 阈值） | **`apply()` 里** | ★ 那条「最多比两次」的 sALU 限制**只管 `RegisterAction` 内部**，`apply()` 不受限（D17 报错行的原文就写着 `RegisterAction ... needs 7 comparisons`） |
| **区间判断**（差值落在哪一段） | **range table** | TCAM 并行匹配，没有比较数上限。参照程序 `cycle_table` 就是这个用法 |
| **一般的位运算 / 加减** | **留在 sALU** | D17 实测：`out_v = meta.curr_ts - v` 这种纯算术**一次都没报错**。受限的只有「比较」和「局部变量」 |

### 逐个动作的改法

#### ① `ctx_ra` —— 判决挪到 `apply()`，寄存器只存「上次的判决」

**问题**：原来寄存器里存的是**上次的原始等级**，差事员每次都要「旧等级比阈值 + 新等级比阈值」
= 6 次比较，外加 `first_seen` / 选指标 / 选 cur/cprev ≈ 10 次。

**改法**：

- `apply()` 里算本次判决（3 次比较，**无限制**）：
  ```
  verdict_now = [Q: ctx_queue >= th_queue] | [L: ctx_load >= th_load]<<1 | [P: ctx_path < th_path]<<2
  ```
- 寄存器 `reg_ctx_last` 改存**上次的判决**（3 bit，占用原来的空闲位 bit12..14）。
- `ctx_ra` 本体只剩**位搬运**：`out_v` 把「上次判决 + 上次三个等级 + init」原样端出来，
  `v` 用 `apply()` 算好的值拼回去。**0 次比较、0 次位运算。**

**启动守卫也变成位运算**（原本是 `if (first_seen == 0) {...}`）：

```p4
crossed3 = (verdict_now ^ prev_verdicts) & ((bit<3>)0 - (bit<3>)init);
```

`0 - init` 是个广播技巧：`init=1` 得全 1、`init=0` 得全 0，正好当开关。
**等于「第一个包不判翻转」，但一次比较都没用。**

#### ② `last_metric` 必须**另起一个寄存器**（`reg_report_ctx`）

这是 A 路上唯一一处「拆寄存器」的代价，理由是**顺序**：

`last_metric` 的值取决于「本包有没有发生跨越」，而跨越判定只能在 `apply()` 里做；
可等 `apply()` 算完，`reg_ctx_last` 的那次 rmw **早就过去了** ——
**同一个寄存器不能在同包访问第二次**（约束①）。所以它只能住在另一个寄存器里。

```p4
RegisterAction<bit<32>, bit<16>, bit<4>>(reg_report_ctx) rctx_ra = {
    void apply(inout bit<32> v, out bit<4> out_v) {
        out_v = (meta.mid == 4w0) ? (bit<4>)v : meta.mid;
        v     = (meta.mid == 4w0) ? v          : (bit<32>)meta.mid;   // ★ 唯一一次比较
    }
};
```

**1 次比较**，在预算内。

#### ③ `seq_ra` —— 把一块黑板劈成两块，让比较能出门

`reg_label_seq`（`pair32_t`：lo=sequence，hi=epoch）**劈成两个 32 位单字**：

| 寄存器 | 存什么 | 标签面怎么用 |
|---|---|---|
| `reg_epoch` | 上次的 epoch | **只读**（看一眼就走，0 次比较） |
| `reg_seq` | 上次的 sequence | 读-改-写，但**体内 0 次比较** |

劈开之后就有了顺序：**先读 reg_epoch（旧 epoch 进 PHV → 出门了）→ 差值 `ed` 交给 range table 判
→ 再让差事员写 reg_seq**。读的是 A 块黑板、写的是 B 块，绕开了「同包读两次」。

`reg_seq` 体内只剩「算出 `sd`、看它的符号、按位决定要不要落盘」，全是算术 + 位运算。

**顺带发现一条简化**：若缓存是空槽 `(0,0)`，单调性判据自动退化成
「新标签不是 `(0,0)` 哨兵就接受」—— 与原来的空槽分支**完全等价**，
所以原来的 `if (v.lo == 0 && v.hi == 0)` 特判可以整段删掉。

#### ④ `sm_ra` —— 状态改「一位一态」，于是整个状态机变成与或非

**问题**：原来是 `if (state == STATE_IDLE) {...} else if (state == STATE_ARMED) ...`
四层分支，光「我现在是哪个状态」就 3~4 次比较。

**改法**：寄存器里状态存**一位一态**（one-hot）：

| 状态 | 寄存器编码 | 对外 2 位码（不变） |
|---|---|---|
| IDLE | `0001` | 0 |
| REPORTED | `0010` | 1 |
| ARMED | `0100` | 2 |
| STALE | `1000` | 3 |

于是「是不是 ARMED」**就是取 `v.lo[2]` 那一位**，不是比较。整个迁移全部改写成位运算：

```p4
passive_report = passive & cooldown_ok & (crossed | pending);
armed_report   = armed   & (~expired) & crossed & cooldown_ok;
report_now     = passive_report | armed_report | retry_report;   // 全 OR
new_armed      = armed & (~expired) & (~crossed);
new_arm_gen    = arm_gen + (armed & (~new_armed));               // 离开 ARMED → +1，纯加法
new_seq        = seq + report_now;                               // 要报就 +1，纯加法
```

**对外仍用 0..3 那套状态码** —— one-hot 只是寄存器内部的存法，
`apply()` 里换算一下即可（`apply()` 无限制）。所以 `md/01` 的状态机、Python 的 `STATE_*`
**一概不动**。

**顺带发现**：原代码里 `STATE_IDLE` 与 `STATE_STALE` 两个分支的代码**逐行相同**
（`min_disc.p4:286` 与 `:327`），本来就该合并。改写成位运算后它们天然合并（都是 `passive`）。

**只剩 2 次比较**：`cooldown_ok` 与 `retry_due`。它们比的是「现在」和
**寄存器里存的冷却起点**，而寄存器里的值门外拿不到 —— **这两次跑不掉**，
正好卡在上限。

### 代价

| 项 | 改前 | 改后 |
|---|---|---|
| 寄存器数 | 5 | **7**（+`reg_report_ctx`、`reg_epoch`、`reg_seq`；−`reg_label_seq`） |
| 数据面访问 | 4 | **5**（+`reg_report_ctx`） |
| 标签面访问 | 4 | **6**（+`reg_report_ctx`、+`reg_epoch`） |
| 协议线格式 | — | **一个字节都不动**（改的全是交换机内部存法） |
| `md/01` 状态机 / 线格式 | — | **不动** |
| 需同步 | — | （历史）`proto/constants.py` 与当时的离线断言；相关离线文件已于 2026-10-17 删除 |

> ⚠️ **D9 的「数据面 4 次访问已排满，第 5 次就是超预算」一条就此作废。**
> 当时那个「预算」是为了守住约束①（同一寄存器每包一次），不是硬件上限。
> 现在多出来的访问打在**不同的寄存器**上，约束①依然成立。
> Tofino 有 12 级 stage，我们的 sALU 用量远未触顶 —— 用一次额外访问换
> 「每个 RegisterAction 都能一眼看懂」，这笔账划算。

### 仍未定的一点（诚实记录）

`sm_ra` 的位运算改写是**平铺长表达式**（sALU 不许声明局部变量，
所以中间量只能内联）。内联后的操作数在 50 上下 —— 我们**没有关于 sALU
「操作数上限」的任何实测证据**（D17 的三条报错只涉及比较数和局部变量，没有一条是
「操作太多」）。

**所以这一条必须靠编译验证，不能靠推理。** 若真编译不过，退路有二：
(a) 把状态机的分支拆成 range table（需要状态进 PHV，那就要 Resubmit 跑第二遍 —— 即 D17 的 B 路）；
(b) 按 D17 参照程序的做法整程序改 Resubmit。
**两条都不必推翻本节的其余部分**（①②③ 已经各自独立成立）。

---

## D19. ★★★ sALU 的真实规则 —— 2026-10-11 实测汇总（D18 的「A 路」**部分被推翻**）

D18 写下后做了 12 轮真编译（`bf-p4c` 9.10，交换机上）。结论分两半：

### 好消息：D18 的方向是对的

> **判断出门、差事员只搬运** —— 方向正确，而且**做得还不够彻底**。

按 D18 改完之后，编译器第一次给出 **`Number of ERRORs: 0`**。
`reg_ctx_last` 的「判决挪进 `apply()`」、`sm_ra` 的「一位一态」全部**通过**。

### 坏消息：D18 漏掉了 sALU 的**其余四条**限制

D18 只处理了「比较数」和「局部变量」。真编译暴露的完整规则表：

| # | 规则 | 报错原文 |
|---|---|---|
| 1 | 每个 `RegisterAction` **至多 2 次比较** | `needs N comparisons; only 2 possible` |
| 2 | **一条语句最多一个二元运算符**，除非最外层是 `\|` | `You can only have more than one binary operator in a statement if the outer one is \|` |
| 3 | **寄存器的写必须写满整个 32 位**，不许切片赋值 | `can only output entire 32-bit ALU output from <action>` |
| 4 | **运算量**本身有上限（多个「移位 + 或」拼一个字就超） | `expression too complex for RegisterAction` |
| 5 | **局部变量基本不可用**（哪怕只是 `bit<1> x = v[2:2];`） | `RegisterAction can't support local var ...` / `Can't assign to ... in RegisterAction` |
| 6 | 32 位变量之间 **不能用 `~`、不能用 `&`**；与常量相与/相或、相减、`+` 都可以 | `expression too complex ...` |
| 7 | **32 位的条件赋值 / 三元选择会让编译器内部崩溃** | `Compiler Bug: ... The etype should be the VALUE instead of IF/OUTPUT` + `Internal compiler error` |

### ★★ 最要命的一条：读写**不能分家**

D18 之后的形态是「一个读动作 + 一个 `reg.write()`」。实测（最小复现，见 `_scratch/`）：

| 最小复现 | 形态 | 结果 |
|---|---|---|
| `t_rdonly.p4` | 只读动作 | ✅ 编译通过 |
| `t_rmw.p4` | **单个** RMW 动作（`out_v = v; v = v + 32w1;`） | ✅ 编译通过 |
| `t_mix.p4` | 读动作 + `reg.write()` | ❌ `Table placement cannot make any more progress` |
| `t_wact.p4` | 读动作 + 另一个写动作 | ❌ 同上 |
| `t_stage.p4` | 读、写分到**两张表**里（想强制排到不同 MAU stage） | ❌ 同上 |

> **结论：一个 Register 在一个包里只能被一个 `RegisterAction` 碰一次。
> 「读出来 → 在 `apply()` 里算 → 写回去」这条路在 Tofino 上走不通** ——
> 不是语法问题，是**表放置**问题（读和写互相依赖，bf-p4c 排不进同一级 MAU）。
> 我们文档里约束①的原话「一个 Register 每包只能一次 RegisterAction」**依然成立，没有被放宽**。

### 于是 D18 的 ④（`sm_ra` 改一位一态）**不成立**

「一位一态 + 全位运算」要求把中间量写下来（局部变量）→ 规则 5 挡死；
退一步全内联 → 规则 4 挡死；再退一步用条件赋值 → 规则 7 崩溃。

**`sm_ra` 必须重新设计。** 这是当前唯一的阻塞点，它不是笔误而是架构问题。

### 仍然成立的部分（D18 的 ①②③ 各自独立）

| 项 | 状态 |
|---|---|
| 判决（比大小）挪进 `apply()` | ✅ 成立，且**必须**这么做 |
| `reg_report_ctx` 单独立一个寄存器 | ✅ 成立，而且它的 RMW 恰好是规则的合法形态：`out_v = v; if (meta.mid != 4w0) { v = meta.mid; }`（1 次比较，条件与取值**都只依赖 PHV**） |
| `reg_epoch` / `reg_seq` 劈成两块 | ✅ 成立（读 A 块、写 B 块，绕开约束①） |
| `sm_ra` 一位一态 | ❌ **被推翻**，见上 |
| 对外 2 位状态码不变 | ✅ 目标不变 |

### 附：`_scratch/` 里的最小复现

上面那张表里的 6 个 `.p4` 都在 `_scratch/`，是**可复现的实验记录**。
它们不参与构建，纯粹是「这条规则我们量过」的凭据。改动 P4 结构前先跑一遍这些，
比重新踩一遍坑便宜得多。

---

## D20. ★★★ `Resubmit` 是 **ingress 流水线专有**的 —— B 方案在 egress-only 设计里不可用

> 日期：2026-10-11。实测。这条**否掉了「B 路：退回 Resubmit」这个候选方案**。

### 背景

D17 留了两条改法，D18 走了 A 路（多表流水线），走到 D19 发现 `reg_sm` 卡死。
于是「B 路：让同寄存器的读和写分到 Resubmit 的两遍里」重新变得有吸引力 ——
如果它成立，协议语义**一个字都不用改**。

**前提是 egress pipeline 里能触发 resubmit。这个前提不成立。**

### 实测（同源程序，只挪一行）

在交换机上用三个除 resubmit 位置外**完全相同**的最小程序编译：

| 程序 | `Resubmit()` 在哪 | 结果 |
|---|---|---|
| `rs4_base` | 哪都没有 | `exit=0` ✅ |
| `rs4_ing` | **ingress** deparser | `exit=0` ✅ |
| `rs4_egr` | **egress** deparser | `exit=1` ❌ |

```
/tmp/rs_exp/out_rs4_egr/pipe/rs4_egr.bfa:183: error: Unknown deparser tag resubmit
failed command assembler
```

**汇编器根本不认识 egress deparser 里的 resubmit tag。** 换成带 64 位 digest 头参数的
写法（`resubmit.emit(hdr.rsd)`）结果一样；连**裸** `resubmit.emit()` 一起报同一个错。

### 三条独立佐证

1. `$SDE_INSTALL/share/p4c/p4include/tofino1_base.p4:785` 原文：
   > "Tofino supports packet resubmission **at the end of ingress pipeline**."
2. `resubmit_type` 这个硬件控制字段**只挂在** `ingress_intrinsic_metadata_for_deparser_t`
   上（同文件 :210）。`egress_intrinsic_metadata_for_deparser_t`（:296）里只有
   `drop_ctl` / `mirror_type` / `coalesce_flush` / `coalesce_length`，**没有 resubmit_type**。
3. 参照程序 `datasettest` 的 `include/parsers.p4:155` 把 `Resubmit()` 放在
   **ingress deparser**，靠 `ig_dprsr_md.resubmit_type` 触发。

### ⚠️ 一个曾经把我们骗过去的假阳性（记下来，别再踩）

中途做过一次"把参照程序的 `Resubmit` 挪到 egress deparser"的编译，**`exit=0`、0 error**，
看起来像"egress 能用"。真相是：

> `ts_test.p4` 只 `#include <core.p4>` 和 `<tna.p4>`，**根本没有 include
> `include/parsers.p4`**（只有 `datasettest.p4` / `zxport.p4` 才 include 它）。
> 改的是一个**死文件**，编译器当然不报错。

**教训**：在交换机上改参照程序做实验前，**先 `grep '#include'` 确认改到的文件真被编译**。
否则会得到一个"干净"的假结果，而它比报错更危险。

### 结论

**`Resubmit` 回的是本 pipe 的 ingress parser —— 它安全，但它是 ingress 的功能。**

于是对一个 **egress-only** 的设计（D1，因为队列深度只有 egress 读得到）：

- 想让寄存器读写分到两遍 ⇒ 必须让包在 **ingress** 再跑一遍；
- 而 egress 测到的队列深度要送回 ingress ⇒ 只能靠 `recirculate`；
- 而 `bypass_egress` + RECIRC_PORT 的 recirculate **会落到另一个 MAU pipe** ⇒
  **寄存器 per-pipe 状态分裂** —— 正是 `INT/wzc_p4` 当年踩的那个坑。

**⇒ B 方案不是"贵"，是"不能用"**（除非把整个设计搬回 ingress，那就同时丢掉
队列深度这个唯一的 egress 独占输入）。**A+C 成为唯一出路。**

---

## D21. ★ v0.3：`context_id` 是 32 位全局轮次号，标签精确绑定

> 2026-10-17。本决策在 `proto/action_label.py`、`proto/ctx_report.py`、
> `p4/include/headers.p4`、`p4/min_disc.p4` 里以「D21」被引用。

### 决策

- `reg_rseq` 是 **32 位全局轮次计数器**：每产生一份**新的**上下文快照
  （跨越上报，或冷却后的补报）就 +1；`ctx_report_t.context_id` 携带的就是它。
- **心跳重发同一个 `context_id`**，不产生新轮次。
- 标签绑定改为**精确相等**：`label.context_id == reg_rseq`，且 `pending == 0`
  （无待发报告）。
- 删除 v0.2 的 `ctx_tolerance`（邻域绑定）与 `reg_report_ctx`（每流 last_metric）。
- 上报固定携带 `queue_level / load_level / path_level` 三路等级，不再有 `metric_id`。

### 理由

需求原文是「服务器协议里的 context_id 就是这个数字」——指的是**上下文更新的次数**，
本来就是全局计数器，不是 4 位等级，也不是每流的局部量。
容差原本用于抗边界抖动；v0.3 已有 100 ms 冷却 + 1 s 心跳兜底，精确绑定更简单、
语义更硬，也更符合「网络 context 变化 ≠ 流的动作需要变化」的表述。

### 代价与残留风险

- 绑定是**全局轮次**而非每流；服务器是唯一签发者，可接受。
- `reg_rseq` 从 0 开始、首份报告后为 1。若交换机**从未上报**，
  一个 `context_id == 0` 的标签理论上能通过精确相等判定。
  当前 P4 未加额外守卫；要堵住在 `apply()` 的 `ctx_ok` 里加 `rseq != 0`
  （该判断在 `apply()`，不占 RegisterAction 的 2 次比较预算）。

---

## D22. ★ 放弃离线参考模型与 pytest，验证改在交换机上（2026-10-17）

### 决策

删除以下内容：

| 路径 | 内容 |
|---|---|
| `model/` | `switch_egress.py`（行为级参考模型）、`registers.py`、`quantizer.py`、`__init__.py` |
| `tests/` | `test_state_machine.py`、`conftest.py` |
| `_parked/test_p4_consistency.py` | P4 字段 ↔ `proto/constants.py` 的离线逐字段比对 |
| `.pytest_cache/` | pytest 缓存 |

此后正确性验证**只在交换机上进行**：`bf-p4c` 编译 → 打流 → 抓包 / 寄存器 dump。

### 理由

用户明确要求：不再维护离线模型，「有测试的话直接在交换机上跑」。

### 后果（如实记录）

- 本地不再有任何自动化测试；「`model/` 是 P4 行为级真源」这条约定终止，
  `md/01` 与 `p4/` 成为唯二真源。
- `bf-p4c` 能抓语法错误与 sALU 资源超限，**抓不了字段错位**
  （两边都没错、就是不一致）。这类 bug 只能靠 V6 抓包与
  `vectors/` **逐字节比对**暴露。
- `proto/` 保留：服务器与发包 agent 仍需要它做编解码；
  它不依赖已删除的 model。
- 本文件前文（D11–D18）提到的 `model/...`、`tests/...` 路径均为历史记录，
  对应文件已不存在。

---

## D23. ★★★ 寄存器改「乒乓双副本 + 相位」—— D19 读写不能分家的最终形态

> 2026-10-17。解决 #11（`reg_sm` 的 sALU 架构重构），并顺带修掉同 epoch
> 标签接受后漏写 `reg_seq` 的防重放漏洞（#17）。

### 问题

D19 的实测结论是：

> 同一物理寄存器同包内「读动作 + `reg.write()`」→
> `Table placement cannot make any more progress`。
> 一个 Register 在一个包里只能被一个 RegisterAction 碰一次。

而状态机天然需要「读旧状态 → 算次态 → 写回」。把它塞进一个 RegisterAction
又撞上 ≤2 次比较 / 不许局部变量 / 写必须写满 32 位 / 32 位条件赋值崩溃
（D17/D19）。v0.3 的代码用的是「读动作 + 直接 write」，与 D19 的实测结论
直接冲突，因此不能算可编译。

### 决策

**把「同一个寄存器」拆成两个物理副本，用相位寄存器轮换：**

```
reg_sm_a / reg_sm_b + reg_par_sm
reg_epoch_a/b[16]、reg_seq_a/b[16] + reg_par_lbl[16]
```

每个相关包：

1. `par_ra.execute(idx)`：单次 RMW（`out_v = v; v = v + 1`），取出旧相位；
2. 按旧相位**只读当前副本**；
3. 全部判断与状态机留在 `apply()`；
4. 把新整字写进**另一副本**（写动作 `out_v = v; v = meta.xxx`）。

于是：

- 每个物理寄存器每包最多被一个 RegisterAction 访问（约束①）；
- 读和写落在**不同的物理寄存器**上，不构成 D19 的依赖环；
- 不需要把状态机塞进 sALU，`apply()` 的比较/局部变量限制都不存在；
- 直接 `reg.write()` 全部删除（控制面写入除外）。

同一个寄存器上挂多个动作（如 `sm_a_rd` / `sm_a_wr`）只在**互斥分支**里执行，
与 `datasettest.p4` 的 `reg_S` 两个动作同形（recirc vs first pass）。

### 必须遵守的配套规则

> **相位一旦翻转，本包必须写另一副本** —— 哪怕标签被拒、状态没变，
> 也要把旧整字原样复制过去。否则下一包会读到没更新的旧副本，两份状态错位。

这条在标签路径上尤其重要：ctx 校验失败时也写、sequence 校验失败时也写。

### 代价

| 项 | v0.3 | D23 |
|---|---|---|
| 物理寄存器 | 7 | 13（多出双副本与相位） |
| 数据面每包访问 | 8 | 8（访问的寄存器换了，次数不变） |
| 标签面每包访问 | 8 | 11 |
| 线格式 | — | **零改动** |
| 状态机位置 | `apply()` | `apply()`（不变） |

RAM 开销可以忽略：16 槽 × 32 位 × 若干份，总共不到 1 KB。

### 待验证

**这套结构尚未在交换机上编译。** 最需要确认的是：bf-p4c 是否接受
「同一寄存器上两个动作、由相位分支互斥执行」——参照程序 `reg_S` 的先例
说明很可能可以，但必须用 `bf-p4c` 9.10 实测。若不行，退路是把副本再拆成
「只读寄存器 + 只写寄存器」并把相位编码进表放置（仍需实测）。

---

## D24. ★★ 流作用域、全局 context 的多流重签、上报投递闸门

> 2026-10-17。对应审计中的 P1-1 / P1-2 / P1-4。

### ① 流作用域：完整 flow_id 守卫 + 16 槽

v0.3 的槽位是 `flow_id & 7`，且标签里虽然有 `flow_id`，P4 **从不拿它和
数据包的 flow_id 比对**。后果：两条流低 3 位相同，就会互相命中 ——
直接违反「标签只能作用于指定流」。

决策：

- 槽位扩到 **16**（`flow_id & 0xF`）；
- 新增 `reg_label_flow[16]`，接受标签时写入完整 16 位 `flow_id`；
- 数据面执行动作前要求 `reg_label_flow[slot] == meta.flow_id`。

这堵住的是**串流**，不是**槽位冲突**：冲突时后写入者覆盖先写入者，
先那条流失去动作（安全失败）。10 条流实验必须选 `flow_id & 0xF` 互不相同的流；
彻底方案是 P6 的 `flow_id → slot` 精确映射表。

> `flow_id` 仍是五元组 XOR，且 **XOR 方向对称**：正反两个方向算出来相同。
> 论文里必须写明这一点，不能声称流作用域是精确无碰撞的。

### ② 全局 context → 服务器必须批量重签

`context_id` 是全局轮次；任何一条流的跨越都会使所有缓存标签失效
（`arm_gen` +1）。而报告只带承载包的 `flow_id`。如果服务器只回应报告里的
那一条流，其他流会永久停在未武装态。

**协议规则**：服务器收到新轮次后，必须对**已知的全部受控流**重新签发标签
（动作可原样不变，只换 `context_id`）。Week1 的服务器 agent 必须维护 flow 列表。

### ③ 上报投递闸门

P4 只改 EtherType、不改目的地址；原实现也没有检查「这个包是不是去服务器」。
决策：新增 `report_dst` 精确匹配表（key = `ipv4.dstAddr`），**默认拒绝**；
控制面安装服务器 IP 后才允许插上报头。不能承载上报的跨越只置 `pending`，
等下一个去服务器的包补发。

服务器侧 agent 必须能识别 EtherType `0x5555` 并剥掉 14 字节头（v0.4，D28 由 24 字节压缩）；
普通 IP 栈会丢弃该帧。若拓扑里没有「发往服务器的受控流」，需要镜像/重定向
（Week2）。

---

## D25. ★★ 2026-10-17：去乒乓 → 版本失效模型；第二批编译减负

### 决策

D23 的 A/B 双副本 + 相位寄存器整体删除，改为**每流一个 `reg_ver`**：
标签有效 ⇔ 标签 `context_id` 等于该流当前版本；跨越（判决翻转）时版本 +1，
旧标签立即失效，与报告是否送达解耦。物理寄存器从 D23 的多个副本降为 6 个
（`reg_cfg` / `reg_ctx_last` / `reg_ver` / `reg_rep_ver` / `reg_label` /
`reg_label_flow`），每个逻辑量一个物理寄存器、每包最多访问一次。

在此基础上，第二批简化（目标是缩短 action 依赖链、减少 egress 表数）：

1. **标签过期判定合并**：删除 `ddl = now − (now+expiry)` 计算和
   `label_ddl_pos` 表（相对偏移下该差值恒为 −expiry，纯冗余）；把
   `label_expiry_never` 改成一张 range 表 `label_expiry`
   （`0..0x7FFF` 正常 / `0xFFFF` 永不过期 / 其他拒收）。
2. **永不过期改编码**：不再把 deadline 存成 0，而是用 `reg_label` bit25 作
   永不过期标志；表 action 直接输出常量 `never_word`，删除
   `0 - flag` / `~` / `&` 掩码链、删除数据面 `cache_deadline_never` 表。
3. **`reg_ctx_last` 只存 3 位判决**：三个等级快照只写不读，删除；init 位也
   删除（初值 0 即「上次无违规」），跨越检测简化为
   `verdict_now ^ old_verdict`，不再需要 `0 - init` 广播技巧。
4. **`reg_rep_ver` 改为每包执行 RMW**：条件写放进 RegisterAction
   （`if (meta.can_report == 1) { v = meta.cur_ver; }`），删除 apply() 里的
   条件 `execute` 和局部变量二次赋值。

### 理由

- bf-p4c 9.10 对标签路径报 `sub` / `andcb` 的
  `action spanning multiple stages`（行 520 / 539），掩码链是直接来源；
- 标签路径原有 9 张串行表，egress stage 紧张；合并后降到 8 张
  （`label_type` / `label_func` / `label_prio` / `label_flow` /
  `label_expiry` / `label_precheck` / `ctx_match` / `ctx_nonzero_check`）；
- 数据路径少一张 `cache_deadline_never` 表，`crossed3` 少两次运算。

### 代价（如实记录）

- 数据面每包固定多一次 `reg_rep_ver` 的 SALU 访问（原来只有 `can_report=1`
  的包访问）；语义不变。
- `reg_ctx_last` 仍占 32 位寄存器，但只使用低 3 位；如需省寄存器，
  Week2 可把它与 `reg_ver` 合并（当前不做，避免 sALU 复杂化）。
- 负偏移 expiry（`0x8000..0xFFFE`）仍然拒收；`0xFFFF` 永不过期语义保留。
- 线格式未变，`md/01` 与 `proto/` 无需改动。

---

## D25. ★ Week2：ingress 侧动作缓存 —— 双 block 各持一份，标签包做同步载体

> 2026-10-22。S1 已落地（`MyIngress` 只执行 `PORT_REDIRECT`）。与 D1、D16 直接相关。

### 问题

Week2 的三个功能里：

| 功能 | 执行位置 | 可写字段 |
|---|---|---|
| `MEASURE`（cm-sketch） | 任意 | 自己的计数器 |
| `PRIORITY_SET` | **只能 ingress** | `ig_tm_md.qid` |
| `PORT_REDIRECT` | **只能 ingress** | `ig_tm_md.ucast_egress_port` |

而 TNA 不允许同一个 `Register` 被 ingress / egress 共用（D1）。ingress 也读不到
egress 的 `deq_qdepth`，所以「把整套 Week1 逻辑搬去 ingress」不成立 —— 会丢掉
队列深度这个唯一的 egress 独占输入。

### 决策

**两个 block 各持一份标签缓存，标签包本身同时流经两边，充当同步载体。**

- ingress 新增 `reg_ing_lbl[16]` / `reg_ing_dl[16]` / `reg_ing_flow[16]`
  （位布局见 `headers.p4` 的 `ING_LBL_*`），由标签包在 ingress 解析时写入；
- 标签包**不在 ingress 丢弃**，照常交给 egress：egress 继续做 Week1 的
  精确版本校验、落它自己那份 `reg_label` / `reg_label_flow`、然后 `drop_ctl`；
- 数据包在 ingress 读 ingress 缓存，在 egress 读 egress 缓存，互不干扰。

**★ 两个 block 的功能白名单必须相同**（`ing_label_func` 与 `label_func` 都包含
全部已实现功能）。否则会出现「egress 把 `PORT_REDIRECT` 当非法标签丢弃 →
旧的 `DROP` 缓存不被覆盖 → 边丢边重定向」的串动作。接受 ≠ 执行：
`ing_exec_decide` 只放 ingress 功能，`exec_decide` 只放 egress 功能。

### ingress 的 context 绑定：单调 ctx + 短有效期（用户 2026-10-22 拍板）

ingress 拿不到 `reg_ver`（跨 block 寄存器共用被禁），无法复刻「精确相等 +
立即失效」。采用：

1. **单调 context_id**：每流缓存最后接受的 `context_id`（`reg_ing_ctx`，S4 加），
   只接受更新或相同的值；更旧的标签拒收（防重放 / 乱序）。
2. **短有效期**：ingress 动作的有效期由标签 `expiry` 兜底，建议 50–100 ms
   （800–1600 tick）。
3. **失效窗口有上界**：context 跨越 → 新标签到达之间，ingress 可能仍执行旧动作，
   残留时间 ≤ 该标签的 `expiry`。**论文里必须写成「有限期内有效」，不能写成
   「立即失效」**；egress 侧仍是立即失效（版本精确相等）。

被否决的替代方案：

| 方案 | 否决理由 |
|---|---|
| 控制面同步（egress 镜像上报表 → agent 写 ingress 寄存器） | 精确，但重新引入 D2 刻意避开的 CPU 回路，Week2 工作量明显变大；留作后续工作 |
| 把整个设计搬去 ingress | 丢掉 `deq_qdepth`，Week1 的队列指标无法实现 |
| ingress 完全不校验 ctx（只靠 expiry） | 重放防护更弱；单调检查只多一张表，代价低 |

### S1 范围（2026-10-22）

- ingress 实现：静态校验（switch_id / msg_type / 功能白名单 / priority≤15 /
  flow 非通配 / expiry）+ deadline + flow 防串流 + `PORT_REDIRECT`；
- **尚未做**：`PRIORITY_SET`（S2）、`MEASURE`（S3）、单调 ctx（S4）、seq/epoch 校验；
- 线格式零改动；只新增 `FUNC_MEASURE = 0x06`。

### 已知限制

- 寄存器 per-pipe：标签包与数据包必须从**同一个 MAU pipe** 进入，ingress 缓存
  才可见。单口回环拓扑满足；多口实验要选同一 pipe 的端口。
- `egress_port` 只有 8 位；实验拓扑端口 ≤ 64，够用。
- `qid` 的效果依赖控制面把 0..7 号队列配成不同调度；只改 `qid` 不配调度，
  行为可能完全一样（S2 上机时要先配队列）。

---

## D28. ★★★ 2026-10-23/24：上机编译落地 —— 头压缩、字节对齐、stage 预算

### 问题

`min_disc.p4` 从 2026-10-07 起就写好了，但直到 2026-10-24 才第一次在交换机上
编译成功。失败分成两类，先后暴露：

1. **每动作 PHV 源数超限**：`hdr.ctx_report.context_id = meta.cur_ver` 需要
   「容器本身 + 两个 16 位半区」= 3 个源，Tofino 只允许 2 个；
   修好后错误往后挪一行，`context_id[31:16]` 与 `timestamp` 又融合成 4 源指令。
2. **全局 PHV 打包组不可满足**：`Unable to slice the following group of fields
   due to unsatisfiable constraints` + `PHV allocation was not successful`
   （73 个切片）。bisect 到根因：`reg_cfg` 的旧布局 `cfg[4:0]/[9:5]/[14:10]/[18:15]`
   是**非字节对齐**的小片，Tofino 的 PHV 切片是**字节粒度**的，这些字段被劈成
   `[3:0][4:4][8:5][9:9]...` 之后无法打包，并且通过 `queue_level` 等字段把整张
   `ctx_report` 拉进同一个不可满足的组。
3. PHV 过了之后暴露第三层：**MAU stage 预算**。Tofino-1 每个 block 只有 12 级
   （`--num-stages-override 16` 会被拒：`device is capped to 12`）；egress 数据面
   的顺序依赖链一度到 16 级，报 `Table placement cannot make any more progress`。

### 决策

**(a) `ctx_report_t` 24 → 14 字节（v0.4）**：删除 `switch_id` / `port_id` /
`diag_value` / `diag_metric` / `crc16` / `_pad`，`timestamp` 32 → 16 位 tick。
线格式细节见 md/01 §1。动机：① 这些常量字段本就不承载信息；② 每多一个字段
就多一次 egress 写头，直接占用 stage 预算。`action_label_t` 不变（仍 24 字节）。

**(b) 凡是参与 PHV 运算/切片的字段，一律字节对齐**：

| 位置 | 旧 | 新 |
|---|---|---|
| `reg_cfg` 布局 | `cfg[4:0]` / `[9:5]` / `[14:10]` / `[18:15]` | `cfg[7:0]` / `[15:8]` / `[23:16]` / `[31:24]` |
| `meta.th_*` / `meta.ctx_*` / `meta.dq/dl/dp` | `bit<5>` / `bit<4>` | 一律 `bit<8>` |
| `verdict_map` 键区间 | `0..15` / `16..31` | `0..15` / `16..255` |

语义：等级值仍是 0..15；阈值 `0..15` 有效，**`≥16` 表示该指标永不判违规**
（全 1 字节即「关闭」）。8 位无符号相减为负时回绕到 241..255，仍然 `≥16`，
所以判决边界常量保持 16。

**(c) egress 省 stage 的三处合并**（语义不变）：

| 合并 | 节省 |
|---|---|
| `data_deadline_past` + `expired_decide` → 一张表（键 = `ddead` range × `label_valid`） | 1 级 |
| `path_level` / `_rsv0` 的写操作 → 塞进 `report_dst` 表动作 | 1 级 |
| `_rsv1` 的写操作 → 塞进 `expired_decide` 动作；`timestamp` → 塞进 `crossed_decide` 动作 | 1~2 级 |

**(d) egress deparser 不再 `emit(hdr.action_label)`**：标签包在 egress 一律
`drop_ctl=1`，永远不上线；而 emit 会让标签头的所有字段（含 egress 根本不读的
`sequence`/`crc16`/`epoch`/`egress_port`/`priority`）都要占 egress PHV。

**(e) 删除死字段 `meta.tstamp`**：48 位只赋值不读，却让 `global_tstamp` 在整个
egress 保持活跃。

### 实测出来的 Tofino 规则（写代码前先对照）

- 单条指令最多 **2 个 PHV 源**；容器读回算 1 个源。
- **32 位字段整字写**需要 3 个源 → 必须拆成两个 16 位半区写，且中间隔一个
  `RegisterAction` / 表动作当屏障（相邻直线写会被 copy-prop 融合成一条）。
- 表 `apply()` 与 `RegisterAction.execute()` 是 stage 屏障；两个屏障之间的
  直线赋值可能被融合。
- 同一容器的「已写 / 未写」两端必须连续。
- 把纯写头语句塞进相邻表动作，能**省掉独立的写头 stage**（D28 的三个合并）。
  但这只是必要手段，不是充分手段：D28 做完仍是 17 级，最终靠 D29 才降到 12 级。
- 诊断手段：`cp -r` 源码到 `/tmp/bisect`，sed 注释掉功能块后重编；
  `-T "table_placement:8"` 能看到 `table placement ending with unplaced tables:` 列表。

### 控制面影响（必须同步）

- `reg_cfg` 改为 4 个 8 位字段：`cfg[7:0]=th_queue`、`[15:8]=th_load`、
  `[23:16]=th_path`、`[31:24]=path_avail`。
- 上报头 14 字节（见 `proto/ctx_report.py`）；`md/01` v0.4 已同步。
- 四张表仍需一致安装：`flow_key_ing` / `slot_map_ing_lbl` / `flow_key` /
  `slot_map_lbl`。

### 代价与限制

- `timestamp` 每 4.295 s 回绕，服务器侧必须用有符号差值比较。
- `path_level` 写头时截断到 4 位（协议字段仍是 4 位），控制面 `path_avail`
  应 ≤ 15。
- egress stage 预算已接近上限：**再加表/寄存器前先数顺序依赖链**。

---

## D29. ★★★ 2026-10-24：egress 17 → 12 级 —— 寄存器融合点与条件链

### 问题

D28 做完后 `make min_disc` 仍然失败：

```
tofino supports up to 12 stages, using 17
```

（这条来自后端 `asm`，`p4c-barefoot` 的诊断脚本**不报**，见 md/03 V11a 的教训。）

### 根因（实测，两条）

1. **同一个 Register 在一个 block 里只有一个物理访问点。**
   标签分支写 `reg_label` / `reg_label_dl` / `reg_label_flow`，数据分支读同一批
   寄存器 → 读写融合到同一个 stage，融合点由**最深的那条依赖链**决定。
   同理 `reg_ver`：数据面 `ver_ra` 写、标签面 `ver_diff_ra` 读，融合点被数据面的
   RMW 拖到 stage 8，于是：
   `reg_ver`(8) → 标签侧 ctx 校验 cond(10) → `reg_label*`(11–12) →
   `expired_decide`(14) → `exec_decide`(15) → 执行 if 链(16)。
2. **每个嵌套 `if` 是一个 cond gateway，各占一个 stage。**
   标签分支 6 层嵌套（type_ok→is_revoke→func_ok→expiry_ok→ctx_match→ctx_nonzero），
   数据分支尾部又有 report_due→can_report、do_exec→exec_func。

**否定过的手段**：把源码里的数据分支移到标签分支前面。p4pp 确认顺序已换，
放置结果**逐 stage 一模一样**——这是物理融合约束，与源码顺序无关。

### 决策

1. **删掉标签侧的版本校验**（`ver_diff_ra` / `ctx_match` / `ctx_nonzero_check`）。
   标签分支只保留 `label_type` / `label_func` / `label_expiry` 三个**不碰寄存器**
   的检查，`reg_ver` 不再被标签侧读 → 融合点提前。
   **安全性论证**：数据面 `exec_decide` 的 key 已有
   `label_valid / ver_xor / expired / flow_xor / label_func`，`ver_xor==0`
   等价于「标签里的 context_id == 当前 reg_ver」，陈旧标签**不可能被执行**。
   失去的只是「陈旧标签不会覆盖同槽位的新标签」这一缓存卫生性质。
2. **执行效果写进 `exec_decide` 的表动作**：`exec_drop` 直接写
   `eg_intr_dprs_md.drop_ctl`，`exec_ecn` 直接改 `hdr.ipv4.diffserv`，
   删掉 `do_exec` / `exec_func` 之后的三层 if（cond-35/36/37）。
3. 删掉 `meta.do_exec` / `meta.exec_func` 的赋值（egress 侧；ingress 的
   `ing_do_exec` 保留）。

### 结果

- `make min_disc` **EXIT=0，0 ERROR**；`pipe/tofino.bin` 1.49 MB。
- egress **12 级（0–11）**，ingress 10 级。
- 行为差异**只有**上面第 1 条的缓存卫生性质；数据面执行条件完全不变。

### 代价与限制

- egress 已经顶到 12 级：**再往 egress 加任何表/寄存器都会失败**，
  必须先删/合并同等数量的 stage。
- 后续 Week2 S2（PRIORITY_SET）要放在 **ingress**（D16），不要动 egress。
- 若将来必须恢复标签侧版本校验，正确做法不是加回 `reg_ver` 的读，而是
  **把校验移到数据面**（例如在 `exec_decide` 前加一个只读 `reg_label` 的表），
  否则融合点会再次被拖后。

---

## D30. ★ `deq_timedelta` 语义纠正（2026-10-24，待实施）

### 问题

上机实测上报解出 `q=1 l=15 p=15`：**空闲链路却报「负载最高」**。
查 `tofino1_base.p4:255`：`deq_timedelta` 是「包的**入队→出队**时间差」，单位 ns，
**不是**相邻出队间隔。`quantize_load` 按「间隔越短负载越高」写成降序表
（`0..99→15` … `50000+→0`），空闲时延小 → 被判成 15。

### 决策

`load_level` 仍用 `deq_timedelta`（排队时延本身是有效的拥塞指标），但桶方向反转：
`0..99→0`、`100..199→1` … `50000+→15`。**线格式不变**，只改量化语义。
实施顺序仍按 `md/01` → `proto/constants.py`（只有注释涉及）→ P4 → 重编译。

### 状态

**未实施。** 需要改 `p4/min_disc.p4` 的 `quantize_load` 并重新编译/重载
（会中断当前数据面，须用户确认）。修复前 `load_level` 不可用 ——
控制面应把 `th_load` 设为 16（永不判违规），避免误报。

---

## D31. ★ 规则生成改用「支付意愿 × 影子价格」，取消判决阈值（2026-10-24，设计草案）

### 问题

早期设计用一组手设状态阈值决定动作（如「队列等级 ≥ X 就升优先级」）。阈值在
不同拓扑/业务下都要重标定，且无法体现"同时考虑私有状态与网络状态"。

### 决策

服务器侧规则改为对偶分解形式：私有状态 → 每单位速率的支付意愿 `v`；交换机
上报的 context → 每单位速率的影子价格 `μ`。`v > μ` 时买入优先级，档位来自
凹优化的一阶条件 `h* = H_max·clip((v−μ)πc/β, 0, 1)`；`v ≤ μ` 时比较 ECN 的
净收益 `J_ECN`；都不成立则**不发标签**（`A = NOOP`）。判决边界 `v = μ` 随
context 连续移动，没有判决阈值；剩下的数值边界只有上报量化桶与安全闸门。

`v` 同时承载 deadline 与 latency sensitivity：

```text
u = 1 − (1 − exp(−max(0, D_rem − r_eff/R̂)/T_v)) · (1 − λ)
v = w/(R0 + R̂) + u · r_eff/(T_v · R̂²)
```

- 业务优先级 → `w ∈ [0,1]`（`w=0` 表示纯让路流）；
- deadline 或 latency sensitivity → `D_rem` 与 `λ ∈ [0,0.9]`；弹性流用 `λ`
  表达时延敏感，`λ<1` 保证 ECN 仍可达；
- 发送端拥塞与重传 → `ρ`、`R̂`、`σ`；
- 网络侧由队列/负载/路径合成稀缺度 `π`，价格 `μ = μ0·exp(κ_π·π)`。

配套约束：

- **有效期 `expiry` 只能由上报间隔统计决定，不能由私有状态决定** —— 否则标签
  会额外泄露 deadline（见 `md/06` B.3 推论 2 的 `I(X;η|A,Z)` 项）。
- **优先级档位数 `|𝒜|` 是披露旋钮**：档位越少，`H(A|Z)` 越小，控制粒度越粗。
- **"不发标签"不是零披露**：缺席是可观测的 `A=NOOP`，计入 `H(A|Z)`；只有当
  该 context 下动作与私有状态无关（`H(A|Z)=0`）时才应下推到交换机本地策略。
- 模型不改线格式；`RATE_LIMIT` 因无速率参数而不使用，"让带宽"用 `ECN_MARK` 表达。

### 状态

**设计草案，未实现。** 详见 `md/06-rule-model-and-theory.md` Part A。
`agent/` 里还没有对应的实现；上机执行侧只覆盖 `NOOP`/`DROP`/`ECN_MARK`/
`PORT_REDIRECT`，`PRIORITY_SET` 的队列选择尚未接通。

---

## 附：D6 已废弃

D6 的 `ctx_tolerance`（上下文邻域绑定）已被 D21 的「32 位轮次号精确相等」
取代；`action_label_t` 中不再有 `ctx_tolerance` 字段。D6 仅作历史记录保留。
