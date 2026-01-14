const std = @import("std");

/// Message role in a conversation
pub const Role = enum {
    user,
    assistant,
    system,
    tool_call,
    tool_result,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "tool_result")) return .tool_result;
        return null;
    }
};

/// A single message in a conversation
pub const Message = struct {
    role: Role,
    content: []const u8,
    timestamp: i64,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,

    pub fn init(role: Role, content: []const u8) Message {
        return .{
            .role = role,
            .content = content,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn initWithToolCall(role: Role, content: []const u8, tool_call_id: []const u8, tool_name: []const u8) Message {
        return .{
            .role = role,
            .content = content,
            .timestamp = std.time.timestamp(),
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
        };
    }
};

/// Tool call request from the model
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.arguments.deinit();
    }
};

/// Result of executing a tool
pub const ToolResult = struct {
    call_id: []const u8,
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,
};

/// Conversation containing multiple messages
pub const Conversation = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    system_prompt: ?[]const u8,
    max_tokens: u32,

    pub fn init(allocator: std.mem.Allocator, system_prompt: ?[]const u8) Conversation {
        return .{
            .allocator = allocator,
            .messages = .empty,
            .system_prompt = system_prompt,
            .max_tokens = 8192,
        };
    }

    pub fn deinit(self: *Conversation) void {
        self.messages.deinit(self.allocator);
    }

    pub fn addMessage(self: *Conversation, msg: Message) !void {
        try self.messages.append(self.allocator, msg);
    }

    pub fn getMessages(self: *const Conversation) []const Message {
        return self.messages.items;
    }

    pub fn clear(self: *Conversation) void {
        self.messages.clearRetainingCapacity();
    }
};

test "message creation" {
    const msg = Message.init(.user, "Hello, world!");
    try std.testing.expectEqual(.user, msg.role);
    try std.testing.expectEqualStrings("Hello, world!", msg.content);
}

test "role conversion" {
    try std.testing.expectEqualStrings("user", Role.user.toString());
    try std.testing.expectEqual(.assistant, Role.fromString("assistant").?);
}
