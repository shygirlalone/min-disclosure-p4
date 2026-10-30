#ifndef _MIN_DISC_HEADERS_
#define _MIN_DISC_HEADERS_

#include <core.p4>
#include <tna.p4>

/*************************************************************************
 *  min-disclosure 包头 / 常量 / metadata
 *
 *  ⚠️ 本文件是 proto/constants.py 的 P4 镜像。两侧字段顺序、位宽必须逐位一致。
 *     改任何一侧都要同步另一侧。
 *
 *  验证手段：在交换机上用 bf-p4c 编译 min_disc.p4（强校验语法/位宽/字段名），
 *  再打流 + 抓包逐字节比对（见 md/03）。离线一致性检查已于 2026-10-17 删除（D22）。
 *
 *  ★ 2026-10-17 简化：放弃显式 4 态状态机与乒乓双副本，改成「每流版本失效」。
 *     - 没有 reg_sm / reg_par_sm / reg_epoch / reg_seq / reg_par_lbl。
 *     - 每个逻辑量只有一个物理寄存器，一个包最多访问它一次。
 *     - 标签是否有效 = 标签里的 context_id 等于该流当前 version。
 *     - 是否需要上报 = 本次跨越产生了新 version，且该 version 还没上过报。
 *************************************************************************/

// ==================== EtherType ====================
// 沿用 INT 项目 0x8888/0x7777/0x6666 的风格扩展，互不冲突
const bit<16> TYPE_IPV4         = 0x0800;
const bit<16> TYPE_CTX_REPORT   = 0x5555;   // 交换机 -> 服务器，其后必然是 IPv4
const bit<16> TYPE_ACTION_LABEL = 0x4444;   // 服务器 -> 交换机，收到后丢弃

const bit<8>  PROTO_TCP = 6;

// ==================== 版本 / msg_type ====================
const bit<4>  PROTO_VERSION = 1;

const bit<4>  MSG_CTX_REPORT      = 1;
const bit<4>  MSG_CTX_REPORT_DIAG = 2;

const bit<4>  MSG_ACTION_LABEL    = 1;
const bit<4>  MSG_LABEL_REVOKE    = 2;
const bit<4>  MSG_LABEL_HEARTBEAT = 3;   // Week1 不处理心跳

// ★ v0.3 起 ctx_report_t 不再携带 metric_id：一条报告固定带三路等级快照，
//   位置本身即含义。P4 侧不再需要 METRIC_* 常量。

// ==================== function_id ====================
const bit<8>  FUNC_NOOP           = 0;   // 默认安全动作：纯转发
const bit<8>  FUNC_RATE_LIMIT     = 1;   // 保留：v0.3 无速率参数字段，标签阶段拒收
const bit<8>  FUNC_PRIORITY_SET   = 2;   // Week2 / ingress
const bit<8>  FUNC_PORT_REDIRECT  = 3;   // Week2 / ingress（v0.3 前叫 QUEUE_REDIRECT）
const bit<8>  FUNC_ECN_MARK       = 4;
const bit<8>  FUNC_DROP           = 5;
const bit<8>  FUNC_MEASURE        = 6;   // Week2 / ingress：cm-sketch，action_id 选 sketch
const bit<8>  FUNC_WILDCARD       = 8w0xFF;

// ==================== 时间（沿用 INT 项目的 tick 约定）====================
// tick = global_tstamp[31:16]，1 tick = 65536ns ≈ 65.536us
// 换算：目标毫秒 * 15.259 = ticks
// ⚠️ 16-bit tick 每 4.2949 秒回绕一次，所有时间比较必须用有符号差值。
// ★ 简化版不再有 cooldown / 1s 重发定时器，因此不再需要 COOLDOWN_TICKS。

// ==================== 特殊值 ====================
// ★ 2026-10-17 简化：「永不过期」不再用 deadline==0 表示，改用
//   reg_label 的 LBL_NEVER_BIT（见下）。删除了 DEADLINE_NEVER 常量。
const bit<16> FLOW_ID_WILDCARD    = 16w0xFFFF;
const bit<8>  DIAG_METRIC_INVALID = 8w0xFF;

