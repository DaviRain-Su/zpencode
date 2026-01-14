# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Session 2026-01-14-001

**Date**: 2026-01-14
**Goal**: 项目初始化和 MVP 基础架构

#### Completed Work
1. 项目结构设计和技术选型
2. 添加核心依赖:
   - libvaxis v0.5.1 (TUI 框架)
   - ai-zig (AI SDK，支持 30+ 提供商)
3. 创建目录结构 (core, models, providers, agent, tools, sandbox, tui, storage)
4. 实现基础模块:
   - `src/models/message.zig` - 消息模型
   - `src/core/config.zig` - 配置管理
5. 创建文档驱动开发结构

#### Technical Decisions
- 使用 ai-zig 替代自行实现 AI 客户端 (节省大量开发时间)
- 采用 libvaxis 作为 TUI 框架 (1.5k+ stars，生产级)
- 遵循 doc-driven-dev 规范管理开发流程

#### Next Steps
- [ ] 实现 AI 提供商集成模块
- [ ] 实现基础 TUI 框架
- [ ] 验证 MVP 基础对话功能

---

## Version History

### v0.1.0 (Planned)
MVP 基础功能版本

### v0.0.0 (Current)
项目初始化
