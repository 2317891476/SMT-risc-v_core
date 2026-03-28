# V1管线删除与V2整合计划

## TL;DR

> **目标**: 删除V1管线，整合V2管线为标准版本，去除所有V2标签，统一项目结构
>
> **核心工作**:
> - 删除22个V1专属文件
> - 重命名11个V2文件（去除_v2后缀）
> - 修改6个脚本文件
> - 更新1个README文档
>
> **估算工作量**: 中等（Medium）
> **并行执行**: YES - 4个Wave，最大化并行度
> **关键路径**: Wave 1 → Wave 2 → Wave 3 → Wave 4 → 最终验证

---

## Context

### 原始需求
用户要求删除V1管线，只保留V2管线作为标准版本，并去除所有V2标签。涉及RTL文件重命名、脚本修改、文档更新和仿真流程验证。

### 调研发现
通过三个探索代理的全面分析，项目结构如下：
- **V1专属**: 22个文件（RTL、测试台、配置）- 可安全删除
- **V2专属**: 30个文件 - 需要重命名去除V2标签
- **共用文件**: 23个基础模块 - 必须保留
- **脚本文件**: 6个文件需要修改V2引用
- **文档**: README需要全面更新

### 关键发现
1. V2已完全独立于V1，删除V1不会影响V2功能
2. 共用模块（如regs_mt.v、alu.v等）被V1和V2共用，但V2以不同方式使用
3. 测试脚本`run_basic_tests.sh`已硬编码使用V2，表明V2已是事实上的主线
4. FPGA流程已完全转向V2

---

## Work Objectives

### Core Objective
删除V1管线，将V2管线整合为项目的唯一标准版本，去除所有V2标签，确保仿真、综合、bitstream生成流程正常工作。

### Concrete Deliverables
- [ ] 删除所有V1专属RTL文件（22个）
- [ ] 重命名所有V2专属文件（去除_v2后缀，11个）
- [ ] 更新V2文件内部的模块名和引用
- [ ] 修改仿真脚本（4个）
- [ ] 修改综合/Bitstream脚本（2个）
- [ ] 更新README文档
- [ ] 验证仿真流程通过

### Definition of Done
- [ ] `python verification/run_all_tests.py --basic` 执行成功，所有测试通过
- [ ] 仿真生成的VCD文件正常（`tb.vcd`）
- [ ] README中无V1/V2对比内容，统一描述当前架构
- [ ] git status无未提交的V1文件残留

### Must Have
- [ ] V1文件彻底删除
- [ ] V2文件重命名完成
- [ ] 仿真脚本可用
- [ ] 基础测试通过

### Must NOT Have (Guardrails)
- [ ] 不删除共用模块（如regs_mt.v、alu.v等）
- [ ] 不破坏FPGA综合流程的结构
- [ ] 不修改共用模块的接口（如regs_mt.v的端口定义）
- [ ] 不删除.git历史记录

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES（有Python测试框架和iverilog）
- **Automated tests**: Tests-after（先修改后验证）
- **Framework**: iverilog + vvp + Python测试脚本
- **Agent-Executed QA**: 所有任务必须通过自动化验证，无人工干预

### QA Policy
每个任务必须包含Agent-Executed QA Scenarios，验证方式：
- **RTL/文件操作**: 使用Bash命令验证文件存在/不存在、内容正确
- **脚本修改**: 运行脚本验证功能正常
- **仿真流程**: 运行iverilog编译和vvp仿真
- **文档**: 使用grep验证关键内容已更新

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately - 低风险删除):
├── Task 1: 删除V1 RTL核心文件 [quick]
├── Task 2: 删除V1流水线寄存器 [quick]
├── Task 3: 删除V1控制逻辑文件 [quick]
└── Task 4: 删除V1测试文件 [quick]

Wave 2 (After Wave 1 - V2 RTL重命名):
├── Task 5: 重命名V2核心RTL文件 [quick]
├── Task 6: 更新V2 RTL内部模块名 [quick]
├── Task 7: 处理define文件合并 [quick]
└── Task 8: 更新module_list_v2 → module_list [quick]

Wave 3 (After Wave 2 - 测试文件和脚本):
├── Task 9: 重命名V2测试文件 [quick]
├── Task 10: 更新测试文件内部引用 [quick]
├── Task 11: 修改仿真脚本 run_iverilog_tests.ps1 [unspecified-high]
├── Task 12: 修改仿真脚本 run_basic_tests.sh [quick]
├── Task 13: 修改Python测试脚本 [quick]
└── Task 14: 修改FPGA综合脚本 [quick]

Wave 4 (After Wave 3 - 文档和验证):
├── Task 15: 更新README文档 [writing]
├── Task 16: 验证仿真流程 - 编译测试 [verification]
└── Task 17: 验证仿真流程 - 运行测试 [verification]

Wave FINAL (After ALL tasks - 4 parallel reviews):
├── Task F1: Plan compliance audit [oracle]
├── Task F2: Code quality review [unspecified-high]
├── Task F3: Real manual QA [unspecified-high]
└── Task F4: Scope fidelity check [deep]
-> Present results -> Get explicit user okay

