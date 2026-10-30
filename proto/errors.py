"""协议层异常。

单独成模块，方便 model/ 与 agent/ 在不引入编解码依赖的情况下捕获。
"""

from __future__ import annotations

__all__ = [
    "ProtoError",
    "TruncatedError",
    "TrailingDataError",
    "FieldRangeError",
    "CrcError",
]


class ProtoError(Exception):
    """协议编解码错误基类。"""


class TruncatedError(ProtoError):
    """输入字节不足，无法解出完整协议。"""


class TrailingDataError(ProtoError):
    """输入字节多于协议长度（解码后仍有剩余位）。"""


class FieldRangeError(ProtoError):
    """字段值超出其位宽能表示的范围。"""


class CrcError(ProtoError):
    """CRC 校验失败。"""
