# 协议规格 v0.1（单一真源）

> ⚠️ **本文件是唯一真源。** `proto/constants.py`、`proto/*.py` 编解码器、`p4/include/headers.p4` 全部从这里派生。改协议必须先改本文件，再改代码，最后在交换机上编译校验（离线一致性检查已于 2026-10-17 删除）。

- 版本：v0.3（Week1 草案，字段已预留扩展空间）
- 日期：2026-10-17
- 目标平台：Intel Tofino / BF-SDE 9.10.0 / P4-16 TNA

---

## 0. 全局约定

### 0.1 字节序

**全部大端（网络字节序）**，与你现有 `telemetry_common_t` 一致。

### 0.2 EtherType 分配

沿用你 `0x8888 / 0x7777 / 0x6666` 的风格扩展，互不冲突：

| EtherType | 常量名 | 含义 | 方向 |
|---|---|---|---|
| `0x5555` | `TYPE_CTX_REPORT` | 上下文报告，其后**必然**是 IPv4 | 交换机 → 服务器 |
| `0x4444` | `TYPE_ACTION_LABEL` | 动作标签，此包**不再转发** | 服务器 → 交换机 |
| `0x0800` | `TYPE_IPV4` | 普通 IPv4 数据 | — |
| `0x8888/0x7777/0x6666` | 你 INT 项目已占用 | 不要复用 | — |

### 0.3 时间基准（★ 最容易写错的地方）

沿用你现有的 tick 约定：

```
tick = global_tstamp[31:16]      // 16 bit
1 tick = 65536 ns = 65.536 µs
ticks_per_ms = 1_000_000 / 65536 = 15.2587890625
换算：ticks = target_ms * 15.259
```

> ⚠️ **16-bit tick 每 4.295 秒回绕一次**（`65536 × 65.536µs = 4.2949 s`）。

由此产生两条**强制规则**，违反会导致上机后"标签随机失效"或"旧标签被误接受"：

| 规则 | 正确做法 | 错误做法 |
|---|---|---|
| **R1** 过期判断 | `expiry` 存**相对当前 tick 的偏移**；比较用**有符号差值** `(int16_t)(now + expiry - now) >= 0` | 存绝对 deadline 再比 `now <= deadline` —— 被 4.295 s 回绕击穿 |
| **R2** epoch 单调判断 | `epoch` 是 `bit<8>`，回绕周期 256。用 `(int8_t)(new - cached) > 0` | 无符号比较 `new > cached` —— `255→0` 时旧标签会被误接受 |

两条规则必须在上机验证时用边界用例覆盖（`epoch 255→0`、`expiry` 跨 tick 回绕点）。

### 0.4 交换机标识

`switch_id = 1`（固定，与 `datasettest.p4` 一致）。多交换机实验必须区分。

### 0.5 CRC16

**CRC-16/CCITT-FALSE**：`poly=0x1021, init=0xFFFF, refin=false, refout=false, xorout=0x0000`，校验值 `0x29B1`（输入 `"123456789"`）。

Python 侧可直接用 `binascii.crc_hqx(data, 0xFFFF)` —— **参数完全等价**，`proto/crc16.py` 必须用它做交叉验证。

> **P4 侧不算 CRC，字段填 0。** 理由：你的 `mau.resources.log` 显示 Hash Dist Unit 已 **100% 占用**（3 个 `CRCPolynomial` × 2 HashDist = 6/6）。上行报告本来就在服务器侧解析，CRC 在 Python 侧校验即可；下行标签的重放/乱序保护由 epoch + sequence 提供，不依赖 CRC。P4 里留 `TODO` 注释和 `verify_crc16` 表桩。

---

## 1. `ctx_report_t` — 交换机 → 服务器上下文报告

**EtherType `0x5555`，固定 14 字节（v0.4，2026-10-23 起；此前为 24 字节）。**

插入位置：`ethernet` 与 `ipv4` 之间。parser 链为 `ethernet(0x5555) → ctx_report → ipv4`（**无条件**进 IPv4，因为只监控 IPv4 流，省掉 `proto_id` 字段 2 字节）。

> **v0.4 压缩（D28，2026-10-23）**：删掉 `switch_id` / `port_id` / `diag_value` /
> `diag_metric` / `crc16` / `_pad` 六个字段（共 10 字节），理由有二：
> ① 交换机 egress 的 PHV 分配吃紧，24 字节头上机后报
> `requires too many sources` / `unable to slice`，压到 14 字节后字段落位余量大得多；
> ② 这几个字段 Week1 全部恒为常量 0，属于「没有信息量的披露」，删掉只会更符合最小披露。
> `timestamp` 同时由 32 位降为 16 位（tick），与交换机内部的 16-bit tick 对齐。

### 字段表