/*************************************************************************
 *  寄存器位布局
 *
 *  ★ TNA 硬约束（见 md/02-design-decisions.md D12）：
 *      sALU 的运算宽度只有 8 / 16 / 32 位，寄存器 entry 只能是
 *      bit<8> / bit<16> / bit<32>（宽于 32 位会报
 *      `Wide operations not supported in stateful alu`）。
 *      ★ D19 起本设计**只用 bit<32> 单字寄存器**，一个 pair 都不留。
 *
 *  ★ 2026-10-22（D26）后 egress 一共 7 个寄存器：
 *      reg_cfg[1]          阈值 + path_avail（控制面写）
 *      reg_ctx_last[16]    每流：上次判决（低 3 位，单次 RMW）
 *      reg_ver[16]         每流：当前上下文版本（单次 RMW，跨越时 +1）
 *      reg_rep_ver[16]     每流：最近一次随包上报的版本（每包一次 RMW，
 *                          RegisterAction 内部只在 can_report=1 时写）
 *      reg_label[16]       每流：function_id + valid/never
 *      reg_label_dl[16]    每流：deadline（S1 从 reg_label 拆出，避免拼字链）
 *      reg_label_flow[16]  每流：完整 flow_id + 标签签发时的版本
 *
 *  ★ 寄存器索引不直接使用计算出的 flow_id：先由 slot_map 表产出
 *    meta.slot（见 min_disc.p4），否则 bf-p4c 报 `The index is too complex`。
 *
 *  每个物理寄存器在一个包里最多被一个 RegisterAction 访问：
 *    - 数据面：ctx_last / ver / rep_ver 各自一次 RMW；
 *      label / label_dl / label_flow 各一次只读；cfg 一次只读。
 *    - 标签面：ver 一次只读；label / label_dl / label_flow 各一次只写。
 *  不再有 A/B 副本，也不再有相位寄存器。
 *
 *  ★ 2026-10-17 第二批简化（编译减负）：
 *    - reg_ctx_last 只存 3 位判决，三等级快照只写不读，已删除；
 *      init 位也删除 —— 初值 0 就是「上次无违规」。
 *    - （D27 更正）永不过期不再用 bit25 标志：协议值 0xFFFF 在写入前
 *      折算成 0x7FFF（≈2.147 s 上界），valid 位 bit24 折进功能白名单的
 *      常量字。标签字组装不再需要 `0 - flag` / `~` / `&` 的掩码链。
 *************************************************************************/

// ==================== reg_cfg：32 位单字 ====================
// ★ v0.4 / D28 起按字节对齐（PHV 切片是字节粒度）：
//   [7:0] th_queue / [15:8] th_load / [23:16] th_path / [31:24] path_avail
//   阈值是等级阈值（0..15 尺度）；取 16 = 该指标永不判违规
const bit<8>  CFG_TH_QUEUE_SHIFT    = 0;    // bit7..0
const bit<8>  CFG_TH_LOAD_SHIFT     = 8;    // bit15..8
const bit<8>  CFG_TH_PATH_SHIFT     = 16;   // bit23..16
const bit<8>  CFG_TH_DISABLED       = 16;   // 8 位字段里的「永不违规」
const bit<8>  CFG_PATH_AVAIL_SHIFT  = 24;   // bit31..24

// ==================== reg_ctx_last：32 位单字（只用低 3 位）====================
//   bit2..0    上次三个指标的**判决**（bit0=Q / bit1=L / bit2=P，1 = 当时不符合要求）
//   bit31..3   ★ 未用
//   ★ 2026-10-17 简化：三等级快照在数据面从没读过（上报用的是本包量化值），
//     整段删除；init 位也删除 —— 寄存器初值 0 即「上次无违规」，
//     首次判决非 0 时自然算作跨越。不再需要 `0 - init` 广播技巧。

// ==================== reg_ver / reg_rep_ver：32 位单字 ====================
// ★ 版本号用满 32 位，每发生一次「判决翻转」就 +1，不在每次上报时 +1。
//   这样上下文一变，旧标签立即失效，与「报告有没有发出去」解耦。
//   标签里的 context_id 必须与 reg_ver 精确相等。
//
//   reg_rep_ver 记录「最近一次真正搭在去服务器的包上发出去的版本」。
//   只有 can_report=1 的包才会更新它，因此没发出去的上报不会把版本吞掉。
const bit<8>  VER_VALUE_SHIFT       = 0;    // bit0..31

