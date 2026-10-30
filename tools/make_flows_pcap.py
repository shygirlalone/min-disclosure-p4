#!/usr/bin/env python3
"""make_flows_pcap.py — 生成 10 条流的 Modbus/TCP 控制流量(纯标准库, 无需 scapy)

用途: week2 case study 1(两个 1x32 直接索引计数器, 10 条流)的输入流量。

★ 2026-10-30 更正：flow_id **不再**由 srcAddr 低 16 位在数据面算出（D27）。
   flow_id 与槽位由控制面按五元组下发（tools/flows10.json，flow_id=1..10），
   交换机侧 sketch 下标 = flow_id[4:0] = 1..10。
   本脚本只负责生成合法五元组，包长/端口都无所谓；五元组必须与 flows10.json 一致。

模式:
  equal  : 每条流发相同包数(默认 500)，用于测计数/估算精度 —— **当前设计用这个**。
  single : 只打某一条流，适合逐个验证寄存器。
  calib  : 旧版哈希 sketch 的 2^i 位图标定法（i=0..9 → 1,2,...,512 包）。
           ★ 当前直接索引设计不需要它，保留只为兼容旧实验。

用法:
  python3 make_flows_pcap.py --mode equal --per-flow 500 -o flows10_equal.pcap
  python3 make_flows_pcap.py --mode single --flow 5 --per-flow 2000 -o f5.pcap
  python3 make_flows_pcap.py --mode calib -o flows10_calib.pcap   # 旧实验
"""
import argparse
import struct

# ---- 二层 ----
DST_MAC = bytes.fromhex("54b203f6c52a")   # 交换机口 MAC(打流时无所谓, 保持合法即可)
SRC_MAC = bytes.fromhex("0c42a17ac609")   # R7 网卡 MAC

# ---- 三层/四层 ----
SRC_BASE = "192.168.10."                 # 第 i 条流 = 192.168.10.(101+i)
DST_IP = "192.168.10.1"
SPORT_BASE = 40000
DPORT = 1502                              # Modbus TCP
PAYLOAD = bytes.fromhex("0006010300680015")  # 定长 Modbus 请求(8B, 内容不影响测试)


def ip2b(s):
    return bytes(int(x) for x in s.split("."))


def csum(data):
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_packet(flow_idx, seq, ident):
    src = SRC_BASE + str(101 + flow_idx)
    eth = DST_MAC + SRC_MAC + struct.pack("!H", 0x0800)

    tcp = struct.pack("!HHIIBBHHH",
                      SPORT_BASE + flow_idx, DPORT,
                      seq & 0xFFFFFFFF, 0,
                      5 << 4, 0x18,               # dataOffset=5, PSH|ACK
                      0x0400, 0, 0)               # window, checksum(不校验), urgent
    total_len = 20 + len(tcp) + len(PAYLOAD)
    ip_hdr_pre = struct.pack("!BBHHHBBH", 0x45, 0, total_len, ident & 0xFFFF,
                             0x4000, 64, 6, 0) + ip2b(src) + ip2b(DST_IP)
    ip = ip_hdr_pre[:10] + struct.pack("!H", csum(ip_hdr_pre)) + ip_hdr_pre[12:]
    return eth + ip + tcp + PAYLOAD


def interleave(per_flow_counts):
    """轮转交织: 保证 10 条流在时间上交错(而不是一条流打完再打下一条)"""
    out = []
    left = list(per_flow_counts)
    ident = 1
    while any(c > 0 for c in left):
        for i, c in enumerate(list(left)):
            if c > 0:
                out.append(build_packet(i, 1_000_000 + ident, ident))
                left[i] -= 1
                ident += 1
    return out


def write_pcap(path, packets):
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        ts = 1_760_000_000
        for n, p in enumerate(packets):
            f.write(struct.pack("<IIII", ts, n, len(p), len(p)))
            f.write(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["calib", "equal", "single"], default="calib")
    ap.add_argument("--flows", type=int, default=10)
    ap.add_argument("--per-flow", type=int, default=500)
    ap.add_argument("--flow", type=int, default=0, help="single 模式下只打第几条流(0..9)")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--payload", type=int, default=8,
                    help="payload 字节数(默认 8 = 老行为; 传 1400 生成大帧贴线速用)")
    args = ap.parse_args()

    # ★ 2026-10-21: 支持自定义 payload 大小(大帧贴线速 → 让 TM 队列真的堆起来)
    global PAYLOAD
    if args.payload != len(PAYLOAD):
        PAYLOAD = (PAYLOAD * (args.payload // len(PAYLOAD) + 1))[:args.payload]

    if args.mode == "calib":
        counts = [1 << i for i in range(args.flows)]
    elif args.mode == "equal":
        counts = [args.per_flow] * args.flows
    else:
        counts = [0] * args.flows
        counts[args.flow] = args.per_flow

    pkts = interleave(counts)
    write_pcap(args.out, pkts)
    print(f"[ok] {args.out}: {len(pkts)} 包, {args.flows} 条流")
    print("     每流包数:", counts)
    print("     flow_id / 计数桶索引（由控制面 flows10.json 指定，1..N）:")
    for i in range(args.flows):
        fid = i + 1
        print(f"       流{i+1}: 192.168.10.{101+i}  flow_id={fid}  idx={fid} (0x{fid:02x})")


if __name__ == "__main__":
    main()
