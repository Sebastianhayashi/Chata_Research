# Chatassembler (libchata) 调研报告

## 1 介绍

### 1.1 简介

Chatassembler 是一个针对 RISC-V 指令集的汇编器（assembler），由 libchata 库提供核心功能。它可以直接将 RISC-V 汇编 .s 文件转换为裸机机器码，而不生成 ELF 等可执行文件。项目地址：

> GitHub: https://github.com/Slackadays/Chata/tree/main/libchata

这个工具支持多种 RISC-V 扩展指令集，具体支持的内容请参考官方 [README](https://github.com/Slackadays/Chata/blob/main/libchata/README.md#%EF%B8%8F-complete)。该工具不依赖 GCC 以及 LLVM 大工具链，直接可以生成裸机机器码。
[官方宣称](https://github.com/Slackadays/Chata/blob/main/libchata/README.md#welcome-to-chatassembler)其在特定环境中可以比 GNU 快 10-13 倍，但是在实际测试甚至是慢了 1.8-2.1 倍(10 轮测试中慢了 1.8-2.5 倍)，但是能够看到生成的文件明显更小。

其核心功能在于 `libchata` 库，这个库可以被任意 C++ 项目调用，也可以使用 CLI 简单调用。

### 1.2 与其他工具对比

Chatassembler 的优势在于，首先是只专注于生成 RISC-V 机器代码，不生成 ELF 也不进行链接，省略这些步骤使得代码生成效率更高。
其采用了更轻量的内部实现，这样不仅仅使得理论处理效率更高，开发者在进行扩展时也会更容易上手，且支持 MPL 协议，相对灵活。

而 GNU as（`riscv64-unknown-elf-as`）是传统的 binutils 工具链，其优点在于成熟稳定，但是需要在后续的 `objcopy` 转换成裸机，相比步骤更加繁琐。
而 LLVM-mc 优势在于其通用性强，但是依赖 LLVM 大量代码库，体积大。

所以其核心在于，像是在现行的 RISC-V 开发版算力资源普遍紧张，调用上述两个大型的工具链会吃掉更多的算力资源，开发效率被进一步的降低。所以 Chatassembler 能够解决的问题就是在于让这些算力资源紧张的开发版上更高效的进行代码翻译。

### 1.3 工具的简要原理

Chatassembler 首先是会读取 '.s' 文件中的各类指令/伪指令，然后会直接编码出对应的机器码字节序列。

Lexer/Parser 会进行分词并且识别 RV 指令与其扩展，接着 RV 指令会被转换成 opcode/funct3/funct7 等的字段。不会处理任何与 ELF 相关的处理，比如说符号表、重定位、Section 等。

能够做到一次解析完成，对伪指令进行映射，跳过许多传统链接符号的逻辑。

## 2 部署与使用

### 2.1 编译与安装

这里使用的环境是：openEuler 24.03 LTS，x86

```
git clone https://github.com/Slackadays/Chata.git
cd Chata

# install just (option)
cargo install just

just build
```

### 2.2 使用库生成机器码

## 测试

### 3.1 环境说明

- 系统：openEuler 24.03 LTS x86_64
- CPU：
- 工具链：
- C++ 编译器：GCC 12.3.1
- 测试脚本：complex_perf_test.sh（我们在测试中指定了 SCALES=1,4,8,16,32,64 并重复多次）

### 3.2 测试介绍

首先我们使用官方仓库中的 testfile 下的 16kinstrs.s 作为基础文件，拼接成 big_1x.s ~ big_32x.s 来模拟不同规模（从 16k 行到 32 倍 ~ 1M 行不等）。

接着，对每个规模的 `.s` 文件，各执行 libchata 与 as+objcopy 各 10 次；记录 “real/user/sys” 时间（用 /usr/bin/time -p）以及 perf stat 收集 “instructions, cycles, cache-misses, branch-misses”。

最后把最终机器码大小 *.bin、执行时间、perf 指标一并写入 results.csv。

### 测试结果

> 详细见附表/CSV

5 轮测试：

| **File**            | **Lines** | **Tool**      | **Real Time (s)** | **User Time (s)** | **Sys Time (s)** | **Instructions**   | **Cycles**       | **Cache Misses** | **Branch Misses** |
|---------------------|-----------|---------------|--------------------|-------------------|------------------|--------------------|------------------|------------------|-------------------|
| gen_s/big_1x.s      | 58        | libchata      | 0.36               | 0.28              | 0.07             | 1415610548         | 805097882        | 168113           | 959754            |
| gen_s/big_1x.s      | 58        | as+objcopy    | 0.17               | 0.14              | 0.03             | 963520810          | 416635541        | 68973            | 1125338           |
| gen_s/big_4x.s      | 58        | libchata      | 1.18               | 1.06              | 0.08             | 5608571120         | 3157631907       | 310474           | 3593204           |
| gen_s/big_4x.s      | 58        | as+objcopy    | 0.59               | 0.55              | 0.04             | 3807565505         | 1613350880       | 254666           | 3928415           |
| gen_s/big_8x.s      | 58        | libchata      | 2.22               | 2.14              | 0.08             | 11199162594        | 6284611699       | 535690           | 6998687           |
| gen_s/big_8x.s      | 58        | as+objcopy    | 1.18               | 1.11              | 0.06             | 7599012898         | 3252799553       | 2259039          | 7496308           |
| gen_s/big_16x.s     | 58        | libchata      | 4.38               | 4.27              | 0.10             | 22380336397        | 12554836065      | 1586447          | 13839184          |
| gen_s/big_16x.s     | 58        | as+objcopy    | 2.39               | 2.25              | 0.13             | 15174536561        | 6647992473       | 10036488         | 14727786          |
| gen_s/big_32x.s     | 58        | libchata      | 8.66               | 8.47              | 0.16             | 44742670929        | 25136990685      | 3145915          | 28180435          |
| gen_s/big_32x.s     | 58        | as+objcopy    | 4.86               | 4.55              | 0.28             | 30347926787        | 13536156327      | 30873557         | 30197567          |

10 轮测试：

| **File**            | **Lines** | **Tool**      | **Real Time (s)** | **User Time (s)** | **Sys Time (s)** | **Instructions**   | **Cycles**       | **Cache Misses** | **Branch Misses** |
|---------------------|-----------|---------------|--------------------|-------------------|------------------|--------------------|------------------|------------------|-------------------|
| gen_s/big_1x.s      | 58        | libchata      | 0.84               | 0.61              | 0.22             | 2829945633         | 1634917642       | 370993           | 2000332           |
| gen_s/big_1x.s      | 58        | as+objcopy    | 0.33               | 0.29              | 0.03             | 1927128190         | 834279853        | 105499           | 2268450           |
| gen_s/big_4x.s      | 58        | libchata      | 2.26               | 2.13              | 0.12             | 11215866645        | 6310535922       | 593191           | 7089173           |
| gen_s/big_4x.s      | 58        | as+objcopy    | 1.22               | 1.10              | 0.10             | 7617549964         | 3262358544       | 850423           | 7634122           |
| gen_s/big_8x.s      | 58        | libchata      | 4.42               | 4.24              | 0.16             | 22397049732        | 12593851843      | 1107690          | 14129741          |
| gen_s/big_8x.s      | 58        | as+objcopy    | 2.35               | 2.18              | 0.15             | 15192982298        | 6524899882       | 3753344          | 15257262          |
| gen_s/big_16x.s     | 58        | libchata      | 8.70               | 8.42              | 0.25             | 44759397019        | 25088115774      | 2943852          | 27797722          |
| gen_s/big_16x.s     | 58        | as+objcopy    | 4.71               | 4.42              | 0.27             | 30370147567        | 13196398117      | 19527862         | 29876346          |
| gen_s/big_32x.s     | 58        | libchata      | 17.20              | 16.85             | 0.29             | 89484063448        | 50112964469      | 6629565          | 55044775          |
| gen_s/big_32x.s     | 58        | as+objcopy    | 9.62               | 9.06              | 0.52             | 60694543150        | 27009237547      | 63094056         | 58509572          |

### 3.4 测试结果分析

在同等规模下，as+objcopy 总体用时约为 libchata 的 50% 左右（1.8~2.5× 差距），随着规模增大从 1x 到 32x，这个差距一直保持。

libchata consistently 更多（指令 ~1.5×, 周期 ~2×）。随着规模增大，as+objcopy 在 cache/branch misses 值更高，但显然并未影响其整体效率，因为它指令数更低 + 其他流水线优势。

## 附录

[5 runs CSV](./results_5_runs.csv)
[10 runs CSV](./results_10_runs.csv)