// ==================== reg_label：32 位单字 ====================
// ★ Week1 只缓存执行路径会用的字段（见 D14）。
//   action_id / egress_port 属于 WEEK1 白名单外的功能，不进缓存。
//   ★ 简化版删除了 arm_gen；bit26..31 未用。
// ★ 2026-10-23（D27）最终布局：deadline 在 reg_label_dl，flow 在
//   reg_label_flow，context_id 在 reg_label 的低 16 位：
//
//   bit3..0    function_id（由 label_func 表常量给出）
//   bit19..16  function_id（数据面读出的位置，供 exec_decide 用）
//   bit24      valid
//   bit15..0   context_id 低 16 位（cached_ver）
//
//   写入 = 「常量 | context_id」，一次或；never 不再占位（expiry 0xFFFF
//   在表里折算成 0x7FFF）。三张标签寄存器全部零/一次运算写入。
const bit<8>  LBL_FUNC_SHIFT      = 16;   // bit16..19
const bit<8>  LBL_VALID_BIT       = 24;   // bit24
const bit<8>  LBL_CTX_SHIFT       = 0;    // bit0..15：context_id 低 16 位

// ==================== reg_label_flow：32 位单字，每流一格 ====================
// ★ 低 16 位：标签携带的**完整 flow_id**（D27 起不再与版本合并在一个寄存器）。
//   数据面执行动作前要求：
//      ① reg_label_flow[slot][15:0] == 本包 flow_id
//      ② reg_label[slot][15:0]     == reg_ver[slot][15:0]
//   ① 堵住槽位冲突串流；② 堵住「上下文已变但旧标签还没被覆盖」的执行。
//   ⚠️ cached_ver 只有 16 位，版本在 65536 次跨越后回绕；实验中跨越次数很少，
//      可接受。Week2 如果要求严格，可拆出独立的 32 位 cached_ver 寄存器。
const bit<8>  LBLFLOW_FLOW_SHIFT  = 0;    // bit0..15：完整 flow_id

//: priority 的寄存器缓存只有 4 位，超过这个值的标签直接拒收（不静默截断）
const bit<8>  PRIORITY_MAX = 15;

// ==================== Week2：ingress 侧动作缓存（D25）====================
// ★ ingress 读不到 egress 的 reg_ver，也不能与 egress 共用任何 Register。
//   标签包同时流经两个 block：ingress 落自己的一份缓存、egress 落 Week1 那份。
//   ingress 的 context 绑定 = 单调 context_id（reg_ing_ctx，S4 引入）+ 标签 expiry。
//
//   reg_ing_lbl[16]   每流：function_id + valid（常量整字）
//   reg_ing_dl[16]    每流：deadline（接收时算一次，低 16 位）
//   reg_ing_flow[16]  每流：完整 flow_id（低 16 位）
//   reg_ing_port[16]  每流：egress_port（低 8 位，D27 拆出）
//   reg_ing_ctx[16]   每流：最后接受的 context_id（S4 引入）
//
// reg_ing_lbl 位布局（与 egress 的 reg_label 布局不同，互不相干）：
//   bit3..0    function_id
//   bit24      valid
//   bit31..4   未用（priority 到 S2、action_id 到 S3 再放，均另开寄存器）
//
// ★ 2026-10-22 首次上机编译后简化（见 md/02 D26）：
//   ingress 的 stage/ALU 预算比 egress 紧。这里让 function 白名单表的
//   常量字**自带 valid 位**（0x01000000 | function_id），写寄存器时不需要
//   任何拼字运算；never 也不再单独存位，expiry==0xFFFF 由表改写成
//   0x7FFF（≈2.147 s 的上界）。
const bit<8>  ING_LBL_FUNC_SHIFT   = 0;
const bit<8>  ING_LBL_VALID_BIT    = 24;

