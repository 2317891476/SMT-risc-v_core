# 课程实验 2（Lab 2）实验报告

陈爽：25023176 肖维城： 25023029

## 实验目的

本实验基于一套 **RV32I 五级顺序流水** 处理器 RTL，完成两项核心改造：

1. 将原单拍 **EX** 扩展为 **4 拍执行链路（EX1~EX4）**。
2. 将原 **ID** 拆分为 **IS（Issue）+RO（Read Operands）**，引入记分牌实现操作数就绪驱动下的指令调度。

实验目标是将流水线从 `IF-ID-EX-MEM-WB` 重构为 `IF-IS-RO-EX1-EX2-EX3-EX4-MEM-WB`，并满足实验说明中“无数据旁路、关注数据冲突、支持指定功能部件”的要求。

---

## 实验原理与架构设计

### 1. 需求解读与设计分解

根据 `课程实验2说明.pdf`，关键约束包括：

- EX 站扩展为 4 拍，其中 3 拍仅做打拍。
- 不实现数据旁路，消费者必须等待生产者写回后再获取值。
- 测试重点是数据冲突，不强制分支预测改造。
- 功能部件按 `ADD/SUB/AND/OR/XOR/LW/SW` 7 类管理。
- `ADDI/LUI/AUIPC` 归入 ADD 功能部件。

本项目当前实现采用“**记分牌 + 保留窗口（RS）**”方案：

- IF/IS 正常推进，IS 指令入记分牌窗口。
- 记分牌按“操作数就绪 + FU 空闲 + 年龄最老”选择一条发往 RO。
- RO 仅负责读寄存器并交付 EX。

该方案相比“IS 直接查 FU busy 后停顿”更解耦，吞吐更高。

### 2. 顶层九级流水架构

顶层 `adam_riscv` 已重构为 9 级通路：

- `IF -> IF/IS寄存器(reg_if_id) -> IS(stage_is) -> Scoreboard -> RO寄存器(reg_is_ro) -> RO(stage_ro) -> RO/EX寄存器(reg_ro_ex) -> EX1(stage_ex) -> EX2/EX3/EX4(reg_ex_stage x3) -> MEM -> WB`

关键连接见 `module/CORE/RTL_V1_2/adam_riscv.v:302`、`module/CORE/RTL_V1_2/adam_riscv.v:415`、`module/CORE/RTL_V1_2/adam_riscv.v:440`、`module/CORE/RTL_V1_2/adam_riscv.v:465`。

### 3. 记分牌核心数据结构

`scoreboard` 模块中包含：

- **功能部件状态表**：`fu_busy[1:7]`，见 `module/CORE/RTL_V1_2/scoreboard.v:64`。
- **结果寄存器状态表**：`reg_result_status[31:0]`，见 `module/CORE/RTL_V1_2/scoreboard.v:64`。

> 说明：由于加入保留站机制，会在WAW 冲突中出现“误清零”问题，所以本实现将结果状态编码扩展为 **4-bit 记分牌 Tag**（`sb_tag`），而非实验文档中的 3-bit FU 编码。将结果寄存器状态表（`reg_result_status`）的语义进行了升级：从“寄存器由哪个 FU 生产”改为了“寄存器由哪个动态 `sb_tag` 生产，这样可区分同一 FU 上多条在飞指令，便于保证“最后写者清零”语义。

### 4. IS/RO 职责划分

- **IS（stage_is）**：译码、FU 分类、源操作数使用位生成。
- **Scoreboard**：维护窗口条目、依赖标签 `Qj/Qk/Qd`、选择可发射指令。
- **RO（stage_ro）**：在被选中后读寄存器堆，向 EX1 发射。

其中 `ADDI/LUI/AUIPC` 映射到 ADD 部件（FU=1），见 `module/CORE/RTL_V1_2/stage_is.v:72`、`module/CORE/RTL_V1_2/stage_is.v:83`、`module/CORE/RTL_V1_2/stage_is.v:84`。

---

## 核心代码与实现细节分析

### 1. EX 四拍扩展（任务 1）

#### 1.1 EX1 执行，EX2~EX4 纯打拍

```verilog
// module/CORE/RTL_V1_2/stage_ex.v
assign op_B_pre        = ex_regs_data2;
assign op_A_pre        = ex_regs_data1;
```

上述实现表明 EX1 不再依赖旁路网络，操作数来自 RO/寄存器堆路径。

