const std = @import("std");
const ai = @import("ai");
const message = @import("../models/message.zig");
const config = @import("../core/config.zig");

/// AI 客户端封装，统一管理多个提供商
pub const Client = struct {
    allocator: std.mem.Allocator,
    provider_config: config.ProviderConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, provider_cfg: config.ProviderConfig) Self {
        return .{
            .allocator = allocator,
            .provider_config = provider_cfg,
        };
    }

    /// 发送消息并获取响应
    pub fn sendMessage(self: *Self, messages: []const message.Message) ![]const u8 {
        // 将内部消息格式转换为 ai-zig 格式
        var ai_messages = try std.ArrayList(ai.Message).initCapacity(self.allocator, messages.len);
        defer ai_messages.deinit(self.allocator);

        for (messages) |msg| {
            const role: ai.Message.Role = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
                else => .user,
            };

            try ai_messages.append(self.allocator, .{
                .role = role,
                .content = msg.content,
            });
        }

        // 根据提供商类型创建请求
        const response = switch (self.provider_config.provider_type) {
            .anthropic => try self.callAnthropic(ai_messages.items),
            .openai => try self.callOpenAI(ai_messages.items),
            .ollama => try self.callOllama(ai_messages.items),
            .custom => return error.UnsupportedProvider,
        };

        return response;
    }

    fn callAnthropic(self: *Self, messages: []const ai.Message) ![]const u8 {
        const api_key = self.provider_config.api_key orelse
            config.Config.loadApiKeyFromEnv(.anthropic) orelse
            return error.MissingApiKey;

        const provider = ai.providers.Anthropic.init(.{
            .api_key = api_key,
        });

        const model = provider.model(self.provider_config.model);

        const result = try model.generateText(.{
            .messages = messages,
            .max_tokens = self.provider_config.max_tokens,
        });

        return result.text;
    }

    fn callOpenAI(self: *Self, messages: []const ai.Message) ![]const u8 {
        const api_key = self.provider_config.api_key orelse
            config.Config.loadApiKeyFromEnv(.openai) orelse
            return error.MissingApiKey;

        const provider = ai.providers.OpenAI.init(.{
            .api_key = api_key,
        });

        const model = provider.model(self.provider_config.model);

        const result = try model.generateText(.{
            .messages = messages,
            .max_tokens = self.provider_config.max_tokens,
        });

        return result.text;
    }

    fn callOllama(self: *Self, messages: []const ai.Message) ![]const u8 {
        const provider = ai.providers.Ollama.init(.{
            .base_url = self.provider_config.base_url,
        });

        const model = provider.model(self.provider_config.model);

        const result = try model.generateText(.{
            .messages = messages,
        });

        return result.text;
    }

    /// 流式发送消息（带回调）
    pub fn streamMessage(
        self: *Self,
        messages: []const message.Message,
        on_chunk: *const fn (chunk: []const u8) void,
    ) !void {
        var ai_messages = try std.ArrayList(ai.Message).initCapacity(self.allocator, messages.len);
        defer ai_messages.deinit(self.allocator);

        for (messages) |msg| {
            const role: ai.Message.Role = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
                else => .user,
            };

            try ai_messages.append(self.allocator, .{
                .role = role,
                .content = msg.content,
            });
        }

        switch (self.provider_config.provider_type) {
            .anthropic => try self.streamAnthropic(ai_messages.items, on_chunk),
            .openai => try self.streamOpenAI(ai_messages.items, on_chunk),
            .ollama => try self.streamOllama(ai_messages.items, on_chunk),
            .custom => return error.UnsupportedProvider,
        }
    }

    fn streamAnthropic(
        self: *Self,
        messages: []const ai.Message,
        on_chunk: *const fn (chunk: []const u8) void,
    ) !void {
        const api_key = self.provider_config.api_key orelse
            config.Config.loadApiKeyFromEnv(.anthropic) orelse
            return error.MissingApiKey;

        const provider = ai.providers.Anthropic.init(.{
            .api_key = api_key,
        });

        const model = provider.model(self.provider_config.model);

        try model.streamText(.{
            .messages = messages,
            .max_tokens = self.provider_config.max_tokens,
            .on_chunk = on_chunk,
        });
    }

    fn streamOpenAI(
        self: *Self,
        messages: []const ai.Message,
        on_chunk: *const fn (chunk: []const u8) void,
    ) !void {
        const api_key = self.provider_config.api_key orelse
            config.Config.loadApiKeyFromEnv(.openai) orelse
            return error.MissingApiKey;

        const provider = ai.providers.OpenAI.init(.{
            .api_key = api_key,
        });

        const model = provider.model(self.provider_config.model);

        try model.streamText(.{
            .messages = messages,
            .max_tokens = self.provider_config.max_tokens,
            .on_chunk = on_chunk,
        });
    }

    fn streamOllama(
        self: *Self,
        messages: []const ai.Message,
        on_chunk: *const fn (chunk: []const u8) void,
    ) !void {
        const provider = ai.providers.Ollama.init(.{
            .base_url = self.provider_config.base_url,
        });

        const model = provider.model(self.provider_config.model);

        try model.streamText(.{
            .messages = messages,
            .on_chunk = on_chunk,
        });
    }
};

/// 快速创建默认 Claude 客户端
pub fn createClaudeClient(allocator: std.mem.Allocator) Client {
    return Client.init(allocator, .{
        .provider_type = .anthropic,
        .base_url = "https://api.anthropic.com",
        .model = "claude-sonnet-4-20250514",
        .max_tokens = 8192,
    });
}

/// 快速创建默认 OpenAI 客户端
pub fn createOpenAIClient(allocator: std.mem.Allocator) Client {
    return Client.init(allocator, .{
        .provider_type = .openai,
        .base_url = "https://api.openai.com/v1",
        .model = "gpt-4o",
        .max_tokens = 8192,
    });
}

/// 快速创建默认 Ollama 客户端
pub fn createOllamaClient(allocator: std.mem.Allocator) Client {
    return Client.init(allocator, .{
        .provider_type = .ollama,
        .base_url = "http://localhost:11434",
        .model = "codellama",
        .max_tokens = 4096,
    });
}

test "create claude client" {
    const allocator = std.testing.allocator;
    const client = createClaudeClient(allocator);
    try std.testing.expectEqual(.anthropic, client.provider_config.provider_type);
}

test "create openai client" {
    const allocator = std.testing.allocator;
    const client = createOpenAIClient(allocator);
    try std.testing.expectEqual(.openai, client.provider_config.provider_type);
}
