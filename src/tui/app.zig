const std = @import("std");
const vaxis = @import("vaxis");

const msg_mod = @import("../models/message.zig");
const config_mod = @import("../core/config.zig");
const prompt = @import("prompt.zig");

const log = std.log.scoped(.tui);
const unicode = std.unicode;

/// 计算 UTF-8 字符串的显示宽度（中文字符宽度为 2）
fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var iter = unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        // 简单判断：CJK 字符宽度为 2，其他为 1
        if (cp >= 0x4E00 and cp <= 0x9FFF) {
            width += 2; // CJK 基本汉字
        } else if (cp >= 0x3400 and cp <= 0x4DBF) {
            width += 2; // CJK 扩展 A
        } else if (cp >= 0x20000 and cp <= 0x2A6DF) {
            width += 2; // CJK 扩展 B
        } else if (cp >= 0xFF00 and cp <= 0xFFEF) {
            width += 2; // 全角字符
        } else if (cp >= 0x3000 and cp <= 0x303F) {
            width += 2; // CJK 标点
        } else {
            width += 1;
        }
    }
    return width;
}

/// 删除 UTF-8 字符串末尾的一个完整字符，返回删除的字节数
fn popUtf8Char(buffer: *std.ArrayList(u8)) usize {
    if (buffer.items.len == 0) return 0;

    // 从末尾向前找 UTF-8 字符的起始位置
    var i: usize = buffer.items.len;
    while (i > 0) {
        i -= 1;
        const byte = buffer.items[i];
        // UTF-8 起始字节：0xxxxxxx (ASCII) 或 11xxxxxx (多字节起始)
        if ((byte & 0x80) == 0 or (byte & 0xC0) == 0xC0) {
            const removed = buffer.items.len - i;
            buffer.shrinkRetainingCapacity(i);
            return removed;
        }
    }
    // 回退：删除一个字节
    _ = buffer.pop();
    return 1;
}

/// 自定义事件类型
pub const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    paste: []const u8, // 粘贴事件（IME 输入也可能通过这个发送）
};

/// 聊天消息
pub const ChatMessage = struct {
    role: msg_mod.Role,
    content: []const u8,
};

/// 流式响应状态
pub const StreamingState = struct {
    allocator: std.mem.Allocator,
    is_streaming: bool = false,
    content: std.ArrayList(u8) = .empty,
    completed: bool = false,
    has_error: bool = false,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) StreamingState {
        return .{
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *StreamingState) void {
        self.content.deinit(self.allocator);
    }

    pub fn reset(self: *StreamingState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.content.clearRetainingCapacity();
        self.is_streaming = false;
        self.completed = false;
        self.has_error = false;
    }

    pub fn appendChunk(self: *StreamingState, chunk: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.content.appendSlice(self.allocator, chunk) catch {};
    }

    pub fn getContent(self: *StreamingState) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.content.items;
    }
};

/// 流式回调函数类型
pub const StreamCallback = *const fn (user_input: []const u8, state: *StreamingState) void;

/// TUI 上下文
pub const TuiContext = struct {
    allocator: std.mem.Allocator,
    config: *config_mod.Config,
    on_message: *const fn ([]const u8) ?[]const u8,
    on_message_stream: ?StreamCallback = null, // 可选的流式回调
};

/// 状态栏信息
pub const StatusInfo = struct {
    provider: []const u8,
    model: []const u8,
    total_tokens: usize,
};

/// 命令处理结果
const CommandResult = union(enum) {
    none, // 不是命令
    handled, // 命令已处理
    quit, // 退出
    clear, // 清空消息
    config_wizard, // 启动配置向导
    message: []const u8, // 显示消息
};

