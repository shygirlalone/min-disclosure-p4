/*
 * min_disc.p4 —— 加密传输最小披露 · 贡献2 的交换机侧实现（Week1 + Week2 S1）
 *
 * ============================================================================
 *  ★ 2026-10-22 Week2 S1：MyIngress 增加「ingress 动作缓存」
 * ============================================================================
 *  PRIORITY_SET（ig_tm_md.qid）与 PORT_REDIRECT（ig_tm_md.ucast_egress_port）
 *  只能在 ingress 写，而 TNA 不允许 Register 跨 block 共用。因此 ingress 另建
 *  reg_ing_lbl / reg_ing_dl / reg_ing_flow 三张表，标签包同时流经 ingress 与
 *  egress，两边各落一份缓存。S1 只执行 PORT_REDIRECT；S2 / S3 再往
 *  ing_exec_decide 加 PRIORITY_SET / MEASURE。
 *  设计理由与 context 绑定取舍见 md/02 D25、md/01 §2。
 *
 * ============================================================================
 *  这个程序干两件事
 * ============================================================================
 *  (1) 状态获取 + 判断 + 上报
 *      读三个指标（队列长度 / 端口负载 / 路径可用）→ 量化成 4-bit 等级
 *      → 与手动设定的阈值比较 → 「不符合要求」发生翻转（跨越）时，让该流的
 *      上下文版本 +1，并在当前数据包上插一个 ctx_report_t 头
 *      （EtherType 0x5555）发往服务器。
 *      ★ 只有目的地命中 report_dst 表（控制面写入服务器 IP）的包才允许携带
 *        上报；否则本次版本变化不上报，等下一个去服务器的包再补（D24）。
 *
 *  (2) 服务器 → 交换机的动作标签协议
 *      解析 action_label_t（EtherType 0x4444）→ switch_id / msg_type / 功能白名单
 *      / priority / flow / expiry / context 版本校验
 *      → 写进标签寄存器 → drop_ctl 丢弃该包。
 *
 * ============================================================================
 *  ★★ 2026-10-17 简化：版本失效模型，彻底去掉乒乓双副本
 * ============================================================================
 *  D19 实测（bf-p4c 9.10）：
 *    · 同一寄存器同包「读动作 + reg.write()」→
 *        `Table placement cannot make any more progress`
 *    · 一个 RegisterAction 内至多 2 次比较 / 不许局部变量 /
 *      写必须写满 32 位 / 32 位条件赋值会让编译器崩溃。
 *
 *  D23 曾用 A/B 双副本 + 相位绕开「同包读-算-写同一寄存器」。本版改为
 *  **每流一个版本号**，每个逻辑量只保留一个物理寄存器：
 *
 *    reg_ctx_last[16]   数据面单次 RMW：读旧判决 + 写本次判决（只用低 3 位）
 *    reg_ver[16]        数据面单次 RMW：跨越时 v=v+1，输出新版本
 *    reg_rep_ver[16]    数据面单次 RMW：每包执行，Action 内仅在 can_report=1 时写
 *    reg_label[16]      数据面只读 / 标签面只写
 *    reg_label_flow[16] 数据面只读 / 标签面只写（低 16 位 flow，高 16 位版本）
 *
 *  语义：
 *    · 标签有效 ⇔ label.context_id == reg_ver[slot]
 *    · 需要上报 ⇔ 本包让版本 +1，且该版本还没被 can_report 的包带走
 *    · 上下文一跨越，旧标签立即失效 —— 不依赖报告是否送达
 *
 *  相比 D23 放弃的东西（Week1 明确接受）：
 *    · 没有显式 IDLE/REPORTED/ARMED/STALE 状态字；
 *    · 没有 100ms 冷却、没有 1s 心跳/补发定时器；
 *    · 标签过期后静默停止执行，不产生 STALE 上报；
 *    · epoch / sequence 仍在线上，但 P4 不校验（防重放降级为“版本 + expiry”）；
 *    · 一个版本只报一次；报告丢失后要等下一次跨越才会再报。
 *
 *  ★ 2026-10-17 第二批简化（编译减负）：
 *    · reg_ctx_last 只存 3 位判决；三等级快照与 init 位删除。
 *    · 标签过期判定合并为一张 range 表；「永不过期」改用 reg_label bit25，
 *      删除 `0-flag` / `~` / `&` 掩码链。
 *    · reg_rep_ver 改为每包执行、Action 内条件写，去掉 apply() 里的条件
 *      execute 与局部变量二次赋值。
 *
 *  ★ 2026-10-17 第三轮（标签字组装）：
 *    bf-p4c 把 apply() 里的每条赋值编成**单 stage action**，混合位宽的
 *    mask / shift / or 无法一条完成（`action spanning multiple stages`）。
 *    对策：func / priority 的移位打包、valid / never 常量位都挪进表 action
 *    的 const entries；deadline 放到寄存器低 16 位免移位；拼接拆成
 *    「一条语句只做一次或」。线格式与协议字段零改动。
 *
 *  ★ 编译状态（2026-10-17）：前端 0 ERROR；索引问题已解决（slot_map）；
 *    标签字组装已按单运算拆分，待编译验证，见 md/04。
 *  ★ 2026-10-22 Week2 S1：MyIngress 新增动作缓存与 PORT_REDIRECT，
 *    **尚未上机编译**（本地无 bf-p4c）；验证项见 md/03 V11。
 *
 * ============================================================================
 *  其他硬约束
 * ============================================================================
 *  · 16-bit tick 每 4.2949s 回绕。所有时间比较一律走有符号差值：
 *        bit<16> d = a - b;   if ((int<16>)d > 0) { ... }
 *  · 队列深度只有 egress 读得到，所以 Week1 逻辑收敛在 egress（D1）。
 *    Week2 的 ingress 动作（qid / 出端口 / sketch）另建一套缓存（D25），
 *    两个 block 之间不共享任何 Register。
 *  · 槽位 = slot_map(flow_id[7:0]) = flow_id[7:4]（16 槽）。
 *    ★ 槽位必须由表产出：bf-p4c 不接受计算值直接当寄存器索引。
 *    reg_label_flow 存完整 flow_id，执行前比对，防止两条流因槽位相同而
 *    互相命中（D24）。10 条流实验必须选低 4 位互不相同的流，或等 P6 的
 *    精确映射表。
 *
 *  线格式与寄存器**位布局**在 include/headers.p4；决策理由见 md/02。
 *  协议字段真源是 md/01-protocol-spec.md。
 */

#include <core.p4>
#include <tna.p4>
#include "include/headers.p4"
#include "include/parsers.p4"