Critical Path: Task 1-4 → Task 5-8 → Task 9-14 → Task 15-17 → F1-F4 → user okay
Parallel Speedup: ~60% faster than sequential
Max Concurrent: 6 (Wave 3)
```

---

## TODOs

### Wave 1: 删除V1专属文件

- [ ] **Task 1: 删除V1核心RTL文件**

  **What to do**:
  - 删除V1顶层模块：`rtl/adam_riscv.v`
  - 删除V1记分牌：`rtl/scoreboard.v`
  - 删除V1取指级：`rtl/stage_if.v`
  - 删除V1指令存储器：`rtl/inst_memory.v`
  - 删除V1译码级：`rtl/stage_id.v`
  - 删除V1读操作数级：`rtl/stage_ro.v`
  - 删除V1执行级：`rtl/stage_ex.v`

  **Must NOT do**:
  - 不要删除共用模块（syn_rst.v, thread_scheduler.v等）
  - 不要删除V2文件（adam_riscv_v2.v等）
  - 不要删除.git目录或修改历史

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Reason**: 纯文件删除操作，低风险
  - **Skills**: `git-master`（用于安全删除和提交）

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1（与Task 2,3,4并行）
  - **Blocks**: Wave 2（V2文件重命名）
  - **Blocked By**: None（可立即开始）

  **References**:
  - `rtl/adam_riscv.v` - V1顶层，有序单发射架构
  - `rtl/adam_riscv_v2.v` - V2顶层（保留）
  - Draft文件中的"V1专属文件"清单

  **Acceptance Criteria**:
  - [ ] `ls rtl/adam_riscv.v` 返回文件不存在
  - [ ] `ls rtl/scoreboard.v` 返回文件不存在
  - [ ] `ls rtl/stage_if.v` 返回文件不存在
  - [ ] `ls rtl/inst_memory.v` 返回文件不存在
  - [ ] `ls rtl/stage_id.v` 返回文件不存在
  - [ ] `ls rtl/stage_ro.v` 返回文件不存在
  - [ ] `ls rtl/stage_ex.v` 返回文件不存在
  - [ ] `git status` 显示这些文件已被删除

  **QA Scenarios**:
  ```
  Scenario: 确认V1核心文件已删除
    Tool: Bash
    Steps:
      1. ls rtl/adam_riscv.v 2>&1 | grep "No such file"
      2. ls rtl/scoreboard.v 2>&1 | grep "No such file"
      3. ls rtl/stage_if.v 2>&1 | grep "No such file"
    Expected Result: 所有命令都返回"No such file or directory"
    Evidence: .sisyphus/evidence/task-1-v1-rtl-deleted.txt
  ```

  **Commit**: YES
  - Message: `refactor(v1): remove V1 core RTL files`
  - Files: 所有删除的7个V1 RTL文件

- [ ] **Task 2: 删除V1流水线寄存器文件**

  **What to do**:
  - 删除：`rtl/reg_if_id.v`
  - 删除：`rtl/reg_id_ex.v`
  - 删除：`rtl/reg_is_ro.v`
  - 删除：`rtl/reg_ro_ex.v`
  - 删除：`rtl/reg_ex_stage.v`
  - 删除：`rtl/reg_ex_mem.v`
  - 删除：`rtl/reg_mem_wb.v`

  **Must NOT do**:
  - 不要误删V2使用的寄存器文件（如有）
  - V2使用不同的寄存器架构，V1的流水线寄存器是V1专属

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 1）
  - **Blocks**: None（这些文件独立）
  - **Blocked By**: None

  **References**:
  - `rtl/reg_*.v` - V1流水线寄存器
  - V2使用ROB和记分牌架构，不使用这些流水线寄存器

  **Acceptance Criteria**:
  - [ ] 所有8个V1流水线寄存器文件被删除
  - [ ] `ls rtl/reg_*.v` 返回空（或使用grep确认不存在）

  **QA Scenarios**:
  ```
  Scenario: 确认流水线寄存器已删除
    Tool: Bash
    Steps:
      1. ls rtl/reg_*.v 2>&1 | wc -l
    Expected Result: 返回0或错误信息
    Evidence: .sisyphus/evidence/task-2-v1-regs-deleted.txt
  ```

  **Commit**: YES（与Task 1一起）

- [ ] **Task 3: 删除V1控制逻辑文件**

  **What to do**:
  - 删除：`rtl/hazard_detection.v` - V1冒险检测
  - 删除：`rtl/forwarding.v` - V1前递网络
  - 删除：`rtl/bypass_network.v` - V1旁路网络（注意：V2也有同名文件，只删V1版本）
  - 删除：`rtl/pc.v` - V1单线程PC（V2使用pc_mt.v）

  **Must NOT do**:
  - **警告**：`rtl/bypass_network.v` 在V1和V2中都有同名文件
  - **验证**：读取文件内容，确认删除的是V1版本（简单实现）
  - V2的bypass_network.v更复杂（3源前递），必须保留
  - 如果无法区分，跳过此文件，在Wave 2中处理

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `verilog-lint`, `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 1）
  - **Blocked By**: None

  **References**:
  - `rtl/bypass_network.v` - 需要检查内容确认版本
  - `rtl/hazard_detection.v` - V1专属
  - `rtl/forwarding.v` - V1专属
  - `rtl/pc.v` - V1专属（V2使用pc_mt.v）

  **Acceptance Criteria**:
  - [ ] hazard_detection.v 已删除
  - [ ] forwarding.v 已删除
  - [ ] pc.v 已删除
  - [ ] bypass_network.v 只有在确认是V1版本时才删除

  **QA Scenarios**:
  ```
  Scenario: 确认V1控制文件已删除（bypass_network谨慎处理）
    Tool: Bash + Read
    Steps:
      1. ls rtl/hazard_detection.v 2>&1 | grep "No such file"
      2. ls rtl/forwarding.v 2>&1 | grep "No such file"
      3. ls rtl/pc.v 2>&1 | grep "No such file"
      4. Read rtl/bypass_network.v | grep -E "3 source|forward|bypass" | head -5
    Expected Result: 前3个命令返回文件不存在；bypass_network内容显示是复杂版本（保留）
    Evidence: .sisyphus/evidence/task-3-v1-ctrl-deleted.txt
  ```

  **Commit**: YES（与Task 1-2一起）

