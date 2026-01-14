const std = @import("std");
const config_mod = @import("config.zig");

/// 模型信息
pub const ModelInfo = struct {
    id: []const u8,
    name: []const u8, // 显示名称
    owned: bool, // 是否需要释放内存
};

/// 获取提供商的可用模型列表
pub fn fetchModels(
    allocator: std.mem.Allocator,
    provider_type: config_mod.ProviderType,
    base_url: []const u8,
    api_key: ?[]const u8,
) ![]ModelInfo {
    return switch (provider_type) {
        .anthropic => fetchAnthropicModels(allocator),
        .openai => fetchOpenAIModels(allocator, base_url, api_key),
        .deepseek => fetchDeepSeekModels(allocator),
        .ollama => fetchOllamaModels(allocator, base_url),
        .custom => &[_]ModelInfo{},
    };
}

/// DeepSeek 模型（硬编码，DeepSeek 没有公开的模型列表 API）
fn fetchDeepSeekModels(allocator: std.mem.Allocator) ![]ModelInfo {
    _ = allocator;
    // DeepSeek 可用模型
    const models = comptime [_]ModelInfo{
        .{ .id = "deepseek-chat", .name = "DeepSeek Chat (V3, Fast)", .owned = false },
        .{ .id = "deepseek-reasoner", .name = "DeepSeek Reasoner (V3, Thinking)", .owned = false },
    };
    return @constCast(&models);
}

/// Anthropic 模型（硬编码，因为没有公开 API）
fn fetchAnthropicModels(allocator: std.mem.Allocator) ![]ModelInfo {
    _ = allocator;
    // Anthropic 没有模型列表 API，返回已知模型
    const models = comptime [_]ModelInfo{
        .{ .id = "claude-sonnet-4-20250514", .name = "Claude Sonnet 4 (Latest)", .owned = false },
        .{ .id = "claude-opus-4-20250514", .name = "Claude Opus 4 (Most Capable)", .owned = false },
        .{ .id = "claude-haiku-3-20250314", .name = "Claude Haiku 3 (Fast)", .owned = false },
        .{ .id = "claude-3-5-sonnet-20241022", .name = "Claude 3.5 Sonnet", .owned = false },
        .{ .id = "claude-3-opus-20240229", .name = "Claude 3 Opus", .owned = false },
    };
    return @constCast(&models);
}

/// 从 OpenAI API 获取模型列表
fn fetchOpenAIModels(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
) ![]ModelInfo {
    const key = api_key orelse {
        // 没有 API key，返回默认列表
        const models = comptime [_]ModelInfo{
            .{ .id = "gpt-4o", .name = "GPT-4o (Recommended)", .owned = false },
            .{ .id = "gpt-4o-mini", .name = "GPT-4o Mini (Fast)", .owned = false },
            .{ .id = "gpt-4-turbo", .name = "GPT-4 Turbo", .owned = false },
            .{ .id = "gpt-3.5-turbo", .name = "GPT-3.5 Turbo", .owned = false },
        };
        return @constCast(&models);
    };

    // 构建 URL
    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{base_url});
    defer allocator.free(url);

    // 创建 HTTP 客户端
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // 创建请求
    var auth_header_buf: [256]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{key});

    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
    });
    defer req.deinit();

    // 发送请求
    try req.sendBodiless();

    // 接收响应
    var head_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) {
        // API 错误，返回默认列表
        const models = comptime [_]ModelInfo{
            .{ .id = "gpt-4o", .name = "GPT-4o", .owned = false },
            .{ .id = "gpt-4o-mini", .name = "GPT-4o Mini", .owned = false },
        };
        return @constCast(&models);
    }

    // 读取响应体
    var body_buf: [65536]u8 = undefined;
    var body_reader = response.reader(&body_buf);
    const body = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(body);

    // 解析 JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "gpt-4o", .name = "GPT-4o", .owned = false },
        };
        return @constCast(&models);
    };
    defer parsed.deinit();

    // 提取模型列表
    var models: std.ArrayList(ModelInfo) = .empty;
    errdefer {
        for (models.items) |m| {
            if (m.owned) {
                allocator.free(m.id);
                allocator.free(m.name);
            }
        }
        models.deinit(allocator);
    }

    if (parsed.value.object.get("data")) |data| {
        if (data == .array) {
            for (data.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("id")) |id_val| {
                        if (id_val == .string) {
                            const id = id_val.string;
                            // 只包含 GPT 模型
                            if (std.mem.startsWith(u8, id, "gpt-")) {
                                try models.append(allocator, .{
                                    .id = try allocator.dupe(u8, id),
                                    .name = try allocator.dupe(u8, id),
                                    .owned = true,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    if (models.items.len == 0) {
        models.deinit(allocator);
        const default_models = comptime [_]ModelInfo{
            .{ .id = "gpt-4o", .name = "GPT-4o", .owned = false },
        };
        return @constCast(&default_models);
    }

    return models.toOwnedSlice(allocator);
}

/// 从 Ollama API 获取本地模型列表
fn fetchOllamaModels(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]ModelInfo {
    // 构建 URL
    const url = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{base_url});
    defer allocator.free(url);

    // 创建 HTTP 客户端
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
            .{ .id = "llama3", .name = "Llama 3", .owned = false },
        };
        return @constCast(&models);
    };

    // 创建请求
    var req = client.request(.GET, uri, .{}) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    };
    defer req.deinit();

    // 发送请求
    req.sendBodiless() catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    };

    // 接收响应
    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    };

    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    }

    // 读取响应体
    var body_buf: [65536]u8 = undefined;
    var body_reader = response.reader(&body_buf);
    const body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024)) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    };
    defer allocator.free(body);

    // 解析 JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama", .owned = false },
        };
        return @constCast(&models);
    };
    defer parsed.deinit();

    // 提取模型列表
    var models: std.ArrayList(ModelInfo) = .empty;
    errdefer {
        for (models.items) |m| {
            if (m.owned) {
                allocator.free(m.id);
                allocator.free(m.name);
            }
        }
        models.deinit(allocator);
    }

    // Ollama 返回格式: { "models": [{ "name": "codellama:latest", ... }] }
    if (parsed.value.object.get("models")) |models_val| {
        if (models_val == .array) {
            for (models_val.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("name")) |name_val| {
                        if (name_val == .string) {
                            const name = name_val.string;
                            try models.append(allocator, .{
                                .id = try allocator.dupe(u8, name),
                                .name = try allocator.dupe(u8, name),
                                .owned = true,
                            });
                        }
                    }
                }
            }
        }
    }

    if (models.items.len == 0) {
        models.deinit(allocator);
        const default_models = comptime [_]ModelInfo{
            .{ .id = "codellama", .name = "Code Llama (not installed)", .owned = false },
            .{ .id = "llama3", .name = "Llama 3 (not installed)", .owned = false },
            .{ .id = "mistral", .name = "Mistral (not installed)", .owned = false },
        };
        return @constCast(&default_models);
    }

    return models.toOwnedSlice(allocator);
}

/// 释放模型列表内存
pub fn freeModels(allocator: std.mem.Allocator, models: []ModelInfo) void {
    for (models) |m| {
        if (m.owned) {
            allocator.free(m.id);
            allocator.free(m.name);
        }
    }
    // 只有动态分配的才需要释放
    if (models.len > 0 and models[0].owned) {
        allocator.free(models);
    }
}
