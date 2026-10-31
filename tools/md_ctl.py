#!/usr/bin/env python3
"""md_ctl.py —— 交换机侧控制面：给 min_disc 装表 / 查状态

跑在交换机上（先 `source /root/bf-sde-9.10.0/set_sde.bash`）：

    # 1) 最小冒烟：只装上报目的地 + 阈值（不区分流）
    python3 md_ctl.py --server-ip 192.168.10.1 --dump

    # 2) 正式实验：按五元组装 flow_key（四张表同映射）
    python3 md_ctl.py --server-ip 192.168.10.1 --flows-file flows10.json

    # 3) 查/清 sketch
    python3 md_ctl.py --server-ip 192.168.10.1 --dump-cms
    python3 md_ctl.py --server-ip 192.168.10.1 --clear-cms

flows10.json 格式：
    [{"src":"192.168.10.101","dst":"192.168.10.1","sport":40000,"dport":5001}, ...]
    flow_id = 序号+1（1..N），slot = flow_id（1..N，<=15）
    ★ 四张表必须同映射：flow_key_ing / slot_map_ing_lbl（ingress），
      flow_key / slot_map_lbl（egress）。
"""
import argparse
import glob
import json
import os
import sys


def _bootstrap_bfrt() -> bool:
    """不依赖 source set_sde.bash：自己扫 $SDE_INSTALL 和 /root/bf-sde-*/install。"""
    cands = []
    if os.environ.get("SDE_INSTALL"):
        cands.append(os.environ["SDE_INSTALL"])
    cands += sorted(glob.glob("/root/bf-sde-*/install"), reverse=True)
    for inst in cands:
        base = os.path.join(inst, "lib", "python3.7", "site-packages")
        for p in (os.path.join(base, "tofino", "bfrt_grpc"),
                  os.path.join(base, "tofino"), base):
            if os.path.isdir(p) and p not in sys.path:
                sys.path.insert(0, p)
        try:
            import bfrt_grpc.client  # noqa: F401
            return True
        except ImportError:
            continue
    return False


try:
    from bfrt_grpc import client as gc
except ImportError:
    if _bootstrap_bfrt():
        from bfrt_grpc import client as gc
    else:
        print("!! 找不到 bfrt_grpc。试过：$SDE_INSTALL 与 /root/bf-sde-*/install 下的 "
              "lib/python3.7/site-packages。\n"
              "   兜底手动：source /root/bf-sde-9.10.0/set_sde.bash 后再跑", file=sys.stderr)
        sys.exit(2)

CFG_TH_QUEUE_SHIFT = 0
CFG_TH_LOAD_SHIFT = 8
CFG_TH_PATH_SHIFT = 16
CFG_PATH_AVAIL_SHIFT = 24


def cfg_word(th_q, th_l, th_p, path_avail):
    """★ P4 侧是**按字节对齐**读的（D28）：
    cfg[7:0]=th_queue, [15:8]=th_load, [23:16]=th_path, [31:24]=path_avail。
    注意不是 constants.py 里那套 5-bit 打包（那份是旧的，别用）。
    """
    return ((th_q & 0xFF)
            | ((th_l & 0xFF) << 8)
            | ((th_p & 0xFF) << 16)
            | ((path_avail & 0xFF) << 24))


def ip_to_int(ip):
    a, b, c, d = (int(x) for x in ip.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def add(ap, info, target, P, tbl_name, key_tuples, action, data_tuples):
    """通用装表：先 add；已存在则 mod。

    ★ 不用“先 delete 再 add”：delete 不存在的条目会让 bfrt server 刷
      `Table Entry delete failed ... Object not found`（无害但很吵）。
    """
    tbl = info.table_get(tbl_name)
    key = tbl.make_key(key_tuples)
    data = tbl.make_data(data_tuples, action_name=action)
    try:
        tbl.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
    except Exception:
        tbl.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)


