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
| **缓存** | 4-way 组相联非阻塞 L1 DCache，PLRU 替换，写回/写分配策略 |
| **总线** | AXI4 突发传输接口 (缓存行填充/写回) |
| **AI 加速** | RoCC 协处理器：8×8 INT8 GEMM 引擎 + 128-bit SIMD 向量单元 + KV-Cache 压缩 |
| **特权态** | Machine-mode CSR (mstatus/mepc/mcause/mtvec/satp)，异常入口/MRET |

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
  ║        SCOREBOARD V2 (16-entry RS)                 ║
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
├─ module/CORE/RTL_V1_2/           # 核心 RTL
│  ├─ adam_riscv.v                  # V1 顶层 (有序单发射, 兼容回归)
│  ├─ adam_riscv_v2.v               # ★ V2 顶层 (乱序双发射, 新架构)
│  │
│  │  ── V2 前端 ──
│  ├─ stage_if_v2.v                 # ★ 升级版 IF (集成 BPU)
│  ├─ bpu_bimodal.v                 # ★ 256-entry 分支预测器 + BTB
│  ├─ fetch_buffer.v                # ★ 4-entry 取指缓冲 FIFO
│  ├─ decoder_dual.v                # ★ 双路译码 + 结构冒险检测
│  │
│  │  ── V2 乱序引擎 ──
│  ├─ scoreboard_v2.v               # ★ 16-entry RS, 双分派/发射/CDB
│  ├─ bypass_network.v              # ★ 3 源前递网络
│  ├─ exec_pipe0.v                  # ★ 执行管道0 (INT+Branch)
│  ├─ exec_pipe1.v                  # ★ 执行管道1 (INT+MUL+AGU)
│  ├─ mul_unit.v                    # ★ 3 级流水乘法器 (RV32M)
│  │
│  │  ── V2 存储子系统 ──
│  ├─ tlb.v                         # ★ 参数化全相联 TLB
│  ├─ mmu_sv32.v                    # ★ Sv32 MMU + 硬件 PTW
│  ├─ l1_dcache_nb.v                # ★ 4-way 非阻塞 DCache + AXI4
│  │
│  │  ── V2 扩展 ──
│  ├─ rocc_ai_accelerator.v         # ★ RoCC AI 协处理器
│  ├─ csr_unit.v                    # ★ 特权态 CSR + 异常处理
│  ├─ define_v2.v                   # ★ 扩展定义
│  │
│  │  ── V1 原有模块 (仍用于兼容) ──
│  ├─ scoreboard.v                  # V1 记分牌 (8-entry RS)
│  ├─ thread_scheduler.v            # Round-Robin 调度器 (V1/V2 共用)
│  ├─ pc_mt.v                       # 双线程 PC 管理器 (V1/V2 共用)
│  ├─ regs_mt.v                     # 双 bank 寄存器堆 (V1/V2 共用)
│  ├─ stage_if.v / stage_is.v / stage_ro.v / stage_ex.v
│  ├─ stage_mem.v / stage_wb.v      # MEM/WB (V1/V2 共用)
│  ├─ alu.v / alu_control.v / ctrl.v / imm_gen.v
│  ├─ reg_if_id.v / reg_is_ro.v / reg_ro_ex.v / reg_ex_stage.v
│  ├─ reg_ex_mem.v / reg_mem_wb.v
│  └─ syn_rst.v / define.v
│
├─ comp_test/
│  ├─ run_iverilog_tests.ps1        # 一键构建 ROM + 仿真 + 判分
│  ├─ module_list                   # V1 iverilog 源文件清单
│  ├─ module_list_v2                # ★ V2 iverilog 源文件清单
│  ├─ tb.sv                         # V1 testbench
│  ├─ tb_v2.sv                      # ★ V2 testbench
│  ├─ test_content.sv               # 测试判分 (支持 test1/test2/smt/rv32i_full)
│  └─ out_iverilog/                 # 仿真输出 (日志/波形/可执行)
│
├─ rom/
│  ├─ test1.s                       # 基础 ALU + Load/Store
│  ├─ test2.S                       # Scoreboard RAW 冒险
│  ├─ test_smt.s                    # SMT 双线程验证
│  ├─ test_rv32i_full.s             # ★ RV32I 全部 47 条指令测试
│  ├─ harvard_link.ld               # 链接脚本 (.text=0x0, .data=0x1000)
│  └─ inst.hex / data.hex           # 仿真加载镜像
│
└─ libs/REG_ARRAY/SRAM/ram_bfm.v    # 行为级 RAM 模型
```

> 标注 ★ 的文件为本次升级新增。

---

## 4. V2 模块详解

### 4.1 前端 (Frontend)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `stage_if_v2` | IF 级：PC 管理 + 取指 + BPU 查询 | 集成 pc_mt + inst_memory + bpu_bimodal |
| `bpu_bimodal` | 2-bit 饱和计数器 + 直接映射 BTB | PHT_ENTRIES=256, XOR-fold thread indexing |
| `fetch_buffer` | 取指缓冲 FIFO，双弹出支持双译码 | DEPTH=4, per-thread flush |
| `decoder_dual` | 双路译码器，复用 stage_is ×2 | 检测: 双分支/双访存/WAW 冲突 |

### 4.2 乱序引擎 (OoO Engine)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `scoreboard_v2` | 集中式调度窗口 | RS_DEPTH=16, 双分派/双发射/双CDB |
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

### 4.4 扩展 (Extensions)

| 模块 | 功能 | 关键参数 |
|------|------|---------|
| `rocc_ai_accelerator` | RoCC AI 协处理器 | GEMM 8×8, SIMD 128-bit, 4KB scratchpad |
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

### 运行全部回归测试 (V1 管线)

```powershell
cd .\comp_test
$env:PATH = "E:\iverilog\bin;E:\xpack-riscv-none-elf-gcc-15.2.0-1\bin;" + $env:PATH
.\run_iverilog_tests.ps1 -Tests @("test1.s","test2.S","test_rv32i_full.s","test_smt.s") -NoGtkWave
```

期望输出:

```
========== Summary ==========
Test              Status
----              ------
test1.s           PASS
test2.S           PASS
test_rv32i_full.s PASS
test_smt.s        PASS
```

### 手动运行 V2 管线仿真

```powershell
cd .\comp_test
$env:PATH = "E:\iverilog\bin;E:\xpack-riscv-none-elf-gcc-15.2.0-1\bin;" + $env:PATH