```verilog
// module/CORE/RTL_V1_2/adam_riscv.v
reg_ex_stage u_reg_ex1_ex2(...);
reg_ex_stage u_reg_ex2_ex3(...);
reg_ex_stage u_reg_ex3_ex4(...);
```

通过三级 `reg_ex_stage` 把 `ALU结果/控制信号/rd/FU/tag` 逐拍传递到 MEM，符合“3 拍仅打拍”要求。

![image-20260227115903214](C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227115903214.png)

#### 1.2 无数据旁路

```verilog
// module/CORE/RTL_V1_2/adam_riscv.v
assign forward_data = 1'b0;
```

```verilog
// module/CORE/RTL_V1_2/stage_ex.v
assign op_B_pre = ex_regs_data2;
assign op_A_pre = ex_regs_data1;
```

此处明确关闭了 ALU 前递与 store-data 前递路径，满足实验“B 等 A 写回后再读”的约束。

### 2. IS + RO + Scoreboard（任务 2）

#### 2.1 功能部件分类与 FU 映射

```verilog
// module/CORE/RTL_V1_2/stage_is.v
`ItypeL: is_fu = 3'd6; // LW
`Stype : is_fu = 3'd7; // SW
`UtypeL: is_fu = 3'd1; // LUI
`UtypeU: is_fu = 3'd1; // AUIPC
```

结合 R/I 类指令分派，实现了实验规定的 7 类功能部件映射，且将 `ADDI/LUI/AUIPC` 归入 ADD（FU=1）。

#### 2.2 功能部件状态表与结果寄存器状态表

```verilog
// module/CORE/RTL_V1_2/scoreboard.v
reg        fu_busy [1:7];
reg [RS_TAG_W-1:0] reg_result_status [31:0];
```

- `fu_busy` 管理 FU 是否被占用。
- `reg_result_status` 记录寄存器最新生产者 tag（增强版实现）。

#### 2.3 发射选择逻辑（RO 选择）

```verilog
// module/CORE/RTL_V1_2/scoreboard.v
if (win_valid[i] && !win_issued[i] && win_ready[i] &&
    (win_fu[i] != 3'd0) && !fu_busy[win_fu[i]]) begin
    ...
    if (!war_block && (!sel_found || (win_seq[i] < sel_seq))) begin
        // select oldest ready
    end
end
```

该逻辑体现三个条件：

1. 操作数就绪（`win_ready`）
2. 对应 FU 空闲（`!fu_busy[win_fu[i]]`）
3. 最老优先（`win_seq` 最小）

并增加了 `war_block` 的保守保护（比实验最低要求更严格）。

> 尽管实验没做要求，为了保证处理器架构的严谨性和鲁棒性，在 `scoreboard.v` 中手动实现了对 WAR 冲突的检测和避免。
>
> 具体逻辑如下：
>
> - 记分牌为每一条入队的指令分配了一个序号（`win_seq`），用来记录指令的“年龄”（序号越小越老）。
> - 当一条写指令（假设为指令 $i$）的操作数已经就绪，准备被选中发射到 RO 站时，记分牌会去扫描窗口里其他还没发射的指令（假设为指令 $j$）。
> - 如果发现指令 $j$ 比指令 $i$ **更老**（`win_seq[j] < win_seq[i]`），并且指令 $j$ 刚好要**读取**指令 $i$ 准备**写入**的那个寄存器，就会立刻拉高 `war_block = 1'b1` 信号。
> - 一旦 `war_block` 被拉高，这条年轻的写指令 $i$ 就**会被剥夺本拍的发射资格**，在窗口里等老指令先发射

#### 2.4 写回更新逻辑（释放 FU + 最后写者清零）

```verilog
// module/CORE/RTL_V1_2/scoreboard.v
if (wb_fu != 3'd0) begin
    fu_busy[wb_fu] <= 1'b0;
end

if (wb_regs_write && (wb_rd != 5'd0) &&
    (wb_sb_tag != 4'd0) &&
    (reg_result_status[wb_rd] == wb_sb_tag)) begin
    reg_result_status[wb_rd] <= {RS_TAG_W{1'b0}};
end
```

该实现严格满足“仅当当前写回者仍是该寄存器最新生产者时，才清空状态”。

### 3. 与实验要求对照

