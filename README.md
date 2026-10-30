# min-disclosure — 加密传输最小披露

P4-16 / Tofino 实现的「上下文绑定的动作标签生成与更新协议」：
交换机只根据网络上下文执行**受约束的动作**，不获得可复用的应用状态字段。

> 核心主张：把网络可观测性从「暴露状态字段」改为「暴露动作标签」。
> 交换机不需要知道该流的 deadline 是 7.3 ms，只需要知道"现在该做什么"。

---

## 目录

| 目录 | 用途 |
|---|---|
| `p4/` | P4-16 TNA 数据面：标签解析/缓存、上下文判决、上报封装、量化表 |
| `proto/` | 协议编解码 Python 库（字节级字段表、CRC16、tick 换算），与 P4 共用同一份字段定义 |
| `tools/` | 交换机控制面、服务器侧 agent、测试流量生成脚本 |
| `md/` | 协议规格与设计决策文档（部分内部实验记录未公开） |

### `tools/` 各文件

| 文件 | 运行位置 | 作用 |
|---|---|---|
| `md_ctl.py` | 交换机 | 用 bfrt gRPC 装/查表：上报目的地、阈值、10 条流的四张映射表、运行时量化桶；dump 寄存器与计数器 |
| `md_agent.py` | 服务器 | 监听 `ctx_report`（0x5555），按等级决策并回发 `action_label`（0x4444）；支持 `priority` / `measure` 两种模式 |
| `make_flows_pcap.py` | 任意 | 生成 10 条 Modbus/TCP 五元组的 pcap（`equal` / `single` / `calib` 模式），与 `flows10.json` 一致 |
| `flows10.json` | — | 10 条测试流：`src 192.168.10.101–110`，`sport 40000–40009`，`dst 192.168.10.1:1502` |

### `proto/` 各文件

| 文件 | 内容 |
|---|---|
| `constants.py` | EtherType、长度、function_id、字段偏移 —— **P4 与 Python 的共同真源** |
| `fields.py` | 位域读写辅助 |
| `action_label.py` / `ctx_report.py` | 24 B 标签 / 14 B 上报的编解码 |
| `crc16.py` | CRC16（当前数据面不校验，填 0） |
| `timebase.py` | 16-bit tick 与毫秒换算、回绕处理 |
| `errors.py` | 解析错误类型 |

---

## 协议

| 协议 | EtherType | 长度 | 方向 |
|---|---|---|---|
| `ctx_report_t` | `0x5555` | 14 B | 交换机 → 服务器（搭在数据发往服务器的包上） |
| `action_label_t` | `0x4444` | 24 B | 服务器 → 交换机（交换机消费后丢弃） |

标签字段：`flow_id / function_id / context_id / action_id / priority /
egress_port / epoch / expiry / sequence`。

---

## 编译（Tofino 1，BF-SDE 9.10）

```bash
cd /root/bf-sde-9.10.0
source ./set_sde.bash
export PATH=$SDE_INSTALL/bin:$PATH          # 缺这行 cmake 会报 P4C-NOTFOUND

mkdir -p build_min_disc && cd build_min_disc
cmake /root/bf-sde-9.10.0/p4studio/ \
  -DCMAKE_INSTALL_PREFIX=$SDE_INSTALL \
  -DCMAKE_MODULE_PATH=/root/bf-sde-9.10.0/cmake \
  -DP4_NAME=min_disc \
  -DP4_PATH=/path/to/p4/min_disc.p4
make -j4 min_disc
make install
```

当前版本：**0 error / 5 warning**；ingress 使用 MAU stage 0–6，egress 0–10。

> 装新程序名时注意：`make install` 会顺带覆盖
> `install/share/p4/targets/tofino/<已有程序>.conf`，装完要检查并还原。

---

## 跑一轮测试

```bash
# 1) 交换机：装上报目的地、阈值、10 条流、运行时量化桶
python3 tools/md_ctl.py --prog min_disc --server-ip <server-ip> \
  --flows-file tools/flows10.json \
  --th-queue 1 --th-load 255 --th-path 0 --path-avail 15 \
  --q-bounds "5,20,100" --l-bounds "100,1000,10000" \
  --reset-ctx --reset-ing

# 2) 服务器：生成 pcap 并打流
python3 tools/make_flows_pcap.py --mode equal --per-flow 500 -o flows10_equal.pcap
sudo tcpreplay -i <iface> --pps=2000 flows10_equal.pcap

# 3) 服务器：agent（measure 模式：flow 1–5 进 sketch0，6–10 进 sketch1）
sudo python3 tools/md_agent.py --iface <iface> --mode measure --verbose

# 4) 交换机：查状态
python3 tools/md_ctl.py --prog min_disc --server-ip <server-ip> \
  --dump --dump-regs --dump-cms --dump-egress
```

阈值语义（`reg_cfg` 按字节对齐）：

- `th_queue` / `th_load`：`level >= th` 判违规；`255` = 禁用。
- `th_path`：`level < th` 判违规；`0` = 禁用。
- `path_avail`：越大越好，`15` = 最好。
- `deq_timedelta` 是**排队时延**（ns），越大等级越高，`--l-bounds` 必须升序。

---

## 设计约束（改 P4 前必读）

- 一个 `Register` 每包只能有一次 `RegisterAction`；读写不能分成两个动作。
- 单个 `RegisterAction` 内最多 2 次比较；不允许局部变量、切片赋值、32 位 `~`。
- Register 写入必须是单个简单运算（`deadline | priority` 这类会报 `action spanning multiple stages`）。
- Hash Dist Unit 已 100% 占用，不要再加 `Hash` / CRC 计算。
- `Resubmit` 只能在 ingress deparser 发出。

---

## 文档

- `md/00-overview.md`：课题背景与 Week1 范围
- `md/01-protocol-spec.md`：字节级字段表与状态机（**单一真源**）
- `md/02-design-decisions.md`：设计决策与被否决方案
- `md/06-rule-model-and-theory.md`：规则生成模型与形式化
- `CHANGELOG.md`：最近改动
- `p4/README.md`：数据面细节

内部实验记录与设备接入方式不在公开范围。