/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G  *******************
 *************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  in ingress_intrinsic_metadata_t ig_intr_md,
                  in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
                  inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
                  inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    /* ====================================================================
     *  Week2：ingress 侧动作缓存（D25）
     *  --------------------------------------------------------------------
     *  ★ 为什么这里必须另起一套寄存器：
     *    PRIORITY_SET（ig_tm_md.qid）与 PORT_REDIRECT
     *    （ig_tm_md.ucast_egress_port）只能在 ingress 写；egress 没有这两个字段。
     *    TNA 又不允许同一个 Register 被 ingress / egress 共用 —— 所以两个
     *    block 各持一份缓存，标签包本身同时流经两边，充当同步载体。
     *
     *  ★ S1 范围：只实现 PORT_REDIRECT。
     *    白名单 / 校验 / deadline / flow 防串流都先就位，PRIORITY_SET 与
     *    MEASURE 在 S2 / S3 往 exec_decide 里加表项即可。
     *
     *  ★ context 绑定：ingress 读不到 egress 的 reg_ver，采用
     *    「单调 context_id + 标签 expiry 上界」（md/01 §2 / D25）。
     *    S1 先不做单调检查，reg_ing_ctx 在 S4 加；当前靠 expiry 兜底。
     * ==================================================================== */

    // ---- 每流动作缓存（16 槽，槽位由控制面下发的表产出）----
    Register<bit<32>, bit<8>>(16) reg_ing_lbl;    // func + valid（白名单表常量整字）
    Register<bit<32>, bit<8>>(16) reg_ing_dl;     // 低 16 位 deadline
    Register<bit<32>, bit<8>>(16) reg_ing_flow;   // 低 16 位 flow_id
    Register<bit<32>, bit<8>>(16) reg_ing_port;   // 低 8 位 目标端口（D27 拆出，写入零运算）

    // ---- Week2 S2（小邹加）：priority 单独一个寄存器（照 D27：拆分，写入零运算）----
    Register<bit<32>, bit<8>>(16) reg_ing_pri;

    // ---- Week2 S3（小邹加）：两个 sketch，action_id=0/1 指定本流进哪个（5+5 分桶）----
    // 下标 = flow_id[4:0]；10 条流 0x01~0x0A 互不相同 -> 各占一格，无碰撞。
    Register<bit<32>, bit<5>>(32) reg_ing_cms0;
    Register<bit<32>, bit<5>>(32) reg_ing_cms1;
    RegisterAction<bit<32>, bit<5>, bit<32>>(reg_ing_cms0) cms0_inc_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { v = v + 1; out_v = v; }
    };
    RegisterAction<bit<32>, bit<5>, bit<32>>(reg_ing_cms1) cms1_inc_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { v = v + 1; out_v = v; }
    };

    // ---- 槽位映射（与 egress 同内容；同一 control 内不能复用同一张表）----
    // ★ 2026-10-23 D27：flow_id 不再由数据面异或计算。
    //   bf-p4c 无法把多级异或放进单个 action（`action spanning multiple
    //   stages`），且 copy-prop 会把表达式跨表重新内联，中间插表也挡不住。
    //   改为**控制面按五元组下发**：数据面查 flow_key_ing 得到 (flow_id, slot)，
    //   标签面查 slot_map_ing_lbl 得到 slot。两张表必须由同一个控制面脚本
    //   安装，且 flow_id → slot 的映射与五元组 → slot 的映射一致。
    action set_flow_ing(bit<16> fid, bit<8> s) { meta.flow_id = fid; meta.slot = s; }
    action set_slot_ing(bit<8> s) { meta.slot = s; }

    table flow_key_ing {
        key = { hdr.ipv4.srcAddr : exact;
                hdr.ipv4.dstAddr : exact;
                hdr.tcp.srcPort  : exact;
                hdr.tcp.dstPort  : exact; }
        actions = { set_flow_ing; }
        size = 64;
        // 未登记的流：flow_id = 0xFFFF（控制面禁用值），槽位 0。
        // 该槽位里即便有标签，flow 比对也必然失败 → 不执行任何动作。
        default_action = set_flow_ing(16w0xFFFF, 8w0);
    }
    table slot_map_ing_lbl {
        key = { hdr.action_label.flow_id : exact; }
        actions = { set_slot_ing; }
        size = 64;
        default_action = set_slot_ing(8w0);
    }

    // ===================== 寄存器动作 =====================
    // ★ 数据面：三条纯读，每包一次；标签面：三条纯写，每包一次。
    //   同一个物理寄存器在同一包内绝不会既读又写。
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_lbl) ing_lbl_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { out_v = v; }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_lbl) ing_lbl_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ing_lbl_word;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_dl) ing_dl_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { out_v = v; }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_dl) ing_dl_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ing_dl_word;
        }
    };
    // ★ D27：读动作直接输出「本次 flow_id − 缓存的 flow_id」，0 = 相等。
    //   比较搬进 RegisterAction 后，apply() 里没有异或，也就不会被 copy-prop
    //   拉成多级依赖。形状与 egress 的 ver_diff_ra 一致（PHV − 寄存器）。
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_flow) ing_flow_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = (bit<32>)meta.flow_id - v;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_flow) ing_flow_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ing_flow_word;
        }
    };
    // ---- reg_ing_port：目标端口单独一个寄存器（D27）----
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_port) ing_port_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { out_v = v; }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_port) ing_port_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ing_port_word;
        }
    };

    // ---- reg_ing_pri：目标优先级（D27 独立寄存器，写入零扩展）----
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_pri) ing_pri_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) { out_v = v; }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ing_pri) ing_pri_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ing_pri_word;
        }
    };

    // ===================== 标签面：静态校验 =====================
    // ★ 与 egress 的判定表同语义；两边白名单必须一致（md/01 §2）。
    action ing_type_label()  { meta.ing_type_ok = 1w1; meta.ing_is_revoke = 1w0; }
    action ing_type_revoke() { meta.ing_type_ok = 1w1; meta.ing_is_revoke = 1w1; }
    action ing_type_bad()    { meta.ing_type_ok = 1w0; meta.ing_is_revoke = 1w0; }
    table ing_label_type {
        key = { hdr.action_label.switch_id : exact;
                hdr.action_label.msg_type  : exact; }
        actions = { ing_type_label; ing_type_revoke; ing_type_bad; }
        size = 8;
        default_action = ing_type_bad;
        const entries = {
            (8w1, MSG_ACTION_LABEL) : ing_type_label();
            (8w1, MSG_LABEL_REVOKE) : ing_type_revoke();
        }
    }

    // function 白名单：全部已实现功能都接受（包括 egress 执行的）。
    // ★ 接受不等于执行：本 block 只在 exec_decide 里执行 PORT_REDIRECT，
    //   其余功能落缓存后即完成「覆盖旧动作」的语义。
    // ★ 常量字 = 0x01000000(valid) | function_id —— valid 位直接进常量，
    //   写 reg_ing_lbl 时零运算（D26）。
    action ing_func_yes(bit<32> w) { meta.ing_func_ok = 1w1; meta.ing_func_word = w; }
    action ing_func_no()           { meta.ing_func_ok = 1w0; meta.ing_func_word = 32w0; }
    table ing_label_func {
        key = { hdr.action_label.function_id : exact; }
        actions = { ing_func_yes; ing_func_no; }
        size = 8;
        default_action = ing_func_no;
        const entries = {
            (FUNC_NOOP)          : ing_func_yes(32w0x01000000);
            (FUNC_PRIORITY_SET)  : ing_func_yes(32w0x01000002);
            (FUNC_PORT_REDIRECT) : ing_func_yes(32w0x01000003);
            (FUNC_ECN_MARK)      : ing_func_yes(32w0x01000004);
            (FUNC_DROP)          : ing_func_yes(32w0x01000005);
            (FUNC_MEASURE)       : ing_func_yes(32w0x01000006);
        }
    }

    // ★ S1 起 ingress 不再校验 priority / flow 通配（D26）：priority 不进缓存，
    //   通配 flow 不会匹配任何真实数据包。两张表省下的 stage 留给数据面。

    // expiry 合法性 + 「有效 expiry」归一化。
    // ★ 0xFFFF（协议里的永不过期）在 ingress 侧折算成 ING_NEVER_EXPIRY，
    //   这样数据面只比较 deadline，不需要再判 never 位（D26）。
    action ing_exp_ok()    { meta.ing_expiry_ok = 1w1; meta.ing_exp_raw = hdr.action_label.expiry; }
    action ing_exp_never() { meta.ing_expiry_ok = 1w1; meta.ing_exp_raw = ING_NEVER_EXPIRY; }
    action ing_exp_bad()   { meta.ing_expiry_ok = 1w0; meta.ing_exp_raw = 16w0; }
    table ing_label_expiry {
        key = { hdr.action_label.expiry : range; }
        actions = { ing_exp_ok; ing_exp_never; ing_exp_bad; }
        size = 4;
        default_action = ing_exp_bad;
        const entries = {
            (16w0 .. 16w0x7FFF)      : ing_exp_ok();
            (16w0xFFFF .. 16w0xFFFF) : ing_exp_never();
        }
    }

    // ★ Week2 S2（小邹加）：priority 单独寄存器（见 reg_ing_pri）。
    //   试过塞进 reg_ing_dl 高 16 位，但 `(bit<32>)rx_dl_raw | pri_word` 报
    //   `action spanning multiple stages`；拆成独立寄存器后写入是纯零扩展。

    // ★ Week2 S3（小邹加）：action_id -> 常量字，写进 reg_ing_lbl 的 [11:4]。
    //   与 func_word 只做一次同宽或（32|32），符合 D26 的单运算约束。
    action ing_act_word(bit<32> w) { meta.ing_act_word = w; }
    table ing_label_act {
        key = { hdr.action_label.action_id : exact; }
        actions = { ing_act_word; }
        size = 8;
        default_action = ing_act_word(32w0);
        const entries = {
            (8w0) : ing_act_word(32w0x00000000);   // sketch0
            (8w1) : ing_act_word(32w0x00000010);   // sketch1（1 << 4）
        }
    }

    // ===================== 数据面：过期 / 执行判定 =====================
    // ★ deadline 与 expired 合并成一张表：key 里带 valid + 有符号差值范围，
    //   直接输出「是否过期」，省掉一张中间表（D26）。
    action ing_exp_yes() { meta.ing_expired = 1w1; }
    action ing_exp_no()  { meta.ing_expired = 1w0; }
    table ing_expired_decide {
        key = { meta.ing_valid : exact;
                meta.ing_ddead : range; }
        actions = { ing_exp_yes; ing_exp_no; }
        size = 4;
        default_action = ing_exp_no;
        const entries = {
            (1w1, 16w1 .. 16w0x7FFF) : ing_exp_yes();   // 有效且已过 deadline
        }
    }

    // ★ S1 只有 PORT_REDIRECT 有表项；S2 / S3 往这里加 PRIORITY_SET / MEASURE。
    action ing_exec_none()     { meta.ing_do_exec = 1w0; meta.ing_exec_func = FUNC_NOOP; }
    action ing_exec_redirect() { meta.ing_do_exec = 1w1; meta.ing_exec_func = FUNC_PORT_REDIRECT; }
    action ing_exec_priority() { meta.ing_do_exec = 1w1; meta.ing_exec_func = FUNC_PRIORITY_SET; }
    table ing_exec_decide {
        key = { meta.ing_valid     : exact;
                meta.ing_flow_diff : exact;   // 0 = 缓存里就是这条流
                meta.ing_expired   : exact;
                meta.ing_func      : exact; }
        actions = { ing_exec_none; ing_exec_redirect; ing_exec_priority; }
        size = 8;
        default_action = ing_exec_none;
        const entries = {
            (1w1, 32w0, 1w0, FUNC_PORT_REDIRECT) : ing_exec_redirect();
            (1w1, 32w0, 1w0, FUNC_PRIORITY_SET)  : ing_exec_priority();
        }
    }

    apply {
        // ★ 选路默认值：与部署前逐比特一致（回环到入口端口）。
        ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
        ig_tm_md.qid = 0;                      // ★ 补默认值：否则无动作时 qid 未初始化
        meta.now_tick = ig_prsr_md.global_tstamp[31:16];

        if (hdr.action_label.isValid()) {
            /* ============================================================
             *  标签包：ingress 侧第一次处理
             *  ★ 处理完**不丢弃**，照常交给 egress：
             *    egress 还要做 Week1 的版本校验、落它自己那份缓存、再丢包。
             * ============================================================ */
            // 槽位：标签携带的 flow_id → 控制面下发的槽位（D27）
            slot_map_ing_lbl.apply();

            ing_label_type.apply();
            if (meta.ing_type_ok == 1) {
                if (meta.ing_is_revoke == 1) {
                    // REVOKE：清本槽的 ingress 缓存（valid=0），
                    // 对应任务书 week1「上报后清空寄存器，直到收到新标签，期间只正常转发」。
                    meta.ing_lbl_word = 32w0;
                    ing_lbl_wr_ra.execute(meta.slot);
                    meta.ing_flow_word = 32w0;
                    ing_flow_wr_ra.execute(meta.slot);
                    meta.ing_port_word = 32w0;
                    ing_port_wr_ra.execute(meta.slot);
                    // ★ 小邹补：deadline 与 priority 也必须一起清，
                    //   否则 exec 用的还是旧优先级 / 旧 deadline。
                    meta.ing_dl_word = 32w0;
                    ing_dl_wr_ra.execute(meta.slot);
                    meta.ing_pri_word = 32w0;
                    ing_pri_wr_ra.execute(meta.slot);
                } else {
                    ing_label_func.apply();     // func_ok + func_word（常量含 valid）
                    ing_label_act.apply();      // action_id -> 常量字（选 sketch）
                    ing_label_expiry.apply();   // expiry_ok + 归一化 expiry

                    if (meta.ing_func_ok == 1) {
                        if (meta.ing_expiry_ok == 1) {
                            // ★ 三个寄存器各写一次，lbl 与 dl 零运算（D26）：
                            //   lbl 的常量字自带 valid；deadline 只做一次 16 位加。
                            meta.ing_lbl_word = meta.ing_func_word | meta.ing_act_word;

                            // deadline 在接收时算一次：now + expiry（16 位自然回绕）
                            bit<16> rx_dl_raw = (bit<16>)(meta.now_tick + meta.ing_exp_raw);
                            meta.ing_dl_word = (bit<32>)rx_dl_raw;
                            meta.ing_pri_word = (bit<32>)hdr.action_label.priority;

                            // ★ D27：flow_id 与端口各占一个寄存器，写入都是纯
                            //   零扩展（0 运算），不再有 `<<16 | ` 这种两级依赖。
                            //   action_id 推迟到 S3（MEASURE 另开寄存器）。
                            meta.ing_flow_word = (bit<32>)hdr.action_label.flow_id;
                            meta.ing_port_word = (bit<32>)hdr.action_label.egress_port;

                            ing_lbl_wr_ra.execute(meta.slot);
                            ing_dl_wr_ra.execute(meta.slot);
                            ing_flow_wr_ra.execute(meta.slot);
                            ing_port_wr_ra.execute(meta.slot);
                            ing_pri_wr_ra.execute(meta.slot);
                        }
                    }
                }
            }
            // 校验不过：ingress 一个寄存器都不写；包仍交给 egress 处理。

        } else if (hdr.ipv4.isValid() && hdr.tcp.isValid()) {
            /* ============================================================
             *  数据包：读取 ingress 缓存并执行 ingress 侧动作
             *  ★ flow_id 的计算必须与 egress 完全一致（md/01 §1.1）。
             * ============================================================ */
            // ★ D27：流标识（flow_id + 槽位）由控制面按五元组下发。
            //   数据面不再做任何异或 —— 多级 ALU 链在 bf-p4c 里放不进
            //   单个 action，且 copy-prop 会把表达式跨表重新内联。
            flow_key_ing.apply();

            bit<32> ilbl = ing_lbl_ra.execute(meta.slot);
            meta.ing_valid       = ilbl[24:24];
            meta.ing_func        = (bit<8>)ilbl[3:0];
            meta.ing_act         = (bit<8>)ilbl[11:4];   // S3：action_id = 选哪个 sketch

            // ★ Week2 S3（小邹加）：只有该流缓存的 function_id == MEASURE 时才计数，
            //   并按 action_id 0/1 分别进 sketch0 / sketch1（服务器 5+5 指定分桶）。
            if (meta.ing_func == FUNC_MEASURE) {
                meta.ing_cms_i0 = meta.flow_id[4:0];
                if (meta.ing_act == 8w1) {
                    meta.ing_cms_cnt = cms1_inc_ra.execute(meta.ing_cms_i0);
                } else {
                    meta.ing_cms_cnt = cms0_inc_ra.execute(meta.ing_cms_i0);
                }
            }

            bit<32> idl = ing_dl_ra.execute(meta.slot);
            meta.ing_deadline_raw = (bit<16>)idl;
            meta.ing_pri          = (bit<8>)(ing_pri_ra.execute(meta.slot));   // S2：独立寄存器读

            // 读动作内直接算「本次 flow_id − 缓存 flow_id」，0 = 命中本流
            meta.ing_flow_diff = ing_flow_ra.execute(meta.slot);

            bit<32> iport = ing_port_ra.execute(meta.slot);
            meta.ing_egress_port = (bit<8>)iport;

            meta.ing_ddead = (bit<16>)(meta.now_tick - meta.ing_deadline_raw);
            ing_expired_decide.apply();   // valid + 有符号差值 → 是否过期

            ing_exec_decide.apply();

            if (meta.ing_do_exec == 1) {
                if (meta.ing_exec_func == FUNC_PORT_REDIRECT) {
                    ig_tm_md.ucast_egress_port = (bit<9>)meta.ing_egress_port;
                }
                // ★ Week2 S2（小邹加）：PRIORITY_SET -> 出队列 qid
                if (meta.ing_exec_func == FUNC_PRIORITY_SET) {
                    ig_tm_md.qid = (bit<5>)meta.ing_pri;
                }
            }
        }
        // 其余情况（ARP / LLDP / 非 TCP IPv4 / 解析失败）：纯转发。
    }
}

