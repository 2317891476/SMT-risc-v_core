# AdamRiscv — 高性能乱序双发射 RISC-V 处理器

## 1. 项目概述

`AdamRiscv` 是面向**全国 CPU 系统能力培养大赛**的高性能 RV32I 处理器实现。项目在一个教学级 SMT 有序内核基础上，完成了工业级的微架构升级。

IF → FB → DualDec → Scoreboard(IS) → reg_is_ro → RO → EX → MEM → WB
 1    2      3            4              5         6    7     8    9

### 当前架构能力

| 维度 | 能力 |
|------|------|
| **ISA** | RV32I 全部 47 条指令 + RV32M 乘法扩展 |
| **发射宽度** | 双发射 (Dual-Issue)，双调度端口 |
| **执行引擎** | 乱序执行 (OoO)，16-entry Reservation Station，Scoreboard 动态调度 |
| **流水线** | IF → FetchBuffer → DualDecode → Scoreboard(IS) → **reg_is_ro** → RO → EX(Pipe0/Pipe1) → MEM → WB |
| **分支预测** | 256-entry 双模态 (Bimodal) 2-bit 饱和计数器 + BTB |
| **SMT** | 2 线程同步多线程，Round-Robin 取指调度，独立 PC 和寄存器堆 |
| **虚拟内存** | Sv32 MMU：I-TLB(16) + D-TLB(32) + 7 状态硬件页表漫游器 (PTW) |
| **缓存** | L1 ICache: 2KB 直接映射, 32B 行<br>L1 DCache: 4-way 非阻塞 (已定义，当前未启用)<br>L2: 仿真走 8KB 4-way 缓存 / FPGA 走 Passthrough 直连片上 RAM |
| **总线** | AXI4 突发传输接口 (缓存行填充/写回) + DDR3 AXI4 256-bit CDC 桥接 |
| **AI 加速** | RoCC 协处理器：8×8 INT8 GEMM 引擎 + 128-bit SIMD 向量单元 + KV-Cache 压缩 |
| **特权态** | Machine-mode CSR (mstatus/mepc/mcause/mtvec/satp)，异常入口/MRET |
| **中断** | CLINT (定时器中断) + PLIC (外部中断)，支持 mcause=0x80000007/0B |

---

## 2. 微架构图

```
  ╔═══════════════════ FRONTEND ═══════════════════════╗
  ║  Thread Scheduler (Round-Robin)                    ║
  ║       ↓                                            ║
  ║  PC_MT ──→ IROM ──→ BPU(256-entry Bimodal+BTB)    ║
  ║       ↓                                            ║
  ║  Fetch Buffer (4-entry FIFO, per-thread flush)     ║
  ╚═══════════════════╤═══════════════════════════════╝
                      │ ×2 instructions
  ╔═══════════════════▼═══════════════════════════════╗
  ║          DUAL DECODER (IS0 / IS1)                  ║
  ║  • 复用 stage_is (ctrl + imm_gen) ×2              ║
  ║  • 结构冒险检测: 双分支/双访存/WAW 冲突           ║
  ╚═══════════════════╤═══════════════════════════════╝
                      │ ×2 decoded μops
  ╔═══════════════════▼═══════════════════════════════╗
  ║        SCOREBOARD (16-entry RS)                 ║
  ║  • 双分派 (Dual-Dispatch)                          ║
  ║  • 双发射仲裁 (oldest-first, 不同 FU)              ║
  ║  • 双 CDB 唤醒 (wb0 / wb1)                        ║
  ║  • WAR 检查 + 同周期分派依赖处理                    ║
  ║  • Per-thread reg_result_status + flush             ║
  ╚═════╤══════════════════════════════╤══════════════╝
        │ Issue Port 0                  │ Issue Port 1
  ┌─────▼──────┐                 ┌──────▼──────────┐
  │ Bypass Net │                 │  Bypass Net      │
  │ (3-source) │                 │  (3-source)      │
  ├────────────┤                 ├──────────────────┤
  │ EXEC_PIPE0 │                 │   EXEC_PIPE1     │
  │ ALU+Branch │                 │   ALU + MUL(3c)  │
  │            │                 │   + AGU (LD/ST)  │
  └─────┬──────┘                 └──┬────────┬──────┘
        │ br_ctrl →                 │        │
        │ flush + redirect     ┌────▼────┐   │ MUL result
        │                      │ D-TLB   │   │ (3-cycle)
        │                      │ DCache  │   │
        │                      │ (4-way) │   │
        │                      │  AXI4   │   │
        │                      └────┬────┘   │
  ┌─────▼──────────────────────────▼─────────▼────┐
  │              WRITE-BACK (WB)                   │
  │  CDB broadcast → Scoreboard wakeup            │
  │  双写回端口 → 寄存器堆                          │
  └────────────────────┬──────────────────────────┘
                       │ RoCC cmd
  ┌────────────────────▼──────────────────────────┐
  │          AI ACCELERATOR (RoCC)                 │
  │  GEMM 8×8  │  SIMD VPU  │  KV-Cache Compress  │
  │  Scratchpad (4KB)  │  DMA to main memory       │
  └────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────┐
  │              CSR Unit (Machine-mode)            │
  │  mstatus │ mepc │ mcause │ mtvec │ satp        │
  │  mcycle  │ minstret │ 异常入口/MRET             │
  └────────────────────────────────────────────────┘
```

---

## 3. 目录结构

```text
AdamRiscv/
├─ module/CORE/RTL/           # 核心 RTL
│  ├─ adam_riscv.v                  # 顶层 (乱序双发射)
│  ├─ adam_riscv.v                顶层 (乱序双发射, 新架构)
│  │
│  │  ── 前端 ──
│  ├─ stage_if.v                 # ★ 升级版 IF (集成 BPU)
│  ├─ bpu_bimodal.v                 # ★ 256-entry 分支预测器 + BTB
│  ├─ fetch_buffer.v                # ★ 4-entry 取指缓冲 FIFO
│  ├─ decoder_dual.v                # ★ 双路译码 + 结构冒险检测
│  │
│  │  ── 乱序引擎 ──
│  ├─ scoreboard.v               # ★ 16-entry RS, 双分派/发射/CDB
│  ├─ bypass_network.v              # ★ 3 源前递网络
│  ├─ exec_pipe0.v                  # ★ 执行管道0 (INT+Branch)
│  ├─ exec_pipe1.v                  # ★ 执行管道1 (INT+MUL+AGU)
│  ├─ mul_unit.v                    # ★ 3 级流水乘法器 (RV32M)
│  │
│  │  ── 存储子系统 ──
│  ├─ tlb.v                         # ★ 参数化全相联 TLB
│  ├─ mmu_sv32.v                    # ★ Sv32 MMU + 硬件 PTW
│  ├─ l1_dcache_nb.v                # ★ 4-way 非阻塞 DCache + AXI4
│  ├─ mem_subsys.v                  # ★ 统一内存子系统 (L2缓存 + 仲裁器 + MMIO)
│  ├─ l2_cache.v                    # ★ 8KB 4路 L2 缓存 (32B 行，PLRU，阻塞设计)
│  ├─ l2_arbiter.v                  # ★ 2主设备轮询仲裁器 (I-side/D-side)
│  ├─ clint.v                       # ★ 内核本地中断器 (CLINT，定时器中断)
│  ├─ plic.v                        # ★ 平台级中断控制器 (PLIC，外部中断)
│  │
│  │  ── 扩展 ──
│  ├─ rocc_ai_accelerator.v         # ★ RoCC AI 协处理器
│  ├─ csr_unit.v                    # ★ 特权态 CSR + 异常处理
│  ├─ define.v                   # ★ 扩展定义
│  │
│  │  ── 基础模块 ──
│  ├─ scoreboard.v                  # 基础模块
│  ├─ thread_scheduler.v            # Round-Robin 调度器 模块
│  ├─ pc_mt.v                       # 双线程 PC 管理器 模块
│  ├─ regs_mt.v                     # 双 bank 寄存器堆 模块
│  ├─ stage_if.v / stage_is.v / stage_ro.v / stage_ex.v
│  ├─ stage_mem.v / stage_wb.v      # MEM/WB 模块
│  ├─ alu.v / alu_control.v / ctrl.v / imm_gen.v
│  ├─ reg_if_id.v / reg_is_ro.v / reg_ro_ex.v / reg_ex_stage.v
│  ├─ reg_ex_mem.v / reg_mem_wb.v
│  ├─ syn_rst.v / define.v
│  └─ uart_tx.v                     # ★ UART 发送模块
│
├─ fpga/                            # ★ FPGA 板级支持 (AX7203)
│  ├─ board_manifest_ax7203.md      # ★ AX7203 板级规格
│  ├─ observability_contract_ax7203.md  # ★ UART/LED 输出规范
│  ├─ resource.md                   # ★ 官方引脚资源文档
│  ├─ rtl/
│  │  ├─ adam_riscv_ax7203_top.v # ★ FPGA 顶层封装
│  │  └─ uart_tx_simple.v           # ★ 简化 UART (板级调试)
│  ├─ constraints/
│  │  ├─ ax7203_base.xdc            # ★ 时钟/复位约束
│  │  └─ ax7203_uart_led.xdc        # ★ UART/LED 约束
│  ├─ ip/
│  │  └─ create_clk_wiz_ax7203.tcl  # ★ 时钟向导 IP
│  ├─ bram_init/
│  │  ├─ create_bram_ip.tcl         # ★ BRAM IP 生成
│  │  ├─ inst_mem.coe               # ★ 指令存储器初始化
│  │  └─ data_mem.coe               # ★ 数据存储器初始化
│  └─ *.tcl                         # ★ Vivado 流程脚本
│
└─ libs/REG_ARRAY/SRAM/ram_bfm.v    # 行为级 RAM 模型
```

> 标注 ★ 的文件为本次升级新增。

---

## 4. 模块详解

### 4.1 前端 (Frontend)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `stage_if` | IF 级：PC 管理 + 取指 + BPU 查询 | 集成 pc_mt + inst_memory + bpu_bimodal |
| `bpu_bimodal` | 2-bit 饱和计数器 + 直接映射 BTB | PHT_ENTRIES=256, XOR-fold thread indexing |
| `fetch_buffer` | 取指缓冲 FIFO，双弹出支持双译码 | DEPTH=4, per-thread flush |
| `decoder_dual` | 双路译码器，复用 stage_is ×2 | 检测: 双分支/双访存/WAW 冲突 |

### 4.2 乱序引擎 (OoO Engine)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `scoreboard` | 集中式调度窗口 | RS_DEPTH=16, 双分派/双发射/双CDB |
| `bypass_network` | 前递网络 (pipe0 > pipe1 > mem > regfile) | 纯组合逻辑, 1 级 MUX |
| `exec_pipe0` | 执行管道0: INT ALU + Branch 解析 | 1 周期延迟 |
| `exec_pipe1` | 执行管道1: INT ALU + MUL + AGU | MUL 3 周期, AGU 1 周期 |
| `mul_unit` | 3 级流水 Booth 乘法器 | 支持 MUL/MULH/MULHSU/MULHU |

### 4.3 存储子系统 (Memory Subsystem)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `tlb` | 参数化全相联 TLB | ENTRIES=16/32, mega-page, SFENCE.VMA |
| `mmu_sv32` | Sv32 MMU + hardware 页表漫游器 | I-TLB(16) + D-TLB(32), 7-state PTW FSM |
| `l1_dcache_nb` | 非阻塞 L1 数据缓存 | 4KB, 4-way, 32B line, PLRU, AXI4 burst |

### 4.4 L2 缓存与中断控制器 (P2 Implementation)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `mem_subsys` | 统一内存子系统 | 集成 L2 缓存、仲裁器、MMIO |
| `l2_cache` | 统一二级缓存 | 仿真: 8KB 4-way 32B 行 PLRU；FPGA: `L2_PASSTHROUGH` 直连片上 RAM |
| `l2_arbiter` | 3主设备优先级仲裁器 | I-side (M0) + D-side (M1) + RoCC DMA (M2), M2优先级最高 |
| `clint` | 内核本地中断器 (CLINT) | 64位 mtime/mtimecmp, 定时器中断 |
| `plic` | 平台级中断控制器 (PLIC) | 优先级/使能/阈值寄存器, Claim/Complete |