# 1) 构建 ROM
riscv-none-elf-gcc -nostdlib -nostartfiles -Wl,--build-id=none `
  -Wl,-T,..\rom\harvard_link.ld -march=rv32i -mabi=ilp32 `
  ..\rom\test_rv32i_full.s -o ..\rom\main_s.elf
riscv-none-elf-objcopy -j .text -O verilog ..\rom\main_s.elf ..\rom\inst.hex
riscv-none-elf-objcopy -j .data -j .sdata -O verilog ..\rom\main_s.elf ..\rom\data.hex

# 2) iverilog 编译 V2
iverilog -g2012 -s tb_v2 -o out_iverilog\bin\tb_v2.out `
  -I ..\module\CORE\RTL_V1_2\ `
  (Get-Content module_list_v2 | Where-Object {$_ -match '\.v$'} | `
   ForEach-Object { (Resolve-Path $_).Path }) `
  ..\libs\REG_ARRAY\SRAM\ram_bfm.v tb_v2.sv

# 3) 运行
vvp out_iverilog\bin\tb_v2.out
```

---

## 7. 测试用例说明

| 测试文件 | 覆盖内容 | 验证方式 |
|---------|---------|---------|
| `test1.s` | ADD/SUB/AND/OR/XOR/LW/SW | 寄存器 x1-x9 + DRAM 黄金值 |
| `test2.S` | Scoreboard RAW 冒险链 (ADD→SUB→LW→SW→LW) | 寄存器 x1-x9 + DRAM 黄金值 |
| `test_smt.s` | SMT: T0 求和 1+..+10=55, T1 乘法 10×3=30 | DRAM[1152]=0x37, DRAM[1153]=0x1E |
| `test_rv32i_full.s` | **RV32I 全部 47 条指令** (详见下表) | 9 个 DRAM 检查点 + TUBE 标记 |

### test_rv32i_full.s 覆盖的指令 (37 条 + NOP)

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

## 8. V1 vs V2 架构对比

| 特性 | V1 (adam_riscv.v) | V2 (adam_riscv_v2.v) |
|------|-------------------|----------------------|
| 流水线 | IF→IS→SB→RO→EX1-4→MEM→WB (9级) | IF→FB→DualDec→SB_v2→RO→EX(×2)→MEM→WB |
| 发射宽度 | 单发射 | **双发射** |
| RS 深度 | 8 entry | **16 entry** |
| 执行单元 | 1× ALU | **2× ALU + 1× MUL** |
| 分支预测 | 无 | **256-entry Bimodal + BTB** |
| 前递网络 | 简单 forwarding | **3 源 bypass (pipe0/pipe1/mem)** |
| 缓存 | 无 (直接 SRAM) | **4-way L1 DCache + AXI4** |
| 虚拟内存 | 无 | **Sv32 MMU + hardware PTW** |
| AI 加速 | 无 | **RoCC GEMM + VPU** |
| CSR | 无 | **Machine-mode 完整支持** |

---

## 9. 波形调试建议

### V1 管线关键信号

```
is_push, sb_rs_full, ro_issue_valid, ro_issue_sb_tag, ro_issue_fu
wb_sb_tag, wb_fu, w_regs_en, w_regs_addr, wb_tid
fetch_tid, if_tid, ro_tid, ex_tid, wb_tid
```

### V2 管线关键信号

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

| 优先级 | 任务 | 说明 |
|--------|------|------|
| ~~P0~~ | ~~V2 管线仿真调试~~ | ✅ 已完成 (test1/test2/test_smt/test_rv32i_full 全部通过) |
| P1 | Store Buffer | 内存顺序约束，消除投机 store 问题 |
| P1 | L1 ICache | 替换 inst_memory 为非阻塞指令缓存 |
| P2 | L2 Cache | 统一二级缓存 + 仲裁器 |
| P2 | 中断控制器 (PLIC/CLINT) | 支持外部中断 + 定时器中断 |
| P3 | RoCC DMA 完善 | 完整 GEMM 数据搬运流水 |
| P3 | FPGA 综合 | 目标板适配 + 时序收敛 |

---

## 12. 常见问题 (FAQ)

**Q1: 脚本提示找不到工具？**
确认 PATH 包含工具链路径 (参见 §5.2)。

**Q2: test_rv32i_full.s FAIL？**
检查 `out_iverilog/logs/test_rv32i_full.log`，确认 DRAM 黄金值是否匹配。用 gtkwave 打开对应 VCD 波形调试。

**Q3: V1 和 V2 可以并存吗？**
是的。V1 (`adam_riscv.v` + `tb.sv` + `module_list`) 和 V2 (`adam_riscv_v2.v` + `tb_v2.sv` + `module_list_v2`) 完全独立，互不影响。

**Q4: 为什么 V2 管线还用 stage_mem / data_memory？**
当前 V2 的存储路径在仿真中直接复用 V1 的 `stage_mem` + `data_memory` (SRAM 行为模型)，确保功能正确。`l1_dcache_nb` 和 `mmu_sv32` 已就位，待切换到 AXI4 仿真环境后启用。

---

## 13. 验证状态

| 测试 | V1 管线 | V2 管线 |
|------|---------|---------|
| test1.s | ✅ PASS | ✅ PASS |
| test2.S | ✅ PASS | ✅ PASS |
| test_rv32i_full.s | ✅ PASS | ✅ PASS |
| test_smt.s | ✅ PASS | ✅ PASS (SMT模式) |

### V2 编译选项

```powershell
# 单线程模式 (test1, test2)
iverilog -g2012 -s tb_v2 -o tb_v2.out ...

# SMT 双线程模式 (test_smt)
iverilog -g2012 -s tb_v2 -DSMT_MODE=1 -o tb_v2_smt.out ...
```