/// 处理命令
fn handleCommand(
    allocator: std.mem.Allocator,
    input: []const u8,
    ctx: *TuiContext,
) !CommandResult {
    if (!std.mem.startsWith(u8, input, "/")) {
        return .none;
    }

    // 解析命令
    var iter = std.mem.splitScalar(u8, input[1..], ' ');
    const cmd = iter.next() orelse return .handled;
    const arg = iter.next();

    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "q")) {
        return .quit;
    }

    if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "c")) {
        return .clear;
    }

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
        return .{ .message = try allocator.dupe(u8,
            \\Commands:
            \\  /help, /h, /?           - Show this help
            \\  /config                 - Run interactive configuration wizard
            \\  /provider, /p           - Show current provider
            \\  /provider <name>        - Switch provider (anthropic/openai/deepseek/ollama)
            \\  /apikey <key>           - Set API key for current provider
            \\  /apikey <provider> <key> - Set API key for specific provider
            \\  /model                  - Show current model
            \\  /clear, /c              - Clear messages
            \\  /quit, /q               - Exit
        ) };
    }

    if (std.mem.eql(u8, cmd, "config")) {
        return .config_wizard;
    }

    if (std.mem.eql(u8, cmd, "provider") or std.mem.eql(u8, cmd, "p")) {
        if (arg) |provider_name| {
            // 切换 provider
            if (config_mod.ProviderType.fromString(provider_name)) |new_provider| {
                // 检查是否有这个 provider 的配置
                if (ctx.config.getProvider(provider_name) != null) {
                    ctx.config.default_provider = new_provider;
                    // 保存到配置文件
                    ctx.config.saveToFile() catch |err| {
                        log.warn("Failed to save config: {}", .{err});
                    };
                    const new_cfg = ctx.config.getDefaultProvider().?;
                    return .{ .message = try std.fmt.allocPrint(allocator,
                        "Switched to {s} ({s}) (saved)", .{ provider_name, new_cfg.model }) };
                } else {
                    return .{ .message = try std.fmt.allocPrint(allocator,
                        "Provider '{s}' not configured", .{provider_name}) };
                }
            } else {
                return .{ .message = try allocator.dupe(u8,
                    "Unknown provider. Available: anthropic, openai, deepseek, ollama") };
            }
        } else {
            // 显示当前 provider
            const p = ctx.config.default_provider.toString();
            const m = if (ctx.config.getDefaultProvider()) |cfg| cfg.model else "unknown";
            return .{ .message = try std.fmt.allocPrint(allocator,
                "Current: {s} ({s})\nAvailable: anthropic, openai, ollama", .{ p, m }) };
        }
    }

    if (std.mem.eql(u8, cmd, "model") or std.mem.eql(u8, cmd, "m")) {
        const cfg = ctx.config.getDefaultProvider() orelse {
            return .{ .message = try allocator.dupe(u8, "No provider configured") };
        };
        return .{ .message = try std.fmt.allocPrint(allocator,
            "Model: {s}\nProvider: {s}", .{ cfg.model, ctx.config.default_provider.toString() }) };
    }

    if (std.mem.eql(u8, cmd, "apikey") or std.mem.eql(u8, cmd, "key") or std.mem.eql(u8, cmd, "k")) {
        if (arg) |first_arg| {
            // 检查是否有第二个参数
            const second_arg = iter.next();

            if (second_arg) |api_key| {
                // /apikey <provider> <key> - 设置指定 provider 的 key
                if (config_mod.ProviderType.fromString(first_arg)) |_| {
                    ctx.config.setApiKey(first_arg, api_key) catch {
                        return .{ .message = try std.fmt.allocPrint(allocator,
                            "Failed to set API key for {s}", .{first_arg}) };
                    };
                    // 保存到配置文件
                    ctx.config.saveToFile() catch |err| {
                        log.warn("Failed to save config: {}", .{err});
                    };
                    return .{ .message = try std.fmt.allocPrint(allocator,
                        "API key set for {s} (saved)", .{first_arg}) };
                } else {
                    return .{ .message = try allocator.dupe(u8,
                        "Unknown provider. Use: /apikey <provider> <key>") };
                }
            } else {
                // /apikey <key> - 设置当前 provider 的 key
                ctx.config.setDefaultApiKey(first_arg) catch {
                    return .{ .message = try allocator.dupe(u8, "Failed to set API key") };
                };
                // 保存到配置文件
                ctx.config.saveToFile() catch |err| {
                    log.warn("Failed to save config: {}", .{err});
                };
                return .{ .message = try std.fmt.allocPrint(allocator,
                    "API key set for {s} (saved)", .{ctx.config.default_provider.toString()}) };
            }
        } else {
            // 显示当前 API key 状态
            const provider_name = ctx.config.default_provider.toString();
            const has_key = blk: {
                if (ctx.config.getDefaultProvider()) |cfg| {
                    if (cfg.api_key != null) break :blk true;
                }
                if (config_mod.Config.loadApiKeyFromEnv(ctx.config.default_provider) != null) break :blk true;
                break :blk false;
            };
            const status = if (has_key) "configured" else "not set";
            return .{ .message = try std.fmt.allocPrint(allocator,
                "API key for {s}: {s}\nUsage: /apikey <key> or /apikey <provider> <key>", .{ provider_name, status }) };
        }
    }

    return .{ .message = try std.fmt.allocPrint(allocator,
        "Unknown command: /{s}\nType /help for available commands.", .{cmd}) };
}