// expiry == 0xFFFF（协议里的「永不过期」）在 ingress 侧折算成这个上下界。
// ★ 这是 S1 的已知限制：ingress 动作本来就按 50–100 ms 短有效期签发，
//   永远不过期只作为协议保留值；精确无穷语义只由 egress 的 never 位承担。
const bit<16> ING_NEVER_EXPIRY    = 16w0x7FFF;

// reg_ing_flow / reg_ing_port 位布局（D27）：
//   reg_ing_flow 低 16 位 = flow_id（防槽位串流）
//   reg_ing_port 低 8 位  = egress_port（PORT_REDIRECT 的目标端口）
//   ★ 拆成两个寄存器后两个写入都是纯零扩展，0 次 ALU 运算。
const bit<8>  ING_FLOW_FLOW_SHIFT  = 0;   // bit0..15：flow_id
const bit<8>  ING_PORT_SHIFT       = 0;   // bit0..7：egress_port

/*************************************************************************
 *  H E A D E R S
 *************************************************************************/

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<3>  res;
    bit<3>  ecn;
    bit<6>  ctrl;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

// ---- ctx_report_t：交换机 -> 服务器，固定 24 字节 ----
// ⚠️ 字段顺序必须与 proto/ctx_report.py 的 BitWriter 调用顺序逐项一致
// ★ v0.4（D28，2026-10-23）压缩：24 -> 14 字节。
//   删除 switch_id / port_id / diag_value / diag_metric / crc16 / _pad，
//   timestamp 32 -> 16 位（tick）。原因见 md/01 §1：egress PHV 分配吃紧，
//   且这些字段在 Week1 恒为 0、不承载信息。
header ctx_report_t {
    bit<4>  version;       // 与 msg_type 共用一个字节
    bit<4>  msg_type;
    bit<8>  flags;
    bit<16> flow_id;       // ★ D27：控制面按五元组下发；0xFFFF = 未登记
    bit<4>  queue_level;   // 队列拥塞等级 0..15
    bit<4>  load_level;    // 端口负载等级 0..15
    bit<4>  path_level;    // 路径可用等级 0..15
    bit<4>  _rsv0;
    bit<32> context_id;    // ★ 每流上下文版本，服务器原样回填
    bit<16> timestamp;     // global_tstamp[31:16]（tick，4.295 s 回绕）
    bit<16> _rsv1;
}

// ---- action_label_t：服务器 -> 交换机，固定 24 字节 ----
// ⚠️ 字段顺序必须与 proto/action_label.py 的 BitWriter 调用顺序逐项一致
header action_label_t {
    bit<4>  version;
    bit<4>  msg_type;
    bit<8>  flags;
    bit<8>  switch_id;
    bit<8>  epoch;         // ★ Week1 不校验（保留线格式）
    bit<16> flow_id;
    bit<8>  function_id;
    bit<32> context_id;    // ★ 必须等于该流当前 reg_ver
    bit<8>  action_id;
    bit<8>  priority;      // 队列优先级 0..7；寄存器只存 4 位，>15 拒收
    bit<8>  egress_port;   // PORT_REDIRECT 目标端口（Week2）
    bit<16> _rsv0;
    bit<32> sequence;      // ★ Week1 不校验（保留线格式）
    bit<16> expiry;        // 相对偏移；0xFFFF = 永不过期
    bit<16> crc16;         // ★ P4 侧不校验
}

struct headers {
    ethernet_t     ethernet;
    ctx_report_t   ctx_report;
    ipv4_t         ipv4;
    tcp_t          tcp;
    action_label_t action_label;
}

/*************************************************************************
 *  M E T A D A T A
 *************************************************************************/

struct metadata {
    // ---- 时间 ----
    // ★ D28：删除 tstamp（48 bit）。它只被赋值、从未被读，却让 global_tstamp
    //   在整个 egress 里保持活跃，是 PHV 分配失败的直接诱因。
    bit<16> now_tick;          // global_tstamp[31:16]