| 偏移 | 字节 | 字段 | 位宽 | 语义 / 编码 |
|---|---|---|---|---|
| 0 | 1 | `version` | 4 | 协议版本，固定 `0x1` |
| 0 | 1 | `msg_type` | 4 | `0x1`=CTX_REPORT（`0x2`=DIAG 自 v0.4 起停用） |
| 1 | 1 | `flags` | 8 | 见下表 |
| 2 | 2 | `flow_id` | 16 | 控制面按五元组下发的流标识（D27）；`0xFFFF` = 未登记流 |
| 4 | 1 | `queue_level` | 4 | 队列拥塞等级 `0..15`（`deq_qdepth` 量化） |
| 4 | 1 | `load_level` | 4 | 端口负载等级 `0..15`（`deq_timedelta` 量化；⚠️ 语义待修正，见 §3.4） |
| 5 | 1 | `path_level` | 4 | 路径可用等级 `0..15`（控制面写入） |
| 5 | 1 | `_rsv0` | 4 | 保留，必须 0 |
| 6 | 4 | `context_id` | 32 | ★ **上下文版本号**：判决翻转时 +1，跨越即新版本。服务器原样回填到 `action_label_t.context_id` |
| 10 | 2 | `timestamp` | 16 | `global_tstamp[31:16]`（tick，65.536 µs），每 **4.295 s** 回绕一次 |
| 12 | 2 | `_rsv1` | 16 | 保留，必须 0（对齐用） |

> v0.4 之后**没有 CRC**：报告在服务器侧解析，下行标签的重放/乱序保护由
> `epoch` + `sequence` 提供，不依赖 CRC（见 §0 的说明）。

### 1.1 `flow_id`：控制面下发（D27，2026-10-22 定稿）

**现状（v0.3-rev3 / D27）**：`flow_id` 由**控制面按五元组精确分配**，数据面零异或。

- 控制面下发两张表：`flow_key`（五元组 exact → `(flow_id, slot)`）与
  `slot_map_lbl`（`action_label.flow_id` exact → `slot`），ingress 侧
  `flow_key_ing` / `slot_map_ing_lbl` 与之对称。
- 未登记流命中默认项，`flow_id = 0xFFFF`（`FLOW_ID_WILDCARD`）；服务器应把它
  当作「不可作用的流」，不为其签发标签。
- 流相等性判定在 RegisterAction 内做 32 位减法（`flow_id - 寄存器值`，0 = 相等），
  避免两个 PHV 在 apply() 里直接比较（bf-p4c 不支持）。

**为什么改**：早先的「5 元组异或取低 16 位」是线性映射，碰撞率高，且交换源/目的
后得到同一个 `flow_id`（正反方向共用标签）。精确映射彻底消除了这个问题，
并且把「flow 作用域」变成控制面可审计的事实。

### `flags` 位定义

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | ~~`DIAG_PRESENT`~~ | **v0.4 起停用**：字段已删除，本位必须为 0 |
| 1 | `STORM_SUPPRESSED` | 本次发生了跨边界但因冷却被抑制，未上报（仅在**未发送**的报告里置位；若同时置位则本包不携带报告） |
| 2 | `CTX_DEBOUNCED` | 跨越经防抖确认（连续 N 次观测一致）后才上报 |
| 3–7 | — | 保留，必须 0 |

### ★ 关键设计点：报告本身也遵守最小披露

三个 `*_level` 都是 **4 bit 量化等级**，绝不出现在 19-bit 原始队列深度、原始 `deq_timedelta`。服务器永远看不到原始值 —— 它拿到的是「本轮 context 的三个等级 + 轮次号」。

★ **报告携带的是"完整的网络状态"**（队列 / 负载 / 路径三路都有），而不是只带触发这次上报的那一个指标。服务器要据此同时算动作，缺任何一路都算不出来。

★ **`context_id` 是轮次计数器，不是等级**。它只告诉服务器「这是第几次快照」，服务器把它原样回填到标签里；标签里不带任何上下文等级。见 §2.1。

★ v0.4 起报告里**不再有任何原始值或诊断例外**：14 字节里只有量化等级、
流标识、上下文版本和 tick。原先 `diag_value` 的「诊断授权例外」被整段删掉 ——
用户明确要求先压缩到能上机；诊断通道留到 Week2 再按贡献 1 的授权模型重新设计。

### ★ 上报投递闸门（D24，2026-10-17）

报告是搭在当前数据包上发出去的，**当前代码不改变包的目的地址**。因此：

- P4 新增 `report_dst` 精确匹配表（key = `ipv4.dstAddr`），**默认拒绝**。
  控制面必须把服务器 IPv4 地址装进这张表，才允许在该包上插 `ctx_report_t`。
  没配表 ⇒ 永不上报，交换机停在未武装态（有意的安全默认，见 `md/03` V5）。
- 本包不能承载上报时，跨越只置 `pending`；等下一个**去服务器**的包再补发
  （补发包的 `flow_id` 是补发包自己的流，不是触发跨越的流 —— 服务器必须按
  `context_id` 轮次处理，并对已知的全部流重签，见 §3.2）。
- 插入上报头会把该包的 EtherType 改成 `0x5555`（原 IPv4 头仍在）。
  **服务器侧 agent 必须能识别 `0x5555` 并剥掉 14 字节头**；普通 IP 栈会丢弃它。
- `port_id` 目前恒为 0（Week1）；报告本身只用于服务器算动作，不依赖端口号。
- 若实验拓扑里受控流不经过服务器（例如服务器→客户端的下行流），必须额外做
  镜像或端口重定向，否则没有任何包能承载上报。这是 Week2 的工作。

### 上报防风暴四道闸门

```
每包 egress:
  闸门①  只有 context 快照发生变化（某个等级跨过阈值边界）才进入上报流程 —— 不是每包都报
  闸门②  状态闸门：IDLE / REPORTED / STALE / ARMED 都允许**因跨越**上报。
          ★ REPORTED 态下的新跨越必须上报，否则服务器会拿过期 context 生成标签
  闸门③  冷却闸门：距上次上报不足 100 ms → 置 STORM_SUPPRESSED / pending，不发
          冷却已过 → 构造 ctx_report_t 挂到本包 → context_id += 1 → 发往服务器
                     状态 = REPORTED, 更新 context 快照, 重置冷却
  闸门④  单包单报告（EtherType 唯一，parser 只有一个分支）
```