def install_flows(info, target, P, flows):
    """四张表同映射：五元组 -> (flow_id, slot)。"""
    for i, f in enumerate(flows):
        fid = i + 1
        slot = fid
        if slot > 15:
            raise SystemExit("slot 超过 15：flow 数必须 <= 15（16 槽，0 留给未登记）")
        tuples = [
            gc.KeyTuple("hdr.ipv4.srcAddr", ip_to_int(f["src"])),
            gc.KeyTuple("hdr.ipv4.dstAddr", ip_to_int(f["dst"])),
            gc.KeyTuple("hdr.tcp.srcPort", int(f["sport"])),
            gc.KeyTuple("hdr.tcp.dstPort", int(f["dport"])),
        ]
        add(None, info, target, P, "pipe.MyIngress.flow_key_ing", tuples,
            "MyIngress.set_flow_ing",
            [gc.DataTuple("fid", fid), gc.DataTuple("s", slot)])
        add(None, info, target, P, "pipe.MyEgress.flow_key", tuples,
            "MyEgress.set_flow",
            [gc.DataTuple("fid", fid), gc.DataTuple("s", slot)])
        add(None, info, target, P, "pipe.MyIngress.slot_map_ing_lbl",
            [gc.KeyTuple("hdr.action_label.flow_id", fid)],
            "MyIngress.set_slot_ing", [gc.DataTuple("s", slot)])
        add(None, info, target, P, "pipe.MyEgress.slot_map_lbl",
            [gc.KeyTuple("hdr.action_label.flow_id", fid)],
            "MyEgress.set_slot", [gc.DataTuple("s", slot)])
        print(f"  flow {fid:2d} slot {slot:2d}  {f['src']}:{f['sport']} -> {f['dst']}:{f['dport']}")


def dump_cms(info, target, P):
    print("  cms 计数（下标 = flow_id[4:0]）:")
    for name in ("reg_ing_cms0", "reg_ing_cms1"):
        try:
            tbl = info.table_get(f"pipe.MyIngress.{name}")
        except Exception as ex:
            print(f"    {name}: 不存在 ({ex})")
            continue
        vals = {}
        for i in range(32):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            for d, _ in tbl.entry_get(target, [key], {"from_hw": True}, p4_name=P):
                vals[i] = next((v for k, v in d.to_dict().items() if k.startswith("MyIngress")), 0)
        nz = {i: v for i, v in vals.items() if v}
        print(f"    {name}: {nz if nz else '(全 0)'}")


def clear_cms(info, target, P):
    for name in ("reg_ing_cms0", "reg_ing_cms1"):
        tbl = info.table_get(f"pipe.MyIngress.{name}")
        for i in range(32):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            data = tbl.make_data([gc.DataTuple(f"MyIngress.{name}.f1", 0)])
            try:
                tbl.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)
            except Exception:
                tbl.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
        print(f"  {name} 已清零（32 桶）")


def dump_regs(info, target, P):
    for name in ("reg_ing_lbl", "reg_ing_dl", "reg_ing_flow", "reg_ing_port", "reg_ing_pri"):
        try:
            tbl = info.table_get(f"pipe.MyIngress.{name}")
        except Exception as ex:
            print(f"  {name}: 不存在 ({ex})")
            continue
        nz = {}
        for i in range(16):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            for d, _ in tbl.entry_get(target, [key], {"from_hw": True}, p4_name=P):
                v = next((x for k, x in d.to_dict().items() if k.startswith("MyIngress")), 0)
                if v:
                    nz[i] = v
        print(f"  {name}: {nz if nz else '(全 0)'}")


def clear_table(info, target, P, tbl_name):
    """删除 range 表的全部条目。

    ★ 2026-10-30：换一组 bounds 再标定时，旧 range 条目不会自动消失；
      表里带 $MATCH_PRIORITY，重叠区间会变成「命中哪条不确定」。
      bfrt 的 entry_del 传 key_list=None 即删除全部。
    """
    tbl = info.table_get(tbl_name)
    try:
        tbl.entry_del(target, p4_name=P)
        print(f"    {tbl_name}: 旧条目已清空")
    except Exception as ex:
        print(f"    {tbl_name}: 清表失败 {ex!r}")


def write_buckets(info, target, P, tbl_name, field, action, bounds, max_val):
    """把等级桶写进 range 表。bounds 是边界列表（升序），最后一段到 max_val。

    ★ 2026-10-30 V-2 修正：deq_timedelta 是「入队→出队」的排队时延 (ns)，
      不是相邻出队间隔。所以**等级随边界升序递增**：时延越大 = 越拥塞 = 等级越高。
      旧版 reverse=True（间隔越小等级越高）是反的，已删除该参数。
    """
    tbl = info.table_get(tbl_name)
    edges = [0] + list(bounds) + [max_val]
    n = len(edges) - 1
    for i in range(n):
        lo = edges[i] + 1 if i > 0 else 0
        hi = edges[i + 1]
        level = i
        key = tbl.make_key([gc.KeyTuple(field, low=lo, high=hi)])
        data = tbl.make_data([gc.DataTuple("c", level)], action_name=action)
        try:
            tbl.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
        except Exception:
            tbl.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)
        print(f"    {tbl_name}: [{lo}, {hi}] -> level {level}")


