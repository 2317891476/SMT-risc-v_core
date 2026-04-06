# AdamRiscv — 高性能乱序双发射 RISC-V 处理器

## 1. 项目概述

`AdamRiscv` 是面向**全国 CPU 系统能力培养大赛**的高性能 RV32I 处理器实现。项目在一个教学级 SMT 有序内核基础上，完成了工业级的微架构升级。

### 当前架构能力

| 维度 | 能力 |
|------|------|
| **ISA** | RV32I 全部 47 条指令 + RV32M 乘法扩展 |
| **发射宽度** | 双发射 (Dual-Issue)，双调度端口 |
| **执行引擎** | 乱序执行 (OoO)，16-entry Reservation Station，Scoreboard 动态调度 |
| **流水线** | IF → FetchBuffer → DualDecode → Scoreboard → RO → EX(Pipe0/Pipe1) → MEM → WB |
| **分支预测** | 256-entry 双模态 (Bimodal) 2-bit 饱和计数器 + BTB |
| **SMT** | 2 线程同步多线程，Round-Robin 取指调度，独立 PC 和寄存器堆 |
| **虚拟内存** | Sv32 MMU：I-TLB(16) + D-TLB(32) + 7 状态硬件页表漫游器 (PTW) |
| **缓存** | L1: 4-way 组相联非阻塞 DCache，PLRU 替换，写回/写分配策略<br>L2: 8KB 统一二级缓存，4-way，32B 行，PLRU 替换，阻塞设计 |
| **总线** | AXI4 突发传输接口 (缓存行填充/写回) |
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
| `l2_cache` | 统一二级缓存 | 8KB, 4-way, 32B 行, PLRU 替换, 阻塞设计 |
| `l2_arbiter` | 3主设备优先级仲裁器 | I-side (M0) + D-side (M1) + RoCC DMA (M2), M2优先级最高 |
| `clint` | 内核本地中断器 (CLINT) | 64位 mtime/mtimecmp, 定时器中断 |
| `plic` | 平台级中断控制器 (PLIC) | 优先级/使能/阈值寄存器, Claim/Complete |

**L2 缓存特性：**
- 8KB 总容量，4路组相联，32字节缓存行
- PLRU (Pseudo-LRU) 替换策略
- 写回 (Write-back) + 写分配 (Write-allocate) 策略
- 阻塞设计：单路缺失处理，8周期填充
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
| L2 缓存 | 无 | **8KB 4-way 统一缓存 + 轮询仲裁器** |
| 中断 | 无 | **CLINT + PLIC，支持定时器/外部中断** |

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
| **P4**     | **DDR3 支持（最小可用版本）**                            | 打通 AX7203 板载 DDR3 的最小稳定数据面：代码仍可驻留 BRAM，数据集/工作集放入 DDR3。优先服务 benchmark 扩展测试和 Demo 数据集加载，而不是一开始就追求完整外存操作系统。 |
| **P4**     | **RoCC DMA 软件栈完善**                                  | 补齐 C 语言接口、内联汇编封装、scratchpad 分配器、blocking/non-blocking DMA API，形成可复用的软件层。让评委看到“不是单个硬件指令能跑，而是软件可调用、系统可集成”。 |
| **P4**     | **应用 Demo A：端侧 AI / TinyML 加速**                   | 主打场景。使用现有 8×8 INT8 GEMM + SIMD，完成小型 MLP / 卷积核 / 关键词分类 / 矩阵推理 Demo。必须给出 `纯 CPU` vs `RoCC` 的延迟、吞吐和能效对比，是最容易形成“杀手锏”的展示方向。 |
| **P5**     | **应用 Demo B：轻量数据流处理**                          | 结合 UART / DDR3 / PCIe / 千兆网口中的一种输入路径，完成 `数据搬运 + 规则计算 + 加速处理 + 输出` 的闭环。例如包头过滤、流式 checksum、工业传感器数据预处理等，强调处理器不仅能跑分，还能接近真实系统。 |
| **P5**     | **应用 Demo C：轻量图像前处理（可选）**                  | 若时序与资源余量允许，再做 Sobel / 阈值化 / Resize / 卷积前处理等轻量图像任务。注意这是“可选加分项”，不应压过主线的 CoreMark + AI Demo。 |
| **P5**     | **评测材料工程化**                                       | 输出统一展示材料：性能表、资源利用率表、时钟频率、测试脚本、上板录像、波形截图、RoCC 加速比图、架构亮点图。将“功能完成”升级为“证据完备”。 |
| **P5**     | **资源/时序最终压榨**                                    | 已定位关键长路径：119 级组合逻辑 Scoreboard→RegFile→ALU（见 §13.9）。提频需在此路径插入流水线寄存器。优先对 Bypass、Scoreboard 仲裁、Cache tag compare、RoCC 接口做切分；乘法与 GEMM 尽量向 DSP48E1 收敛。目标不是极限堆频，而是在 AX7203 上保持稳定、可重复、可展示。 |
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
| **DDR3** | ⏳ | 后续支持 (当前 BRAM-first) |
| **当前固定配置** | ✅ | `FPGA_MODE=1`, `ENABLE_MEM_SUBSYS=0`, `ENABLE_ROCC_ACCEL=0`, `SMT_MODE=0` |

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

