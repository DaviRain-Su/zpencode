const std = @import("std");
const vaxis = @import("vaxis");

const config_mod = @import("../core/config.zig");
const models_mod = @import("../core/models.zig");

const log = std.log.scoped(.prompt);

/// 交互式提示事件
pub const PromptEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

/// 选择结果
pub const SelectResult = union(enum) {
    selected: usize,
    cancelled,
};

/// 输入结果
pub const InputResult = union(enum) {
    confirmed: []const u8,
    cancelled,
};

/// 运行选择菜单
pub fn runSelect(
    allocator: std.mem.Allocator,
    title: []const u8,
    options: []const []const u8,
) !SelectResult {
    // 初始化 TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    // 初始化 Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

    // 初始化事件循环
    var loop: vaxis.Loop(PromptEvent) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // 进入 alt screen
    try vx.enterAltScreen(writer);
    try writer.flush();

    // 查询终端能力
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    var selected_index: usize = 0;

    // 初始渲染
    try renderSelect(&vx, writer, title, options, selected_index);

    // 事件循环
    while (true) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                // Ctrl+C 或 Esc 取消
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    return .cancelled;
                }

                // Enter 确认选择
                if (key.matches(vaxis.Key.enter, .{})) {
                    return .{ .selected = selected_index };
                }

                // 上箭头
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                    if (selected_index > 0) {
                        selected_index -= 1;
                    }
                }

                // 下箭头
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                    if (selected_index < options.len - 1) {
                        selected_index += 1;
                    }
                }

                try renderSelect(&vx, writer, title, options, selected_index);
            },
            .winsize => |ws| {
                try vx.resize(allocator, writer, ws);
                try renderSelect(&vx, writer, title, options, selected_index);
            },
        }
    }
}

fn renderSelect(
    vx: *vaxis.Vaxis,
    writer: anytype,
    title: []const u8,
    options: []const []const u8,
    selected_index: usize,
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

    // 计算起始位置（居中）
    const content_height: u16 = @intCast(options.len + 3);
    const start_row: u16 = if (height > content_height) (height - content_height) / 2 else 0;

    // 标题
    _ = win.print(&.{.{
        .text = "? ",
        .style = .{ .fg = .{ .index = 2 }, .bold = true }, // 绿色问号
    }}, .{ .row_offset = start_row, .col_offset = 2 });

    _ = win.print(&.{.{
        .text = title,
        .style = .{ .fg = .{ .index = 7 }, .bold = true },
    }}, .{ .row_offset = start_row, .col_offset = 4 });

    // 选项列表
    for (options, 0..) |option, i| {
        const row: u16 = start_row + 2 + @as(u16, @intCast(i));
        const is_selected = i == selected_index;

        if (is_selected) {
            // 选中项：显示 > 和高亮
            _ = win.print(&.{.{
                .text = "  > ",
                .style = .{ .fg = .{ .index = 6 }, .bold = true }, // 青色箭头
            }}, .{ .row_offset = row, .col_offset = 2 });

            _ = win.print(&.{.{
                .text = option,
                .style = .{ .fg = .{ .index = 6 }, .bold = true },
            }}, .{ .row_offset = row, .col_offset = 6 });
        } else {
            // 未选中项
            _ = win.print(&.{.{
                .text = "    ",
                .style = .{},
            }}, .{ .row_offset = row, .col_offset = 2 });

            _ = win.print(&.{.{
                .text = option,
                .style = .{ .fg = .{ .index = 8 } }, // 灰色
            }}, .{ .row_offset = row, .col_offset = 6 });
        }
    }

    // 底部提示
    const hint = "Use arrow keys to move, Enter to select, Esc to cancel";
    const hint_row: u16 = start_row + 3 + @as(u16, @intCast(options.len));
    _ = win.print(&.{.{
        .text = hint,
        .style = .{ .fg = .{ .index = 8 } },
    }}, .{ .row_offset = hint_row, .col_offset = 2 });

    try vx.render(writer);
    try writer.flush();
}

/// 运行文本输入
pub fn runInput(
    allocator: std.mem.Allocator,
    title: []const u8,
    is_password: bool,
) !InputResult {
    // 初始化 TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    // 初始化 Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

    // 初始化事件循环
    var loop: vaxis.Loop(PromptEvent) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // 进入 alt screen
    try vx.enterAltScreen(writer);
    try writer.flush();

    // 查询终端能力
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    var input_buffer: std.ArrayList(u8) = .empty;
    defer input_buffer.deinit(allocator);

    // 初始渲染
    try renderInput(&vx, writer, title, &input_buffer, is_password);

    // 事件循环
    while (true) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                // Ctrl+C 或 Esc 取消
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    return .cancelled;
                }

                // Enter 确认
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (input_buffer.items.len > 0) {
                        return .{ .confirmed = try allocator.dupe(u8, input_buffer.items) };
                    }
                }

                // Backspace 删除
                if (key.matches(vaxis.Key.backspace, .{})) {
                    if (input_buffer.items.len > 0) {
                        _ = input_buffer.pop();
                    }
                }

                // 普通字符输入
                if (key.text) |text| {
                    try input_buffer.appendSlice(allocator, text);
                }

                try renderInput(&vx, writer, title, &input_buffer, is_password);
            },
            .winsize => |ws| {
                try vx.resize(allocator, writer, ws);
                try renderInput(&vx, writer, title, &input_buffer, is_password);
            },
        }
    }
}

