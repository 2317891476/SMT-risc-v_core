# P3 FPGA 综合、目标板适配与 CoreMark 板级验证

## TL;DR
> **Summary**: 为 ALINX AX7203 建立原生 Vivado TCL 综合/实现/下载流程，完成板级封装、XDC、时钟复位、JTAG+Flash 烧录与 BRAM-first CoreMark UART 测分，并对 `-2` 实板与 `-3` 目标器件做显式区分。
> **Deliverables**:
> - 原生 `/fpga` Vivado 批处理流（project/build/program/cfgmem/report）
> - AX7203 板级 top、XDC、clock/reset/IP 生成脚本
> - BRAM-first 上板启动与 UART 可观测性
> - CoreMark 移植、镜像生成、UART 结果采集与得分记录
> - `xc7a200t-2fbg484i` 主签核 + `xc7a200tfbg484-3` 次级比较报告
> **Effort**: XL
> **Parallel**: YES - 5 waves
> **Critical Path**: T1 部件/板卡真值 → T2 原生 Vivado 流 → T4 板级 top/XDC → T6 时钟复位/IP → T7 BRAM 启动 → T8 JTAG 下载 → T10 UART 可观测性 → T12 CoreMark BRAM-first → T11/13 时序与 Flash → T14 板级得分采集

## Context
### Original Request
- 完成 P3 FPGA 综合、目标板适配、时序收敛
- 使用本机已安装的 Vivado 与 TCL 脚本完成综合和烧录
- 目标芯片型号给定为 `xc7a200tfbg484-3`
- 烧录后测试一次 CoreMark 得分
- 生成给西西弗斯的详细计划

### Interview Summary
- 板卡：**ALINX AX7203**
- 烧录目标：**JTAG + Flash**，相关交付统一放在 `/fpga`
- XDC：**需要新写**，不依赖现成原生约束
- CoreMark 结果采集：**UART 串口**
- 首个板级里程碑：**先 BRAM 跑通**，不把 DDR3 带入第一阶段签核
- 器件差异：计划必须**同时覆盖** AX7203 常见实板 `XC7A200T-2FBG484I` 与用户给定 `xc7a200tfbg484-3`

### Metis Review (gaps addressed)
- 将 **`-2` 实板器件** 设为主签核目标，`-3` 设为次级比较构建目标，禁止混淆签核结论
- 明确 **BRAM-first**，DDR3 不进入首个成功定义
- 明确 **JTAG 下载** 与 **Flash 持久化启动** 为两个独立证明项
- 明确 **UART/LED/日志** 先于性能优化，避免“能综合但不可调”
- 明确 **CoreMark 不能只声称能跑**，必须输出 UART 证据、checksum/score/频率信息

## Work Objectives
### Core Objective
建立可复现的 AX7203 原生 FPGA 落地流程：从 RTL 到 bitstream、从 JTAG 到 Flash、从 BRAM-first 启动到 UART CoreMark 得分采集，并以真实板卡 `-2` 器件完成主签核。

### Deliverables
- `/fpga/create_project_ax7203.tcl`
- `/fpga/build_ax7203_bitstream.tcl`
- `/fpga/program_ax7203_jtag.tcl`
- `/fpga/program_ax7203_flash.tcl`
- `/fpga/write_ax7203_cfgmem.tcl`
- `/fpga/reboot_ax7203_after_flash.tcl`
- `/fpga/report_ax7203_timing.tcl`
- `/fpga/ip/create_clk_wiz_ax7203.tcl`
- `/fpga/constraints/ax7203_base.xdc`
- `/fpga/constraints/ax7203_uart_led.xdc`
- `/fpga/rtl/adam_riscv_v2_ax7203_top.v`
- `/verification/build_coremark_ax7203.py` 或等价脚本（固定路径、固定参数）
- `/rom/coremark/` CoreMark 移植与链接脚本
- `.sisyphus/evidence/` 下的综合、实现、下载、启动、UART、CoreMark 证据

### Definition of Done (verifiable conditions with commands)
- `vivado -mode batch -source fpga/create_project_ax7203.tcl` 成功创建工程且 part/board 选择正确
- `vivado -mode batch -source fpga/build_ax7203_bitstream.tcl` 生成 bitstream、utilization、timing 报告
- `vivado -mode batch -source fpga/program_ax7203_jtag.tcl` 成功下载并输出硬件管理日志
- `vivado -mode batch -source fpga/write_ax7203_cfgmem.tcl` + `fpga/program_ax7203_flash.tcl` 成功烧写 Flash
- `verification/build_coremark_ax7203.py --target bram` 成功生成 `rom/inst.hex`/`rom/data.hex`
- 板上上电/JTAG 下载后 UART 输出 CoreMark 结果，包含 checksum、iterations、ticks 或 time、CoreMark 或 CoreMark/MHz
- `xc7a200t-2fbg484i` 的 post-route setup/hold 时序签核通过，**0 unconstrained paths**
- `xc7a200tfbg484-3` 生成独立比较报告，且不替代 `-2` 实板签核结论