    // ---- 控制面配置（从 reg_cfg 读出）----
    // ★ 等级阈值（0..15 尺度），不是原始队列长度。8 位：0..15 是有效阈值，
    //   ≥16 表示「该指标永不判违规」（ctx 最大只有 15）。
    // ★ D28：从 bit<5> 改成 bit<8>，且 reg_cfg 按字节对齐下标 —— Tofino 的
    //   PHV 切片是字节粒度的，5 位错位字段会被切成 [4:4]/[3:0] 这类碎片，
    //   和 cfg_0 的错位片一起打包时直接分配失败（17 个切片无家可归）。
    bit<8>  th_queue;          // cfg[7:0]
    bit<8>  th_load;           // cfg[15:8]
    bit<8>  th_path;           // cfg[23:16]
    bit<8>  path_avail;        // cfg[31:24]，控制面写入的路径可用等级（越大越好）

    // ---- 本包所属流 ----
    // ★ D27：flow_id 与 slot 都由控制面下发的表给出（数据面零异或）。
    //   数据面查 flow_key / flow_key_ing（五元组 → flow_id, slot），
    //   标签面查 slot_map_lbl / slot_map_ing_lbl（flow_id → slot）。
    //   bf-p4c 不接受计算值直接当寄存器索引（`The index is too complex`），
    //   表输出的 PHV 是简单索引 —— 这条约束因此自然满足。
    bit<16> flow_id;           // 控制面下发的流标识（0xFFFF = 未登记）
    bit<8>  slot;              // 表输出，0..15（16 个槽位）

    // ---- 三个指标的量化等级（range table 产出，不占寄存器访问）----
    // ★ D28：统一成 bit<8>。表动作参数仍是 bit<4>（等级本身只有 0..15），
    //   赋值零扩展；这样 dq/dl/dp 的减法两端都是字节对齐字段，
    //   PHV 切片不会再被劈成 [4:4]/[3:0] 碎片。
    bit<8>  ctx_queue;
    bit<8>  ctx_load;
    bit<8>  ctx_path;

    // ---- 本次判决（apply() 里算好，再交给寄存器）----
    bit<3>  verdict_now;       // bit0=Q / bit1=L / bit2=P
    // ★ 等级与阈值的差（8 位减法，D28）：非负（0..15）表示达到/超过阈值，
    //   借位后回绕到 241..255（对应 -15..-1）表示低于阈值。判决表只按
    //   「0..15」与「16..255」两个区间判，因此 8 位无符号减法可以直接用。
    bit<8>  dq;
    bit<8>  dl;
    bit<8>  dp;

    // ---- 跨越检测 / 版本 ----
    bit<3>  crossed_mask;      // 三路判决里发生翻转的那些位
    bit<1>  ctx_crossed;
    bit<32> ctx_word;          // 要写入 reg_ctx_last 的整字（只用低 3 位）
    bit<8>  inc_ver;           // 本包是否让版本 +1（0/1，供 sALU 做简单比较）
    bit<32> cur_ver;           // 本包处理完后的当前版本（reg_ver 的输出）

    // ---- 上报判定 ----
    bit<1>  can_report;        // report_dst 表命中：本包目的地是服务器
    bit<1>  report_due;        // 本包第一次承载该版本
    bit<1>  report_now;        // report_due && can_report

    // ---- 缓存的标签（从 reg_label / reg_label_flow 读出）----
    bit<1>  label_valid;
    bit<8>  label_func;        // 寄存器里 4 位，读出后零扩展成 8 位与 FUNC_* 比较
    bit<16> label_deadline_raw;
    bit<16> label_flow_id;     // reg_label_flow 低 16 位
    bit<16> cached_ver;        // reg_label 低 16 位（D27 从 flow 寄存器移过来）
    bit<16> flow_xor;          // label_flow_id ^ flow_id（表键，0 = 匹配）
    bit<32> ver_xor;           // cached_ver ^ cur_ver（表键，0 = 未失效）
                               // ★ 用 32 位：取 cur_ver 的低 16 位会让 bf-p4c 把它劈成
                               //   两个 16 位 PHV 半区，写 ctx_report.context_id 时变成 2 个源。
    bit<1>  expired;

    // ---- 执行结果 ----
    bit<1>  do_exec;
    bit<8>  exec_func;

