# Interface Reference

本文档按 `module/CORE/RTL_V1_2/*.v` 的当前代码生成，逐条列出模块端口。

- 位宽 `1` 表示单比特。
- 说明列按端口命名语义给出，详细行为请结合实现代码。

## Module Index

- [`adam_riscv`](#adam_riscv)
- [`syn_rst`](#syn_rst)
- [`pc`](#pc)
- [`stage_if`](#stage_if)
- [`inst_memory`](#inst_memory)
- [`reg_if_id`](#reg_if_id)
- [`stage_is`](#stage_is)
- [`scoreboard`](#scoreboard)
- [`reg_is_ro`](#reg_is_ro)
- [`stage_ro`](#stage_ro)
- [`regs`](#regs)
- [`reg_ro_ex`](#reg_ro_ex)
- [`stage_ex`](#stage_ex)
- [`alu_control`](#alu_control)
- [`alu`](#alu)
- [`reg_ex_stage`](#reg_ex_stage)
- [`reg_ex_mem`](#reg_ex_mem)
- [`stage_mem`](#stage_mem)
- [`data_memory`](#data_memory)
- [`reg_mem_wb`](#reg_mem_wb)
- [`stage_wb`](#stage_wb)
- [`stage_id`](#stage_id)
- [`reg_id_ex`](#reg_id_ex)
- [`hazard_detection`](#hazard_detection)
- [`forwarding`](#forwarding)
- [`imm_gen`](#imm_gen)
- [`ctrl`](#ctrl)

## `adam_riscv`

- File: `module\CORE\RTL_V1_2\adam_riscv.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `sys_clk` | `input` | `1` | 时钟输入 |
| `led` | `output` | `[2:0]` | 板级LED输出 |
| `sys_rstn` | `input` | `1` | 复位相关信号 |

## `syn_rst`

- File: `module\CORE\RTL_V1_2\syn_rst.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clock` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `syn_rstn` | `output` | `1` | 复位相关信号 |

## `pc`

- File: `module\CORE\RTL_V1_2\pc.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `br_ctrl` | `input` | `1` | 分支跳转生效标志 |
| `br_addr` | `input` | `[31:0]` | 分支目标地址 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `pc_o` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `pc_stall` | `input` | `1` | 暂停/阻塞控制 |

## `stage_if`

- File: `module\CORE\RTL_V1_2\stage_if.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `pc_stall` | `input` | `1` | 暂停/阻塞控制 |
| `if_flush` | `input` | `1` | 冲刷控制 |
| `br_addr` | `input` | `[31:0]` | 分支目标地址 |
| `br_ctrl` | `input` | `1` | 分支跳转生效标志 |
| `if_inst` | `output` | `[31:0]` | 指令字或指令地址 |
| `if_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |

## `inst_memory`

- File: `module\CORE\RTL_V1_2\inst_memory.v`
- Parameters: `IROM_SPACE`=4096

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `inst_addr` | `input` | `[31:0]` | 指令字或指令地址 |
| `inst_o` | `output` | `[31:0]` | 指令字或指令地址 |

## `reg_if_id`

- File: `module\CORE\RTL_V1_2\reg_if_id.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `if_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `if_inst` | `input` | `[31:0]` | 指令字或指令地址 |
| `id_inst` | `output` | `[31:0]` | 指令字或指令地址 |
| `id_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `if_id_flush` | `input` | `1` | 冲刷控制 |
| `if_id_stall` | `input` | `1` | 暂停/阻塞控制 |

## `stage_is`

- File: `module\CORE\RTL_V1_2\stage_is.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `is_inst` | `input` | `[31:0]` | 指令字或指令地址 |
| `is_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `is_pc_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `is_imm` | `output` | `[31:0]` | 立即数通路 |
| `is_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `is_func7_code` | `output` | `1` | ALU控制相关字段 |
| `is_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `is_br` | `output` | `1` | 输出端口（语义按命名） |
| `is_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `is_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `is_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `is_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `is_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `is_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `is_br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `is_regs_write` | `output` | `1` | 寄存器写回使能 |
| `is_rs1` | `output` | `[4:0]` | 源寄存器编号 |
| `is_rs2` | `output` | `[4:0]` | 源寄存器编号 |
| `is_rs1_used` | `output` | `1` | 输出端口（语义按命名） |
| `is_rs2_used` | `output` | `1` | 输出端口（语义按命名） |
| `is_fu` | `output` | `[2:0]` | 功能单元编号 |
| `is_valid` | `output` | `1` | 输出端口（语义按命名） |

## `scoreboard`

- File: `module\CORE\RTL_V1_2\scoreboard.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `flush` | `input` | `1` | 冲刷控制 |
| `is_push` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `is_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `is_imm` | `input` | `[31:0]` | 立即数通路 |
| `is_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `is_func7_code` | `input` | `1` | ALU控制相关字段 |
| `is_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `is_br` | `input` | `1` | 输入端口（语义按命名） |
| `is_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `is_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `is_alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `is_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `is_alu_src1` | `input` | `[1:0]` | ALU操作数选择控制 |
| `is_alu_src2` | `input` | `[1:0]` | ALU操作数选择控制 |
| `is_br_addr_mode` | `input` | `1` | 输入端口（语义按命名） |
| `is_regs_write` | `input` | `1` | 寄存器写回使能 |
| `is_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `is_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `is_rs1_used` | `input` | `1` | 输入端口（语义按命名） |
| `is_rs2_used` | `input` | `1` | 输入端口（语义按命名） |
| `is_fu` | `input` | `[2:0]` | 功能单元编号 |
| `rs_full` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_valid` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `ro_issue_imm` | `output` | `[31:0]` | 立即数通路 |
| `ro_issue_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `ro_issue_func7_code` | `output` | `1` | ALU控制相关字段 |
| `ro_issue_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `ro_issue_br` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `ro_issue_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `ro_issue_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `ro_issue_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `ro_issue_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ro_issue_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ro_issue_br_addr_mode` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_regs_write` | `output` | `1` | 寄存器写回使能 |
| `ro_issue_rs1` | `output` | `[4:0]` | 源寄存器编号 |
| `ro_issue_rs2` | `output` | `[4:0]` | 源寄存器编号 |
| `ro_issue_rs1_used` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_rs2_used` | `output` | `1` | Scoreboard发射/入队接口信号 |
| `ro_issue_fu` | `output` | `[2:0]` | 功能单元编号 |
| `ro_issue_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `wb_fu` | `input` | `[2:0]` | 功能单元编号 |
| `wb_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `wb_regs_write` | `input` | `1` | 寄存器写回使能 |
| `wb_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `reg_is_ro`

- File: `module\CORE\RTL_V1_2\reg_is_ro.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `flush` | `input` | `1` | 冲刷控制 |
| `issue_en` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `ro_fire` | `input` | `1` | 流水寄存器装载/消费握手 |
| `issue_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `issue_imm` | `input` | `[31:0]` | 立即数通路 |
| `issue_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `issue_func7_code` | `input` | `1` | ALU控制相关字段 |
| `issue_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `issue_br` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `issue_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `issue_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `issue_alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `issue_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `issue_alu_src1` | `input` | `[1:0]` | ALU操作数选择控制 |
| `issue_alu_src2` | `input` | `[1:0]` | ALU操作数选择控制 |
| `issue_br_addr_mode` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `issue_regs_write` | `input` | `1` | 寄存器写回使能 |
| `issue_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `issue_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `issue_rs1_used` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `issue_rs2_used` | `input` | `1` | Scoreboard发射/入队接口信号 |
| `issue_fu` | `input` | `[2:0]` | 功能单元编号 |
| `issue_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `ro_valid` | `output` | `1` | 输出端口（语义按命名） |
| `ro_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `ro_imm` | `output` | `[31:0]` | 立即数通路 |
| `ro_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `ro_func7_code` | `output` | `1` | ALU控制相关字段 |
| `ro_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `ro_br` | `output` | `1` | 输出端口（语义按命名） |
| `ro_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `ro_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `ro_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `ro_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `ro_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ro_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ro_br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `ro_regs_write` | `output` | `1` | 寄存器写回使能 |
| `ro_rs1` | `output` | `[4:0]` | 源寄存器编号 |
| `ro_rs2` | `output` | `[4:0]` | 源寄存器编号 |
| `ro_rs1_used` | `output` | `1` | 输出端口（语义按命名） |
| `ro_rs2_used` | `output` | `1` | 输出端口（语义按命名） |
| `ro_fu` | `output` | `[2:0]` | 功能单元编号 |
| `ro_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `stage_ro`

- File: `module\CORE\RTL_V1_2\stage_ro.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `ro_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `ro_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `w_regs_en` | `input` | `1` | 寄存器写回使能 |
| `w_regs_addr` | `input` | `[4:0]` | 目的寄存器编号 |
| `w_regs_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_regs_data1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |

## `regs`

- File: `module\CORE\RTL_V1_2\regs.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `r_regs_addr1` | `input` | `[4:0]` | 源寄存器编号 |
| `r_regs_addr2` | `input` | `[4:0]` | 源寄存器编号 |
| `w_regs_addr` | `input` | `[4:0]` | 目的寄存器编号 |
| `w_regs_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `w_regs_en` | `input` | `1` | 寄存器写回使能 |
| `r_regs_o1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `r_regs_o2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |

## `reg_ro_ex`

- File: `module\CORE\RTL_V1_2\reg_ro_ex.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `flush` | `input` | `1` | 冲刷控制 |
| `ro_fire` | `input` | `1` | 流水寄存器装载/消费握手 |
| `ro_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `ro_regs_data1` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_imm` | `input` | `[31:0]` | 立即数通路 |
| `ro_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `ro_func7_code` | `input` | `1` | ALU控制相关字段 |
| `ro_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `ro_br` | `input` | `1` | 输入端口（语义按命名） |
| `ro_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `ro_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `ro_alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `ro_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `ro_alu_src1` | `input` | `[1:0]` | ALU操作数选择控制 |
| `ro_alu_src2` | `input` | `[1:0]` | ALU操作数选择控制 |
| `ro_br_addr_mode` | `input` | `1` | 输入端口（语义按命名） |
| `ro_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ro_fu` | `input` | `[2:0]` | 功能单元编号 |
| `ro_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `ex_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `ex_regs_data1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_imm` | `output` | `[31:0]` | 立即数通路 |
| `ex_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `ex_func7_code` | `output` | `1` | ALU控制相关字段 |
| `ex_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `ex_br` | `output` | `1` | 输出端口（语义按命名） |
| `ex_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `ex_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `ex_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `ex_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `ex_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ex_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ex_br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `ex_regs_write` | `output` | `1` | 寄存器写回使能 |
| `ex_fu` | `output` | `[2:0]` | 功能单元编号 |
| `ex_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `stage_ex`

- File: `module\CORE\RTL_V1_2\stage_ex.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `ex_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `ex_regs_data1` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_imm` | `input` | `[31:0]` | 立即数通路 |
| `ex_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `ex_func7_code` | `input` | `1` | ALU控制相关字段 |
| `ex_alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `ex_alu_src1` | `input` | `[1:0]` | ALU操作数选择控制 |
| `ex_alu_src2` | `input` | `[1:0]` | ALU操作数选择控制 |
| `ex_br_addr_mode` | `input` | `1` | 输入端口（语义按命名） |
| `ex_br` | `input` | `1` | 输入端口（语义按命名） |
| `ex_alu_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `ex_regs_data2_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `br_pc` | `output` | `[31:0]` | 分支目标地址 |
| `br_ctrl` | `output` | `1` | 分支跳转生效标志 |

## `alu_control`

- File: `module\CORE\RTL_V1_2\alu_control.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `func7_code` | `input` | `1` | ALU控制相关字段 |
| `alu_ctrl_r` | `output` | `[3:0]` | ALU控制相关字段 |

## `alu`

- File: `module\CORE\RTL_V1_2\alu.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `alu_ctrl` | `input` | `[3:0]` | ALU控制相关字段 |
| `op_A` | `input` | `[31:0]` | ALU输入操作数 |
| `op_B` | `input` | `[31:0]` | ALU输入操作数 |
| `alu_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `br_mark` | `output` | `1` | 分支判断结果 |

## `reg_ex_stage`

- File: `module\CORE\RTL_V1_2\reg_ex_stage.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `in_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `in_alu_o` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `in_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `in_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `in_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `in_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `in_regs_write` | `input` | `1` | 寄存器写回使能 |
| `in_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `in_fu` | `input` | `[2:0]` | 功能单元编号 |
| `in_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `out_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `out_alu_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `out_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `out_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `out_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `out_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `out_regs_write` | `output` | `1` | 寄存器写回使能 |
| `out_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `out_fu` | `output` | `[2:0]` | 功能单元编号 |
| `out_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `reg_ex_mem`

- File: `module\CORE\RTL_V1_2\reg_ex_mem.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `ex_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_alu_o` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `ex_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `ex_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `ex_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `ex_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `ex_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ex_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `ex_fu` | `input` | `[2:0]` | 功能单元编号 |
| `ex_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `ex_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `me_rs2` | `output` | `[4:0]` | 源寄存器编号 |
| `me_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `me_alu_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `me_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `me_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `me_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `me_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `me_regs_write` | `output` | `1` | 寄存器写回使能 |
| `me_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `me_fu` | `output` | `[2:0]` | 功能单元编号 |
| `me_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `stage_mem`

- File: `module\CORE\RTL_V1_2\stage_mem.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `me_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `me_alu_o` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `me_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `me_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `me_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `forward_data` | `input` | `1` | 旁路/转发相关信号 |
| `w_regs_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `me_led` | `output` | `[2:0]` | 输出端口（语义按命名） |
| `me_mem_data` | `output` | `[31:0]` | 寄存器/存储器数据通路 |

## `data_memory`

- File: `module\CORE\RTL_V1_2\data_memory.v`
- Parameters: `RAM_SPACE`=4096

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `addr_mem` | `input` | `[31:0]` | 存储器地址信号 |
| `w_data_mem` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `w_en_mem` | `input` | `[ 3:0]` | 存储器字节写使能 |
| `en_mem` | `input` | `1` | 存储器片选/使能 |
| `r_data_mem` | `output` | `[31:0]` | 输出端口（语义按命名） |

## `reg_mem_wb`

- File: `module\CORE\RTL_V1_2\reg_mem_wb.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `me_mem_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `me_alu_o` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `me_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `me_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `me_regs_write` | `input` | `1` | 寄存器写回使能 |
| `me_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `me_fu` | `input` | `[2:0]` | 功能单元编号 |
| `me_sb_tag` | `input` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `wb_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `wb_mem_data` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `wb_alu_o` | `output` | `[31:0]` | 输出端口（语义按命名） |
| `wb_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `wb_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `wb_regs_write` | `output` | `1` | 寄存器写回使能 |
| `wb_fu` | `output` | `[2:0]` | 功能单元编号 |
| `wb_sb_tag` | `output` | `[3:0]` | Scoreboard动态标签（依赖跟踪） |

## `stage_wb`

- File: `module\CORE\RTL_V1_2\stage_wb.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `wb_mem_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `wb_alu_o` | `input` | `[31:0]` | 输入端口（语义按命名） |
| `wb_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `wb_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `w_regs_data` | `output` | `[31:0]` | 寄存器/存储器数据通路 |

## `stage_id`

- File: `module\CORE\RTL_V1_2\stage_id.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `id_inst` | `input` | `[31:0]` | 指令字或指令地址 |
| `w_regs_en` | `input` | `1` | 寄存器写回使能 |
| `w_regs_addr` | `input` | `[4:0]` | 目的寄存器编号 |
| `w_regs_data` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `ctrl_stall` | `input` | `1` | 暂停/阻塞控制 |
| `id_regs_data1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `id_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `id_imm` | `output` | `[31:0]` | 立即数通路 |
| `id_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `id_func7_code` | `output` | `1` | ALU控制相关字段 |
| `id_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `id_br` | `output` | `1` | 输出端口（语义按命名） |
| `id_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `id_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `id_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `id_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `id_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `id_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `id_br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `id_regs_write` | `output` | `1` | 寄存器写回使能 |
| `id_mem_write_forward` | `output` | `1` | 旁路/转发相关信号 |
| `id_rs1` | `output` | `[4:0]` | 源寄存器编号 |
| `id_rs2` | `output` | `[4:0]` | 源寄存器编号 |

## `reg_id_ex`

- File: `module\CORE\RTL_V1_2\reg_id_ex.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `clk` | `input` | `1` | 时钟输入 |
| `rstn` | `input` | `1` | 复位相关信号 |
| `id_pc` | `input` | `[31:0]` | 程序计数器/阶段PC |
| `id_regs_data1` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `id_regs_data2` | `input` | `[31:0]` | 寄存器/存储器数据通路 |
| `id_imm` | `input` | `[31:0]` | 立即数通路 |
| `id_func3_code` | `input` | `[2:0]` | ALU控制相关字段 |
| `id_func7_code` | `input` | `1` | ALU控制相关字段 |
| `id_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `id_br` | `input` | `1` | 输入端口（语义按命名） |
| `id_mem_read` | `input` | `1` | 存储器读使能/控制 |
| `id_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `id_alu_op` | `input` | `[2:0]` | ALU控制相关字段 |
| `id_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `id_alu_src1` | `input` | `[1:0]` | ALU操作数选择控制 |
| `id_alu_src2` | `input` | `[1:0]` | ALU操作数选择控制 |
| `id_br_addr_mode` | `input` | `1` | 输入端口（语义按命名） |
| `id_regs_write` | `input` | `1` | 寄存器写回使能 |
| `id_ex_flush` | `input` | `1` | 冲刷控制 |
| `id_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `id_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `ex_rs1` | `output` | `[4:0]` | 源寄存器编号 |
| `ex_rs2` | `output` | `[4:0]` | 源寄存器编号 |
| `ex_pc` | `output` | `[31:0]` | 程序计数器/阶段PC |
| `ex_regs_data1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ex_imm` | `output` | `[31:0]` | 立即数通路 |
| `ex_func3_code` | `output` | `[2:0]` | ALU控制相关字段 |
| `ex_func7_code` | `output` | `1` | ALU控制相关字段 |
| `ex_rd` | `output` | `[4:0]` | 目的寄存器编号 |
| `ex_br` | `output` | `1` | 输出端口（语义按命名） |
| `ex_mem_read` | `output` | `1` | 存储器读使能/控制 |
| `ex_mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `ex_alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `ex_mem_write` | `output` | `1` | 存储器写使能/控制 |
| `ex_alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ex_alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `ex_br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `ex_regs_write` | `output` | `1` | 寄存器写回使能 |

## `hazard_detection`

- File: `module\CORE\RTL_V1_2\hazard_detection.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `ex1_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ex1_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `ex2_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ex2_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `ex3_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ex3_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `ex4_regs_write` | `input` | `1` | 寄存器写回使能 |
| `ex4_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `me_regs_write` | `input` | `1` | 寄存器写回使能 |
| `me_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `id_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `id_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `br_ctrl` | `input` | `1` | 分支跳转生效标志 |
| `stall` | `output` | `1` | 暂停/阻塞控制 |
| `flush` | `output` | `1` | 冲刷控制 |

## `forwarding`

- File: `module\CORE\RTL_V1_2\forwarding.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `ex_rs1` | `input` | `[4:0]` | 源寄存器编号 |
| `ex_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `me_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `wb_rd` | `input` | `[4:0]` | 目的寄存器编号 |
| `me_rs2` | `input` | `[4:0]` | 源寄存器编号 |
| `me_mem_write` | `input` | `1` | 存储器写使能/控制 |
| `wb_mem2reg` | `input` | `1` | 写回数据来源选择（MEM/ALU） |
| `me_regs_write` | `input` | `1` | 寄存器写回使能 |
| `wb_regs_write` | `input` | `1` | 寄存器写回使能 |
| `forwardA` | `output` | `[1:0]` | 旁路/转发相关信号 |
| `forwardB` | `output` | `[1:0]` | 旁路/转发相关信号 |
| `forward_data` | `output` | `1` | 旁路/转发相关信号 |

## `imm_gen`

- File: `module\CORE\RTL_V1_2\imm_gen.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `inst` | `input` | `[31:0]` | 指令字或指令地址 |
| `imm_o` | `output` | `[31:0]` | 立即数通路 |

## `ctrl`

- File: `module\CORE\RTL_V1_2\ctrl.v`

| Port | Dir | Width | Description |
|---|---|---:|---|
| `inst_op` | `input` | `[6:0]` | 输入端口（语义按命名） |
| `br` | `output` | `1` | 输出端口（语义按命名） |
| `mem_read` | `output` | `1` | 存储器读使能/控制 |
| `mem2reg` | `output` | `1` | 写回数据来源选择（MEM/ALU） |
| `alu_op` | `output` | `[2:0]` | ALU控制相关字段 |
| `mem_write` | `output` | `1` | 存储器写使能/控制 |
| `alu_src1` | `output` | `[1:0]` | ALU操作数选择控制 |
| `alu_src2` | `output` | `[1:0]` | ALU操作数选择控制 |
| `br_addr_mode` | `output` | `1` | 输出端口（语义按命名） |
| `regs_write` | `output` | `1` | 寄存器写回使能 |