> ★ **v0.3 改了闸门②。** v0.2 写的是「REPORTED 一律不报」，但那样会造成一个真实的洞：
> 上报（轮次 N）→ 标签在途 → context **又变了一次** → 交换机不上报 → 标签到达
> （轮次仍是 N，匹配）→ 进入 ARMED，执行**基于过期 context** 算出的动作。
> 现在防风暴由 **100 ms 冷却**承担（最快 10 次/秒），而不是靠状态锁死。
> 这与贡献 2 的「context 变化 → 标签立即失效 → 发新 context」一致。
>
> **1 秒心跳重传**仍然保留（`REPORTED` 下 `context_id` **不变**），只为兜底
> 「上报或标签在网络里丢了」导致的永久卡死。注意报告是**搭在数据包上**发出去的，
> 所以 `flow_id` / `timestamp` 必然与首发不同；三个等级也可能在同一阈值侧内轻微
> 漂移（未跨阈值 ⇒ 协议仍认为这是同一轮 context）。**服务器按 `context_id` 去重**，
> 重复轮次的快照一律忽略；心跳因此不引入新披露。关闭它的办法是服务器拒收重复
> `context_id`，或在上层做超时。

---

## 2. `action_label_t` — 服务器 → 交换机动作标签

**EtherType `0x4444`，固定 24 字节。**

交换机收到后：解析 → 校验 → 写标签寄存器 → **`drop_ctl` 丢弃该包**（不转发）。

### 字段表

| 偏移 | 字节 | 字段 | 位宽 | 语义 / 编码 |
|---|---|---|---|---|
| 0 | 1 | `version` | 4 | 固定 `0x1` |
| 0 | 1 | `msg_type` | 4 | `0x1`=ACTION_LABEL，`0x2`=LABEL_REVOKE，`0x3`=LABEL_HEARTBEAT |
| 1 | 1 | `flags` | 8 | `bit0`=CRITICAL(不可缓存)，`bit1`=PARAM_VALID，`bit2..7`=0 |
| 2 | 1 | `switch_id` | 8 | **必须匹配本机 `1`，否则丢弃**（防误投） |
| 3 | 1 | `epoch` | 8 | 纪元号。服务器重启/策略切换时 +1。★ 有符号差值比较 |
| 4 | 2 | `flow_id` | 16 | 作用域：流。`0xFFFF`=通配，作用于所有流 |
| 6 | 1 | `function_id` | 8 | 作用域：功能，见下表 |
| 7 | 4 | `context_id` | 32 | ★ **服务器回填的 context 轮次号**：必须等于交换机当前 `reg_rseq`，否则拒收（见 §2.1） |
| 11 | 1 | `action_id` | 8 | 同 function 下的参数档位，便于服务器侧审计 |
| 12 | 1 | `priority` | 8 | 冲突仲裁（大者胜）；同时是 `PRIORITY_SET` 的参数（队列优先级 0–7；寄存器只存 4 位，`>15` 直接拒收） |
| 13 | 1 | `egress_port` | 8 | `PORT_REDIRECT` 的目标端口（实验拓扑端口 ≤64） |
| 14 | 2 | `_rsv0` | 16 | 保留，必须 0 |
| 16 | 4 | `sequence` | 32 | ★ **同 epoch 内单调递增，防重放** |
| 20 | 2 | `expiry` | 16 | ★ **相对当前 tick 的偏移**。`0xFFFF`=永不过期 |
| 22 | 2 | `crc16` | 16 | 覆盖字节 0..21。P4 侧填 0 |

### `function_id` 定义

| 值 | 名称 | 参数 | 执行位置 |
|---|---|---|---|
| `0x00` | `NOOP` | — | 纯转发（默认安全动作） |
| `0x01` | `RATE_LIMIT` | — | ⚠️ **保留**：v0.3 无速率参数字段，收到即拒收；Week3+ 再定 |
| `0x02` | `PRIORITY_SET` | `priority` | **Week2 / ingress** ⚠️ |
| `0x03` | `PORT_REDIRECT` | `egress_port` | **Week2 / ingress** ⚠️ |
| `0x04` | `ECN_MARK` | — | egress |
| `0x05` | `DROP` | — | egress |
| `0x06` | `MEASURE` | `action_id` = sketch 编号（0/1） | **Week2 / ingress** |
| `0x07–0xFE` | 保留 | | |
| `0xFF` | 通配（作用于该 flow 的所有功能） | | |