### 13.4 当前固定综合配置（2026-04-03）

当前默认的 FPGA 配置是面向 AX7203 bring-up 的轻量 on-chip RAM 版本，目标是先固定一条稳定、可复现、可烧录的上板路径，而不是直接上完整的 `mem_subsys/L2/RoCC` 竞赛配置。

> 这里特别说明：README 前文提到的“`RS=16、L2=8KB、RoCC Scratchpad=4KB`”是**目标竞赛配置**。  
> 当前已经综合、生成 bitstream 并上板验证的配置不是那一版，而是下面这套轻量 bring-up 配置。

| 开关 | 当前值 | 说明 |
|------|------|------|
| `FPGA_MODE` | `1` | 启用 AX7203 顶层时钟/复位/板级接口路径 |
| `ENABLE_MEM_SUBSYS` | `0` | 不综合 `mem_subsys/L2/CLINT/PLIC`，改走轻量 `legacy_mem_subsys` |
| `ENABLE_ROCC_ACCEL` | `0` | 默认不综合 RoCC 加速器 |
| `SMT_MODE` | `0` | 当前固定为单线程 bring-up 配置 |
| `AX7203_CORE_CLK_MHZ` | `10.0` | 为 `RS=16 / FetchBuffer=16` 的稳定板测收敛到 10MHz core clock |
| `AX7203_UART_CLK_DIV` | `87` | 保持 core 内 MMIO UART 为 `115200 8N1` |
| `AX7203_MAX_THREADS` / `AX7203_SYNTH_JOBS` | `1 / 1` | 避免 Vivado 综合阶段偶发 `EXCEPTION_ACCESS_VIOLATION` |

**当前实际上板的关键微架构参数**

| 参数 | 当前上板值 | 目标竞赛值 | 说明 |
|------|------|------|------|
| 发射宽度 | 2 | 2 | 当前仍是双发射 core |
| `scoreboard` RS 深度 | `16` | `16` | 已在当前 `FPGA_MODE` 上恢复到目标深度，稳定板测依赖 `core_clk=10MHz` |
| Fetch Buffer 深度 | `16` | `16` | 已在当前 `FPGA_MODE` 上恢复到目标深度 |
| L1 ICache | `2KB, 1-way, 32B line` | 待后续冻结 | 当前 `inst_memory` 内部仍启用轻量指令缓存 |
| L1 DCache | `关闭` | 待后续冻结 | 当前上板不走 `l1_dcache_nb`，数据侧直接走轻量后端 |
| L2 Cache | `关闭` | `8KB` | 当前走 `legacy_mem_subsys`，不走完整 `mem_subsys/L2` |
| `legacy_mem_subsys` 本地 RAM | `16KB, LUTRAM` | 待后续冻结 | 当前实现结果为 `4096` LUT as Memory，而不是 BRAM |
| RoCC Scratchpad | `关闭` | `4KB` | 当前默认不综合 RoCC |
| SMT | `关闭` | 可选 | 当前上板固定单线程 |

