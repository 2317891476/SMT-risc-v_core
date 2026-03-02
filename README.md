# AdamRiscv

## 1. 项目概述

`AdamRiscv` 是一个 RV32I 教学处理器实现，当前主线结构为 9 级流水：

`IF -> IS -> RO -> EX1 -> EX2 -> EX3 -> EX4 -> MEM -> WB`

本版本核心特性：
- 在不改变主流水级数量的前提下，引入了基于 `Scoreboard + Reservation Station (RS)` 的集中式调度。
- `IS` 与 `RO` 解耦：指令先进入 Scoreboard 窗口，等操作数就绪且 FU 空闲后再发射到 `RO`。
- 使用 `sb_tag`（动态指令标签）跟踪依赖，写回时广播唤醒等待项。
- **SMT（超线程）支持**：2 个硬件线程（Thread 0 / Thread 1）共享执行流水，拥有独立 PC 和寄存器堆，Round-Robin 取指调度，per-thread flush。

---

## 2. 目录结构

```text
AdamRiscv/
├─ module/CORE/RTL_V1_2/         # 核心 RTL
│  ├─ adam_riscv.v               # 顶层
│  ├─ scoreboard.v               # 记分牌+RS窗口（SMT多线程隔离）
│  ├─ thread_scheduler.v         # [SMT新增] Round-Robin 取指调度器
│  ├─ pc_mt.v                    # [SMT新增] 双线程 PC 管理器
│  ├─ regs_mt.v                  # [SMT新增] 双 bank 寄存器堆
│  ├─ stage_if.v stage_is.v stage_ro.v stage_ex.v stage_mem.v stage_wb.v
│  ├─ reg_if_id.v reg_is_ro.v reg_ro_ex.v reg_ex_stage.v reg_ex_mem.v reg_mem_wb.v
│  ├─ ctrl.v imm_gen.v alu.v alu_control.v ...
├─ comp_test/
│  ├─ run_iverilog_tests.ps1      # 一键构建ROM+仿真+判分
│  ├─ module_list                 # iverilog 源文件清单
│  ├─ tb.sv test_content.sv       # testbench（支持 test1/test2/test_smt）
│  └─ out_iverilog/               # 仿真输出（日志/波形/可执行）
├─ rom/
│  ├─ test1.s test2.S            # 单线程回归用例
│  ├─ test_smt.s                  # [SMT新增] 双线程功能验证用例
│  ├─ harvard_link.ld             # 链接脚本
│  ├─ inst.hex data.hex           # 仿真加载镜像
│  └─ main_s.elf/.map/.dump/.o    # 构建中间产物
└─ libs/REG_ARRAY/SRAM/ram_bfm.v  # 行为级RAM模型
```

---

## 2.1 SMT 改造主要文件

### 新增（SMT专用）
- `thread_scheduler.v` — Round-Robin 取指线程调度器
- `pc_mt.v` — 双线程独立 PC 管理器（per-thread stall/flush）
- `regs_mt.v` — 双 bank 寄存器堆（`reg_bank[tid][addr]`，含同线程 WB 旁路）
- `rom/test_smt.s` — SMT 双线程功能验证程序

### 改造
- `scoreboard.v` — `reg_result_status` 变为 `[2][32]`，RS 项增加 `win_tid`，依赖检测/flush 均按线程隔离
- `stage_if.v` — 接入 `pc_mt`，输出 `if_tid`
- `stage_ro.v` — 接入 `regs_mt`，按 `ro_tid` 读写寄存器 bank
- `adam_riscv.v` — 顶层全面重连，接入 `thread_scheduler`，全流水 `tid` 通路
- `reg_if_id / reg_is_ro / reg_ro_ex / reg_ex_stage / reg_ex_mem / reg_mem_wb` — 全部新增 `tid` 透传字段，并实现 per-thread flush

## 3. 环境配置

## 3.1 必需工具

`comp_test/run_iverilog_tests.ps1` 会检查以下工具是否在 `PATH`：

- `riscv-none-elf-gcc`
- `riscv-none-elf-objdump`
- `riscv-none-elf-objcopy`
- `iverilog`
- `vvp`

可选工具：
- `gtkwave`（用于自动打开 VCD 波形）

## 3.2 Windows (PowerShell) 示例

```powershell
$env:PATH = "C:\riscv\bin;C:\iverilog\bin;C:\gtkwave\bin;" + $env:PATH
riscv-none-elf-gcc --version
iverilog -V
vvp -V
```

## 3.3 Linux/macOS 示例

