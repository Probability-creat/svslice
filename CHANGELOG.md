# Changelog

所有值得注意的项目变更将被记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本控制方案参考 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

## [1.1.0] - 2026-04-16

### Added

- **缺失模块检测功能**：自动检测并记录在代码中被实例化但未在输入文件中定义的模块
  - 在输出中显示缺失模块的数量和名称列表
  - 生成 `missing_modules.txt` 文件供用户参考
  - 帮助用户快速识别设计的外部库依赖

### Changed

- 更新 `extract_children()` 函数签名，添加可选的 `$missing_ref` 参数用于跟踪缺失模块
- 优化依赖图构建过程以支持缺失模块记录
- 增强终端输出信息，现在显示缺失模块统计

### Details

修改的主要函数：
- `extract_children()` — 新增缺失模块跟踪逻辑
- 主程序依赖图构建 — 传递缺失模块哈希表
- 输出阶段 — 生成 `missing_modules.txt` 文件

**使用示例：**

运行脚本后的输出示例：
```
Done
  input      : design.sv
  top        : cpu_top
  modules    : 5 (cpu_top, alu, decoder, regfile, controller)
  output sv  : extracted.sv
  hierarchy  : hierarchy.txt
  include dir: extracted/include (copied 3)
  missing mod: 3 (dsp_lib, memory_ctrl, pll_core)
```

## [1.0.0] - 2025-XX-XX

### Added

- 初始版本发布
- 支持从单个 Verilog/SystemVerilog 文件中提取指定顶层模块及其依赖
- 保持编译指令作用域。
- 输出层级关系树
- 自动复制 `include` 文件依赖
