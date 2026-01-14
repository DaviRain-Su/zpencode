const std = @import("std");
const vaxis = @import("vaxis");

const msg_mod = @import("../models/message.zig");

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

/// 运行 TUI 应用
pub fn runApp(allocator: std.mem.Allocator, on_message: *const fn ([]const u8) ?[]const u8) !void {
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
    try messages.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "Type your message and press Enter. Ctrl+C to exit."),
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

                        // 添加用户消息
                        try messages.append(allocator, .{
                            .role = .user,
                            .content = user_input,
                        });

                        try render(&vx, writer, &messages, &input_buffer);

                        // 获取 AI 响应
                        if (on_message(user_input)) |response| {
                            try messages.append(allocator, .{
                                .role = .assistant,
                                .content = try allocator.dupe(u8, response),
                            });
                        } else {
                            try messages.append(allocator, .{
                                .role = .system,
                                .content = try allocator.dupe(u8, "(No response)"),
                            });
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

    // 消息区域
    {
        const message_area_height: u16 = if (height > 4) height - 4 else 1;
        var row: u16 = 1;

        const total = messages.items.len;
        const max_display: usize = @intCast(message_area_height);
        const start_idx = if (total > max_display) total - max_display else 0;

        for (messages.items[start_idx..]) |msg| {
            if (row >= message_area_height + 1) break;

            const prefix = switch (msg.role) {
                .user => "> ",
                .assistant => "< ",
                else => "  ",
            };

            const color: vaxis.Color = switch (msg.role) {
                .user => .{ .index = 2 },
                .assistant => .{ .index = 4 },
                else => .{ .index = 7 },
            };

            _ = win.print(&.{.{
                .text = prefix,
                .style = .{ .fg = color, .bold = true },
            }}, .{ .row_offset = row, .col_offset = 0 });

            const max_len: usize = if (width > 2) @as(usize, width) - 2 else @as(usize, width);
            const content = if (msg.content.len > max_len) msg.content[0..max_len] else msg.content;

            _ = win.print(&.{.{
                .text = content,
                .style = .{ .fg = color },
            }}, .{ .row_offset = row, .col_offset = 2 });

            row += 1;
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