/*************************************************************************
 **************  E G R E S S   P R O C E S S I N G  *********************
 *************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 in egress_intrinsic_metadata_t eg_intr_md,
                 in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
                 inout egress_intrinsic_metadata_for_deparser_t eg_intr_dprs_md,
                 inout egress_intrinsic_metadata_for_output_port_t eg_intr_oprt_md) {

    // ===================== 寄存器 =====================
    // ★ 全部是 32 位单字。同一物理寄存器每包最多被一个 RegisterAction 访问。
    //   本版**没有 A/B 副本、没有相位寄存器**。
    //
    //   reg_cfg            阈值 + path_avail（控制面写）
    //   reg_ctx_last[16]   每流：上次判决（低 3 位）
    //   reg_ver[16]        每流：当前上下文版本（跨越时 +1）
    //   reg_rep_ver[16]    每流：最近一次随包上报的版本（每包一次 RMW）
    //   reg_label[16]      每流：动作标签缓存
    //   reg_label_flow[16] 每流：完整 flow_id + 标签版本
    Register<bit<32>, bit<16>>(1) reg_cfg;
    // ★ 2026-10-17：寄存器索引必须是「表输出 PHV」。
    //   bf-p4c 对 XOR 计算值直接当索引报 `The index is too complex`；
    //   16/256 槽、4/8 位切片都试过，均失败。现在先由 slot_map 表
    //   把 flow_id[7:0] 映射成 0..15，slot 是表动作的输出。
    Register<bit<32>, bit<8>>(16) reg_ctx_last;
    Register<bit<32>, bit<8>>(16) reg_ver;
    Register<bit<32>, bit<8>>(16) reg_rep_ver;
    Register<bit<32>, bit<8>>(16) reg_label;      // func(bit19..16)+valid(bit24)；低 16 位 = context_id（D27）
    Register<bit<32>, bit<8>>(16) reg_label_dl;   // deadline（低 16 位，D26 拆出）
    Register<bit<32>, bit<8>>(16) reg_label_flow; // 低 16 位 = flow_id（D27 拆出，写入零运算）

    // ===================== 指标量化 =====================
    // 量化用 range table 完成，**不消耗任何寄存器访问**。
    // ⚠️ 桶边界是占位值，上机后按 V8 实测的 deq_qdepth 单位重标定。
    // ★ D27：quantize 表直接把等级写进 ctx_report 头。
    //   flow_id / queue / load / path / _rsv0 在报文里是**连续的 32 位**，
    //   bf-p4c 会合并成一条指令，源超过 2 个就报
    //   `Action ... requires too many sources`。让每一项在自己的 stage 里写，
    //   指令就不会被合并。（头无效时写字段是合法的，只有 setValid 后才发出。）
    action set_ctx_queue(bit<4> c) { meta.ctx_queue = (bit<8>)c; hdr.ctx_report.queue_level = c; }
    // ★ 2026-10-24：去 const，改成**运行时可写**（桶边界由 md_ctl --q-bounds 标定，
    //   调参不用再重编译）。默认 0 = 未配置时不判拥塞，避免 placeholder 桶误导。
    table quantize_queue {
        key = { eg_intr_md.deq_qdepth : range; }   // ⚠️ 字段名/位宽待编译期验证
        actions = { set_ctx_queue; }
        size = 16;
        default_action = set_ctx_queue(4w0);
    }

    // ---- 端口负载量化（deq_timedelta：入队→出队的排队时延，ns）----
    // ★ V-2（2026-10-30 修正）：它是**排队时延**，不是相邻出队间隔。
    //   时延越大 = 越拥塞 = 等级越高，所以桶是**升序**的（md_ctl --l-bounds 按升序写）。
    //   本表无 const entries，边界全部由控制面运行时写入；默认 0。
    action set_ctx_load(bit<4> c) { meta.ctx_load = (bit<8>)c; hdr.ctx_report.load_level = c; }
    // ★ 2026-10-24：去 const，运行时标定（md_ctl --l-bounds）。默认 0。
    table quantize_load {
        key = { eg_intr_md.deq_timedelta : range; }   // ★ 实测为 bit<18>（编译期确认）
        actions = { set_ctx_load; }
        size = 16;
        default_action = set_ctx_load(4w0);
    }

    // ===================== 上报目的地闸门（D24）=====================
    // ★ 只允许把 ctx_report_t 搭在**发往服务器**的数据包上。
    //   控制面把服务器 IPv4 地址装进这张表（bfrt table add），默认拒绝。
    //   默认拒绝意味着：没配表就完全不上报 —— 这是有意的安全默认；
    //   V5 必须先把服务器 IP 装进表，否则看不到任何上报。
    //   ⚠️ 本包的目的地址不变、EtherType 被改成 0x5555；服务器侧 agent
    //      必须能识别并剥掉 24 字节头（见 md/01 §1 与 md/03 V6）。
    // ★ D28：path_level / _rsv0 的写操作塞进本表动作，省掉单独的写头 stage
    //   （egress 12 级 stage 装不下原来的 16 级依赖链）。
    action set_report_ok(bit<1> ok) {
        meta.can_report = ok;
        hdr.ctx_report.path_level = (bit<4>)meta.ctx_path;
        hdr.ctx_report._rsv0       = 4w0;
    }
    table report_dst {
        key = { hdr.ipv4.dstAddr : exact; }
        actions = { set_report_ok; }
        size = 16;
        default_action = set_report_ok(0);
    }

    // ===================== 槽位映射：让寄存器索引由表产出 =====================
    // ★ bf-p4c 不接受 XOR 计算值直接当 RegisterAction 的索引（报
    //   `The index is too complex`）。把 flow_id[7:0] 经这张 16 项 range 表
    //   映射成 0..15，meta.slot 就是表动作输出的 PHV，索引形状一定简单。
    //   ★ 映射 = flow_id[7:4]；10 条流实验仍建议选低 4 位互不相同的流。
    // ★ bf-p4c 不允许同一张表在一个 control 里 apply 两次（next-table 信息
    //   无法传播），因此标签面和数据面各用一张表。
    // ★ D27：与 ingress 相同 —— 流标识由控制面下发，数据面零异或。
    //   两张表必须与 ingress 的两张同内容、同映射（同一控制面脚本安装）。
    action set_slot(bit<8> s) { meta.slot = s; }
    action set_flow(bit<16> fid, bit<8> s) { meta.flow_id = fid; meta.slot = s; }
    table slot_map_lbl {
        key = { hdr.action_label.flow_id : exact; }
        actions = { set_slot; }
        size = 64;
        default_action = set_slot(8w0);
    }
    table flow_key {
        key = { hdr.ipv4.srcAddr : exact;
                hdr.ipv4.dstAddr : exact;
                hdr.tcp.srcPort  : exact;
                hdr.tcp.dstPort  : exact; }
        actions = { set_flow; }
        size = 64;
        default_action = set_flow(16w0xFFFF, 8w0);
    }

    // ===================== 所有 RegisterAction =====================
    // ★ 读动作：apply() 只有一行 out_v = v（0 运算、0 比较、0 局部变量）。
    // ★ 写动作：out_v = v; v = meta.xxx;（整字写满，0 比较）。
    // ★ 同一物理寄存器上的多个动作只会在互斥分支里执行。

    // ---- reg_cfg：只读（控制面写）----
    RegisterAction<bit<32>, bit<16>, bit<32>>(reg_cfg) cfg_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
        }
    };

    // ---- reg_ctx_last：数据面单次 RMW（写值不依赖旧值）----
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ctx_last) ctx_rmw_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.ctx_word;
        }
    };

    // ---- reg_ver：数据面单次 RMW；跨越时 +1 ----
    // ★ 已验证形状（action_label.p4 的 ctx_ver_rmw）：
    //   写条件是「flag == 1」，写值是「寄存器 + 立即数」。
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_ver) ver_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            if (meta.inc_ver == 1) { v = v + 32w1; }
            out_v = v;                  // 输出自增后的当前版本
        }
    };
    // ★ D29（2026-10-24）：删除标签面的 ver_diff_ra。
    //   原因不是省寄存器，而是**省 stage**：同一个 Register 在一个 block 里
    //   只能有一个物理访问点，reg_ver 的「数据面写 + 标签面读」被迫融合，
    //   融合点被数据面的 RMW 拖到 stage 8，于是标签分支的 ctx 校验在 stage 10、
    //   标签三个寄存器在 stage 11-12、expired/exec 被推到 14-15（共 17 级）。
    //   去掉标签面的读之后，标签侧只剩 label_type/func/expiry 三个无寄存器
    //   检查，融合点提前到 stage 2-3。
    //   ★ 安全性不变：数据面 exec_decide 已经用 ver_xor==0 复核版本
    //     （见 exec_decide 的表项），过期/陈旧标签不可能被执行。
    //   代价：陈旧标签可能覆盖同槽位的新标签（只影响缓存内容，不影响执行）。

    // ---- reg_rep_ver：数据面单次 RMW，每包都执行 ----
    //   out = 上次真正上报的版本；v = 本次版本（仅 can_report=1 时写）。
    //   ★ 2026-10-17 简化：不再在 apply() 里条件执行 RegisterAction
    //     （那需要给局部变量二次赋值）。条件写放进 sALU 内：
    //     1 次比较，非上报包 v 原样写回，语义不变。
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_rep_ver) rep_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            if (meta.can_report == 1) { v = meta.cur_ver; }
        }
    };

    // ---- reg_label / reg_label_flow：数据面只读、标签面只写 ----
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label) lbl_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label) lbl_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.label_word;
        }
    };
    // ---- reg_label_dl：deadline 单独一个寄存器（D26）----
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label_dl) ldl_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label_dl) ldl_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.dl_word;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label_flow) lblflow_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
        }
    };
    RegisterAction<bit<32>, bit<8>, bit<32>>(reg_label_flow) lblflow_wr_ra = {
        void apply(inout bit<32> v, out bit<32> out_v) {
            out_v = v;
            v = meta.label_flow_word;
        }
    };

    // ★ D29：ctx_match / ctx_nonzero_check 已删除（见 ver_diff_ra 处的说明）。
    //   版本绑定与「context_id==0」的防御全部由数据面 exec_decide 承担：
    //   那里 key 含 ver_xor，源码里 ver_xor 只在标签 context_id == reg_ver
    //   时为 0；reg_ver 初值 0 时，未绑定过的槽位也要求标签 context_id==0
    //   才可能命中——而这类标签在 Week1 控制面不会下发。
    // ===================== 标签面：类型 / 预检 =====================
    // ★ 判定全部由表输出 flag；apply() 里的 if 只判断 flag 与常量。
    action lbl_type_label()  { meta.type_ok = 1w1; meta.is_revoke = 1w0; }
    action lbl_type_revoke() { meta.type_ok = 1w1; meta.is_revoke = 1w1; }
    action lbl_type_bad()    { meta.type_ok = 1w0; meta.is_revoke = 1w0; }
    table label_type {
        key = { hdr.action_label.switch_id : exact;
                hdr.action_label.msg_type  : exact; }
        actions = { lbl_type_label; lbl_type_revoke; lbl_type_bad; }
        size = 8;
        default_action = lbl_type_bad;
        const entries = {
            (8w1, MSG_ACTION_LABEL) : lbl_type_label();
            (8w1, MSG_LABEL_REVOKE) : lbl_type_revoke();
        }
    }

    // ③a function 白名单 + 标签字低段：表 action 直接给出已移位的 32 位常量。
    //   ★ 2026-10-17 第三轮：把「掩码 + 移位 + 或」从 apply() 挪进表项常量。
    //     bf-p4c 会把 apply() 里的每条赋值编成单 stage action，混合位宽的
    //     mask/shift/or 无法单 stage 完成（`action spanning multiple stages`）。
    // ★ D27：valid 位（bit24）折进常量，标签字就只剩一次「或 context_id」。
    action func_yes(bit<32> w) { meta.func_ok = 1w1; meta.func_word = w; }
    action func_no()           { meta.func_ok = 1w0; meta.func_word = 32w0; }
    table label_func {
        key = { hdr.action_label.function_id : exact; }
        actions = { func_yes; func_no; }
        size = 8;
        default_action = func_no;
        const entries = {
            (FUNC_NOOP)          : func_yes(32w0x01000000);   // valid | function_id<<16
            (FUNC_PRIORITY_SET)  : func_yes(32w0x01020000);
            (FUNC_PORT_REDIRECT) : func_yes(32w0x01030000);   // Week2 / ingress 执行
            (FUNC_DROP)          : func_yes(32w0x01050000);
            (FUNC_ECN_MARK)      : func_yes(32w0x01040000);
            (FUNC_MEASURE)       : func_yes(32w0x01060000);   // Week2 / ingress 执行
        }
    }

    // ③b priority / ④b flow 通配校验：★ S1 起删除（D26）。
    //   - egress 缓存不再保存 priority，校验它没有下游意义；S2 需要时再加回。
    //   - 通配 flow_id 的标签写进缓存后不会匹配任何真实数据包（数据面按完整
    //     flow_id 比较），因此「非通配」校验可以省掉一张表。
    //   两张表合计省下约 2 级 stage，这是让 ingress Week2 逻辑放得下所必需的。

    // ⑤b expiry 合法性 + 归一化，一张 range 表搞定。
    //   ★ 2026-10-17 简化：expiry 是相对偏移，`now − (now + expiry)` 恒等于
    //     `−expiry`，原先的 ddl 减法与 range 表是纯冗余。只有最高位为 1 的
    //     （有符号为负的）畸形值需要拒收。
    // ★ D27（2026-10-23）：与 ingress 一致，0xFFFF（协议里的永不过期）折算成
    //   0x7FFF（≈2.14 s）；valid 位折进 label_func 的常量字。标签字因此不再
    //   需要 never 位，写入只剩「常量 | context_id」一次或。
    action exp_ok()    { meta.expiry_ok = 1w1; meta.exp_raw = hdr.action_label.expiry; }
    action exp_never() { meta.expiry_ok = 1w1; meta.exp_raw = 16w0x7FFF; }
    action exp_bad()   { meta.expiry_ok = 1w0; meta.exp_raw = 16w0; }
    table label_expiry {
        key = { hdr.action_label.expiry : range; }
        actions = { exp_ok; exp_never; exp_bad; }
        size = 4;
        default_action = exp_bad;
        const entries = {
            (16w0 .. 16w0x7FFF)      : exp_ok();      // 正常相对偏移
            (16w0xFFFF .. 16w0xFFFF) : exp_never();   // 永不过期
        }
    }

    // ★ S1 起不再用 label_precheck 表合并 flag：apply() 里用嵌套
    //   `if (flag == 1)` 表达合取，省一张表（D26）。

    // ===================== 数据面：跨越 / 过期判定 =====================
    // ★ 全部由表输出 flag：apply() 里的三目运算一旦流入这些上报表的键，
    //   bf-p4c 会报「Conditions in an action must be simple comparisons」
    //   （2026-10-17 实测）。flag 只作键，if 只判表输出。
    // ★ 三指标判决（2026-10-22 简化）：bf-p4c 既不许两个 PHV 直接比大小
    //   （"one operand of >= must be constant"），也不接受「差值取切片 / 比 0」
    //   （"action spanning multiple stages" / "condition expression too complex"）。
    //   最终做法：apply() 里只做三条减法，判决交给一张三项 range 表。
    //   减法走 8 位无符号（D28）：差值只有 -15..15，负值回绕到 241..255，
    //   所以边界仍是常量 16：
    //     dq < 16  ⇔ q >= th（无借位，违规）  dq >= 16 ⇔ q < th
    //     dl < 16  ⇔ l >= th                  dl >= 16 ⇔ l < th
    //     dp >= 16 ⇔ p <  th（有借位，违规）  dp < 16  ⇔ p >= th
    action vd0() { meta.verdict_now = 3w0; }
    action vd1() { meta.verdict_now = 3w1; }
    action vd2() { meta.verdict_now = 3w2; }
    action vd3() { meta.verdict_now = 3w3; }
    action vd4() { meta.verdict_now = 3w4; }
    action vd5() { meta.verdict_now = 3w5; }
    action vd6() { meta.verdict_now = 3w6; }
    action vd7() { meta.verdict_now = 3w7; }
    table verdict_map {
        key = { meta.dq : range;
                meta.dl : range;
                meta.dp : range; }
        actions = { vd0; vd1; vd2; vd3; vd4; vd5; vd6; vd7; }
        size = 16;
        default_action = vd0;
        const entries = {
            (8w0  .. 8w15, 8w0  .. 8w15, 8w0  .. 8w15) : vd3();   // Q L
            (8w0  .. 8w15, 8w0  .. 8w15, 8w16 .. 8w255) : vd7();  // Q L P
            (8w0  .. 8w15, 8w16 .. 8w255, 8w0  .. 8w15) : vd1();  // Q
            (8w0  .. 8w15, 8w16 .. 8w255, 8w16 .. 8w255) : vd5(); // Q P
            (8w16 .. 8w255, 8w0  .. 8w15, 8w0  .. 8w15) : vd2();  // L
            (8w16 .. 8w255, 8w0  .. 8w15, 8w16 .. 8w255) : vd6(); // L P
            (8w16 .. 8w255, 8w16 .. 8w255, 8w0  .. 8w15) : vd0(); // 无
            (8w16 .. 8w255, 8w16 .. 8w255, 8w16 .. 8w255) : vd4();// P
        }
    }

    // ★ D28：timestamp 的写操作放进本表动作 —— 它原本单独占一个 stage
    //   当「屏障」，现在由这张表本身当屏障，正好省一级。
    action crossed_yes() { meta.ctx_crossed = 1w1; meta.inc_ver = 8w1;
                           hdr.ctx_report.timestamp = meta.now_tick; }
    action crossed_no()  { meta.ctx_crossed = 1w0; meta.inc_ver = 8w0;
                           hdr.ctx_report.timestamp = meta.now_tick; }
    table crossed_decide {
        key = { meta.crossed_mask : exact; }
        actions = { crossed_yes; crossed_no; }
        size = 4;
        default_action = crossed_yes;
        const entries = {
            (3w0) : crossed_no();   // 本次判决与上次完全一致
        }
    }

    // ★ D28：原先是 data_deadline_past + expired_decide 两张表（两级 stage），
    //   合并成一张：键 = (ddead 的跨零区间, 标签有效位)。
    //   ddead = now_tick - deadline_raw（16 位有符号差值）：
    //     ddead ∈ 1..0x7FFF  ⇔ 已过 deadline
    //     ddead ∈ 0x8000..0xFFFF ⇔ 未到 deadline
    //   顺带把 _rsv1 的常量写进本表动作（省一个纯写头 stage）。
    action exp_yes() { meta.expired = 1w1; hdr.ctx_report._rsv1 = 16w0; }
    action exp_no()  { meta.expired = 1w0; hdr.ctx_report._rsv1 = 16w0; }
    table expired_decide {
        key = { meta.ddead : range;
                meta.label_valid : exact; }
        actions = { exp_yes; exp_no; }
        size = 4;
        default_action = exp_no;
        const entries = {
            (16w1 .. 16w0x7FFF, 1w1) : exp_yes();   // 标签有效且已过 deadline
        }
    }

    // ===================== 数据面：执行判定 =====================
    // 执行条件：标签有效 + 版本未失效 + 未过期 + flow 完全一致 + 功能命中。
    // ★ D29：执行效果直接写进表动作，消掉 exec_decide 之后的三层 if
    //   （cond-35 do_exec → cond-36/37 exec_func），省 2-3 个 stage。
    action exec_drop()     { eg_intr_dprs_md.drop_ctl = 1; }
    action exec_ecn()      { hdr.ipv4.diffserv = hdr.ipv4.diffserv | 8w0x03; }
    action exec_priority() { /* ★ 队列选择只能在 ingress（D16）；egress 空执行。 */ }
    action exec_none()     { }
    table exec_decide {
        key = { meta.label_valid : exact;
                meta.ver_xor     : exact;
                meta.expired     : exact;
                meta.flow_xor    : exact;
                meta.label_func  : exact; }
        actions = { exec_drop; exec_ecn; exec_priority; exec_none; }
        size = 8;
        default_action = exec_none;
        const entries = {
            (1w1, 32w0, 1w0, 16w0, FUNC_DROP)         : exec_drop();
            (1w1, 32w0, 1w0, 16w0, FUNC_ECN_MARK)     : exec_ecn();
            (1w1, 32w0, 1w0, 16w0, FUNC_PRIORITY_SET) : exec_priority();
        }
    }

    /*********************************************************************
     *  A P P L Y
     *********************************************************************/
    apply {
        // ★ 补默认值：只有标签分支会置 1，数据包必须显式清 0，否则 drop 未初始化。
        eg_intr_dprs_md.drop_ctl = 0;
        // ★ D28：不再整字搬 global_tstamp（meta.tstamp 是死字段，48 bit 只赋值不读，
        //   还会让 global_tstamp 在整个 egress 里保持活跃，加重 PHV 压力）。
        meta.now_tick = eg_intr_md_from_prsr.global_tstamp[31:16];

        if (hdr.ipv4.isValid() && hdr.tcp.isValid()) {
            /* ============================================================
             *  数据包路径
             *  ★ 必须同时是 IPv4 + TCP；否则纯转发，一个寄存器都不碰。
             * ============================================================ */

            // ---- 流量标识：由控制面按五元组下发（D27）----
            // ★ flow_id 与槽位都来自 flow_key 表，数据面零异或。
            flow_key.apply();
            // ★ 上报头里「flow_id + _rsv0」必须凑成同一个 32 位容器**一次性写满**
            //   （Tofino：同一容器内的局部写必须保持「已写/未写」两端连续，且
            //   源数 ≤2）。这里 flow_id 来自表输出、_rsv0 是常量，正好 2 个源。
            //   后面 queue/load/path/context_id/timestamp 再按容器顺序往下写。
            hdr.ctx_report.flow_id = meta.flow_id;

            // ---- 步骤 1: reg_cfg ----
            bit<32> cfg = cfg_ra.execute(16w0);
            // ★ D28：reg_cfg 按字节对齐解读（每字段 8 位）。
            //   旧布局 cfg[4:0]/[9:5]/[14:10]/[18:15] 是错位小片，
            //   Tofino PHV 切片是字节粒度的，会直接导致分配失败。
            meta.th_queue   = cfg[7:0];      // 队列等级阈值（0..15；≥16 = 永不判违规）
            meta.th_load    = cfg[15:8];     // 负载等级阈值
            meta.th_path    = cfg[23:16];    // 路径等级阈值
            meta.path_avail = cfg[31:24];    // 路径可用等级（0..15，越大越好）

            // ---- 指标量化（range table，零寄存器访问）----
            //   ★ 表动作顺手把等级写进 ctx_report（见 set_ctx_queue 注释）。
            quantize_queue.apply();
            quantize_load.apply();
            meta.ctx_path = meta.path_avail;

            // ---- 本包能否把上报送到服务器（D24）----
            //   ★ D28：path_level / _rsv0 的写操作已挪进本表动作，省 stage。
            report_dst.apply();

            // ---- 步骤 2: 读标签缓存 + 完整 flow_id + cached_ver ----
            bit<32> lbl = lbl_ra.execute(meta.slot);
            meta.label_valid        = lbl[24:24];
            meta.label_func         = (bit<8>)lbl[19:16];
            meta.cached_ver         = (bit<16>)lbl;      // D27：低 16 位存 context_id

            // deadline 在独立寄存器（D26）
            bit<32> ldl = ldl_ra.execute(meta.slot);
            meta.label_deadline_raw = (bit<16>)ldl;

            bit<32> llf = lblflow_ra.execute(meta.slot);
            meta.label_flow_id = (bit<16>)llf;

            // ---- 步骤 3: 过期判定（表给 flag，apply() 只做纯运算/查表）----
            //   有符号差值 ddead > 0 表示已过 deadline。
            //   ★ D28：deadline 判定与「标签有效」合并成一张 expired_decide。
            meta.ddead = (bit<16>)(meta.now_tick - meta.label_deadline_raw);
            expired_decide.apply();

            // ---- 步骤 3b: 本次判决（三条减法 + 一张 range 表，见 verdict_map）----
            meta.dq = meta.ctx_queue - meta.th_queue;
            meta.dl = meta.ctx_load  - meta.th_load;
            meta.dp = meta.ctx_path  - meta.th_path;
            verdict_map.apply();

            // ---- 步骤 4: reg_ctx_last 单次 RMW ----
            //   out_v = 旧字（上次判决），v = 本次判决。
            //   ★ 简化后只存 3 位判决；初值 0 即「上次无违规」。
            meta.ctx_word = (bit<32>)meta.verdict_now;
            bit<32> cout = ctx_rmw_ra.execute(meta.slot);

            // 本次判决 ^ 上次判决 = 翻转图
            bit<3> crossed3 = meta.verdict_now ^ ((bit<3>)cout[2:0]);
            meta.crossed_mask = crossed3;
            crossed_decide.apply();         // 掩码 == 0 → 未跨越；同时给出 inc_ver

            // ★ D28：timestamp 的写操作在 crossed_decide 的表动作里完成，
            //   本表同时充当与 reg_ver 之间的 stage 屏障。

            // ---- 步骤 5: reg_ver 单次 RMW（跨越时 +1）----
            meta.cur_ver = ver_ra.execute(meta.slot);
            // ★ 32 位 context_id 必须拆两个 stage 写（D28 实测）：
            //   整字写需要「容器本身 + cur_ver[15:0] + cur_ver[31:16]」= 3 个 PHV 源，
            //   Tofino 只允许 2 个。拆成两个 16 位半区、中间隔一个 RegisterAction
            //   屏障，每次就只剩「容器 + 1 个半区」= 2 个源。
            hdr.ctx_report.context_id[15:0] = meta.cur_ver[15:0];

            // ---- 步骤 6: 上报判定 ----
            //   ★ 每包都执行 reg_rep_ver 的 RMW；Action 内部只在 can_report=1
            //     时推进版本，所以没发出去的上报不会把这个版本吞掉。
            //   ★ 比较写成独立 if（两个 PHV 比较 + 1 位赋值），不写成三目。
            bit<32> old_rep = rep_wr_ra.execute(meta.slot);
            meta.report_due = 1w0;
            if (old_rep != meta.cur_ver) { meta.report_due = 1w1; }
            // ★ 不要写成 meta.report_due & meta.can_report：bf-p4c 对这种
            //   「非常量 & 表达式」当 if 条件会报
            //   "condition too complex, one operand of & must be constant"。
            //   改用下面两层嵌套 if（每层都是 PHV 位 == 常量）。
            // context_id 高半区（与低半区隔了 reg_rep_ver 的 RMW，必在不同 stage）
            hdr.ctx_report.context_id[31:16] = meta.cur_ver[31:16];

            // ---- 步骤 7: 上报（本包第一次承载该版本）----
            //   ★ 只剩下 valid + etherType：其余字段都已在前面的 stage 写好。
            if (meta.report_due == 1) {
                if (meta.can_report == 1) {
                    hdr.ctx_report.setValid();
                    // ★ v0.4（D28）：switch_id / port_id / diag_value / diag_metric /
                    //   crc16 / _pad 已从协议删除；剩下的常量放最后一批，
                    //   此时已写区间是 {16..111}，补上 {0..15} 正好写满。
                    hdr.ctx_report.version  = PROTO_VERSION;
                    hdr.ctx_report.msg_type = MSG_CTX_REPORT;
                    hdr.ctx_report.flags    = 8w0;
                    hdr.ethernet.etherType = TYPE_CTX_REPORT;
                }
            }

            // ---- 步骤 8: 执行网络内功能 ----
            //   条件：标签有效 + 版本未失效 + 未过期 + flow 完全一致 + 功能命中。
            //   ver_xor / flow_xor 为 0 表示相等，表项只放常量 0。
            // ★ 32 位异或：不要取 cur_ver[15:0]，否则 cur_ver 会被劈成两个半区
            meta.ver_xor  = ((bit<32>)meta.cached_ver) ^ meta.cur_ver;
            meta.flow_xor = meta.label_flow_id ^ meta.flow_id;
            exec_decide.apply();

            // ★ D29：执行效果已在 exec_decide 的表动作里完成，不再有 if 链。

        } else if (hdr.action_label.isValid()) {
            /* ============================================================
             *  标签包路径（服务器 → 交换机）
             *  ★ 校验顺序：先做不碰寄存器的检查，再做写操作。
             * ============================================================ */
            // 槽位：标签携带的 flow_id → 控制面下发的槽位（D27）
            slot_map_lbl.apply();

            // ★ 标签帧一律不上线：放在分支入口，后续各分支不必重复设置
            eg_intr_dprs_md.drop_ctl = 1;

            // ① switch_id / ② msg_type：表输出 flag，if 只判 flag
            label_type.apply();
            if (meta.type_ok == 1) {
                if (meta.is_revoke == 1) {
                    // REVOKE：清本流槽位的标签、deadline 与 flow_id。
                    // ★ 不重置 reg_ver / reg_rep_ver —— 旧版本不能被重放。
                    meta.label_word = 32w0;
                    lbl_wr_ra.execute(meta.slot);
                    meta.dl_word = 32w0;
                    ldl_wr_ra.execute(meta.slot);
                    meta.label_flow_word = 32w0;
                    lblflow_wr_ra.execute(meta.slot);
                } else {
                    // ③ 白名单 + ⑤ expiry：两个 flag 用嵌套 if 表达合取。
                    //   （priority / 通配 flow / precheck 表已在 S1 删除，见 D26）
                    label_func.apply();     // func_ok + func_word
                    label_expiry.apply();   // expiry_ok + 归一化后的 exp_raw

                    if (meta.func_ok == 1) {
                        if (meta.expiry_ok == 1) {
                            // ★ D29：不再做版本绑定校验（不读 reg_ver）。
                            //   旧标签可能覆盖同槽位的新标签，但数据面 exec_decide
                            //   用 ver_xor / expired / flow_xor 复核，不会误执行。
                            meta.label_ctx_id = hdr.action_label.context_id;

                            // ⑧ 标签字 = 常量(func|valid) | context_id（单次或，D27）
                            meta.label_word = meta.func_word | meta.label_ctx_id;
                            lbl_wr_ra.execute(meta.slot);

                            // deadline 单独一个寄存器（D26），只用归一化后的 expiry
                            bit<16> rx_dl_raw = (bit<16>)(meta.now_tick + meta.exp_raw);
                            meta.dl_word = (bit<32>)rx_dl_raw;
                            ldl_wr_ra.execute(meta.slot);

                            // flow 单独一个寄存器，写入是纯零扩展（D27）
                            meta.label_flow_word = (bit<32>)hdr.action_label.flow_id;
                            lblflow_wr_ra.execute(meta.slot);
                        }
                    }
                }       // else（LABEL，非 REVOKE）
            }           // if (meta.type_ok == 1)
            // 任何一项校验不过也只是丢标签包：drop_ctl 已在分支入口置 1


        }        // 其余情况（ARP / LLDP / 非 TCP IPv4 / 解析失败）：纯转发，不碰寄存器。
    }
}

/*************************************************************************
 *  P I P E L I N E
 *************************************************************************/

Pipeline(MyIngressParser(),
         MyIngress(),
         MyIngressDeparser(),
         MyEgressParser(),
         MyEgress(),
         MyEgressDeparser()) pipe;

Switch(pipe) main;
