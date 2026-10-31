#!/usr/bin/env python3
"""md_agent.py —— 服务器侧 agent（跑在 R7 上）

接收 min_disc 发来的 ctx_report（EtherType 0x5555，14B），
按三路等级决策，回发 action_label（EtherType 0x4444，24B），交换机收到后丢弃。

    sudo python3 md_agent.py --iface enp101s0f1
    sudo python3 md_agent.py --iface enp101s0f1 --expiry-ms 50 --priority 3 --verbose

决策（可改）：
    path_level >= 8            -> PORT_REDIRECT，egress_port=8
    queue_level >= q_th        -> PRIORITY_SET，priority=3（高）
    load_level  >= l_th        -> PRIORITY_SET，priority=1
    其它                        -> NOOP（priority=0）

字段布局严格按 proto/constants.py（14B / 24B），CRC 填 0（P4 侧不校验）。
"""
import argparse
import socket
import struct
import sys
import time

TYPE_CTX_REPORT = 0x5555
TYPE_ACTION_LABEL = 0x4444

PROTO_VERSION = 1
MSG_CTX_REPORT = 1
MSG_ACTION_LABEL = 1
MSG_LABEL_REVOKE = 2
SWITCH_ID = 1

FUNC_NOOP = 0
FUNC_PRIORITY_SET = 2
FUNC_PORT_REDIRECT = 3
FUNC_MEASURE = 6

TICKS_PER_MS = 1000000 / 65536.0


def ms_to_ticks(ms: float) -> int:
    return max(1, min(0xFFFE, int(round(ms * TICKS_PER_MS))))


def decode_report(b: bytes) -> dict:
    """14 字节 ctx_report_t -> dict（字段顺序见 proto/constants.py）。"""
    ver_msg, flags, flow, ql, pr, ctx, ts, rsv1 = struct.unpack("!BBHBBIHH", b)
    return {
        "version": ver_msg >> 4,
        "msg_type": ver_msg & 0xF,
        "flags": flags,
        "flow_id": flow,
        "queue_level": ql >> 4,
        "load_level": ql & 0xF,
        "path_level": pr >> 4,
        "rsv0": pr & 0xF,
        "context_id": ctx,
        "timestamp": ts,
        "pkt_seq": rsv1,   # 2026-10-31：_rsv1 复用为每流包序号
    }


def encode_label(flow_id: int, function_id: int, context_id: int,
                 action_id: int = 0, priority: int = 0,
                 egress_port: int = 0, expiry: int = 0,
                 sequence: int = 0, msg_type: int = MSG_ACTION_LABEL) -> bytes:
    """24 字节 action_label_t（crc16 填 0，P4 不校验）。"""
    out = bytearray(24)
    out[0] = (PROTO_VERSION << 4) | (msg_type & 0xF)
    out[1] = 0                                  # flags
    out[2] = SWITCH_ID
    out[3] = 0                                  # epoch
    struct.pack_into("!H", out, 4, flow_id)
    out[6] = function_id
    struct.pack_into("!I", out, 7, context_id)
    out[11] = action_id
    out[12] = priority
    out[13] = egress_port
    # 14..15 rsv0 = 0
    struct.pack_into("!I", out, 16, sequence)
    struct.pack_into("!H", out, 20, expiry)
    # 22..23 crc16 = 0
    return bytes(out)


def decide(rep: dict, q_th: int, l_th: int) -> tuple:
    """(function_id, action_id, priority, egress_port)

    ★ path_level = path_avail（控制面写的“路径可用等级”，**越大越好**，15 = 最好）。
      所以劣化是 `<= 8`，不是 `>= 8`（之前写反了，会误把流量打到没人接的 8 号口）。
    """
    if rep["path_level"] <= 8:
        return (FUNC_PORT_REDIRECT, 0, 0, 8)
    if rep["queue_level"] >= q_th:
        return (FUNC_PRIORITY_SET, 0, 3, 0)
    if rep["load_level"] >= l_th:
        return (FUNC_PRIORITY_SET, 0, 1, 0)
    return (FUNC_NOOP, 0, 0, 0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="enp101s0f1")
    ap.add_argument("--expiry-ms", type=float, default=50.0)
    ap.add_argument("--q-th", type=int, default=2, help="队列等级阈值（0..15）")
    ap.add_argument("--l-th", type=int, default=3)
    ap.add_argument("--max-labels", type=int, default=0, help="0 = 不限")
    ap.add_argument("--mode", choices=["priority", "measure"], default="priority",
                    help="priority=按等级下发 qid；measure=下发 MEASURE（flow 1-5 进 sketch0，6-10 进 sketch1）")
    ap.add_argument("--no-revoke", action="store_true",
                    help="不先发 REVOKE（默认会发：收到上报先清缓存，再下发新动作）")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
    sock.bind((args.iface, 0))
    print(f"[agent] listening on {args.iface}, expiry={args.expiry_ms}ms "
          f"(q_th={args.q_th}, l_th={args.l_th})")

    n_rep = n_lbl = 0
    while True:
        frame, _addr = sock.recvfrom(65535)
        if len(frame) < 14 + 14:
            continue
        if struct.unpack("!H", frame[12:14])[0] != TYPE_CTX_REPORT:
            continue

        try:
            rep = decode_report(frame[14:28])
        except Exception as ex:
            print("[agent] 解码失败:", repr(ex))
            continue

        n_rep += 1
        if args.mode == "measure":
            # Case study 1：服务器直接指定 5+5 分桶（对比方案做不到这件事）
            fn = FUNC_MEASURE
            act = 0 if rep["flow_id"] <= 5 else 1
            pri, port = 0, 0
        else:
            fn, act, pri, port = decide(rep, args.q_th, args.l_th)
        expiry = ms_to_ticks(args.expiry_ms)

        dst_mac = frame[6:12]      # 交换机口 MAC（上报帧的源）
        src_mac = frame[0:6]       # 本机 MAC（上报帧的目的）
        eth = dst_mac + src_mac + struct.pack("!H", TYPE_ACTION_LABEL)

        # ★ 任务书 week1：context 变了，先让交换机清空动作缓存、只做正常转发，
        #   直到新标签到达。用协议里现成的 REVOKE（msg_type=2）实现，不占 stage。
        if not args.no_revoke:
            revoke = encode_label(flow_id=rep["flow_id"], function_id=0,
                                  context_id=rep["context_id"],
                                  msg_type=MSG_LABEL_REVOKE)
            sock.send(eth + revoke)

        label = encode_label(
            flow_id=rep["flow_id"], function_id=fn, context_id=rep["context_id"],
            action_id=act, priority=pri, egress_port=port, expiry=expiry,
            sequence=rep["pkt_seq"],
        )
        sock.send(eth + label)
        n_lbl += 1

        if args.verbose or n_rep % 20 == 1:
            print(f"[{n_rep:6d}] flow={rep['flow_id']:#06x} ctx={rep['context_id']} "
                  f"lv(q={rep['queue_level']} l={rep['load_level']} p={rep['path_level']}) "
                  f"seq={rep['pkt_seq']} -> func={fn} pri={pri} port={port} expiry={expiry}ticks")

        if args.max_labels and n_rep >= args.max_labels:
            print(f"[agent] 已发 {n_lbl} 个标签，退出")
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[agent] stopped")