| 实验要求 | 代码实现位置 | 对应说明 |
|---|---|---|
| EX 扩 4 拍 | `adam_riscv.v` 中 3 级 `reg_ex_stage` | EX1 执行 + EX2/3/4 打拍 |
| 无数据旁路 | `stage_ex.v`、`adam_riscv.v` | 操作数直接来自寄存器读路径，前递关闭 |
| ID 拆分 IS/RO | `stage_is.v`、`reg_is_ro.v`、`stage_ro.v`、`reg_ro_ex.v` | IS 译码，RO 读操作数 |
| 7 类 FU 状态管理 | `scoreboard.v` 中 `fu_busy[1:7]` | Index 1~7 对应 ADD..SW |
| 结果寄存器状态 | `scoreboard.v` 中 `reg_result_status[31:0]` | 用 tag 跟踪生产者，增强“最后写者”语义 |
| WB 更新状态表 | `scoreboard.v` 的 `wb_fu/wb_rd/wb_sb_tag` 更新分支 | 释放 FU + 条件清零寄存器状态 |
| ADDI/LUI/AUIPC 在 ADD FU | `stage_is.v` FU 分类逻辑 | 统一映射到 `is_fu=3'd1` |

---


## 测试与仿真结果

### 1. 测试环境与脚本

- Testbench：`comp_test/tb.sv`
- 判分逻辑：`comp_test/test_content.sv`
- 一键脚本：`comp_test/run_iverilog_tests.ps1`
- 汇编用例：`rom/test1.s`、`rom/test2.S`

`tb.sv` 中使用 `inst.hex/data.hex` 初始化指令和数据存储器，见 `comp_test/tb.sv:42`、`comp_test/tb.sv:57`。

### 2. 测试覆盖点

#### 用例 1（`test1.s`）

覆盖 `ADD/SUB/AND/OR/XOR/LW/SW` 基本功能与执行链路。日志中可见 PASS：

- `comp_test/out_iverilog/logs/test1.log:1464`

并且关键寄存器写回符合预期：

- `x7 = 0x00000003`：`comp_test/out_iverilog/logs/test1.log:808`
- `x8 = 0x00000003`：`comp_test/out_iverilog/logs/test1.log:865`
- `x9 = 0xF3F2F1F0`：`comp_test/out_iverilog/logs/test1.log:882`

#### 用例 2（`test2.S`）

用于验证记分牌驱动下的乱序执行。日志中可见 PASS：

- `comp_test/out_iverilog/logs/test2.log:1647`

并可观察到 `or/xor` 的结果先于 `sub/and` 写回：

- `x7 = 0x3f`：`comp_test/out_iverilog/logs/test2.log:939`
- `x8 = 0x3f`：`comp_test/out_iverilog/logs/test2.log:1008`
- `x5 = 0xFFFFFFD6`：`comp_test/out_iverilog/logs/test2.log:1282`
- `x6 = 0x00000015`：`comp_test/out_iverilog/logs/test2.log:1289`

这与实验说明要求的“`or/xor` 先于 `sub/and` 执行”一致。

### 3. 波形与状态观测

#### 3.1 EX 扩 4 拍

观测信号u_adam_riscv.ex1_alu_o/ex2_alu_o/ex3_alu_o/ex4_alu_o如下图所示

![image-20260227121427973](C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227121427973.png)

可以看到延迟4拍才将结果传入MEM模块

#### 3.2 乱序执行

重点观察is_pc，ro_pc，ro_fu,和执行结果alu_o，可以看出is_pc按照顺序正常递增（pc+4），表明按序流出，然后ro_pc乱序递增，表明指令乱序发射执行，ro_fu的100和101分别代表or和xor部件，即表明了main程序段中的or 指令和xor指令先于sub指令和and指令被执行。（限制这二者并行的原因在于保留站数目的限制，即保留站已满，or和上一条nop执行完才能释放保留站给xor和下一次的nop）

![image-20260227132039863](C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227132039863.png)

![image-20260227132527475](C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227132527475.png)

---

## 总结与反思

1. 本次实现已完成实验核心目标：
- 5 级扩展到 9 级流水。
- EX 站改造为 4 拍。
- ID 拆分为 IS/RO，并通过记分牌完成依赖管理与乱序调度。

2. 关键技术难点与解决方法：
- **难点 1：无旁路条件下的依赖解析**
  - 方案：在记分牌中维护 `Qj/Qk/Qd` 标签与 ready 状态，由 WB 广播消除依赖。
