# 更新日志

## 2026-10-31 — 同步远端：每流包序号 + 阈值禁用值修复

### 1. 数据面：每流包序号（小邹提交 `72277b3`）

- `p4/min_disc.p4` 新增 `reg_pkt_seq`（16 槽 × 32 位）与 `pktseq_ra`，每个
  IPv4+TCP 包在 egress 执行一次 `+1`，结果写进 `ctx_report._rsv1`
  （低 16 位）。**帧长与线格式不变。**
- `tools/md_agent.py`：报告解码把 `rsv1` 改名 `pkt_seq`，下发标签的
  `sequence` 改为回填该值。
- ⚠️ 计数**不受 flow 登记 / expiry / 是否上报门控**：未登记流落到 slot 0，
  所有未登记流量共用该槽。与两个直接索引计数器同属待修的 P0 问题。
- ✅ 2026-10-31 上机编译通过：0 error / 5 warning（与基线相同的 5 条
  parser 警告）；`reg_pkt_seq` 与 `reg_rep_ver` 同处 **egress stage 9**，
  命名表的 stage 范围与 10-30 基线一致（ingress 0–6 / egress 0–10），
  未新增流水级。

### 2. 控制面：阈值禁用值 255 → 16（小邹提交 `55fc775`）

- `verdict_map` 用 8 位减法判 `0..15` / `≥16`，所以 `th = 16` 才是禁用值；
  写 `255` 会得到 `level - 255 ≡ level + 1`，对 level 0–14 恒违规。
- `md_ctl.py` 的默认值/help 改为 16。本次补充：显式传
  `--th-queue 255` / `--th-load 255` 时告警并按 16 处理，兼容旧脚本。
- 之前运行实例的 `reg_cfg = 0x0F00FF03`（`th_load = 255`）正是这个 bug，
  下一轮测试应写 `th_load = 16`。

### 3. 本次同步修复（本地）

- `README.md`：示例 `--th-load 255` → `16`，阈值语义同步说明回绕问题。
- `proto/ctx_report.py`：新增 `pkt_seq` 字段；`encode()` 写入该字段，
  `decode(strict=True)` 不再要求 `_rsv1 == 0`（`_rsv0` 仍必须为 0）；
  `to_dict()` / `__repr__` 同步。
- `proto/constants.py`：`CTX_REPORT_LAYOUT` 中 `_rsv1` 加复用说明（字段名不变，
  仍与 `headers.p4` 对齐）。
- `md/01-protocol-spec.md`：字段表更新为 `pkt_seq`；补充门控条件与
  `sequence` 当前不承担防重放的说明；新增 v0.4-rev2 变更记录。
- `md_ctl.py`：上述 255 兜底。

### 4. 仍待验证

- 运行时验证 `pkt_seq` 是否按预期递增（寄存器 dump / 抓 0x5555 报告）。
  本次编译**未 `make install`**；不过交换机当前安装的 `min_disc`（小邹
  2026-10-31 16:23 安装）的 `bf-rt.json` md5 与新编译一致
  （`c29a4b5a92f7d0921aaeeacf629346b2`），已包含 `reg_pkt_seq`。
- 计数器/包序号的 flow 与 expiry 门控（P0）。
- `qid` 是否在 TM 真正生效（读每队列计数）。

---

## 2026-10-30 — 采纳小邹的 Week2 改版

### 1. 数据面采纳

- `p4/min_disc.p4`：**采用你的版本**（md5 `ef23c0c7…`），包含优先级寄存器、
  两个直接索引计数器、REVOKE 补清、量化表去 `const entries`、默认值。
- `p4/include/headers.p4`：**没有直接覆盖**，用的是合并版。
  原因：你的 headers 基于旧的 5-bit 打包 `CFG_*`，而工作区已在 D28 改为字节对齐
  （`cfg[7:0]=th_queue`、`[15:8]=th_load`、`[23:16]=th_path`、`[31:24]=path_avail`，
  禁用值 `CFG_TH_DISABLED=16`）。直接覆盖会让控制面 `cfg_word()` 全部错位。
  合并版保留工作区的 `CFG_*`，只插入你新增的 6 个 metadata 字段：
  `ing_pri / ing_pri_word / ing_cms_i0 / ing_cms_cnt / ing_act / ing_act_word`。
  **已验证合并版与你的原版编译出的 `bf-rt.json` md5 相同（`179a513e…`），控制面 API 无差异。**