```bash
export PATH=/opt/riscv/bin:/opt/iverilog/bin:/opt/gtkwave/bin:$PATH
riscv-none-elf-gcc --version
iverilog -V
vvp -V
```

## 3.4 ROM 布局约定

链接脚本 `rom/harvard_link.ld` 固定：
- `.text` 起始地址：`0x00000000`
- `.data/.sdata` 起始地址：`0x00001000`

这与 testbench 加载方式匹配，请勿随意修改地址布局。

---

## 4. 快速开始

在仓库根目录执行：

```powershell
cd .\comp_test #需进入测试目录
.\run_iverilog_tests.ps1
```

或：

```powershell
cd .\comp_test
.\run_iverilog_tests.bat
```

默认会跑 `test1.s` 与 `test2.S`。

---

## 5. 脚本使用说明

主脚本：`comp_test/run_iverilog_tests.ps1`

参数：
- `-Tests <string[]>`：指定测试集合
- `-NoGtkWave`：不自动打开波形
- `-StopOnError`：首个错误立即停止

示例：

```powershell
# 只跑 test2，并禁用gtkwave
.\run_iverilog_tests.ps1 -Tests test2.S -NoGtkWave

# 自定义多用例
.\run_iverilog_tests.ps1 -Tests @("test1.s","test2.S")
```

脚本执行流程：
1. 用 `riscv-none-elf-gcc` 编译汇编，链接生成 `rom/main_s.elf`。
2. 用 `objcopy` 导出 `rom/inst.hex` 和 `rom/data.hex`。
3. 根据 `comp_test/module_list` 调 `iverilog` 编译 testbench。
4. `vvp` 运行仿真，日志落到 `comp_test/out_iverilog/logs/*.log`。
5. 若生成 `tb.vcd`，移动到 `comp_test/out_iverilog/waves/*.vcd`。
6. 根据日志关键字判断 `PASS/FAIL/ERROR` 并汇总。

输出目录：
- `comp_test/out_iverilog/bin/`：编译后的仿真可执行文件
- `comp_test/out_iverilog/logs/`：仿真日志
- `comp_test/out_iverilog/waves/`：波形文件

---

## 6. 顶层数据流与时序

当前顶层关键控制（见 `module/CORE/RTL_V1_2/adam_riscv.v`）：
- `stall = sb_rs_full`：仅当 RS 窗口满时阻塞前端。
- `is_push = is_valid && !sb_rs_full && !flush`：IS 指令进入 Scoreboard 的入队条件。
- `ro_fire = ro_valid`：RO 寄存器中有有效指令即前推到 EX。
- `flush = br_ctrl`：分支跳转触发前端冲刷。

主数据流：
1. IF 取指，`reg_if_id` 缓冲。
2. IS 解码，形成控制/寄存器/FU 信息。
3. Scoreboard 入队并跟踪依赖。
4. Scoreboard 选择就绪指令，送入 `reg_is_ro`。
5. RO 从寄存器堆读取源操作数。
6. EX1 运算，EX2~EX4 打拍。
7. MEM 访存。
8. WB 写回，同时向 Scoreboard 广播 `wb_fu/wb_rd/wb_sb_tag`。

---

## 7. 模块接口说明（重点）

下面只列核心模块与关键接口语义。完整端口请直接查看对应 RTL 文件。

## 7.1 `adam_riscv.v`（顶层）

输入输出：
- `sys_clk`：系统时钟
- `sys_rstn`：系统复位（低有效）
- `led[2:0]`：仅 `FPGA_MODE` 下有效

内部关键互联：
- `stage_is -> scoreboard`：`is_*` 入队字段
- `scoreboard -> reg_is_ro`：`sb_issue_*` 被选中发射字段
- `reg_mem_wb -> scoreboard`：`wb_fu/wb_rd/wb_regs_write/wb_sb_tag` 回写广播

## 7.2 `scoreboard.v`（调度窗口）

输入分组：
- 时序/控制：`clk/rstn/flush`
- 入队接口：`is_push + is_*`
- 写回广播：`wb_fu/wb_rd/wb_regs_write/wb_sb_tag`

输出分组：
- 反压：`rs_full`
- 发射：`ro_issue_valid + ro_issue_* + ro_issue_sb_tag + ro_issue_tid`

内部语义（SMT 扩展）：
- `win_tid[RS_DEPTH]`：每个 RS 项的线程归属
- `reg_result_status[2][32]`：分线程的寄存器未来值生产者 tag
- 依赖检测（RAW/WAW/WAR）仅在同 `thread_id` 内进行
- `flush_tid`：per-thread flush，只清当前分支线程的 RS 项