### Must Have
- 真实板卡 AX7203 的原生 TCL 流，不借用 `cva6_ref` 直接产出
- `-2` 实板器件为主签核目标，`-3` 为次级比较产物
- BRAM-first CoreMark 首次上板成功路径
- UART 串口可观测性与结果采集
- JTAG 与 Flash 两套独立下载/启动证据
- 约束完整：时钟、IOSTANDARD、pin、例外路径、无约束路径检查

### Must NOT Have
- 不得以 synth-only、未约束、错 part、错 package 的结果宣称成功
- 不得把 DDR3/MIG 引入首个 CoreMark 成功定义
- 不得只给 PASS/FAIL 而无 CoreMark 真实分数与 UART 证据
- 不得把 `-3` 结果当作 AX7203 实板签核结论
- 不得直接移植 `cva6_ref` 板级 wrapper/XDC 作为最终文件
- 不得使用“手工目视检查即可”作为验收标准

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: **tests-after**；先建失败检查，再实现，再跑 Vivado/串口/烧录验证
- QA policy: 每个任务都必须给出 agent 可执行的 happy-path 与 failure-path
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`

## Execution Strategy
### Parallel Execution Waves
Wave 1: T1/T2/T3（板卡真值、原生流骨架、观测契约）
Wave 2: T4/T5/T6（board top、XDC、clock/reset/IP）
Wave 3: T7/T8/T10（BRAM 启动、JTAG 下载、UART 观测）
Wave 4: T11/T13（时序收敛、Flash 持久化启动）
Wave 5: T9/T12/T14（CoreMark 构建、BRAM-first 运行、板级测分与 `-3` 比较）

### Dependency Matrix (full, all tasks)
- T1 blocks T2/T4/T5/T6/T11/T13/T14
- T2 blocks T4/T5/T6/T7/T8/T11/T13
- T3 blocks T10/T12/T14
- T4 + T5 + T6 block T7/T8/T10/T11
- T7 blocks T8/T10/T12
- T8 + T10 block T12/T14
- T11 blocks final signoff for `-2`
- T13 blocks final Flash signoff
- T12 blocks T14
- T14 blocks final verification wave

### Agent Dispatch Summary
- Wave 1 → 3 tasks → `explore`, `build`, `doc`
- Wave 2 → 3 tasks → `rtl`, `build`, `verification`
- Wave 3 → 3 tasks → `build`, `rtl`, `tb`
- Wave 4 → 2 tasks → `build`, `verification`
- Wave 5 → 3 tasks → `build`, `writing`, `unspecified-high`

## TODOs
> Implementation + Test = ONE task. Never separate.
> EVERY task MUST have: Agent Profile + Parallelization + QA Scenarios.

- [ ] 1. Lock AX7203 truth set and dual-part signoff policy

  **What to do**: 以 AX7203 为主对象，固定板卡资源真值表：主时钟 200MHz 差分、USB-UART、JTAG、16MB QSPI、1GB DDR3、用户 LED/按键；同时在计划交付中显式区分 `xc7a200t-2fbg484i`（主签核）和 `xc7a200tfbg484-3`（次级比较）。输出 `fpga/board_manifest_ax7203.md` 或等价板卡清单文件，由后续脚本统一引用。
  **Must NOT do**: 不得把 `-3` 当作实际板卡 truth；不得在未确认前把 DDR 纳入首个里程碑依赖。

  **Recommended Agent Profile**:
  - Category: `doc` — Reason: 需要固化板卡与签核策略文档
  - Skills: `[]` — 不需要额外技能
  - Omitted: `[]` — 无

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: T2,T4,T5,T6,T11,T13,T14 | Blocked By: none

  **References**:
  - Pattern: `fpga/check_jtag.tcl` — 现有 `/fpga` 目录命名风格
  - Pattern: `rtl/adam_riscv_v2.v` — 原生顶层基线
  - External: `https://alinx.com/public/upload/file/AX7203B_UG.pdf` — AX7203 用户手册（时钟/DDR/UART/JTAG）
  - External: `https://www.en.alinx.com/detail/613` — AX7203 产品页

  **Acceptance Criteria**:
  - [ ] 板卡清单中明确列出 `-2` 为主签核、`-3` 为次级比较
  - [ ] 列出时钟/复位/UART/JTAG/QSPI/DDR/LED 资源及后续是否使用

  **QA Scenarios**:
  ```
  Scenario: Board truth set created
    Tool: Bash
    Steps: verify planned manifest file exists and contains AX7203, XC7A200T-2FBG484I, XC7A200TFBG484-3, 200MHz, UART, JTAG, QSPI
    Expected: all required identifiers are present
    Evidence: .sisyphus/evidence/task-1-board-truth.txt

  Scenario: Wrong-part ambiguity rejected
    Tool: Bash
    Steps: search manifest for any statement treating -3 as primary board signoff target
    Expected: no such statement exists
    Evidence: .sisyphus/evidence/task-1-board-truth-error.txt
  ```

  **Commit**: YES | Message: `docs(fpga): lock ax7203 board truth and part policy` | Files: `fpga/board_manifest_ax7203.md`

