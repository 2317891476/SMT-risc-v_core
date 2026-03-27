# AX7203 开发平台硬件与接口引脚速查文档

> 基于《AX7203 ARTIX-7 FPGA 开发平台用户手册》整理，面向“快速检索硬件组成、接口能力、关键引脚分配”的查阅场景。:contentReference[oaicite:0]{index=0}

---

## 1. 文档目的

本文将 AX7203 开发平台中的**核心硬件信息**与**常用接口引脚分配**重新整理为一份便于搜索和检索的 Markdown 文档，适合：

- 查板卡资源配置
- 查接口对应 FPGA 管脚
- 做约束文件（XDC）前的速查
- 做原理图/模块对接时的引脚核对

---

## 2. 平台总览

AX7203 采用**核心板 + 扩展板**结构：

- **核心板 AC7200**
  - FPGA：Xilinx Artix-7 `XC7A200T-2FBG484I`
  - 存储：`2 x DDR3`
  - 启动存储：`128Mbit QSPI Flash`
  - 时钟：`200MHz` 差分时钟、`148.5MHz` GTP 参考时钟
- **扩展板**
  - `PCIe x4`
  - `2 x 千兆以太网`
  - `HDMI 输入`
  - `HDMI 输出`
  - `USB-UART`
  - `Micro SD`
  - `EEPROM`
  - `2 x 40Pin 扩展口`
  - `XADC 接口`
  - `JTAG`
  - 用户按键 / LED 等:contentReference[oaicite:1]{index=1}

---

## 3. 核心板硬件参数

### 3.1 FPGA

- 型号：`XC7A200T-2FBG484I`
- 系列：Xilinx Artix-7
- 封装：`FBG484`
- 速度等级：`-2`
- 温度等级：`工业级`

### 3.2 FPGA 资源

| 项目            |                参数 |
| --------------- | ------------------: |
| Logic Cells     |              215360 |
| Slices          |               33650 |
| CLB Flip-Flops  |              269200 |
| Block RAM       |            13140 kb |
| DSP Slices      |                 740 |
| PCIe Gen2       |                   1 |
| XADC            | 1 个，12-bit，1Msps |
| GTP Transceiver |  4 个，最高 6.6Gb/s |

### 3.3 核心板 IO 资源

- `180` 个 `3.3V` 标准普通 IO
- `15` 个 `1.5V` 标准普通 IO
- `4` 对 GTP 高速差分 RX/TX 信号:contentReference[oaicite:2]{index=2}

---

## 4. 电源与电压域

### 4.1 FPGA 主要电源

| 电源     | 电压         |
| -------- | ------------ |
| VCCINT   | 1.0V         |
| VCCBRAM  | 1.0V         |
| VCCAUX   | 1.8V         |
| VCCO     | 依 BANK 而定 |
| VMGTAVCC | 1.0V         |
| VMGTAVTT | 1.2V         |

### 4.2 BANK 电压说明

- `BANK34 / BANK35`：`1.5V`（因连接 DDR3）
- 其它常规 BANK：`3.3V`
- `BANK15 / BANK16`：由 LDO 供电，默认 `3.3V`，可通过更换 LDO 调整:contentReference[oaicite:3]{index=3}

### 4.3 上电顺序

#### FPGA 主电源
`VCCINT -> VCCBRAM -> VCCAUX -> VCCO`

> 若 VCCINT 与 VCCBRAM 电压相同，可同时上电。

#### GTP 电源
`VCCINT -> VMGTAVCC -> VMGTAVTT`

> 若 VCCINT 与 VMGTAVCC 电压相同，可同时上电。:contentReference[oaicite:4]{index=4}

---

## 5. 时钟资源

### 5.1 200MHz 差分系统时钟

- 型号：`SiT9102-200.00MHz`
- 用途：
  - FPGA 系统主时钟
  - DDR3 控制时钟来源

| 信号名    | FPGA 管脚 |
| --------- | --------- |
| SYS_CLK_P | R4        |
| SYS_CLK_N | T4        |

### 5.2 148.5MHz GTP 参考时钟

- 型号：`SiT9102-148.5MHz`
- 用途：GTP 收发器参考时钟

