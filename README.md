# svslice_simple

从单个 Verilog/SystemVerilog 文件中提取指定顶层模块及其依赖的所有子模块，输出合并后的文件。

## 功能

- 解析 `.v` / `.sv` 文件中的多个 module 定义
- 从指定顶层模块做闭包遍历，提取所有依赖模块
- 保持原文件中 `timescale`、`include`、`define` 等编译指令的作用域
- 输出层级关系到 `hierarchy.txt`
- 自动复制被抽取模块用到的 `include` 文件到输出目录
- **[NEW]** 自动检测并记录缺失的外部模块依赖到 `missing_modules.txt`

## 依赖

- Perl 5.10+（使用标准模块：`Getopt::Long`、`File::Path`、`File::Copy`、`File::Basename`）

## 用法

```bash
perl svslice_simple.pl --in design.sv --top top_module [options]
```

### 必选参数

| 参数 | 说明 |
|------|------|
| `--in <file>` | 输入的 .v/.sv 文件 |
| `--top <module>` | 需要抽取的顶层模块名 |

### 可选参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--out <file>` | `extracted.sv` | 输出合并文件 |
| `--hier <file>` | `hierarchy.txt` | 层级关系文件 |
| `--incdir <dir>` | 无 | include 搜索路径（可重复指定） |

### 示例

```bash
# 基本用法
perl svslice_simple.pl --in ANA_ABB.all.v --top module_A

# 指定输出路径
perl svslice_simple.pl --in design.sv --top cpu_top --out cpu_extracted.sv --hier cpu_hierarchy.txt

# 添加 include 搜索路径
perl svslice_simple.pl --in top.sv --top TOP --incdir ./include --incdir ./common
```

## 输出

1. **`<outfile>`**（默认 `extracted.sv`）：合并后的 SystemVerilog 文件，仅包含顶层模块及其依赖的所有子模块
2. **`<hierfile>`**（默认 `hierarchy.txt`）：层级关系树形文本
3. **`missing_modules.txt`**（如果存在外部依赖）：不在输入文件中的缺失模块列表
4. **`<outdir>/include/`**：被抽取模块用到的 `include` 文件副本

### missing_modules.txt 说明

该文件包含所有在代码中被实例化但未在输入文件中定义的模块，通常来自外部库。示例：

```
dsp_lib
memory_ctrl
pll_core
```

这有助于用户快速识别设计的外部依赖。

## 层级文件格式

```
- module_A
  - CPU
    - ALU
      - register_file
        - pipeline_stage
          - decode_unit
            - control_unit
```

## 注意

- 输入文件必须是语法正确的 Verilog/SystemVerilog
- 每个 module 必须以 `endmodule` 结尾
- instance 格式需为 `ModuleName #(...) u_name (...)` 或 `ModuleName u_name (...)`

## License

MIT