- [ ] 2. Create native AX7203 Vivado TCL flow under `/fpga`

  **What to do**: 建立原生 TCL 骨架：`create_project_ax7203.tcl`、`build_ax7203_bitstream.tcl`、`report_ax7203_timing.tcl`、`program_ax7203_jtag.tcl`、`write_ax7203_cfgmem.tcl`、`program_ax7203_flash.tcl`、`reboot_ax7203_after_flash.tcl`。统一输出目录到 `build/ax7203/`，并将 part 选择参数化为 `BOARD_PART_PRIMARY=xc7a200t-2fbg484i`、`COMPARE_PART=xc7a200tfbg484-3`。
  **Must NOT do**: 不得复用 `cva6_ref` TCL 直接作为最终脚本；不得把编程与综合混在同一脚本里。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: 纯构建/工具流搭建
  - Skills: [`verilog-lint`] — 便于最终脚本流带上 RTL 语法门禁
  - Omitted: `[]` — 无

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: T4,T5,T6,T7,T8,T11,T13 | Blocked By: T1

  **References**:
  - Pattern: `fpga/example.tcl` — 原生下载脚本入口风格
  - Pattern: `fpga/check_jtag.tcl` — 硬件管理 TCL 风格
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/run.tcl` — Vivado batch 流结构模板
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/program.tcl` — JTAG 编程模板
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/write_cfgmem.tcl` — Flash/cfgmem 模板

  **Acceptance Criteria**:
  - [ ] `/fpga` 下新增 7 个原生 TCL 脚本，职责分离清晰
  - [ ] `build/ax7203/` 作为唯一产物目录
  - [ ] 主/次 part 参数可切换，默认主签核为 `-2`

  **QA Scenarios**:
  ```
  Scenario: TCL skeleton lint
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/hello.tcl and parse environment; then syntax-check each new TCL with vivado -mode tcl -source <script> -notrace -nolog -nojournal where applicable
    Expected: scripts parse without TCL syntax errors
    Evidence: .sisyphus/evidence/task-2-tcl-syntax.log

  Scenario: Wrong output directory prevented
    Tool: Bash
    Steps: grep new TCLs for any output path not under build/ax7203
    Expected: no foreign output directories found
    Evidence: .sisyphus/evidence/task-2-tcl-output-check.txt
  ```

  **Commit**: YES | Message: `build(fpga): add native ax7203 vivado tcl flow` | Files: `/fpga/*.tcl`

- [ ] 3. Define hardware observability contract before bring-up

  **What to do**: 固定首个板级 bring-up 的最小可观测集：UART 串口、1 个 heartbeat LED、1 个 boot-status LED、必要时可选 ILA 钩子但不纳入首个 DoD。规定 UART 波特率、串口参数、日志头格式、CoreMark 结果行格式。
  **Must NOT do**: 不得把 ILA 作为首个成功前置条件；不得只保留 TUBE/LED 而没有 UART 结果输出。

  **Recommended Agent Profile**:
  - Category: `doc` — Reason: 先固化验证契约
  - Skills: `[]` — 无
  - Omitted: `[]` — 无

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: T10,T12,T14 | Blocked By: none

  **References**:
  - Pattern: `rtl/mem_subsys.v` — 现有 TUBE/MMIO 成功信号思路
  - Pattern: `comp_test/test_content.sv` — 现有 PASS/FAIL 判定思路
  - External: `AX7203B_UG.pdf` — 板载 USB-UART 与 LED/KEY 资源

  **Acceptance Criteria**:
  - [ ] 文档中明确 UART 参数（建议 115200 8N1）
  - [ ] 文档中明确 heartbeat/boot-status 语义
  - [ ] 文档中明确 CoreMark 结果行格式模板

  **QA Scenarios**:
  ```
  Scenario: Observability contract complete
    Tool: Bash
    Steps: verify contract file contains UART baud, LED semantics, CoreMark result line format
    Expected: all three observability items present
    Evidence: .sisyphus/evidence/task-3-observability.txt

  Scenario: UART-only score path enforced
    Tool: Bash
    Steps: search contract for any statement allowing score signoff without UART
    Expected: no such statement exists
    Evidence: .sisyphus/evidence/task-3-observability-error.txt
  ```

  **Commit**: YES | Message: `docs(fpga): define ax7203 observability contract` | Files: `fpga/board_manifest_ax7203.md` or dedicated doc

- [ ] 4. Create AX7203-native FPGA top wrapper

  **What to do**: 新建 `fpga/rtl/adam_riscv_v2_ax7203_top.v`，以 `rtl/adam_riscv_v2.v` 为核内基线，只暴露首阶段必须引脚：200MHz 差分时钟、复位、UART TX/RX、2 个用户 LED、JTAG/Flash 所需专用配置路径依赖。保留 DDR3 端口占位策略但不接入首个里程碑。
  **Must NOT do**: 不得直接把 `rtl/adam_riscv_v2.v` 当作板级顶层；不得在首阶段引入 DDR MIG 接口。

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: 顶层封装与管脚导出
  - Skills: [`verilog-lint`] — 保证 wrapper 语法正确
  - Omitted: `[]` — 无

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: T7,T8,T10,T11,T13 | Blocked By: T1,T2

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v` — 当前核顶层
  - Pattern: `rtl/syn_rst.v` — reset sync 逻辑
  - Pattern: `cva6_ref/corev_apu/fpga/src/ariane_xilinx.sv` — FPGA wrapper 结构模板
  - Pattern: `docs/interface_reference.md` — 端口参考

  **Acceptance Criteria**:
  - [ ] 新 wrapper 为 Vivado 工程唯一顶层
  - [ ] 仅导出首阶段所需 IO
  - [ ] DDR 相关逻辑不影响 BRAM-first 路径

  **QA Scenarios**:
  ```
  Scenario: Wrapper compiles with core
    Tool: Bash
    Steps: run iverilog -tnull -Wall rtl/*.v fpga/rtl/adam_riscv_v2_ax7203_top.v
    Expected: compile succeeds without syntax errors
    Evidence: .sisyphus/evidence/task-4-wrapper-compile.log

  Scenario: DDR not pulled into first milestone
    Tool: Bash
    Steps: grep wrapper for MIG/DDR instantiation enable path in default BRAM-first build
    Expected: no active DDR instantiation in primary build path
    Evidence: .sisyphus/evidence/task-4-wrapper-ddr-check.txt
  ```

  **Commit**: YES | Message: `feat(fpga): add ax7203 board wrapper top` | Files: `fpga/rtl/adam_riscv_v2_ax7203_top.v`

- [ ] 5. Author initial AX7203 XDC set

  **What to do**: 编写 `fpga/constraints/ax7203_base.xdc` 与 `fpga/constraints/ax7203_uart_led.xdc`。内容至少包括：200MHz 差分时钟引脚、create_clock、reset pin + IOSTANDARD、UART pin + IOSTANDARD、LED pin + IOSTANDARD、未用端口处理策略。对 AX7203 常见 pin 名（SYS_CLK_P/N 等）做显式绑定。
  **Must NOT do**: 不得留下 unconstrained primary clocks；不得把参考板 XDC 直接复制后不筛选。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: 约束与实现工具相关
  - Skills: `[]` — 无
  - Omitted: `[]` — 无

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: T7,T8,T11,T13 | Blocked By: T1,T2

  **References**:
  - External: `AX7203B_UG.pdf` — 200MHz differential clock and board I/O
  - Pattern: `cva6_ref/corev_apu/fpga/constraints/genesys-2.xdc` — XDC 组织方式模板
  - Pattern: `cva6_ref/corev_apu/fpga/constraints/kc705.xdc` — clock/UART/LED 约束风格参考

  **Acceptance Criteria**:
  - [ ] 两个 XDC 文件创建完成并被 build TCL 引用
  - [ ] 时钟、UART、LED、reset 全部有 pin 与 IOSTANDARD
  - [ ] `report_timing_summary` 中 unconstrained paths 为 0 才允许后续签核

  **QA Scenarios**:
  ```
  Scenario: Constraints loaded
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/create_project_ax7203.tcl and report loaded constraint files
    Expected: both XDC files are loaded into the project
    Evidence: .sisyphus/evidence/task-5-xdc-load.log

  Scenario: No unconstrained clocks accepted
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/report_ax7203_timing.tcl and inspect unconstrained paths count
    Expected: unconstrained paths count is 0
    Evidence: .sisyphus/evidence/task-5-xdc-unconstrained.rpt
  ```

  **Commit**: YES | Message: `build(fpga): add ax7203 base and uart constraints` | Files: `fpga/constraints/*.xdc`

- [ ] 6. Generate clock/reset IP and deterministic startup path

  **What to do**: 提供 `fpga/ip/create_clk_wiz_ax7203.tcl`，在 `FPGA_MODE` 下满足 `rtl/adam_riscv_v2.v` 对 `clk_wiz_0` 的依赖；将 `syn_rst.v` 与 PLL/MMCM lock 联动，定义 async assert / sync deassert 的板级复位释放顺序。首阶段仅生成 CPU 所需主时钟，不引入额外 generated clock 除非必须。
  **Must NOT do**: 不得依赖手工 GUI 生成 IP；不得让 reset 在 lock 未稳定时释放。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: Vivado IP + clocking
  - Skills: [`verilog-lint`] — 校验与 FPGA_MODE 交互
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: T7,T8,T10,T11,T13 | Blocked By: T1,T2,T4,T5

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v` — `FPGA_MODE` 下 `clk_wiz_0` 依赖
  - Pattern: `rtl/syn_rst.v` — reset 同步
  - Pattern: `cva6_ref/corev_apu/fpga/xilinx/xlnx_clk_gen/tcl/run.tcl` — clock IP TCL 风格

  **Acceptance Criteria**:
  - [ ] `create_clk_wiz_ax7203.tcl` 可在 batch 模式下重建所需 IP
  - [ ] 顶层 build 不依赖手工生成的本地缓存文件
  - [ ] reset deassert 依赖时钟稳定信号

  **QA Scenarios**:
  ```
  Scenario: Clock IP regeneration works
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/ip/create_clk_wiz_ax7203.tcl
    Expected: clock IP is generated without GUI interaction
    Evidence: .sisyphus/evidence/task-6-clk-ip.log

  Scenario: Reset sequencing guarded by lock
    Tool: Bash
    Steps: inspect RTL/netlist references to ensure syn_rst input is gated by pll/mmcm lock in FPGA_MODE path
    Expected: lock-aware reset path exists
    Evidence: .sisyphus/evidence/task-6-reset-check.txt
  ```

  **Commit**: YES | Message: `build(fpga): add ax7203 clock and reset generation` | Files: `fpga/ip/create_clk_wiz_ax7203.tcl`, related RTL glue

- [ ] 7. Stand up BRAM-first FPGA image path

  **What to do**: 定义 FPGA BRAM-first 镜像路径，使 ROM/数据初始化不依赖 DDR。将现有 ELF→`inst.hex`/`data.hex` 流收敛到 FPGA 构建入口，并提供最小 smoke 程序（heartbeat + UART banner + PASS 标记）作为上板前置。
  **Must NOT do**: 不得让首个板测依赖 DDR 控制器；不得沿用仅仿真有效的加载假设而不转成 FPGA 可用初始化方式。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: 软硬件镜像衔接
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: T8,T10,T12 | Blocked By: T2,T4,T5,T6

  **References**:
  - Pattern: `verification/run_all_tests.py` — ELF→hex 流
  - Pattern: `comp_test/run_iverilog_tests.ps1` — 镜像转换细节
  - Pattern: `rom/harvard_link.ld` — 现有链接布局

  **Acceptance Criteria**:
  - [ ] 能从固定命令生成 FPGA 用镜像
  - [ ] smoke 镜像在 JTAG 下载后可驱动 LED/UART/tube 成功路径

  **QA Scenarios**:
  ```
  Scenario: BRAM image generation
    Tool: Bash
    Steps: run the chosen core image build command and verify inst.hex/data.hex timestamps update
    Expected: both hex files are generated successfully
    Evidence: .sisyphus/evidence/task-7-bram-build.log

  Scenario: DDR dependency absent
    Tool: Bash
    Steps: inspect primary FPGA build flow for DDR/MIG dependency when --target bram is selected
    Expected: no DDR requirement in BRAM-first path
    Evidence: .sisyphus/evidence/task-7-bram-ddr-check.txt
  ```

  **Commit**: YES | Message: `build(fpga): add bram-first image flow for ax7203` | Files: image build scripts/linker glue

- [ ] 8. Prove JTAG programming and board smoke bring-up

  **What to do**: 基于 `program_ax7203_jtag.tcl` 完成硬件发现、下载、启动 smoke 镜像，并输出硬件管理日志。成功标准是设备识别、bit 下载成功、UART banner 或 LED heartbeat 进入稳定状态。
  **Must NOT do**: 不得只证明 JTAG 枚举而不证明 bitstream actually loaded；不得跳过 smoke 镜像直接跑 CoreMark。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: JTAG 下载与硬件管理
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: T10,T12,T13,T14 | Blocked By: T4,T5,T6,T7

  **References**:
  - Pattern: `fpga/check_jtag.tcl` — JTAG 检测
  - Pattern: `fpga/example.tcl` — 编程脚本风格
  - Pattern: `vivado.log` — 现有 batch 调用痕迹

  **Acceptance Criteria**:
  - [ ] 硬件管理日志中出现正确 FPGA 识别
  - [ ] JTAG 下载成功日志落盘
  - [ ] smoke 镜像输出可观测证据（UART 或 LED 状态）

  **QA Scenarios**:
  ```
  Scenario: JTAG program success
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/program_ax7203_jtag.tcl
    Expected: hardware target found and bitstream programmed successfully
    Evidence: .sisyphus/evidence/task-8-jtag.log

  Scenario: No-device failure path
    Tool: Bash
    Steps: run the same script with cable disconnected or using mock no-target branch handling
    Expected: script exits non-zero with explicit 'no hw target/device' message
    Evidence: .sisyphus/evidence/task-8-jtag-error.log
  ```

  **Commit**: YES | Message: `build(fpga): add ax7203 jtag programming proof flow` | Files: `fpga/program_ax7203_jtag.tcl`

- [ ] 9. Port CoreMark into repo with BRAM-first build flow

  **What to do**: 引入 CoreMark 源码与最小 platform port，固定目录为 `rom/coremark/`，固定构建入口为 `verification/build_coremark_ax7203.py --target bram`。实现启动代码、链接布局、计时源读取、UART 输出格式、完成后 checksum/score 输出，并保留 TUBE PASS 作为辅助终止机制。
  **Must NOT do**: 不得只打印 PASS/FAIL；不得不输出 checksum；不得依赖主机侧人工计算 score。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: benchmark 构建与镜像生成
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 5 | Blocks: T12,T14 | Blocked By: T3,T7

  **References**:
  - Pattern: `rom/harvard_link.ld` — 现有链接布局基线
  - Pattern: `verification/run_all_tests.py` — 工具链与镜像转换方式
  - Pattern: `rom/p2_mmio.inc` — TUBE MMIO 定义
  - External: CoreMark 官方代码/移植说明（实施时固定具体版本）

  **Acceptance Criteria**:
  - [ ] `verification/build_coremark_ax7203.py --target bram` 成功生成镜像
  - [ ] UART 输出包含：benchmark start、iterations、ticks/time、checksum、score 或 CoreMark/MHz
  - [ ] TUBE PASS 仅在 checksum/score 输出后触发

  **QA Scenarios**:
  ```
  Scenario: CoreMark build succeeds
    Tool: Bash
    Steps: run python verification/build_coremark_ax7203.py --target bram
    Expected: inst.hex and data.hex for coremark are generated
    Evidence: .sisyphus/evidence/task-9-coremark-build.log

  Scenario: Incomplete UART output rejected
    Tool: Bash
    Steps: parse captured UART log against required keys: iterations, checksum, score
    Expected: missing any key causes failure
    Evidence: .sisyphus/evidence/task-9-coremark-uart-keys.txt
  ```

  **Commit**: YES | Message: `feat(coremark): add ax7203 bram-first coremark port` | Files: `rom/coremark/*`, `verification/build_coremark_ax7203.py`

- [ ] 10. Implement UART board observability on AX7203

  **What to do**: 在板级 wrapper 中接入 UART，并定义与 CoreMark/runtime 共用的输出 API。首个 smoke 程序输出固定 banner，CoreMark 输出固定结果格式。串口设置固定为 115200 8N1，主机采集命令固定写入计划。
  **Must NOT do**: 不得把 UART 仅用于 debug 临时 print；不得让 smoke 与 CoreMark 使用不同日志格式约定。

  **Recommended Agent Profile**:
  - Category: `rtl` — Reason: 板级串口逻辑与 top 连接
  - Skills: [`verilog-lint`] — 语法门禁
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 3 | Blocks: T12,T14 | Blocked By: T3,T4,T5,T6,T8

  **References**:
  - External: `AX7203B_UG.pdf` — USB-UART 资源
  - Pattern: `rtl/adam_riscv_v2.v` — 顶层集成方式
  - Pattern: `rtl/mem_subsys.v` — MMIO 结果路径可复用

  **Acceptance Criteria**:
  - [ ] 串口在 smoke 镜像与 CoreMark 镜像上均可输出
  - [ ] 主机采集命令固定，例如串口工具脚本或 Python 串口脚本

  **QA Scenarios**:
  ```
  Scenario: UART smoke banner
    Tool: Bash
    Steps: program smoke image, start serial capture at 115200 8N1, wait for banner
    Expected: exact banner string appears within timeout
    Evidence: .sisyphus/evidence/task-10-uart-banner.log

  Scenario: Baud mismatch failure
    Tool: Bash
    Steps: intentionally capture with wrong baud in failure test harness
    Expected: parse step rejects garbled output
    Evidence: .sisyphus/evidence/task-10-uart-error.log
  ```

  **Commit**: YES | Message: `feat(fpga): add ax7203 uart observability path` | Files: UART RTL/top glue/host capture script

- [ ] 11. Close timing for AX7203 real-board `-2` target

  **What to do**: 以 `xc7a200t-2fbg484i` 为唯一主签核对象，跑 synth/place/route，检查 utilization、clock interaction、timing summary、failing endpoints、unconstrained paths。若失败，仅基于报告做定向修复（约束、pipeline、fanout、placement hints），直到 setup/hold 均过关。
  **Must NOT do**: 不得接受 `-3` 通过来替代 `-2`；不得通过忽略 unconstrained paths 或滥加 false path 伪造成功。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: 综合/实现/时序收敛
  - Skills: [`verilog-lint`] — 每轮变更后 RTL 健康检查
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 4 | Blocks: T14 | Blocked By: T1,T2,T4,T5,T6

  **References**:
  - Pattern: `rtl/adam_riscv_v2.v` — CPU 长路径主要来源
  - Pattern: `rtl/scoreboard_v2.v` — 可能的关键组合路径之一
  - Pattern: `rtl/rob_lite.v` — 可能的关键组合路径之一
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/run.tcl` — 报告输出结构参考

  **Acceptance Criteria**:
  - [ ] setup WNS >= 0
  - [ ] hold WNS >= 0
  - [ ] unconstrained paths = 0
  - [ ] failing endpoints = 0
  - [ ] utilization 报告与 timing 报告归档

  **QA Scenarios**:
  ```
  Scenario: Primary timing signoff
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/build_ax7203_bitstream.tcl then fpga/report_ax7203_timing.tcl
    Expected: reports show non-negative setup/hold and zero unconstrained paths
    Evidence: .sisyphus/evidence/task-11-timing-primary.rpt

  Scenario: False-success rejection
    Tool: Bash
    Steps: parse timing reports for 'Unconstrained Paths' and 'Failing Endpoints'
    Expected: any non-zero value causes task failure
    Evidence: .sisyphus/evidence/task-11-timing-guard.txt
  ```

  **Commit**: YES | Message: `fix(fpga): close timing for ax7203 -2 target` | Files: targeted RTL/XDC/TCL deltas only

- [ ] 12. Run BRAM-first CoreMark on board and capture UART score

  **What to do**: 下载 CoreMark BRAM-first 镜像到板上，执行 benchmark，采集 UART 全日志，提取 checksum、iterations、ticks/time、CoreMark、CoreMark/MHz、所用频率、commit id。将结果固化为文本证据与 README/报告更新输入。
  **Must NOT do**: 不得只报告单个 score 数字；不得缺少 checksum；不得缺少频率上下文。

  **Recommended Agent Profile**:
  - Category: `unspecified-high` — Reason: 板测 + 结果采集 + 证据整理
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: NO | Wave 5 | Blocks: T14 | Blocked By: T7,T8,T9,T10

  **References**:
  - Pattern: `verification/build_coremark_ax7203.py` — 镜像构建入口
  - Pattern: `fpga/program_ax7203_jtag.tcl` — 下载入口
  - Pattern: observability contract — UART 输出格式契约

  **Acceptance Criteria**:
  - [ ] UART 日志完整落盘
  - [ ] 日志中出现 checksum、iterations、ticks/time、CoreMark 或 CoreMark/MHz
  - [ ] score 提取脚本可重复解析日志

  **QA Scenarios**:
  ```
  Scenario: CoreMark board run
    Tool: Bash
    Steps: build coremark bram image, program via JTAG, start serial capture, wait for full result block, parse required fields
    Expected: all required fields present and parse succeeds
    Evidence: .sisyphus/evidence/task-12-coremark-board.log

  Scenario: Incomplete benchmark rejected
    Tool: Bash
    Steps: parse a truncated UART capture
    Expected: parser exits non-zero and marks run invalid
    Evidence: .sisyphus/evidence/task-12-coremark-board-error.log
  ```

  **Commit**: YES | Message: `test(fpga): capture ax7203 bram-first coremark result` | Files: result parser/capture docs as needed

- [ ] 13. Prove QSPI/Flash persistent boot flow

  **What to do**: 使用 `write_ax7203_cfgmem.tcl` 生成 cfgmem/bin/mcs，使用 `program_ax7203_flash.tcl` 烧写 QSPI，并提供 `reboot_ax7203_after_flash.tcl` 作为**agent 可执行**的重配置/重启入口，随后验证 smoke 或 CoreMark 镜像可自主启动。首个持久化验证可先用 smoke，再升级到 CoreMark。
  **Must NOT do**: 不得把 JTAG 下载成功当作 Flash 启动成功；不得缺少掉电重启证据。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: cfgmem/Flash 工具流
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 4 | Blocks: T14 | Blocked By: T1,T2,T4,T5,T6,T7,T8

  **References**:
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/write_cfgmem.tcl` — cfgmem 流参考
  - Pattern: `cva6_ref/corev_apu/fpga/scripts/program.tcl` — programming 流参考
  - External: AX7203 QSPI 规格（16MB）

  **Acceptance Criteria**:
  - [ ] cfgmem 文件生成成功
  - [ ] Flash 烧写日志成功
  - [ ] `reboot_ax7203_after_flash.tcl` 可由 agent 调用并触发非 JTAG 镜像启动验证
  - [ ] 重启后可看到 smoke/UART 证据

  **QA Scenarios**:
  ```
  Scenario: Flash programming success
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/write_ax7203_cfgmem.tcl, then fpga/program_ax7203_flash.tcl
    Expected: cfgmem generated and flash programming succeeds
    Evidence: .sisyphus/evidence/task-13-flash.log

  Scenario: Flash boot proof
    Tool: Bash
    Steps: run vivado -mode batch -source fpga/reboot_ax7203_after_flash.tcl, then capture UART/LED smoke evidence without re-running JTAG download script
    Expected: board boots from Flash image and emits expected smoke output
    Evidence: .sisyphus/evidence/task-13-flashboot.log
  ```

  **Commit**: YES | Message: `build(fpga): add ax7203 qspi flash boot flow` | Files: cfgmem/program flash scripts

- [ ] 14. Build comparative `-3` implementation report without replacing `-2` signoff

  **What to do**: 以 `xc7a200tfbg484-3` 运行同一原生流程，生成单独 utilization/timing 对比报告，明确标注“仅比较，不代表 AX7203 实板签核”。将频率余量、资源利用与 `-2` 对照归档。
  **Must NOT do**: 不得把 `-3` bitstream 用于宣称 AX7203 实板成功；不得省略与 `-2` 的差异说明。

  **Recommended Agent Profile**:
  - Category: `build` — Reason: 次级目标实现对比
  - Skills: `[]`
  - Omitted: `[]`

  **Parallelization**: Can Parallel: YES | Wave 5 | Blocks: none | Blocked By: T1,T2,T4,T5,T6

  **References**:
  - Pattern: `fpga/build_ax7203_bitstream.tcl` — 主流程复用
  - Pattern: board manifest — `-2` / `-3` 角色定义

  **Acceptance Criteria**:
  - [ ] 生成独立 `-3` timing/utilization 报告
  - [ ] 报告中显式写明其仅为比较目标
  - [ ] 最终摘要仍以 `-2` 为主签核

  **QA Scenarios**:
  ```
  Scenario: Comparative build report
    Tool: Bash
    Steps: run primary build script with compare part parameter set to xc7a200tfbg484-3
    Expected: separate reports for -3 are generated
    Evidence: .sisyphus/evidence/task-14-compare-part.rpt

  Scenario: Primary signoff not overwritten
    Tool: Bash
    Steps: inspect final summary/report bundle for statements claiming -3 as board signoff target
    Expected: no such statement exists
    Evidence: .sisyphus/evidence/task-14-compare-guard.txt
  ```

  **Commit**: YES | Message: `build(fpga): add comparative -3 implementation reports` | Files: report scripts/docs only

## Final Verification Wave (MANDATORY — after ALL implementation tasks)
> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.
> **Do NOT auto-proceed after verification. Wait for user's explicit approval before marking work complete.**
> **Never mark F1-F4 as checked before getting user's okay.** Rejection or user feedback -> fix -> re-run -> present again -> wait for okay.
- [ ] F1. Plan Compliance Audit — oracle
- [ ] F2. Code Quality Review — unspecified-high
- [ ] F3. Real Manual QA — unspecified-high (+ UART capture / Vivado hardware-manager evidence)
- [ ] F4. Scope Fidelity Check — deep

## Commit Strategy
- `docs(fpga): lock ax7203 board truth and part policy`
- `build(fpga): add native ax7203 vivado tcl flow`
- `docs(fpga): define ax7203 observability contract`
- `feat(fpga): add ax7203 board wrapper top`
- `build(fpga): add ax7203 base and uart constraints`
- `build(fpga): add ax7203 clock and reset generation`
- `build(fpga): add bram-first image flow for ax7203`
- `build(fpga): add ax7203 jtag programming proof flow`
- `feat(coremark): add ax7203 bram-first coremark port`
- `feat(fpga): add ax7203 uart observability path`
- `fix(fpga): close timing for ax7203 -2 target`
- `test(fpga): capture ax7203 bram-first coremark result`
- `build(fpga): add ax7203 qspi flash boot flow`
- `build(fpga): add comparative -3 implementation reports`

## Success Criteria
- AX7203 原生 Vivado 流可从零生成工程、综合、实现、报告、bitstream、cfgmem
- `xc7a200t-2fbg484i` 达成主签核：0 unconstrained、0 failing endpoints、setup/hold 通过
- JTAG 下载与 Flash 持久化启动均有独立证据
- BRAM-first CoreMark 在板上通过 UART 输出完整 benchmark 结果块
- `xc7a200tfbg484-3` 仅生成次级比较报告，不污染主签核结论
