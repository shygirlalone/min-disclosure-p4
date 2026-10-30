"""协议编解码器 —— P4 与 Python 共用的线上格式。

改协议的唯一顺序：
    md/01-protocol-spec.md → proto/constants.py → p4/include/headers.p4
    → 在交换机上编译 min_disc.p4
"""

from .action_label import ActionLabel, ctx_matches
from .ctx_report import CtxReport
from .errors import (
    FieldRangeError,
    ProtoError,
    TrailingDataError,
    TruncatedError,
)
from .fields import BitReader, BitWriter, signed_diff, u32_signed_diff
from .timebase import (
    TickClock,
    compute_deadline,
    is_expired,
    ms_to_ticks,
    ns_to_ticks,
    ticks_to_ms,
)

__all__ = [
    # 协议对象
    "CtxReport",
    "ActionLabel",
    "ctx_matches",
    # 编解码原语
    "BitWriter",
    "BitReader",
    "signed_diff",
    "u32_signed_diff",
    # 时间
    "TickClock",
    "compute_deadline",
    "is_expired",
    "ms_to_ticks",
    "ns_to_ticks",
    "ticks_to_ms",
    # 异常
    "ProtoError",
    "TruncatedError",
    "TrailingDataError",
    "FieldRangeError",
]