> **Week1 实现了 `NOOP` / `DROP` / `ECN_MARK`（全部在 egress）。
> Week2 增加 `PRIORITY_SET` / `PORT_REDIRECT` / `MEASURE`（全部在 ingress）。**
> 前两项只能在 **ingress** 写 `ig_tm_md`（`qid` / `ucast_egress_port`；egress
> 侧没有可写字段）；`MEASURE` 同样放 ingress，让 Week2 的三项功能共用一套
> 标签缓存与校验路径。
>
> ⚠️ **架构含义：** `p4/min_disc.p4` 的 Week1 逻辑是 egress-only。Week2 必须为
> ingress 单独建一套寄存器（TNA 不允许同一 Register 被两个 pipeline 共用），
> 用「标签包本身同时流经两个 pipeline」做同步。**不要**试图共享寄存器。
>
> ★ **两个 block 的功能白名单必须相同**（都包含全部已实现功能）。一个流同一时刻
> 只有一张标签：若 egress 把 `PORT_REDIRECT` 当非法标签丢弃，旧的 egress 动作
> （例如 `DROP`）就不会被覆盖，会出现「边丢边重定向」。正确语义是两边都接受、
> 都落缓存，执行时只做属于本 block 的功能。
>
> `MEASURE` 的 `action_id` 选择 sketch：`0` = sketch A，`1` = sketch B。
> `priority` / `egress_port` 在该功能下无意义，但字段仍然按原格式携带。
>
> `RATE_LIMIT` 的 `rate_kbps` 参数已从 v0.3 包头移除（Week1/Week2 都不用），
> 功能号保留，标签阶段按白名单拒收。

### ★ 上下文绑定：`context_id` 轮次号

`context_id` **不是上下文等级**，而是「第几轮 context 快照」的计数器：

- 交换机每次产生**新的 context 快照并上报**时，`reg_rseq += 1`；报告里的 `context_id` 就是这个数。
- 服务器生成标签时**原样回填**收到的 `context_id`，标签里不携带任何上下文等级。
- 交换机收到标签时：`label.context_id == 当前 reg_rseq` 才接受。

这样「标签只在生成它的那一轮 context 下有效」由**一次 32 bit 相等比较**完成，不需要容差参数。上下文一变就换轮次，旧标签自动失效；**网络 context 变化 ≠ 流的动作必须变化** —— 服务器完全可以对同一个动作重新签发一张新轮次的标签。

> v0.2 的 `ctx_tolerance`（容差窗）已废弃：它把 `context_id` 当作等级，
> 与规格的「轮次号」语义冲突，且多引入一个没有出处可依的参数。
> 防抖改由 100 ms 冷却承担（见 §3.2）。

### ★ Week2：ingress 侧的上下文绑定（D25）

egress 侧仍按上面「精确相等」执行。**ingress 侧拿不到 `reg_ver`**（TNA 不允许
同一 Register 被两个 block 共用），因此 `PRIORITY_SET` / `PORT_REDIRECT` /
`MEASURE` 的 context 绑定采用：

- **单调 `context_id`**：ingress 每流缓存最后接受的 `context_id`（`reg_ing_ctx`），
  新标签必须**更新或相同**才接受；更旧的标签一律拒收（防重放、防乱序）。
  ⚠️ 这条在 **S4** 才进 P4；**S1 目前只靠 `expiry` 兜底**，单调检查尚未实现。
- **短有效期**：ingress 动作的有效期由标签的 `expiry` 兜底。服务器对
  ingress 动作按 **50–100 ms** 量级签发（`expiry` 建议 800–1600 tick），
  到期自动停止执行。
- **失效窗口有上界**：egress 检测到 context 跨越、到新标签到达之间，
  ingress 可能仍在执行旧动作，**残留时间 ≤ 该标签的 `expiry`**。
  这个上界是论文里必须写清楚的一条语义（不是"立即失效"，而是"有限期内有效"）。
- 槽位冲突（`flow_id & 0xF` 相同）时，`reg_ing_flow` 记录完整 `flow_id`；
  新流覆盖旧槽时允许重置单调计数器，避免新流被旧流的 ctx 卡死。

> 为什么不在 ingress 直接复刻"精确相等"：队列深度只有 egress 读得到，
> 版本号在 egress 产生；跨 block 传递只剩"控制面镜像"一条路（成本高，
> 且重新引入 D2 刻意避开的 CPU 回路）。Week2 先用可证明有界的单调 + 有效期，
> 把精确失效留作后续工作。

### 校验流程（按序，任一失败 → 丢弃标签，保持 `REPORTED`）

```
1. switch_id == 1 ?                                  // 防误投
2. crc16 正确 ?                                      // Week1: P4 跳过，Python 侧校验
3. msg_type == ACTION_LABEL ?                        // REVOKE/HEARTBEAT 走别的分支
4. epoch:  (int8_t)(new - cached) > 0      → 接受，重置 cached_seq
           (int8_t)(new - cached) == 0 且 (int32_t)(seq - cached_seq) > 0 → 接受
           否则 → 丢                                    ★ R2 有符号差值
5. expiry: now = global_tstamp[31:16]
           deadline = now + expiry                       // 16-bit 自然回绕 = 正确行为
           if ((int16_t)(deadline - now) < 0) → 过期，丢  ★ R1 相对偏移
           注意 expiry == 0xFFFF 特判为永不过期
6. flow_id / function_id 作用域: 非通配则查 flow_scope_table
7. context 轮次: if (label.context_id != reg_rseq || reg_rseq == 0) → 丢
               ★ `reg_rseq == 0` 的守卫堵住「交换机从未上报时 context_id=0
                 的标签被接受」（D21 的残留风险，2026-10-17 补进 P4）。
7b. 在途跨越:  if (当前 sm 副本.pending == 1) → 丢
               （冷却期内或上报包无法到达服务器时，有尚未发出的新跨越
                 → 服务器手里的 context 已过期）
8. 全部通过 → 写标签缓存, REPORTED/STALE → ARMED
```

### ★ 默认安全动作

> 在 `REPORTED` / `STALE` 态（标签缺失、过期、被拒），交换机执行 `function_id = NOOP`，即**退回到没有任何网络内处理的正常转发**。