**当前 `legacy_mem_subsys` 配置**

- 数据 RAM：`RAM_WORDS=4096`，按 32-bit word 组织，总容量 `16KB`
- 地址窗口：`0x0000_0000 - 0x0000_3FFF`
- 实现形态：当前 Vivado 综合结果为 `4096` 个 LUT as Memory（`16KB LUTRAM`）的轻量数据后端
- 数据侧行为：当前不带 L1 DCache / L2 / CLINT / PLIC，load/store 直接落到这块本地 RAM 或 MMIO
- 当前 MMIO：`TUBE` + 完整 MMIO UART（`TXDATA/STATUS/RXDATA/CTRL`）

**当前综合进去的主要部件**

- `adam_riscv` 主核：双发射前后端、`scoreboard`、`rob_lite`、两套寄存器堆、`decoder_dual`、`fetch_buffer`、`exec_pipe0/1`、`mul_unit`、`csr_unit`
- 访存路径：`lsu_shell + store_buffer`
- 取指路径：`stage_if + bimodal BPU + inst_memory + inst_backing_store`
- 轻量数据后端：`legacy_mem_subsys`，包含 `16KB LUTRAM` 数据路径和完整 MMIO UART（TX/RX/STATUS/CTRL）
- 板级逻辑：`clk_wiz_0`、`syn_rst`、`u_board_uart_tx`、`uart_rx_monitor`、LED/诊断 glue
- 默认板测 top：`adam_riscv_ax7203_top`
- 板级诊断 top：`adam_riscv_ax7203_status_top`、`adam_riscv_ax7203_issue_probe_top`、`adam_riscv_ax7203_branch_probe_top`、`adam_riscv_ax7203_main_bridge_probe_top`

**当前没有综合进去的部件**

- `mem_subsys`
- `L2 cache`
- `CLINT / PLIC` MMIO 中断子系统
- `RoCC accelerator`
- `SMT` 多线程模式

### 13.5 当前综合/实现资源（AX7203, 2026-04-03）

综合入口使用 `fpga/run_ax7203_synth.tcl`，默认 15 分钟超时门限；当前稳定设置为 `AX7203_MAX_THREADS=1`、`AX7203_SYNTH_JOBS=1`。最近一次 `RS=16 / FetchBuffer=16 / core_clk=10MHz` 的 `core_diag` / `uart_echo` 板测流程中，`synth_design` 实际用时约 `6.05` 分钟。

**时序结果（2026-04 Scoreboard 优化后）**

| 构建 | WNS | WHS | 说明 |
|------|-----|-----|------|
| Dhrystone ROM | `+0.543ns` | `+0.084ns` | Scoreboard 树优化后最新结果 |
| core_diag ROM | `+0.359ns` | `+0.084ns` | 优化前基线 |

> Scoreboard FPGA 树优化（见 §13.8）改善了关键路径时序，WNS 从 +0.359ns 提升至 +0.543ns。

> 下面这些资源数字对应的是**当前实际上板的轻量 bring-up 配置**，也就是  
> `RS=16 + FetchBuffer=16 + L1 ICache=2KB(1-way) + legacy_mem_subsys=16KB(LUTRAM) + core_clk=10MHz + UART_CLK_DIV=87 + ENABLE_MEM_SUBSYS=0 + ENABLE_ROCC_ACCEL=0 + SMT_MODE=0`，  
> 并不是 README 前文提到的目标竞赛配置（`RS=16 + L2=8KB + RoCC Scratchpad=4KB`）。

| 资源 | 使用量 | 可用量 | 利用率 |
|------|------|------|------|
| Slice LUTs | 53,278 | 133,800 | 39.82% |
| Slice Registers | ~34,000 | 269,200 | ~12.6% |
| LUT as Memory | 4,096 | 46,200 | 8.87% |
| RAMB18 | 0 | 730 | 0.00% |
| DSP48E1 | 4 | 740 | 0.54% |