- [ ] **Task 4: 删除V1测试文件**

  **What to do**:
  - 删除：`comp_test/tb.sv` - V1测试台
  - 删除：`comp_test/module_list` - V1模块列表
  - 删除：`comp_test/test_content_v1.sv` - V1测试内容
  - 注意：保留`comp_test/test_content.sv`（V2使用）

  **Must NOT do**:
  - 不要删除`comp_test/tb_v2.sv`（V2测试台，将在Wave 3重命名）
  - 不要删除`comp_test/test_content.sv`（V2使用）
  - 不要删除`comp_test/module_list_v2`（将在Wave 2重命名）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 1）
  - **Blocks**: Wave 3（测试文件重命名）
  - **Blocked By**: None

  **References**:
  - `comp_test/tb.sv` - V1测试台
  - `comp_test/tb_v2.sv` - V2测试台（保留）
  - `comp_test/module_list` - V1模块列表（32个条目）
  - `comp_test/module_list_v2` - V2模块列表（61个条目，保留）

  **Acceptance Criteria**:
  - [ ] tb.sv 已删除
  - [ ] module_list 已删除
  - [ ] test_content_v1.sv 已删除
  - [ ] tb_v2.sv 仍存在
  - [ ] test_content.sv 仍存在
  - [ ] module_list_v2 仍存在

  **QA Scenarios**:
  ```
  Scenario: 确认V1测试文件已删除，V2文件保留
    Tool: Bash
    Steps:
      1. ls comp_test/tb.sv 2>&1 | grep "No such file"
      2. ls comp_test/module_list 2>&1 | grep "No such file"
      3. ls comp_test/test_content_v1.sv 2>&1 | grep "No such file"
      4. ls comp_test/tb_v2.sv | grep "tb_v2.sv"
      5. ls comp_test/module_list_v2 | grep "module_list_v2"
    Expected Result: 前3个返回不存在，后2个返回存在
    Evidence: .sisyphus/evidence/task-4-v1-test-deleted.txt
  ```

  **Commit**: YES（与Task 1-3一起，作为单个Wave 1提交）

### Wave 2: V2 RTL文件重命名

- [ ] **Task 5: 重命名V2核心RTL文件**

  **What to do**:
  - 重命名：`rtl/adam_riscv_v2.v` → `rtl/adam_riscv.v`
  - 重命名：`rtl/stage_if_v2.v` → `rtl/stage_if.v`
  - 重命名：`rtl/inst_memory_v2.v` → `rtl/inst_memory.v`
  - 重命名：`rtl/scoreboard_v2.v` → `rtl/scoreboard.v`
  - 注意：使用git mv保持历史记录

  **Must NOT do**:
  - 不要直接删除后新建（会丢失git历史）
  - 不要修改文件内容（只重命名）
  - 不要重命名共用文件（如define.v）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 2）
  - **Blocks**: Task 6（更新内部模块名）
  - **Blocked By**: Wave 1（V1文件删除完成）

  **References**:
  - `rtl/adam_riscv_v2.v` - V2顶层模块
  - `rtl/stage_if_v2.v` - V2取指级
  - `rtl/inst_memory_v2.v` - V2指令存储器
  - `rtl/scoreboard_v2.v` - V2记分牌

  **Acceptance Criteria**:
  - [ ] `ls rtl/adam_riscv.v` 存在
  - [ ] `ls rtl/adam_riscv_v2.v` 不存在
  - [ ] `ls rtl/stage_if.v` 存在
  - [ ] `ls rtl/inst_memory.v` 存在
  - [ ] `ls rtl/scoreboard.v` 存在
  - [ ] `git status` 显示rename操作

  **QA Scenarios**:
  ```
  Scenario: 确认核心RTL文件已重命名
    Tool: Bash
    Steps:
      1. ls rtl/adam_riscv.v && echo "NEW EXISTS"
      2. ls rtl/adam_riscv_v2.v 2>&1 | grep "No such file"
      3. git status --short | grep "renamed" | wc -l
    Expected Result: 新文件存在，旧文件不存在，git显示rename状态
    Evidence: .sisyphus/evidence/task-5-rtl-renamed.txt
  ```

  **Commit**: YES
  - Message: `refactor(v2): rename core V2 RTL files`