    // ---- 标签包路径 ----
    bit<32> label_ctx_id;      // 标签携带的 context_id（搬进 meta 供 SALU 用）
    bit<32> ctx_delta;         // label_ctx_id - reg_ver，0 = 匹配
    bit<1>  ctx_match_ok;      // ctx_match 表给出：delta == 0
    bit<1>  ctx_nonzero;       // 标签 context_id != 0（防未上报时的 0 轮次）

    // ---- 标签面：单比较/表 action 给出的判定 flag ----
    bit<1>  type_ok;           // switch_id + msg_type 通过（label_type 表）
    bit<1>  is_revoke;         // msg_type == MSG_LABEL_REVOKE
    bit<1>  func_ok;           // function_id 在白名单内
    bit<1>  expiry_ok;         // expiry 是合法相对偏移或 0xFFFF（label_expiry 表）
    // ★ S1 起删除 prio_ok / flow_ok / precheck_ok：priority 不进缓存，
    //   通配 flow 不会匹配真实数据包，合取改用嵌套 if（D26）。

    // ---- 标签整字（表 action 给常量，按单运算分段拼成）----
    bit<32> label_word;        // 要写入 reg_label 的整字（REVOKE 时为 0）
    bit<32> label_flow_word;   // 要写入 reg_label_flow 的整字（REVOKE 时为 0）
    bit<32> func_word;         // label_func 表给出：0x01000000 | function_id<<16
    bit<16> exp_raw;           // 有效 expiry；0xFFFF 被表改写成 0x7FFF（D27）
    bit<32> dl_word;           // (bit<32>)deadline（写入独立的 reg_label_dl）

    // ---- 只做表键的原始量：纯算术/切片得到，不带条件三目 ----
    bit<16> ddead;             // 数据包：now − 标签 deadline
    bit<1>  deadline_past;     // 有符号差值 > 0（表）

    // ==================== Week2：ingress 侧（D25）====================
    // ★ 与 egress 的字段完全独立；ingress/egress 各有自己的 metadata 实例。
    //   标签面判定 flag（全部由表动作给出，apply() 只判 flag）
    bit<1>  ing_type_ok;
    bit<1>  ing_is_revoke;
    bit<1>  ing_func_ok;
    bit<1>  ing_expiry_ok;

    // 标签整字（每个寄存器至多一次 32 位运算，见 D26）
    bit<32> ing_func_word;     // 白名单表常量：0x01000000 | function_id（自带 valid）
    bit<32> ing_port_word;     // egress_port 零扩展（D27 独立寄存器，不再移位拼接）
    bit<16> ing_exp_raw;       // 有效 expiry；0xFFFF 被表改写成 ING_NEVER_EXPIRY
    bit<32> ing_lbl_word;      // 写入 reg_ing_lbl 的整字
    bit<32> ing_dl_word;       // 写入 reg_ing_dl 的整字（低 16 位 deadline）
    bit<32> ing_flow_word;     // 写入 reg_ing_flow 的整字（低 16 位 flow_id）

    // 数据面从 ingress 缓存读出的量
    bit<1>  ing_valid;
    bit<8>  ing_func;
    bit<8>  ing_exec_func;
    bit<8>  ing_egress_port;
    bit<32> ing_flow_diff;     // 本次 flow_id − 缓存 flow_id（0 = 匹配，D27）
    bit<16> ing_deadline_raw;
    bit<16> ing_ddead;         // now − deadline
    bit<1>  ing_expired;
    bit<1>  ing_do_exec;

    // ---- Week2 S2/S3（小邹加，2026-10-30 合并）：优先级 + cm-sketch ----
    bit<8>  ing_pri;           // 从 reg_ing_pri 读出的 priority
    bit<32> ing_pri_word;      // priority 常量字（整字写入 reg_ing_pri）
    bit<5>  ing_cms_i0;        // sketch 列下标 = flow_id[4:0]
    bit<32> ing_cms_cnt;       // sketch RMW 返回值
    bit<8>  ing_act;           // 从 reg_ing_lbl[11:4] 取出的 action_id（0/1 选 sketch）
    bit<32> ing_act_word;      // action_id 的常量字（表给出，写 reg_ing_lbl 时一次或）
}

#endif
