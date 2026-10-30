"""协议常量 —— 从 md/01-protocol-spec.md 派生。

⚠️ 本文件是 P4 与 Python 的共同真源。改这里必须同步：
    1. md/01-protocol-spec.md
    2. p4/include/headers.p4
    3. 在交换机上编译 min_disc.p4
"""

# ==================== 版本 ====================

PROTO_VERSION = 0x1

# ==================== EtherType ====================
# 沿用 INT 项目 0x8888/0x7777/0x6666 的风格扩展，互不冲突

TYPE_IPV4 = 0x0800
TYPE_CTX_REPORT = 0x5555  # 交换机 → 服务器，其后必然是 IPv4
TYPE_ACTION_LABEL = 0x4444  # 服务器 → 交换机，收到后丢弃

# ==================== 交换机标识 ====================

SWITCH_ID = 1

# ==================== msg_type ====================

MSG_CTX_REPORT = 0x1
MSG_CTX_REPORT_DIAG = 0x2

MSG_ACTION_LABEL = 0x1
MSG_LABEL_REVOKE = 0x2
MSG_LABEL_HEARTBEAT = 0x3

# ==================== 指标维度 ====================
# ★ v0.3 起 ctx_report_t **不再携带 metric_id**：上报固定带三路等级，
#   位置本身已经指明了指标。这些常量只给日志 / 诊断使用。

METRIC_QUEUE_CONGEST = 0x1
METRIC_PORT_LOAD = 0x2
METRIC_PATH_AVAIL = 0x3

METRIC_NAMES = {
    METRIC_QUEUE_CONGEST: "QUEUE_CONGEST",
    METRIC_PORT_LOAD: "PORT_LOAD",
    METRIC_PATH_AVAIL: "PATH_AVAIL",
}

# ==================== function_id ====================
# Week1: NOOP / DROP / ECN_MARK（egress）
# Week2: PRIORITY_SET / PORT_REDIRECT / MEASURE（ingress）

FUNC_NOOP = 0x00  # 默认安全动作：纯转发
FUNC_RATE_LIMIT = 0x01  # 保留：v0.3 无速率参数字段，标签阶段按白名单拒收
FUNC_PRIORITY_SET = 0x02  # Week2 / ingress
FUNC_PORT_REDIRECT = 0x03  # Week2 / ingress（v0.3 前叫 QUEUE_REDIRECT）
FUNC_ECN_MARK = 0x04
FUNC_DROP = 0x05
FUNC_MEASURE = 0x06  # Week2 / ingress：cm-sketch 计数，action_id 选 sketch（0/1）
FUNC_WILDCARD = 0xFF

FUNCTION_NAMES = {
    FUNC_NOOP: "NOOP",
    FUNC_RATE_LIMIT: "RATE_LIMIT",
    FUNC_PRIORITY_SET: "PRIORITY_SET",
    FUNC_PORT_REDIRECT: "PORT_REDIRECT",
    FUNC_ECN_MARK: "ECN_MARK",
    FUNC_DROP: "DROP",
    FUNC_MEASURE: "MEASURE",
    FUNC_WILDCARD: "WILDCARD",
}

# Week1 实际实现的功能集合（egress 执行）
WEEK1_FUNCTIONS = frozenset({FUNC_NOOP, FUNC_PRIORITY_SET, FUNC_DROP, FUNC_ECN_MARK})

# Week2 实际实现的功能集合（PRIORITY_SET / PORT_REDIRECT / MEASURE 在 ingress）
WEEK2_FUNCTIONS = frozenset(
    {FUNC_NOOP, FUNC_PRIORITY_SET, FUNC_PORT_REDIRECT, FUNC_ECN_MARK, FUNC_DROP, FUNC_MEASURE}
)

# ★ 两个 block 的白名单必须相同（见 md/01 §2 与 md/02 D25）：
#   任何一张合法标签都要覆盖旧缓存，执行位置由 block 自己判断。
IMPLEMENTED_FUNCTIONS = WEEK2_FUNCTIONS

# ==================== ctx_report_t flags 位 ====================

CR_FLAG_DIAG_PRESENT = 0  # ⚠️ v0.4 起停用（diag 字段已删），本位必须为 0
CR_FLAG_STORM_SUPPRESSED = 1  # bit1: 跨越但被冷却抑制，未上报
CR_FLAG_CTX_DEBOUNCED = 2  # bit2: 跨越经防抖确认

# ==================== action_label_t flags 位 ====================

AL_FLAG_CRITICAL = 0  # bit0: 不可缓存
AL_FLAG_PARAM_VALID = 1  # bit1: 参数字段有效

# ==================== 状态机 ====================

STATE_IDLE = 0  # 无有效标签，正常转发，监控跨越
STATE_REPORTED = 1  # 报告已发，等标签。★ 只做正常转发
STATE_ARMED = 2  # 标签有效。执行 function
STATE_STALE = 3  # 标签过期但未收到新标签。★ 等同 REPORTED

STATE_NAMES = {
    STATE_IDLE: "IDLE",
    STATE_REPORTED: "REPORTED",
    STATE_ARMED: "ARMED",
    STATE_STALE: "STALE",
}

# ★ 只有 ARMED 会执行 function
STATES_ACTING = frozenset({STATE_ARMED})

# ==================== 时间基准 ====================
# tick = global_tstamp[31:16]，1 tick = 65536 ns = 65.536 µs
# ⚠️ 16-bit tick 每 4.295 秒回绕一次，见 docs 的 R1/R2 规则