注意这不是"退回到某个保守的网络内处理"，而是**完全等同于部署前的行为**。标签非法时系统行为与未部署本协议时逐比特一致 —— 这对论文的安全性论证很重要，且**由状态机强制，不是靠默认表项**。

---

## 3. 交换机侧状态机

### 3.1 状态定义

| 值 | 名称 | 语义 |
|---|---|---|
| `0` | `IDLE` | 无有效标签，正常转发，监控跨越 |
| `1` | `REPORTED` | 报告已发，等标签。★ **只做正常转发** |
| `2` | `ARMED` | 标签有效。执行 function |
| `3` | `STALE` | 标签过期但未收到新标签。★ **等同 REPORTED** |

> **`ARMED` 是唯一会执行 function 的状态。**

### 3.2 状态转移表

| 当前 | 事件 | 次态 | 动作 |
|---|---|---|---|
| `IDLE` | ctx 跨越 且 冷却已过 | `REPORTED` | 发报告，`context_id += 1`，更新 context 快照，置冷却 |
| `IDLE` | 跨越但冷却未过 | `IDLE` | 置 `STORM_SUPPRESSED` / `pending`，不发 |
| `IDLE` | 收到合法标签 | `ARMED` | 写标签，丢标签包 |
| `REPORTED` | 收到合法标签 | `ARMED` | 写标签，丢标签包 |
| `REPORTED` | 收到非法/过期/乱序/轮次不符标签 | `REPORTED` | 丢弃，**保持静默** |
| `REPORTED` | ctx **再次**跨越 且 冷却已过 | `REPORTED` | ★ **必须重报**：在途的旧轮次标签已作废 |
| `REPORTED` | 超时（1 s 心跳） | `REPORTED` | 重传**同一** `context_id` 的报告（不增加披露） |
| `ARMED` | 每包查 deadline 未过期 | `ARMED` | 执行 function |
| `ARMED` | deadline 到期 | `STALE` | 停止 function |
| `ARMED` / `STALE` | ctx 跨越 | `REPORTED` | ★ **标签立即失效**，发新报告 |
| `ARMED` | 收到新标签 | `ARMED` | 覆盖缓存 |
| `STALE` | 收到合法标签 | `ARMED` | 恢复 |
| 任意 | `LABEL_REVOKE` | `IDLE` | 清标签缓存 |

> ★ **多流补充规则（D24，2026-10-17）**：`context_id` 是**全局**轮次号，
> 任何一条流的跨越都会让所有流的缓存标签失效（`arm_gen` 在离开 ARMED 时 +1）。
> 而 `ctx_report_t` 只携带**承载本次报告的包**的 `flow_id`。
> 因此服务器在收到新轮次后，必须对它已知的所有受控流**批量重签**标签
> （动作可以原样不变，只换 `context_id`）；否则未触发上报的流会永久停在
> 未武装态。Week1 的服务器 agent 必须维护 flow 列表，不能只回应当前报告的流。

### 3.3 寄存器设计

**核心约束（TNA）**：一个 `Register` 每包只能执行一次 `RegisterAction`；且**同一个 extern 实例不能被 Ingress 和 Egress 共用**。

**设计原则**（建议直接写进论文方法论）：

> - 凡是"每包都用、且每包都变"的量 → **不放寄存器，放进包头**
> - 凡是"每包都用、但变化慢"的量 → **放寄存器，每包读一次**
> - 凡是"只在特定事件才变"的量 → **放寄存器，只在那个事件写**

**★ 每个寄存器每包最多访问一次**（约束①）。v0.3 删掉了 `reg_report_ctx`
（上报不再带 `metric_id`，`last_metric` 失去用途），数据面访问从 10 次降到 **8 次**。

| 寄存器 | 类型 | 基数 | 数据面每包 | 标签面每包 | 用途 |
|---|---|---|---|---|---|
| `reg_cfg` | `bit<32>` | 1 | 读一次 | — | 四个 8 位字段：三个阈值 + `path_avail`（控制面写，D28 字节对齐） |
| `reg_rseq` | `bit<32>` | 1 | **RMW**（旧值 + `inc_ctx`） | 读一次 | 全局 context 轮次计数器 |
| `reg_sm_a` / `reg_sm_b` | `bit<32>` | 各 1 | 读一副本 + 写另一副本 | 读一副本 + 写另一副本 | 全局状态机（一位一态）+ pending + arm_gen + cooldown |
| `reg_par_sm` | `bit<32>` | 1 | RMW（+1） | RMW（+1） | 状态双副本相位（最低位） |
| `reg_ctx_last` | `bit<32>` | 16 | **单次 RMW** | — | 每流：上次判决 + 上次三等级快照 |
| `reg_label` | `bit<32>` | 16 | 读一次 | 写一次 | 每流：动作标签缓存 |
| `reg_label_flow` | `bit<32>` | 16 | 读一次 | 写一次 | 每流：标签携带的完整 `flow_id`（D24） |
| `reg_epoch_a` / `reg_epoch_b` | `bit<32>` | 各 16 | — | 读一副本 + 写另一副本 | 每流：上次 epoch（防重放） |
| `reg_seq_a` / `reg_seq_b` | `bit<32>` | 各 16 | — | 读一副本 + 写另一副本 | 每流：上次 sequence（防重放） |
| `reg_par_lbl` | `bit<32>` | 16 | — | RMW（+1） | 每流 epoch/seq 双副本相位 |

