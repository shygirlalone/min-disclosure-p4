#ifndef _MIN_DISC_PARSERS_
#define _MIN_DISC_PARSERS_

#include <core.p4>
#include <tna.p4>
#include "headers.p4"

/*************************************************************************
 *  min-disclosure 解析器 / 逆解析器
 *
 *  结构照抄 INT 项目的 include/parsers.p4：
 *    - TofinoIngressParser 先吃掉 Tofino 自带的 intrinsic metadata
 *    - MyIngressParser / MyEgressParser 才是协议自己的解析
 *    - 两个 deparser 分别对应 ingress / egress
 *
 *  ★ 关键：ingress deparser **必须把 action_label 头 emit 出去**，
 *    否则 egress parser 根本看不到标签包，整个下行协议就断了。
 *************************************************************************/

/*************************************************************************
 ***********************  I N G R E S S  *********************************
 *************************************************************************/

parser TofinoIngressParser(
        packet_in pkt,
        out ingress_intrinsic_metadata_t ig_intr_md) {
    state start {
        pkt.extract(ig_intr_md);
        transition parse_port_metadata;
    }
    state parse_port_metadata {
        pkt.advance(PORT_METADATA_SIZE);
        transition accept;
    }
}

parser MyIngressParser(packet_in packet,
                       out headers hdr,
                       out metadata meta,
                       out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(packet, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_ACTION_LABEL : parse_action_label;
            TYPE_CTX_REPORT   : parse_ctx_report;   // 防御性：理论上不该从入口进来
            TYPE_IPV4         : parse_ipv4;
            default           : accept;
        }
    }

    // ---- 下行标签：整帧只有 ethernet + action_label，解析完就到头 ----
    state parse_action_label {
        packet.extract(hdr.action_label);
        transition accept;
    }

    // ---- 上报头：插在 ethernet 与 ipv4 之间 ----
    state parse_ctx_report {
        packet.extract(hdr.ctx_report);
        transition select(hdr.ethernet.etherType) {
            TYPE_CTX_REPORT : parse_ipv4;
            default         : accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP : parse_tcp;
            default   : accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }
}

control MyIngressDeparser(packet_out packet,
                          inout headers hdr,
                          in metadata meta,
                          in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {
    apply {
        packet.emit(hdr.ethernet);
        // ★ ctx_report 只在 egress 里 setValid → ingress deparser 不 emit 它。
        //   （2026-10-23 实测：两边都 emit 会把 egress 里分 stage 写的字段拉成
        //    一个不可满足的 PHV 打包组，报 "requires too many sources"。）
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        // ★ 标签包必须在 ingress 就被 emit 出来，egress parser 才解析得到
        packet.emit(hdr.action_label);
    }
}

/*************************************************************************
 ***********************  E G R E S S  ***********************************
 *************************************************************************/

parser MyEgressParser(
        packet_in packet,
        out headers hdr,
        out metadata meta,
        out egress_intrinsic_metadata_t eg_intr_md) {

    state start {
        packet.extract(eg_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_ACTION_LABEL : parse_action_label;
            TYPE_CTX_REPORT   : parse_ctx_report;
            TYPE_IPV4         : parse_ipv4;
            default           : accept;
        }
    }

    state parse_action_label {
        packet.extract(hdr.action_label);
        transition accept;
    }

    state parse_ctx_report {
        packet.extract(hdr.ctx_report);
        transition parse_ipv4;
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP : parse_tcp;
            default   : accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }
}

control MyEgressDeparser(packet_out packet,
                         inout headers hdr,
                         in metadata meta,
                         in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {
    apply {
        packet.emit(hdr.ethernet);
        // ctx_report 是 egress control 里才 setValid 的；invalid 时 emit 自动跳过，
        // 所以「不需要上报」的包原样出去，一个字节都不变。
        packet.emit(hdr.ctx_report);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        // ★ 不 emit action_label（D28）：标签包在本 block 一律 drop_ctl=1，
        //   永远不会上线；而 emit 会让标签头的全部字段（含 egress 根本不读的
        //   sequence/crc16/epoch/egress_port/priority）都要占 egress PHV，
        //   实测直接把 PHV 分配撑爆（73 个切片无法分配）。
    }
}

#endif