- [ ] **Task 6: 更新V2 RTL文件内部模块名**

  **What to do**:
  对于每个重命名的文件，更新内部的module声明和实例化引用：
  
  1. **adam_riscv_v2.v → adam_riscv.v**:
     - 修改：`module adam_riscv_v2` → `module adam_riscv`
     - 修改：所有内部实例化的模块名（如有_self引用）
  
  2. **stage_if_v2.v → stage_if.v**:
     - 修改：`module stage_if_v2` → `module stage_if`
  
  3. **inst_memory_v2.v → inst_memory.v**:
     - 修改：`module inst_memory_v2` → `module inst_memory`
  
  4. **scoreboard_v2.v → scoreboard.v**:
     - 修改：`module scoreboard_v2` → `module scoreboard`

  **Must NOT do**:
  - 不要修改模块的端口定义（保持接口兼容）
  - 不要修改内部逻辑（只改模块名）
  - 不要修改注释中的V2说明（除非明确是模块名引用）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `verilog-lint`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 2）
  - **Blocks**: Task 8（更新module_list）
  - **Blocked By**: Task 5（文件重命名）

  **References**:
  - `rtl/adam_riscv_v2.v` 第20行左右: `module adam_riscv_v2`
  - `rtl/stage_if_v2.v` - module声明
  - `rtl/inst_memory_v2.v` - module声明
  - `rtl/scoreboard_v2.v` - module声明

  **Acceptance Criteria**:
  - [ ] `grep "module adam_riscv_v2" rtl/adam_riscv.v` 返回空
  - [ ] `grep "module adam_riscv" rtl/adam_riscv.v` 返回匹配
  - [ ] 同理检查其他3个文件

  **QA Scenarios**:
  ```
  Scenario: 确认模块名已更新
    Tool: Bash (grep)
    Steps:
      1. grep "^module adam_riscv_v2" rtl/adam_riscv.v || echo "OLD NAME NOT FOUND - GOOD"
      2. grep "^module adam_riscv[^_]" rtl/adam_riscv.v && echo "NEW NAME FOUND - GOOD"
      3. grep "^module stage_if_v2" rtl/stage_if.v || echo "NOT FOUND"
      4. grep "^module scoreboard_v2" rtl/scoreboard.v || echo "NOT FOUND"
    Expected Result: 旧模块名不存在，新模块名存在
    Evidence: .sisyphus/evidence/task-6-module-names-updated.txt
  ```

  **Commit**: YES（可与Task 5合并或单独提交）

- [ ] **Task 7: 处理define文件**

  **What to do**:
  - **方案A（推荐）**：合并define_v2.v到define.v
    - 读取`define_v2.v`的内容
    - 将V2特有的宏定义追加到`define.v`
    - 删除`define_v2.v`
    - 更新所有引用`define_v2.v`的文件改为引用`define.v`
  
  - **方案B**：保留define_v2.v但重命名
    - 如果合并风险大，可保留为`define_ext.v`
    - 更新引用路径

  **Must NOT do**:
  - 不要修改define.v中现有的宏定义（保持V1兼容的宏）
  - 不要删除define.v中的任何内容
  - 确保宏定义不冲突

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `verilog-lint`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 2）
  - **Blocked By**: None（在Wave 2内独立）

  **References**:
  - `rtl/define.v` - 基础宏定义
  - `rtl/define_v2.v` - V2扩展定义（包含define.v）
  - `rtl/adam_riscv_v2.v` - 引用define_v2.v

  **Acceptance Criteria**:
  - [ ] define_v2.v中的V2特有宏已转移到define.v
  - [ ] define_v2.v已删除（或重命名）
  - [ ] define.v仍然存在且包含原有内容
  - [ ] `grep "define_v2" rtl/*.v` 返回空（无残留引用）

  **QA Scenarios**:
  ```
  Scenario: 确认define文件处理完成
    Tool: Bash (grep + ls)
    Steps:
      1. grep -l "include.*define_v2" rtl/*.v 2>/dev/null | wc -l
      2. ls rtl/define_v2.v 2>&1 | grep "No such file"
      3. grep "V2_SPECIFIC_MACRO" rtl/define.v &>/dev/null && echo "V2 macros merged"
    Expected Result: 无文件引用define_v2，define_v2.v不存在，define.v包含V2宏
    Evidence: .sisyphus/evidence/task-7-define-merged.txt
  ```

  **Commit**: YES

- [ ] **Task 8: 更新module_list_v2文件**

  **What to do**:
  1. 读取`comp_test/module_list_v2`
  2. 更新所有`_v2`后缀的引用：
     - `adam_riscv_v2.v` → `adam_riscv.v`
     - `stage_if_v2.v` → `stage_if.v`
     - `inst_memory_v2.v` → `inst_memory.v`
     - `scoreboard_v2.v` → `scoreboard.v`
  3. 如果define_v2.v已处理，更新引用
  4. 将文件重命名为`module_list`（替换原V1的module_list）

  **Must NOT do**:
  - 不要修改模块的顺序（可能影响编译依赖）
  - 不要添加或删除模块条目（只改路径）
  - 不要修改相对路径结构

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 2）
  - **Blocks**: Wave 3（测试文件使用module_list）
  - **Blocked By**: Task 5-7（RTL文件和define处理完成）

  **References**:
  - `comp_test/module_list_v2` - 第5行: `../rtl/adam_riscv_v2.v`
  - `comp_test/module_list` - 原V1模块列表（已删除）

  **Acceptance Criteria**:
  - [ ] module_list_v2已重命名为module_list
  - [ ] 文件中无_v2后缀引用
  - [ ] 文件包含61个模块条目（与原来相同）
  - [ ] 路径正确指向重命名后的RTL文件

  **QA Scenarios**:
  ```
  Scenario: 确认module_list已更新
    Tool: Bash (cat + grep)
    Steps:
      1. ls comp_test/module_list | grep "module_list$"
      2. ls comp_test/module_list_v2 2>&1 | grep "No such file"
      3. grep "_v2\.v" comp_test/module_list | wc -l
      4. grep "adam_riscv\.v" comp_test/module_list &>/dev/null && echo "OK"
    Expected Result: module_list存在，module_list_v2不存在，无_v2引用，有标准名称
    Evidence: .sisyphus/evidence/task-8-module-list-updated.txt
  ```

  **Commit**: YES
  - Message: `refactor(v2): update module list for unified pipeline`

### Wave 3: 测试文件重命名和脚本修改