> ★ **D23（2026-10-17）为什么改成乒乓双副本**：D19 实测表明「同一物理寄存器同包
> 内读动作 + 写动作」会报 `Table placement cannot make any more progress`。
> 现在每个包只访问相位指向的**当前副本**，把新值写到**另一副本**；每个物理寄存器
> 每包最多被一个 `RegisterAction` 访问，读写不再落在同一条依赖链上。
> 所有判断和状态机仍在 `apply()` 里（无 sALU 的比较/局部变量限制）。
>
> **P4 里不再出现直接 `reg.write()`**（控制面写入除外）：所有写都走 RegisterAction。
> 相位寄存器本身是单次 RMW（`v = v + 1`），0 次比较。

> **统计量不上寄存器**。报告数 / 接受数 / 拒绝数在服务器侧统计；
> 硬件上若需要就走 `Counter` extern（Stats ALU，不占 SALU 预算）。
> P4 里**不声明**这类寄存器 —— 一旦声明就会多出访问次数。

#### ★ 宽度硬约束（D12）

TNA 的 sALU 只做 **8 / 16 / 32 位**运算，寄存器 entry 只能是：

- `bit<8>` / `bit<16>` / `bit<32>` 标量，或
- `pair32_t` —— **恰好两个** `bit<32>` 字段的 struct

宽于 32 位的单字 entry 会让 bf-p4c 直接报
`Wide operations not supported in stateful alu`。并且：

> **任何字段都不得横跨 bit31 / bit32 分界** —— 跨字的切片 sALU 做不了。

这两条由 D12 记录；离线一致性检查已于 2026-10-17 删除，现靠 `bf-p4c` 编译与上机 dump 把关。

**位布局**（全部 `bit<32>` 单字；偏移是**给文档和 Python 看**的，P4 里用 `headers.p4` 的 `*_SHIFT` 常量）：

```
reg_sm_a / reg_sm_b   （bit<32>，各一格；D23 乒乓双副本）
      两个副本**布局相同**；每包只读相位指向的当前副本、只写另一副本
      bit3..0     state              一位一态：IDLE=1 REPORTED=2 ARMED=4 STALE=8
      bit4        pending_report     被冷却抑制、待补发的标记
      bit8..5     arm_gen            arm 世代号（D9）
      bit24..9    cooldown           16 bit 冷却截止（相对 tick，有符号差值比较）
      bit31..25   reserved

reg_par_sm        （bit<32>，全局一格）
      bit0        相位               0 = A 是当前副本，1 = B；每处理一个相关包 +1
      bit31..1    reserved

reg_rseq          （bit<32>）
      bit31..0    context_id         ★ 上下文轮次计数器（v0.3 起用满 32 位）

reg_cfg           （bit<32>，★ v0.4/D28 起按字节对齐：每字段 8 位）
      bit0..7     th_queue           ★ 等级阈值（0..15；≥16 = 永不判违规）
      bit8..15    th_load            ★ 同上
      bit16..23   th_path            ★ 同上
      bit24..31   path_avail         控制面写入的路径可用性等级（0..15）
      ── 旧布局 bit0..4 / bit5..9 / bit10..14 / bit15..18 已废弃 ──
      （Tofino PHV 切片是字节粒度的，非字节对齐字段会被切成跨字节碎片，
        直接导致 PHV 分配失败；详见 md/02 D28）

reg_ctx_last      （bit<32>，每流一格）
      bit2..0     verdict            本次三个指标是否违规（1 = 不符合要求）
      bit3        init               本流槽位已初始化（防冷启动误报）
      bit7..4     queue_level        本次快照的队列等级
      bit11..8    load_level         本次快照的负载等级
      bit15..12   path_level         本次快照的路径等级
      bit31..16   reserved

reg_label         （bit<32>，每流一格）
      bit3..0     function_id        执行哪个动作（0 = NOOP）
      bit7..4     priority           ★ 只有 4 位；超出的标签直接拒收，不静默截断
      bit23..8    deadline           接收时算一次（见 R1）
      bit24       valid
      bit28..25   arm_gen            签发时的 arm 世代号（D9）
      bit31..29   reserved

reg_label_flow    （bit<32>，每流一格）
      bit15..0    标签携带的完整 flow_id（执行前要求与本包 flow_id 精确相等）
      bit31..16   reserved

reg_epoch_a / reg_epoch_b（bit<32>，每流一格；D23 乒乓双副本）
      bit7..0     epoch              上次 epoch

reg_seq_a / reg_seq_b    （bit<32>，每流一格；D23 乒乓双副本）
      bit31..0    sequence           上次 sequence

reg_par_lbl       （bit<32>，每流一格）
      bit0        相位               0 = A 是当前副本，1 = B；每收到一个相关标签 +1
      bit31..1    reserved
```

> **`reg_label` 里没有 `queue_id` / `action_id` / `egress_port`**。它们属于 Week2 的
> `PORT_REDIRECT` 与审计；缓存它们会把 32 位顶爆。Week2 做 ingress 侧时单独设计。
>
> **也没有 `context_id`** —— 上下文绑定在**标签接收时**校验一次即可；
> 此后任何 ctx 跨越都会让标签立即失效转入 `REPORTED`（见 3.2 转移表）。

**数据面每包的处理顺序**（D23 起）：