def dump_egress(info, target, P):
    """看 egress 的上下文状态：reg_ctx_last 是“上次判决”，非 0 说明已经锁存过。"""
    for name in ("reg_ctx_last", "reg_ver", "reg_rep_ver"):
        try:
            tbl = info.table_get(f"pipe.MyEgress.{name}")
        except Exception as ex:
            print(f"  {name}: 不存在 ({ex})")
            continue
        nz = {}
        for i in range(16):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            for d, _ in tbl.entry_get(target, [key], {"from_hw": True}, p4_name=P):
                v = next((x for k, x in d.to_dict().items() if k.startswith("MyEgress")), 0)
                if v:
                    nz[i] = v
        print(f"  {name}: {nz if nz else '(全 0)'}")


def reset_ctx(info, target, P, slots=16):
    """把 egress 的上下文判决/版本清零，等价于“重新开始”，
    这样下一次打流一定会触发一次“0 -> 违规”的翻转、重新上报。"""
    for name in ("reg_ctx_last", "reg_ver", "reg_rep_ver"):
        try:
            tbl = info.table_get(f"pipe.MyEgress.{name}")
        except Exception as ex:
            print(f"  {name}: 不存在 ({ex})")
            continue
        for i in range(slots):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            data = tbl.make_data([gc.DataTuple(f"MyEgress.{name}.f1", 0)])
            try:
                tbl.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)
            except Exception:
                tbl.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
        print(f"  {name}: 已清零（{slots} 槽）")