| 信号名     | FPGA 管脚 |
| ---------- | --------- |
| MGT_CLK0_P | F6        |
| MGT_CLK0_N | E6        |

> 手册中小节标题有“125MHz”字样，但正文与器件型号均明确为 `148.5MHz`。:contentReference[oaicite:5]{index=5}

---

## 6. DDR3 存储器

### 6.1 基本信息

- 芯片：`2 x Micron MT41J256M16HA-125`
- 兼容：`MT41K256M16HA-125`
- 单片容量：`4Gbit / 256M x 16bit`
- 总容量：`8Gbit`
- 总线宽度：`32bit`
- 最高时钟：`400MHz`
- 数据速率：`800Mbps`
- 连接 BANK：`BANK34 / BANK35`:contentReference[oaicite:6]{index=6}

### 6.2 DDR3 引脚分配

#### DQS

| 信号        | FPGA 管脚 |
| ----------- | --------- |
| DDR3_DQS0_P | E1        |
| DDR3_DQS0_N | D1        |
| DDR3_DQS1_P | K2        |
| DDR3_DQS1_N | J2        |
| DDR3_DQS2_P | M1        |
| DDR3_DQS2_N | L1        |
| DDR3_DQS3_P | P5        |
| DDR3_DQS3_N | P4        |

#### DQ[0:31]

| 信号        | FPGA 管脚 | 信号        | FPGA 管脚 |
| ----------- | --------- | ----------- | --------- |
| DDR3_DQ[0]  | C2        | DDR3_DQ[16] | L4        |
| DDR3_DQ[1]  | G1        | DDR3_DQ[17] | M3        |
| DDR3_DQ[2]  | A1        | DDR3_DQ[18] | L3        |
| DDR3_DQ[3]  | F3        | DDR3_DQ[19] | J6        |
| DDR3_DQ[4]  | B2        | DDR3_DQ[20] | K3        |
| DDR3_DQ[5]  | F1        | DDR3_DQ[21] | K6        |
| DDR3_DQ[6]  | B1        | DDR3_DQ[22] | J4        |
| DDR3_DQ[7]  | E2        | DDR3_DQ[23] | L5        |
| DDR3_DQ[8]  | H3        | DDR3_DQ[24] | P1        |
| DDR3_DQ[9]  | G3        | DDR3_DQ[25] | N4        |
| DDR3_DQ[10] | H2        | DDR3_DQ[26] | R1        |
| DDR3_DQ[11] | H5        | DDR3_DQ[27] | N2        |
| DDR3_DQ[12] | J1        | DDR3_DQ[28] | M6        |
| DDR3_DQ[13] | J5        | DDR3_DQ[29] | N5        |
| DDR3_DQ[14] | K1        | DDR3_DQ[30] | P6        |
| DDR3_DQ[15] | H4        | DDR3_DQ[31] | P2        |

#### DM

| 信号     | FPGA 管脚 |
| -------- | --------- |
| DDR3_DM0 | D2        |
| DDR3_DM1 | G2        |
| DDR3_DM2 | M2        |
| DDR3_DM3 | M5        |

#### 地址线 A[0:14]

| 信号      | FPGA 管脚 | 信号       | FPGA 管脚 |
| --------- | --------- | ---------- | --------- |
| DDR3_A[0] | AA4       | DDR3_A[8]  | V2        |
| DDR3_A[1] | AB2       | DDR3_A[9]  | U2        |
| DDR3_A[2] | AA5       | DDR3_A[10] | Y1        |
| DDR3_A[3] | AB5       | DDR3_A[11] | W2        |
| DDR3_A[4] | AB1       | DDR3_A[12] | Y2        |
| DDR3_A[5] | U3        | DDR3_A[13] | U1        |
| DDR3_A[6] | W1        | DDR3_A[14] | V3        |
| DDR3_A[7] | T1        |            |           |

#### BA / 控制

| 信号       | FPGA 管脚 |
| ---------- | --------- |
| DDR3_BA[0] | AA3       |
| DDR3_BA[1] | Y3        |
| DDR3_BA[2] | Y4        |
| DDR3_S0    | AB3       |
| DDR3_RAS   | V4        |
| DDR3_CAS   | W4        |
| DDR3_WE    | AA1       |
| DDR3_ODT   | U5        |
| DDR3_RESET | W6        |
| DDR3_CLK_P | R3        |
| DDR3_CLK_N | R2        |
| DDR3_CKE   | T5        |