/// 运行 TUI 应用
pub fn runApp(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    on_message: *const fn ([]const u8) ?[]const u8,
) !void {
    return runAppWithStreaming(allocator, cfg, on_message, null);
}

/// 带流式回调的 TUI 应用
pub fn runAppWithStreaming(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    on_message: *const fn ([]const u8) ?[]const u8,
    on_message_stream: ?StreamCallback,
) !void {
    var vaxis_arena = std.heap.ArenaAllocator.init(allocator);
    defer vaxis_arena.deinit();
    const vaxis_allocator = vaxis_arena.allocator();

    // TUI 上下文
    var ctx = TuiContext{
        .allocator = allocator,
        .config = cfg,
        .on_message = on_message,
        .on_message_stream = on_message_stream,
    };

    // 初始化 TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    // 初始化 Vaxis（禁用 kitty keyboard 协议以改善 IME 兼容性）
    var vx = try vaxis.init(vaxis_allocator, .{
        .system_clipboard_allocator = allocator,
        // 禁用 kitty keyboard 增强功能，改善 IME（中文输入法）兼容性
        .kitty_keyboard_flags = .{
            .disambiguate = false,
            .report_events = false,
            .report_alternate_keys = false,
            .report_all_as_ctl_seqs = false,
            .report_text = false,
        },
    });
    defer vx.deinit(vaxis_allocator, writer);

    // 初始化事件循环
    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();

    // 启动事件循环
    try loop.start();
    defer loop.stop();

    // 进入 alt screen
    try vx.enterAltScreen(writer);

    // 启用 bracketed paste（支持 IME 输入）
    try vx.setBracketedPaste(writer, true);

    // 刷新
    try writer.flush();

    // 查询终端能力
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    // 状态
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer {
        for (messages.items) |msg| {
            allocator.free(msg.content);
        }
        messages.deinit(allocator);
    }

    var input_buffer: std.ArrayList(u8) = .empty;
    defer input_buffer.deinit(allocator);

    // Token 计数（粗略估计：字符数/4）
    var total_tokens: usize = 0;

    // 辅助函数：获取当前状态栏信息
    const getStatusInfo = struct {
        fn call(config: *config_mod.Config, tokens: usize) StatusInfo {
            return .{
                .provider = config.default_provider.toString(),
                .model = if (config.getDefaultProvider()) |c| c.model else "unknown",
                .total_tokens = tokens,
            };
        }
    }.call;

    // 添加欢迎消息
    try messages.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "Welcome to Zpencode - AI Code Assistant"),
    });

    // 显示当前 provider
    {
        const p = cfg.default_provider.toString();
        const m = if (cfg.getDefaultProvider()) |c| c.model else "unknown";
        try messages.append(allocator, .{
            .role = .system,
            .content = try std.fmt.allocPrint(allocator, "Provider: {s} | Model: {s}", .{ p, m }),
        });
    }

    try messages.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "Type /help for commands. Ctrl+C to exit."),
    });

    // 初始渲染
    try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));

    // 主事件循环
    var running = true;
    while (running) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                // Ctrl+C 退出
                if (key.matches('c', .{ .ctrl = true })) {
                    running = false;
                    continue;
                }

                // Enter 发送消息
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (input_buffer.items.len > 0) {
                        const user_input = try allocator.dupe(u8, input_buffer.items);
                        input_buffer.clearRetainingCapacity();

                        // 检查是否是命令
                        const cmd_result = try handleCommand(allocator, user_input, &ctx);

                        switch (cmd_result) {
                            .none => {
                                // 不是命令，发送给 AI
                                try messages.append(allocator, .{
                                    .role = .user,
                                    .content = user_input,
                                });

                                // 检查是否有流式回调
                                if (ctx.on_message_stream) |stream_callback| {
                                    // 流式输出模式
                                    var stream_state = StreamingState.init(allocator);
                                    defer stream_state.deinit();

                                    // 添加空的 AI 响应占位
                                    try messages.append(allocator, .{
                                        .role = .assistant,
                                        .content = try allocator.dupe(u8, "▌"),
                                    });

                                    // 在后台线程中调用流式回调
                                    stream_state.is_streaming = true;
                                    const thread = try std.Thread.spawn(.{}, struct {
                                        fn run(cb: StreamCallback, input: []const u8, state: *StreamingState) void {
                                            cb(input, state);
                                            state.mutex.lock();
                                            state.completed = true;
                                            state.is_streaming = false;
                                            state.mutex.unlock();
                                        }
                                    }.run, .{ stream_callback, user_input, &stream_state });

                                    // 轮询更新显示
                                    var last_len: usize = 0;
                                    while (true) {
                                        stream_state.mutex.lock();
                                        const current_content = stream_state.content.items;
                                        const completed = stream_state.completed;
                                        stream_state.mutex.unlock();

                                        // 更新显示
                                        if (current_content.len > last_len or completed) {
                                            // 更新最后一条消息
                                            if (messages.items.len > 0) {
                                                allocator.free(messages.items[messages.items.len - 1].content);
                                                if (completed and current_content.len > 0) {
                                                    messages.items[messages.items.len - 1].content = try allocator.dupe(u8, current_content);
                                                } else if (current_content.len > 0) {
                                                    // 添加光标指示符
                                                    const display = try std.fmt.allocPrint(allocator, "{s}▌", .{current_content});
                                                    messages.items[messages.items.len - 1].content = display;
                                                } else {
                                                    messages.items[messages.items.len - 1].content = try allocator.dupe(u8, "▌");
                                                }
                                            }
                                            try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
                                            last_len = current_content.len;
                                        }

                                        if (completed) break;

                                        // 短暂休眠避免忙等待
                                        std.Thread.sleep(50 * std.time.ns_per_ms);
                                    }

                                    thread.join();

                                    // 更新 token 计数
                                    stream_state.mutex.lock();
                                    const final_content = stream_state.content.items;
                                    total_tokens += (user_input.len + final_content.len) / 4;
                                    stream_state.mutex.unlock();

                                    if (stream_state.has_error) {
                                        // 更新为错误消息
                                        if (messages.items.len > 0) {
                                            allocator.free(messages.items[messages.items.len - 1].content);
                                            messages.items[messages.items.len - 1].content = try allocator.dupe(u8, "Error: Streaming failed");
                                            messages.items[messages.items.len - 1].role = .system;
                                        }
                                    }
                                } else {
                                    // 非流式模式（原有逻辑）
                                    // 显示 "Thinking..." 提示
                                    try messages.append(allocator, .{
                                        .role = .system,
                                        .content = try allocator.dupe(u8, "⏳ Thinking..."),
                                    });
                                    try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));

                                    // 获取 AI 响应
                                    const ai_response = on_message(user_input);

                                    // 移除 "Thinking..." 消息
                                    if (messages.items.len > 0) {
                                        if (messages.pop()) |last| {
                                            allocator.free(last.content);
                                        }
                                    }

                                    // 显示 AI 响应或错误
                                    if (ai_response) |response| {
                                        defer allocator.free(response); // 释放回调返回的内存
                                        if (response.len > 0) {
                                            try messages.append(allocator, .{
                                                .role = .assistant,
                                                .content = try allocator.dupe(u8, response),
                                            });
                                            // 更新 token 计数（粗略估计：用户输入 + AI 响应）
                                            total_tokens += (user_input.len + response.len) / 4;
                                        } else {
                                            try messages.append(allocator, .{
                                                .role = .system,
                                                .content = try allocator.dupe(u8, "Error: Empty response from AI"),
                                            });
                                        }
                                    } else {
                                        try messages.append(allocator, .{
                                            .role = .system,
                                            .content = try allocator.dupe(u8, "Error: No response (check API key)"),
                                        });
                                    }
                                }
                            },
                            .handled => {
                                allocator.free(user_input);
                            },
                            .quit => {
                                allocator.free(user_input);
                                running = false;
                                continue;
                            },
                            .clear => {
                                allocator.free(user_input);
                                // 清空消息
                                for (messages.items) |msg| {
                                    allocator.free(msg.content);
                                }
                                messages.clearRetainingCapacity();
                                try messages.append(allocator, .{
                                    .role = .system,
                                    .content = try allocator.dupe(u8, "Messages cleared."),
                                });
                            },
                            .config_wizard => {
                                allocator.free(user_input);
                                // 退出 alt screen 运行配置向导
                                try vx.exitAltScreen(writer);
                                try writer.flush();
                                loop.stop();

                                // 运行配置向导
                                const wizard_success = prompt.runConfigWizard(allocator, ctx.config) catch false;

                                // 重新进入 TUI
                                try loop.start();
                                try vx.enterAltScreen(writer);
                                try writer.flush();

                                if (wizard_success) {
                                    // 更新 provider 显示
                                    const p = ctx.config.default_provider.toString();
                                    const m = if (ctx.config.getDefaultProvider()) |c| c.model else "unknown";
                                    try messages.append(allocator, .{
                                        .role = .system,
                                        .content = try std.fmt.allocPrint(allocator, "Config updated: {s} | {s}", .{ p, m }),
                                    });
                                } else {
                                    try messages.append(allocator, .{
                                        .role = .system,
                                        .content = try allocator.dupe(u8, "Configuration cancelled."),
                                    });
                                }
                            },
                            .message => |msg| {
                                allocator.free(user_input);
                                try messages.append(allocator, .{
                                    .role = .system,
                                    .content = msg,
                                });
                            },
                        }
                    }
                    try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
                    continue;
                }

                // Backspace 删除字符（支持 UTF-8 多字节字符）
                if (key.matches(vaxis.Key.backspace, .{})) {
                    _ = popUtf8Char(&input_buffer);
                    try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
                    continue;
                }

                // 普通字符输入
                if (key.text) |text| {
                    try input_buffer.appendSlice(allocator, text);
                    try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
                }
            },
            .winsize => |ws| {
                try vx.resize(vaxis_allocator, writer, ws);
                try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
            },
            .paste => |text| {
                // 处理粘贴事件（IME 输入也可能通过这里）
                try input_buffer.appendSlice(allocator, text);
                try render(&vx, writer, &messages, &input_buffer, getStatusInfo(cfg, total_tokens));
                // 释放粘贴的文本内存
                allocator.free(text);
            },
            else => {},
        }
    }
}

