# RTL 模块接口列表 (Module Interface Catalog)

自动从 `rtl/*.v` 与 `fpga/rtl/*.v` 提取。每个模块给出：
源文件、角色简介、参数列表、端口列表（保持 RTL 中声明顺序）。

共 70 个模块。

## 索引

### 00. 顶层 / 集成

- [`adam_riscv`](#adam_riscv) - `rtl/adam_riscv.v` - OoO 双发射 RV32IM SMT 核心顶层（IF/Decode/Dispatch/Exec/Mem/WB 串接）

### 01. 取指 (IF) 与分支预测

- [`bpu_bimodal`](#bpu_bimodal) - `rtl/bpu_bimodal.v` - 分支预测器：bimodal
- [`fetch_buffer`](#fetch_buffer) - `rtl/fetch_buffer.v` - 取指缓冲 FIFO（16-entry，支持双弹出给双解码）
- [`pc_mt`](#pc_mt) - `rtl/pc_mt.v` - SMT 多线程 PC 管理
- [`stage_if`](#stage_if) - `rtl/stage_if.v` - 取指级（IF）：PC 选择 + ICache 接口 + BPU 集成 + per-thread fetch

### 02. 解码 (Decode)

- [`decoder_dual`](#decoder_dual) - `rtl/decoder_dual.v` - 双发射解码：结构冒险检测（双分支 / 双 mem / WAW）

### 03. Dispatch / Rename / OoO 中枢

- [`dispatch_unit`](#dispatch_unit) - `rtl/dispatch_unit.v` - 乱序中枢：rename/freelist + 3xIQ(INT/MEM/MUL) + pipe1 仲裁 + ROB 分配（最复杂模块）
- [`freelist`](#freelist) - `rtl/freelist.v` - 物理寄存器 freelist
- [`iq_pipe1_arbiter`](#iq_pipe1_arbiter) - `rtl/iq_pipe1_arbiter.v` - pipe1 端 MEM/MUL/DIV/ALU 仲裁
- [`issue_queue`](#issue_queue) - `rtl/issue_queue.v` - 通用发射队列（INT/MEM/MUL/DIV 共用模板）
- [`phys_regfile`](#phys_regfile) - `rtl/phys_regfile.v` - 物理寄存器堆（48-entry, 4R2W）
- [`rename_map_table`](#rename_map_table) - `rtl/rename_map_table.v` - 重命名映射表 + checkpoint

### 04. 执行 (Execute)

- [`alu`](#alu) - `rtl/alu.v` - 基本 ALU
- [`alu_control`](#alu_control) - `rtl/alu_control.v` - ALU 控制译码
- [`bypass_network`](#bypass_network) - `rtl/bypass_network.v` - 前向旁路网络
- [`div_unit`](#div_unit) - `rtl/div_unit.v` - 33 周期除法器
- [`exec_pipe0`](#exec_pipe0) - `rtl/exec_pipe0.v` - 执行端口 0：ALU + 分支解析
- [`exec_pipe1`](#exec_pipe1) - `rtl/exec_pipe1.v` - 执行端口 1：ALU + MUL + DIV + AGU
- [`imm_gen`](#imm_gen) - `rtl/imm_gen.v` - 立即数扩展
- [`mul_unit`](#mul_unit) - `rtl/mul_unit.v` - 3 周期乘法器

### 05. ROB / 提交

- [`rob`](#rob) - `rtl/rob.v` - 16-entry Reorder Buffer，2 级流水提交
- [`rob_lite`](#rob_lite) - `rtl/rob_lite.v` - ROB 精简变体（备用 / 实验路径）

### 06. 内存子系统 (Mem subsys / Caches)

- [`data_memory`](#data_memory) - `rtl/data_memory.v` - 数据存储（仿真路径）
- [`ddr3_mem_port`](#ddr3_mem_port) - `rtl/ddr3_mem_port.v` - DDR3 跨时钟域桥（核心 <-> MIG AXI）
- [`icache`](#icache) - `rtl/icache.v` - 8KB 直接映射 ICache
- [`icache_mem_adapter`](#icache_mem_adapter) - `rtl/icache_mem_adapter.v` - ICache -> 后端内存接口适配
- [`inst_backing_store`](#inst_backing_store) - `rtl/inst_backing_store.v` - 指令后备存储（FPGA: ROM；Sim: 大容量）
- [`inst_memory`](#inst_memory) - `rtl/inst_memory.v` - 指令存储（仿真路径）
- [`l1_dcache_m1`](#l1_dcache_m1) - `rtl/l1_dcache_m1.v` - 4KB 4-way write-back L1 DCache（主线）
- [`l1_dcache_nb`](#l1_dcache_nb) - `rtl/l1_dcache_nb.v` - L1 DCache non-blocking 变体
- [`l2_arbiter`](#l2_arbiter) - `rtl/l2_arbiter.v` - L2 端口仲裁（I + D + RoCC）
- [`l2_cache`](#l2_cache) - `rtl/l2_cache.v` - L2 cache
- [`legacy_mem_subsys`](#legacy_mem_subsys) - `rtl/legacy_mem_subsys.v` - 老内存子系统（旧路径，simulation only）
- [`lsu_shell`](#lsu_shell) - `rtl/lsu_shell.v` - Load/Store Unit + D-TLB 接口 shell
- [`mem_subsys`](#mem_subsys) - `rtl/mem_subsys.v` - 内存子系统中枢：ICache/DCache/RoCC <-> L2/RAM 仲裁
- [`mmu_sv32`](#mmu_sv32) - `rtl/mmu_sv32.v` - Sv32 MMU（实验性）
- [`stage_mem`](#stage_mem) - `rtl/stage_mem.v` - 访存级（旧路径）
- [`store_buffer`](#store_buffer) - `rtl/store_buffer.v` - 32-entry 写合并 store buffer
- [`tlb`](#tlb) - `rtl/tlb.v` - TLB 主体

### 07. 控制 / CSR / 中断

- [`clint`](#clint) - `rtl/clint.v` - 核心局部中断控制器（CLINT，timer + softirq）
- [`csr_unit`](#csr_unit) - `rtl/csr_unit.v` - M-mode CSR + HPM 计数器（mhpmcounter3-9）
- [`plic`](#plic) - `rtl/plic.v` - 平台级中断控制器（PLIC，外部 IRQ）
- [`syn_rst`](#syn_rst) - `rtl/syn_rst.v` - 同步复位生成器

### 08. SMT / 线程

- [`regs_mt`](#regs_mt) - `rtl/regs_mt.v` - SMT 架构寄存器堆
- [`thread_scheduler`](#thread_scheduler) - `rtl/thread_scheduler.v` - SMT 线程调度策略

### 09. 旧 in-order 路径 (legacy)

- [`ctrl`](#ctrl) - `rtl/ctrl.v` - 控制信号生成（旧路径）
- [`regs`](#regs) - `rtl/regs.v` - 架构寄存器堆（旧路径）
- [`scoreboard`](#scoreboard) - `rtl/scoreboard.v` - 记分板（旧路径，单发射调试用）
- [`stage_is`](#stage_is) - `rtl/stage_is.v` - 发射级（旧路径）
- [`stage_wb`](#stage_wb) - `rtl/stage_wb.v` - 写回级（旧路径）

### 10. UART / 调试 / RoCC

- [`debug_beacon_tx`](#debug_beacon_tx) - `rtl/debug_beacon_tx.v` - 调试 beacon 发送器
- [`rocc_ai_accelerator`](#rocc_ai_accelerator) - `rtl/rocc_ai_accelerator.v` - RoCC AI 加速器（可选）
- [`uart_rx`](#uart_rx) - `rtl/uart_rx.v` - 标准 UART RX
- [`uart_tx`](#uart_tx) - `rtl/uart_tx.v` - 标准 UART TX
- [`uart_tx_simple`](#uart_tx_simple) - `rtl/uart_tx_simple.v` - 简化 UART TX（FPGA 调试用）

### 11. FPGA 板级顶层与 beacon

- [`adam_riscv_ax7203_beacon_transport_top`](#adam_riscv_ax7203_beacon_transport_top) - `fpga/rtl/adam_riscv_ax7203_beacon_transport_top.v` - 板级顶层变体：UART beacon 透传调试
- [`adam_riscv_ax7203_branch_probe_top`](#adam_riscv_ax7203_branch_probe_top) - `fpga/rtl/adam_riscv_ax7203_branch_probe_top.v` - 板级顶层变体：branch 探针
- [`adam_riscv_ax7203_io_smoke_top`](#adam_riscv_ax7203_io_smoke_top) - `fpga/rtl/adam_riscv_ax7203_io_smoke_top.v` - 板级顶层变体：IO smoke 测试
- [`adam_riscv_ax7203_issue_probe_top`](#adam_riscv_ax7203_issue_probe_top) - `fpga/rtl/adam_riscv_ax7203_issue_probe_top.v` - 板级顶层变体：issue 探针
- [`adam_riscv_ax7203_main_bridge_probe_top`](#adam_riscv_ax7203_main_bridge_probe_top) - `fpga/rtl/adam_riscv_ax7203_main_bridge_probe_top.v` - 板级顶层变体：主桥探针
- [`adam_riscv_ax7203_status_top`](#adam_riscv_ax7203_status_top) - `fpga/rtl/adam_riscv_ax7203_status_top.v` - 板级顶层变体：status beacon
- [`adam_riscv_ax7203_top`](#adam_riscv_ax7203_top) - `fpga/rtl/adam_riscv_ax7203_top.v` - AX7203 板级最终顶层（核心 + DDR3 桥 + UART + LED）
- [`adam_riscv_ax7203_uart_echo_raw_top`](#adam_riscv_ax7203_uart_echo_raw_top) - `fpga/rtl/adam_riscv_ax7203_uart_echo_raw_top.v` - 板级顶层变体：UART 回环 smoke
- [`uart_branch_probe_beacon`](#uart_branch_probe_beacon) - `fpga/rtl/uart_branch_probe_beacon.v` - UART branch probe beacon
- [`uart_ddr3_fetch_probe_beacon`](#uart_ddr3_fetch_probe_beacon) - `fpga/rtl/uart_ddr3_fetch_probe_beacon.v` - UART DDR3 fetch probe beacon
- [`uart_issue_probe_beacon`](#uart_issue_probe_beacon) - `fpga/rtl/uart_issue_probe_beacon.v` - UART issue probe beacon
- [`uart_main_bridge_beacon`](#uart_main_bridge_beacon) - `fpga/rtl/uart_main_bridge_beacon.v` - UART 主桥 probe beacon
- [`uart_rx_monitor`](#uart_rx_monitor) - `fpga/rtl/uart_rx_monitor.v` - UART RX 监控（核心 boot 监控）
- [`uart_status_beacon`](#uart_status_beacon) - `fpga/rtl/uart_status_beacon.v` - UART status beacon（板级）

### 99. 其它

- [`uart_tx_autoboot`](#uart_tx_autoboot) - `rtl/uart_tx.v`

## 模块详情

## 00. 顶层 / 集成

### adam_riscv

- 源文件：`rtl/adam_riscv.v`
- 角色：OoO 双发射 RV32IM SMT 核心顶层（IF/Decode/Dispatch/Exec/Mem/WB 串接）
- 端口：

```verilog
    input wire sys_clk
    `ifdef FPGA_MODE output wire[2:0] led
    `endif input wire sys_rstn
    input wire uart_rx
    input wire ext_irq_src
    output wire [7:0] tube_status
    output wire uart_tx
    output wire debug_core_ready
    output wire debug_core_clk
    output wire debug_retire_seen
    output wire debug_uart_status_busy
    output wire debug_uart_busy
    output wire debug_uart_pending_valid
    output wire [7:0] debug_uart_status_load_count
    output wire [7:0] debug_uart_tx_store_count
    output wire debug_uart_tx_byte_valid
    output wire [7:0] debug_uart_tx_byte
    `ifdef VERILATOR_FAST_UART input wire fast_uart_rx_byte_valid
    input wire [7:0] fast_uart_rx_byte
    `endif output wire [7:0] debug_last_iss0_pc_lo
    output wire [7:0] debug_last_iss1_pc_lo
    output wire debug_branch_pending_any
    output wire debug_br_found_t0
    output wire debug_branch_in_flight_t0
    output wire debug_oldest_br_ready_t0
    output wire debug_oldest_br_just_woke_t0
    output wire [3:0] debug_oldest_br_qj_t0
    output wire [3:0] debug_oldest_br_qk_t0
    output wire [3:0] debug_slot1_flags
    output wire [7:0] debug_slot1_pc_lo
    output wire [3:0] debug_slot1_qj
    output wire [3:0] debug_slot1_qk
    output wire [3:0] debug_tag2_flags
    output wire [3:0] debug_reg_x12_tag_t0
    output wire [3:0] debug_slot1_issue_flags
    output wire [3:0] debug_sel0_idx
    output wire [3:0] debug_slot1_fu
    output wire [7:0] debug_oldest_br_seq_lo_t0
    output wire [15:0] debug_rs_flags_flat
    output wire [31:0] debug_rs_pc_lo_flat
    output wire [15:0] debug_rs_fu_flat
    output wire [15:0] debug_rs_qj_flat
    output wire [15:0] debug_rs_qk_flat
    output wire [31:0] debug_rs_seq_lo_flat
    output wire debug_spec_dispatch0
    output wire debug_spec_dispatch1
    output wire debug_branch_gated_mem_issue
    output wire debug_flush_killed_speculative
    output wire debug_commit_suppressed
    output wire debug_spec_mmio_load_blocked
    output wire debug_spec_mmio_load_violation
    output wire debug_mmio_load_at_rob_head
    output wire debug_older_store_blocked_mmio_load
    output wire [7:0] debug_branch_issue_count
    output wire [7:0] debug_branch_complete_count
    output wire [383:0] debug_ddr3_fetch_bus `ifdef ENABLE_DDR3
    output wire ddr3_req_valid
    input wire ddr3_req_ready
    output wire [31:0] ddr3_req_addr
    output wire ddr3_req_write
    output wire [31:0] ddr3_req_wdata
    output wire [3:0] ddr3_req_wen
    input wire ddr3_resp_valid
    input wire [31:0] ddr3_resp_data
    input wire ddr3_init_calib_complete `endif
```

## 01. 取指 (IF) 与分支预测

### bpu_bimodal

- 源文件：`rtl/bpu_bimodal.v`
- 角色：分支预测器：bimodal
- 参数：

```verilog
    parameter PHT_ENTRIES = 256
    parameter PHT_IDX_W = $clog2(PHT_ENTRIES)
    parameter RAS_DEPTH = 8
    parameter RAS_IDX_W = $clog2(RAS_DEPTH)
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [31:0] pred_pc
    input wire [0:0] pred_tid
    output wire pred_taken
    output wire [31:0] pred_target
    input wire update_valid
    input wire [31:0] update_pc
    input wire [0:0] update_tid
    input wire update_taken
    input wire [31:0] update_target
    input wire update_is_call
    input wire update_is_return
```

### fetch_buffer

- 源文件：`rtl/fetch_buffer.v`
- 角色：取指缓冲 FIFO（16-entry，支持双弹出给双解码）
- 参数：

```verilog
    parameter DEPTH = 4
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [1:0] flush
    input wire push_valid
    input wire [31:0] push_inst
    input wire [31:0] push_pc
    input wire [0:0] push_tid
    input wire push_pred_taken
    input wire [31:0] push_pred_target
    output wire push_ready
    output wire pop0_valid
    output wire [31:0] pop0_inst
    output wire [31:0] pop0_pc
    output wire [0:0] pop0_tid
    output wire pop0_pred_taken
    output wire [31:0] pop0_pred_target
    output wire pop1_valid
    output wire [31:0] pop1_inst
    output wire [31:0] pop1_pc
    output wire [0:0] pop1_tid
    output wire pop1_pred_taken
    output wire [31:0] pop1_pred_target
    input wire consume_0
    input wire consume_1
```

### pc_mt

- 源文件：`rtl/pc_mt.v`
- 角色：SMT 多线程 PC 管理
- 参数：

```verilog
    parameter N_T = 2
    parameter THREAD1_BOOT_PC = 32'h00000800
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [N_T-1:0] br_ctrl
    input wire [31:0] br_addr_t0
    input wire [31:0] br_addr_t1
    input wire [N_T-1:0] pred_ctrl
    input wire [31:0] pred_addr_t0
    input wire [31:0] pred_addr_t1
    input wire [N_T-1:0] pc_stall
    input wire [N_T-1:0] flush
    input wire [N_T-1:0] pc_advance
    input wire [0:0] fetch_tid
    output reg [31:0] if_pc
    output reg [0:0] if_tid
```

### stage_if

- 源文件：`rtl/stage_if.v`
- 角色：取指级（IF）：PC 选择 + ICache 接口 + BPU 集成 + per-thread fetch
- 参数：

```verilog
    parameter USE_EXTERNAL_REFILL_STATIC = 0
    parameter BPU_PHT_ENTRIES = 1024
    parameter ICACHE_SIZE = 8192
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire pc_stall
    input wire [1:0] if_flush
    input wire [31:0] br_addr_t0
    input wire [31:0] br_addr_t1
    input wire [1:0] br_ctrl
    input wire bpu_update_valid
    input wire [31:0] bpu_update_pc
    input wire [0:0] bpu_update_tid
    input wire bpu_update_taken
    input wire [31:0] bpu_update_target
    input wire bpu_update_is_call
    input wire bpu_update_is_return
    input wire [0:0] fetch_tid
    input wire fb_ready
    output wire if_valid
    output wire [31:0] if_inst
    output wire [31:0] if_pc
    output wire [0:0] if_tid
    output wire if_pred_taken
    output wire [31:0] if_pred_target
    output wire ext_mem_req_valid
    input wire ext_mem_req_ready
    output wire [31:0] ext_mem_req_addr
    input wire ext_mem_resp_valid
    input wire [31:0] ext_mem_resp_data
    input wire ext_mem_resp_last
    output wire ext_mem_resp_ready
    output wire [31:0] ext_mem_bypass_addr
    input wire [31:0] ext_mem_bypass_data
    input wire use_external_refill
    output wire [31:0] debug_fetch_pc_pending
    output wire [31:0] debug_pc_out
    output wire [31:0] debug_if_inst
    output wire [7:0] debug_if_flags
    output wire [7:0] debug_ic_high_miss_count
    output wire [7:0] debug_ic_mem_req_count
    output wire [7:0] debug_ic_mem_resp_count
    output wire [7:0] debug_ic_cpu_resp_count
    output wire [7:0] debug_ic_state_flags
    output wire icache_miss_event
```

## 02. 解码 (Decode)

### decoder_dual

- 源文件：`rtl/decoder_dual.v`
- 角色：双发射解码：结构冒险检测（双分支 / 双 mem / WAW）
- 端口：

```verilog
    input wire stall
    input wire inst0_valid
    input wire [31:0] inst0_word
    input wire [31:0] inst0_pc
    input wire [0:0] inst0_tid
    input wire inst1_valid
    input wire [31:0] inst1_word
    input wire [31:0] inst1_pc
    input wire [0:0] inst1_tid
    output wire dec0_valid
    output wire [31:0] dec0_pc
    output wire [31:0] dec0_imm
    output wire [2:0] dec0_func3
    output wire dec0_func7
    output wire [4:0] dec0_rd
    output wire dec0_br
    output wire dec0_mem_read
    output wire dec0_mem2reg
    output wire [2:0] dec0_alu_op
    output wire dec0_mem_write
    output wire [1:0] dec0_alu_src1
    output wire [1:0] dec0_alu_src2
    output wire dec0_br_addr_mode
    output wire dec0_regs_write
    output wire [4:0] dec0_rs1
    output wire [4:0] dec0_rs2
    output wire dec0_rs1_used
    output wire dec0_rs2_used
    output wire [2:0] dec0_fu
    output wire [0:0] dec0_tid
    output wire dec1_valid
    output wire [31:0] dec1_pc
    output wire [31:0] dec1_imm
    output wire [2:0] dec1_func3
    output wire dec1_func7
    output wire [4:0] dec1_rd
    output wire dec1_br
    output wire dec1_mem_read
    output wire dec1_mem2reg
    output wire [2:0] dec1_alu_op
    output wire dec1_mem_write
    output wire [1:0] dec1_alu_src1
    output wire [1:0] dec1_alu_src2
    output wire dec1_br_addr_mode
    output wire dec1_regs_write
    output wire [4:0] dec1_rs1
    output wire [4:0] dec1_rs2
    output wire dec1_rs1_used
    output wire dec1_rs2_used
    output wire [2:0] dec1_fu
    output wire [0:0] dec1_tid
    output wire consume_0
    output wire consume_1
    input wire disp1_blocked
    output wire dec0_is_csr
    output wire dec0_is_mret
    output wire [11:0] dec0_csr_addr
    output wire dec1_is_csr
    output wire dec1_is_mret
    output wire [11:0] dec1_csr_addr
    output wire dec0_is_rocc
    output wire [6:0] dec0_rocc_funct7
    output wire dec1_is_rocc
    output wire [6:0] dec1_rocc_funct7
```

## 03. Dispatch / Rename / OoO 中枢

### dispatch_unit

- 源文件：`rtl/dispatch_unit.v`
- 角色：乱序中枢：rename/freelist + 3xIQ(INT/MEM/MUL) + pipe1 仲裁 + ROB 分配（最复杂模块）
- 参数：

```verilog
    parameter RS_DEPTH = 16
    parameter RS_IDX_W = 4
    parameter RS_TAG_W = 5
    parameter INT_IQ_DEPTH = 8
    parameter INT_IQ_IDX_W = 3
    parameter MEM_IQ_DEPTH = 16
    parameter MEM_IQ_IDX_W = 4
    parameter MUL_IQ_DEPTH = 4
    parameter MUL_IQ_IDX_W = 2
    parameter DIV_IQ_DEPTH = 4
    parameter DIV_IQ_IDX_W = 2
    parameter NUM_FU = 8
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire [`METADATA_EPOCH_W-1:0] flush_new_epoch
    input wire disp0_valid
    input wire [31:0] disp0_pc
    input wire [31:0] disp0_imm
    input wire [2:0] disp0_func3
    input wire disp0_func7
    input wire [4:0] disp0_rd
    input wire disp0_br
    input wire disp0_mem_read
    input wire disp0_mem2reg
    input wire [2:0] disp0_alu_op
    input wire disp0_mem_write
    input wire [1:0] disp0_alu_src1
    input wire [1:0] disp0_alu_src2
    input wire disp0_br_addr_mode
    input wire disp0_regs_write
    input wire [4:0] disp0_rs1
    input wire [4:0] disp0_rs2
    input wire disp0_rs1_used
    input wire disp0_rs2_used
    input wire [2:0] disp0_fu
    input wire [0:0] disp0_tid
    input wire disp0_is_mret
    input wire disp0_is_csr
    input wire disp0_is_rocc
    input wire disp1_valid
    input wire [31:0] disp1_pc
    input wire [31:0] disp1_imm
    input wire [2:0] disp1_func3
    input wire disp1_func7
    input wire [4:0] disp1_rd
    input wire disp1_br
    input wire disp1_mem_read
    input wire disp1_mem2reg
    input wire [2:0] disp1_alu_op
    input wire disp1_mem_write
    input wire [1:0] disp1_alu_src1
    input wire [1:0] disp1_alu_src2
    input wire disp1_br_addr_mode
    input wire disp1_regs_write
    input wire [4:0] disp1_rs1
    input wire [4:0] disp1_rs2
    input wire disp1_rs1_used
    input wire disp1_rs2_used
    input wire [2:0] disp1_fu
    input wire [0:0] disp1_tid
    input wire disp1_is_mret
    input wire disp1_is_csr
    input wire disp1_is_rocc
    output wire disp_stall
    output wire disp1_blocked
    output wire [RS_TAG_W-1:0] disp0_tag
    output wire [RS_TAG_W-1:0] disp1_tag
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp0_epoch
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp1_epoch
    output wire iss0_valid
    output wire [RS_TAG_W-1:0] iss0_tag
    output wire [31:0] iss0_pc
    output wire [31:0] iss0_imm
    output wire [2:0] iss0_func3
    output wire iss0_func7
    output wire [4:0] iss0_rd
    output wire [4:0] iss0_rs1
    output wire [4:0] iss0_rs2
    output wire iss0_rs1_used
    output wire iss0_rs2_used
    output wire [RS_TAG_W-1:0] iss0_src1_tag
    output wire [RS_TAG_W-1:0] iss0_src2_tag
    output wire iss0_br
    output wire iss0_mem_read
    output wire iss0_mem2reg
    output wire [2:0] iss0_alu_op
    output wire iss0_mem_write
    output wire [1:0] iss0_alu_src1
    output wire [1:0] iss0_alu_src2
    output wire iss0_br_addr_mode
    output wire iss0_regs_write
    output wire [2:0] iss0_fu
    output wire [0:0] iss0_tid
    output wire [`METADATA_ORDER_ID_W-1:0] iss0_order_id
    output wire [`METADATA_EPOCH_W-1:0] iss0_epoch
    output wire p1_winner_valid
    output wire [1:0] p1_winner
    output reg p1_mem_cand_valid
    output reg [RS_TAG_W-1:0] p1_mem_cand_tag
    output reg [31:0] p1_mem_cand_pc
    output reg [31:0] p1_mem_cand_imm
    output reg [2:0] p1_mem_cand_func3
    output reg p1_mem_cand_func7
    output reg [4:0] p1_mem_cand_rd
    output reg [4:0] p1_mem_cand_rs1
    output reg [4:0] p1_mem_cand_rs2
    output reg p1_mem_cand_rs1_used
    output reg p1_mem_cand_rs2_used
    output reg [RS_TAG_W-1:0] p1_mem_cand_src1_tag
    output reg [RS_TAG_W-1:0] p1_mem_cand_src2_tag
    output reg p1_mem_cand_br
    output reg p1_mem_cand_mem_read
    output reg p1_mem_cand_mem2reg
    output reg [2:0] p1_mem_cand_alu_op
    output reg p1_mem_cand_mem_write
    output reg [1:0] p1_mem_cand_alu_src1
    output reg [1:0] p1_mem_cand_alu_src2
    output reg p1_mem_cand_br_addr_mode
    output reg p1_mem_cand_regs_write
    output reg [2:0] p1_mem_cand_fu
    output reg [0:0] p1_mem_cand_tid
    output reg p1_mem_cand_is_mret
    output reg [`METADATA_ORDER_ID_W-1:0] p1_mem_cand_order_id
    output reg [`METADATA_EPOCH_W-1:0] p1_mem_cand_epoch
    output reg p1_mul_cand_valid
    output reg [RS_TAG_W-1:0] p1_mul_cand_tag
    output reg [31:0] p1_mul_cand_pc
    output reg [31:0] p1_mul_cand_imm
    output reg [2:0] p1_mul_cand_func3
    output reg p1_mul_cand_func7
    output reg [4:0] p1_mul_cand_rd
    output reg [4:0] p1_mul_cand_rs1
    output reg [4:0] p1_mul_cand_rs2
    output reg p1_mul_cand_rs1_used
    output reg p1_mul_cand_rs2_used
    output reg [RS_TAG_W-1:0] p1_mul_cand_src1_tag
    output reg [RS_TAG_W-1:0] p1_mul_cand_src2_tag
    output reg p1_mul_cand_br
    output reg p1_mul_cand_mem_read
    output reg p1_mul_cand_mem2reg
    output reg [2:0] p1_mul_cand_alu_op
    output reg p1_mul_cand_mem_write
    output reg [1:0] p1_mul_cand_alu_src1
    output reg [1:0] p1_mul_cand_alu_src2
    output reg p1_mul_cand_br_addr_mode
    output reg p1_mul_cand_regs_write
    output reg [2:0] p1_mul_cand_fu
    output reg [0:0] p1_mul_cand_tid
    output reg p1_mul_cand_is_mret
    output reg [`METADATA_ORDER_ID_W-1:0] p1_mul_cand_order_id
    output reg [`METADATA_EPOCH_W-1:0] p1_mul_cand_epoch
    output reg p1_div_cand_valid
    output reg [RS_TAG_W-1:0] p1_div_cand_tag
    output reg [31:0] p1_div_cand_pc
    output reg [31:0] p1_div_cand_imm
    output reg [2:0] p1_div_cand_func3
    output reg p1_div_cand_func7
    output reg [4:0] p1_div_cand_rd
    output reg [4:0] p1_div_cand_rs1
    output reg [4:0] p1_div_cand_rs2
    output reg p1_div_cand_rs1_used
    output reg p1_div_cand_rs2_used
    output reg [RS_TAG_W-1:0] p1_div_cand_src1_tag
    output reg [RS_TAG_W-1:0] p1_div_cand_src2_tag
    output reg p1_div_cand_br
    output reg p1_div_cand_mem_read
    output reg p1_div_cand_mem2reg
    output reg [2:0] p1_div_cand_alu_op
    output reg p1_div_cand_mem_write
    output reg [1:0] p1_div_cand_alu_src1
    output reg [1:0] p1_div_cand_alu_src2
    output reg p1_div_cand_br_addr_mode
    output reg p1_div_cand_regs_write
    output reg [2:0] p1_div_cand_fu
    output reg [0:0] p1_div_cand_tid
    output reg p1_div_cand_is_mret
    output reg [`METADATA_ORDER_ID_W-1:0] p1_div_cand_order_id
    output reg [`METADATA_EPOCH_W-1:0] p1_div_cand_epoch
    output wire branch_pending_any
    output wire debug_br_found_t0
    output wire debug_branch_in_flight_t0
    output wire debug_oldest_br_ready_t0
    output wire debug_oldest_br_just_woke_t0
    output wire [3:0] debug_oldest_br_qj_t0
    output wire [3:0] debug_oldest_br_qk_t0
    output wire [3:0] debug_slot1_flags
    output wire [7:0] debug_slot1_pc_lo
    output wire [3:0] debug_slot1_qj
    output wire [3:0] debug_slot1_qk
    output wire [3:0] debug_tag2_flags
    output wire [3:0] debug_reg_x12_tag_t0
    output wire [3:0] debug_slot1_issue_flags
    output wire [3:0] debug_sel0_idx
    output wire [3:0] debug_slot1_fu
    output wire [7:0] debug_oldest_br_seq_lo_t0
    output wire [15:0] debug_rs_flags_flat
    output wire [31:0] debug_rs_pc_lo_flat
    output wire [15:0] debug_rs_fu_flat
    output wire [15:0] debug_rs_qj_flat
    output wire [15:0] debug_rs_qk_flat
    output wire [31:0] debug_rs_seq_lo_flat
    output wire debug_spec_dispatch0
    output wire debug_spec_dispatch1
    output wire debug_branch_gated_mem_issue
    output wire debug_flush_killed_speculative
    output wire debug_stall_iq_int_full
    output wire debug_stall_iq_mem_full
    output wire debug_stall_iq_mul_full
    output wire debug_stall_iq_div_full
    output wire debug_stall_rs_tag_empty
    input wire wb0_valid
    input wire [RS_TAG_W-1:0] wb0_tag
    input wire [4:0] wb0_rd
    input wire wb0_regs_write
    input wire [2:0] wb0_fu
    input wire [0:0] wb0_tid
    input wire wb1_valid
    input wire [RS_TAG_W-1:0] wb1_tag
    input wire [4:0] wb1_rd
    input wire wb1_regs_write
    input wire [2:0] wb1_fu
    input wire [0:0] wb1_tid
    input wire lsu_early_wakeup_valid
    input wire [RS_TAG_W-1:0] lsu_early_wakeup_tag
    input wire commit0_valid
    input wire [RS_TAG_W-1:0] commit0_tag
    input wire [0:0] commit0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id
    input wire commit1_valid
    input wire [RS_TAG_W-1:0] commit1_tag
    input wire [0:0] commit1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id
    input wire br_complete
    input wire [0:0] br_complete_tid
    input wire [`METADATA_ORDER_ID_W-1:0] br_complete_order_id
    input wire branch_track_clear_t0
    input wire branch_track_clear_t1
    input wire rocc_ready
    output wire iss0_is_rocc
```

### freelist

- 源文件：`rtl/freelist.v`
- 角色：物理寄存器 freelist
- 参数：

```verilog
    parameter PHYS_REG_W = 6
    parameter NUM_FREE = 32
    parameter FL_DEPTH = 64
    parameter FL_IDX_W = 6
    parameter BR_CKPT_DEPTH = 32
    parameter BR_CKPT_IDX_W = 5
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [0:0] tid
    input wire alloc0_req
    input wire alloc1_after_alloc0
    output wire [PHYS_REG_W-1:0] alloc0_prd
    input wire alloc1_req
    output wire [PHYS_REG_W-1:0] alloc1_prd
    output wire can_alloc_1
    output wire can_alloc_2
    input wire free0_valid
    input wire [PHYS_REG_W-1:0] free0_prd
    input wire [0:0] free0_tid
    input wire free1_valid
    input wire [PHYS_REG_W-1:0] free1_prd
    input wire [0:0] free1_tid
    input wire recover_push_valid
    input wire [PHYS_REG_W-1:0] recover_push_prd
    input wire [0:0] recover_push_tid
    input wire branch_ckpt_capture0_valid
    input wire [0:0] branch_ckpt_capture0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture0_order_id
    input wire [1:0] branch_ckpt_capture0_alloc_count
    input wire branch_ckpt_capture1_valid
    input wire [0:0] branch_ckpt_capture1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture1_order_id
    input wire [1:0] branch_ckpt_capture1_alloc_count
    input wire branch_ckpt_restore
    input wire [0:0] branch_ckpt_restore_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_restore_order_id
    output reg branch_ckpt_restore_hit
    input wire branch_ckpt_drop0_valid
    input wire [0:0] branch_ckpt_drop0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop0_order_id
    input wire branch_ckpt_drop1_valid
    input wire [0:0] branch_ckpt_drop1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop1_order_id
    input wire rebuild_valid
    input wire [0:0] rebuild_tid
    input wire [FL_DEPTH-1:0] rebuild_mapped_mask
    input wire reset_list
    input wire [0:0] reset_tid
```

### iq_pipe1_arbiter

- 源文件：`rtl/iq_pipe1_arbiter.v`
- 角色：pipe1 端 MEM/MUL/DIV/ALU 仲裁
- 端口：

```verilog
    input wire mem_valid
    input wire [`METADATA_ORDER_ID_W-1:0] mem_order_id
    input wire mul_valid
    input wire [`METADATA_ORDER_ID_W-1:0] mul_order_id
    input wire div_valid
    input wire [`METADATA_ORDER_ID_W-1:0] div_order_id
    output reg [1:0] winner
    output reg winner_valid
```

### issue_queue

- 源文件：`rtl/issue_queue.v`
- 角色：通用发射队列（INT/MEM/MUL/DIV 共用模板）
- 参数：

```verilog
    parameter IQ_DEPTH = 8
    parameter IQ_IDX_W = 3
    parameter RS_TAG_W = 5
    parameter NUM_THREAD = 2
    parameter WAKE_HOLD = 1
    parameter DEALLOC_AT_COMMIT = 0
    parameter CHECK_LOAD_STORE_ORDER = 0
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire [`METADATA_EPOCH_W-1:0] flush_new_epoch
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire disp0_valid
    input wire [RS_TAG_W-1:0] disp0_tag
    input wire [31:0] disp0_pc
    input wire [31:0] disp0_imm
    input wire [2:0] disp0_func3
    input wire disp0_func7
    input wire [4:0] disp0_rd
    input wire disp0_br
    input wire disp0_mem_read
    input wire disp0_mem2reg
    input wire [2:0] disp0_alu_op
    input wire disp0_mem_write
    input wire [1:0] disp0_alu_src1
    input wire [1:0] disp0_alu_src2
    input wire disp0_br_addr_mode
    input wire disp0_regs_write
    input wire [4:0] disp0_rs1
    input wire [4:0] disp0_rs2
    input wire disp0_rs1_used
    input wire disp0_rs2_used
    input wire [2:0] disp0_fu
    input wire [0:0] disp0_tid
    input wire disp0_is_mret
    input wire disp0_side_effect
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp0_epoch
    input wire [RS_TAG_W-1:0] disp0_src1_tag
    input wire [RS_TAG_W-1:0] disp0_src2_tag
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_src1_order_id
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_src2_order_id
    input wire disp1_valid
    input wire [RS_TAG_W-1:0] disp1_tag
    input wire [31:0] disp1_pc
    input wire [31:0] disp1_imm
    input wire [2:0] disp1_func3
    input wire disp1_func7
    input wire [4:0] disp1_rd
    input wire disp1_br
    input wire disp1_mem_read
    input wire disp1_mem2reg
    input wire [2:0] disp1_alu_op
    input wire disp1_mem_write
    input wire [1:0] disp1_alu_src1
    input wire [1:0] disp1_alu_src2
    input wire disp1_br_addr_mode
    input wire disp1_regs_write
    input wire [4:0] disp1_rs1
    input wire [4:0] disp1_rs2
    input wire disp1_rs1_used
    input wire disp1_rs2_used
    input wire [2:0] disp1_fu
    input wire [0:0] disp1_tid
    input wire disp1_is_mret
    input wire disp1_side_effect
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp1_epoch
    input wire [RS_TAG_W-1:0] disp1_src1_tag
    input wire [RS_TAG_W-1:0] disp1_src2_tag
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_src1_order_id
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_src2_order_id
    output wire iq_full
    output wire iq_almost_full
    output reg iss_valid
    output reg [RS_TAG_W-1:0] iss_tag
    output reg [31:0] iss_pc
    output reg [31:0] iss_imm
    output reg [2:0] iss_func3
    output reg iss_func7
    output reg [4:0] iss_rd
    output reg [4:0] iss_rs1
    output reg [4:0] iss_rs2
    output reg iss_rs1_used
    output reg iss_rs2_used
    output reg [RS_TAG_W-1:0] iss_src1_tag
    output reg [RS_TAG_W-1:0] iss_src2_tag
    output reg iss_br
    output reg iss_mem_read
    output reg iss_mem2reg
    output reg [2:0] iss_alu_op
    output reg iss_mem_write
    output reg [1:0] iss_alu_src1
    output reg [1:0] iss_alu_src2
    output reg iss_br_addr_mode
    output reg iss_regs_write
    output reg [2:0] iss_fu
    output reg [0:0] iss_tid
    output reg iss_is_mret
    output reg [`METADATA_ORDER_ID_W-1:0] iss_order_id
    output reg [`METADATA_EPOCH_W-1:0] iss_epoch
    input wire wb0_valid
    input wire [RS_TAG_W-1:0] wb0_tag
    input wire [0:0] wb0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] wb0_order_id
    input wire wb0_regs_write
    input wire wb1_valid
    input wire [RS_TAG_W-1:0] wb1_tag
    input wire [0:0] wb1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] wb1_order_id
    input wire wb1_regs_write
    input wire early_wakeup_valid
    input wire [RS_TAG_W-1:0] early_wakeup_tag
    input wire commit0_valid
    input wire [RS_TAG_W-1:0] commit0_tag
    input wire [0:0] commit0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id
    input wire commit1_valid
    input wire [RS_TAG_W-1:0] commit1_tag
    input wire [0:0] commit1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id
    input wire older_store_valid_t0
    input wire [`METADATA_ORDER_ID_W-1:0] older_store_order_id_t0
    input wire older_store_valid_t1
    input wire [`METADATA_ORDER_ID_W-1:0] older_store_order_id_t1
    input wire issue_inhibit_t0
    input wire issue_inhibit_t1
    input wire issue_after_order_block_valid_t0
    input wire [`METADATA_ORDER_ID_W-1:0] issue_after_order_block_id_t0
    input wire issue_after_order_block_valid_t1
    input wire [`METADATA_ORDER_ID_W-1:0] issue_after_order_block_id_t1
    input wire issue_side_effect_block_valid_t0
    input wire [`METADATA_ORDER_ID_W-1:0] issue_side_effect_block_id_t0
    input wire issue_side_effect_block_valid_t1
    input wire [`METADATA_ORDER_ID_W-1:0] issue_side_effect_block_id_t1
    output wire oldest_store_valid_t0
    output wire [`METADATA_ORDER_ID_W-1:0] oldest_store_order_id_t0
    output wire oldest_store_valid_t1
    output wire [`METADATA_ORDER_ID_W-1:0] oldest_store_order_id_t1
    output wire debug_order_blocked_any
    output reg debug_flush_killed_any
```

### phys_regfile

- 源文件：`rtl/phys_regfile.v`
- 角色：物理寄存器堆（48-entry, 4R2W）
- 参数：

```verilog
    parameter NUM_PHYS_REG = 64
    parameter PHYS_REG_W = 6
    parameter NUM_THREAD = 2
    parameter DATA_W = 32
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [0:0] r0_tid
    input wire [PHYS_REG_W-1:0] r0_addr
    output wire [DATA_W-1:0] r0_data
    input wire [0:0] r1_tid
    input wire [PHYS_REG_W-1:0] r1_addr
    output wire [DATA_W-1:0] r1_data
    input wire [0:0] r2_tid
    input wire [PHYS_REG_W-1:0] r2_addr
    output wire [DATA_W-1:0] r2_data
    input wire [0:0] r3_tid
    input wire [PHYS_REG_W-1:0] r3_addr
    output wire [DATA_W-1:0] r3_data
    input wire w0_en
    input wire [0:0] w0_tid
    input wire [PHYS_REG_W-1:0] w0_addr
    input wire [DATA_W-1:0] w0_data
    input wire w1_en
    input wire [0:0] w1_tid
    input wire [PHYS_REG_W-1:0] w1_addr
    input wire [DATA_W-1:0] w1_data
```

### rename_map_table

- 源文件：`rtl/rename_map_table.v`
- 角色：重命名映射表 + checkpoint
- 参数：

```verilog
    parameter NUM_ARCH_REG = 32
    parameter ARCH_REG_W = 5
    parameter NUM_PHYS_REG = 64
    parameter PHYS_REG_W = 6
    parameter BR_CKPT_DEPTH = 32
    parameter BR_CKPT_IDX_W = 5
    parameter ENABLE_CKPT_QUERY = 1
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [0:0] tid
    input wire [ARCH_REG_W-1:0] lookup0_rs1
    input wire [ARCH_REG_W-1:0] lookup0_rs2
    input wire [ARCH_REG_W-1:0] lookup0_rd
    input wire [ARCH_REG_W-1:0] lookup1_rs1
    input wire [ARCH_REG_W-1:0] lookup1_rs2
    input wire [ARCH_REG_W-1:0] lookup1_rd
    output wire [PHYS_REG_W-1:0] prs0_1
    output wire [PHYS_REG_W-1:0] prs0_2
    output wire [PHYS_REG_W-1:0] prd0_old
    output wire [PHYS_REG_W-1:0] prs1_1
    output wire [PHYS_REG_W-1:0] prs1_2
    output wire [PHYS_REG_W-1:0] prd1_old
    output wire prs0_1_ready
    output wire prs0_2_ready
    output wire prs1_1_ready
    output wire prs1_2_ready
    input wire alloc0_valid
    input wire [ARCH_REG_W-1:0] alloc0_rd
    input wire [PHYS_REG_W-1:0] alloc0_prd_new
    input wire alloc1_valid
    input wire [ARCH_REG_W-1:0] alloc1_rd
    input wire [PHYS_REG_W-1:0] alloc1_prd_new
    input wire cdb0_valid
    input wire [PHYS_REG_W-1:0] cdb0_prd
    input wire cdb1_valid
    input wire [PHYS_REG_W-1:0] cdb1_prd
    input wire recover_en
    input wire [ARCH_REG_W-1:0] recover_rd
    input wire [PHYS_REG_W-1:0] recover_prd
    input wire [0:0] recover_tid
    input wire reset_to_arch
    input wire [0:0] reset_tid
    input wire [PHYS_REG_W-1:0] query0_prd
    input wire [0:0] query0_tid
    output reg query0_mapped
    input wire [PHYS_REG_W-1:0] query1_prd
    input wire [0:0] query1_tid
    output reg query1_mapped
    input wire [PHYS_REG_W-1:0] ckpt_query0_prd
    input wire [0:0] ckpt_query0_tid
    output reg ckpt_query0_live
    input wire [PHYS_REG_W-1:0] ckpt_query1_prd
    input wire [0:0] ckpt_query1_tid
    output reg ckpt_query1_live
    input wire branch_ckpt_capture0_valid
    input wire [0:0] branch_ckpt_capture0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture0_order_id
    input wire branch_ckpt_capture1_valid
    input wire [0:0] branch_ckpt_capture1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture1_order_id
    input wire branch_ckpt_restore
    input wire [0:0] branch_ckpt_restore_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_restore_order_id
    output reg branch_ckpt_restore_hit
    output reg branch_ckpt_any_live
    input wire branch_ckpt_drop0_valid
    input wire [0:0] branch_ckpt_drop0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop0_order_id
    input wire branch_ckpt_drop1_valid
    input wire [0:0] branch_ckpt_drop1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop1_order_id
    input wire ckpt_commit0_valid
    input wire [0:0] ckpt_commit0_tid
    input wire [ARCH_REG_W-1:0] ckpt_commit0_rd
    input wire [PHYS_REG_W-1:0] ckpt_commit0_prd_new
    input wire ckpt_commit1_valid
    input wire [0:0] ckpt_commit1_tid
    input wire [ARCH_REG_W-1:0] ckpt_commit1_rd
    input wire [PHYS_REG_W-1:0] ckpt_commit1_prd_new
    output reg [NUM_PHYS_REG-1:0] mapped_mask_t0
    output reg [NUM_PHYS_REG-1:0] mapped_mask_t1
```

## 04. 执行 (Execute)

### alu

- 源文件：`rtl/alu.v`
- 角色：基本 ALU
- 端口：

```verilog
    input wire[3:0] alu_ctrl
    input wire[31:0] op_A
    input wire[31:0] op_B
    output reg[31:0] alu_o
    output wire br_mark
```

### alu_control

- 源文件：`rtl/alu_control.v`
- 角色：ALU 控制译码
- 端口：

```verilog
    input wire[2:0] alu_op
    input wire[2:0] func3_code
    input wire func7_code
    output reg[3:0] alu_ctrl_r
```

### bypass_network

- 源文件：`rtl/bypass_network.v`
- 角色：前向旁路网络
- 参数：

```verilog
    parameter DATA_W = 32
```
- 端口：

```verilog
    input wire [4:0] ro_rs1_addr
    input wire [4:0] ro_rs2_addr
    input wire [DATA_W-1:0] ro_rs1_regdata
    input wire [DATA_W-1:0] ro_rs2_regdata
    input wire [0:0] ro_tid
    input wire tagbuf_rs1_valid
    input wire [DATA_W-1:0] tagbuf_rs1_data
    input wire tagbuf_rs2_valid
    input wire [DATA_W-1:0] tagbuf_rs2_data
    input wire pipe0_valid
    input wire [4:0] pipe0_rd
    input wire pipe0_rd_wen
    input wire [DATA_W-1:0] pipe0_data
    input wire [0:0] pipe0_tid
    input wire pipe1_valid
    input wire [4:0] pipe1_rd
    input wire pipe1_rd_wen
    input wire [DATA_W-1:0] pipe1_data
    input wire [0:0] pipe1_tid
    input wire mem_valid
    input wire [4:0] mem_rd
    input wire mem_rd_wen
    input wire [DATA_W-1:0] mem_data
    input wire [0:0] mem_tid
    output wire [DATA_W-1:0] op_a
    output wire [DATA_W-1:0] op_b
    output wire [1:0] fwd_src_a
    output wire [1:0] fwd_src_b
```

### div_unit

- 源文件：`rtl/div_unit.v`
- 角色：33 周期除法器
- 参数：

```verilog
    parameter TAG_W = 5
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire in_valid
    input wire [TAG_W-1:0] in_tag
    input wire [31:0] in_op_a
    input wire [31:0] in_op_b
    input wire [2:0] in_func3
    input wire [4:0] in_rd
    input wire in_regs_write
    input wire [2:0] in_fu
    input wire [0:0] in_tid
    input wire [`METADATA_ORDER_ID_W-1:0] in_order_id
    output wire out_valid
    output wire [TAG_W-1:0] out_tag
    output wire [31:0] out_result
    output wire [4:0] out_rd
    output wire out_regs_write
    output wire [2:0] out_fu
    output wire [0:0] out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] out_order_id
    output wire busy
```

### exec_pipe0

- 源文件：`rtl/exec_pipe0.v`
- 角色：执行端口 0：ALU + 分支解析
- 参数：

```verilog
    parameter TAG_W = 5
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire in_valid
    input wire [TAG_W-1:0] in_tag
    input wire [31:0] in_pc
    input wire [31:0] in_op_a
    input wire [31:0] in_op_b
    input wire [4:0] in_rs1_idx
    input wire [31:0] in_imm
    input wire [`METADATA_ORDER_ID_W-1:0] in_order_id
    input wire [2:0] in_func3
    input wire in_func7
    input wire [2:0] in_alu_op
    input wire [1:0] in_alu_src1
    input wire [1:0] in_alu_src2
    input wire in_br_addr_mode
    input wire in_br
    input wire in_pred_taken
    input wire [31:0] in_pred_target
    input wire [4:0] in_rd
    input wire in_regs_write
    input wire [2:0] in_fu
    input wire [0:0] in_tid
    input wire flush
    input wire [0:0] flush_tid
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire in_is_csr
    input wire in_is_mret
    input wire [11:0] in_csr_addr
    input wire [31:0] csr_rdata
    output wire out_valid
    output wire [TAG_W-1:0] out_tag
    output wire [31:0] out_result
    output wire [4:0] out_rd
    output wire out_regs_write
    output wire [2:0] out_fu
    output wire [0:0] out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] out_order_id
    output wire csr_valid
    output wire [31:0] csr_wdata
    output wire [2:0] csr_op
    output wire [11:0] csr_addr
    output wire mret_valid
    output wire [`METADATA_ORDER_ID_W-1:0] mret_order_id
    output wire br_ctrl
    output wire [31:0] br_addr
    output wire [0:0] br_tid
    output wire [`METADATA_ORDER_ID_W-1:0] br_order_id
    output wire br_complete
    output wire br_update_valid
    output wire [31:0] br_update_pc
    output wire br_update_taken
    output wire [31:0] br_update_target
    output wire br_update_is_call
    output wire br_update_is_return
```

### exec_pipe1

- 源文件：`rtl/exec_pipe1.v`
- 角色：执行端口 1：ALU + MUL + DIV + AGU
- 参数：

```verilog
    parameter TAG_W = 5
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire in_valid
    input wire [TAG_W-1:0] in_tag
    input wire [31:0] in_pc
    input wire [31:0] in_op_a
    input wire [31:0] in_op_b
    input wire [31:0] in_imm
    input wire [2:0] in_func3
    input wire in_func7
    input wire [2:0] in_alu_op
    input wire [1:0] in_alu_src1
    input wire [1:0] in_alu_src2
    input wire in_br
    input wire in_mem_read
    input wire in_mem_write
    input wire in_mem2reg
    input wire [4:0] in_rd
    input wire in_regs_write
    input wire [2:0] in_fu
    input wire [0:0] in_tid
    input wire [`METADATA_ORDER_ID_W-1:0] in_order_id
    input wire [7:0] in_epoch
    input wire flush
    input wire [0:0] flush_tid
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    output wire alu_out_valid
    output wire [TAG_W-1:0] alu_out_tag
    output wire [31:0] alu_out_result
    output wire [4:0] alu_out_rd
    output wire alu_out_regs_write
    output wire [2:0] alu_out_fu
    output wire [0:0] alu_out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] alu_out_order_id
    output wire mem_req_valid
    input wire mem_req_accept
    output wire mem_req_wen
    output wire [31:0] mem_req_addr
    output wire [31:0] mem_req_wdata
    output wire [2:0] mem_req_func3
    output wire [TAG_W-1:0] mem_req_tag
    output wire [4:0] mem_req_rd
    output wire mem_req_regs_write
    output wire [2:0] mem_req_fu
    output wire mem_req_mem2reg
    output wire [0:0] mem_req_tid
    output wire [`METADATA_ORDER_ID_W-1:0] mem_req_order_id
    output wire [7:0] mem_req_epoch
    output wire mul_out_valid
    output wire [TAG_W-1:0] mul_out_tag
    output wire [31:0] mul_out_result
    output wire [4:0] mul_out_rd
    output wire mul_out_regs_write
    output wire [2:0] mul_out_fu
    output wire [0:0] mul_out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] mul_out_order_id
    output wire div_out_valid
    output wire [TAG_W-1:0] div_out_tag
    output wire [31:0] div_out_result
    output wire [4:0] div_out_rd
    output wire div_out_regs_write
    output wire [2:0] div_out_fu
    output wire [0:0] div_out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] div_out_order_id
    output wire div_busy
```

### imm_gen

- 源文件：`rtl/imm_gen.v`
- 角色：立即数扩展
- 端口：

```verilog
    input wire[31:0] inst
    output wire[31:0] imm_o
```

### mul_unit

- 源文件：`rtl/mul_unit.v`
- 角色：3 周期乘法器
- 参数：

```verilog
    parameter TAG_W = 5
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire in_valid
    input wire [TAG_W-1:0] in_tag
    input wire [31:0] in_op_a
    input wire [31:0] in_op_b
    input wire [2:0] in_func3
    input wire [4:0] in_rd
    input wire in_regs_write
    input wire [2:0] in_fu
    input wire [0:0] in_tid
    input wire [`METADATA_ORDER_ID_W-1:0] in_order_id
    output wire out_valid
    output wire [TAG_W-1:0] out_tag
    output wire [31:0] out_result
    output wire [4:0] out_rd
    output wire out_regs_write
    output wire [2:0] out_fu
    output wire [0:0] out_tid
    output wire [`METADATA_ORDER_ID_W-1:0] out_order_id
```

## 05. ROB / 提交

### rob

- 源文件：`rtl/rob.v`
- 角色：16-entry Reorder Buffer，2 级流水提交
- 参数：

```verilog
    parameter ROB_DEPTH = 32
    parameter ROB_IDX_W = 5
    parameter RS_TAG_W = 5
    parameter PHYS_REG_W = 6
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire [`METADATA_EPOCH_W-1:0] flush_new_epoch
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire disp0_valid
    input wire [RS_TAG_W-1:0] disp0_tag
    input wire [0:0] disp0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp0_epoch
    input wire [4:0] disp0_rd
    input wire disp0_is_store
    input wire disp0_is_mret
    input wire [PHYS_REG_W-1:0] disp0_prd_new
    input wire [PHYS_REG_W-1:0] disp0_prd_old
    input wire disp0_is_branch
    input wire disp0_regs_write
    input wire [31:0] disp0_pc
    output wire rob0_full
    output wire [ROB_IDX_W-1:0] disp0_rob_idx
    input wire disp1_valid
    input wire [RS_TAG_W-1:0] disp1_tag
    input wire [0:0] disp1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp1_epoch
    input wire [4:0] disp1_rd
    input wire disp1_is_store
    input wire disp1_is_mret
    input wire [PHYS_REG_W-1:0] disp1_prd_new
    input wire [PHYS_REG_W-1:0] disp1_prd_old
    input wire disp1_is_branch
    input wire disp1_regs_write
    input wire [31:0] disp1_pc
    output wire rob1_full
    output wire [ROB_IDX_W-1:0] disp1_rob_idx
    input wire wb0_valid
    input wire [RS_TAG_W-1:0] wb0_tag
    input wire [0:0] wb0_tid
    input wire [31:0] wb0_data
    input wire wb0_regs_write
    input wire wb1_valid
    input wire [RS_TAG_W-1:0] wb1_tag
    input wire [0:0] wb1_tid
    input wire [31:0] wb1_data
    input wire wb1_regs_write
    output wire commit0_valid
    output wire commit1_valid
    output wire [4:0] commit0_rd
    output wire [4:0] commit1_rd
    output wire [1:0] instr_retired
    output wire [RS_TAG_W-1:0] commit0_tag
    output wire [RS_TAG_W-1:0] commit1_tag
    output wire commit0_has_result
    output wire commit1_has_result
    output wire [31:0] commit0_data
    output wire [31:0] commit1_data
    output wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id
    output wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id
    output wire [31:0] commit0_pc
    output wire [31:0] commit1_pc
    output wire commit0_is_store
    output wire commit1_is_store
    output wire commit0_is_mret
    output wire commit1_is_mret
    output wire commit0_is_branch
    output wire commit1_is_branch
    output wire [PHYS_REG_W-1:0] commit0_prd_old
    output wire [PHYS_REG_W-1:0] commit0_prd_new
    output wire commit0_regs_write_out
    output wire [PHYS_REG_W-1:0] commit1_prd_old
    output wire [PHYS_REG_W-1:0] commit1_prd_new
    output wire commit1_regs_write_out
    output wire recover_walk_active
    output wire recover_en
    output wire [4:0] recover_rd
    output wire [PHYS_REG_W-1:0] recover_prd_old
    output wire [PHYS_REG_W-1:0] recover_prd_new
    output wire recover_regs_write
    output wire [0:0] recover_tid
    output wire debug_commit_suppressed
    input wire [PHYS_REG_W-1:0] free_query0_prd
    input wire [0:0] free_query0_tid
    output reg free_query0_prd_old_live
    input wire [PHYS_REG_W-1:0] free_query1_prd
    input wire [0:0] free_query1_tid
    output reg free_query1_prd_old_live
    output wire head_valid_t0
    output wire [`METADATA_ORDER_ID_W-1:0] head_order_id_t0
    output wire head_flushed_t0
    output wire head_valid_t1
    output wire [`METADATA_ORDER_ID_W-1:0] head_order_id_t1
    output wire head_flushed_t1
```

### rob_lite

- 源文件：`rtl/rob_lite.v`
- 角色：ROB 精简变体（备用 / 实验路径）
- 参数：

```verilog
    parameter ROB_DEPTH = 8
    parameter ROB_IDX_W = 3
    parameter RS_TAG_W = 5
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire [`METADATA_EPOCH_W-1:0] flush_new_epoch
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire disp0_valid
    input wire [RS_TAG_W-1:0] disp0_tag
    input wire [0:0] disp0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp0_epoch
    input wire [4:0] disp0_rd
    input wire disp0_is_store
    output wire rob0_full
    input wire disp1_valid
    input wire [RS_TAG_W-1:0] disp1_tag
    input wire [0:0] disp1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp1_epoch
    input wire [4:0] disp1_rd
    input wire disp1_is_store
    output wire rob1_full
    input wire wb0_valid
    input wire [RS_TAG_W-1:0] wb0_tag
    input wire [0:0] wb0_tid
    input wire [31:0] wb0_data
    input wire wb0_regs_write
    input wire wb1_valid
    input wire [RS_TAG_W-1:0] wb1_tag
    input wire [0:0] wb1_tid
    input wire [31:0] wb1_data
    input wire wb1_regs_write
    output wire commit0_valid
    output wire commit1_valid
    output wire [4:0] commit0_rd
    output wire [4:0] commit1_rd
    output wire [1:0] instr_retired
    output wire [RS_TAG_W-1:0] commit0_tag
    output wire [RS_TAG_W-1:0] commit1_tag
    output wire commit0_has_result
    output wire commit1_has_result
    output wire [31:0] commit0_data
    output wire [31:0] commit1_data
    output wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id
    output wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id
    output wire commit0_is_store
    output wire commit1_is_store
```

## 06. 内存子系统 (Mem subsys / Caches)

### data_memory

- 源文件：`rtl/data_memory.v`
- 角色：数据存储（仿真路径）
- 参数：

```verilog
    parameter RAM_SPACE = 4096
```
- 端口：

```verilog
    input wire clk
    input wire[31:0] addr_mem
    input wire[31:0] w_data_mem
    input wire[ 3:0] w_en_mem
    input wire en_mem
    output wire[31:0] r_data_mem
```

### ddr3_mem_port

- 源文件：`rtl/ddr3_mem_port.v`
- 角色：DDR3 跨时钟域桥（核心 <-> MIG AXI）
- 参数：

```verilog
    parameter AXI_DATA_W = 256
    parameter AXI_ADDR_W = 30
    parameter AXI_ID_W = 4
```
- 端口：

```verilog
    input wire core_clk
    input wire core_rstn
    input wire req_valid
    output wire req_ready
    input wire [31:0] req_addr
    input wire req_write
    input wire [31:0] req_wdata
    input wire [3:0] req_wen
    output wire resp_valid
    output wire [31:0] resp_data
    input wire ui_clk
    input wire ui_rstn
    input wire init_calib_complete
    output reg m_axi_awvalid
    input wire m_axi_awready
    output wire [AXI_ID_W-1:0] m_axi_awid
    output reg [AXI_ADDR_W-1:0] m_axi_awaddr
    output wire [7:0] m_axi_awlen
    output wire [2:0] m_axi_awsize
    output wire [1:0] m_axi_awburst
    output wire m_axi_awlock
    output wire [3:0] m_axi_awcache
    output wire [2:0] m_axi_awprot
    output wire [3:0] m_axi_awqos
    output reg m_axi_wvalid
    input wire m_axi_wready
    output reg [AXI_DATA_W-1:0] m_axi_wdata
    output reg [AXI_DATA_W/8-1:0] m_axi_wstrb
    output wire m_axi_wlast
    input wire m_axi_bvalid
    output wire m_axi_bready
    input wire [AXI_ID_W-1:0] m_axi_bid
    input wire [1:0] m_axi_bresp
    output reg m_axi_arvalid
    input wire m_axi_arready
    output wire [AXI_ID_W-1:0] m_axi_arid
    output reg [AXI_ADDR_W-1:0] m_axi_araddr
    output wire [7:0] m_axi_arlen
    output wire [2:0] m_axi_arsize
    output wire [1:0] m_axi_arburst
    output wire m_axi_arlock
    output wire [3:0] m_axi_arcache
    output wire [2:0] m_axi_arprot
    output wire [3:0] m_axi_arqos
    input wire m_axi_rvalid
    output wire m_axi_rready
    input wire [AXI_ID_W-1:0] m_axi_rid
    input wire [AXI_DATA_W-1:0] m_axi_rdata
    input wire [1:0] m_axi_rresp
    input wire m_axi_rlast
```

### icache

- 源文件：`rtl/icache.v`
- 角色：8KB 直接映射 ICache
- 参数：

```verilog
    parameter CACHE_SIZE = 2048
    parameter LINE_SIZE = 32
    parameter WAYS = 1
    parameter ADDR_WIDTH = 32
    parameter TID_WIDTH = 1
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire cpu_req_valid
    output wire cpu_req_ready
    input wire [ADDR_WIDTH-1:0] cpu_req_addr
    input wire [TID_WIDTH-1:0] cpu_req_tid
    output reg [31:0] cpu_resp_data
    output reg [TID_WIDTH-1:0] cpu_resp_tid
    output reg [3:0] cpu_resp_epoch
    output reg cpu_resp_valid
    input wire [3:0] current_epoch
    input wire [3:0] current_epoch_t0
    input wire [3:0] current_epoch_t1
    input wire flush
    output reg mem_req_valid
    input wire mem_req_ready
    output reg [ADDR_WIDTH-1:0] mem_req_addr
    input wire mem_resp_valid
    input wire [31:0] mem_resp_data
    input wire mem_resp_last
    output wire mem_resp_ready
    input wire [31:0] bypass_data
    output wire [7:0] debug_high_miss_count
    output wire [7:0] debug_mem_req_count
    output wire [7:0] debug_mem_resp_count
    output wire [7:0] debug_cpu_resp_count
    output wire [7:0] debug_state_flags
    output wire icache_miss_event
```

### icache_mem_adapter

- 源文件：`rtl/icache_mem_adapter.v`
- 角色：ICache -> 后端内存接口适配
- 参数：

```verilog
    parameter ADDR_WIDTH = 32
    parameter LINE_SIZE = 32
    parameter IROM_SPACE = 4096
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire req_valid
    output reg req_ready
    input wire [ADDR_WIDTH-1:0] req_addr
    output reg resp_valid
    output reg [31:0] resp_data
    output reg resp_last
    input wire resp_ready
    output reg [31:0] mem_addr
    input wire [31:0] mem_data
```

### inst_backing_store

- 源文件：`rtl/inst_backing_store.v`
- 角色：指令后备存储（FPGA: ROM；Sim: 大容量）
- 参数：

```verilog
    parameter IROM_SPACE = 4096
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire[31:0] inst_addr
    output wire[31:0] inst_o
```

### inst_memory

- 源文件：`rtl/inst_memory.v`
- 角色：指令存储（仿真路径）
- 参数：

```verilog
    parameter IROM_SPACE = 4096
    parameter ICACHE_SIZE = 8192
    parameter OMIT_BACKING_STORE = 0
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire req_valid
    output wire req_ready
    input wire [31:0] inst_addr
    input wire [0:0] req_tid
    output wire [31:0] inst_o
    output wire [0:0] resp_tid
    output wire [3:0] resp_epoch
    output wire resp_valid
    input wire [3:0] current_epoch
    input wire [3:0] current_epoch_t0
    input wire [3:0] current_epoch_t1
    input wire flush
    output wire ext_mem_req_valid
    input wire ext_mem_req_ready
    output wire [31:0] ext_mem_req_addr
    input wire ext_mem_resp_valid
    input wire [31:0] ext_mem_resp_data
    input wire ext_mem_resp_last
    output wire ext_mem_resp_ready
    input wire [31:0] ext_mem_bypass_data
    input wire use_external_refill
    output wire [7:0] debug_ic_high_miss_count
    output wire [7:0] debug_ic_mem_req_count
    output wire [7:0] debug_ic_mem_resp_count
    output wire [7:0] debug_ic_cpu_resp_count
    output wire [7:0] debug_ic_state_flags
    output wire icache_miss_event
```

### l1_dcache_m1

- 源文件：`rtl/l1_dcache_m1.v`
- 角色：4KB 4-way write-back L1 DCache（主线）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire up_m1_req_valid
    output wire up_m1_req_ready
    input wire [31:0] up_m1_req_addr
    input wire up_m1_req_write
    input wire [31:0] up_m1_req_wdata
    input wire [3:0] up_m1_req_wen
    output wire up_m1_resp_valid
    output wire [31:0] up_m1_resp_data
    output wire up_m1_resp_l1d_hit
    output wire dn_m1_req_valid
    input wire dn_m1_req_ready
    output wire [31:0] dn_m1_req_addr
    output wire dn_m1_req_write
    output wire [31:0] dn_m1_req_wdata
    output wire [3:0] dn_m1_req_wen
    input wire dn_m1_resp_valid
    input wire [31:0] dn_m1_resp_data
    output wire dcache_miss_event
```

### l1_dcache_nb

- 源文件：`rtl/l1_dcache_nb.v`
- 角色：L1 DCache non-blocking 变体
- 参数：

```verilog
    parameter CACHE_SIZE = 4096
    parameter LINE_SIZE = 32
    parameter WAYS = 4
    parameter MSHR_ENTRIES = 4
    parameter AXI_DATA_W = 32
    parameter AXI_ADDR_W = 32
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire cpu_req_valid
    output wire cpu_req_ready
    input wire [AXI_ADDR_W-1:0] cpu_req_addr
    input wire [31:0] cpu_req_wdata
    input wire [3:0] cpu_req_wmask
    input wire cpu_req_wen
    input wire [2:0] cpu_req_size
    output reg cpu_resp_valid
    output reg [31:0] cpu_resp_rdata
    output wire cpu_resp_miss
    output reg m_axi_awvalid
    input wire m_axi_awready
    output reg [AXI_ADDR_W-1:0] m_axi_awaddr
    output wire [7:0] m_axi_awlen
    output wire [2:0] m_axi_awsize
    output wire [1:0] m_axi_awburst
    output reg m_axi_wvalid
    input wire m_axi_wready
    output reg [AXI_DATA_W-1:0] m_axi_wdata
    output wire [AXI_DATA_W/8-1:0] m_axi_wstrb
    output reg m_axi_wlast
    input wire m_axi_bvalid
    output wire m_axi_bready
    input wire [1:0] m_axi_bresp
    output reg m_axi_arvalid
    input wire m_axi_arready
    output reg [AXI_ADDR_W-1:0] m_axi_araddr
    output wire [7:0] m_axi_arlen
    output wire [2:0] m_axi_arsize
    output wire [1:0] m_axi_arburst
    input wire m_axi_rvalid
    output wire m_axi_rready
    input wire [AXI_DATA_W-1:0] m_axi_rdata
    input wire [1:0] m_axi_rresp
    input wire m_axi_rlast
```

### l2_arbiter

- 源文件：`rtl/l2_arbiter.v`
- 角色：L2 端口仲裁（I + D + RoCC）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire m0_req_valid
    output wire m0_req_ready
    input wire [31:0] m0_req_addr
    output wire m0_resp_valid
    output wire [31:0] m0_resp_data
    output wire m0_resp_last
    input wire m1_req_valid
    output wire m1_req_ready
    input wire [31:0] m1_req_addr
    input wire m1_req_write
    input wire [31:0] m1_req_wdata
    input wire [3:0] m1_req_wen
    output wire m1_resp_valid
    output wire [31:0] m1_resp_data
    input wire m2_req_valid
    output wire m2_req_ready
    input wire [31:0] m2_req_addr
    input wire m2_req_write
    input wire [31:0] m2_req_wdata
    input wire [3:0] m2_req_wen
    output wire m2_resp_valid
    output wire [31:0] m2_resp_data
    output wire l2_req_valid
    input wire l2_req_ready
    output wire [31:0] l2_req_addr
    output wire l2_req_write
    output wire [31:0] l2_req_wdata
    output wire [3:0] l2_req_wen
    output wire l2_req_uncached
    input wire l2_resp_valid
    input wire [31:0] l2_resp_data
    input wire l2_resp_last
    output wire grant_m0
    output wire grant_m1
    output wire grant_m2
    output wire [2:0] grant_count
```

### l2_cache

- 源文件：`rtl/l2_cache.v`
- 角色：L2 cache
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire req_valid
    output wire req_ready
    input wire [31:0] req_addr
    input wire req_write
    input wire [31:0] req_wdata
    input wire [3:0] req_wen
    input wire req_uncached
    output wire resp_valid
    output wire [31:0] resp_data
    output wire resp_last
    output wire [31:0] ram_addr
    output wire ram_write
    output wire [31:0] ram_wdata
    input wire [31:0] ram_rdata
    output wire [2:0] ram_word_idx
    output wire [2:0] cache_state
    output wire cache_hit
    output wire cache_miss
```

### legacy_mem_subsys

- 源文件：`rtl/legacy_mem_subsys.v`
- 角色：老内存子系统（旧路径，simulation only）
- 参数：

```verilog
    parameter RAM_WORDS = 4096
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire uart_rx
    input wire [31:0] load_addr
    input wire [3:0] load_read
    output reg [31:0] load_rdata
    input wire sb_write_valid
    input wire [31:0] sb_write_addr
    input wire [31:0] sb_write_data
    input wire [3:0] sb_write_wen
    output wire sb_write_ready
    output reg [7:0] tube_status
    output wire uart_tx
    output wire debug_uart_status_busy
    output wire debug_uart_busy
    output wire debug_uart_pending_valid
    output reg [7:0] debug_uart_status_load_count
    output reg [7:0] debug_uart_tx_store_count
    output reg debug_uart_tx_byte_valid
    output reg [7:0] debug_uart_tx_byte
```

### lsu_shell

- 源文件：`rtl/lsu_shell.v`
- 角色：Load/Store Unit + D-TLB 接口 shell
- 参数：

```verilog
    parameter TAG_W = 5
    parameter ORDER_ID_W = `METADATA_ORDER_ID_W
    parameter EPOCH_W = 8
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire [EPOCH_W-1:0] flush_new_epoch_t0
    input wire [EPOCH_W-1:0] flush_new_epoch_t1
    input wire [EPOCH_W-1:0] current_epoch_t0
    input wire [EPOCH_W-1:0] current_epoch_t1
    input wire flush_order_valid
    input wire [ORDER_ID_W-1:0] flush_order_id
    input wire req_valid
    output wire req_accept
    input wire [0:0] req_tid
    input wire [ORDER_ID_W-1:0] req_order_id
    input wire [EPOCH_W-1:0] req_epoch
    input wire [TAG_W-1:0] req_tag
    input wire [4:0] req_rd
    input wire [2:0] req_func3
    input wire req_wen
    input wire [31:0] req_addr
    input wire [31:0] req_wdata
    input wire req_regs_write
    input wire [2:0] req_fu
    input wire req_mem2reg
    input wire rob_head_valid_t0
    input wire [ORDER_ID_W-1:0] rob_head_order_id_t0
    input wire rob_head_flushed_t0
    input wire rob_head_valid_t1
    input wire [ORDER_ID_W-1:0] rob_head_order_id_t1
    input wire rob_head_flushed_t1
    output reg resp_valid
    output reg [0:0] resp_tid
    output reg [ORDER_ID_W-1:0] resp_order_id
    output reg [EPOCH_W-1:0] resp_epoch
    output reg [TAG_W-1:0] resp_tag
    output reg [4:0] resp_rd
    output reg [2:0] resp_func3
    output reg resp_regs_write
    output reg [2:0] resp_fu
    output reg [31:0] resp_rdata
    output wire resp_early_wakeup_valid
    output wire [TAG_W-1:0] resp_early_wakeup_tag
    output wire [31:0] mem_addr
    output wire [3:0] mem_read
    input wire [31:0] mem_rdata
    input wire use_mem_subsys
    output wire m1_req_valid
    input wire m1_req_ready
    output wire [31:0] m1_req_addr
    output wire m1_req_write
    output wire [31:0] m1_req_wdata
    output wire [3:0] m1_req_wen
    input wire m1_resp_valid
    input wire [31:0] m1_resp_data
    input wire m1_resp_l1d_hit
    input wire commit0_valid
    input wire commit1_valid
    input wire [ORDER_ID_W-1:0] commit0_order_id
    input wire [ORDER_ID_W-1:0] commit1_order_id
    input wire commit0_is_store
    input wire commit1_is_store
    output wire sb_mem_write_valid
    output wire [31:0] sb_mem_write_addr
    output wire [31:0] sb_mem_write_data
    output wire [3:0] sb_mem_write_wen
    input wire sb_mem_write_ready
    output wire debug_store_buffer_empty
    output wire [2:0] debug_store_buffer_count_t0
    output wire [2:0] debug_store_buffer_count_t1
    output wire load_hazard
    output wire hpm_sb_stall_event
    output wire debug_spec_mmio_load_blocked
    output wire debug_spec_mmio_load_violation
    output wire debug_mmio_load_at_rob_head
    output wire debug_older_store_blocked_mmio_load
    output reg debug_lsu_cooldown_set
    output reg debug_lsu_cooldown_skipped_l1hit
```

### mem_subsys

- 源文件：`rtl/mem_subsys.v`
- 角色：内存子系统中枢：ICache/DCache/RoCC <-> L2/RAM 仲裁
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire m0_req_valid
    output wire m0_req_ready
    input wire [31:0] m0_req_addr
    output wire m0_resp_valid
    output wire [31:0] m0_resp_data
    output wire m0_resp_last
    input wire m0_resp_ready
    input wire [31:0] m0_bypass_addr
    output wire [31:0] m0_bypass_data
    input wire m1_req_valid
    output wire m1_req_ready
    input wire [31:0] m1_req_addr
    input wire m1_req_write
    input wire [31:0] m1_req_wdata
    input wire [3:0] m1_req_wen
    output wire m1_resp_valid
    output wire [31:0] m1_resp_data
    output wire m1_resp_l1d_hit
    input wire m2_req_valid
    output wire m2_req_ready
    input wire [31:0] m2_req_addr
    input wire m2_req_write
    input wire [31:0] m2_req_wdata
    input wire [3:0] m2_req_wen
    output wire m2_resp_valid
    output wire [31:0] m2_resp_data
    output reg [7:0] tube_status
    input wire ext_irq_src
    output wire ext_timer_irq
    output wire ext_external_irq
    input wire uart_rx
    output wire uart_tx
    output wire debug_uart_tx_byte_valid
    output wire [7:0] debug_uart_tx_byte
    output wire [7:0] debug_uart_status_load_count
    output wire [7:0] debug_uart_tx_store_count
    `ifdef VERILATOR_FAST_UART input wire fast_uart_rx_byte_valid
    input wire [7:0] fast_uart_rx_byte
    `endif input wire debug_store_buffer_empty
    input wire [2:0] debug_store_buffer_count_t0
    input wire [2:0] debug_store_buffer_count_t1
    output wire [127:0] debug_ddr3_m0_bus `ifdef ENABLE_DDR3
    output wire ddr3_req_valid
    input wire ddr3_req_ready
    output wire [31:0] ddr3_req_addr
    output wire ddr3_req_write
    output wire [31:0] ddr3_req_wdata
    output wire [3:0] ddr3_req_wen
    input wire ddr3_resp_valid
    input wire [31:0] ddr3_resp_data
    input wire ddr3_init_calib_complete `endif
```

### mmu_sv32

- 源文件：`rtl/mmu_sv32.v`
- 角色：Sv32 MMU（实验性）
- 参数：

```verilog
    parameter ITLB_ENTRIES = 16
    parameter DTLB_ENTRIES = 32
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [31:0] satp
    input wire [1:0] priv_mode
    input wire mstatus_mxr
    input wire mstatus_sum
    input wire sfence_valid
    input wire [31:0] sfence_vaddr
    input wire [8:0] sfence_asid
    input wire itlb_req_valid
    input wire [31:0] itlb_req_vaddr
    output wire itlb_resp_hit
    output wire [31:0] itlb_resp_paddr
    output wire itlb_resp_fault
    output wire itlb_busy
    input wire dtlb_req_valid
    input wire [31:0] dtlb_req_vaddr
    input wire dtlb_req_store
    output wire dtlb_resp_hit
    output wire [31:0] dtlb_resp_paddr
    output wire dtlb_resp_fault
    output wire dtlb_busy
    output reg ptw_axi_arvalid
    input wire ptw_axi_arready
    output reg [31:0] ptw_axi_araddr
    output wire [2:0] ptw_axi_arprot
    input wire ptw_axi_rvalid
    output wire ptw_axi_rready
    input wire [31:0] ptw_axi_rdata
    input wire [1:0] ptw_axi_rresp
```

### stage_mem

- 源文件：`rtl/stage_mem.v`
- 角色：访存级（旧路径）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire[31:0] me_regs_data2
    input wire[31:0] me_alu_o
    input wire me_mem_read
    input wire me_mem_write
    input wire[2:0] me_func3_code
    input wire forward_data
    input wire[31:0] w_regs_data
    `ifdef FPGA_MODE output reg[2:0] me_led
    `endif output wire[31:0] me_mem_data
    input wire sb_write_valid
    input wire [31:0] sb_write_addr
    input wire [31:0] sb_write_data
    input wire [2:0] sb_write_func3
    input wire [3:0] sb_write_wen
    output wire sb_write_ready
```

### store_buffer

- 源文件：`rtl/store_buffer.v`
- 角色：32-entry 写合并 store buffer
- 参数：

```verilog
    parameter SB_DEPTH = 4
    parameter SB_IDX_W = 2
    parameter ORDER_ID_W = `METADATA_ORDER_ID_W
    parameter EPOCH_W = 8
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire [EPOCH_W-1:0] flush_new_epoch_t0
    input wire [EPOCH_W-1:0] flush_new_epoch_t1
    input wire [EPOCH_W-1:0] current_epoch_t0
    input wire [EPOCH_W-1:0] current_epoch_t1
    input wire flush_order_valid
    input wire [ORDER_ID_W-1:0] flush_order_id
    input wire store_req_valid
    output wire store_req_accept
    input wire [0:0] store_tid
    input wire [ORDER_ID_W-1:0] store_order_id
    input wire [EPOCH_W-1:0] store_epoch
    input wire [31:0] store_addr
    input wire [31:0] store_data
    input wire [2:0] store_func3
    input wire commit0_valid
    input wire commit1_valid
    input wire [ORDER_ID_W-1:0] commit0_order_id
    input wire [ORDER_ID_W-1:0] commit1_order_id
    input wire commit0_is_store
    input wire commit1_is_store
    output reg mem_write_valid
    output reg [31:0] mem_write_addr
    output reg [31:0] mem_write_data
    output reg [2:0] mem_write_func3
    output reg [3:0] mem_write_wen
    input wire mem_write_ready
    input wire load_query_valid
    input wire [0:0] load_query_tid
    input wire [ORDER_ID_W-1:0] load_query_order_id
    input wire [31:0] load_query_addr
    input wire [2:0] load_query_func3
    output wire [31:0] forward_data
    output wire forward_valid
    output wire load_hazard
    output wire older_store_pending_for_load
    output wire debug_empty
    output wire [SB_IDX_W:0] debug_count_t0
    output wire [SB_IDX_W:0] debug_count_t1
    output wire sb_stall_event
    output wire sb_drain_urgent
```

### tlb

- 源文件：`rtl/tlb.v`
- 角色：TLB 主体
- 参数：

```verilog
    parameter ENTRIES = 16
    parameter WAYS = 0
    parameter VPN_W = 20
    parameter PPN_W = 22
    parameter ASID_W = 9
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire lookup_valid
    input wire [VPN_W-1:0] lookup_vpn
    input wire [ASID_W-1:0] lookup_asid
    output wire lookup_hit
    output wire [PPN_W-1:0] lookup_ppn
    output wire lookup_is_mega
    output wire [7:0] lookup_perm
    input wire refill_valid
    input wire [VPN_W-1:0] refill_vpn
    input wire [ASID_W-1:0] refill_asid
    input wire [PPN_W-1:0] refill_ppn
    input wire refill_is_mega
    input wire [7:0] refill_perm
    input wire sfence_valid
    input wire [VPN_W-1:0] sfence_vpn
    input wire [ASID_W-1:0] sfence_asid
```

## 07. 控制 / CSR / 中断

### clint

- 源文件：`rtl/clint.v`
- 角色：核心局部中断控制器（CLINT，timer + softirq）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire req_valid
    input wire [31:0] req_addr
    input wire req_wen
    input wire [31:0] req_wdata
    output reg [31:0] resp_rdata
    output reg resp_valid
    output wire [31:0] read_data
    output wire timer_irq
```

### csr_unit

- 源文件：`rtl/csr_unit.v`
- 角色：M-mode CSR + HPM 计数器（mhpmcounter3-9）
- 参数：

```verilog
    parameter HART_ID = 0
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire csr_valid
    input wire [11:0] csr_addr
    input wire [2:0] csr_op
    input wire [31:0] csr_wdata
    output reg [31:0] csr_rdata
    input wire exc_valid
    input wire [31:0] exc_cause
    input wire [31:0] exc_pc
    input wire [31:0] exc_tval
    input wire mret_valid
    input wire mret_commit
    output wire trap_enter
    output wire [31:0] trap_target
    output wire trap_return
    output wire [31:0] mepc_out
    output wire [31:0] satp_out
    output wire [1:0] priv_mode_out
    output wire mstatus_mxr
    output wire mstatus_sum
    output wire global_int_en
    input wire instr_retired
    input wire instr_retired_1
    input wire hpm_branch_mispredict
    input wire hpm_icache_miss
    input wire hpm_dcache_miss
    input wire hpm_l2_miss
    input wire hpm_sb_stall
    input wire hpm_issue_bubble
    input wire hpm_rocc_busy
    input wire ext_timer_irq
    input wire ext_external_irq
```

### plic

- 源文件：`rtl/plic.v`
- 角色：平台级中断控制器（PLIC，外部 IRQ）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire req_valid
    input wire [31:0] req_addr
    input wire req_wen
    input wire [31:0] req_wdata
    output reg [31:0] resp_rdata
    output reg resp_valid
    output wire [31:0] read_data
    input wire ext_irq_src
    output wire external_irq
```

### syn_rst

- 源文件：`rtl/syn_rst.v`
- 角色：同步复位生成器
- 端口：

```verilog
    input wire clock
    input wire rstn
    output wire syn_rstn
```

## 08. SMT / 线程

### regs_mt

- 源文件：`rtl/regs_mt.v`
- 角色：SMT 架构寄存器堆
- 参数：

```verilog
    parameter N_T = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [0:0] r_thread_id
    input wire [4:0] r_regs_addr1
    input wire [4:0] r_regs_addr2
    input wire [0:0] w_thread_id_0
    input wire [4:0] w_regs_addr_0
    input wire [31:0] w_regs_data_0
    input wire w_regs_en_0
    input wire [0:0] w_thread_id_1
    input wire [4:0] w_regs_addr_1
    input wire [31:0] w_regs_data_1
    input wire w_regs_en_1
    output wire [31:0] r_regs_o1
    output wire [31:0] r_regs_o2
```

### thread_scheduler

- 源文件：`rtl/thread_scheduler.v`
- 角色：SMT 线程调度策略
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire [1:0] thread_stall
    input wire smt_mode
    output reg [0:0] fetch_tid
```

## 09. 旧 in-order 路径 (legacy)

### ctrl

- 源文件：`rtl/ctrl.v`
- 角色：控制信号生成（旧路径）
- 端口：

```verilog
    input wire[6:0] inst_op
    output wire br
    output wire mem_read
    output wire mem2reg
    output wire[2:0] alu_op
    output wire mem_write
    output wire[1:0] alu_src1
    output wire[1:0] alu_src2
    output wire br_addr_mode
    output wire regs_write
```

### regs

- 源文件：`rtl/regs.v`
- 角色：架构寄存器堆（旧路径）
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire[4:0] r_regs_addr1
    input wire[4:0] r_regs_addr2
    input wire[4:0] w_regs_addr
    input wire[31:0] w_regs_data
    input wire w_regs_en
    output wire[31:0] r_regs_o1
    output wire[31:0] r_regs_o2
```

### scoreboard

- 源文件：`rtl/scoreboard.v`
- 角色：记分板（旧路径，单发射调试用）
- 参数：

```verilog
    parameter RS_DEPTH = 16
    parameter RS_IDX_W = 4
    parameter RS_TAG_W = 5
    parameter NUM_FU = 8
    parameter NUM_THREAD = 2
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire flush
    input wire [0:0] flush_tid
    input wire flush_order_valid
    input wire [`METADATA_ORDER_ID_W-1:0] flush_order_id
    input wire disp0_valid
    input wire [31:0] disp0_pc
    input wire [31:0] disp0_imm
    input wire [2:0] disp0_func3
    input wire disp0_func7
    input wire [4:0] disp0_rd
    input wire disp0_br
    input wire disp0_mem_read
    input wire disp0_mem2reg
    input wire [2:0] disp0_alu_op
    input wire disp0_mem_write
    input wire [1:0] disp0_alu_src1
    input wire [1:0] disp0_alu_src2
    input wire disp0_br_addr_mode
    input wire disp0_regs_write
    input wire [4:0] disp0_rs1
    input wire [4:0] disp0_rs2
    input wire disp0_rs1_used
    input wire disp0_rs2_used
    input wire [2:0] disp0_fu
    input wire [0:0] disp0_tid
    input wire disp0_is_mret
    input wire disp1_valid
    input wire [31:0] disp1_pc
    input wire [31:0] disp1_imm
    input wire [2:0] disp1_func3
    input wire disp1_func7
    input wire [4:0] disp1_rd
    input wire disp1_br
    input wire disp1_mem_read
    input wire disp1_mem2reg
    input wire [2:0] disp1_alu_op
    input wire disp1_mem_write
    input wire [1:0] disp1_alu_src1
    input wire [1:0] disp1_alu_src2
    input wire disp1_br_addr_mode
    input wire disp1_regs_write
    input wire [4:0] disp1_rs1
    input wire [4:0] disp1_rs2
    input wire disp1_rs1_used
    input wire disp1_rs2_used
    input wire [2:0] disp1_fu
    input wire [0:0] disp1_tid
    input wire disp1_is_mret
    output wire disp_stall
    output wire [RS_TAG_W-1:0] disp0_tag
    output wire [RS_TAG_W-1:0] disp1_tag
    output reg iss0_valid
    output reg [RS_TAG_W-1:0] iss0_tag
    output reg [31:0] iss0_pc
    output reg [31:0] iss0_imm
    output reg [2:0] iss0_func3
    output reg iss0_func7
    output reg [4:0] iss0_rd
    output reg [4:0] iss0_rs1
    output reg [4:0] iss0_rs2
    output reg iss0_rs1_used
    output reg iss0_rs2_used
    output reg [RS_TAG_W-1:0] iss0_src1_tag
    output reg [RS_TAG_W-1:0] iss0_src2_tag
    output reg iss0_br
    output reg iss0_mem_read
    output reg iss0_mem2reg
    output reg [2:0] iss0_alu_op
    output reg iss0_mem_write
    output reg [1:0] iss0_alu_src1
    output reg [1:0] iss0_alu_src2
    output reg iss0_br_addr_mode
    output reg iss0_regs_write
    output reg [2:0] iss0_fu
    output reg [0:0] iss0_tid
    output reg iss1_valid
    output reg [RS_TAG_W-1:0] iss1_tag
    output reg [31:0] iss1_pc
    output reg [31:0] iss1_imm
    output reg [2:0] iss1_func3
    output reg iss1_func7
    output reg [4:0] iss1_rd
    output reg [4:0] iss1_rs1
    output reg [4:0] iss1_rs2
    output reg iss1_rs1_used
    output reg iss1_rs2_used
    output reg [RS_TAG_W-1:0] iss1_src1_tag
    output reg [RS_TAG_W-1:0] iss1_src2_tag
    output reg iss1_br
    output reg iss1_mem_read
    output reg iss1_mem2reg
    output reg [2:0] iss1_alu_op
    output reg iss1_mem_write
    output reg [1:0] iss1_alu_src1
    output reg [1:0] iss1_alu_src2
    output reg iss1_br_addr_mode
    output reg iss1_regs_write
    output reg [2:0] iss1_fu
    output reg [0:0] iss1_tid
    output wire branch_pending_any
    output wire debug_br_found_t0
    output wire debug_branch_in_flight_t0
    output wire debug_oldest_br_ready_t0
    output wire debug_oldest_br_just_woke_t0
    output wire [3:0] debug_oldest_br_qj_t0
    output wire [3:0] debug_oldest_br_qk_t0
    output wire [3:0] debug_slot1_flags
    output wire [7:0] debug_slot1_pc_lo
    output wire [3:0] debug_slot1_qj
    output wire [3:0] debug_slot1_qk
    output wire [3:0] debug_tag2_flags
    output wire [3:0] debug_reg_x12_tag_t0
    output wire [3:0] debug_slot1_issue_flags
    output wire [3:0] debug_sel0_idx
    output wire [3:0] debug_slot1_fu
    output wire [7:0] debug_oldest_br_seq_lo_t0
    output wire [15:0] debug_rs_flags_flat
    output wire [31:0] debug_rs_pc_lo_flat
    output wire [15:0] debug_rs_fu_flat
    output wire [15:0] debug_rs_qj_flat
    output wire [15:0] debug_rs_qk_flat
    output wire [31:0] debug_rs_seq_lo_flat
    input wire wb0_valid
    input wire [RS_TAG_W-1:0] wb0_tag
    input wire [4:0] wb0_rd
    input wire wb0_regs_write
    input wire [2:0] wb0_fu
    input wire [0:0] wb0_tid
    input wire wb1_valid
    input wire [RS_TAG_W-1:0] wb1_tag
    input wire [4:0] wb1_rd
    input wire wb1_regs_write
    input wire [2:0] wb1_fu
    input wire [0:0] wb1_tid
    input wire commit0_valid
    input wire [RS_TAG_W-1:0] commit0_tag
    input wire [0:0] commit0_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit0_order_id
    input wire commit1_valid
    input wire [RS_TAG_W-1:0] commit1_tag
    input wire [0:0] commit1_tid
    input wire [`METADATA_ORDER_ID_W-1:0] commit1_order_id
    input wire br_complete
    input wire rocc_ready
    input wire iss0_is_rocc
    input wire [`METADATA_ORDER_ID_W-1:0] disp0_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp0_epoch
    input wire [`METADATA_ORDER_ID_W-1:0] disp1_order_id
    input wire [`METADATA_EPOCH_W-1:0] disp1_epoch
    output reg [`METADATA_ORDER_ID_W-1:0] iss0_order_id
    output reg [`METADATA_EPOCH_W-1:0] iss0_epoch
    output reg [`METADATA_ORDER_ID_W-1:0] iss1_order_id
    output reg [`METADATA_EPOCH_W-1:0] iss1_epoch
```

### stage_is

- 源文件：`rtl/stage_is.v`
- 角色：发射级（旧路径）
- 端口：

```verilog
    input wire[31:0] is_inst
    input wire[31:0] is_pc
    output wire[31:0] is_pc_o
    output wire[31:0] is_imm
    output wire[2:0] is_func3_code
    output wire is_func7_code
    output wire[4:0] is_rd
    output wire is_br
    output wire is_mem_read
    output wire is_mem2reg
    output wire[2:0] is_alu_op
    output wire is_mem_write
    output wire[1:0] is_alu_src1
    output wire[1:0] is_alu_src2
    output wire is_br_addr_mode
    output wire is_regs_write
    output wire[4:0] is_rs1
    output wire[4:0] is_rs2
    output reg is_rs1_used
    output reg is_rs2_used
    output reg[2:0] is_fu
    output wire is_valid
    output wire is_system
    output wire is_csr
    output wire is_mret
    output wire [11:0] csr_addr
    output wire is_rocc
    output wire [6:0] rocc_funct7
```

### stage_wb

- 源文件：`rtl/stage_wb.v`
- 角色：写回级（旧路径）
- 端口：

```verilog
    input wire[31:0] wb_mem_data
    input wire[31:0] wb_alu_o
    input wire wb_mem2reg
    input wire[2:0] wb_func3_code
    output wire[31:0] w_regs_data
```

## 10. UART / 调试 / RoCC

### debug_beacon_tx

- 源文件：`rtl/debug_beacon_tx.v`
- 角色：调试 beacon 发送器
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire evt_valid
    output wire evt_ready
    input wire [7:0] evt_type
    input wire [7:0] evt_arg
    output wire byte_valid
    input wire byte_ready
    output wire [7:0] byte_data
```

### rocc_ai_accelerator

- 源文件：`rtl/rocc_ai_accelerator.v`
- 角色：RoCC AI 加速器（可选）
- 参数：

```verilog
    parameter SA_SIZE = 8
    parameter VEC_WIDTH = 128
    parameter SCRATCH_KB = 4
    parameter TAG_W = 5
```
- 端口：

```verilog
    input wire clk
    input wire rstn
    input wire cmd_valid
    output wire cmd_ready
    input wire [6:0] cmd_funct7
    input wire [2:0] cmd_funct3
    input wire [4:0] cmd_rd
    input wire [31:0] cmd_rs1_data
    input wire [31:0] cmd_rs2_data
    input wire [TAG_W-1:0] cmd_tag
    input wire [0:0] cmd_tid
    output reg resp_valid
    input wire resp_ready
    output reg [4:0] resp_rd
    output reg [31:0] resp_data
    output reg [TAG_W-1:0] resp_tag
    output reg [0:0] resp_tid
    output reg mem_req_valid
    input wire mem_req_ready
    output reg [31:0] mem_req_addr
    output reg [31:0] mem_req_wdata
    output reg mem_req_wen
    input wire mem_resp_valid
    input wire [31:0] mem_resp_rdata
    output wire accel_busy
    output wire accel_interrupt
```

### uart_rx

- 源文件：`rtl/uart_rx.v`
- 角色：标准 UART RX
- 参数：

```verilog
    parameter integer CLK_DIV = 434
```
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire enable
    input wire rx
    output reg byte_valid
    output reg [7:0] byte_data
    output reg frame_error
```

### uart_tx

- 源文件：`rtl/uart_tx.v`
- 角色：标准 UART TX
- 参数：

```verilog
    parameter CLK_DIV = 434
```
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire tx_start
    input wire [7:0] tx_data
    output reg tx
    output reg busy
```

### uart_tx_simple

- 源文件：`rtl/uart_tx_simple.v`
- 角色：简化 UART TX（FPGA 调试用）
- 端口：

```verilog
    input wire clk
    input wire rst_n
    output reg tx
```

## 11. FPGA 板级顶层与 beacon

### adam_riscv_ax7203_beacon_transport_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_beacon_transport_top.v`
- 角色：板级顶层变体：UART beacon 透传调试
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_branch_probe_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_branch_probe_top.v`
- 角色：板级顶层变体：branch 探针
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_io_smoke_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_io_smoke_top.v`
- 角色：板级顶层变体：IO smoke 测试
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_issue_probe_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_issue_probe_top.v`
- 角色：板级顶层变体：issue 探针
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_main_bridge_probe_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_main_bridge_probe_top.v`
- 角色：板级顶层变体：主桥探针
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_status_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_status_top.v`
- 角色：板级顶层变体：status beacon
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### adam_riscv_ax7203_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_top.v`
- 角色：AX7203 板级最终顶层（核心 + DDR3 桥 + UART + LED）
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led `ifdef ENABLE_DDR3
    inout wire [31:0] ddr3_dq
    inout wire [3:0] ddr3_dqs_p
    inout wire [3:0] ddr3_dqs_n
    output wire [14:0] ddr3_addr
    output wire [2:0] ddr3_ba
    output wire ddr3_ras_n
    output wire ddr3_cas_n
    output wire ddr3_we_n
    output wire ddr3_ck_p
    output wire ddr3_ck_n
    output wire ddr3_cke
    output wire ddr3_reset_n
    output wire [3:0] ddr3_dm
    output wire ddr3_odt
    output wire ddr3_cs_n `endif
```

### adam_riscv_ax7203_uart_echo_raw_top

- 源文件：`fpga/rtl/adam_riscv_ax7203_uart_echo_raw_top.v`
- 角色：板级顶层变体：UART 回环 smoke
- 端口：

```verilog
    input wire sys_clk_p
    input wire sys_clk_n
    input wire sys_rst_n
    output wire uart_tx
    input wire uart_rx
    output wire [4:0] led
```

### uart_branch_probe_beacon

- 源文件：`fpga/rtl/uart_branch_probe_beacon.v`
- 角色：UART branch probe beacon
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire core_ready
    input wire retire_seen
    input wire tube_pass
    input wire [7:0] last_iss0_pc_lo
    input wire [7:0] last_iss1_pc_lo
    input wire branch_pending
    input wire br_found_t0
    input wire branch_in_flight_t0
    input wire oldest_br_ready_t0
    input wire oldest_br_just_woke_t0
    input wire [3:0] oldest_br_qj_t0
    input wire [3:0] oldest_br_qk_t0
    input wire [7:0] uart_status_load_count
    input wire [7:0] uart_tx_store_count
    input wire [3:0] uart_flags
    input wire [3:0] tag2_flags
    input wire [3:0] reg_x12_tag_t0
    output wire tx
```

### uart_ddr3_fetch_probe_beacon

- 源文件：`fpga/rtl/uart_ddr3_fetch_probe_beacon.v`
- 角色：UART DDR3 fetch probe beacon
- 参数：

```verilog
    parameter integer CLK_DIV = 217
```
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire core_ready
    input wire ddr3_calib_done
    input wire core_uart_byte_valid
    input wire [7:0] core_uart_byte
    input wire [383:0] debug_bus
    output wire tx
    output wire active
    output reg debug_byte_valid
    output reg [7:0] debug_byte
```

### uart_issue_probe_beacon

- 源文件：`fpga/rtl/uart_issue_probe_beacon.v`
- 角色：UART issue probe beacon
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire core_ready
    input wire retire_seen
    input wire tube_pass
    input wire [7:0] last_iss0_pc_lo
    input wire [7:0] last_iss1_pc_lo
    input wire branch_pending
    input wire br_found_t0
    input wire branch_in_flight_t0
    input wire [3:0] oldest_br_qj_t0
    input wire [7:0] oldest_br_seq_lo_t0
    input wire [15:0] rs_flags_flat
    input wire [31:0] rs_pc_lo_flat
    input wire [15:0] rs_fu_flat
    input wire [15:0] rs_qj_flat
    input wire [15:0] rs_qk_flat
    input wire [31:0] rs_seq_lo_flat
    output wire tx
```

### uart_main_bridge_beacon

- 源文件：`fpga/rtl/uart_main_bridge_beacon.v`
- 角色：UART 主桥 probe beacon
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire core_ready
    input wire retire_seen
    input wire tube_pass
    input wire [7:0] core_uart_frame_count_rolling
    input wire [7:0] board_tx_start_count
    input wire [7:0] board_uart_frame_count_rolling
    input wire [3:0] bridge_flags
    output wire tx
```

### uart_rx_monitor

- 源文件：`fpga/rtl/uart_rx_monitor.v`
- 角色：UART RX 监控（核心 boot 监控）
- 参数：

```verilog
    parameter integer CLK_DIV = 1736
```
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire rx
    output reg frame_seen
    output reg [3:0] frame_count
    output reg [7:0] frame_count_rolling
    output reg byte_valid
    output reg [7:0] byte_data
```

### uart_status_beacon

- 源文件：`fpga/rtl/uart_status_beacon.v`
- 角色：UART status beacon（板级）
- 端口：

```verilog
    input wire clk
    input wire rst_n
    input wire core_ready
    input wire retire_seen
    input wire tube_pass
    input wire core_uart_seen
    input wire core_uart_frame_seen
    input wire [7:0] core_uart_frame_count_rolling
    input wire [7:0] bridge_uart_frame_count_rolling
    input wire [7:0] debug_uart_status_load_count
    input wire [7:0] debug_uart_tx_store_count
    input wire [3:0] debug_uart_flags
    input wire [7:0] debug_last_iss0_pc_lo
    input wire [7:0] debug_last_iss1_pc_lo
    input wire debug_branch_pending_any
    input wire debug_br_found_t0
    input wire debug_branch_in_flight_t0
    input wire debug_oldest_br_ready_t0
    input wire debug_oldest_br_just_woke_t0
    input wire [3:0] debug_oldest_br_qj_t0
    input wire [3:0] debug_oldest_br_qk_t0
    input wire [3:0] debug_slot1_flags
    input wire [7:0] debug_slot1_pc_lo
    input wire [3:0] debug_slot1_qj
    input wire [3:0] debug_slot1_qk
    input wire [3:0] debug_tag2_flags
    input wire [3:0] debug_reg_x12_tag_t0
    input wire [3:0] debug_slot1_issue_flags
    input wire [3:0] debug_sel0_idx
    input wire [3:0] debug_slot1_fu
    input wire [7:0] debug_branch_issue_count
    input wire [7:0] debug_branch_complete_count
    output wire tx
```

## 99. 其它

### uart_tx_autoboot

- 源文件：`rtl/uart_tx.v`
- 端口：

```verilog
    input wire clk
    input wire rst_n
    output wire tx
```
