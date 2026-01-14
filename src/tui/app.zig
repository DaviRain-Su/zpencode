const std = @import("std");
const vaxis = @import("vaxis");

const msg_mod = @import("../models/message.zig");
const config_mod = @import("../core/config.zig");
const prompt = @import("prompt.zig");

const log = std.log.scoped(.tui);

/// 自定义事件类型
pub const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// 聊天消息
pub const ChatMessage = struct {
    role: msg_mod.Role,
    content: []const u8,
};

/// TUI 上下文
pub const TuiContext = struct {
    allocator: std.mem.Allocator,
    config: *config_mod.Config,
    on_message: *const fn ([]const u8) ?[]const u8,
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
    // TUI 上下文
    var ctx = TuiContext{
        .allocator = allocator,
        .config = cfg,
        .on_message = on_message,
    };

    // 初始化 TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    // 初始化 Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

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
    try render(&vx, writer, &messages, &input_buffer);

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

                                // 显示 "Thinking..." 提示
                                try messages.append(allocator, .{
                                    .role = .system,
                                    .content = try allocator.dupe(u8, "⏳ Thinking..."),
                                });
                                try render(&vx, writer, &messages, &input_buffer);

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
                    try render(&vx, writer, &messages, &input_buffer);
                    continue;
                }

                // Backspace 删除字符
                if (key.matches(vaxis.Key.backspace, .{})) {
                    if (input_buffer.items.len > 0) {
                        _ = input_buffer.pop();
                    }
                    try render(&vx, writer, &messages, &input_buffer);
                    continue;
                }

                // 普通字符输入
                if (key.text) |text| {
                    try input_buffer.appendSlice(allocator, text);
                    try render(&vx, writer, &messages, &input_buffer);
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, writer, ws);
                try render(&vx, writer, &messages, &input_buffer);
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
) !void {
    const win = vx.window();
    win.clear();

    const height = win.height;
    const width = win.width;

    if (height < 5 or width < 20) {
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
        const message_area_height: u16 = if (height > 4) height - 4 else 1;

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
        const sep_row: u16 = if (height > 3) height - 3 else 1;
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
        const input_row: u16 = if (height > 2) height - 2 else height - 1;

        _ = win.print(&.{.{
            .text = "> ",
            .style = .{ .fg = .{ .index = 3 }, .bold = true },
        }}, .{ .row_offset = input_row, .col_offset = 0 });

        if (input_buffer.items.len > 0) {
            const max_len: usize = if (width > 2) @as(usize, width) - 2 else 0;
            const display = if (input_buffer.items.len > max_len)
                input_buffer.items[input_buffer.items.len - max_len ..]
            else
                input_buffer.items;

            _ = win.print(&.{.{
                .text = display,
                .style = .{},
            }}, .{ .row_offset = input_row, .col_offset = 2 });
        }

        const cursor_col: u16 = @intCast(@min(input_buffer.items.len + 2, width - 1));
        win.showCursor(cursor_col, input_row);
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