fn render(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    messages: *std.ArrayList(ChatMessage),
    input_buffer: *std.ArrayList(u8),
    status_info: StatusInfo,
) !void {
    const win = vx.window();
    win.clear();

    const height = win.height;
    const width = win.width;

    if (height < 6 or width < 20) {
        try vx.render(writer);
        try writer.flush();
        return;
    }

    // 标题栏
    {
        const title = " Zpencode - AI Code Assistant ";
        const title_len: u16 = @intCast(title.len);
        const start_x: u16 = if (width > title_len) (width - title_len) / 2 else 0;

        const segment = vaxis.Segment{
            .text = title,
            .style = .{
                .fg = .{ .index = 0 },
                .bg = .{ .index = 6 },
                .bold = true,
            },
        };
        _ = win.print(&.{segment}, .{ .col_offset = start_x, .row_offset = 0 });
    }

    // 消息区域 - 先计算所有行数
    {
        const message_area_height: u16 = if (height > 5) height - 5 else 1;

        // 计算总行数（每条消息可能有多行）
        var total_lines: usize = 0;
        for (messages.items) |msg| {
            var line_iter = std.mem.splitScalar(u8, msg.content, '\n');
            while (line_iter.next()) |_| {
                total_lines += 1;
            }
        }

        // 确定从哪里开始显示（滚动到最新消息）
        const max_display: usize = @intCast(message_area_height);
        var lines_to_skip: usize = 0;
        if (total_lines > max_display) {
            lines_to_skip = total_lines - max_display;
        }

        // 渲染消息
        var row: u16 = 1;
        var skipped: usize = 0;

        for (messages.items) |msg| {
            if (row >= message_area_height + 1) break;

            const prefix = switch (msg.role) {
                .user => "> ",
                .assistant => "< ",
                else => "  ",
            };

            const color: vaxis.Color = switch (msg.role) {
                .user => .{ .index = 2 }, // green
                .assistant => .{ .index = 4 }, // blue
                else => .{ .index = 8 }, // gray for system
            };

            // 分行显示消息内容
            var first_line = true;
            var line_iter = std.mem.splitScalar(u8, msg.content, '\n');
            while (line_iter.next()) |line| {
                // 跳过早期行（滚动效果）
                if (skipped < lines_to_skip) {
                    skipped += 1;
                    first_line = false;
                    continue;
                }

                if (row >= message_area_height + 1) break;

                // 只在第一行显示前缀
                if (first_line) {
                    _ = win.print(&.{.{
                        .text = prefix,
                        .style = .{ .fg = color, .bold = true },
                    }}, .{ .row_offset = row, .col_offset = 0 });
                    first_line = false;
                } else {
                    // 续行用空格对齐
                    _ = win.print(&.{.{
                        .text = "  ",
                        .style = .{},
                    }}, .{ .row_offset = row, .col_offset = 0 });
                }

                const max_len: usize = if (width > 2) @as(usize, width) - 2 else @as(usize, width);
                const content = if (line.len > max_len) line[0..max_len] else line;

                _ = win.print(&.{.{
                    .text = content,
                    .style = .{ .fg = color },
                }}, .{ .row_offset = row, .col_offset = 2 });

                row += 1;
            }
        }
    }

    // 分隔线
    {
        const sep_row: u16 = if (height > 4) height - 4 else 1;
        var i: u16 = 0;
        while (i < width) : (i += 1) {
            win.writeCell(i, sep_row, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = .{ .index = 8 } },
            });
        }
    }

    // 输入区域
    {
        const input_row: u16 = if (height > 3) height - 3 else height - 2;

        _ = win.print(&.{.{
            .text = "> ",
            .style = .{ .fg = .{ .index = 3 }, .bold = true },
        }}, .{ .row_offset = input_row, .col_offset = 0 });

        if (input_buffer.items.len > 0) {
            const max_width: usize = if (width > 2) @as(usize, width) - 2 else 0;
            const current_width = displayWidth(input_buffer.items);

            // 如果显示宽度超过最大宽度，从末尾截取
            const display = if (current_width > max_width) blk: {
                // 从末尾向前遍历，找到合适的起始位置
                var width_from_end: usize = 0;
                var start: usize = input_buffer.items.len;

                while (start > 0) {
                    // 找到前一个 UTF-8 字符的起始位置
                    var char_start = start - 1;
                    while (char_start > 0 and (input_buffer.items[char_start] & 0xC0) == 0x80) {
                        char_start -= 1;
                    }

                    // 解码这个字符
                    const char_bytes = input_buffer.items[char_start..start];
                    var iter = unicode.Utf8Iterator{ .bytes = char_bytes, .i = 0 };
                    const cp = iter.nextCodepoint() orelse break;

                    // 计算字符宽度
                    const char_width: usize = if ((cp >= 0x4E00 and cp <= 0x9FFF) or
                        (cp >= 0x3400 and cp <= 0x4DBF) or
                        (cp >= 0x20000 and cp <= 0x2A6DF) or
                        (cp >= 0xFF00 and cp <= 0xFFEF) or
                        (cp >= 0x3000 and cp <= 0x303F)) 2 else 1;

                    if (width_from_end + char_width > max_width) break;
                    width_from_end += char_width;
                    start = char_start;
                }

                break :blk input_buffer.items[start..];
            } else input_buffer.items;

            _ = win.print(&.{.{
                .text = display,
                .style = .{},
            }}, .{ .row_offset = input_row, .col_offset = 2 });
        }

        // 计算光标位置（使用显示宽度而非字节数）
        const display_len = displayWidth(input_buffer.items);
        const cursor_col: u16 = @intCast(@min(display_len + 2, width - 1));
        win.showCursor(cursor_col, input_row);
    }

    // 状态栏分隔线
    {
        const sep_row: u16 = if (height > 2) height - 2 else height - 1;
        var i: u16 = 0;
        while (i < width) : (i += 1) {
            win.writeCell(i, sep_row, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = .{ .index = 8 } },
            });
        }
    }

    // 状态栏
    {
        const status_row: u16 = height - 1;

        // 格式: " Provider: xxx | Model: xxx | Tokens: xxx "
        var status_buf: [256]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status_buf, " Provider: {s} | Model: {s} | Tokens: {d} ", .{
            status_info.provider,
            status_info.model,
            status_info.total_tokens,
        }) catch " Status ";

        // 状态栏背景
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            win.writeCell(col, status_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = .{ .index = 8 } },
            });
        }

        // 状态栏文字
        _ = win.print(&.{.{
            .text = status_text,
            .style = .{
                .fg = .{ .index = 15 }, // white
                .bg = .{ .index = 8 }, // gray background
            },
        }}, .{ .row_offset = status_row, .col_offset = 0 });
    }

    try vx.render(writer);
    try writer.flush();
}

// 导出用于 root.zig
pub const App = struct {
    pub fn init(_: std.mem.Allocator) !App {
        return .{};
    }
    pub fn deinit(_: *App) void {}
};

pub const AppState = enum { running, quitting };

test "compile check" {}