```
1. cfg   = reg_cfg.read()                     → 阈值, path_avail             [1]
2. label = reg_label[slot].read()             → function_id / priority / deadline [1]
   llf   = reg_label_flow[slot].read()        → 标签的完整 flow_id           [1]
3. 三路等级 ← range table 量化                  ← 零寄存器访问
4. expired = is_expired(now, deadline)                 ← 纯运算
5. report_dst.apply()                          → 本包能否承载上报（纯表，不占寄存器）
6. par_sm = reg_par_sm.RMW(+1)                 → 旧相位                        [1]
   smv    = 读相位指向的 sm 副本                → 状态机全部输入                 [1]
7. cout  = reg_ctx_last[slot].RMW(本次快照)     → 上次判决 + 上次快照             [1]
8. 状态机整体在 apply() 里算（无 sALU 限制）
9. 把新状态字写进**另一** sm 副本                → 次态 + pending + arm_gen + 冷却 [1]
10. rseq = reg_rseq.RMW(旧值 + inc_ctx)         → 新轮次号                       [1]
11. 依据 state_after 决定动作（纯运算，不再访问寄存器）
```

**标签面每包的处理顺序**（D23 起；顺序**不可调换**）：

```
1..6  switch_id → msg_type → function 白名单 → priority 宽度
      → flow 作用域 → expiry
      ★ 这 6 步全是纯运算或只读。只要有一项失败，**一个寄存器都不碰**。
7. rseq  = reg_rseq.read()                      → 当前轮次号                    [1]
8. par_sm = reg_par_sm.RMW(+1) → 读当前 sm 副本  → pending / arm_gen             [1 RMW + 1 读]
   ⑦ context 轮次：label.context_id == rseq 且 rseq != 0 且 pending == 0
   ⑦ 失败 → 跳过 9~11，直接到 12（只把旧状态字原样复制到另一副本）
9. ctx 通过后：par_lbl = reg_par_lbl[slot].RMW(+1) → 读当前 epoch / seq 副本      [1 RMW + 2 读]
10. 算下一组 epoch/seq；**无论接受与否都写另一副本**（保持乒乓一致）                [2 写]
11. 接受时：写 reg_label + reg_label_flow，sm_next = ARMED                         [2 写]
12. 无条件把 sm_next 写进另一 sm 副本（拒绝时就是原样复制）                        [1 写]
```

> ★ **为什么第 8 步开始就必须「读一副本、写另一副本」**：相位寄存器一翻转，
> 下一个相关包就会读另一副本；如果本包只读不写，两份副本就会错位。
> 所以标签路径在 ctx 校验失败时也要把旧状态字原样复制到另一副本。
>
> ★ **第 10 步永远写**：即使 sequence 校验失败，也要把旧 epoch/seq 写进另一副本；
> 只有**接受**时才把新值写进去。这同时修复了 v0.3 中「同 epoch 接受后漏写
> `reg_seq`」的防重放漏洞（任务 #17）。
>
> ★ **第 11 步之前不写任何会改变语义的寄存器**：一个过期、ctx 不符或重放的标签
> 不会写标签缓存、不会转 ARMED。唯一会变的是「另一副本里的原值」和相位。

> ★ **第 8 步必须在第 9 步之前**（D15）。第 9 步一旦执行就**必然**改状态；
> 若它排在前面，一条「重放 / epoch 回退」的标签会先把交换机推进 `ARMED`
> 再被拒绝 —— 凭空进入「已武装」态，而根本没有任何合法标签。
> 而且它**不留痕迹**：`accepted=False` 看起来一切正常，只有 `state` 悄悄变了。
> 对应 P4 里的顺序必须是：**ctx 校验 → 判 epoch/seq → 写 epoch/seq 另一副本 →
> 才写 sm 另一副本**；写 sm 永远是标签路径的最后一步。

**★ `meta.state_after` 里带的是处理后的状态，不是处理前的**：状态机在 `apply()`
里算完后得到 `state_after` 并写进 `meta.sm_next`，动作决策基于它。若本包导致
`ARMED→STALE`，`state_after` 就不是 `ARMED`，动作自然不执行 —— 比「拿旧状态
再单配一个 `expired` 判断」更不容易写错。处理前的状态不需要带出：`arm_gen` 的
+1 在 `apply()` 里算，`out_v` 只负责端出当前副本的原字。

**★ 为什么这样切分能省掉第二遍**：

| 需求 | 朴素做法（要跑两遍） | 本设计 |
|---|---|---|
| 读队列深度 + 判断跨越 | 寄存器读两次 | 深度在 egress 直接读，寄存器只读一次 |
| 状态转移 + 计数器递增 | 同一个寄存器上读-算-写 | **D23 乒乓**：读当前副本、写另一副本，都是 RegisterAction |
| 写标签 + 清状态 | 跨 block 冲突 | 标签包走独立代码路径，不与数据包冲突 |

> **Week1 的 P4 程序里不出现 `resubmit`** —— 不是因为危险（它回本 pipe，是安全的），
> 而是因为**没必要**：同包读-改-写用 D23 的乒乓双副本就解决了，不需要第二遍流水线。
> 会被它救回来的是 `bypass_egress` + `RECIRC_PORT` 那种跨 pipe 写法，本设计不用。
>
> ⚠️ 注意：D23 的代价是**寄存器数量翻倍**（7 → 13 块），换来的是每个物理寄存器
> 每包最多被一个 `RegisterAction` 访问。**不要**为了省寄存器把 A/B 合回一块 ——
> 那会直接撞回 `Table placement cannot make any more progress`（D19 已实测）。