---

## 7. QSPI Flash

### 7.1 基本信息

- 型号：`N25Q128`
- 容量：`128Mbit`
- 电平标准：`3.3V CMOS`
- 用途：
  - FPGA 启动镜像
  - bit 文件
  - 软核程序
  - 用户数据文件:contentReference[oaicite:7]{index=7}

### 7.2 引脚分配

| 信号     | FPGA 管脚 |
| -------- | --------- |
| QSPI_CLK | L12       |
| QSPI_CS  | T19       |
| QSPI_DQ0 | P22       |
| QSPI_DQ1 | R22       |
| QSPI_DQ2 | P21       |
| QSPI_DQ3 | R21       |

---

## 8. 核心板 LED / 复位 / JTAG / 供电

### 8.1 核心板 LED

核心板共有 3 个红色 LED：

- `PWR`：电源指示
- `DONE`：FPGA 配置完成指示
- `LED1`：用户 LED

#### 用户 LED 引脚

| 信号 | FPGA 管脚 | 备注     |
| ---- | --------- | -------- |
| LED1 | W5        | 用户 LED |

### 8.2 复位按键

- 按键名：`Reset`
- 有效电平：`低有效`

| 信号    | FPGA 管脚 | 备注     |
| ------- | --------- | -------- |
| RESET_N | T6        | 复位按键 |

### 8.3 核心板 JTAG

- 接口：`6 针 2.54mm 单排测试孔`
- 信号：`TMS / TDI / TDO / TCK / GND / +3.3V`

### 8.4 核心板独立供电接口

- 接口：`J3`
- 类型：`2Pin`
- `PIN1 = +5V`
- `PIN2 = GND`

> 不要与底板同时给核心板供电。:contentReference[oaicite:8]{index=8}

---

## 9. 核心板板间高速连接器（CON1 ~ CON4）概要

> 这 4 个 80Pin 高速板间连接器主要用于核心板与底板连接，表格较大，这里按**用途和电压域**总结，方便先定位资源，再去查详细引脚。

### 9.1 CON1
- 包含：
  - `+5V`
  - `GND`
  - `BANK13` 部分 `3.3V IO`
  - `BANK16` 部分 `3.3V IO`
  - `BANK34` 部分 `1.5V IO`
  - `XADC_VP / XADC_VN`
- 特别注意：CON1 上连接到 `BANK34` 的 IO 全部是 `1.5V` 电平。

### 9.2 CON2
- 主要扩展：
  - `BANK13`
  - `BANK14`
- 电平：**全部 3.3V**

### 9.3 CON3
- 主要扩展：
  - `BANK15`
  - `BANK16`
- 默认电平：`3.3V`
- 可通过更换 LDO 改变电平
- 还带出 JTAG 信号：
  - `FPGA_TCK = V12`
  - `FPGA_TDI = R13`
  - `FPGA_TDO = U13`
  - `FPGA_TMS = T13`

### 9.4 CON4
- 主要扩展：
  - `BANK16` 常规 IO
  - `GTP` 高速差分收发信号
  - `GTP` 差分参考时钟
- 默认普通 IO 电平：`3.3V`

> 若你后续需要，我可以再把 `CON1~CON4` 的 80Pin 全表完整转成独立 md 附录版。:contentReference[oaicite:9]{index=9}

---

## 10. 扩展板接口速查

---

## 11. 千兆以太网接口

### 11.1 硬件信息

- PHY 芯片：`2 x KSZ9031RNX`
- 支持：`10/100/1000 Mbps`
- 与 FPGA 接口：`RGMII`
- 管理总线：`MDIO`
- 默认 PHY 地址：`011`:contentReference[oaicite:10]{index=10}

### 11.2 PHY1 引脚分配