- [ ] **Task 9: 重命名V2测试文件**

  **What to do**:
  - 重命名：`comp_test/tb_v2.sv` → `comp_test/tb.sv`
  - 重命名：`comp_test/tb_v2_debug.sv` → `comp_test/tb_debug.sv`
  - 使用git mv保持历史

  **Must NOT do**:
  - 不要修改文件内容（只重命名）
  - 不要删除原V1的tb.sv（已在Wave 1删除）
  - 确保test_content.sv保留（V2使用）

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `git-master`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）
  - **Blocks**: Task 10（更新测试文件内部引用）
  - **Blocked By**: Wave 2（RTL文件重命名完成）

  **References**:
  - `comp_test/tb_v2.sv` - V2测试台
  - `comp_test/tb_v2_debug.sv` - V2调试测试台

  **Acceptance Criteria**:
  - [ ] `ls comp_test/tb.sv` 存在
  - [ ] `ls comp_test/tb_v2.sv` 不存在
  - [ ] `ls comp_test/tb_debug.sv` 存在
  - [ ] `ls comp_test/tb_v2_debug.sv` 不存在

  **QA Scenarios**:
  ```
  Scenario: 确认测试文件已重命名
    Tool: Bash
    Steps:
      1. ls comp_test/tb.sv && echo "tb.sv exists"
      2. ls comp_test/tb_v2.sv 2>&1 | grep "No such file"
      3. ls comp_test/tb_debug.sv && echo "tb_debug.sv exists"
    Expected Result: 新文件存在，旧文件不存在
    Evidence: .sisyphus/evidence/task-9-testbench-renamed.txt
  ```

  **Commit**: YES

- [ ] **Task 10: 更新测试文件内部引用**

  **What to do**:
  1. **tb.sv**（原tb_v2.sv）：
     - 修改：`module tb_v2` → `module tb`
     - 修改：`adam_riscv_v2 u_adam_riscv_v2` → `adam_riscv u_adam_riscv`
     - 修改：`$dumpfile("tb_v2.vcd")` → `$dumpfile("tb.vcd")`
     - 修改：`define TB_IROM tb_v2.u_adam_riscv_v2` → `define TB_IROM tb.u_adam_riscv`
  
  2. **tb_debug.sv**（原tb_v2_debug.sv）：
     - 类似修改：模块名、实例化名、VCD文件名

  **Must NOT do**:
  - 不要修改测试逻辑或检查点
  - 不要修改时钟周期等时序参数
  - 不要修改`test_content.sv`的引用

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `verilog-lint`

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）
  - **Blocked By**: Task 9（文件重命名）

  **References**:
  - `comp_test/tb_v2.sv` 第28行: `module tb_v2`
  - `comp_test/tb_v2.sv` 第40行: `adam_riscv_v2 u_adam_riscv_v2`
  - `comp_test/tb_v2.sv` 第49行: `$dumpfile("tb_v2.vcd")`

  **Acceptance Criteria**:
  - [ ] tb.sv中无`tb_v2`字符串
  - [ ] tb.sv中无`adam_riscv_v2`字符串
  - [ ] tb.sv中无`tb_v2.vcd`字符串
  - [ ] tb_debug.sv同样检查通过

  **QA Scenarios**:
  ```
  Scenario: 确认测试文件内部引用已更新
    Tool: Bash (grep)
    Steps:
      1. grep "tb_v2\|adam_riscv_v2" comp_test/tb.sv | wc -l
      2. grep "^module tb[^_]" comp_test/tb.sv &>/dev/null && echo "Module name OK"
      3. grep "tb\.vcd" comp_test/tb.sv &>/dev/null && echo "VCD name OK"
    Expected Result: grep计数为0，模块名和VCD名已更新
    Evidence: .sisyphus/evidence/task-10-testbench-content-updated.txt
  ```

  **Commit**: YES（可与Task 9合并）

