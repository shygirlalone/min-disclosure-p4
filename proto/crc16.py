"""CRC-16/CCITT-FALSE。

参数：poly=0x1021, init=0xFFFF, refin=false, refout=false, xorout=0x0000
校验值：对 b"123456789" 应得 0x29B1

⚠️ 见 md/02-design-decisions.md D3：**P4 端不算 CRC，字段填 0。**
原因是你的 Hash Dist Unit 已被 3 个 CRCPolynomial 占满 100%。
校验完整实现在 Python 侧（服务器 agent 解析上行报告时校验）。

本模块必须与 binascii.crc_hqx 逐值一致 —— 见 tests/test_codec_roundtrip.py 的交叉验证。
"""

from __future__ import annotations

import binascii

__all__ = ["CRC16_POLY", "CRC16_INIT", "crc16", "crc16_verify", "crc16_append"]

CRC16_POLY = 0x1021
CRC16_INIT = 0xFFFF

# 标准校验值（来自 CRC reveng 目录：CRC-16/CCITT-FALSE）
CRC16_CHECK_INPUT = b"123456789"
CRC16_CHECK_VALUE = 0x29B1

def _build_table() -> tuple[int, ...]:
    """构建 CRC-16/CCITT-FALSE 查表。"""
    table = []
    for byte in range(256):
        crc = byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ CRC16_POLY) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
        table.append(crc)
    return tuple(table)


_TABLE = _build_table()


def crc16(data: bytes, init: int = CRC16_INIT) -> int:
    """计算 CRC-16/CCITT-FALSE。"""
    crc = init & 0xFFFF
    for byte in data:
        crc = ((crc << 8) & 0xFFFF) ^ _TABLE[((crc >> 8) ^ byte) & 0xFF]
    return crc


def crc16_reference(data: bytes, init: int = CRC16_INIT) -> int:
    """用 Python 标准库算同一个 CRC，仅用于交叉验证。

    binascii.crc_hqx 就是 CRC-CCITT (poly 0x1021, 无反射, 无 xorout)，
    参数与 CCITT-FALSE 完全等价。
    """
    return binascii.crc_hqx(data, init)


def crc16_verify(data_with_crc: bytes, init: int = CRC16_INIT) -> bool:
    """校验带 CRC 的数据：末尾 2 字节是 CRC（大端），前面是载荷。

    注意：这不是「CRC 余数为 0」的检查，而是重新计算载荷 CRC 后比对。
    """
    if len(data_with_crc) < 2:
        return False
    payload = data_with_crc[:-2]
    stored = int.from_bytes(data_with_crc[-2:], "big")
    return crc16(payload, init) == stored


def crc16_append(data: bytes, init: int = CRC16_INIT) -> bytes:
    """在数据末尾追加 2 字节大端 CRC。"""
    return data + crc16(data, init).to_bytes(2, "big")


# ---- 模块自检 ----
assert crc16(CRC16_CHECK_INPUT) == CRC16_CHECK_VALUE, (
    f"CRC16 自检失败：对 {CRC16_CHECK_INPUT!r} 应得 {CRC16_CHECK_VALUE:#06x}，"
    f"实际 {crc16(CRC16_CHECK_INPUT):#06x}"
)
assert crc16_reference(CRC16_CHECK_INPUT) == CRC16_CHECK_VALUE, (
    "binascii.crc_hqx 交叉验证失败 —— 标准库行为与预期不符"
)