**L2 缓存特性：**
- 仿真模式: 8KB 总容量，4路组相联，32字节缓存行，PLRU 替换，写回+写分配，阻塞设计
- FPGA 模式 (`L2_PASSTHROUGH`): 绕过 tag/data 数组，3-state FSM (PT_IDLE→PT_READ→PT_WRITE)，2-3 cycle 直连 RAM，仅 81 LUTs
- 后续规划: 不保留完整 L2 cache，仅保留 L1 并通过 AXI 接口直连 DDR3
- MMIO 旁路：TUBE/CLINT/PLIC 访问直接旁路 L2

**中断控制器特性：**
- CLINT：RISC-V 标准机器定时器中断 (mcause=0x80000007)
- PLIC：RISC-V 标准外部中断控制器 (mcause=0x8000000B)
- 支持中断屏蔽 (mie 寄存器) 和 MRET 返回

### 4.5 RoCC AI 加速器 (P3 Implementation)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `rocc_ai_accelerator` | RoCC AI 协处理器 | GEMM 8×8 INT8/INT32, SIMD 128-bit, 4KB scratchpad, DMA (M2) |

**RoCC 指令编码 (custom-0 opcode 0x0B):**

| funct7 | 指令 | 描述 |
|--------|------|------|
| 0 | GEMM.START | 启动 8×8 矩阵乘法 (rs1=A, rs2=B, rd=C) |
| 1 | VEC.OP | 向量操作 (VADD/VMUL/VRELU/VREDUCE) |
| 3 | SCRATCH.LOAD | DMA 从 RAM 加载到 scratchpad |
| 4 | SCRATCH.STORE | DMA 从 scratchpad 存储到 RAM |
| 5 | STATUS.READ | 读取加速器状态到 rd |

**RoCC DMA 特性：**
- 专用 M2 主设备，优先级高于 M0/M1
- RAM-only 访问 (0x0000_0000 - 0x0000_3FFF)
- 单拍确定性传输，支持地址错误检测
- DMA 完成通过现有 WB/ROB 机制退休

**RoCC 测试集：**
| 测试文件 | 覆盖内容 |
|---------|---------|
| `test_rocc_dma.s` | SCRATCH.LOAD/STORE, 错误地址检测 |
| `test_rocc_gemm.s` | GEMM.START 8×8 矩阵乘法 |
| `test_rocc_status.s` | STATUS.READ 格式验证 |

### 4.6 其他扩展 (Other Extensions)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `csr_unit` | Machine-mode CSR 单元 | mstatus/mepc/mcause/mtvec/satp, cycle/instret |

---

## 5. 环境配置

### 5.1 必需工具

| 工具 | 用途 | 当前安装路径 |
|------|------|-------------|
| `riscv-none-elf-gcc` | 交叉编译 | `E:\xpack-riscv-none-elf-gcc-15.2.0-1\bin\` |
| `iverilog` / `vvp` | 仿真 | `E:\iverilog\bin\` |
| `gtkwave` (可选) | 波形查看 | `E:\iverilog\gtkwave\bin\` |

### 5.2 PATH 配置

```powershell
$env:PATH = "E:\iverilog\bin;E:\xpack-riscv-none-elf-gcc-15.2.0-1\bin;E:\iverilog\gtkwave\bin;" + $env:PATH
```

---

## 6. 快速开始

### 运行全部回归测试 

```powershell
python verification/run_all_tests.py --basic
```

期望输出:

```
============================================================
  AdamRiscv Unified Test Runner
  2026-03-29 13:59:12
============================================================
  Running basic tests...
  Testing test1...
  test1: PASS
  Testing test2...
  test2: PASS
  ...
============================================================
  Test Summary
============================================================
  Total: 26 passed, 0 failed, 0 skipped
```

### 运行 RoCC 协处理器测试

RoCC 目前已经改成**可配置开关**；默认 `--basic` 回归**不启用** RoCC RTL，也**不包含** 3 个 RoCC 专项测试。需要显式加 `--enable-rocc` 才会打开加速器并纳入回归。

```powershell
# 运行基础回归 + RoCC 测试（26 个基础测试 + 3 个 RoCC 测试）
python verification/run_all_tests.py --basic --enable-rocc

# 单独运行特定 RoCC 测试
python verification/run_all_tests.py --basic --enable-rocc --tests test_rocc_dma.s
python verification/run_all_tests.py --basic --enable-rocc --tests test_rocc_status.s
python verification/run_all_tests.py --basic --enable-rocc --tests test_rocc_gemm.s

# 一次运行所有 RoCC 测试
python verification/run_all_tests.py --basic --enable-rocc --tests test_rocc_dma.s test_rocc_status.s test_rocc_gemm.s
```

RoCC 测试说明：

| 测试文件 | 功能覆盖 | 测试内容 |
|---------|---------|---------|
| `test_rocc_dma.s` | SCRATCH.LOAD/STORE | DMA 数据搬运、地址边界检测、错误地址处理 |
| `test_rocc_status.s` | STATUS.READ | 状态寄存器格式验证、忙/完成/错误位检测 |
| `test_rocc_gemm.s` | GEMM.START | 8×8 INT8 矩阵乘法、三地址数据传输 |

期望输出：

```
============================================================
  Running basic tests...
  Testing test_rocc_dma...
  test_rocc_dma: PASS
  Testing test_rocc_status...
  test_rocc_status: PASS
  Testing test_rocc_gemm...
  test_rocc_gemm: PASS
============================================================
```

### riscv-tests 测试说明

riscv-tests 是经典的 RISC-V 测试套件，包含 RV32I/M 指令测试。

```powershell
# 运行 riscv-tests
python verification/run_all_tests.py --riscv-tests

# 或使用底层脚本
python verification/run_riscv_tests.py --suite riscv-tests
```

**当前状态**: 50/50 测试通过 (PASS)

| 测试 | 状态 | 说明 |
|------|------|------|
| 50 个基础测试 | ✅ PASS | RV32I/M 指令测试全部通过（含此前预期失败的 4 个测试） |

**技术细节**:
- 通过率阈值设置为 90%，允许需要可选扩展的测试失败
- 非对齐访问是处理器设计选择，不影响标准 RV32I/M 兼容性
- 实际部署时若需要支持非对齐访问，可启用 DCache 的硬件处理
- `verification/run_riscv_tests.py` 现在会在每个测试前清理 `rom/inst.hex` / `rom/data.hex`，并为当前测试重新生成镜像
- 当测试 ELF 不包含 `.data` 段时，脚本会自动写入一个空 `data.hex`，避免沿用上一轮的陈旧数据镜像
- Icarus 仿真超时门限已提高到 `120s`，减少大测试在 Windows 下的误报 timeout

### 运行统一测试脚本 

统一测试脚本支持多种测试集，测试集会自动下载：

```powershell
# 运行所有测试（basic + riscv-tests + riscv-arch-test）
python verification/run_all_tests.py --basic --riscv-tests --riscv-arch-test

# 单独运行各测试集
python verification/run_all_tests.py --basic              # 基础测试 (默认 26 个测试，不含 RoCC)
python verification/run_all_tests.py --basic --enable-rocc  # 基础测试 + 3 个 RoCC 测试
python verification/run_all_tests.py --riscv-tests        # 经典 riscv-tests (自动下载)
python verification/run_all_tests.py --riscv-arch-test    # 官方 arch-test (自动下载)

# 直接使用 run_riscv_tests.py
python verification/run_riscv_tests.py --suite riscv-tests           # RV32I + RV32M
python verification/run_riscv_tests.py --suite riscv-arch-test       # RV32I + RV32M
python verification/run_riscv_tests.py --suite riscv-arch-test --categories rv32i   # 仅 RV32I
python verification/run_riscv_tests.py --suite all                   # 运行所有套件
```

期望输出:

```
============================================================
  Test Summary
============================================================
  [PASS] test1: PASS
  [PASS] test2: PASS
  [PASS] test_rv32i_full: PASS
  [PASS] test_store_buffer_simple: PASS
  [PASS] test_store_buffer_commit: PASS
  [PASS] test_store_buffer_forwarding: PASS
  [PASS] test_store_buffer_hazard: PASS
  [PASS] test_commit_flush_store: PASS
  [PASS] test_store_buffer_stream_multiline: PASS
  [PASS] test_l2_mmio_ping_pong: PASS
  [PASS] test_plic_retrigger: PASS
  [PASS] riscv-tests: PASS (50/50 passed)
  [PASS] riscv-arch-test: PASS (47/47 passed)

------------------------------------------------------------
  Total: 28 passed, 0 failed, 0 skipped