- [ ] **Task 11: 修改PowerShell仿真脚本 run_iverilog_tests.ps1**

  **What to do**:
  这个脚本需要大量修改，主要变更点：
  
  1. **移除V1/V2流程切换**（第4-5行）：
     - 原：`[ValidateSet("V1", "V2")] [string]$Flow = "V2"`
     - 改为：直接定义单一流程参数
  
  2. **更新路径**（第140-152行）：
     - `TestbenchPath = "tb_v2.sv"` → `"tb.sv"`
     - `ModuleListPath = "module_list_v2"` → `"module_list"`
     - `TopModule = "tb_v2"` → `"tb"`
     - `TmpVcdPath = "tb_v2.vcd"` → `"tb.vcd"`
  
  3. **更新匹配字符串**（第306、309行）：
     - `"V2 case PASS"` → `"This case is pass"`
     - `"V2 case FAILED"` → `"This case is failed"`
  
  4. **移除V1 case块**（第132-139行）：
     - 删除整个V1配置块

  **Must NOT do**:
  - 不要修改测试逻辑本身（如何编译、如何运行）
  - 不要修改输出格式（只修改匹配字符串）
  - 不要删除DryRun等实用功能

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`（需要仔细分析PowerShell脚本）
  - **Skills**: 无（通用脚本修改）

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）
  - **Blocked By**: Task 8-10（module_list和testbench就绪）

  **References**:
  - `comp_test/run_iverilog_tests.ps1` - 完整脚本
  - Draft中的"V2引用详情"部分

  **Acceptance Criteria**:
  - [ ] 脚本语法正确（PowerShell解析无错误）
  - [ ] 无V1流程相关代码
  - [ ] 路径指向重命名后的文件
  - [ ] 匹配字符串已更新

  **QA Scenarios**:
  ```
  Scenario: 确认PowerShell脚本已更新
    Tool: Bash (grep + 可选PowerShell语法检查)
    Steps:
      1. grep -i "ValidateSet.*V1" comp_test/run_iverilog_tests.ps1 | wc -l
      2. grep "tb_v2\.sv\|module_list_v2" comp_test/run_iverilog_tests.ps1 | wc -l
      3. grep "tb_v2\.vcd" comp_test/run_iverilog_tests.ps1 | wc -l
      4. grep "V2 case PASS" comp_test/run_iverilog_tests.ps1 | wc -l
    Expected Result: 所有计数为0
    Evidence: .sisyphus/evidence/task-11-ps-script-updated.txt
  ```

  **Commit**: YES
  - Message: `refactor(scripts): update PowerShell simulation script`

- [ ] **Task 12: 修改Shell测试脚本 run_basic_tests.sh**

  **What to do**:
  1. 修改输出字符串（第9行）：
     - `"Running all Basic Tests (V2)"` → `"Running all Basic Tests"`
  
  2. 更新仿真输出文件名（第17行，重复14次）：
     - `out_iverilog/bin/tb_v2_test.out` → `out_iverilog/bin/tb_test.out`

  **Must NOT do**:
  - 不要修改测试逻辑（vvp命令、参数）
  - 不要修改测试选择逻辑

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）

  **References**:
  - `run_basic_tests.sh` - Shell脚本

  **Acceptance Criteria**:
  - [ ] 输出字符串无"(V2)"
  - [ ] 仿真文件名指向tb_test.out

  **QA Scenarios**:
  ```
  Scenario: 确认Shell脚本已更新
    Tool: Bash (grep)
    Steps:
      1. grep "Running all Basic Tests (V2)" run_basic_tests.sh | wc -l
      2. grep "tb_v2_test\.out" run_basic_tests.sh | wc -l
      3. grep "tb_test\.out" run_basic_tests.sh | wc -l
    Expected Result: 前两个为0，最后一个>0
    Evidence: .sisyphus/evidence/task-12-sh-script-updated.txt
  ```

  **Commit**: YES（可与Task 11合并）

- [ ] **Task 13: 修改Python测试脚本**

  **What to do**:
  修改两个Python脚本：
  
  1. **verification/run_all_tests.py**（第154、161行）：
     - `-s tb_v2 -o out_iverilog/bin/tb_v2_test.out` → `-s tb -o out_iverilog/bin/tb_test.out`
     - `vvp out_iverilog/bin/tb_v2_test.out` → `vvp out_iverilog/bin/tb_test.out`
  
  2. **verification/run_riscv_tests.py**（多处）：
     - 第3行：注释 `"AdamRiscv V2"` → `"AdamRiscv"`
     - 第271行：`"Run the V2 simulation"` → `"Run the simulation"`
     - 第273-275行：编译命令中的`tb_v2`和`tb_v2_riscv_test.out`
     - 第283行：vvp命令中的`tb_v2_riscv_test.out`
     - 第424行：argparse description中的`V2`

  **Must NOT do**:
  - 不要修改Python逻辑（测试选择、结果解析）
  - 不要修改riscv-arch-test第三方代码

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）

  **References**:
  - `verification/run_all_tests.py`
  - `verification/run_riscv_tests.py`

  **Acceptance Criteria**:
  - [ ] 两个脚本中无`tb_v2`引用
  - [ ] 两个脚本中无`AdamRiscv V2`字符串（除了历史记录）
  - [ ] Python语法正确

  **QA Scenarios**:
  ```
  Scenario: 确认Python脚本已更新
    Tool: Bash (grep + python语法检查)
    Steps:
      1. grep "tb_v2" verification/run_all_tests.py | wc -l
      2. grep "tb_v2" verification/run_riscv_tests.py | wc -l
      3. python -m py_compile verification/run_all_tests.py && echo "Syntax OK"
    Expected Result: grep计数为0，语法检查通过
    Evidence: .sisyphus/evidence/task-13-python-scripts-updated.txt
  ```

  **Commit**: YES
  - Message: `refactor(scripts): update Python test scripts`

- [ ] **Task 14: 修改FPGA综合脚本**

  **What to do**:
  修改FPGA相关TCL脚本：
  
  1. **fpga/create_project_ax7203.tcl**（第180行）：
     - `set_property top adam_riscv_v2_ax7203_top` → `adam_riscv_ax7203_top`
     - 第157行注释更新（如有V2提及）
  
  2. **fpga/program_ax7203_jtag.tcl**（第15行）：
     - `adam_riscv_v2_ax7203_top.bit` → `adam_riscv_ax7203_top.bit`
  
  3. **检查**：`fpga/build_ax7203_bitstream.tcl` 是否需要修改
  
  4. **重命名**：`fpga/rtl/adam_riscv_v2_ax7203_top.v` → `adam_riscv_ax7203_top.v`
     - 更新文件内部的module名

  **Must NOT do**:
  - 不要修改IP核配置（clk_wiz等）
  - 不要修改约束文件
  - 不要修改BRAM初始化

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: YES（Wave 3）
  - **Blocked By**: Task 5（RTL文件重命名）

  **References**:
  - `fpga/create_project_ax7203.tcl`
  - `fpga/program_ax7203_jtag.tcl`
  - `fpga/rtl/adam_riscv_v2_ax7203_top.v`

  **Acceptance Criteria**:
  - [ ] FPGA顶层文件已重命名
  - [ ] TCL脚本中的模块名和文件名已更新
  - [ ] 无`adam_riscv_v2`引用

  **QA Scenarios**:
  ```
  Scenario: 确认FPGA脚本已更新
    Tool: Bash (grep + ls)
    Steps:
      1. ls fpga/rtl/adam_riscv_ax7203_top.v && echo "File renamed"
      2. grep "adam_riscv_v2" fpga/*.tcl | wc -l
      3. grep "adam_riscv_ax7203_top" fpga/create_project_ax7203.tcl | wc -l
    Expected Result: 文件存在，tcl脚本无v2引用，有新模块名
    Evidence: .sisyphus/evidence/task-14-fpga-scripts-updated.txt
  ```

  **Commit**: YES
  - Message: `refactor(fpga): update synthesis scripts for unified pipeline`

### Wave 4: 文档更新和验证

- [ ] **Task 15: 更新README文档**

  **What to do**:
  全面更新`README.md`，删除所有V1/V2对比内容：
  
  1. **删除架构对比表**（第518-534行）：
     - 删除整个V1 vs V2对比表格
     - 保留当前架构的描述
  
  2. **更新文件列表**（第94-122行）：
     - `adam_riscv_v2.v` → `adam_riscv.v`
     - 删除所有`# ★ V2`等标签
     - 统一描述为当前架构
  
  3. **更新章节标题**（第162行）：
     - `## 4. V2 模块详解` → `## 4. 模块详解`
  
  4. **更新模块名引用**（第177行等）：
     - `scoreboard_v2` → `scoreboard`
     - 其他_v2后缀的模块名
  
  5. **更新使用说明**（第356、397行）：
     - 删除`(V2 管线)`等标签
     - 统一为"仿真"、"测试"
  
  6. **删除或更新FAQ**（第614-615行）：
     - Q3: V1和V2可以并存吗? → 删除或更新为历史说明
  
  7. **更新测试对比表**（第706-715行）：
     - 删除V1/V2对比列
     - 只保留当前架构的测试结果

  **Must NOT do**:
  - 不要删除技术细节（架构描述、模块功能）
  - 不要删除性能数据
  - 不要删除使用说明（只删除V1相关）
  - 不要修改项目介绍和特性列表

  **Recommended Agent Profile**:
  - **Category**: `writing`
  - **Skills**: 无

  **Parallelization**:
  - **Can Run In Parallel**: NO（必须在所有文件修改完成后）
  - **Blocked By**: Wave 1-3（所有文件和脚本修改完成）

  **References**:
  - `README.md` - 主文档
  - Draft中的"V2引用详情 - README"部分

  **Acceptance Criteria**:
  - [ ] 无`V1 vs V2`或`V1 和 V2`对比
  - [ ] 无`# ★ V2`等标签
  - [ ] 文件列表中的模块名已更新
  - [ ] 文档整体通顺，描述统一架构

  **QA Scenarios**:
  ```
  Scenario: 确认README已更新
    Tool: Bash (grep)
    Steps:
      1. grep -i "v1 vs v2\|v1 和 v2\|V1 and V2" README.md | wc -l
      2. grep "# ★ V2" README.md | wc -l
      3. grep "adam_riscv_v2\.v" README.md | wc -l
      4. grep "scoreboard_v2" README.md | wc -l
    Expected Result: 所有计数为0
    Evidence: .sisyphus/evidence/task-15-readme-updated.txt
  ```

  **Commit**: YES
  - Message: `docs(readme): update documentation for unified architecture`

- [ ] **Task 16: 验证仿真流程 - 编译阶段**

  **What to do**:
  运行仿真编译，验证所有文件路径正确：
  
  1. 运行Python测试脚本的编译阶段：
     ```bash
     python verification/run_all_tests.py --basic --compile-only
     ```
     或手动运行iverilog：
     ```bash
     cd comp_test
     iverilog -f module_list -s tb -o out_iverilog/bin/tb_test.out
     ```
  
  2. 检查编译输出：
     - 无"file not found"错误
     - 无"module not found"错误
     - 生成tb_test.out文件

  **Must NOT do**:
  - 如果编译失败，不要继续到Task 17
  - 不要跳过错误（记录并修复）

  **Recommended Agent Profile**:
  - **Category**: `verification`
  - **Skills**: `verilog-lint`

  **Parallelization**:
  - **Can Run In Parallel**: NO（顺序验证）
  - **Blocked By**: Wave 1-3（所有修改完成）
  - **Blocks**: Task 17（运行测试）

  **References**:
  - `verification/run_all_tests.py`
  - `comp_test/module_list`

  **Acceptance Criteria**:
  - [ ] iverilog编译成功（返回码0）
  - [ ] 生成`out_iverilog/bin/tb_test.out`
  - [ ] 无文件/模块未找到错误

  **QA Scenarios**:
  ```
  Scenario: 验证仿真编译成功
    Tool: Bash
    Preconditions: 在comp_test目录
    Steps:
      1. iverilog -f module_list -s tb -o out_iverilog/bin/tb_test.out 2>&1
      2. echo $?  # 检查返回码
      3. ls -la out_iverilog/bin/tb_test.out
    Expected Result: 返回码0，文件存在且大小>0
    Evidence: .sisyphus/evidence/task-16-compile-success.log
  
  Scenario: 编译失败时的错误处理
    Tool: Bash
    Preconditions: 故意引入错误（如删除一个模块）
    Steps:
      1. 编译
      2. 检查错误输出
    Expected Result: 错误信息明确，返回码非0
    Evidence: .sisyphus/evidence/task-16-compile-error.log
  ```

  **Commit**: NO（验证任务，不单独提交）

- [ ] **Task 17: 验证仿真流程 - 运行测试**

  **What to do**:
  运行完整的仿真测试，验证功能正常：
  
  1. 运行vvp仿真：
     ```bash
     cd comp_test
     vvp out_iverilog/bin/tb_test.out
     ```
  
  2. 或使用Python脚本：
     ```bash
     python verification/run_all_tests.py --basic
     ```
  
  3. 检查输出：
     - 测试通过（显示PASS）
     - 生成VCD文件（tb.vcd）
     - 无运行时错误

  **Must NOT do**:
  - 如果测试失败，标记任务未完成并报告
  - 不要忽略失败的测试用例

  **Recommended Agent Profile**:
  - **Category**: `verification`
  - **Skills**: `verilog-lint`

  **Parallelization**:
  - **Can Run In Parallel**: NO（顺序验证）
  - **Blocked By**: Task 16（编译成功）
  - **Blocks**: Wave FINAL

  **References**:
  - `verification/run_all_tests.py --basic`
  - `comp_test/tb.sv`

  **Acceptance Criteria**:
  - [ ] 仿真运行完成（返回码0）
  - [ ] 生成`tb.vcd`
  - [ ] 测试输出显示PASS（或成功完成）

  **QA Scenarios**:
  ```
  Scenario: 验证基础测试通过
    Tool: Bash
    Preconditions: 编译已成功
    Steps:
      1. vvp out_iverilog/bin/tb_test.out > simulation.log 2>&1
      2. echo $?  # 检查返回码
      3. grep -E "PASS|FAIL|Error" simulation.log | tail -20
      4. ls -la tb.vcd
    Expected Result: 返回码0，日志显示测试通过，VCD文件存在
    Evidence: .sisyphus/evidence/task-17-test-pass.log
  ```

  **Commit**: NO（验证任务）

---

## Final Verification Wave

### Task F1. Plan Compliance Audit - `oracle`
**What to verify**:
- [ ] 所有"Must Have"已交付：V1文件删除、V2文件重命名、脚本修改、README更新
- [ ] 所有"Must NOT Have"检查通过：共用模块未删除、FPGA结构未破坏
- [ ] 证据文件存在：`.sisyphus/evidence/`目录下每个任务的验证截图/输出
- [ ] 仿真流程验证通过：`run_all_tests.py --basic`执行成功

**Output**: `Must Have [4/4] | Must NOT Have [4/4] | Tasks [17/17] | VERDICT: APPROVE/REJECT`

### Task F2. Code Quality Review - `unspecified-high`
**What to verify**:
- [ ] 无残留V1文件引用（使用`grep -r "v1\|V1"`检查，排除文档历史记录）
- [ ] 无残留V2标签（使用`grep -r "_v2\|_V2"`检查关键路径）
- [ ] 无语法错误（iverilog编译检查）
- [ ] 脚本可执行（bash/ps1/python语法检查）

**Output**: `Syntax Check [PASS/FAIL] | V1 Residue [CLEAN/N issues] | V2 Tag [CLEAN/N issues] | VERDICT`

### Task F3. Real Manual QA - `unspecified-high`
**What to verify**:
- [ ] 完整仿真流程：从编译到测试通过
- [ ] 关键文件存在性：tb.sv、module_list、所有重命名后的RTL文件
- [ ] 输出文件生成：tb.vcd、测试日志

**Output**: `Compilation [PASS/FAIL] | Tests [N/N pass] | Output Files [YES/NO] | VERDICT`

### Task F4. Scope Fidelity Check - `deep`
**What to verify**:
- [ ] 计划中的文件删除已完成（对比删除清单）
- [ ] 计划中的文件重命名已完成（对比重命名清单）
- [ ] 无额外未计划修改（检查git diff统计）
- [ ] 修改范围符合预期（无无关文件被修改）

**Output**: `Deletions [N/N] | Renames [N/N] | Scope [CLEAN/N issues] | VERDICT`

---

## Commit Strategy

### Wave 1 Commit
- **Message**: `refactor(v1): remove V1 pipeline RTL and test files`
- **Files**: 所有删除的V1文件
- **Type**: git rm（删除操作）

### Wave 2 Commit
- **Message**: `refactor(v2): rename V2 RTL files to standard names`
- **Files**: 所有重命名的V2 RTL文件

### Wave 3 Commit
- **Message**: `refactor(scripts): update simulation and synthesis scripts for unified pipeline`
- **Files**: 所有修改的脚本文件

### Wave 4 Commit
- **Message**: `docs(readme): update documentation for unified architecture`
- **Files**: README.md

### Final Commit (After Verification)
- **Message**: `chore(cleanup): remove V1 references and finalize unified pipeline`
- **Files**: 任何遗漏的清理

---

## Success Criteria

### Verification Commands
```bash
# 1. 验证V1文件已删除
git ls-files | grep -E "(adam_riscv\.v|scoreboard\.v|stage_if\.v|inst_memory\.v|stage_id\.v|stage_ro\.v|stage_ex\.v)$"
# Expected: 无输出（V1核心文件不存在）

# 2. 验证V2文件已重命名
ls rtl/adam_riscv.v rtl/stage_if.v rtl/inst_memory.v rtl/scoreboard.v 2>/dev/null
# Expected: 所有文件存在

# 3. 验证仿真编译
python verification/run_all_tests.py --basic
# Expected: 所有测试通过

# 4. 验证README更新
grep -i "v1 vs v2\|v1 和 v2\|V1 and V2" README.md
# Expected: 无输出（无V1/V2对比内容）
```

### Final Checklist
- [ ] 所有V1专属文件已删除（22个）
- [ ] 所有V2文件已重命名（11个）
- [ ] 仿真脚本可用
- [ ] 基础测试通过
- [ ] README已更新
- [ ] git历史清晰（分阶段提交）
- [ ] 用户明确确认完成
