const std = @import("std");
const vaxis = @import("vaxis");
const ai = @import("ai");
const anthropic = @import("anthropic");
const openai = @import("openai");
const deepseek = @import("deepseek");

const zpencode = @import("zpencode");
const config = zpencode.config;
const message = zpencode.message;
const tui = zpencode.tui;
const prompt = zpencode.prompt;

/// 全局配置
var global_config: ?*config.Config = null;
var global_allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;

    // 初始化配置
    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    try cfg.loadDefaults();

    // 从配置文件加载（覆盖默认值）
    const config_loaded = cfg.loadFromFile() catch false;

    global_config = &cfg;

    // 检查是否需要首次配置（没有配置文件且没有环境变量中的 API key）
    const needs_setup = blk: {
        if (config_loaded) break :blk false;
        // 检查是否有可用的 API key（配置文件或环境变量）
        if (cfg.getDefaultProvider()) |pcfg| {
            if (pcfg.api_key != null) break :blk false;
            if (config.Config.loadApiKeyFromEnv(pcfg.provider_type) != null) break :blk false;
        }
        break :blk true;
    };

    // 解析命令行参数
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var use_simple_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--simple") or std.mem.eql(u8, arg, "-s")) {
            use_simple_mode = true;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    // 首次运行时显示配置向导
    if (needs_setup and !use_simple_mode) {
        const stdout = std.fs.File.stdout();
        _ = stdout.write("\n  Welcome to Zpencode! Let's configure your AI provider.\n\n") catch {};

        const wizard_success = prompt.runConfigWizard(allocator, &cfg) catch |err| blk: {
            std.log.warn("Config wizard failed: {}", .{err});
            break :blk false;
        };

        if (!wizard_success) {
            _ = stdout.write("\n  Setup cancelled. You can run /config later to configure.\n") catch {};
            _ = stdout.write("  Or set ANTHROPIC_API_KEY / OPENAI_API_KEY environment variable.\n\n") catch {};
        }
    }

    if (use_simple_mode) {
        // 简单的命令行模式
        try runSimpleMode(allocator, &cfg);
    } else {
        // TUI 模式 - 如果无法初始化 TUI，回退到简单模式
        runTuiMode(allocator, &cfg) catch |err| {
            std.log.warn("TUI mode unavailable ({s}), falling back to simple mode", .{@errorName(err)});
            try runSimpleMode(allocator, &cfg);
        };
    }
}

fn printHelp() void {
    const stdout = std.fs.File.stdout();
    _ = stdout.write(
        \\Zpencode - AI Code Assistant
        \\
        \\Usage: zpencode [OPTIONS]
        \\
        \\Options:
        \\  -s, --simple    Run in simple CLI mode (no TUI)
        \\  -h, --help      Show this help message
        \\
        \\TUI Mode (default):
        \\  Ctrl+C or Ctrl+Q - Exit
        \\  Enter            - Send message
        \\  Backspace        - Delete character
        \\
        \\Simple Mode:
        \\  /quit, /exit     - Exit the program
        \\  /help            - Show help
        \\  /clear           - Clear conversation
        \\  /provider        - Show current provider
        \\
    ) catch {};
}

fn runTuiMode(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    try tui.runApp(allocator, cfg, &onMessageCallback);
}

fn onMessageCallback(user_input: []const u8) ?[]const u8 {
    const cfg = global_config orelse return null;
    return getAIResponse(global_allocator, cfg, user_input) catch |err| {
        // 返回错误信息给用户显示
        return std.fmt.allocPrint(global_allocator, "[Error: {s}]", .{@errorName(err)}) catch null;
    };
}

