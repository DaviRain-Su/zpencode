# Zpencode - Zig AI 代码助手实现计划

## 项目概述

使用 Zig 语言实现一个完整的 AI 代码助手 CLI 工具，对标 Claude Code 和 OpenCode 的功能。

**目标特性**：
- 多 AI 提供商支持 (Anthropic, OpenAI, Ollama)
- 丰富的 TUI 界面 (窗口分割、语法高亮、快捷键)
- 完整工具系统 (文件读写、命令执行、代码搜索)
- 安全沙箱 (进程隔离、权限控制)

---

## 技术栈选型

| 功能 | 库 | 说明 |
|-----|-----|------|
| TUI | **libvaxis** | 1.5k+ stars，生产级，类似 Ratatui |
| HTTP | **std.http.Client** | 内置，支持 TLS 和流式传输 |
| JSON | **std.json** | 内置，编译时类型安全 |
| SQLite | **zqlite.zig** | 连接池，线程安全 |
| 事件循环 | **libxev** | io_uring/kqueue，高性能 |
| Markdown | **Koino** | CommonMark + GFM 兼容 |
| 语法高亮 | **zig-tree-sitter** | 官方绑定，增量解析 |

---

## 架构设计

```
┌─────────────────────────────────────────────────────┐
│                    CLI Entry (main.zig)             │
└─────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────┐
│  Core Layer: Config | Session | Event | Logger      │
└─────────────────────────────────────────────────────┘
          │                │                │
┌─────────────┐  ┌─────────────┐  ┌─────────────────┐
│  TUI Layer  │  │ Agent Layer │  │ Provider Layer  │
│  libvaxis   │  │ Orchestrator│  │ Anthropic/OpenAI│
│  Widgets    │  │ ToolExecutor│  │ Ollama/Custom   │
└─────────────┘  └─────────────┘  └─────────────────┘
                         │
┌─────────────────────────────────────────────────────┐
│  Tools Layer: FileR/W | Bash | Glob | Grep | Git    │
└─────────────────────────────────────────────────────┘
                         │
┌─────────────────────────────────────────────────────┐
│  Sandbox Layer: seccomp | namespace | rlimit        │
└─────────────────────────────────────────────────────┘
```

---

## 目录结构

```
zpencode/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig              # CLI 入口
│   ├── root.zig              # 库导出
│   ├── core/                 # 核心抽象
│   │   ├── app.zig
│   │   ├── config.zig
│   │   ├── event.zig
│   │   └── logger.zig
│   ├── models/               # 数据模型
│   │   ├── message.zig
│   │   ├── session.zig
│   │   └── tool.zig
│   ├── providers/            # LLM 提供商
│   │   ├── provider.zig      # 接口定义
│   │   ├── anthropic.zig
│   │   ├── openai.zig
│   │   └── ollama.zig
│   ├── agent/                # Agent 系统
│   │   ├── orchestrator.zig
│   │   ├── executor.zig
│   │   └── memory.zig
│   ├── tools/                # 工具实现
│   │   ├── registry.zig
│   │   ├── file_read.zig
│   │   ├── file_write.zig
│   │   ├── bash.zig
│   │   ├── glob.zig
│   │   └── grep.zig
│   ├── sandbox/              # 安全沙箱
│   │   ├── sandbox.zig
│   │   ├── linux.zig
│   │   └── permission.zig
│   ├── tui/                  # 终端界面
│   │   ├── app.zig
│   │   ├── state.zig
│   │   ├── pages/
│   │   │   └── chat.zig
│   │   └── widgets/
│   │       ├── editor.zig
│   │       └── message_list.zig
│   └── storage/              # 持久化
│       ├── db.zig
│       └── sqlite.zig
└── tests/
```

---

## 分阶段实施

### Phase 1: MVP 基础功能

**目标**: 基础对话 + 简单 TUI

**步骤**:
1. 配置 build.zig.zon 添加依赖 (libvaxis, zqlite)
2. 实现 `src/core/config.zig` - 配置文件加载
3. 实现 `src/providers/provider.zig` - 提供商接口
4. 实现 `src/providers/anthropic.zig` - Claude API 客户端
   - HTTP 请求封装
   - SSE 流式解析
5. 实现 `src/tui/app.zig` - 基础 TUI 框架
6. 实现 `src/tui/widgets/editor.zig` - 输入编辑器
7. 实现 `src/tui/pages/chat.zig` - 聊天页面

**验证**: 能与 Claude 进行基础对话，TUI 显示消息

### Phase 2: 多提供商 + 工具系统

**目标**: 支持多 LLM + 工具调用