- **难点 2：同一寄存器多次重定义的正确清零**
  - 方案：结果状态表使用 `sb_tag` 而非 FU 编码，WB 仅在 tag 匹配时清零。
- **难点 3：调度选择策略稳定性**
  - 方案：采用“最老就绪优先 + FU busy 约束”，提高可解释性与可复现性。

3. 工程化评价：
- 当前实现在实验目标上达成度高，且对“最后写者语义”与乱序鲁棒性做了增强。
- 与实验“最小实现”相比，加入了保留窗口与 tag 化状态，复杂度提升但验证价值更高。

4. 可继续优化方向：
- 将 `run_iverilog_tests.ps1` 的 include 路径与工作目录管理再收敛，确保任意目录启动均可复现。
- 增加对 Scoreboard 关键内部状态的断言与覆盖统计，提升回归可诊断性。

---

## 附录:各模块接口信息

##### 2.1.1 IS模块

<img src="C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227120154413.png" alt="image-20260227120154413" style="zoom:50%;" />

- File: `module\CORE\RTL_V1_2\stage_is.v`

| Port              | Dir      |    Width | Description                 |
| ----------------- | -------- | -------: | --------------------------- |
| `is_inst`         | `input`  | `[31:0]` | 指令字或指令地址            |
| `is_pc`           | `input`  | `[31:0]` | 程序计数器/阶段PC           |
| `is_pc_o`         | `output` | `[31:0]` | 输出端口（语义按命名）      |
| `is_imm`          | `output` | `[31:0]` | 立即数通路                  |
| `is_func3_code`   | `output` |  `[2:0]` | ALU控制相关字段             |
| `is_func7_code`   | `output` |      `1` | ALU控制相关字段             |
| `is_rd`           | `output` |  `[4:0]` | 目的寄存器编号              |
| `is_br`           | `output` |      `1` | 输出端口（语义按命名）      |
| `is_mem_read`     | `output` |      `1` | 存储器读使能/控制           |
| `is_mem2reg`      | `output` |      `1` | 写回数据来源选择（MEM/ALU） |
| `is_alu_op`       | `output` |  `[2:0]` | ALU控制相关字段             |
| `is_mem_write`    | `output` |      `1` | 存储器写使能/控制           |
| `is_alu_src1`     | `output` |  `[1:0]` | ALU操作数选择控制           |
| `is_alu_src2`     | `output` |  `[1:0]` | ALU操作数选择控制           |
| `is_br_addr_mode` | `output` |      `1` | 输出端口（语义按命名）      |
| `is_regs_write`   | `output` |      `1` | 寄存器写回使能              |
| `is_rs1`          | `output` |  `[4:0]` | 源寄存器编号                |
| `is_rs2`          | `output` |  `[4:0]` | 源寄存器编号                |
| `is_rs1_used`     | `output` |      `1` | 输出端口（语义按命名）      |
| `is_rs2_used`     | `output` |      `1` | 输出端口（语义按命名）      |
| `is_fu`           | `output` |  `[2:0]` | 功能单元编号                |
| `is_valid`        | `output` |      `1` | 输出端口（语义按命名）      |

##### 2.1.2 RO模块

<img src="C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227120341039.png" alt="image-20260227120341039" style="zoom:67%;" />

- File: `module\CORE\RTL_V1_2\stage_ro.v`