> 以上数据对应 Dhrystone ROM 构建（含 `$readmemh` 数据初始化），较 core_diag 基线略有增加。

**主要层级资源分布（综合层级报告）**

| 模块/层级 | Total LUTs | FFs | 备注 |
|------|------|------|------|
| `u_scoreboard` | 24,962 | 4,753 | 当前最大 LUT 消耗点（含 FPGA 树优化，见 §13.8） |
| `u_stage_if` | 6,553 | 18,926 | 含 `bpu_bimodal + inst_memory` |
| `gen_legacy_mem.u_legacy_mem_subsys` | 4,671 | 141 | 其中 4,096 LUTRAM |
| `u_regs_mt` | 3,313 | 1,984 | Pipe0/线程寄存器堆 |
| `u_regs_mt_p1` | 3,313 | 1,984 | Pipe1/线程寄存器堆 |
| `u_rob_lite` | 1,888 | 1,278 | 提交/回滚路径 |
| `u_lsu_shell` | 1,238 | 942 | 含 `store_buffer` |
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

**实现细节**

- `localparam FPGA_TREE_SLOTS = 16, CAND_W = 1 + 16 + RS_IDX_W = 21`
- 每个候选打包为 21-bit 向量 `{valid[1], seq[16], idx[4]}`
- 4 级 `always @(*)` 组合逻辑锦标赛：`l0(16→8) → l1(8→4) → l2(4→2) → l3(2→1) → l4(winner)`
- `pick_older_fpga_cand` 函数：比较两个候选的 valid 位和 seq 值，选择更旧的
- 分支树和发射候选树使用相同的基础设施

**时序改善**

| 指标 | 优化前 | 优化后 | 变化 |
|------|--------|--------|------|
| WNS (10 MHz) | +0.359 ns | +0.543 ns | **+0.184 ns (+51%)** |
| Slice LUTs | 51,631 (38.59%) | 53,278 (39.82%) | +1,647 (+3.2%) |

> LUT 开销增加约 3.2%，换取 51% 的时序余量改善。树结构用面积换时序，适合 FPGA 综合。

### 13.9 关键路径分析

当前 10 MHz 配置下的后实现关键路径：

```
路径深度:  119 个逻辑级别
延迟:      ~74 ns (post-implementation)
起点:      u_scoreboard/win_tid_reg[0][0]_rep__0/C
终点:      u_exec_pipe1/alu_out_result_r_reg[29]/D
```

**路径构成**

这是一条单周期组合路径，从 Scoreboard 发射仲裁 → 寄存器堆读取 → ALU 运算：

1. **Scoreboard 发射选择** (~40 级): 候选筛选、seq 比较、优先级仲裁
2. **寄存器堆读端口** (~20 级): 基于发射结果的地址解码和数据读出
3. **ALU 计算** (~20 级): 算术逻辑运算和结果生成
4. **布线延迟**: 跨模块连线贡献约 30% 的总延迟

**频率扫描结果**

| 目标频率 | WNS | 结果 |
|----------|-----|------|
| 10 MHz | +0.543 ns | ✅ 时序收敛 |
| 11 MHz | -3.955 ns | ❌ |
| 12 MHz | -2.850 ns | ❌ |
| 13 MHz | -4.061 ns | ❌ |
| 15 MHz | -4.882 ns | ❌ |
| 25 MHz | -34.460 ns | ❌ |
| 40 MHz | -47.713 ns | ❌ |
| 65 MHz | -57.383 ns | ❌ |

> **提频瓶颈**: 119 级组合逻辑路径限制了最大可达频率约 ~13.5 MHz（理论值）。
> 突破此瓶颈需要在 Scoreboard 发射→寄存器堆读→ALU 之间**插入流水线寄存器**，
> 这是一项重大的微架构变更，当前阶段收敛到 10 MHz 稳定运行。

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