## 7.3 `stage_is.v`（Issue Decode）

输入：`is_inst/is_pc`

输出：
- 解码控制：`is_alu_op/is_mem_read/is_mem_write/is_br/...`
- 寄存器号：`is_rs1/is_rs2/is_rd`
- 使用掩码：`is_rs1_used/is_rs2_used`
- 功能单元编号：`is_fu`
- 有效标志：`is_valid`

`is_valid` 为 1 表示该指令被支持并可入队。

## 7.4 `reg_is_ro.v`（Scoreboard->RO 缓冲）

输入：`issue_en/issue_*`（来自 Scoreboard）和 `ro_fire`

输出：`ro_valid/ro_*`

行为：
- `issue_en=1` 时装载新发射指令。
- `ro_fire=1` 时消费当前项。
- `flush` 时清空。

## 7.5 `stage_ro.v` + `regs_mt.v`（读操作数）

`stage_ro` 按 `ro_tid` 选择寄存器 bank，读出对应线程的 `ro_regs_data1/2`。

`regs_mt.v` 支持：
- 双 bank（Thread 0 和 Thread 1 各一份 32×32bit 寄存器）
- 按 `r_thread_id` 读，按 `w_thread_id` 写
- 同线程 WB 同拍读写旁路（跨线程不旁路）

## 7.6 `reg_ro_ex.v`（RO->EX1）

将 RO 阶段控制和数据（含 `ro_sb_tag`）寄存到 EX 输入。

## 7.7 `reg_ex_stage.v`（EX1->EX2->EX3->EX4 通用打拍）

输入：`in_*`

输出：`out_*`

用于把 ALU 结果、访存控制、`fu` 与 `sb_tag` 跨多个 EX 子阶段传递。

## 7.8 `stage_ex.v`（执行）

输入：操作数、立即数、ALU 控制、分支控制。

输出：
- `ex_alu_o`：ALU结果/地址
- `ex_regs_data2_o`：Store 数据通路
- `br_pc/br_ctrl`：分支目标与分支生效

## 7.9 `reg_ex_mem.v`、`stage_mem.v`、`reg_mem_wb.v`、`stage_wb.v`

- `reg_ex_mem.v`：EX4->MEM 寄存，传递访存控制、`fu`、`sb_tag`。
- `stage_mem.v`：字节/半字/字访存写掩码与读数据输出。
- `reg_mem_wb.v`：MEM->WB 寄存，回写 `wb_fu/wb_sb_tag` 给 Scoreboard。
- `stage_wb.v`：根据 `wb_mem2reg` 和 load 类型选择最终写回数据。

## 7.10 `reg_if_id.v`（IF->IS 缓冲）

在 `stall/flush` 条件下保持稳定指令，避免前端长 stall 时指令漂移。

---

## 8. 与原版相比的主要改动

相对原“顺序 IS->RO 直连 + 简化 scoreboard”版本，当前主要工作包括：

1. 引入集中式 RS 窗口
- `scoreboard.v` 支持指令缓存、依赖跟踪、选择发射、写回唤醒。

2. IS/RO 解耦
- 取消严格 FIFO 的 IS->RO 直通关系。
- 改为 IS 入队、Scoreboard 选择后再发射给 RO。

3. `reg_result_status` 语义升级
- 从“寄存器由哪个 FU 生产”改为“寄存器由哪个动态 `sb_tag` 生产”。

4. `sb_tag` 全流水透传
- `reg_is_ro/reg_ro_ex/reg_ex_stage/reg_ex_mem/reg_mem_wb` 新增 `sb_tag`。
- WB 可精准唤醒对应等待项。

5. 冲突处理增强
- RAW：通过 `qj/qk` 等待生产者写回。
- WAW：通过 `qd` 防止年轻写覆盖老写语义。
- WAR：通过 age+检查（`win_seq` + `war_block`）避免年轻写先于老读。

6. 前端 stall 稳定性修正
- `reg_if_id.v` 在 stall 进入时锁存并保持稳定指令。

---

## 9. 验证流程

## 9.1 自动回归

```powershell
cd .\comp_test
# 运行单线程回归
.\run_iverilog_tests.ps1
# 运行 SMT 功能验证
.\run_iverilog_tests.ps1 -Tests @("test1.s", "test2.S", "test_smt.s") -NoGtkWave
```

