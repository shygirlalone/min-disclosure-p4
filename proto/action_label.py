"""`action_label_t` — 服务器 → 交换机动作标签。

EtherType 0x4444，固定 24 字节。字段表见 md/01-protocol-spec.md §2。

交换机收到后：解析 → 校验 → 写标签寄存器 → drop_ctl 丢弃该包（不转发）。

★ v0.3 起 `context_id` 是 32 位**轮次号**，不是 4 位等级：
  服务器把最近一次收到的 `ctx_report_t.context_id` 原样回填，
  交换机要求 `label.context_id == reg_rseq` **精确相等**才算绑定成功。
  v0.2 的 `ctx_tolerance` 已删除（见 02-design-decisions.md D21）。
"""

from __future__ import annotations

from dataclasses import dataclass

from .constants import (
    ACTION_LABEL_CRC_COVER,
    ACTION_LABEL_LEN,
    AL_FLAG_CRITICAL,
    AL_FLAG_PARAM_VALID,
    CTX_ID_MAX,
    EXPIRY_NEVER,
    FLOW_ID_WILDCARD,
    FUNC_NOOP,
    MSG_ACTION_LABEL,
    PROTO_VERSION,
    SWITCH_ID,
    TYPE_ACTION_LABEL,
)
from .crc16 import crc16
from .fields import BitReader, BitWriter, ProtoError
from .timebase import compute_deadline

__all__ = ["ActionLabel", "ETHERTYPE", "ctx_matches"]

ETHERTYPE = TYPE_ACTION_LABEL


def ctx_matches(cur_ctx: int, label_ctx: int) -> bool:
    """上下文绑定判定：标签的轮次号必须与交换机当前轮次号精确相等。"""
    return cur_ctx == label_ctx