| 信号     | FPGA 管脚 | 说明           |
| -------- | --------- | -------------- |
| E1_GTXC  | E18       | RGMII 发送时钟 |
| E1_TXD0  | C20       | 发送数据 bit0  |
| E1_TXD1  | D20       | 发送数据 bit1  |
| E1_TXD2  | A19       | 发送数据 bit2  |
| E1_TXD3  | A18       | 发送数据 bit3  |
| E1_TXEN  | F18       | 发送使能       |
| E1_RXC   | B17       | RGMII 接收时钟 |
| E1_RXD0  | A16       | 接收数据 bit0  |
| E1_RXD1  | B18       | 接收数据 bit1  |
| E1_RXD2  | C18       | 接收数据 bit2  |
| E1_RXD3  | C19       | 接收数据 bit3  |
| E1_RXDV  | A15       | 接收数据有效   |
| E1_MDC   | B16       | MDIO 管理时钟  |
| E1_MDIO  | B15       | MDIO 管理数据  |
| E1_RESET | D16       | PHY 复位       |

### 11.3 PHY2 引脚分配

| 信号     | FPGA 管脚 | 说明           |
| -------- | --------- | -------------- |
| E2_GTXC  | A14       | RGMII 发送时钟 |
| E2_TXD0  | E17       | 发送数据 bit0  |
| E2_TXD1  | C14       | 发送数据 bit1  |
| E2_TXD2  | C15       | 发送数据 bit2  |
| E2_TXD3  | A13       | 发送数据 bit3  |
| E2_TXEN  | D17       | 发送使能       |
| E2_RXC   | E19       | RGMII 接收时钟 |
| E2_RXD0  | A20       | 接收数据 bit0  |
| E2_RXD1  | B20       | 接收数据 bit1  |
| E2_RXD2  | D19       | 接收数据 bit2  |
| E2_RXD3  | C17       | 接收数据 bit3  |
| E2_RXDV  | F19       | 接收数据有效   |
| E2_MDC   | F20       | MDIO 管理时钟  |
| E2_MDIO  | C22       | MDIO 管理数据  |
| E2_RESET | B22       | PHY 复位       |

---

## 12. PCIe x4 接口

### 12.1 硬件信息

- 接口类型：`PCIe x4`
- 参考时钟：`100MHz`（由 PC 插槽提供）
- 与 FPGA 连接：`GTP`
- 单通道通信速率：最高约 `5 Gbit`:contentReference[oaicite:11]{index=11}

### 12.2 引脚分配

| 信号       | FPGA 管脚 | 说明       |
| ---------- | --------- | ---------- |
| PCIE_RX0_P | D11       | Lane0 RX+  |
| PCIE_RX0_N | C11       | Lane0 RX-  |
| PCIE_RX1_P | B8        | Lane1 RX+  |
| PCIE_RX1_N | A8        | Lane1 RX-  |
| PCIE_RX2_P | B10       | Lane2 RX+  |
| PCIE_RX2_N | A10       | Lane2 RX-  |
| PCIE_RX3_P | D9        | Lane3 RX+  |
| PCIE_RX3_N | C9        | Lane3 RX-  |
| PCIE_TX0_P | D5        | Lane0 TX+  |
| PCIE_TX0_N | C5        | Lane0 TX-  |
| PCIE_TX1_P | B4        | Lane1 TX+  |
| PCIE_TX1_N | A4        | Lane1 TX-  |
| PCIE_TX2_P | B6        | Lane2 TX+  |
| PCIE_TX2_N | A6        | Lane2 TX-  |
| PCIE_TX3_P | D7        | Lane3 TX+  |
| PCIE_TX3_N | C7        | Lane3 TX-  |
| PCIE_CLK_P | F10       | 参考时钟 + |
| PCIE_CLK_N | E10       | 参考时钟 - |

---

## 13. HDMI 输出接口（SiI9134）

### 13.1 硬件信息

- 芯片：`SiI9134`
- 类型：HDMI / DVI 编码器
- 最高支持：`1080P@60Hz`
- 支持：`3D 输出`:contentReference[oaicite:12]{index=12}

### 13.2 FPGA 引脚分配

