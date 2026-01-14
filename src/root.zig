//! Zpencode - AI Code Assistant Library
//!
//! A Zig implementation of an AI-powered code assistant,
//! inspired by Claude Code and OpenCode.

const std = @import("std");

// Re-export core modules
pub const config = @import("core/config.zig");
pub const models = @import("core/models.zig");
pub const message = @import("models/message.zig");
pub const tui = @import("tui/app.zig");
pub const prompt = @import("tui/prompt.zig");

// Re-export commonly used types
pub const Config = config.Config;
pub const ProviderType = config.ProviderType;
pub const ProviderConfig = config.ProviderConfig;

pub const Message = message.Message;
pub const Role = message.Role;
pub const Conversation = message.Conversation;
pub const ToolCall = message.ToolCall;
pub const ToolResult = message.ToolResult;

pub const App = tui.App;
pub const AppState = tui.AppState;

/// Version information
pub const version = "0.1.0-dev";
pub const name = "zpencode";

/// Print version info
pub fn printVersion(writer: anytype) !void {
    try writer.print("{s} v{s}\n", .{ name, version });
}

test "version info" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try printVersion(fbs.writer());
    try std.testing.expectEqualStrings("zpencode v0.1.0-dev\n", fbs.getWritten());
}

test "config module" {
    _ = config;
}

test "message module" {
    _ = message;
}