期望看到 Summary 中：
- `test1.s PASS`
- `test2.S PASS`
- `test_smt.s PASS`

## 9.2 判分机制说明

`comp_test/test_content.sv` 通过以下方式判定 PASS：
1. 根据 `IROM[0]` 识别当前镜像是 `test1` 还是 `test2`。
2. 等待 `DRAM[0][7:0] == 8'h04`（程序写 tube/结束标记）。
3. 延时后检查寄存器与内存的确定值。
4. 任一条件不满足即 FAIL。
5. 200us 超时强制 FAIL。

## 9.3 SMT 波形调试

运行 `test_smt.s` 后打开 `waves/test_smt.vcd`，建议观察：
- `fetch_tid`：Round-Robin 取指线程切换
- `if_tid / ro_tid / ex_tid / wb_tid`：tid 随流水线传播
- `WRITE T0 / WRITE T1`（`$display` 输出）：两线程交替写回
- `DRAM[1152] = 0x37`、`DRAM[1153] = 0x1E`：SMT 计算结果落盘

## 9.4 波形调试（通用）

建议重点观察信号：
- `is_push`, `sb_rs_full`
- `ro_issue_valid`, `ro_issue_sb_tag`, `ro_issue_fu`, `ro_issue_tid`
- `wb_sb_tag`, `wb_fu`, `w_regs_en`, `w_regs_addr`, `wb_tid`
- `win_valid/win_issued/win_qj/win_qk/win_qd`（若展开内部）

---

## 10. 手动构建 ROM（可选）

如果你希望单独生成 `inst.hex/data.hex`，可参考脚本内命令：

```powershell
riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none `
  -Wl,-T,rom/harvard_link.ld -Wl,-Map,rom/main_s.map `
  -march=rv32i -mabi=ilp32 rom/test1.s -o rom/main_s.elf

riscv-none-elf-objdump -S -l rom/main_s.elf -M no-aliases,numeric > rom/main_s.dump

riscv-none-elf-objcopy -j .text -O verilog rom/main_s.elf rom/inst.hex
riscv-none-elf-objcopy -j .data -j .sdata -O verilog rom/main_s.elf rom/data.hex
```

---

## 11. 后续可继续优化的模块

建议优先级从高到低：

1. `scoreboard.v`
- 支持多发射/多选择策略。
- 支持更严格的内存相关（Load/Store 顺序、地址相关检测）。
- 用 CDB 风格结果广播替代仅 WB 唤醒（可减少等待周期）。

2. `stage_ro.v` / `regs.v`
- 引入更完整旁路网络，减少“等到 WB 才能发射”的保守策略。

3. `adam_riscv.v`
- 当前仍编译进部分旧模块（如 `hazard_detection/forwarding/stage_id`）以保持兼容，可清理为最小文件集。

4. `reg_mem_wb.v` / `reg_ex_mem.v`
- 清理调试 `display`，加 `ifdef` 调试开关，避免大量日志影响速度。

5. `comp_test`
- 增加更多 ISA 子集测试（branch/jump/load-store corner case）。
- 增加随机指令流与长时回归脚本。

6. 异常与架构完整性
- 增加 trap/exception、精确中断、非法指令处理。
- 后续可扩展 CSR/M 模式（超出当前 RV32I 教学范围）。

---

## 12. 常见问题（FAQ）

Q1: 脚本提示找不到工具？
- 确认 `riscv-none-elf-*`、`iverilog`、`vvp` 在 `PATH`。

Q2: 波形没自动打开？
- 安装 `gtkwave` 或使用 `-NoGtkWave` 手动打开 `waves/*.vcd`。

Q3: 修改了 `rom/*.s` 但结果没变？
- 确认脚本是否真的跑到了该测试（`-Tests` 参数），并检查 `logs/*.log` 对应用例名。

Q4: 为什么有些旧模块还在 `module_list`？
- 当前以“稳定回归优先”，保留了一些兼容项；不影响主数据流已切换到 IS/RO/Scoreboard 架构。

---

## 13. 当前状态

- 默认回归：`test1.s`、`test2.S` 均通过。
- SMT 验证：`test_smt.s` 通过（Thread 0 计算 1+2+...+10=55，Thread 1 计算 10×3=30，结果正确落盘）。
- 主干功能：9 级流水 + Scoreboard/RS OoO 调度 + 2线程 SMT 均可用。
- 已知局限：当前 OoO 调度器对 store 指令缺乏内存顺序约束（无 store buffer），测试程序需在分支后插入 NOPs 以规避投机 store。
