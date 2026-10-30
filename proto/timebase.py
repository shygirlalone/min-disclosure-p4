"""tick 时间基准工具。

tick = global_tstamp[31:16]，1 tick = 65536 ns = 65.536 µs。

⚠️ ★★ 16-bit tick 每 4.295 秒回绕一次 ★★
   65536 ticks × 65.536 µs = 4.2949 s

所以任何时间比较**必须**用有符号差值（见 fields.signed_diff），
绝不能用无符号的大小比较。错误写法会导致「标签随机失效」——
上机后极难定位，因为现象是间歇性的。

见 md/02-design-decisions.md D4 规则 R1。
"""

from __future__ import annotations

from .constants import (
    EXPIRY_NEVER,
    NS_PER_MS,
    TICK_NS,
    TICK_WRAP,
    TICKS_PER_MS,
)
from .fields import signed_diff

__all__ = [
    "ms_to_ticks",
    "ticks_to_ms",
    "ns_to_ticks",
    "compute_deadline",
    "is_expired",
    "TickClock",
]


def ms_to_ticks(ms: float) -> int:
    """毫秒 → tick。例：ms_to_ticks(100) == 1526（与 datasettest.p4 的常量一致）。"""
    return int(round(ms * TICKS_PER_MS))


def ticks_to_ms(ticks: float) -> float:
    """tick → 毫秒。"""
    return ticks / TICKS_PER_MS


def ns_to_ticks(ns: float) -> int:
    """纳秒 → tick。"""
    return int(round(ns / TICK_NS))


def compute_deadline(recv_tick: int, expiry: int) -> int | None:
    """由「收到标签时的 tick」和 label 里的相对 `expiry` 算出要存的绝对 deadline。

    ★ 关键：deadline 是**在标签被接收的那一刻**算一次并存下来的，
      之后每个包只做「now vs 存下来的 deadline」比较，
      **不能每个包都重新用它自己的 now 去算 deadline**（那样永远不过期）。

    返回 None 表示永不过期（expiry == EXPIRY_NEVER）。
    返回值已经过 16-bit 回绕处理。
    """
    if expiry == EXPIRY_NEVER:
        return None
    return (recv_tick + expiry) & (TICK_WRAP - 1)


def is_expired(now_tick: int, deadline: int | None) -> bool:
    """判断是否已过期。`deadline` 为 None 表示永不过期。

    用有符号差值，天然免疫 16-bit 回绕。
    """
    if deadline is None:
        return False
    return signed_diff(now_tick, deadline, 16) > 0


class TickClock:
    """单调递增的 16-bit tick 时钟，用于仿真。

    对上位机而言它单调递增到无穷，但对外暴露的 `tick` 属性
    自动按 16 位回绕 —— 这正是硬件的行为。
    """

    __slots__ = ("_full_tick",)

    def __init__(self, start_full_tick: int = 0) -> None:
        if start_full_tick < 0:
            raise ValueError("start_full_tick 必须非负")
        self._full_tick = start_full_tick

    @property
    def full_tick(self) -> int:
        """未回绕的完整 tick 计数（仅用于仿真侧的时间推进与统计）。"""
        return self._full_tick

    @property
    def tick(self) -> int:
        """对外可见的 16-bit tick，会回绕 —— 与硬件一致。"""
        return self._full_tick & (TICK_WRAP - 1)

    def advance(self, ticks: int = 1) -> int:
        """推进若干 tick，返回推进后的 16-bit tick。"""
        if ticks < 0:
            raise ValueError("不能倒退")
        self._full_tick += ticks
        return self.tick

    def advance_ms(self, ms: float) -> int:
        """按毫秒推进。"""
        return self.advance(ms_to_ticks(ms))

    def __repr__(self) -> str:
        return f"TickClock(full={self._full_tick}, tick={self.tick})"