- `p4/include/parsers.p4`：未改。

### 2. 负载量化方向修正（V-2）

`egress_intrinsic_metadata_t.deq_timedelta` 是**入队→出队的排队时延（ns）**，
不是相邻出队间隔（BF-SDE `tofino1_base.p4:255` 明确写了）。
所以「间隔越短负载越高」的降序桶是反的——空闲时会上报 `load_level=15`（实测 `q=1 l=15`）。

- 现在：**边界升序 → 等级升序**，时延越大等级越高。
- 量化表已无 `const entries`，方向完全由控制面 `md_ctl --l-bounds` 决定；
  `write_buckets()` 里的 `reverse` 参数已删除。
- `min_disc.p4` 里对应注释已同步改正。

### 3. 控制面工具修改（`tools/`，不在本仓库）

- `md_ctl.py`
  - `--l-bounds` 改为升序语义，删除 `reverse`；
  - 写 bounds 前先清空旧 range 条目（`--keep-buckets` 可跳过），避免重叠区间命中不确定；
  - 修复单独 `--dump` 时 `reg`/`key` 未定义导致的 NameError；
  - 新增 `--reset-ing`：清 `reg_ing_lbl/dl/flow/port/pri` 与两个计数器。
- `make_flows_pcap.py`
  - 更正过时说明：flow_id 由控制面 `flows10.json` 指定（1..10），
    sketch 下标 = `flow_id[4:0]`；当前是 2 × 1 × 32 直接索引计数器；
    `equal` 是当前模式，`calib` 仅保留兼容旧实验。

### 4. 编译结果（交换机，BF-SDE 9.10.0）

| 版本 | 结果 | MAU stage（ingress / egress） |
|---|---|---|
| Week1 基线 | 0 error / 5 warning | 0–8 / 0–10 |
| 你的原版 | 0 error / 5 warning | 0–6 / 0–10 |
| 合并 headers 版 | 0 error / 5 warning | 0–6 / 0–10 |

- 你文档里「12 stage 通过」不准确：ingress 实际只用到 7 个 stage（0–6），egress 用满 11 个（0–10）。
- 编译时注意：先 `export PATH=$SDE_INSTALL/bin:$PATH`，否则 cmake 报 `P4C-NOTFOUND`；
  报错后删 `CMakeCache.txt` / `CMakeFiles` 重跑 cmake 即可。

### 5. 交换机侧变更（2026-10-30）

- 用独立程序名 `md_test` 编译安装，**未覆盖** `install/share/tofinopd/min_disc/`。
- ⚠️ `make install` 会**顺带覆盖** `install/share/p4/targets/tofino/min_disc.conf`，
  已用 `p4learn/build_min_disc/.../min_disc.conf` 还原。
  以后装新程序名务必检查这个 conf。
- `md_test` 的 switchd 启动后、运行时验证（量化表 / 5+5 计数 / 寄存器 dump）开始前，
  设备被另一个登录的 `bf_switchd -p cmsketch` 占用，验证**尚未完成**。

### 6. 仍待处理

- **计数器未按流/有效期门控**：计数动作在 `ing_dl_ra.execute` / `ing_expired_decide`
  之前执行，未登记流、过期流、普通转发流量都会被计数。
- **ingress 动作仍未绑定 context**：qid/端口只受 `expiry` 约束（你文档坑 #5 也提到）。
- **qid 是否在 TM 真正生效**未验证（需要读每队列计数）。
- 术语修正：`reg_ing_cms*` 是**直接索引计数器**，不是 Count-Min Sketch，
  论文里不要写 CMS 的精度保证。