**步骤**:
1. 实现 `src/providers/openai.zig` - OpenAI API
2. 实现 `src/providers/ollama.zig` - 本地模型
3. 实现 `src/tools/registry.zig` - 工具注册表
4. 实现核心工具:
   - `file_read.zig` - 文件读取
   - `file_write.zig` - 文件写入
   - `bash.zig` - 命令执行
   - `glob.zig` - 文件搜索
   - `grep.zig` - 内容搜索
5. 实现 `src/agent/executor.zig` - 工具执行器
6. 实现权限确认对话框

**验证**: 能调用工具完成文件操作任务

### Phase 3: 会话管理 + TUI 增强

**目标**: 持久化 + 丰富界面

**步骤**:
1. 实现 `src/storage/sqlite.zig` - SQLite 操作
2. 实现会话 CRUD 操作
3. 实现 `src/tui/widgets/message_list.zig` - 虚拟滚动
4. 实现侧边栏会话列表
5. 集成 Koino 渲染 Markdown
6. 集成 tree-sitter 语法高亮
7. 实现快捷键系统

**验证**: 会话持久化，代码块高亮显示

### Phase 4: 安全沙箱

**目标**: 进程隔离 + 权限控制

**步骤**:
1. 实现 `src/sandbox/sandbox.zig` - 沙箱主逻辑
2. 实现 `src/sandbox/linux.zig`:
   - namespace 隔离 (mount, pid, net)
   - seccomp syscall 过滤
   - rlimit 资源限制
3. 实现 `src/sandbox/permission.zig` - 权限管理
4. 配置文件权限规则

**验证**: 命令在沙箱中执行，文件访问受限

---

## 关键实现细节

### SSE 流式解析

```zig
// src/utils/sse.zig
pub fn parseSSEStream(reader: anytype, callback: *const fn([]const u8) void) !void {
    var line_buf: [4096]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..];
            if (!std.mem.eql(u8, data, "[DONE]")) {
                callback(data);
            }
        }
    }
}
```

### Provider 接口模式

```zig
// src/providers/provider.zig
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        complete: *const fn(*anyopaque, CompletionRequest) anyerror!CompletionResponse,
        stream: *const fn(*anyopaque, CompletionRequest, StreamCallback) anyerror!void,
    };

    pub fn complete(self: Provider, req: CompletionRequest) !CompletionResponse {
        return self.vtable.complete(self.ptr, req);
    }
};
```

---

## 关键文件清单

| 优先级 | 文件路径 | 说明 |
|-------|---------|------|
| P0 | `build.zig.zon` | 添加依赖声明 |
| P0 | `src/providers/provider.zig` | 提供商接口 |
| P0 | `src/providers/anthropic.zig` | Claude API |
| P0 | `src/tui/app.zig` | TUI 入口 |
| P1 | `src/tools/registry.zig` | 工具注册 |
| P1 | `src/agent/executor.zig` | 工具执行 |
| P2 | `src/storage/sqlite.zig` | 持久化 |
| P3 | `src/sandbox/sandbox.zig` | 沙箱 |

---

## 验证方式

1. **MVP 验证**:
   ```bash
   zig build run
   # 输入消息，验证 Claude 响应
   ```

2. **工具验证**:
   ```bash
   # 在 TUI 中请求读取文件
   # 验证工具调用和权限提示
   ```

3. **集成测试**:
   ```bash
   zig build test
   # 运行单元测试和集成测试
   ```

---

## 风险和缓解

| 风险 | 影响 | 缓解措施 |
|-----|-----|---------|
| Zig 版本兼容性 | 高 | 锁定 0.15.2，监控上游变更 |
| Windows 沙箱 | 中 | 初期仅支持 Linux/macOS |
| libvaxis API 变更 | 中 | 封装适配层，减少耦合 |
| SSE 解析边缘情况 | 低 | 完善错误处理，添加测试 |

---

## 技术调研结果

### Claude Code
- 技术栈: TypeScript + React + Ink + Bun
- 约 90% 代码由 Claude Code 自己编写
- 选择原因: 模型已擅长的技术栈

### OpenCode
- 技术栈: **Go** + Bubble Tea (TUI)
- 客户端/服务端架构
- GitHub: https://github.com/opencode-ai/opencode

### OpenAI Codex CLI
- 技术栈: **Rust** (原 TypeScript)
- 目标: 零依赖、高性能
- GitHub: https://github.com/openai/codex

### Zig 实现优势
1. 单二进制文件分发
2. 编译速度快
3. 内存安全且简洁
4. 优秀的交叉编译支持
5. 可直接使用 C 库
