# min-disclosure — P4/Tofino 数据面

「加密传输最小披露」贡献 2 的数据面实现：交换机读取网络上下文（队列深度、端口负载、
路径可用性），在阈值被越过时向服务器上报；服务器回发**动作标签**，交换机缓存并执行。

本仓库只包含 P4 源码；控制面脚本、协议 Python 库和实验记录不在公开范围。

## 文件

| 文件 | 内容 |
|---|---|
| `min_disc.p4` | `MyIngress` / `MyEgress` 两个 block：标签解析与缓存、上下文判决、上报封装、量化表 |
| `include/headers.p4` | 头定义（`action_label_t` 24B / 0x4444、`ctx_report_t` 14B / 0x5555）、metadata |
| `include/parsers.p4` | ingress / egress parser |

## 协议要点

- **ctx_report**：14 字节，EtherType `0x5555`，搭在发往服务器的数据包上上报。
- **action_label**：24 字节，EtherType `0x4444`，服务器 → 交换机，交换机消费后丢弃。
- 标签字段：`flow_id / function_id / context_id / action_id / priority / egress_port /
  epoch / expiry / sequence`，CRC16 目前填 0（数据面不校验）。

## 编译（Tofino 1，BF-SDE 9.10）

```bash
cd /root/bf-sde-9.10.0
source ./set_sde.bash
export PATH=$SDE_INSTALL/bin:$PATH

mkdir -p build_min_disc && cd build_min_disc
cmake /root/bf-sde-9.10.0/p4studio/ \
  -DCMAKE_INSTALL_PREFIX=$SDE_INSTALL \
  -DCMAKE_MODULE_PATH=/root/bf-sde-9.10.0/cmake \
  -DP4_NAME=min_disc \
  -DP4_PATH=/path/to/p4/min_disc.p4
make -j4 min_disc
make install
```

当前版本编译结果为 **0 error / 5 warning**，ingress 使用 MAU stage 0–6，egress 0–10。

## 设计约束（改代码前必读）

TNA/Tofino 1 的硬限制：

- 一个 `Register` 每包只能有一次 `RegisterAction`；读和写不能分成两个动作。
- 单个 `RegisterAction` 内最多 2 次比较；不允许局部变量、切片赋值、32 位 `~`。
- Register 的写入必须是单个简单运算（例如不能把 `deadline | priority` 打包后一次写入，
  会报 `action spanning multiple stages`）。
- Hash Dist Unit 已 100% 占用，不要再加 `Hash` / CRC 计算。
- `Resubmit` 只能在 ingress deparser 发出。

## 说明

- 量化表 `quantize_queue` / `quantize_load` 没有 `const entries`，等级桶由控制面在运行时写入；
  未配置时默认 0。
- `deq_timedelta` 是「入队→出队」的排队时延（ns），**时延越大等级越高**（升序桶）。
- ingress 动作用于 qid 的优先级目前只受标签 `expiry` 约束，尚未绑定 context。
