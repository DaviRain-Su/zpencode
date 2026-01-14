# Zpencode Roadmap

> Zig 实现的 AI 代码助手 CLI 工具，对标 Claude Code 和 OpenCode

## Version Overview

| Version | Description | Status |
|---------|-------------|--------|
| v0.1.0 | MVP 基础功能 | 🔨 Currently Working |
| v0.2.0 | 多提供商 + 工具系统 | ⏳ Planned |
| v0.3.0 | 会话管理 + TUI 增强 | ⏳ Planned |
| v0.4.0 | 安全沙箱 | ⏳ Planned |
| v1.0.0 | 稳定版发布 | ⏳ Planned |

---

## v0.1.0 - MVP 基础功能 🔨

**目标**: 基础对话 + 简单 TUI

### Core Features
- ⏳ 项目结构和依赖配置
- ⏳ 配置管理 (config.zig)
- ⏳ Provider 接口定义
- ⏳ Anthropic Claude API 客户端
- ⏳ 基础 TUI 框架 (libvaxis)
- ⏳ 简单聊天界面

### Acceptance Criteria
- 能够与 Claude API 进行基础对话
- TUI 界面能够显示消息和接收输入
- 配置文件支持 API key 设置

---

## v0.2.0 - 多提供商 + 工具系统 ⏳

**目标**: 支持多 LLM + 工具调用

### Core Features
- OpenAI GPT API 客户端
- Ollama 本地模型支持
- 工具注册表
- 文件读写工具
- 命令执行工具
- 代码搜索工具 (glob, grep)

### Acceptance Criteria
- 支持切换 AI 提供商
- 能够执行工具调用完成文件操作

---

## v0.3.0 - 会话管理 + TUI 增强 ⏳

**目标**: 持久化 + 丰富界面

### Core Features
- SQLite 会话持久化
- 会话 CRUD 操作
- 虚拟滚动消息列表
- 侧边栏会话列表
- Markdown 渲染
- 语法高亮
- 快捷键系统

### Acceptance Criteria
- 会话能够保存和恢复
- 代码块有语法高亮显示

---

## v0.4.0 - 安全沙箱 ⏳

**目标**: 进程隔离 + 权限控制

### Core Features
- Linux namespace 隔离
- seccomp syscall 过滤
- rlimit 资源限制
- 权限管理系统
- 配置文件权限规则

### Acceptance Criteria
- 命令在沙箱中执行
- 文件访问受限于配置规则

---

## v1.0.0 - 稳定版发布 ⏳

**目标**: 生产就绪

### Core Features
- 完整功能验证
- 性能优化
- 跨平台测试 (Linux, macOS)
- 完善文档
- 发布二进制

### Acceptance Criteria
- 所有功能稳定可用
- 无已知重大 bug
- 文档完整

---

## Technical Stack

| Component | Library | Status |
|-----------|---------|--------|
| TUI | libvaxis | ✅ Added |
| AI SDK | ai-zig | ✅ Added (30+ providers) |
| HTTP | std.http.Client (via ai-zig) | ✅ Included |
| JSON | std.json | ✅ Built-in |
| SQLite | zqlite.zig | ⏳ Planned |
| Markdown | Koino | ⏳ Planned |
| Syntax Highlight | tree-sitter | ⏳ Planned |

### AI Providers (via ai-zig)

- Anthropic Claude ✅
- OpenAI GPT ✅
- Google Gemini ✅
- Ollama (local) ✅
- 26+ more providers...