```

### 运行 管线仿真（Canonical Entrypoint）

```powershell
python verification/run_all_tests.py --basic
```

`run_all_tests.py` 是 AX7203 / 仿真的规范入口；它会自动处理 ROM 编译、仿真运行和结果验证，为每个测试独立生成 `inst.hex` 和 `data.hex`。

当前脚本行为已经同步到 Windows 仿真环境：
- ROM 构建使用**顺序、无 shell 拼接**的命令调用，避免 `cmd.exe` 多行命令吞掉后续 `objcopy`
- 每个测试前都会清理并重建 `inst.hex` / `data.hex`，避免陈旧镜像污染后续回归
- PASS/FAIL 判定以 testbench 的明确结果标记为准，不再依赖宽松的字符串包含判断

---

## 7. 测试集说明

### 7.1 基础测试 (Basic Tests)

当前 `--basic` 默认包含 **26** 个测试；RoCC 的 3 个专项测试默认关闭，需要 `--enable-rocc` 才会纳入回归。`test_smt.s` 仍可通过 `--tests test_smt.s` 单独运行，但不在当前默认 basic 集合内。

| 测试文件 | 覆盖内容 | 验证方式 |
|---------|---------|---------|
| `test1.s` | ADD/SUB/AND/OR/XOR/LW/SW | 寄存器 x1-x9 + DRAM 黄金值 |
| `test2.S` | Scoreboard RAW 冒险链 (ADD→SUB→LW→SW→LW) | 寄存器 x1-x9 + DRAM 黄金值 |
| `test_rv32i_full.s` | **RV32I 全部 47 条指令** (详见下表) | 9 个 DRAM 检查点 + TUBE 标记 |
| `test_store_buffer_simple.s` | Store Buffer 基础功能测试 | 存储-加载验证 |
| `test_store_buffer_commit.s` | Store Buffer 提交边界测试 | ROB 提交时序验证 |
| `test_store_buffer_forwarding.s` | Store-Load 转发测试 | 数据前递验证 |
| `test_store_buffer_hazard.s` | Store Buffer 冒险检测测试 | RAW/WAW 冒险处理 |
| `test_commit_flush_store.s` | Flush 时 Store 提交测试 | 投机执行回滚验证 |
| `test_store_buffer_wraparound.s` | Store Buffer 环回与重复覆盖测试 | head/tail 回卷、后写覆盖前写 |
| `test_store_buffer_subword_merge.s` | 子字节/半字写合并测试 | byte/halfword lane 对齐与读回 |
| `test_store_buffer_flush_preserve.s` | trap/flush 后已提交 store 保留测试 | 已提交项继续排空，未提交项回滚 |
| `test_store_buffer_latest_write_wins.s` | 同地址连续覆盖测试 | latest-write-wins、partial/full store 叠加 |
| `test_store_buffer_stream_multiline.s` | 跨多 cache line 连续写压力测试 | 长串流 store 提交与整段回读 |
| `test_l2_icache_refill.s` | ★ L2 I-Cache 填充测试 | 指令缓存缺失处理 |
| `test_l2_i_d_arbiter.s` | ★ L2 I/D 仲裁器测试 | 指令/数据仲裁验证 |
| `test_l2_mmio_bypass.s` | ★ L2 MMIO 旁路测试 | 非缓存内存映射访问 |
| `test_l2_subword_store_hit.s` | ★ L2 子字节写命中测试 | byte lane 更新与相邻字隔离 |
| `test_l2_line_boundary_rw.s` | ★ L2 行边界读写测试 | 相邻 cache line 边界稳定性 |
| `test_l2_mmio_cache_isolation.s` | ★ L2/MMIO 隔离测试 | cacheable RAM 与 MMIO 流量隔离 |
| `test_l2_mmio_ping_pong.s` | ★ L2/MMIO 交错压力测试 | cacheable 数据在 CLINT/PLIC 交错访问下保持稳定 |
| `test_csr_mret_smoke.s` | ★ CSR/MRET 基础测试 | CSR 读写、MRET 指令 |
| `test_clint_timer_interrupt.s` | ★ CLINT 定时器中断 | 定时器中断 (mcause=0x80000007) |
| `test_plic_external_interrupt.s` | ★ PLIC 外部中断 | 外部中断 (mcause=0x8000000B) |
| `test_interrupt_mask_mret.s` | ★ 中断掩码/MRET | 中断使能/屏蔽/MRET 返回 |
| `test_clint_timer_rearm.s` | ★ CLINT 定时器重装测试 | 多次 mtimecmp 触发与重新 armed |
| `test_plic_retrigger.s` | ★ PLIC pending/重触发测试 | threshold mask、pending 保留与再次投递 |

**注：** `test_rv32i_full.s` 包含 17 条分支指令，用于验证分支预测单元 (BPU)。

### 7.2 riscv-tests (经典测试集)

来自 [riscv-tests](https://github.com/riscv-software-src/riscv-tests)，包含 RV32I 和 RV32M 基础指令测试：

| 类别 | 测试数量 | 说明 |
|------|---------|------|
| rv32ui | 42 个 | RV32I 整数指令测试 (add, sub, and, or, branch, load/store 等) |
| rv32um | 8 个 | RV32M 乘除法指令测试 (mul, mulh, div, rem 等) |

**特点：**
- 自动下载，无需手动配置
- 适配 TUBE 测试结果输出机制
- 当前通过率：50/50 (PASS)
  - 46个基础测试全部通过
  - 4个预期失败测试（fence_i / ld_st / ma_data / st_ld）已通过 march 配置和测试框架更新修复

### 7.3 riscv-arch-test (官方架构测试集)

来自 [riscv-arch-test](https://github.com/riscv/riscv-arch-test)，官方 RISC-V 架构合规性测试：

| 类别 | 测试数量 | 说明 |
|------|---------|------|
| rv32i | 39 个 | RV32I 完整架构测试 (add, and, auipc, branch, jal, load/store, shift 等) |
| rv32im | 8 个 | RV32M 乘除法测试 (mul, mulh, div, rem 等) |

**特点：**
- 官方架构认证测试，覆盖更全面
- 自动下载，无需手动配置
- 当前通过率：47/47 (100%)

### 7.4 Store Buffer 测试集

专用测试验证乱序执行中的存储缓冲区功能：

| 测试文件 | 测试场景 | 验证要点 |
|---------|---------|---------|
| `test_store_buffer_simple.s` | 基础存储缓冲 | Store 缓冲、内存写入、数据一致性 |
| `test_store_buffer_commit.s` | 提交边界 | ROB 提交时序、非投机 Store 提交 |
| `test_store_buffer_forwarding.s` | Store-Load 转发 | 同地址 Store-Load 数据前递 |
| `test_store_buffer_hazard.s` | 冒险检测 | RAW/WAW 冒险识别与处理 |
| `test_commit_flush_store.s` | Flush 回滚 | 投机执行失败时 Store 缓冲区清理 |
| `test_store_buffer_wraparound.s` | 队列环回 | 超过队列深度后的 head/tail 回卷正确性 |
| `test_store_buffer_subword_merge.s` | 子字节写合并 | `sb/sh` 地址偏移、lane 合并与符号/零扩展 |
| `test_store_buffer_flush_preserve.s` | flush 保留已提交项 | 已 commit store 不被 trap/global flush 误删 |
| `test_store_buffer_latest_write_wins.s` | 同地址覆盖 | newer store 必须覆盖 older store 的可见值 |
| `test_store_buffer_stream_multiline.s` | 长串流写入 | 跨多行连续 store、排空与整段读回 |

**运行方式：**
```powershell
python verification/run_all_tests.py --basic  # 自动包含所有 Store Buffer 测试
```

### 7.5 分支预测测试

分支预测单元 (BPU) 测试通过 `test_rv32i_full.s` 中的分支指令进行验证：

| 分支类型 | 指令 | 测试场景 |
|---------|------|---------|
| 条件分支 | BEQ, BNE, BLT, BGE, BLTU, BGEU | 6 条指令，覆盖相等、大小、无符号比较 |
| 无条件跳转 | JAL, JALR | 函数调用、间接跳转 |

**BPU 配置：**
- 256-entry PHT (Pattern History Table)
- 2-bit 饱和计数器
- 直接映射 BTB (Branch Target Buffer)
- 每线程独立索引 (XOR-fold)

**运行方式：**
```powershell
python verification/run_all_tests.py --basic  # test_rv32i_full.s 包含 17 条分支指令
```

### 7.6 test_rv32i_full.s 覆盖的指令 (37 条 + NOP)

| 类别 | 指令 | 数量 |
|------|------|------|
| R-type | ADD SUB SLL SLT SLTU XOR SRL SRA OR AND | 10 |
| I-type ALU | ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI | 9 |
| Load | LB LH LW LBU LHU | 5 |
| Store | SB SH SW | 3 |
| Branch | BEQ BNE BLT BGE BLTU BGEU | 6 |
| U-type | LUI AUIPC | 2 |
| J-type | JAL JALR | 2 |
| 其他 | NOP (ADDI x0,x0,0), FENCE*, ECALL*, EBREAK* | — |

> *FENCE/ECALL/EBREAK 在当前微架构中为 NOP 处理，不影响功能正确性。

---

## 8. 架构概述

| 特性 | 当前架构 (adam_riscv.v) |
|------|-------------------|
| 流水线 | IF→FB→DualDec→SB→RO→EX(×2)→MEM→WB |
| 发射宽度 | 单发射 | **双发射** |
| RS 深度 | 8 entry | **16 entry** |
| 执行单元 | 1× ALU | **2× ALU + 1× MUL** |
| 分支预测 | 无 | **256-entry Bimodal + BTB** |
| 前递网络 | 简单 forwarding | **3 源 bypass (pipe0/pipe1/mem)** |
| 缓存 | 无 (直接 SRAM) | **4-way L1 DCache + AXI4** |
| 虚拟内存 | 无 | **Sv32 MMU + hardware PTW** |
| AI 加速 | 无 | **RoCC GEMM + VPU** |
| CSR | 无 | **Machine-mode 完整支持** |
| L2 缓存 | 无 | **仿真: 8KB 4-way 缓存；FPGA: L2 Passthrough 直连 RAM** |
| 中断 | 无 | **CLINT + PLIC，支持定时器/外部中断（已上板验证）** |

---

## 9. 波形调试建议

### 关键信号

```
is_push, sb_rs_full, ro_issue_valid, ro_issue_sb_tag, ro_issue_fu
wb_sb_tag, wb_fu, w_regs_en, w_regs_addr, wb_tid
fetch_tid, if_tid, ro_tid, ex_tid, wb_tid
```

### 管线关键信号

```
# 前端
if_valid, fb_push_ready, fb_pop0_valid, fb_pop1_valid
dec0_valid, dec1_valid, sb_disp_stall

# 发射
iss0_valid, iss0_fu, iss0_tag, iss1_valid, iss1_fu, iss1_tag

# 执行
p0_ex_valid, p0_ex_result, pipe0_br_ctrl, pipe0_br_addr
p1_alu_valid, p1_mem_req_valid, p1_mul_valid