fn renderInput(
    vx: *vaxis.Vaxis,
    writer: anytype,
    title: []const u8,
    input_buffer: *std.ArrayList(u8),
    is_password: bool,
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

    // 计算起始位置（居中）
    const start_row: u16 = height / 2 - 1;

    // 标题
    _ = win.print(&.{.{
        .text = "? ",
        .style = .{ .fg = .{ .index = 2 }, .bold = true },
    }}, .{ .row_offset = start_row, .col_offset = 2 });

    _ = win.print(&.{.{
        .text = title,
        .style = .{ .fg = .{ .index = 7 }, .bold = true },
    }}, .{ .row_offset = start_row, .col_offset = 4 });

    // 输入框
    const input_row: u16 = start_row + 2;
    _ = win.print(&.{.{
        .text = "> ",
        .style = .{ .fg = .{ .index = 6 }, .bold = true },
    }}, .{ .row_offset = input_row, .col_offset = 2 });

    if (input_buffer.items.len > 0) {
        if (is_password) {
            // 密码模式显示 *
            var mask_buf: [256]u8 = undefined;
            const mask_len = @min(input_buffer.items.len, 256);
            for (0..mask_len) |i| {
                mask_buf[i] = '*';
            }
            _ = win.print(&.{.{
                .text = mask_buf[0..mask_len],
                .style = .{},
            }}, .{ .row_offset = input_row, .col_offset = 4 });
        } else {
            _ = win.print(&.{.{
                .text = input_buffer.items,
                .style = .{},
            }}, .{ .row_offset = input_row, .col_offset = 4 });
        }
    }

    // 光标位置
    const cursor_col: u16 = @intCast(@min(input_buffer.items.len + 4, width - 1));
    win.showCursor(cursor_col, input_row);

    // 底部提示
    const hint = "Enter to confirm, Esc to cancel";
    const hint_row: u16 = start_row + 4;
    _ = win.print(&.{.{
        .text = hint,
        .style = .{ .fg = .{ .index = 8 } },
    }}, .{ .row_offset = hint_row, .col_offset = 2 });

    try vx.render(writer);
    try writer.flush();
}

/// 配置向导 - 完整的首次配置流程
pub fn runConfigWizard(allocator: std.mem.Allocator, cfg: *config_mod.Config) !bool {
    // 1. 选择 Provider
    const providers = [_][]const u8{ "anthropic", "openai", "deepseek", "ollama" };
    const provider_result = try runSelect(allocator, "Select AI Provider:", &providers);

    switch (provider_result) {
        .cancelled => return false,
        .selected => |idx| {
            const provider_name = providers[idx];
            const provider_type = config_mod.ProviderType.fromString(provider_name) orelse return false;
            cfg.default_provider = provider_type;

            // 获取 provider 配置
            const pcfg = cfg.getProvider(provider_name) orelse return false;

            // 2. 如果不是 ollama，需要 API key
            var api_key: ?[]const u8 = null;
            if (idx != 3) { // ollama (index 3) 不需要 API key
                const key_result = try runInput(allocator, "Enter API Key:", true);

                switch (key_result) {
                    .cancelled => return false,
                    .confirmed => |key| {
                        api_key = key;
                        try cfg.setApiKey(provider_name, key);
                    },
                }
            }
            defer if (api_key) |k| allocator.free(k);

            // 3. 动态获取模型列表
            const models_list = models_mod.fetchModels(
                allocator,
                provider_type,
                pcfg.base_url,
                api_key,
            ) catch |err| {
                log.warn("Failed to fetch models: {}", .{err});
                // 使用默认列表
                const default_models = switch (idx) {
                    0 => &[_][]const u8{ "claude-sonnet-4-20250514", "claude-opus-4-20250514" },
                    1 => &[_][]const u8{ "gpt-4o", "gpt-4o-mini" },
                    2 => &[_][]const u8{ "deepseek-chat", "deepseek-reasoner" },
                    3 => &[_][]const u8{ "codellama", "llama3" },
                    else => &[_][]const u8{"default"},
                };
                const model_result = try runSelect(allocator, "Select Model:", default_models);
                switch (model_result) {
                    .cancelled => return false,
                    .selected => |model_idx| {
                        if (cfg.providers.getPtr(provider_name)) |p| {
                            p.model = default_models[model_idx];
                        }
                    },
                }
                try cfg.saveToFile();
                return true;
            };
            defer models_mod.freeModels(allocator, models_list);

            // 构建显示列表
            var model_names = try allocator.alloc([]const u8, models_list.len);
            defer allocator.free(model_names);
            for (models_list, 0..) |m, i| {
                model_names[i] = m.name;
            }

            const model_result = try runSelect(allocator, "Select Model:", model_names);

            switch (model_result) {
                .cancelled => return false,
                .selected => |model_idx| {
                    // 更新模型配置
                    if (cfg.providers.getPtr(provider_name)) |p| {
                        // 需要复制字符串因为 models_list 会被释放
                        const model_id = models_list[model_idx].id;
                        // 检查是否是静态字符串
                        if (models_list[model_idx].owned) {
                            p.model = try allocator.dupe(u8, model_id);
                        } else {
                            p.model = model_id;
                        }
                    }
                },
            }

            // 保存配置
            try cfg.saveToFile();
            return true;
        },
    }
}