@dataclass
class ActionLabel:
    """服务器下发给交换机的动作标签。"""

    msg_type: int = MSG_ACTION_LABEL
    flags: int = 0
    switch_id: int = SWITCH_ID
    epoch: int = 0
    flow_id: int = 0
    function_id: int = FUNC_NOOP
    context_id: int = 0
    action_id: int = 0
    priority: int = 0
    egress_port: int = 0
    sequence: int = 0
    expiry: int = 0

    # ---- flags 便捷访问 ----

    def _get_flag(self, bit: int) -> bool:
        return bool((self.flags >> bit) & 1)

    def _set_flag(self, bit: int, value: bool) -> None:
        if value:
            self.flags |= 1 << bit
        else:
            self.flags &= ~(1 << bit)

    @property
    def critical(self) -> bool:
        """置位时标签不可被普通标签覆盖（按 priority 仲裁）。"""
        return self._get_flag(AL_FLAG_CRITICAL)

    @critical.setter
    def critical(self, value: bool) -> None:
        self._set_flag(AL_FLAG_CRITICAL, value)

    @property
    def param_valid(self) -> bool:
        """置位时 priority / egress_port 等参数字段有效。"""
        return self._get_flag(AL_FLAG_PARAM_VALID)

    @param_valid.setter
    def param_valid(self, value: bool) -> None:
        self._set_flag(AL_FLAG_PARAM_VALID, value)

    # ---- 语义辅助 ----

    @property
    def is_wildcard_flow(self) -> bool:
        """flow_id == 0xFFFF 表示作用于所有流。"""
        return self.flow_id == FLOW_ID_WILDCARD

    @property
    def never_expires(self) -> bool:
        return self.expiry == EXPIRY_NEVER

    def matches_flow(self, flow_id: int) -> bool:
        """流作用域判定。"""
        return self.is_wildcard_flow or self.flow_id == flow_id

    def matches_ctx(self, cur_ctx: int) -> bool:
        """上下文绑定判定（轮次号精确相等）。"""
        return ctx_matches(cur_ctx, self.context_id)

    def deadline_from(self, recv_tick: int) -> int | None:
        """★ 由「收到标签时的 tick」算出要存进寄存器的绝对 deadline。

        必须在接收时算一次并存下来；之后每个包只做 now vs deadline 比较。
        """
        return compute_deadline(recv_tick, self.expiry)

    # ---- 编解码 ----

    def encode(self, compute_crc: bool = True) -> bytes:
        """编码为 24 字节。

        compute_crc=False 用于仿真 P4 侧行为（P4 不算 CRC，字段填 0）。
        """
        w = BitWriter()
        w.u(PROTO_VERSION, 4, "version")
        w.u(self.msg_type, 4, "msg_type")
        w.u(self.flags, 8, "flags")
        w.u(self.switch_id, 8, "switch_id")
        w.u(self.epoch, 8, "epoch")
        w.u(self.flow_id, 16, "flow_id")
        w.u(self.function_id, 8, "function_id")
        w.u(self.context_id, 32, "context_id")
        w.u(self.action_id, 8, "action_id")
        w.u(self.priority, 8, "priority")
        w.u(self.egress_port, 8, "egress_port")
        w.u(0, 16, "_rsv0")
        w.u(self.sequence, 32, "sequence")
        w.u(self.expiry, 16, "expiry")
        body = w.to_bytes()
        assert len(body) == ACTION_LABEL_CRC_COVER[1], "CRC 覆盖范围与 body 长度不符"

        crc = crc16(body) if compute_crc else 0
        return body + crc.to_bytes(2, "big")

    @classmethod
    def decode(
        cls, data: bytes, verify_crc: bool = True, strict: bool = True
    ) -> "ActionLabel":
        """从 24 字节解码。

        verify_crc=False 用于解析 P4 侧构造的包（P4 不算 CRC，字段为 0）。
        """
        if len(data) != ACTION_LABEL_LEN:
            raise ProtoError(
                f"action_label_t 长度应为 {ACTION_LABEL_LEN} 字节，实际 {len(data)} 字节"
            )
        r = BitReader(data)

        version = r.u(4, "version")
        if version != PROTO_VERSION:
            raise ProtoError(f"action_label_t 版本不支持：{version}，期望 {PROTO_VERSION}")

        msg_type = r.u(4, "msg_type")
        flags = r.u(8, "flags")
        switch_id = r.u(8, "switch_id")
        epoch = r.u(8, "epoch")
        flow_id = r.u(16, "flow_id")
        function_id = r.u(8, "function_id")
        context_id = r.u(32, "context_id")
        action_id = r.u(8, "action_id")
        priority = r.u(8, "priority")
        egress_port = r.u(8, "egress_port")
        rsv0 = r.u(16, "_rsv0")
        sequence = r.u(32, "sequence")
        expiry = r.u(16, "expiry")
        stored_crc = r.u(16, "crc16")
        r.require_end("action_label_t")

        if strict:
            if rsv0:
                raise ProtoError(f"保留字段必须为 0，实际 _rsv0={rsv0}")
            if flags >> (AL_FLAG_PARAM_VALID + 1):
                raise ProtoError(
                    f"flags 高位（bit{AL_FLAG_PARAM_VALID + 1} 及以上）必须为 0：{flags:#04x}"
                )

        if verify_crc:
            expected = crc16(data[ACTION_LABEL_CRC_COVER[0] : ACTION_LABEL_CRC_COVER[1]])
            if expected != stored_crc:
                raise ProtoError(
                    f"action_label_t CRC 校验失败：期望 {expected:#06x}，实际 {stored_crc:#06x}"
                )

        return cls(
            msg_type=msg_type,
            flags=flags,
            switch_id=switch_id,
            epoch=epoch,
            flow_id=flow_id,
            function_id=function_id,
            context_id=context_id,
            action_id=action_id,
            priority=priority,
            egress_port=egress_port,
            sequence=sequence,
            expiry=expiry,
        )

    # ---- 工具 ----

    def to_dict(self) -> dict:
        """转 dict，用于 golden vectors 与 JSON 输出。"""
        return {
            "msg_type": self.msg_type,
            "flags": self.flags,
            "switch_id": self.switch_id,
            "epoch": self.epoch,
            "flow_id": self.flow_id,
            "function_id": self.function_id,
            "context_id": self.context_id,
            "action_id": self.action_id,
            "priority": self.priority,
            "egress_port": self.egress_port,
            "sequence": self.sequence,
            "expiry": self.expiry,
        }

    def validate_ctx_range(self) -> None:
        """context_id 是 32 位轮次号，必须在 [0, 2^32-1]。"""
        if not (0 <= self.context_id <= CTX_ID_MAX):
            raise ProtoError(f"context_id={self.context_id} 超出 [0, {CTX_ID_MAX}]")

    def __repr__(self) -> str:
        return (
            f"ActionLabel(flow={self.flow_id:#06x} func={self.function_id} "
            f"ctx={self.context_id} action={self.action_id} "
            f"port={self.egress_port} prio={self.priority} "
            f"epoch={self.epoch} seq={self.sequence} expiry={self.expiry})"
        )