fn runSimpleMode(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    // 显示欢迎信息
    _ = try stdout_file.write(
        \\
        \\  ╔═══════════════════════════════════════╗
        \\  ║     Zpencode - AI Code Assistant      ║
        \\  ║     Powered by Zig + ai-zig           ║
        \\  ╚═══════════════════════════════════════╝
        \\
    );

    // 显示配置信息
    var info_buf: [256]u8 = undefined;
    const info = try std.fmt.bufPrint(&info_buf, "  Provider: {s}\n  Model: {s}\n\n", .{
        cfg.default_provider.toString(),
        if (cfg.getDefaultProvider()) |p| p.model else "unknown",
    });
    _ = try stdout_file.write(info);

    _ = try stdout_file.write(
        \\  Commands:
        \\    /quit or Ctrl+C - Exit
        \\    /help - Show help
        \\    /clear - Clear messages
        \\
        \\
    );

    var conversation = message.Conversation.init(allocator, null);
    defer conversation.deinit();

    _ = try stdout_file.write("Enter your message (or /quit to exit):\n\n");

    var line_buf: [4096]u8 = undefined;
    var out_buf: [8192]u8 = undefined;

    while (true) {
        _ = try stdout_file.write("> ");

        // 读取用户输入
        const bytes_read = stdin_file.read(&line_buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (bytes_read == 0) break;

        const input = std.mem.trim(u8, line_buf[0..bytes_read], " \t\r\n");

        if (input.len == 0) continue;

        // 处理命令
        if (std.mem.startsWith(u8, input, "/")) {
            if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/exit")) {
                _ = try stdout_file.write("\nGoodbye!\n");
                break;
            }
            if (std.mem.eql(u8, input, "/help")) {
                _ = try stdout_file.write(
                    \\
                    \\Commands:
                    \\  /quit, /exit - Exit the program
                    \\  /help       - Show this help
                    \\  /clear      - Clear conversation
                    \\  /provider   - Show current provider
                    \\
                    \\
                );
                continue;
            }
            if (std.mem.eql(u8, input, "/clear")) {
                conversation.clear();
                _ = try stdout_file.write("\nConversation cleared.\n\n");
                continue;
            }
            if (std.mem.eql(u8, input, "/provider")) {
                const msg = try std.fmt.bufPrint(&out_buf, "\nProvider: {s}\nModel: {s}\n\n", .{
                    cfg.default_provider.toString(),
                    if (cfg.getDefaultProvider()) |p| p.model else "unknown",
                });
                _ = try stdout_file.write(msg);
                continue;
            }
            const msg = try std.fmt.bufPrint(&out_buf, "\nUnknown command: {s}\nType /help for available commands.\n\n", .{input});
            _ = try stdout_file.write(msg);
            continue;
        }

        // 添加用户消息
        try conversation.addMessage(message.Message.init(.user, input));

        // 调用 AI
        _ = try stdout_file.write("\n< Thinking...\n");

        const response = getAIResponse(allocator, cfg, input) catch |err| {
            const err_msg = try std.fmt.bufPrint(&out_buf, "< Error: {}\n\n", .{err});
            _ = try stdout_file.write(err_msg);
            continue;
        };
        defer if (response) |r| allocator.free(r);

        if (response) |r| {
            try conversation.addMessage(message.Message.init(.assistant, r));
            _ = try stdout_file.write("< ");
            _ = try stdout_file.write(r);
            _ = try stdout_file.write("\n\n");
        } else {
            _ = try stdout_file.write("< (No response)\n\n");
        }
    }
}

fn getAIResponse(allocator: std.mem.Allocator, cfg: *config.Config, user_input: []const u8) !?[]u8 {
    const provider_config = cfg.getDefaultProvider() orelse return null;

    // 获取 API key
    const api_key = provider_config.api_key orelse
        config.Config.loadApiKeyFromEnv(provider_config.provider_type) orelse {
        return error.MissingApiKey;
    };

    // 使用 ai-zig SDK
    switch (provider_config.provider_type) {
        .anthropic => {
            var provider = anthropic.createAnthropicWithSettings(allocator, .{
                .api_key = api_key,
            });
            defer provider.deinit();

            var model = provider.languageModel(provider_config.model);
            var lm_interface = model.asLanguageModel();

            const result = try ai.generateText(allocator, .{
                .model = &lm_interface,
                .prompt = user_input,
            });

            return try allocator.dupe(u8, result.text);
        },
        .openai => {
            var provider = openai.createOpenAIWithSettings(allocator, .{
                .api_key = api_key,
            });
            defer provider.deinit();

            var model = provider.languageModel(provider_config.model);
            var lm_interface = model.asLanguageModel();

            const result = try ai.generateText(allocator, .{
                .model = &lm_interface,
                .prompt = user_input,
            });

            return try allocator.dupe(u8, result.text);
        },
        .deepseek => {
            var provider = deepseek.createDeepSeekWithSettings(allocator, .{
                .api_key = api_key,
            });
            defer provider.deinit();

            var model = provider.languageModel(provider_config.model);
            var lm_interface = model.asLanguageModel();

            const result = try ai.generateText(allocator, .{
                .model = &lm_interface,
                .prompt = user_input,
            });

            return try allocator.dupe(u8, result.text);
        },
        .ollama => {
            // Ollama 使用 OpenAI 兼容 API
            var provider = openai.createOpenAIWithSettings(allocator, .{
                .base_url = provider_config.base_url,
            });
            defer provider.deinit();

            var model = provider.languageModel(provider_config.model);
            var lm_interface = model.asLanguageModel();

            const result = try ai.generateText(allocator, .{
                .model = &lm_interface,
                .prompt = user_input,
            });

            return try allocator.dupe(u8, result.text);
        },
        .custom => return null,
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