| Port            | Dir      |    Width | Description           |
| --------------- | -------- | -------: | --------------------- |
| `clk`           | `input`  |      `1` | 时钟输入              |
| `rstn`          | `input`  |      `1` | 复位相关信号          |
| `ro_rs1`        | `input`  |  `[4:0]` | 源寄存器编号          |
| `ro_rs2`        | `input`  |  `[4:0]` | 源寄存器编号          |
| `w_regs_en`     | `input`  |      `1` | 寄存器写回使能        |
| `w_regs_addr`   | `input`  |  `[4:0]` | 目的寄存器编号        |
| `w_regs_data`   | `input`  | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_regs_data1` | `output` | `[31:0]` | 寄存器/存储器数据通路 |
| `ro_regs_data2` | `output` | `[31:0]` | 寄存器/存储器数据通路 |

##### 2.1.3 scoreboad模块

<img src="C:/Users/23178/AppData/Roaming/Typora/typora-user-images/image-20260227120502806.png" alt="image-20260227120502806" style="zoom:50%;" />

- File: `module\CORE\RTL_V1_2\scoreboard.v`

| Port                    | Dir      |    Width | Description                    |
| ----------------------- | -------- | -------: | ------------------------------ |
| `clk`                   | `input`  |      `1` | 时钟输入                       |
| `rstn`                  | `input`  |      `1` | 复位相关信号                   |
| `flush`                 | `input`  |      `1` | 冲刷控制                       |
| `is_push`               | `input`  |      `1` | Scoreboard发射/入队接口信号    |
| `is_pc`                 | `input`  | `[31:0]` | 程序计数器/阶段PC              |
| `is_imm`                | `input`  | `[31:0]` | 立即数通路                     |
| `is_func3_code`         | `input`  |  `[2:0]` | ALU控制相关字段                |
| `is_func7_code`         | `input`  |      `1` | ALU控制相关字段                |
| `is_rd`                 | `input`  |  `[4:0]` | 目的寄存器编号                 |
| `is_br`                 | `input`  |      `1` | 输入端口（语义按命名）         |
| `is_mem_read`           | `input`  |      `1` | 存储器读使能/控制              |
| `is_mem2reg`            | `input`  |      `1` | 写回数据来源选择（MEM/ALU）    |
| `is_alu_op`             | `input`  |  `[2:0]` | ALU控制相关字段                |
| `is_mem_write`          | `input`  |      `1` | 存储器写使能/控制              |
| `is_alu_src1`           | `input`  |  `[1:0]` | ALU操作数选择控制              |
| `is_alu_src2`           | `input`  |  `[1:0]` | ALU操作数选择控制              |
| `is_br_addr_mode`       | `input`  |      `1` | 输入端口（语义按命名）         |
| `is_regs_write`         | `input`  |      `1` | 寄存器写回使能                 |
| `is_rs1`                | `input`  |  `[4:0]` | 源寄存器编号                   |
| `is_rs2`                | `input`  |  `[4:0]` | 源寄存器编号                   |
| `is_rs1_used`           | `input`  |      `1` | 输入端口（语义按命名）         |
| `is_rs2_used`           | `input`  |      `1` | 输入端口（语义按命名）         |
| `is_fu`                 | `input`  |  `[2:0]` | 功能单元编号                   |
| `rs_full`               | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_valid`        | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_pc`           | `output` | `[31:0]` | 程序计数器/阶段PC              |
| `ro_issue_imm`          | `output` | `[31:0]` | 立即数通路                     |
| `ro_issue_func3_code`   | `output` |  `[2:0]` | ALU控制相关字段                |
| `ro_issue_func7_code`   | `output` |      `1` | ALU控制相关字段                |
| `ro_issue_rd`           | `output` |  `[4:0]` | 目的寄存器编号                 |
| `ro_issue_br`           | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_mem_read`     | `output` |      `1` | 存储器读使能/控制              |
| `ro_issue_mem2reg`      | `output` |      `1` | 写回数据来源选择（MEM/ALU）    |
| `ro_issue_alu_op`       | `output` |  `[2:0]` | ALU控制相关字段                |
| `ro_issue_mem_write`    | `output` |      `1` | 存储器写使能/控制              |
| `ro_issue_alu_src1`     | `output` |  `[1:0]` | ALU操作数选择控制              |
| `ro_issue_alu_src2`     | `output` |  `[1:0]` | ALU操作数选择控制              |
| `ro_issue_br_addr_mode` | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_regs_write`   | `output` |      `1` | 寄存器写回使能                 |
| `ro_issue_rs1`          | `output` |  `[4:0]` | 源寄存器编号                   |
| `ro_issue_rs2`          | `output` |  `[4:0]` | 源寄存器编号                   |
| `ro_issue_rs1_used`     | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_rs2_used`     | `output` |      `1` | Scoreboard发射/入队接口信号    |
| `ro_issue_fu`           | `output` |  `[2:0]` | 功能单元编号                   |
| `ro_issue_sb_tag`       | `output` |  `[3:0]` | Scoreboard动态标签（依赖跟踪） |
| `wb_fu`                 | `input`  |  `[2:0]` | 功能单元编号                   |
| `wb_rd`                 | `input`  |  `[4:0]` | 目的寄存器编号                 |
| `wb_regs_write`         | `input`  |      `1` | 寄存器写回使能                 |
| `wb_sb_tag`             | `input`  |  `[3:0]` | Scoreboard动态标签（依赖跟踪） |
