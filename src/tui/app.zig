const std = @import("std");
const vaxis = @import("vaxis");

const message = @import("../models/message.zig");

/// 自定义事件类型
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    // 可以添加更多事件类型
};

/// TUI 应用状态
pub const AppState = enum {
    running,
    quitting,
};

/// 聊天消息显示格式
pub const ChatMessage = struct {
    role: message.Role,
    content: []const u8,
    owned: bool = false, // 是否拥有内容的所有权

    pub fn deinit(self: *ChatMessage, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.content);
        }
    }
};

/// TUI 应用
pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    loop: vaxis.Loop(Event),
    state: AppState,
    messages: std.ArrayList(ChatMessage),
    input_buffer: std.ArrayList(u8),
    scroll_offset: usize,
    tty_buf: [4096]u8,

    const Self = @This();

    /// 初始化 TUI 应用
    pub fn init(allocator: std.mem.Allocator) !Self {
        // 初始化 TTY
        var tty_buf: [4096]u8 = undefined;
        var tty = try vaxis.Tty.init(&tty_buf);
        errdefer tty.deinit();

        // 初始化 Vaxis
        var vx = try vaxis.Vaxis.init(allocator, .{});
        errdefer vx.deinit(allocator, tty.writer());

        // 初始化事件循环
        var loop: vaxis.Loop(Event) = .{
            .tty = &tty,
            .vaxis = &vx,
        };
        try loop.init();

        return .{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .loop = loop,
            .state = .running,
            .messages = .empty,
            .input_buffer = .empty,
            .scroll_offset = 0,
            .tty_buf = tty_buf,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        // 停止事件循环
        self.loop.stop();

        // 重置终端状态
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();

        // 清理消息
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
    }

    /// 进入 alt screen 模式
    pub fn start(self: *Self) !void {
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1_000_000_000);
        try self.loop.start();
    }

    /// 处理键盘事件
    pub fn handleKey(self: *Self, key: vaxis.Key) !?[]const u8 {
        // Ctrl+C 或 Ctrl+Q 退出
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
            self.state = .quitting;
            return null;
        }

        // Enter 发送消息
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.input_buffer.items.len > 0) {
                // 复制输入内容
                const input = try self.allocator.dupe(u8, self.input_buffer.items);
                self.input_buffer.clearRetainingCapacity();
                return input;
            }
            return null;
        }

        // Backspace 删除字符
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.input_buffer.items.len > 0) {
                _ = self.input_buffer.pop();
            }
            return null;
        }

        // 处理普通字符输入
        if (key.text) |text| {
            try self.input_buffer.appendSlice(self.allocator, text);
        }

        return null;
    }

    /// 添加用户消息
    pub fn addUserMessage(self: *Self, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = owned_content,
            .owned = true,
        });
    }

    /// 添加助手消息
    pub fn addAssistantMessage(self: *Self, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = owned_content,
            .owned = true,
        });
    }

    /// 添加系统消息
    pub fn addSystemMessage(self: *Self, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = owned_content,
            .owned = true,
        });
    }

    /// 渲染界面
    pub fn render(self: *Self) !void {
        const win = self.vx.window();
        win.clear();

        // 获取窗口尺寸
        const height = win.height;
        const width = win.width;

        if (height < 5 or width < 20) {
            // 窗口太小
            return;
        }

        // 标题栏
        self.renderTitle(win, width);

        // 消息区域 (留 3 行给输入区)
        const message_area_height: u16 = if (height > 4) height - 4 else 1;
        self.renderMessages(win, width, message_area_height);

        // 分隔线
        self.renderSeparator(win, width, if (height > 3) height - 3 else 1);

        // 输入区域
        self.renderInput(win, width, if (height > 2) height - 2 else height - 1);

        // 刷新屏幕
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
    }

    fn renderTitle(self: *Self, win: vaxis.Window, width: u16) void {
        _ = self;
        const title = " Zpencode - AI Code Assistant ";
        const title_len: u16 = @intCast(title.len);
        const start_x: u16 = if (width > title_len) (width - title_len) / 2 else 0;

        const segment = vaxis.Segment{
            .text = title,
            .style = .{
                .fg = .{ .index = 0 }, // Black
                .bg = .{ .index = 6 }, // Cyan
                .bold = true,
            },
        };

        _ = win.print(&.{segment}, .{ .col_offset = start_x, .row_offset = 0 });
    }

    fn renderMessages(self: *Self, win: vaxis.Window, width: u16, height: u16) void {
        var row: u16 = 1;

        // 计算显示起点
        const total_messages = self.messages.items.len;
        const max_display: usize = @intCast(height);
        const start_idx = if (total_messages > max_display) total_messages - max_display else 0;

        for (self.messages.items[start_idx..]) |msg| {
            if (row >= height + 1) break;

            const prefix = switch (msg.role) {
                .user => "> ",
                .assistant => "< ",
                else => "  ",
            };

            const color: vaxis.Color = switch (msg.role) {
                .user => .{ .index = 2 }, // Green
                .assistant => .{ .index = 4 }, // Blue
                else => .{ .index = 7 }, // White
            };

            // 渲染前缀
            const prefix_segment = vaxis.Segment{
                .text = prefix,
                .style = .{ .fg = color, .bold = true },
            };
            _ = win.print(&.{prefix_segment}, .{ .row_offset = row, .col_offset = 0 });

            // 渲染内容 (截断到窗口宽度)
            const max_content_len: usize = if (width > 2) @as(usize, width) - 2 else @as(usize, width);
            const display_content = if (msg.content.len > max_content_len)
                msg.content[0..max_content_len]
            else
                msg.content;

            const content_segment = vaxis.Segment{
                .text = display_content,
                .style = .{ .fg = color },
            };
            _ = win.print(&.{content_segment}, .{ .row_offset = row, .col_offset = 2 });

            row += 1;
        }
    }

    fn renderSeparator(self: *Self, win: vaxis.Window, width: u16, row: u16) void {
        _ = self;
        var i: u16 = 0;
        while (i < width) : (i += 1) {
            win.writeCell(i, row, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = .{ .fg = .{ .index = 8 } }, // Gray
            });
        }
    }

    fn renderInput(self: *Self, win: vaxis.Window, width: u16, row: u16) void {
        // 渲染提示符
        const prompt_segment = vaxis.Segment{
            .text = "> ",
            .style = .{ .fg = .{ .index = 3 }, .bold = true }, // Yellow
        };
        _ = win.print(&.{prompt_segment}, .{ .row_offset = row, .col_offset = 0 });

        // 渲染输入内容
        const max_input_len: usize = if (width > 2) @as(usize, width) - 2 else 0;
        if (self.input_buffer.items.len > 0) {
            const display_input = if (self.input_buffer.items.len > max_input_len)
                self.input_buffer.items[self.input_buffer.items.len - max_input_len ..]
            else
                self.input_buffer.items;

            const input_segment = vaxis.Segment{
                .text = display_input,
                .style = .{},
            };
            _ = win.print(&.{input_segment}, .{ .row_offset = row, .col_offset = 2 });
        }

        // 显示光标位置
        const cursor_col: u16 = @intCast(@min(self.input_buffer.items.len + 2, width - 1));
        win.showCursor(cursor_col, row);
    }

    /// 运行事件循环
    pub fn run(self: *Self, on_message: *const fn ([]const u8) ?[]const u8) !void {
        try self.start();

        while (self.state == .running) {
            // 等待事件
            const event = self.loop.nextEvent();

            switch (event) {
                .key_press => |key| {
                    if (try self.handleKey(key)) |user_input| {
                        defer self.allocator.free(user_input);

                        // 添加用户消息
                        try self.addUserMessage(user_input);
                        try self.render();

                        // 获取 AI 响应
                        if (on_message(user_input)) |response| {
                            try self.addAssistantMessage(response);
                        }
                    }
                },
                .winsize => |ws| {
                    try self.vx.resize(self.allocator, self.tty.writer(), ws);
                },
            }

            try self.render();
        }
    }
};

/// 创建并运行 TUI 应用
pub fn runApp(allocator: std.mem.Allocator, on_message: *const fn ([]const u8) ?[]const u8) !void {
    var app = try App.init(allocator);
    defer app.deinit();

    try app.run(on_message);
}

test "app initialization" {
    // 测试只验证编译，不实际运行 TUI
    // 因为 TUI 需要真实终端
}