**降级路径**：若上机后发现某寄存器确实需要同包两次访问，**先试"加一个并行寄存器做影子"**
（D23 就是这条路的系统化版本），再考虑 Resubmit。例如若要额外记一份「本流上一次的
ctx」，用第二个寄存器而非把 `reg_ctx_last` 加宽 —— 因为 sALU 的 `out_v` 只能输出一个值。
**两条路都可行，Resubmit 那条不危险，只是多一次 pipeline 往返。**

### 3.4 三个指标

| 指标 | 来源 | 量化 |
|---|---|---|
| `QUEUE_CONGEST` | **egress** `deq_qdepth`（19 bit，字段名待编译期验证）→ range table 量化到 `queue_level 0..15` | 真数据面测量 |
| `PORT_LOAD` | **egress** `deq_timedelta`（⚠️ **入队→出队排队时延**，非相邻出队间隔）→ range table 量化到 `load_level 0..15`（时延越大 = 负载越高；**当前实现方向待修正**，见下方警告） | 真数据面测量（per-queue 代理；多队列共端口时是近似） |
| `PATH_AVAIL` | **控制面**写入的 `reg_cfg[31:24]`（D28） | ⚠️ 控制面建模，非数据面测量，论文需注明 |

> ★ v0.3 起 `PORT_LOAD` **不再**用 `deq_congest_stat`：它是 `bit<2>` 的队列拥塞状态，
> 与 `QUEUE_CONGEST` 回答的是同一类问题，而且不是"单位时间的包数量"。

> ⚠️ **待修复缺陷（2026-10-24 实测）**：`deq_timedelta` 的真实语义是
> **「入队→出队」的排队时延（ns）**，不是「相邻出队间隔」
> （`tofino1_base.p4:255` 原注释）。当前 `quantize_load` 仍按「间隔越短 = 负载越高」
> 写成降序，导致**空闲时 `load_level=15`（最高负载）**，实测上报 `l=15` 即证据。
> 修正方案：反转桶方向（`0..99→0` … `50000+→15`），同步本节与
> `p4/min_disc.p4` 后重编译。**在修复前，`load_level` 不可用。**

> `PATH_AVAIL` 用控制面建模的原因：单台交换机看不到备用路径，数据面无法直接测量。Week1 由 `bfrt_python` 写入（见 `03-tna-verify-checklist.md` V5）。

---

## 4. 字段长度变更记录

协议一旦上机验证，变更需同步更新：本文件 → `proto/constants.py` → `p4/include/headers.p4` → 在交换机上编译 `min_disc.p4`。

| 版本 | 日期 | 变更 |
|---|---|---|
| v0.1 | 2026-09-23 | 初版。两个协议各 24 字节 |
| v0.2 | 2026-10-07 | **寄存器重排到 sALU 宽度约束内**（D12/D13/D14）：`reg_sm`/`reg_label_seq` 改 `pair32_t`，`reg_cfg`/`reg_label` 降到 32 位，阈值降到 5 位，`report_seq` 寄存器里只存 16 位，`reg_label` 去掉 `queue_id`/`action_id`。**协议字段（§1/§2）与包长零改动。** |
| v0.3 | 2026-10-17 | **按课题文档对齐语义**：① `context_id` 从"4 位等级"改为"32 位轮次计数器"，删除 `ctx_tolerance`；② `ctx_report_t` 改为携带三路等级（`queue_level`/`load_level`/`path_level`），`report_seq` 改名 `context_id`；③ `PORT_LOAD` 改用 `deq_timedelta`；④ `action_label_t` 增加 `egress_port`，移除 `queue_id`/`rate_kbps`，`QUEUE_REDIRECT` 改名 `PORT_REDIRECT`；⑤ `REPORTED` 态改为冷却限速上报（不再是"一报封死"）；⑥ 删除 `reg_report_ctx`，数据面访问 10 → 8 次；⑦ `reg_rseq` 用满 32 位。**两个包头仍为 24 字节。** |
| v0.4-rev1 | 2026-10-24 | **寄存器/PHV 字段字节对齐**（D28）：`reg_cfg` 改 4×8 位（`[7:0]`/`[15:8]`/`[23:16]`/`[31:24]`），阈值与三指标差值一律 8 位；**线格式零改动**（包长仍 14 / 24 字节）。 |
| v0.4 | 2026-10-23 | **D28 压缩 `ctx_report_t` 24 → 14 字节**：删除 `switch_id`/`port_id`/`diag_value`/`diag_metric`/`crc16`/`_pad`，`timestamp` 32 → 16 位（tick）；`DIAG_PRESENT` 停用、DIAG 消息类型停用。动机：egress PHV 分配吃紧导致上机编译失败 + 常量字段本就不承载信息。`action_label_t` 不变，仍 24 字节。 |
| v0.3-rev2 | 2026-10-17 | **只改交换机内部实现，线格式零改动**（D23/D24）：① 状态/epoch/sequence 改乒乓双副本 + 相位寄存器，所有写走 RegisterAction，消除 D19 的「同寄存器依赖式读+写」；② 槽位 8→16，新增 `reg_label_flow` 存完整 flow_id，执行前比对；③ 标签接受后总是推进 `reg_seq`（修防重放漏写）；④ 增加 `rseq != 0` 守卫；⑤ 新增 `report_dst` 表，上报只能搭在发往服务器的包上；⑥ 服务器必须对已知全部流批量重签。**两个包头仍为 24 字节。** |
