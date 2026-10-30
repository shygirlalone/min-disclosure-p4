"""`ctx_report_t` — 交换机 → 服务器上下文报告。

EtherType 0x5555，固定 14 字节。字段表见 md/01-protocol-spec.md §1。

★ 设计要点：只携带 4-bit 量化后的等级（queue_level / load_level / path_level，
  0..15），**绝不出现 19-bit 原始队列深度** —— 上报本身也遵守最小披露原则。

★ v0.4（2026-10-23，D28）压缩：24 → 14 字节，删除 switch_id / port_id /
  diag_value / diag_metric / crc16 / _pad，timestamp 由 32 位降为 16 位 tick。
  动机：① egress PHV 分配吃紧，24 字节头上机编译失败；② 这些字段在 Week1
  恒为常量 0，不承载信息。

★ v0.3 起不再有 `metric_id`：一条报告固定带三路等级快照，位置本身即含义。
  `context_id` 是 32 位**上下文版本号**，判决翻转时 +1；服务器下发标签时
  原样回填（见 02-design-decisions.md D21）。
"""

from __future__ import annotations

from dataclasses import dataclass

from .constants import (
    CR_FLAG_CTX_DEBOUNCED,
    CR_FLAG_DIAG_PRESENT,
    CR_FLAG_STORM_SUPPRESSED,
    CTX_ID_MAX,
    CTX_MAX,
    CTX_MIN,
    CTX_REPORT_LEN,
    MSG_CTX_REPORT,
    PROTO_VERSION,
    TYPE_CTX_REPORT,
)
from .fields import BitReader, BitWriter, ProtoError

__all__ = ["CtxReport", "ETHERTYPE"]

ETHERTYPE = TYPE_CTX_REPORT


@dataclass
class CtxReport:
    """交换机向服务器上报的上下文越过事件（三路等级 + 上下文版本）。"""

    msg_type: int = MSG_CTX_REPORT
    flags: int = 0
    flow_id: int = 0
    queue_level: int = 0
    load_level: int = 0
    path_level: int = 0
    context_id: int = 0
    timestamp: int = 0

    # ---- flags 便捷访问 ----

    def _get_flag(self, bit: int) -> bool:
        return bool((self.flags >> bit) & 1)

    def _set_flag(self, bit: int, value: bool) -> None:
        if value:
            self.flags |= 1 << bit
        else:
            self.flags &= ~(1 << bit)

    @property
    def diag_present(self) -> bool:
        """[已停用] v0.4 起没有诊断字段；本位恒为 0。"""
        return self._get_flag(CR_FLAG_DIAG_PRESENT)

    @property
    def storm_suppressed(self) -> bool:
        """本次跨越是否因冷却被抑制。"""
        return self._get_flag(CR_FLAG_STORM_SUPPRESSED)

    @storm_suppressed.setter
    def storm_suppressed(self, value: bool) -> None:
        self._set_flag(CR_FLAG_STORM_SUPPRESSED, value)

    @property
    def ctx_debounced(self) -> bool:
        """跨越是否经防抖确认。"""
        return self._get_flag(CR_FLAG_CTX_DEBOUNCED)

    @ctx_debounced.setter
    def ctx_debounced(self, value: bool) -> None:
        self._set_flag(CR_FLAG_CTX_DEBOUNCED, value)

    # ---- 编解码 ----

    def encode(self) -> bytes:
        """编码为 14 字节（无 CRC，见 md/01 §0）。"""
        w = BitWriter()
        w.u(PROTO_VERSION, 4, "version")
        w.u(self.msg_type, 4, "msg_type")
        w.u(self.flags, 8, "flags")
        w.u(self.flow_id, 16, "flow_id")
        w.u(self.queue_level, 4, "queue_level")
        w.u(self.load_level, 4, "load_level")
        w.u(self.path_level, 4, "path_level")
        w.u(0, 4, "_rsv0")
        w.u(self.context_id, 32, "context_id")
        w.u(self.timestamp, 16, "timestamp")
        w.u(0, 16, "_rsv1")
        body = w.to_bytes()
        assert len(body) == CTX_REPORT_LEN, "ctx_report_t 编码长度不符"
        return body

    @classmethod
    def decode(cls, data: bytes, strict: bool = True) -> "CtxReport":
        """从 14 字节解码。

        strict=True 时，保留字段非 0 或 flags 高位非 0 会报错。
        """
        if len(data) != CTX_REPORT_LEN:
            raise ProtoError(
                f"ctx_report_t 长度应为 {CTX_REPORT_LEN} 字节，实际 {len(data)} 字节"
            )
        r = BitReader(data)

        version = r.u(4, "version")
        if version != PROTO_VERSION:
            raise ProtoError(f"ctx_report_t 版本不支持：{version}，期望 {PROTO_VERSION}")

        msg_type = r.u(4, "msg_type")
        flags = r.u(8, "flags")
        flow_id = r.u(16, "flow_id")
        queue_level = r.u(4, "queue_level")
        load_level = r.u(4, "load_level")
        path_level = r.u(4, "path_level")
        rsv0 = r.u(4, "_rsv0")
        context_id = r.u(32, "context_id")
        timestamp = r.u(16, "timestamp")
        rsv1 = r.u(16, "_rsv1")
        r.require_end("ctx_report_t")

        if strict:
            if rsv0 or rsv1:
                raise ProtoError(f"保留字段必须为 0，实际 _rsv0={rsv0} _rsv1={rsv1}")
            if flags >> (CR_FLAG_CTX_DEBOUNCED + 1):
                raise ProtoError(
                    f"flags 高位（bit{CR_FLAG_CTX_DEBOUNCED + 1} 及以上）必须为 0：{flags:#04x}"
                )

        return cls(
            msg_type=msg_type,
            flags=flags,
            flow_id=flow_id,
            queue_level=queue_level,
            load_level=load_level,
            path_level=path_level,
            context_id=context_id,
            timestamp=timestamp,
        )

    # ---- 工具 ----

    def to_dict(self) -> dict:
        """转 dict，用于 golden vectors 与 JSON 输出。"""
        return {
            "msg_type": self.msg_type,
            "flags": self.flags,
            "flow_id": self.flow_id,
            "queue_level": self.queue_level,
            "load_level": self.load_level,
            "path_level": self.path_level,
            "context_id": self.context_id,
            "timestamp": self.timestamp,
        }

    def validate_ctx_range(self) -> None:
        """三路等级必须在 [0, 15]；context_id 是 32 位版本号。"""
        for name, value in (
            ("queue_level", self.queue_level),
            ("load_level", self.load_level),
            ("path_level", self.path_level),
        ):
            if not (CTX_MIN <= value <= CTX_MAX):
                raise ProtoError(f"{name}={value} 超出 [{CTX_MIN}, {CTX_MAX}]")
        if not (0 <= self.context_id <= CTX_ID_MAX):
            raise ProtoError(f"context_id={self.context_id} 超出 [0, {CTX_ID_MAX}]")

    def __repr__(self) -> str:
        return (
            f"CtxReport(ctx={self.context_id} "
            f"level(q={self.queue_level} l={self.load_level} p={self.path_level}) "
            f"flow={self.flow_id:#06x} ts={self.timestamp} flags={self.flags:#04x})"
        )