TICK_NS = 65536
NS_PER_MS = 1_000_000
TICKS_PER_MS = NS_PER_MS / TICK_NS  # 15.2587890625
TICK_WRAP = 1 << 16  # 65536
TICK_WRAP_SECONDS = TICK_WRAP * TICK_NS / 1e9  # 4.2949s

EXPIRY_NEVER = 0xFFFF  # expiry 特判：永不过期

# ==================== 特殊值 ====================

FLOW_ID_WILDCARD = 0xFFFF
DIAG_METRIC_INVALID = 0xFF

#: 三路量化等级各 4 bit（queue_level / load_level / path_level）
CTX_MIN = 0
CTX_MAX = 15

#: ★ v0.3 `context_id` 是 32 位轮次计数器，不再是 4 位等级
CTX_ID_MAX = 0xFFFFFFFF

# ==================== 寄存器位布局 ====================
# ★ TNA 硬约束（详见 02-design-decisions.md D12）：
#     sALU 的运算宽度只有 8 / 16 / 32 位，寄存器 entry 只能是
#     bit<8> / bit<16> / bit<32>，或「恰好两个同类型字段组成的 struct」（下称 pair）。
#     宽于 32 位的 entry 会报 `Wide operations not supported in stateful alu`。
#
#   v0.3 起全部寄存器都是 32 位单字。
#
# ⚠️ 2026-10-17：`reg_sm` / `reg_rseq` / `reg_ctx_last` / `reg_label` /
#    `reg_epoch` / `reg_seq` 的位布局常量已删除 —— 它们只服务于已删除的
#    离线参考模型，Python 侧（服务器 / 控制面）从不读取这些寄存器的内部字段。
#    **这些寄存器的唯一位布局真源是 `p4/include/headers.p4`。**
#
#    保留下来的只有 `reg_cfg`：控制面需要用 Python 算出要写的 32 位字
#    （见 md/03 V5），所以它需要一份与 P4 对齐的布局。

# ---- reg_cfg：32 位单字 —— 控制面配置 ----
#: ★ v0.4 / D28 起**按字节对齐**（Tofino PHV 切片是字节粒度）：
#:   [7:0] th_queue / [15:8] th_load / [23:16] th_path / [31:24] path_avail。
#:   阈值是**等级阈值**（0..15 尺度）；16 表示「该指标永不判违规」。
CFG_TH_QUEUE_SHIFT = 0        # bit7..0
CFG_TH_LOAD_SHIFT = 8         # bit15..8
CFG_TH_PATH_SHIFT = 16        # bit23..16
CFG_TH_MASK = 0xFF
#: 阈值取 16 即表达「永不违规」：ctx_id 最大只有 15，`ctx >= 16` 恒假。
CFG_TH_DISABLED = 0x10
CFG_PATH_AVAIL_SHIFT = 24     # bit31..24（★ 4 位，是等级本身）
CFG_PATH_AVAIL_MASK = 0xF

#: 服务器生成标签时的约束：`priority` 在交换机寄存器里只缓存 4 位，
#: 超过 15 的标签会被 P4 直接拒收（而不是静默截断）。
PRIORITY_MAX = 0xF

# ==================== 协议长度 ====================

CTX_REPORT_LEN = 14  # 字节（v0.4 / D28：24 -> 14，删 switch_id/port_id/diag/crc/pad）
ACTION_LABEL_LEN = 24  # 字节（不变）

# CRC 覆盖范围（字节偏移，左闭右开）
# ★ v0.4 起 ctx_report_t 不再有 crc16 字段（P4 侧本来就恒填 0）
ACTION_LABEL_CRC_COVER = (0, 22)


# ==================== 字段布局描述 ====================
# 供 _parked/test_p4_consistency.py 与 p4/include/headers.p4 逐字段比对。
# 每项: (字段名, 位宽, P4 类型字符串)

CTX_REPORT_LAYOUT = (
    ("version", 4, "bit<4>"),  # 与 msg_type 共用一个字节
    ("msg_type", 4, "bit<4>"),
    ("flags", 8, "bit<8>"),
    ("flow_id", 16, "bit<16>"),   # ★ D27：控制面按五元组下发
    ("queue_level", 4, "bit<4>"),
    ("load_level", 4, "bit<4>"),
    ("path_level", 4, "bit<4>"),
    ("_rsv0", 4, "bit<4>"),
    ("context_id", 32, "bit<32>"),
    ("timestamp", 16, "bit<16>"),  # ★ v0.4：global_tstamp[31:16]，4.295 s 回绕
    ("_rsv1", 16, "bit<16>"),
)

ACTION_LABEL_LAYOUT = (
    ("version", 4, "bit<4>"),
    ("msg_type", 4, "bit<4>"),
    ("flags", 8, "bit<8>"),
    ("switch_id", 8, "bit<8>"),
    ("epoch", 8, "bit<8>"),
    ("flow_id", 16, "bit<16>"),
    ("function_id", 8, "bit<8>"),
    ("context_id", 32, "bit<32>"),
    ("action_id", 8, "bit<8>"),
    ("priority", 8, "bit<8>"),
    ("egress_port", 8, "bit<8>"),
    ("_rsv0", 16, "bit<16>"),
    ("sequence", 32, "bit<32>"),
    ("expiry", 16, "bit<16>"),
    ("crc16", 16, "bit<16>"),
)


def layout_bits(layout) -> int:
    """布局的总位数。"""
    return sum(width for _, width, _ in layout)


# 自检：布局位数必须等于声明的协议长度
assert layout_bits(CTX_REPORT_LAYOUT) == CTX_REPORT_LEN * 8, "ctx_report_t 布局长度不符"
assert layout_bits(ACTION_LABEL_LAYOUT) == ACTION_LABEL_LEN * 8, "action_label_t 布局长度不符"