# 写回
wb0_valid, wb0_tag, wb1_valid, wb1_tag
w_regs_en, w_regs_addr, w_regs_data
```

---

## 10. ROM 布局约定

链接脚本 `rom/harvard_link.ld`:
- `.text` 起始地址: `0x00000000`
- `.data/.sdata` 起始地址: `0x00001000`
- TUBE 地址: `0x13000000` (写入 0x04 表示测试结束)

---

## 11. 后续路线图

| **优先级** | **任务**                                                 | **说明**                                                     |
|--------|------|------|
| ~~P0~~     | ~~仿真调试~~                                      | ✅ 已完成 (test1/test2/smt/rv32i_full 全部通过)               |
| ~~P1~~     | ~~Store Buffer~~                                         | ✅ 已完成 (5个专用测试通过)                                   |
| ~~P1~~     | ~~L1 ICache~~                                            | ✅ 已完成 (非阻塞 ICache 集成到 inst_memory)                  |
| ~~P2~~     | ~~L2 Cache~~                                             | ✅ 已完成 (8KB 4路统一缓存 + 轮询仲裁器)                      |
| ~~P2~~     | ~~中断控制器~~                                           | ✅ 已完成 (CLINT + PLIC，7个中断测试通过)                     |
| ~~P3~~     | ~~FPGA 综合~~                                            | ✅ 已完成 (AX7203 板级适配 + 时序收敛)                        |
| ~~P3~~     | ~~UART 串口调试~~                                        | ✅ 已完成 (115200 baud, 启动消息验证)                         |
| **P3**     | **Benchmark 体系固化（CoreMark / Dhrystone / Embench）** | 🔄 Dhrystone 已完成板级镜像构建和数据内存初始化基础设施（`$readmemh` + `data_word.hex`），板测可启动但计算结果异常（见 §13.10）。CoreMark 待测。 |
| **P3**     | **CoreMark 上板跑分与参数扫点**                          | 完成 CoreMark 在 AX7203 的 BRAM-first 运行闭环，系统扫点 `-O2/-O3/-Ofast/LTO`、分支预测开关、L1/L2 参数、乘法器映射策略，优先拿到“稳定可复现”的官方展示成绩。 |
| **P3**     | **硬件性能计数器 (HPM/PMC) 完善**                        | 除 mcycle/minstret 外，新增 `branch_mispredict`、`icache_miss`、`dcache_miss`、`l2_miss`、`sb_stall`、`issue_bubble`、`rocc_busy_cycle` 等事件计数器，给性能调优提供硬件证据链。 |
| **P3**     | **资源封顶版竞赛 Bitstream**                             | 这是**目标竞赛配置**而非当前实际上板配置。目标是冻结竞赛主核结构：保持双发射、RS=16、L2=8KB、RoCC Scratchpad=4KB，不再盲目扩窗口/扩缓存。形成 `benchmark bitstream` 与 `demo bitstream` 两套配置，避免功能堆叠导致 AX7203 资源和时序双失控。 |
| **P4**     | **轻量前端优化（只做资源友好升级）**                     | 在不明显增加 BRAM/LUT 的前提下，将现有 Bimodal 升级为轻量 Gshare / 小型 Tournament 版本；严禁引入 TAGE/Perceptron 这类高成本预测器。目标是用极小代价提升 CoreMark 与分支密集程序的实际 IPC。 |
| **P4**     | **Load/Store 路径微优化**                                | 聚焦影响跑分最明显的路径：Store-Load 转发时序、Cache refill 停顿、提交边界气泡、MMIO 访问旁路。只做“小改动高收益”的微优化，不引入更大 ROB / 更深 LSQ。 |
| ~~P4~~     | ~~**DDR3 支持（mem_subsys→DDR3 直连）**~~                  | ✅ 已完成。MIG 7-Series v4.2 已集成，`ddr3_mem_port.v` CDC 桥接模块实现 32b↔256b AXI lane steering + toggle-flag 异步 CDC。板测验证：`CAL=1, W=DEADBEEF R=DEADBEEF, DDR3 PASS`（含 walking-ones 测试）。修复 3 个 CDC Bug（#10 请求丢失、#11 wstrb 重叠、#12 响应数据时序——根因）。 |
| **P4**     | **RoCC DMA 软件栈完善**                                  | 补齐 C 语言接口、内联汇编封装、scratchpad 分配器、blocking/non-blocking DMA API，形成可复用的软件层。让评委看到“不是单个硬件指令能跑，而是软件可调用、系统可集成”。 |
| **P4**     | **应用 Demo A：端侧 AI / TinyML 加速**                   | 主打场景。使用现有 8×8 INT8 GEMM + SIMD，完成小型 MLP / 卷积核 / 关键词分类 / 矩阵推理 Demo。必须给出 `纯 CPU` vs `RoCC` 的延迟、吞吐和能效对比，是最容易形成“杀手锏”的展示方向。 |
| **P5**     | **应用 Demo B：轻量数据流处理**                          | 结合 UART / DDR3 / PCIe / 千兆网口中的一种输入路径，完成 `数据搬运 + 规则计算 + 加速处理 + 输出` 的闭环。例如包头过滤、流式 checksum、工业传感器数据预处理等，强调处理器不仅能跑分，还能接近真实系统。 |
| **P5**     | **应用 Demo C：轻量图像前处理（可选）**                  | 若时序与资源余量允许，再做 Sobel / 阈值化 / Resize / 卷积前处理等轻量图像任务。注意这是“可选加分项”，不应压过主线的 CoreMark + AI Demo。 |
| **P5**     | **评测材料工程化**                                       | 输出统一展示材料：性能表、资源利用率表、时钟频率、测试脚本、上板录像、波形截图、RoCC 加速比图、架构亮点图。将“功能完成”升级为“证据完备”。 |
| ~~P5~~     | ~~**资源/时序最终压榨**~~                                    | ✅ 已完成。(1) `iss0_is_rocc` 反馈环切断 + `entry_eligible_r` 候选谓词寄存化 + store tree 树化（§13.15），**Fmax 从 20 MHz 提升至 30 MHz（+50%）**。30 MHz bitstream 生成并通过时序。(2) `branch_in_flight` flush 安全修复。仿真 26/26 PASS。 |
| **P6**     | **RTOS / OpenSBI 适配（中期）**                          | 在 benchmark 与 Demo 已经稳定拿分后，再向 RT-Thread / OpenSBI 推进。重点展示“从裸机核到系统软件”的延展性，而非比赛前期就把大量时间压在复杂系统移植上。 |
| **P6**     | **Linux / RV32A / 外设全面化（长期）**                   | 作为长期路线保留。Linux 启动、RV32A、完整 DDR3 外存体系、重型外设联动都很有价值，但更适合放在比赛后续迭代，而不是赛前核心里程碑。 |

---

## 12. 常见问题 (FAQ)

**Q1: 脚本提示找不到工具？**
确认 PATH 包含工具链路径 (参见 §5.2)。

**Q2: test_rv32i_full.s FAIL？**
检查 `out_iverilog/logs/test_rv32i_full.log`，确认 DRAM 黄金值是否匹配。用 gtkwave 打开对应 VCD 波形调试。

**Q3: 为什么使用 stage_mem / data_memory？**
当前仿真使用 `stage_mem` + `data_memory` (SRAM 行为模型) 确保功能正确。`l1_dcache_nb` 和 `mmu_sv32` 已就位，待切换到 AXI4 仿真环境后启用。

---

## 13. FPGA 支持 (AX7203)

### 13.1 硬件支持

| 特性 | 状态 | 说明 |
|------|------|------|
| **目标板** | ✅ | ALINX AX7203 (XC7A200T-2FBG484I) |
| **时钟** | ✅ | 200MHz 差分时钟输入 (R4/T4) |
| **复位** | ✅ | 按键复位 T6 (active-low) |
| **BRAM 启动** | ✅ | 32KB/64KB BRAM 初始化 (COE) |
| **UART 调试** | ✅ | 115200 baud, TX=N15, RX=P20 |
| **JTAG 编程** | ✅ | Vivado Tcl 脚本 + DONE/EOS 校验 |
| **QSPI Flash** | ✅ | 16MB Flash 持久化启动 |
| **DDR3** | ✅ | 板载 2×MT41K256M16HA-125 (1GB, 32-bit)，MIG 7-Series v4.2 已集成，CDC 桥接模块 `ddr3_mem_port.v` 已调通，板测读写验证通过 |
| **当前固定配置** | ✅ | `FPGA_MODE=1`, `ENABLE_MEM_SUBSYS=1`, `ENABLE_ROCC_ACCEL=0`, `SMT_MODE=0` |
| **mem_subsys 上板** | ✅ | 完整 mem_subsys (L2 Passthrough + CLINT + PLIC + UART)，板测 `UART DIAG PASS` |

**引脚分配 (来自官方资源文档):**
- 时钟: SYS_CLK_P=R4, SYS_CLK_N=T4
- 复位: RESET_N=T6
- UART: UART1_TXD=N15 (FPGA→PC), UART1_RXD=P20 (PC→FPGA)
- LED: 核心板 LED1=W5, 扩展板 LED1-4=B13/C13/D14/D15

### 13.2 FPGA 目录结构

```
fpga/
├─ board_manifest_ax7203.md         # AX7203 板级规格
├─ observability_contract_ax7203.md # UART/LED 输出规范
├─ resource.md                      # ★ 官方硬件资源文档 (完整引脚表)
├─ rtl/
│  ├─ adam_riscv_ax7203_top.v                 # 默认板级 top（CPU UART 板测入口）
│  ├─ adam_riscv_ax7203_status_top.v          # 板级状态诊断 top
│  ├─ adam_riscv_ax7203_issue_probe_top.v     # issue 路径诊断 top
│  ├─ adam_riscv_ax7203_branch_probe_top.v    # branch 路径诊断 top
│  ├─ adam_riscv_ax7203_main_bridge_probe_top.v # 主桥接 UART 诊断 top
│  ├─ adam_riscv_ax7203_io_smoke_top.v        # 纯板级 IO smoke top
│  ├─ uart_rx_monitor.v                       # 板侧 UART 帧监测器
│  ├─ uart_status_beacon.v                    # 状态信标
│  ├─ uart_issue_probe_beacon.v               # issue probe 信标
│  ├─ uart_branch_probe_beacon.v              # branch probe 信标
│  └─ uart_main_bridge_beacon.v               # 主桥接 probe 信标
├─ constraints/
│  ├─ ax7203_base.xdc               # 时钟/复位约束 (T6复位, R4/T4时钟)
│  └─ ax7203_uart_led.xdc           # UART/LED 约束 (N15/P20, W5/B13等)
├─ ip/
│  └─ create_clk_wiz_ax7203.tcl     # 时钟向导 IP 生成
├─ bram_init/
│  ├─ create_bram_ip.tcl            # BRAM IP 生成
│  ├─ inst_mem.coe                  # 指令存储器初始化
│  └─ data_mem.coe                  # 数据存储器初始化
├─ scripts/
│  ├─ generate_coe.py               # COE 文件生成脚本
│  ├─ build_rom_image.py            # 板级 profile ROM 镜像构建
│  ├─ capture_uart_once.ps1         # 单次串口收发/抓取脚本
│  └─ run_board_feedback.py         # 默认端到端板测入口
├─ flow_common.tcl                  # ★ Vivado 批处理公共辅助
├─ prepare_ax7203_synth.tcl         # ★ 综合前准备脚本
├─ run_ax7203_synth.tcl             # ★ 仅综合脚本 (默认 15 分钟超时)
├─ build_ax7203_bitstream.tcl       # ★ 综合实现脚本
├─ create_project_ax7203.tcl        # ★ 创建工程脚本
├─ check_jtag.tcl                   # ★ JTAG 链探测脚本
├─ program_ax7203_jtag.tcl          # ★ JTAG 下载脚本
├─ program_ax7203_flash.tcl         # QSPI Flash 烧录脚本
└─ reboot_ax7203_after_flash.tcl    # Flash 烧录后重启脚本
```

### 13.3 快速开始 (FPGA)

```powershell
# 1. 先跑仿真 gate
python verification/run_all_tests.py --basic

# 2. 单 profile 端到端板测（仿真 -> 建工程 -> <=15 分钟综合 -> bitstream -> JTAG -> 串口抓取）
python fpga/scripts/run_board_feedback.py --profile core_diag --port COM5 --capture-seconds 4 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0

# 3. 完整自动调试闭环（basic -> core_diag -> uart_echo，失败时自动切诊断 profile）
python fpga/scripts/run_fpga_autodebug.py --port COM5 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0
```

**当前状态**: `RS=16 / FetchBuffer=16 / core_clk=10MHz` 这条流程已经在 AX7203 上闭环验证
- 波特率: 115200
- 数据位: 8, 停止位: 1, 无校验
- 流控: 无
- `python verification/run_all_tests.py --basic`：`26/26 PASS`
- `python fpga/scripts/run_board_feedback.py --profile core_diag --port COM5 --capture-seconds 4 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0`：闭环通过
- `python fpga/scripts/run_board_feedback.py --profile uart_echo --port COM5 --capture-seconds 4 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0`：闭环通过
- `python fpga/scripts/run_fpga_autodebug.py --port COM5 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0`：主验收双通过
- 最近一次 `core_diag` 板测 `BuildID=0x69CFB1B5`
- 最近一次 `uart_echo` 板测 `BuildID=0x69CFB4E6`
- `synth_design` 实测约 `6.05` 分钟，满足 15 分钟门限
- bitstream 生成通过，时序满足，`WNS=0.359ns` / `WHS=0.084ns`
- `program_ax7203_jtag.tcl` 已完成 `BuildID` 回读校验，`DONE=1 / EOS=1`
- `COM5` 串口已稳定收到重复的 `UART DIAG PASS`，并且 `uart_echo` 已实测回显 `Z`
- WNS 经 Scoreboard 树优化后从 `+0.359ns` 提升至 `+0.543ns`（见 §13.8）
- WNS 经 reg_is_ro 流水线寄存器插入后，核心时钟域 WNS=`+0.383ns`（见 §13.13），关键路径从 119 级跨模块降至 111 级 Scoreboard 内部
- WNS 经 oldest_store 树化后，**Fmax 从 13 MHz 提升至 20 MHz**（见 §13.14）。15 MHz WNS=+0.928ns，20 MHz WNS=+0.326ns
- WNS 经 entry_eligible_r + store tree + iss0_is_rocc 优化后，**Fmax 从 20 MHz 提升至 30 MHz**（见 §13.15）。30 MHz post-impl WNS=+0.087ns

**常用底层脚本**

```powershell
# 仅重建当前 profile 的 ROM 镜像
python fpga/scripts/build_rom_image.py --asm rom/test_fpga_uart_board_diag_gap.s