| 信号        | FPGA 管脚 |
| ----------- | --------- |
| 9134_nRESET | J19       |
| 9134_CLK    | M13       |
| 9134_HS     | T15       |
| 9134_VS     | T14       |
| 9134_DE     | V13       |
| 9134_D[0]   | V14       |
| 9134_D[1]   | H14       |
| 9134_D[2]   | J14       |
| 9134_D[3]   | K13       |
| 9134_D[4]   | K14       |
| 9134_D[5]   | L13       |
| 9134_D[6]   | L19       |
| 9134_D[7]   | L20       |
| 9134_D[8]   | K17       |
| 9134_D[9]   | J17       |
| 9134_D[10]  | L16       |
| 9134_D[11]  | K16       |
| 9134_D[12]  | L14       |
| 9134_D[13]  | L15       |
| 9134_D[14]  | M15       |
| 9134_D[15]  | M16       |
| 9134_D[16]  | L18       |
| 9134_D[17]  | M18       |
| 9134_D[18]  | N18       |
| 9134_D[19]  | N19       |
| 9134_D[20]  | M20       |
| 9134_D[21]  | N20       |
| 9134_D[22]  | L21       |
| 9134_D[23]  | M21       |

---

## 14. HDMI 输入接口（SiI9013）

### 14.1 硬件信息

- 芯片：`SiI9013`
- 类型：HDMI 解码器
- 最高支持：`1080P@60Hz` 输入:contentReference[oaicite:13]{index=13}

### 14.2 FPGA 引脚分配

| 信号        | FPGA 管脚 |
| ----------- | --------- |
| 9013_nRESET | H19       |
| 9013_CLK    | K21       |
| 9013_HS     | K19       |
| 9013_VS     | K18       |
| 9013_DE     | H17       |
| 9013_D[0]   | H18       |
| 9013_D[1]   | N22       |
| 9013_D[2]   | M22       |
| 9013_D[3]   | K22       |
| 9013_D[4]   | J22       |
| 9013_D[5]   | H22       |
| 9013_D[6]   | H20       |
| 9013_D[7]   | G20       |
| 9013_D[8]   | G22       |
| 9013_D[9]   | G21       |
| 9013_D[10]  | D22       |
| 9013_D[11]  | E22       |
| 9013_D[12]  | D21       |
| 9013_D[13]  | E21       |
| 9013_D[14]  | B21       |
| 9013_D[15]  | A21       |
| 9013_D[16]  | F21       |
| 9013_D[17]  | M17       |
| 9013_D[18]  | J16       |
| 9013_D[19]  | F15       |
| 9013_D[20]  | G17       |
| 9013_D[21]  | G18       |
| 9013_D[22]  | G15       |
| 9013_D[23]  | G16       |

---

## 15. Micro SD 卡槽

### 15.1 硬件信息

- 卡型：`MicroSD`
- 支持模式：
  - `SD 模式`
  - `SPI 模式`:contentReference[oaicite:14]{index=14}

### 15.2 SD 模式引脚分配

| 信号    | FPGA 管脚 |
| ------- | --------- |
| SD_CLK  | AB12      |
| SD_CMD  | AB11      |
| SD_CD_N | F14       |
| SD_DAT0 | AA13      |
| SD_DAT1 | AB13      |
| SD_DAT2 | Y13       |
| SD_DAT3 | AA14      |

---

## 16. USB 转串口（CP2102GM）

### 16.1 硬件信息

- 芯片：`CP2102GM`
- 接口：`MINI USB`
- 功能：USB 转 UART
- 板上带 `TX / RX` 串口状态 LED:contentReference[oaicite:15]{index=15}

### 16.2 FPGA 引脚分配

| 信号      | FPGA 管脚 |
| --------- | --------- |
| UART1_RXD | P20       |
| UART1_TXD | N15       |

---

## 17. EEPROM（24LC04）

### 17.1 硬件信息

- 型号：`24LC04`
- 容量：`4Kbit`
- 接口：`I2C`:contentReference[oaicite:16]{index=16}

### 17.2 FPGA 引脚分配

| 信号           | FPGA 管脚 |
| -------------- | --------- |
| EEPROM_I2C_SCL | F13       |
| EEPROM_I2C_SDA | E14       |

---

## 18. 扩展口 J11（40Pin）

### 18.1 接口说明

- 2.54mm 标准间距
- 共 40 个信号：
  - `1 路 +5V`
  - `2 路 +3.3V`
  - `3 路 GND`
  - `34 路 IO`

