---
name: verilog-lint
description: 验证 Verilog RTL 代码的语法正确性
---

# Verilog 语法检查规范

当你创建、修改或重构 `rtl/` 目录下的任何 `.v` 文件后，**必须**在终端中执行以下命令来进行纯语法检查：

```bash
iverilog -tnull -Wall rtl/*.v
```