# 手动分步执行 Vivado 流程
vivado -mode batch -source fpga/create_project_ax7203.tcl
vivado -mode batch -source fpga/run_ax7203_synth.tcl
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl
vivado -mode batch -source fpga/program_ax7203_jtag.tcl
```

**`FPGA_MODE` 仿真 gate 的实际入口**

`run_board_feedback.py` 在进入 Vivado 之前，会先用一套固定的 `FPGA_MODE` 仿真 profile 做 gate，编译开关固定为：

- `-DFPGA_MODE=1`
- `-DENABLE_MEM_SUBSYS=0`
- `-DENABLE_ROCC_ACCEL=0`
- `-DSMT_MODE=0`
- `-DFPGA_SCOREBOARD_RS_DEPTH=16`
- `-DFPGA_SCOREBOARD_RS_IDX_W=4`
- `-DFPGA_FETCH_BUFFER_DEPTH=16`
- `-DFPGA_CLK_WIZ_HALF_DIV=10`
- `-DFPGA_UART_CLK_DIV=87`

当前常用 profile 如下：

| Profile | 顶层 Top | Testbench | 默认 ROM | 用途 |
|------|------|------|------|------|
| `core_diag` | `adam_riscv_ax7203_top` | `tb_ax7203_top_smoke.sv` | `rom/test_fpga_uart_board_diag_gap.s` | 默认 CPU 板级 smoke |
| `uart_echo` | `adam_riscv_ax7203_top` | `tb_ax7203_uart_echo_smoke.sv` | `rom/test_fpga_uart_echo.s` | MMIO UART 回环验证 |
| `core_status` | `adam_riscv_ax7203_status_top` | `tb_ax7203_status_top_smoke.sv` | `rom/test_fpga_uart_board_diag_pollsafe.s` | 状态导出诊断 |
| `issue_probe` | `adam_riscv_ax7203_issue_probe_top` | `tb_ax7203_issue_probe_smoke.sv` | `rom/test_fpga_uart_board_diag_pollsafe.s` | issue/wakeup 诊断 |
| `branch_probe` | `adam_riscv_ax7203_branch_probe_top` | `tb_ax7203_branch_probe_smoke.sv` | `rom/test_fpga_uart_board_diag_pollsafe.s` | branch 链路诊断 |
| `main_bridge_probe` | `adam_riscv_ax7203_main_bridge_probe_top` | `tb_ax7203_main_bridge_probe_smoke.sv` | `rom/test_fpga_uart_board_diag.s` | 主 UART bridge 观测 |
| `io_smoke` | `adam_riscv_ax7203_io_smoke_top` | `tb_ax7203_io_smoke.sv` | 无 | 纯板级 IO 通路 smoke |

**`run_board_feedback.py` 的固定顺序**

1. 根据 profile 重建板级 ROM 镜像
2. 用对应的 `Top + Testbench` 做 `FPGA_MODE` 顶层仿真
3. 创建 Vivado 工程
4. 15 分钟内综合
5. 生成 bitstream
6. JTAG 下载并回读 `BuildID`
7. 串口抓取或串口回环校验

### 13.4 当前固定综合配置（2026-04-07）

当前 FPGA 配置已升级为**完整 mem_subsys 路径**（L2 Passthrough + CLINT + PLIC + UART），在 AX7203 上板验证通过（`UART DIAG PASS`）。`legacy_mem_subsys` 仍作为 `ifdef` 保护的 fallback（`ENABLE_MEM_SUBSYS=0` 可切回）。

| 开关 | 当前值 | 说明 |
|------|------|------|
| `FPGA_MODE` | `1` | 启用 AX7203 顶层时钟/复位/板级接口路径 |
| `ENABLE_MEM_SUBSYS` | `1` | ✅ 综合完整 `mem_subsys`（L2 Passthrough + CLINT + PLIC + UART） |
| `L2_PASSTHROUGH` | `1` (自动) | 当 `ENABLE_MEM_SUBSYS=1` 时 TCL 自动追加，绕过 L2 缓存数组直连片上 RAM |
| `ENABLE_ROCC_ACCEL` | `0` | 默认不综合 RoCC 加速器 |
| `ENABLE_DDR3` | `1` | ✅ 综合 MIG DDR3 控制器 + `ddr3_mem_port` CDC 桥接 |
| `SMT_MODE` | `0` | 当前固定为单线程 bring-up 配置 |
| `AX7203_CORE_CLK_MHZ` | `30.0` | entry_eligible_r + store tree + iss0_is_rocc 优化后收敛至 30MHz core clock（之前为 20MHz） |
| `AX7203_UART_CLK_DIV` | `87` | 保持 core 内 MMIO UART 为 `115200 8N1` |
| `AX7203_SYNTH_TIMEOUT_MIN` | `30` | mem_subsys 构建推荐 30 分钟超时 |
| `AX7203_MAX_THREADS` / `AX7203_SYNTH_JOBS` | `1 / 1` | 避免 Vivado 综合阶段偶发 `EXCEPTION_ACCESS_VIOLATION` |

**当前实际上板的关键微架构参数**

| 参数 | 当前上板值 | 目标竞赛值 | 说明 |
|------|------|------|------|
| 发射宽度 | 2 | 2 | 当前仍是双发射 core |
| `scoreboard` RS 深度 | `16` | `16` | 已在当前 `FPGA_MODE` 上恢复到目标深度，稳定板测依赖 `core_clk=10MHz` |
| Fetch Buffer 深度 | `16` | `16` | 已在当前 `FPGA_MODE` 上恢复到目标深度 |
| L1 ICache | `2KB, 1-way, 32B line` | 待后续冻结 | 当前 `inst_memory` 内部仍启用轻量指令缓存 |
| L1 DCache | `关闭` | L1→DDR3 | AXI4 端口已定义，计划直连 DDR3 MIG（跳过 L2） |
| DDR3 | **✅ 已启用** | ✅ | MIG 7-Series v4.2 + `ddr3_mem_port` CDC 桥接，板测读写验证通过 |
| L2 Cache | **Passthrough** | 不保留 | `L2_PASSTHROUGH` 绕过缓存数组，直连片上 RAM（81 LUTs） |
| mem_subsys 共享 RAM | `16KB, LUTRAM` | DDR3 外存 | 4096×32-bit `$readmemh` 初始化，指令+数据共享 |
| CLINT | ✅ 已启用 | ✅ | 64-bit mtime/mtimecmp，定时器中断 (176 LUTs) |
| PLIC | ✅ 已启用 | ✅ | 优先级/使能/阈值/Claim-Complete (93 LUTs) |
| UART (mem_subsys) | ✅ 已启用 | ✅ | TXDATA/STATUS/RXDATA/CTRL 完整寄存器 |
| RoCC Scratchpad | `关闭` | `4KB` | 当前默认不综合 RoCC |
| SMT | `关闭` | 可选 | 当前上板固定单线程 |

**当前 `mem_subsys` 配置（Phase 1: 片上 RAM）**

- 共享 RAM：`4096×32-bit = 16KB` LUTRAM，指令和数据共享同一块 `ram[]`
- 地址窗口：`0x0000_0000 - 0x0000_3FFF`（可缓存区域）
- L2 Cache：`L2_PASSTHROUGH` 模式 — 绕过 tag/data 数组，3-state FSM (PT_IDLE→PT_READ→PT_WRITE)，2-3 cycle 直连 RAM
- L2 Arbiter：3 主设备优先级仲裁 (M0=I-side, M1=D-side, M2=RoCC DMA)
- CLINT：64-bit mtime/mtimecmp，定时器中断
- PLIC：优先级/使能/阈值/Claim-Complete
- UART MMIO：TXDATA(0x1300_0010) / STATUS(0x1300_0014) / RXDATA(0x1300_0018) / CTRL(0x1300_001C)
- DDR3 Status MMIO：DDR3_STATUS(0x1300_0020) — 返回 `{31'b0, init_calib_complete}`
- TUBE：0x1300_0000（测试完成标记）
- RAM 初始化：`$readmemh("mem_subsys_ram.hex", ram)` — 由 `merge_hex_for_mem_subsys.py` 合并 inst.hex + data.hex 生成
- Vivado 构建时 `create_project_ax7203.tcl` 自动调用 merge_hex

> `legacy_mem_subsys` 仍保留为 `ifdef` 保护的 fallback（`ENABLE_MEM_SUBSYS=0` 可切回）。

**当前综合进去的主要部件**

- `adam_riscv` 主核：双发射前后端、`scoreboard`、`rob_lite`、两套寄存器堆、`decoder_dual`、`fetch_buffer`、`exec_pipe0/1`、`mul_unit`、`csr_unit`
- 访存路径：`lsu_shell + store_buffer`
- 取指路径：`stage_if + bimodal BPU + inst_memory + L2 arbiter M0`
- 完整内存子系统：`mem_subsys`（L2 Passthrough + `l2_arbiter` + `clint` + `plic` + UART TX/RX）
- 板级逻辑：`clk_wiz_0`、`syn_rst`、`u_board_uart_tx`、`uart_rx_monitor`、LED/诊断 glue
- DDR3：`u_mig` (MIG 7-Series v4.2, AXI4 256-bit) + `u_ddr3_mem_port` (CDC 桥接, 32b↔256b lane steering)
- 默认板测 top：`adam_riscv_ax7203_top`
- 板级诊断 top：`adam_riscv_ax7203_status_top`、`adam_riscv_ax7203_issue_probe_top`、`adam_riscv_ax7203_branch_probe_top`、`adam_riscv_ax7203_main_bridge_probe_top`

**当前没有综合进去的部件**

- `l1_dcache_nb`（L1 DCache AXI4 端口已定义但未接入）
- `mmu_sv32`（Sv32 MMU 已定义但未接入）
- `RoCC accelerator`
- `SMT` 多线程模式

### 13.5 当前综合/实现资源（AX7203, 2026-04-07）

综合入口使用 `fpga/run_ax7203_synth.tcl`。mem_subsys 构建推荐 `AX7203_SYNTH_TIMEOUT_MIN=30`（`synth_design` 实测约 15.5 分钟）。当前稳定设置为 `AX7203_MAX_THREADS=1`、`AX7203_SYNTH_JOBS=1`。

**时序结果**

| 构建 | 频率 | WNS | WHS | 说明 |
|------|------|-----|-----|------|
| **oldest_store 树 + DDR3 (最新)** | **20 MHz** | **+0.326ns** | **+0.077ns** | ✅ oldest_store 树化，post-impl，**所有约束满足** |
| oldest_store 树 + DDR3 | 15 MHz | +0.928ns | — | ✅ 核心时钟域 WNS=+14.111ns，余量充裕 |
| **entry_eligible_r + store tree + iss0_is_rocc (最新)** | **30 MHz** | **+0.087ns** | **+0.072ns** | ✅ §13.15 优化后 post-impl，**Fmax 20→30 MHz (+50%)** |
| reg_is_ro + DDR3 (树优化前) | 10 MHz | +0.238ns | +0.058ns | reg_is_ro 流水线寄存器 + DDR3，核心时钟域 WNS=+0.383ns |
| DDR3 集成 (Phase 2, pre-reg_is_ro) | 10 MHz | +0.238ns | +0.059ns | MIG + ddr3_mem_port CDC 桥接 |
| **mem_subsys (Phase 1)** | 10 MHz | **+1.736ns** | **+0.119ns** | ✅ 完整 mem_subsys，L2 Passthrough |
| Dhrystone ROM (legacy) | 10 MHz | +0.543ns | +0.084ns | Scoreboard 分支/候选树优化后 |
| core_diag ROM (legacy) | 10 MHz | +0.359ns | +0.084ns | legacy 基线 |

> **最新**: entry_eligible_r 寄存化 + store tree + iss0_is_rocc bypass 优化后 Fmax 从 20 MHz 提升至 **30 MHz（+50%）**。30 MHz bitstream 生成，post-impl WNS=+0.087ns，WHS=+0.072ns。

> 以上 15/20 MHz 数据对应 `ENABLE_MEM_SUBSYS=1` + `ENABLE_DDR3=1` + `L2_PASSTHROUGH=1` 构建。

| 资源 | 使用量 | 可用量 | 利用率 |
|------|------|------|------|
| Slice LUTs | 54,767 | 133,800 | 40.93% |
| Slice Registers | ~34,000 | 269,200 | ~12.6% |
| LUT as Memory | 4,096 | 46,200 | 8.87% |
| RAMB18 | 0 | 730 | 0.00% |
| DSP48E1 | 4 | 740 | 0.54% |

> L2 Passthrough 将 L2 cache 从 184,905 LUTs 缩减至 81 LUTs。总 LUT 利用率 40.93%。

**主要层级资源分布（综合层级报告, mem_subsys）**

| 模块/层级 | Total LUTs | FFs | 备注 |
|------|------|------|------|
| `u_scoreboard` | 27,001 | 4,782 | 当前最大 LUT 消耗点（含 FPGA 树优化，见 §13.8） |
| `u_stage_if` | 6,604 | 18,932 | 含 `bpu_bimodal + inst_memory` |
| `gen_mem_subsys.u_mem_subsys` | 5,245 | 1,940 | 完整 mem_subsys（含 4,096 LUTRAM） |
| ├─ `u_l2_cache` | 81 | 116 | L2 Passthrough (3-state FSM) |
| ├─ `u_l2_arbiter` | 76 | 74 | 3 主设备仲裁器 |
| ├─ `u_clint` | 176 | 128 | 定时器中断控制器 |
| ├─ `u_plic` | 93 | 67 | 外部中断控制器 |
| ├─ `u_uart_tx` | 24 | 21 | mem_subsys 内 UART TX |
| └─ `u_uart_rx` | 36 | 32 | mem_subsys 内 UART RX |
| `u_regs_mt` | 3,313 | 1,984 | Pipe0/线程寄存器堆 |
| `u_regs_mt_p1` | 3,313 | 1,984 | Pipe1/线程寄存器堆 |
| `u_rob_lite` | 1,888 | 1,278 | 提交/回滚路径 |
| `u_lsu_shell` | 1,239 | 983 | 含 `store_buffer` |
| `u_board_uart_tx` | 30 | 25 | 板侧重新定时 UART 发送器 |
| `u_core_uart_monitor` | 36 | 35 | 板侧 UART 帧监测器 |

### 13.6 当前板测 Profile

默认板测入口由 `fpga/scripts/run_board_feedback.py` 统一管理。它会按固定顺序执行：

1. 顶层仿真
2. 创建 Vivado 工程
3. 15 分钟内综合
4. skip-opt bitstream 生成
5. JTAG 下载并回读 `BuildID`
6. COM 串口抓取

完整自动调试入口为 `fpga/scripts/run_fpga_autodebug.py`。它会按固定顺序执行：

1. `python verification/run_all_tests.py --basic`
2. `core_diag` 的完整板测流程
3. `uart_echo` 的完整板测流程
4. 只有主验收失败时，才自动切到 `core_status / issue_probe / branch_probe / main_bridge_probe`

**当前默认 profile**

| Profile | Top | 默认 ROM | 用途 |
|------|------|------|------|
| `core_diag` | `adam_riscv_ax7203_top` | `rom/test_fpga_uart_board_diag_gap.s` | 默认 CPU 板级 smoke，串口回传 `UART DIAG PASS` |
| `main_bridge_probe` | `adam_riscv_ax7203_main_bridge_probe_top` | `rom/test_fpga_uart_board_diag.s` | 证明主顶层内部 UART bridge 在真板上可观测 |
| `core_status` | `adam_riscv_ax7203_status_top` | `rom/test_fpga_uart_board_diag_pollsafe.s` | 导出 core ready / retire / tube / UART 等状态 |
| `issue_probe` | `adam_riscv_ax7203_issue_probe_top` | `rom/test_fpga_uart_board_diag_pollsafe.s` | 排查 issue / wakeup 相关卡死 |
| `branch_probe` | `adam_riscv_ax7203_branch_probe_top` | `rom/test_fpga_uart_board_diag_pollsafe.s` | 排查 branch pending / complete 链路 |
| `io_smoke` | `adam_riscv_ax7203_io_smoke_top` | 无 | 纯板级 IO / 串口通路 smoke |
| `uart_echo` | `adam_riscv_ax7203_top` | `rom/test_fpga_uart_echo.s` | MMIO UART 回环验证，PC 发 1 字节，CPU 读回后再回传 |

**当前 FPGA profile 下的 MMIO UART 寄存器**

| 地址 | 名称 | 访问 | 说明 |
|------|------|------|------|
| `0x1300_0010` | `UART_TXDATA_ADDR` | `W` | 发送 1 字节；当前轻量实现为“正在发送 + 1 字节 pending” |
| `0x1300_0014` | `UART_STATUS_ADDR` | `R` | `bit0=TX busy`, `bit1=TX ready`, `bit2=RX valid`, `bit3=RX overrun`, `bit4=RX frame error`, `bit5=RX enable`, `bit6=TX enable` |
| `0x1300_0018` | `UART_RXDATA_ADDR` | `R` | 读取最近收到的 1 字节，同时弹出 `RX valid` |
| `0x1300_001C` | `UART_CTRL_ADDR` | `R/W` | `bit0=TX enable`, `bit1=RX enable`, `bit2=clear RX overrun`, `bit3=clear RX frame error`, `bit4=flush RX byte` |
| `0x1300_0020` | `DDR3_STATUS_ADDR` | `R` | `bit0=init_calib_complete`（MIG DDR3 校准完成标志） |

**最近一次板测结果**

- `run_fpga_autodebug.py --port COM5 --rs-depth 16 --fetch-buffer-depth 16 --core-clk-mhz 10.0`：通过，`FailedStage: none`
- `core_diag`：`BuildID=0x69CFB1B5`，`UartBytes=75`，抓包内容为重复的 `UART DIAG PASS`
- `uart_echo`：`BuildID=0x69CFB4E6`，`UartBytes=1`，串口抓包内容为单字节回显 `Z`
- `main_bridge_probe` 仍保留为失败时自动触发的诊断 profile，用来证明“CPU -> core_uart -> 板侧 bridge -> PC 串口”这条链在真板上确实打通
- 默认 `core_diag` 之所以使用 `test_fpga_uart_board_diag_gap.s`，是为了在板级串口抓取上保留明显行间空闲，避免过于紧凑的连续流影响可观测性

### 13.7 CoreMark 性能测试

```powershell
cd benchmarks/coremark
make -f Makefile.ax7203
cp build_ax7203/coremark_ax7203.elf ../../rom/
```

### 13.8 Scoreboard FPGA 树优化（2026-04）

为降低 Scoreboard 在 FPGA 上的关键路径深度，引入了 `ifdef FPGA_MODE` 保护的树结构优化。所有变更仅在 `FPGA_MODE` 定义时生效，仿真路径完全不变（验证：26/26 basic + 50/50 riscv-tests 全通过）。

**优化内容**

| 优化 | 说明 | 影响 |
|------|------|------|
| WAKE_HOLD 缩减 | `WAKE_HOLD_CYCLES` 从 `2'd2` 降为 `2'd1`（仅 FPGA_MODE） | 减少唤醒延迟 |
| 分支查找树 | 16-entry 4 级锦标赛树替代线性扫描查找最旧未发射分支 | 关键路径从 O(N) 降为 O(log N) |
| 发射候选树 | `pick_older_fpga_cand` 函数，打包 `{valid, seq, idx}` 做 4 级比较 | 发射仲裁逻辑深度降低 |
| oldest_store 树 | 16-entry 4 级二叉树替代线性扫描查找每线程最旧 store（见 §13.14） | Scoreboard 内部 111→60 级，**Fmax 从 13→20 MHz** |
| iss0_is_rocc 反馈环切断 | FPGA_MODE 下 hardwire `iss0_is_rocc=0`，去掉 RoCC 门控（见 §13.15） | 消除 ~18ns 跨模块组合反馈 |
| entry_eligible 寄存化 | 候选过滤谓词预计算为寄存器，fpga_cand_l0 仅检查 1-bit + fu_busy（见 §13.15） | 消除 ~16ns 分支树+seq 比较链 |

**实现细节**

- `localparam FPGA_TREE_SLOTS = 16, CAND_W = 1 + 16 + RS_IDX_W = 21`
- 每个候选打包为 21-bit 向量 `{valid[1], seq[16], idx[4]}`
- 4 级 `always @(*)` 组合逻辑锦标赛：`l0(16→8) → l1(8→4) → l2(4→2) → l3(2→1) → l4(winner)`
- `pick_older_fpga_cand` 函数：比较两个候选的 valid 位和 seq 值，选择更旧的
- 分支树和发射候选树使用相同的基础设施

**时序改善**

| 指标 | 优化前（线性扫描） | 分支+候选树 | +oldest_store 树 | +entry_eligible_r (§13.15) | 变化 |
|------|--------|--------|--------|--------|------|
| WNS (10 MHz) | +0.359 ns | +0.543 ns | — | — | +0.184 ns |
| 15 MHz | -5.247 ns ❌ | — | **+0.928 ns ✅** | — | **+6.175 ns** |
| 20 MHz | -11.864 ns ❌ | — | **+0.326 ns ✅** | — | **+12.190 ns** |
| **30 MHz** | — | — | — | **+0.087 ns ✅** | **Fmax 20→30 MHz** |
| Post-impl 逻辑级数 | 111 级 | — | **60 级** | **42 级** | -62% |
| Post-impl 数据路径 | 71.7 ns | — | **36.6 ns** | **33.0 ns** | -54% |

> 分支+候选树将 WNS@10MHz 从 +0.359→+0.543ns。oldest_store 树进一步将 Scoreboard 内部逻辑级数从 111 降至 60，**使最大频率从 13 MHz 飞跃至 20 MHz（+54%）**。entry_eligible_r 寄存化 + iss0_is_rocc 反馈环切断进一步将逻辑级数从 60 降至 42，**Fmax 从 20 MHz 提升至 30 MHz（+50%）**。

### 13.9 关键路径分析

#### 13.9.1 oldest_store 树优化后（当前，2026-04-08）

在 reg_is_ro 流水线寄存器 + oldest_store 树化优化后，Scoreboard 内部关键路径从 111 级降至 60 级。当前 15 MHz 配置下的后实现关键路径：

```
路径深度:  60 个逻辑级别 (post-synthesis)
延迟:      36.603 ns (post-synthesis data path)
起点:      u_scoreboard/win_tid_reg[9]/C
终点:      u_scoreboard/win_ready_reg[9]/CE
```

**路径构成**

这仍是一条 **Scoreboard 内部** 的单周期组合路径，但由于 oldest_store 线性扫描被树结构替代，逻辑级数大幅降低：

1. **发射窗口候选筛选 → 就绪判定**（~60 级）: `win_tid_reg[9]` → 候选树 → 优先级仲裁 → `win_ready_reg[9]` 写使能
2. **树结构**: 4 级二叉 `pick_older_fpga_cand` 替代 16-entry 线性 for 循环

> **关键改善**: oldest_store 树将 Scoreboard 内部逻辑级数从 111 降至 60（-46%），数据路径从 99.4ns 降至 36.6ns（-63%）。
> 最大频率从 13 MHz 提升至 **20 MHz（+54%）**。

**Fmax 估算**: 数据路径 36.6ns + 时钟裕量 → 实测 Fmax ≈ 20 MHz（WNS=+0.326ns@50ns 周期）。

#### 13.9.1.1 reg_is_ro 优化后 / 树优化前（历史中间态）

```
路径深度:  111 个逻辑级别
延迟:      99.437 ns (post-implementation)
起点:      u_scoreboard/win_valid_reg[0]/C
终点:      u_scoreboard/reg_result_order_reg[0][18][10]/CE
逻辑延迟:  21.615 ns (21.7%)
布线延迟:  77.822 ns (78.3%)
```

> Fmax ≈ 10.04 MHz。瓶颈为 Scoreboard 内部 oldest_store 线性扫描。

#### 13.9.2 reg_is_ro 优化前（历史基线）

```
路径深度:  119 个逻辑级别
延迟:      ~74 ns (post-implementation)
起点:      u_scoreboard/win_tid_reg[0][0]_rep__0/C
终点:      u_exec_pipe1/alu_out_result_r_reg[29]/D
```

这是一条跨模块组合路径：Scoreboard 发射仲裁 → 寄存器堆读取 → ALU 运算。

**频率扫描结果汇总**

| 目标频率 | 优化前 (线性扫描) | reg_is_ro 后 | +oldest_store 树后 |
|----------|------|------|------|
| 10 MHz | +0.633 ns ✅ | +0.383 ns ✅ | ✅ |
| 12 MHz | +0.963 ns ✅ | — | ✅ |
| 13 MHz | +0.850 ns ✅ | — | ✅ |
| 15 MHz | -5.247 ns ❌ | — | **+0.928 ns ✅** |
| 20 MHz | -11.864 ns ❌ | — | **+0.326 ns ✅** |
| 25 MHz | -34.460 ns ❌ | — | ❌ (未测，余量不足) |

> **里程碑**: oldest_store 树化将最大频率从 13 MHz 提升至 **20 MHz（+54%）**。
> 20 MHz WNS 仅 +0.326ns，25 MHz 不可行。如需更高频率需进一步流水化 issue selection。

### 13.10 Dhrystone 板级测试（2026-04）

**板测基础设施**

为支持 C 语言 Benchmark 上板，新增以下基础设施：

| 组件 | 文件 | 说明 |
|------|------|------|
| 数据内存初始化 | `rtl/legacy_mem_subsys.v` | `ifdef FPGA_MODE` 下通过 `$readmemh("data_word.hex", data_mem)` 加载 `.rodata/.data` 段 |
| 字格式 HEX 转换 | `rom/data_word.hex` | 从字节格式 `data.hex` 转换为 32-bit word 格式，供 Vivado $readmemh 使用 |
| ROM 保护机制 | `fpga/flow_common.tcl` | `SKIP_ROM_BUILD` 环境变量，防止 Vivado 流程覆盖 Benchmark ROM |
| Benchmark 镜像构建 | `fpga/scripts/build_benchmark_image.py` | 统一的 Benchmark 编译→链接→HEX 生成工具 |

**构建与烧录流程**

```powershell
# 1. 构建 Dhrystone ROM 镜像
python fpga/scripts/build_benchmark_image.py --benchmark dhrystone --cpu-hz 10000000 --dhrystone-runs 1

# 2. 生成 data_word.hex（32-bit word 格式）
python -c "
lines = open('rom/data.hex').read().split('\n')
addr = 0; words = []
for l in lines:
    l = l.strip()
    if l.startswith('@'):
        addr = int(l[1:], 16)
        continue
    if not l: continue
    bytes_list = l.split()
    for b in bytes_list:
        words.append((addr, int(b, 16)))
        addr += 1
# pack into 32-bit words
word_dict = {}
for a, b in words:
    wa = (a // 4) * 4
    shift = (a % 4) * 8
    word_dict[wa] = word_dict.get(wa, 0) | (b << shift)
with open('rom/data_word.hex', 'w') as f:
    f.write('@00000000\n')
    max_wa = max(word_dict.keys()) if word_dict else 0
    for wa in range(0, max_wa + 4, 4):
        f.write(f'{word_dict.get(wa, 0):08X}\n')
"

# 3. 设置环境变量并运行 Vivado 流程
$env:SKIP_ROM_BUILD = "1"
$env:FORCE_COE_GEN = "1"
$env:AX7203_CORE_CLK_MHZ = "10.0"

vivado -mode batch -source fpga/create_project_ax7203.tcl
vivado -mode batch -source fpga/run_ax7203_synth.tcl
vivado -mode batch -source fpga/build_ax7203_bitstream.tcl

# 4. UART 先开、再烧录（ROM 输出在编程后立即开始）
Start-Job -ScriptBlock { powershell -File build/capture_uart_once.ps1 -Port COM5 -OutFile build/dhrystone_capture.txt -Seconds 60 }
vivado -mode batch -source fpga/program_ax7203_jtag.tcl
Wait-Job -Id (Get-Job | Select-Object -Last 1).Id -Timeout 90
```

**当前板测状态**

| 测试 | 状态 | 说明 |
|------|------|------|
| 板级 UART 通信 | ✅ | `UART DIAG PASS` 稳定输出 |
| Dhrystone 启动 | ✅ | 输出 Benchmark 头信息、版本号 |
| Dhrystone 循环执行 | ⚠️ | 1 次迭代可完成，5000 次迭代挂起 |
| Dhrystone 计算正确性 | ❌ | 整数结果全零、字符串截断、HZ=0000 |
| CoreMark | ⏳ | 待 Dhrystone 问题修复后测试 |

**已知问题**

Dhrystone 1 次迭代运行完成但计算结果错误：
- `HZ` 显示为 `0000`（应为 `10000000`）
- `Number_Of_Runs` 显示为 `0`（应为 `1`）
- 所有 `Int_Comp` / `Bool_Glob` / `Ch_1_Glob` 等结果为 `0`
- 字符串 `Str_Comp` 在约 16 字符处截断

**根因推测**
1. `legacy_mem_subsys` 数据内存被 Vivado 综合为 LUTRAM（而非 BRAM），可能存在初始化或读时序差异
2. C printf 的 `%d` 整数格式化依赖 va_list 栈读取，可能受 LUTRAM 数据完整性影响
3. Scoreboard FPGA 树优化可能在特定长时间计算路径上触发微妙的发射时序问题

> 此问题不影响诊断 ROM（纯汇编、无 `.data` 段）的板测通过，仅影响 C 语言 Benchmark。

### 基础测试（截至 2026-03-30，本地 `--basic` 回归）

| 测试 | 结果 |
|------|---------|
| 核心功能测试 (`test1` / `test2` / `test_rv32i_full`) | ✅ PASS |
| **Store Buffer 测试 (10个)** | ✅ PASS |
| **L2/Cache/MMIO 测试 (7个)** | ✅ PASS |
| **CSR/中断测试 (6个)** | ✅ PASS |
| **默认 basic 总计** | **26/26 PASS** |
| `test_smt.s` | 可单独运行，不在当前默认 `--basic` 集合中 |
| `test_rocc_*.s` (3个) | 默认关闭；需 `--enable-rocc` 显式打开 |

### riscv-tests (经典测试集)

| 类别 | 通过/总数 | 状态 | 说明 |
|------|----------|------|------|
| rv32ui | 42/42 | ✅ PASS | 全部通过（含 fence_i / ld_st / ma_data / st_ld） |
| rv32um | 8/8 | ✅ PASS | 乘除法测试全部通过 |
| **总计** | **50/50** | ✅ PASS | 通过率 100% |

> **更新（2026-04）**：此前 4 个预期失败测试（fence_i / ld_st / ma_data / st_ld）已在最新验证中全部通过，
> 当前通过率 50/50 (100%)。

### riscv-arch-test (官方架构测试)

| 类别 | 通过/总数 | 状态 |
|------|----------|------|
| rv32i | 39/39 | ✅ PASS |
| rv32im | 8/8 | ✅ PASS |
| **总计** | **47/47** | ✅ PASS |

### 编译选项

仿真编译/运行统一由 `verification/run_all_tests.py` 处理；测试差异通过 `--tests` 选择，不再维护单独的裸 `iverilog` 编译命令。

### 13.11 mem_subsys FPGA 上板验证（2026-04-07）

**Phase 1: 片上 RAM + L2 Passthrough**

| 里程碑 | 状态 | 说明 |
|------|------|------|
| mem_subsys 综合 | ✅ | `ENABLE_MEM_SUBSYS=1` + `L2_PASSTHROUGH=1`，54,767 LUTs (40.93%) |
| L2 Passthrough 优化 | ✅ | L2 从 184,905 LUTs → 81 LUTs（3-state FSM 替代完整缓存） |
| CLINT + PLIC 上板 | ✅ | 定时器中断 + 外部中断控制器均已综合 |
| UART MMIO 上板 | ✅ | mem_subsys 内 UART TX/RX，板测输出 `UART DIAG PASS` |
| RAM 初始化 | ✅ | `$readmemh` + `merge_hex_for_mem_subsys.py` 合并 inst/data hex |
| 时序收敛 | ✅ | WNS +1.736ns, WHS +0.119ns (post-impl, 10MHz) |
| 板测验证 | ✅ | 串口稳定输出 `UART DIAG PASS` ×2 |

**关键技术决策**

- **为什么用 L2 Passthrough 而非完整 L2 缓存？** 完整 L2 cache 的 3D `data_array[64][4][8]` 在 FPGA 上被综合为 184,905 个分布式 LUT/FF，超出芯片总容量。Passthrough 模式仅保留仲裁和 MMIO 路由逻辑，用 81 LUTs 实现直连 RAM 的功能。
- **为什么跳过 L2 缓存？** 后续架构方向为 L1 DCache → DDR3 直连（通过 AXI4 接口），不保留 L2 层级。
- **为什么需要 merge_hex？** mem_subsys 使用单块共享 RAM（指令+数据），而编译工具链分别输出 `inst.hex` 和 `data.hex`。`merge_hex_for_mem_subsys.py` 将两者合并为地址对齐的 `mem_subsys_ram.hex`。

**DDR3 集成状态**

| 步骤 | 内容 | 状态 |
|------|------|------|
| ① 生成 MIG IP | MT41K256M16HA-125, 32-bit bus, BANK34/35 | ✅ 已完成 |
| ② DDR3 XDC 约束 | 数据/地址/控制引脚约束 | ✅ 已完成 |
| ③ CDC 桥接模块 | `ddr3_mem_port.v`: 32b↔256b AXI lane steering + toggle-flag CDC | ✅ 已完成 |
| ④ 地址映射 | DDR3: 0x8000_0000+, MMIO 旁路, DDR3_STATUS: 0x1300_0020 | ✅ 已完成 |
| ⑤ 板测验证 | `CAL=1, W=DEADBEEF R=DEADBEEF, DDR3 PASS` | ✅ 已完成 |

> 架构方向：仅保留 L1 缓存，通过 AXI 接口直连 DDR3，不再使用 L2 缓存层级。

### 13.12 DDR3 上板验证（2026-04-07）

**Phase 2: DDR3 外存集成**

| 里程碑 | 状态 | 说明 |
|------|------|------|
| MIG IP 生成 | ✅ | MIG 7-Series v4.2, AXI4, 256-bit data, 4-bit ID, 30-bit addr |
| DDR3 XDC 约束 | ✅ | Bank 34 (addr/ctrl) + Bank 35 (data), 400MHz DDR |
| CDC 桥接模块 | ✅ | `ddr3_mem_port.v`: toggle-flag 异步 CDC, 32b↔256b lane steering |
| DDR3 状态 MMIO | ✅ | `DDR3_STATUS_ADDR = 0x1300_0020` → `{31'b0, init_calib_complete}` |
| LED 状态指示 | ✅ | LED[2] = `~init_calib_complete`（DDR3 启用时） |
| MIG 校准 | ✅ | `CAL=1` — DDR3 初始化校准成功 |
| DDR3 读写 | ✅ | `W=DEADBEEF R=DEADBEEF` — 写入后读回完全匹配 |
| Walking-ones 测试 | ✅ | 全部通过，循环运行稳定 |
| 时序收敛 | ✅ | WNS +0.238ns, WHS +0.059ns (post-impl, 10MHz core + ~100MHz UI) |

**板测 UART 输出**

```
SCAL=1
W=DEADBEEF R=DEADBEEF
DDR3 PASS
```

ROM 在循环运行，60 秒 UART 捕获内每次迭代均 PASS。

**DDR3 地址映射**

| 地址范围 | 目标 | 说明 |
|------|------|------|
| `0x0000_0000 - 0x0000_3FFF` | 片上 RAM (16KB LUTRAM) | 指令+数据共享 |
| `0x1300_0000 - 0x1300_001F` | MMIO (TUBE/UART) | 非缓存 IO |
| `0x1300_0020` | DDR3 Status MMIO | `{31'b0, init_calib_complete}` |
| `0x8000_0000+` | DDR3 外存 (1GB) | 通过 `ddr3_mem_port` CDC 桥接 |

**`ddr3_mem_port.v` 架构**

```
Core Domain (~10MHz)              UI Domain (~100MHz)
┌─────────────────┐               ┌─────────────────────────┐
│ req_addr/data   │──toggle-flag──│ 3-stage sync             │
│ req_we/be       │   CDC         │ req_flag_ui_sync[2:0]    │
│                 │               │                          │
│ resp_valid ←────│──toggle-flag──│ AXI4 FSM:                │
│ resp_data  ←────│   CDC         │  UI_IDLE → UI_WR/RD_ADDR │
│                 │               │  → UI_WR/RD_DATA         │
│                 │               │  → UI_WR_RESP → UI_DONE   │
└─────────────────┘               └─────────────────────────┘

32-bit CPU word ↔ 256-bit AXI data (8-word lane steering via addr[4:2])
```

**调试过程中发现并修复的 Bug**

| Bug | 描述 | 症状 | 修复 |
|-----|------|------|------|
| **#10 CDC 竞态** | `req_pulse_ui` 边沿检测丢失请求 | CPU 挂死 | 改为 `req_pending_ui` 电平标志 |
| **#11 wstrb 重叠** | case 分支间非阻塞赋值重叠 | 代码质量问题（未影响功能） | 每个 case 分支写完整 256-bit wdata/wstrb |
| **#12 响应数据时序** | `resp_data` 比 `resp_valid` 晚一拍 | **DDR3 读回全零（根因）** | `assign resp_data = resp_pulse_core ? resp_data_ui : resp_data_r;` |

> **Bug #12 是 DDR3 读回全零的根本原因。** `resp_valid` 是组合逻辑（立即为 1），但 `resp_data_r` 是寄存器（要到下一个时钟沿才更新）。修复方式：在响应脉冲有效时直接旁路到 CDC 安全的 `resp_data_ui`（toggle 握手保证数据在标志传播前已稳定）。

**DDR3 构建流程**

```powershell
# 环境变量由 run_ddr3_full_rebuild.ps1 内部设置：
#   AX7203_ENABLE_MEM_SUBSYS=1
#   AX7203_ENABLE_DDR3=1
#   AX7203_ROM_ASM=rom/test_fpga_ddr3_diag.s
#   AX7203_CORE_CLK_MHZ=10.0

# 完整构建（综合+实现+bitstream，约 12-15 分钟）
powershell -File build/run_ddr3_full_rebuild.ps1

# UART 捕获（先开，再下载）
Start-Job { powershell -File "$PWD\build\capture_uart_once.ps1" -Port COM5 -OutFile "$PWD\build\uart_ddr3_test.txt" -Seconds 60 }
vivado.bat -mode batch -source fpga/program_ax7203_jtag.tcl
```

**诊断 ROM (`test_fpga_ddr3_diag.s`) 测试流程**

1. 打印 `"S"` — CPU 启动
2. 轮询 `DDR3_STATUS_ADDR`（5M 次迭代 ≈ 500ms 超时）
3. 打印 `"CAL=0"` (halt) 或 `"CAL=1"` (继续)
4. 写入 `0xDEADBEEF` → 读回对比 → 打印 `"W=xxxxxxxx R=yyyyyyyy"`
5. Walking-ones 测试（0x1, 0x2, 0x4, ..., 0x80000000）
6. 全部通过打印 `"DDR3 PASS"`
7. 循环重复

### 13.13 reg_is_ro 流水线寄存器优化（2026-04-08）

**背景**: §13.9 分析的 119 级跨模块关键路径（Scoreboard→RegFile→Bypass→ALU）是 Fmax 瓶颈。

**方案**: 在 Scoreboard 发射（IS）和 Register Operand（RO）之间插入一组流水线寄存器 `reg_is_ro`，将单周期跨模块路径拆分为两拍。

**修改范围**: 仅 `rtl/adam_riscv.v`（+236/-84 行），不修改任何子模块。

| 内容 | 说明 |
|------|------|
| **寄存器信号** | ~30 信号 × 2 端口：`ro0_*` / `ro1_*`（ALU 操作、操作数、目标寄存器、控制标志等） |
| **刷新门控** | `epoch` 匹配检查：IS 阶段 epoch 不匹配时插入气泡（`ro*_valid = 0`） |
| **tagbuf 修复** | `result_buffer` 查询提前至 IS 阶段捕获，避免注册后组合反馈竞态 |
| **CSR 路径** | `ro0_csr_addr` 驱动 CSR 单元（仅 pipe0 端口支持 CSR） |
| **RoCC 路径** | `ro0_rocc_*` 信号完整注册 |

**时序代价**

| 事件 | 优化前 | 优化后 |
|------|--------|--------|
| Issue → ALU Result | N+1 拍 | N+2 拍 |
| Branch Resolution | N+2 拍 | N+3 拍（误预测罚分 +1） |
| IPC 影响 | — | 轻微下降（乱序执行可掩盖大部分延迟） |

**验证结果**

| 测试套件 | 结果 |
|----------|------|
| `run_all_tests.py --basic` | 23/23 PASS（3 个无关预置失败） |
| `riscv-tests` | 50/50 PASS |
| `riscv-arch-test` | PASS |

**FPGA 时序（post-impl, 10 MHz, DDR3 已启用）**

| 指标 | 值 |
|------|-----|
| WNS (overall) | +0.238 ns |
| WNS (core clock) | +0.383 ns |
| WHS | +0.058 ns |
| 关键路径 | Scoreboard 内部（111 级） |
| 数据路径延迟 | 99.437 ns |

> 跨模块 SB→RegFile→ALU 路径已完全消除。新瓶颈为 Scoreboard 内部发射仲裁逻辑。
> 通过 §13.14 的 oldest_store 树化进一步将路径从 111 级降至 60 级，Fmax 提升至 20 MHz。

### 13.14 oldest_store 树化优化（2026-04-08）

**背景**: §13.13 的 reg_is_ro 将关键路径收缩至 Scoreboard 内部（111 级），Fmax 约 10 MHz。瓶颈为 oldest_store 的 16-entry 线性 for 循环 O(N) 扫描。

**方案**: 用 4 级二叉锦标赛树替代线性扫描，将 oldest_store 查找从 O(N) 降为 O(log N)。复用已有的 `pick_older_fpga_cand` 函数和 branch 树基础设施。

**修改范围**: 仅 `rtl/scoreboard.v`（`ifdef FPGA_MODE` 保护，仿真路径完全不变）。

| 内容 | 说明 |
|------|------|
| **新增声明** | `store_t0_l0..l4`, `store_t1_l0..l4` — 每线程 5 级树数组 |
| **新增 always 块** | ~50 行 store tree computation：叶子填充 → 4 级 `pick_older_fpga_cand` 归约 |
| **修改 candidate 块** | 原 16-entry 线性扫描 → 直接读取树根 `store_t0_l4` / `store_t1_l4` |
| **无变更** | 顺序逻辑（wakeup/dealloc/flush）、仿真路径、pick_older_fpga_cand 函数 |

**实现模式**

```
叶子(l0[16]): win_valid[i] && win_mem_write[i] → {1'b1, win_seq[i], idx}
                                              or → {1'b0, 16'hffff, 4'd0}
l1[8]  = pick_older(l0[0],l0[1]),  pick_older(l0[2],l0[3]), ...
l2[4]  = pick_older(l1[0],l1[1]),  pick_older(l1[2],l1[3])
l3[2]  = pick_older(l2[0],l2[1]),  pick_older(l2[2],l2[3])
l4     = pick_older(l3[0],l3[1])   ← 最终结果
```

每线程独立树（`store_t0` / `store_t1`），结果直接驱动 `oldest_store_found_t0/t1` 和 `oldest_store_seq_t0/t1`。

**时序改善**

| 指标 | 优化前（reg_is_ro only） | 优化后（+oldest_store 树） | 变化 |
|------|--------|--------|------|
| Post-synth 逻辑级数 | 111 级 | **60 级** | **-46%** |
| Post-synth 数据路径 | 99.4 ns (估) | **36.6 ns** | **-63%** |
| 15 MHz WNS | ❌ -5.247 ns | **✅ +0.928 ns** | **+6.175 ns** |
| 15 MHz Core WNS | — | **+14.111 ns** | 余量充裕 |
| 20 MHz WNS | ❌ -11.864 ns | **✅ +0.326 ns** | **+12.190 ns** |
| Fmax | ~10 MHz | **~20 MHz** | **+100%** |

**验证结果**

| 测试套件 | 结果 |
|----------|------|
| `run_all_tests.py --basic` | 26/26 PASS |
| `riscv-tests` | 50/50 PASS |
| `riscv-arch-test` | 47/47 PASS |
| iverilog FPGA_MODE 编译 | ✅ 0 errors |
| Vivado 综合 15 MHz | ✅ 0 errors, 60 logic levels |
| Vivado 实现 15 MHz | ✅ WNS=+0.928ns, all met |
| Vivado 实现 20 MHz | ✅ WNS=+0.326ns, all met |

> 所有变更均在 `ifdef FPGA_MODE` 内，仿真路径零影响。
> 仅 Step 1.1（树化）即达成 15 MHz 目标（原 Plan 的 Steps 1.2/1.3 寄存化无需实施）。

### 13.15 Issue 关键路径双阶段优化 — 目标 50 MHz（2026-04-08）

**背景**: §13.14 后 Fmax ≈ 20 MHz（WNS=+0.326ns @ 20 MHz）。关键路径为 Scoreboard 内部 57 级组合链，数据路径 49.504ns：

```
win_br_reg[15] (1.9ns)
  ↓ [A] Branch tree + seq extraction (~8ns, 10 levels)
  ↓ [B] effective_br_seq → pending_branch → fpga_cand_l0 filter (~8ns, 8 levels, CARRY4)
  ↓ [C] Candidate tree reduction l0→l4 (~3ns, 8 levels)
  ↓ [D] sel0/sel1 + issue output mux (~12ns, 15 levels, fanout=204)
  ↓ [E] iss0_tag → adam_riscv iss0_is_rocc bypass → scoreboard win_issued/ready (~18ns, 16 levels)
win_ready_reg[3] (51ns)
```

目标 50 MHz (20ns 周期) 需要将数据路径从 49.5ns 降至 <19ns，共需 ~62% 缩减。

**方案**: 两阶段递进优化。

#### Phase 1: 切断 `iss0_is_rocc` 跨模块反馈环 (消除 Stage E, -18ns)

FPGA 构建中 `ENABLE_ROCC_ACCEL=0`（默认值），RoCC 不综合。但 `iss0_is_rocc` 信号仍由 decode 组合逻辑驱动，形成 scoreboard → adam_riscv → scoreboard 的跨模块反馈路径（~18ns, 16 levels），占总延迟的 36%。

| 文件 | 修改 |
|------|------|
| `rtl/scoreboard.v` L1530 | `ifdef FPGA_MODE` 下去掉 RoCC 门控：`if (sel0_found)` 替代原条件 |
| `rtl/adam_riscv.v` L1177 | `ifdef FPGA_MODE` 下 hardwire `iss0_is_rocc = 1'b0` |

#### Phase 2: 候选谓词寄存化 (消除 Stage A+B, -16ns)

`fpga_cand_l0[i]` 有 ~10 个组合过滤条件（valid/issued/ready/just_woke、FU type/busy、`branch_in_flight`、16-bit seq 比较 ×2），构成 Stage A+B（~16ns, 18 levels）。将这些条件预计算为 `entry_eligible_r[RS_DEPTH-1:0]` 寄存器。

| 内容 | 说明 |
|------|------|
| **新增声明** | `entry_eligible_r[RS_DEPTH-1:0]` — 每 entry 1-bit 预计算资格 |
| **新增顺序逻辑** | ~20 行在 `always @(posedge clk)` 中预计算 `entry_eligible_r[i]`，包含所有原过滤条件（除 `fu_busy`） |
| **修改 fpga_cand_l0** | 原 10 条件链 → `entry_eligible_r[i] && !fu_busy_check`（2 条件） |
| **fu_busy 保留组合** | `fu_busy` 在 issue 同拍设置，必须保持组合检查避免同 FU 双发射 |

`entry_eligible_r[i]` 预计算条件集合:
- `win_valid[i] && !win_issued[i] && win_ready[i] && !win_just_woke[i]`
- FU type 合法性检查 (INT0/INT1/MUL/LOAD/STORE)
- `!branch_in_flight` 序列化
- `!pending_branch || win_br[i] || (seq < effective_br_seq)` 分支后指令阻止
- `!(mem_op && oldest_store_found && oldest_store_seq < seq)` store ordering

**1 拍延迟分析**: `entry_eligible_r` 基于上一拍状态，新唤醒的指令在 `win_ready` 变 1 后要多等 1 拍才能被 `entry_eligible_r` 捕获。但 `WAKE_HOLD_CYCLES=1` 已确保 `win_just_woke=1` 的指令在唤醒后被抑制 1 拍，所以这个额外延迟已被设计覆盖。

**预期效果**: Phase 1 + Phase 2 合计消除 ~34ns (Stages A+B+E)，剩余路径为 candidate tree → issue MUX (~15ns)。

**验证结果** (2026-04-08):

| 频率 | WNS (synth) | WNS (impl) | 关键路径 (impl) | 逻辑级数 | 状态 |
|------|------------|------------|----------------|---------|------|
| 25 MHz | +12.772ns | — | 27.018ns | 44 | ✅ |
| 30 MHz | — | **+0.087ns** | **33.044ns** | **42** | ✅ bitstream 生成 |
| 35 MHz | +1.295ns | -2.371ns | — | — | ❌ impl 违约 |

**实测 Fmax = 30 MHz**（从 20 MHz 提升 **+50%**）。关键路径从 49.5ns → 33.0ns（减少 33%），逻辑级数从 57 → 42（减少 26%）。

Post-impl 关键路径 @ 30 MHz:
```
scoreboard/fu_busy_reg[6] → exec_pipe0/stored_br_mark_reg
  Data Path: 33.044ns (logic 7.603ns, route 25.441ns)
  Logic Levels: 42 (CARRY4=7 LUT2=1 LUT3=7 LUT4=2 LUT5=8 LUT6=14 MUXF7=2 MUXF8=1)
```

**注意**: `reg_is_ro` 流水线寄存器（§13.15 原始设计）因仿真中引入 flush/branch 交互 bug 被暂时回退。仅保留 Scoreboard 侧优化（entry_eligible_r + store tree + iss0_is_rocc bypass）。同时修复了 scoreboard flush 时 `branch_in_flight` 可能死锁的 bug（flush 块中强制清零对应线程的 `branch_in_flight`）。

**修改范围**: `rtl/scoreboard.v`（`ifdef FPGA_MODE` 内 + flush 安全修复）+ `rtl/adam_riscv.v`（仅 `iss0_is_rocc` ifdef）。

**仿真验证**: 26/26 basic tests PASS。FPGA bitstream 在 30 MHz 下生成（9.28 MB）。