> **不要将 FPGA IO 直接连接到 5V 设备。** 如需连接 5V 外设，必须增加电平转换。:contentReference[oaicite:17]{index=17}

### 18.2 J11 引脚分配

|  Pin | FPGA  |  Pin | FPGA  |
| ---: | ----- | ---: | ----- |
|    1 | GND   |    2 | +5V   |
|    3 | P16   |    4 | R17   |
|    5 | R16   |    6 | P15   |
|    7 | N17   |    8 | P17   |
|    9 | U16   |   10 | T16   |
|   11 | U17   |   12 | U18   |
|   13 | P19   |   14 | R19   |
|   15 | V18   |   16 | V19   |
|   17 | U20   |   18 | V20   |
|   19 | AA9   |   20 | AB10  |
|   21 | AA10  |   22 | AA11  |
|   23 | W10   |   24 | V10   |
|   25 | Y12   |   26 | Y11   |
|   27 | W12   |   28 | W11   |
|   29 | AA15  |   30 | AB15  |
|   31 | Y16   |   32 | AA16  |
|   33 | AB16  |   34 | AB17  |
|   35 | W14   |   36 | Y14   |
|   37 | GND   |   38 | GND   |
|   39 | +3.3V |   40 | +3.3V |

---

## 19. 扩展口 J13（40Pin）

### 19.1 接口说明

- 2.54mm 标准间距
- 共 40 个信号：
  - `1 路 +5V`
  - `2 路 +3.3V`
  - `3 路 GND`
  - `34 路 IO`:contentReference[oaicite:18]{index=18}

### 19.2 J13 引脚分配

|  Pin | FPGA  |  Pin | FPGA  |
| ---: | ----- | ---: | ----- |
|    1 | GND   |    2 | +5V   |
|    3 | W16   |    4 | W15   |
|    5 | V17   |    6 | W17   |
|    7 | U15   |    8 | V15   |
|    9 | AB21  |   10 | AB22  |
|   11 | AA21  |   12 | AA20  |
|   13 | AB20  |   14 | AA19  |
|   15 | AA18  |   16 | AB18  |
|   17 | T20   |   18 | Y17   |
|   19 | W22   |   20 | W21   |
|   21 | T21   |   22 | U21   |
|   23 | Y21   |   24 | Y22   |
|   25 | W20   |   26 | W19   |
|   27 | Y19   |   28 | Y18   |
|   29 | V22   |   30 | U22   |
|   31 | T18   |   32 | R18   |
|   33 | R14   |   34 | P14   |
|   35 | N13   |   36 | N14   |
|   37 | GND   |   38 | GND   |
|   39 | +3.3V |   40 | +3.3V |

---

## 20. XADC 接口（默认不安装）

### 20.1 接口说明

- 连接器：`2x8 2.54mm`
- 默认：**不安装**
- 提供 `3 对`差分 ADC 输入
- 接入 FPGA 内部 `12-bit 1Msps XADC`:contentReference[oaicite:19]{index=19}

### 20.2 XADC 引脚分配

| XADC 接口引脚 | FPGA 引脚             | 输入幅度  | 描述                          |
| ------------- | --------------------- | --------- | ----------------------------- |
| 1, 2          | VP_0: L10 / VN_0: M9  | 峰峰值 1V | 专用 XADC 输入通道            |
| 5, 6          | AD9P: J15 / AD9N: H15 | 峰峰值 1V | 辅助 XADC 通道 9，可作普通 IO |
| 9, 10         | AD0P: H13 / AD0N: G13 | 峰峰值 1V | 辅助 XADC 通道 0，可作普通 IO |

---

## 21. 扩展板按键

### 21.1 说明

- 用户按键：`KEY1 ~ KEY2`
- 有效电平：`低有效`

### 21.2 引脚分配

| 信号 | FPGA 管脚 |
| ---- | --------- |
| KEY1 | J21       |
| KEY2 | E13       |

---

## 22. 扩展板用户 LED

### 22.1 说明

- 扩展板用户 LED：`LED1 ~ LED4`
- 行为：**低电平点亮，高电平熄灭**
- 另有：
  - 电源指示灯
  - USB-UART TX/RX 指示灯:contentReference[oaicite:20]{index=20}

