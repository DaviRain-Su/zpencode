const std = @import("std");
const vaxis = @import("vaxis");

const message = @import("../models/message.zig");

/// TUI 应用状态
pub const AppState = enum {
    running,
    quitting,
};

/// 聊天消息显示格式
pub const ChatMessage = struct {
    role: message.Role,
    content: []const u8,
};

/// TUI 应用
pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    state: AppState,
    messages: std.ArrayList(ChatMessage),
    input_buffer: std.ArrayList(u8),
    scroll_offset: usize,

    const Self = @This();

    /// 初始化 TUI 应用
    pub fn init(allocator: std.mem.Allocator) !Self {
        var vx = try vaxis.Vaxis.init(allocator, .{});
        errdefer vx.deinit();

        return .{
            .allocator = allocator,
            .vx = vx,
            .state = .running,
            .messages = std.ArrayList(ChatMessage).init(allocator),
            .input_buffer = std.ArrayList(u8).init(allocator),
            .scroll_offset = 0,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.vx.deinit();
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
    }

    /// 进入 raw 模式并初始化终端
    pub fn start(self: *Self) !void {
        try self.vx.enterAltScreen();
        try self.vx.queryTerminal();
    }

    /// 退出 raw 模式
    pub fn stop(self: *Self) void {
        self.vx.exitAltScreen() catch {};
    }

    /// 处理键盘事件
    pub fn handleKey(self: *Self, key: vaxis.Key) !?[]const u8 {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
            self.state = .quitting;
            return null;
        }

        if (key.matches(.enter, .{})) {
            if (self.input_buffer.items.len > 0) {
                // 复制输入内容
                const input = try self.allocator.dupe(u8, self.input_buffer.items);
                self.input_buffer.clearRetainingCapacity();
                return input;
            }
            return null;
        }

        if (key.matches(.backspace, .{})) {
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
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = content,
        });
    }

    /// 添加助手消息
    pub fn addAssistantMessage(self: *Self, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = content,
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
        const message_area_height = height - 4;
        self.renderMessages(win, width, message_area_height);

        // 分隔线
        self.renderSeparator(win, width, height - 3);

        // 输入区域
        self.renderInput(win, width, height - 2);

        // 刷新屏幕
        try self.vx.render();
    }

    fn renderTitle(self: *Self, win: vaxis.Window, width: usize) void {
        _ = self;
        const title = " Zpencode - AI Code Assistant ";
        const start_x = if (width > title.len) (width - title.len) / 2 else 0;

        const segment = vaxis.Segment{
            .text = title,
            .style = .{
                .fg = .{ .index = 0 }, // Black
                .bg = .{ .index = 6 }, // Cyan
                .bold = true,
            },
        };

        _ = win.printSegment(.{ .row = 0, .col = start_x }, &.{segment});
    }

    fn renderMessages(self: *Self, win: vaxis.Window, width: usize, height: usize) void {
        var row: usize = 1;

        // 计算显示起点
        const total_messages = self.messages.items.len;
        const start_idx = if (total_messages > height) total_messages - height else 0;

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
            _ = win.printSegment(.{ .row = row, .col = 0 }, &.{prefix_segment});

            // 渲染内容 (截断到窗口宽度)
            const max_content_len = if (width > 2) width - 2 else width;
            const display_content = if (msg.content.len > max_content_len)
                msg.content[0..max_content_len]
            else
                msg.content;

            const content_segment = vaxis.Segment{
                .text = display_content,
                .style = .{ .fg = color },
            };
            _ = win.printSegment(.{ .row = row, .col = 2 }, &.{content_segment});

            row += 1;
        }
    }

    fn renderSeparator(self: *Self, win: vaxis.Window, width: usize, row: usize) void {
        _ = self;
        var i: usize = 0;
        while (i < width) : (i += 1) {
            const segment = vaxis.Segment{
                .text = "─",
                .style = .{ .fg = .{ .index = 8 } }, // Gray
            };
            _ = win.printSegment(.{ .row = row, .col = i }, &.{segment});
        }
    }

    fn renderInput(self: *Self, win: vaxis.Window, width: usize, row: usize) void {
        // 渲染提示符
        const prompt_segment = vaxis.Segment{
            .text = "> ",
            .style = .{ .fg = .{ .index = 3 }, .bold = true }, // Yellow
        };
        _ = win.printSegment(.{ .row = row, .col = 0 }, &.{prompt_segment});

        // 渲染输入内容
        const max_input_len = if (width > 2) width - 2 else 0;
        if (self.input_buffer.items.len > 0) {
            const display_input = if (self.input_buffer.items.len > max_input_len)
                self.input_buffer.items[self.input_buffer.items.len - max_input_len ..]
            else
                self.input_buffer.items;

            const input_segment = vaxis.Segment{
                .text = display_input,
                .style = .{},
            };
            _ = win.printSegment(.{ .row = row, .col = 2 }, &.{input_segment});
        }

        // 显示光标位置
        const cursor_col = @min(self.input_buffer.items.len + 2, width - 1);
        win.showCursor(.{ .row = row, .col = cursor_col });
    }

    /// 运行事件循环
    pub fn run(self: *Self, on_message: *const fn ([]const u8) ?[]const u8) !void {
        try self.start();
        defer self.stop();

        while (self.state == .running) {
            // 等待事件
            const event = self.vx.nextEvent();

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
                    try self.vx.resize(.{ .rows = ws.rows, .cols = ws.cols });
                },
                else => {},
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
