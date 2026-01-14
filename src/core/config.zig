const std = @import("std");

/// Provider types supported
pub const ProviderType = enum {
    anthropic,
    openai,
    ollama,
    custom,

    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .openai => "openai",
            .ollama => "ollama",
            .custom => "custom",
        };
    }

    pub fn fromString(s: []const u8) ?ProviderType {
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return null;
    }
};

/// Configuration for a single provider
pub const ProviderConfig = struct {
    provider_type: ProviderType,
    api_key: ?[]const u8 = null,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32 = 8192,
    temperature: f32 = 0.7,
    timeout_ms: u32 = 60000,
};

/// Application configuration
pub const Config = struct {
    allocator: std.mem.Allocator,
    default_provider: ProviderType,
    providers: std.StringHashMap(ProviderConfig),

    // Sandbox settings
    sandbox_enabled: bool = true,
    allowed_paths: std.ArrayList([]const u8),
    denied_paths: std.ArrayList([]const u8),

    // TUI settings
    theme: []const u8 = "dark",
    syntax_highlighting: bool = true,
    vim_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .default_provider = .anthropic,
            .providers = std.StringHashMap(ProviderConfig).init(allocator),
            .allowed_paths = .empty,
            .denied_paths = .empty,
        };
    }

    pub fn deinit(self: *Config) void {
        self.providers.deinit();
        self.allowed_paths.deinit(self.allocator);
        self.denied_paths.deinit(self.allocator);
    }

    /// Load configuration with defaults
    pub fn loadDefaults(self: *Config) !void {
        // Add default Anthropic provider
        try self.providers.put("anthropic", .{
            .provider_type = .anthropic,
            .base_url = "https://api.anthropic.com",
            .model = "claude-sonnet-4-20250514",
            .max_tokens = 8192,
        });

        // Add default OpenAI provider
        try self.providers.put("openai", .{
            .provider_type = .openai,
            .base_url = "https://api.openai.com/v1",
            .model = "gpt-4o",
            .max_tokens = 8192,
        });

        // Add default Ollama provider (local)
        try self.providers.put("ollama", .{
            .provider_type = .ollama,
            .base_url = "http://localhost:11434",
            .model = "codellama",
            .max_tokens = 4096,
        });
    }

    /// Get provider config by name
    pub fn getProvider(self: *const Config, name: []const u8) ?ProviderConfig {
        return self.providers.get(name);
    }

    /// Get the default provider config
    pub fn getDefaultProvider(self: *const Config) ?ProviderConfig {
        return self.providers.get(self.default_provider.toString());
    }

    /// Load API key from environment variable
    pub fn loadApiKeyFromEnv(provider_type: ProviderType) ?[]const u8 {
        const env_var = switch (provider_type) {
            .anthropic => "ANTHROPIC_API_KEY",
            .openai => "OPENAI_API_KEY",
            .ollama => null,
            .custom => null,
        };

        if (env_var) |var_name| {
            return std.posix.getenv(var_name);
        }
        return null;
    }
};

/// Get the config file path
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/.config/zpencode/config.json", .{home});
}

/// Get the data directory path
pub fn getDataPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/.local/share/zpencode", .{home});
}

test "config initialization" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.loadDefaults();

    const anthropic = config.getProvider("anthropic");
    try std.testing.expect(anthropic != null);
    try std.testing.expectEqual(.anthropic, anthropic.?.provider_type);
}

test "provider type conversion" {
    try std.testing.expectEqualStrings("anthropic", ProviderType.anthropic.toString());
    try std.testing.expectEqual(.openai, ProviderType.fromString("openai").?);
}
