# Chatassembler (libchata) 调研报告

## 1 介绍

### 1.1 简介

Chatassembler 是一个针对 RISC-V 指令集的汇编器（assembler），由 libchata 库提供核心功能。它可以直接将 RISC-V 汇编 .s 文件转换为裸机机器码，而不生成 ELF 等可执行文件。项目地址：

> GitHub: https://github.com/Slackadays/Chata/tree/main/libchata

这个工具支持多种 RISC-V 扩展指令集，具体支持的内容请参考官方 [README](https://github.com/Slackadays/Chata/blob/main/libchata/README.md#%EF%B8%8F-complete)。该工具不依赖 GCC 以及 LLVM 大工具链，直接可以生成裸机机器码。
[官方宣称](https://github.com/Slackadays/Chata/blob/main/libchata/README.md#welcome-to-chatassembler)其在特定环境中可以比 GNU 快 10~13 倍，但是在实际测试只有提升 1.4~2 倍的速度，详见下文测试部分。
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

更详细的原理解释见下文。

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

首先我们使用官方仓库中的 testfile 下的 16kinstrs.s 作为基础文件，拼接成 big_1x.s ~ big_64x.s 来模拟不同规模（从 16k 行到 64 倍 ~ 1M 行不等）。

接着，对每个规模的 `.s` 文件，各执行 libchata 与 as+objcopy 各 10 次；记录 “real/user/sys” 时间（用 /usr/bin/time -p）以及 perf stat 收集 “instructions, cycles, cache-misses, branch-misses”。

最后把最终机器码大小 *.bin、执行时间、perf 指标一并写入 results.csv。

### 测试结果

> 详细见附表/CSV


| **类别**               | **Chatassembler**      | **as+objcopy**      | **对比**                 |
|------------------------|-----------------------|---------------------|--------------------------|
| **时间**               | 约 1.2 s             | 约 1.9~2.0 s        | 加速比 1.6~1.7 倍        |
| **产物大小**           | 3,891,200 bytes      | 4,710,400 bytes     | 小 ~ 20~25%             |
| **CPU 指令数**         | ~ 6.96 × 10⁹         | ~ 1.21 × 10¹⁰       | 二者相差 ~ 1:1.7        |
| **Cache misses / Branch misses** | 显著更低            | 高一个量级          | Chatassembler 优势明显 |


### 3.4 测试结果分析

从结果来看，Chatassembler 确实是最快的，在越大规模的文件下差距会越来越明显，我测试的结果是快了 1.4~2 倍。
同时，指令数、周期数、cache miss、branch miss 等都更低；说明 Chatassembler 在解析策略、数据结构上更高效。

## 附录

[CSV](./results.csv)