def reset_ing(info, target, P, slots=16):
    """清空 ingress 侧的动作缓存和 cms 计数。

    ★ 2026-10-30：--reset-ctx 只清 egress。上报只在判决翻转时发生，
      重复实验时如果判决不翻转，agent 不会发 REVOKE，ingress 会一直用旧标签。
      重新打流前把两边一起清，才是真正的「从零开始」。
    """
    for name in ("reg_ing_lbl", "reg_ing_dl", "reg_ing_flow",
                 "reg_ing_port", "reg_ing_pri"):
        try:
            tbl = info.table_get(f"pipe.MyIngress.{name}")
        except Exception as ex:
            print(f"  {name}: 不存在 ({ex})")
            continue
        for i in range(slots):
            key = tbl.make_key([gc.KeyTuple("$REGISTER_INDEX", i)])
            data = tbl.make_data([gc.DataTuple(f"MyIngress.{name}.f1", 0)])
            try:
                tbl.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)
            except Exception:
                tbl.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
        print(f"  {name}: 已清零（{slots} 槽）")
    clear_cms(info, target, P)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prog", default="min_disc")
    ap.add_argument("--bfrt-server", default="localhost:50052")
    ap.add_argument("--server-ip", required=True)
    ap.add_argument("--flows-file", default=None, help="五元组 JSON（装了才会区分流）")
    ap.add_argument("--th-queue", type=int, default=None, help="队列阈值：level >= th 违规；16=禁用")
    ap.add_argument("--th-load", type=int, default=None, help="负载阈值：level >= th 违规；16=禁用")
    # ★ 路径判据是 p < th 才违规，所以禁用值是 0
    ap.add_argument("--th-path", type=int, default=None, help="路径阈值：level < th 违规；0=禁用")
    ap.add_argument("--path-avail", type=int, default=None, help="控制面写入的 path_avail 等级(0..15)")
    ap.add_argument("--q-bounds", default=None,
                    help="队列等级边界，逗号分隔（升序），例：10,50,200")
    ap.add_argument("--l-bounds", default=None,
                    help="负载等级边界（deq_timedelta 排队时延 ns，升序；"
                         "时延越大等级越高），例：100,1000,10000")
    ap.add_argument("--keep-buckets", action="store_true",
                    help="标定前不清空 quantize 表（默认会先清，避免旧 range 条目重叠）")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--dump-cms", action="store_true")
    ap.add_argument("--clear-cms", action="store_true")
    ap.add_argument("--dump-regs", action="store_true")
    ap.add_argument("--reset-ctx", action="store_true",
                    help="把 reg_ctx_last/reg_ver/reg_rep_ver 清零（每次重新测之前跑一次）")
    ap.add_argument("--reset-ing", action="store_true",
                    help="把 ingress 槽位缓存（lbl/dl/flow/port/pri）与 cms 清零")
    ap.add_argument("--dump-egress", action="store_true",
                    help="看 egress 的 reg_ctx_last / reg_ver / reg_rep_ver（判断判决是否已锁存）")
    args = ap.parse_args()

    client = gc.ClientInterface(grpc_addr=args.bfrt_server, client_id=0, device_id=0)
    info = client.bfrt_info_get(args.prog)
    target = gc.Target(device_id=0, pipe_id=0xFFFF)
    P = args.prog

    # ---- report_dst ----
    add(None, info, target, P, "pipe.MyEgress.report_dst",
        [gc.KeyTuple("hdr.ipv4.dstAddr", ip_to_int(args.server_ip))],
        "MyEgress.set_report_ok", [gc.DataTuple("ok", 1)])
    print(f"report_dst: {args.server_ip} -> can_report=1")

    # ---- reg_cfg：只有显式传了 --th-* 才写 ----
    # ★ 2026-10-24 修 bug：原来每次运行都写 reg_cfg（包括纯 --dump-*），
    #   结果“设成 1 之后一条 dump 又把阈值改回 2”，怎么都调不动。
    if any(v is not None for v in (args.th_queue, args.th_load, args.th_path, args.path_avail)):
        q = 2 if args.th_queue is None else args.th_queue
        # ★ 禁用值是 16，不是 255：判决用 8 位减法，level(0..15) - 16 回绕到 240..255（≥16 = 不违规）；
        #   写 255 会得到 level-255 ∈ 1..16，反而落在“0..15 = 违规”区间里（实测踩过）。
        l = 16 if args.th_load is None else args.th_load
        p = 0 if args.th_path is None else args.th_path
        avail = 15 if args.path_avail is None else args.path_avail
        world = cfg_word(q, l, p, avail)
        reg = info.table_get("pipe.MyEgress.reg_cfg")
        key = reg.make_key([gc.KeyTuple("$REGISTER_INDEX", 0)])
        data = reg.make_data([gc.DataTuple("MyEgress.reg_cfg.f1", world)])
        try:
            reg.entry_mod(target, key_list=[key], data_list=[data], p4_name=P)
        except Exception:
            reg.entry_add(target, key_list=[key], data_list=[data], p4_name=P)
        print(f"reg_cfg = 0x{world:08x} (q>={q} l>={l} p>={p})")
    else:
        print("reg_cfg: 未改动（纯查询模式；要改请显式传 --th-queue/--th-load/--th-path）")

    # ---- 量化桶（运行时可写，替代原来 P4 里的 const entries）----
    if args.q_bounds:
        bounds = [int(x) for x in args.q_bounds.split(",") if x.strip()]
        print("quantize_queue:")
        if not args.keep_buckets:
            clear_table(info, target, P, "pipe.MyEgress.quantize_queue")
        write_buckets(info, target, P, "pipe.MyEgress.quantize_queue",
                      "eg_intr_md.deq_qdepth", "MyEgress.set_ctx_queue",
                      bounds, 0x7FFFF)
    if args.l_bounds:
        bounds = [int(x) for x in args.l_bounds.split(",") if x.strip()]
        print("quantize_load:")
        if not args.keep_buckets:
            clear_table(info, target, P, "pipe.MyEgress.quantize_load")
        write_buckets(info, target, P, "pipe.MyEgress.quantize_load",
                      "eg_intr_md.deq_timedelta", "MyEgress.set_ctx_load",
                      bounds, 0x3FFFF)

    # ---- flows ----
    if args.flows_file:
        flows = json.load(open(args.flows_file, encoding="utf-8"))
        install_flows(info, target, P, flows)
        print(f"flow_key: 装好 {len(flows)} 条流（flow_id=1..{len(flows)}，slot 同值）")

    # ---- 查询 ----
    if args.dump:
        # ★ 2026-10-30：reg/key 原先只在「传了 --th-*」时定义，
        #   单独 --dump 会走进 except 打印 NameError。这里自己取一次。
        try:
            dump_reg = info.table_get("pipe.MyEgress.reg_cfg")
            dump_key = dump_reg.make_key([gc.KeyTuple("$REGISTER_INDEX", 0)])
            resp = dump_reg.entry_get(target, [dump_key], {"from_hw": True}, p4_name=P)
            for d, _ in resp:
                print("  reg_cfg 读回:", d.to_dict())
        except Exception as ex:
            print("  reg_cfg 读回失败:", repr(ex))
    if args.dump_regs:
        dump_regs(info, target, P)
    if args.reset_ctx:
        reset_ctx(info, target, P)
    if args.reset_ing:
        reset_ing(info, target, P)
    if args.dump_egress:
        dump_egress(info, target, P)
    if args.dump_cms:
        dump_cms(info, target, P)
    if args.clear_cms:
        clear_cms(info, target, P)

    print("[OK] md_ctl 完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
