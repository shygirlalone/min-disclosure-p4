"""位级打包 / 解包。

协议里有 4-bit 的非字节对齐字段（version|msg_type、queue/load/path_level 等），
所以不能直接用 struct。这里用「累积成大整数再切字节」的方式，简单且不易错。

全部大端（网络字节序）。
"""

from __future__ import annotations

from .errors import (
    FieldRangeError,
    ProtoError,
    TrailingDataError,
    TruncatedError,
)

__all__ = [
    "ProtoError",
    "TruncatedError",
    "TrailingDataError",
    "FieldRangeError",
    "BitWriter",
    "BitReader",
    "signed_diff",
    "u32_signed_diff",
]


class BitWriter:
    """按位宽依次写入，最后产出字节串。"""

    __slots__ = ("_acc", "_nbits")

    def __init__(self) -> None:
        self._acc = 0
        self._nbits = 0

    def u(self, value: int, width: int, name: str = "?") -> "BitWriter":
        """写入一个 width 位的无符号整数。返回 self 以支持链式调用。"""
        if width <= 0:
            raise FieldRangeError(f"字段 {name}: 位宽必须为正，得到 {width}")
        if not isinstance(value, int):
            raise FieldRangeError(f"字段 {name}: 需要 int，得到 {type(value).__name__}")
        if value < 0 or (value >> width) != 0:
            raise FieldRangeError(
                f"字段 {name}: 值 {value} 超出 {width} 位范围 [0, {(1 << width) - 1}]"
            )
        self._acc = (self._acc << width) | value
        self._nbits += width
        return self

    def flag(self, value: bool, name: str = "?") -> "BitWriter":
        """写入 1 位布尔。"""
        return self.u(1 if value else 0, 1, name)

    @property
    def nbits(self) -> int:
        return self._nbits

    def to_bytes(self) -> bytes:
        """产出字节串。要求已按字节对齐。"""
        if self._nbits % 8 != 0:
            raise ProtoError(
                f"打包后共 {self._nbits} 位，不是 8 的整数倍，无法产出字节串"
            )
        return self._acc.to_bytes(self._nbits // 8, "big")


class BitReader:
    """按位宽依次读出。"""

    __slots__ = ("_acc", "_nbits", "_pos")

    def __init__(self, data: bytes) -> None:
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise ProtoError(f"需要 bytes，得到 {type(data).__name__}")
        data = bytes(data)
        self._acc = int.from_bytes(data, "big")
        self._nbits = len(data) * 8
        self._pos = 0

    def u(self, width: int, name: str = "?") -> int:
        """读出一个 width 位的无符号整数。"""
        if width <= 0:
            raise FieldRangeError(f"字段 {name}: 位宽必须为正，得到 {width}")
        if self._pos + width > self._nbits:
            raise TruncatedError(
                f"字段 {name}: 需要 {width} 位，但只剩 {self._nbits - self._pos} 位"
            )
        shift = self._nbits - self._pos - width
        value = (self._acc >> shift) & ((1 << width) - 1)
        self._pos += width
        return value

    def flag(self, name: str = "?") -> bool:
        """读出一个 1 位布尔。"""
        return bool(self.u(1, name))

    @property
    def remaining(self) -> int:
        """剩余位数。"""
        return self._nbits - self._pos

    def require_end(self, what: str = "协议") -> None:
        """断言已读完全部位，否则说明输入超长。"""
        if self.remaining:
            raise TrailingDataError(
                f"{what}: 解码后仍剩余 {self.remaining} 位（{self.remaining / 8:.1f} 字节）未消费"
            )


# ==================== 有符号差值工具 ====================
# 见 md/02-design-decisions.md D4：16-bit tick 每 4.295 秒回绕，
# 8-bit epoch 每 256 回绕，都必须用有符号差值比较，不能用无符号大小比较。


def signed_diff(value: int, reference: int, width: int) -> int:
    """把 (value - reference) 解释为 width 位的二进制补码有符号数。

    用于回绕安全的比较：
        signed_diff(new_epoch, cached_epoch, 8) > 0   → new 更新
        signed_diff(deadline, now, 16) < 0            → 已过期

    例：signed_diff(0, 255, 8) == 1    （255 之后是 0，epoch 前进 1）
        signed_diff(255, 0, 8) == -1   （0 之前是 255，epoch 后退 1）
    """
    if width <= 0 or width > 64:
        raise FieldRangeError(f"位宽必须在 [1, 64]，得到 {width}")
    mask = (1 << width) - 1
    raw = (value - reference) & mask
    sign_bit = 1 << (width - 1)
    if raw & sign_bit:
        return raw - (1 << width)
    return raw


def u32_signed_diff(value: int, reference: int) -> int:
    """32 位版本，用于 sequence 比较。"""
    return signed_diff(value, reference, 32)