### 22.2 引脚分配

| 信号 | FPGA 管脚 |
| ---- | --------- |
| LED1 | B13       |
| LED2 | C13       |
| LED3 | D14       |
| LED4 | D15       |

---

## 23. 扩展板供电

### 23.1 供电方式

- 输入电压：`DC12V`
- 支持：
  - 外接电源适配器供电
  - `PCIe` 插槽取电
  - `ATX 12V` 供电:contentReference[oaicite:21]{index=21}

### 23.2 电源转换

扩展板通过 `4 路 MP1482 DC/DC` 将 `+12V` 转为：

- `+5V`
- `+3.3V`
- `+1.8V`
- `+1.2V`

其中扩展板的 `+5V` 还会通过板间连接器给核心板供电。:contentReference[oaicite:22]{index=22}

---

## 24. 常用检索关键词

为方便全文搜索，下面给出建议关键词：

### 板级资源
- `XC7A200T`
- `DDR3`
- `QSPI`
- `PCIe`
- `HDMI`
- `KSZ9031`
- `CP2102`
- `24LC04`
- `XADC`
- `J11`
- `J13`

### 时钟
- `SYS_CLK_P`
- `SYS_CLK_N`
- `MGT_CLK0_P`
- `MGT_CLK0_N`

### 常用外设
- `UART1_RXD`
- `UART1_TXD`
- `SD_CLK`
- `SD_CMD`
- `EEPROM_I2C_SCL`
- `EEPROM_I2C_SDA`

### 调试与控制
- `RESET_N`
- `KEY1`
- `KEY2`
- `LED1`
- `FPGA_TCK`
- `FPGA_TDI`
- `FPGA_TDO`
- `FPGA_TMS`

---

## 25. 使用注意事项

1. `BANK34 / BANK35` 为 `1.5V` 电压域，相关 IO 使用时不要按 3.3V 处理。  
2. `BANK15 / BANK16` 默认 `3.3V`，但可通过更换 LDO 改变。  
3. 扩展口 `J11/J13` 的 IO **不能直接接 5V 器件**。  
4. 核心板单独供电时使用 `J3 5V`，不要与底板同时供电。  
5. 扩展板供电要求 `12V`，建议使用原配电源。  
6. JTAG 线插拔不要热插拔。:contentReference[oaicite:23]{index=23}

---

## 26. 一页式速查表

### 26.1 关键器件

| 模块       | 器件                  |
| ---------- | --------------------- |
| FPGA       | XC7A200T-2FBG484I     |
| DDR3       | 2 x MT41J256M16HA-125 |
| QSPI Flash | N25Q128               |
| 以太网 PHY | 2 x KSZ9031RNX        |
| HDMI 输出  | SiI9134               |
| HDMI 输入  | SiI9013               |
| USB-UART   | CP2102GM              |
| EEPROM     | 24LC04                |

### 26.2 关键时钟

| 信号       | 引脚 |
| ---------- | ---- |
| SYS_CLK_P  | R4   |
| SYS_CLK_N  | T4   |
| MGT_CLK0_P | F6   |
| MGT_CLK0_N | E6   |

### 26.3 关键控制

| 信号           | 引脚 |
| -------------- | ---- |
| RESET_N        | T6   |
| LED1（核心板） | W5   |
| KEY1           | J21  |
| KEY2           | E13  |
| LED1（扩展板） | B13  |
| LED2（扩展板） | C13  |
| LED3（扩展板） | D14  |
| LED4（扩展板） | D15  |

### 26.4 通信接口

| 接口        | 关键引脚                                                     |
| ----------- | ------------------------------------------------------------ |
| UART        | UART1_RXD=P20, UART1_TXD=N15                                 |
| EEPROM I2C  | SCL=F13, SDA=E14                                             |
| SD          | CLK=AB12, CMD=AB11, DAT0=AA13, DAT1=AB13, DAT2=Y13, DAT3=AA14 |
| PCIe RefClk | F10 / E10                                                    |

---

## 27. 参考来源

本文依据 AX7203 用户手册整理。:contentReference[oaicite:24]{index=24}