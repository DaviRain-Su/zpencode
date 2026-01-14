const std = @import("std");

/// Provider types supported
pub const ProviderType = enum {
    anthropic,
    openai,
    deepseek,
    ollama,
    custom,

    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .openai => "openai",
            .deepseek => "deepseek",
            .ollama => "ollama",
            .custom => "custom",
        };
    }

    pub fn fromString(s: []const u8) ?ProviderType {
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return null;
    }
};

/// Configuration for a single provider
pub const ProviderConfig = struct {
    provider_type: ProviderType,
    api_key: ?[]const u8 = null,
    api_key_owned: bool = false, // 是否需要释放 api_key
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
        // 释放已分配的 API keys
        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.api_key_owned) {
                if (entry.value_ptr.api_key) |key| {
                    self.allocator.free(key);
                }
            }
        }
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

        // Add default DeepSeek provider
        try self.providers.put("deepseek", .{
            .provider_type = .deepseek,
            .base_url = "https://api.deepseek.com/v1",
            .model = "deepseek-chat",
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

    /// Set API key for a provider
    pub fn setApiKey(self: *Config, provider_name: []const u8, api_key: []const u8) !void {
        if (self.providers.getPtr(provider_name)) |cfg| {
            // 如果之前有 key，先释放
            if (cfg.api_key) |old_key| {
                // 只释放我们分配的 key，不释放环境变量的
                if (cfg.api_key_owned) {
                    self.allocator.free(old_key);
                }
            }
            cfg.api_key = try self.allocator.dupe(u8, api_key);
            cfg.api_key_owned = true;
        }
    }

    /// Set API key for default provider
    pub fn setDefaultApiKey(self: *Config, api_key: []const u8) !void {
        try self.setApiKey(self.default_provider.toString(), api_key);
    }

    /// Load API key from environment variable
    pub fn loadApiKeyFromEnv(provider_type: ProviderType) ?[]const u8 {
        const env_var = switch (provider_type) {
            .anthropic => "ANTHROPIC_API_KEY",
            .openai => "OPENAI_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
            .ollama => null,
            .custom => null,
        };

        if (env_var) |var_name| {
            return std.posix.getenv(var_name);
        }
        return null;
    }

    /// 递归释放 JSON Value
    fn freeJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
        switch (value.*) {
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    freeJsonValue(allocator, entry.value_ptr);
                }
                obj.deinit();
            },
            .array => |*arr| {
                for (arr.items) |*item| {
                    freeJsonValue(allocator, item);
                }
                arr.deinit();
            },
            else => {},
        }
    }

    /// Save configuration to file
    pub fn saveToFile(self: *const Config) !void {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        // Ensure config directory exists
        const dir_path = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Build JSON object
        const json_obj = std.json.ObjectMap.init(self.allocator);
        var json_value = std.json.Value{ .object = json_obj };
        defer freeJsonValue(self.allocator, &json_value);

        // Save default provider
        try json_value.object.put("default_provider", .{ .string = self.default_provider.toString() });

        // Save provider configs with API keys
        var providers_obj = std.json.ObjectMap.init(self.allocator);

        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            var provider_obj = std.json.ObjectMap.init(self.allocator);

            const cfg = entry.value_ptr.*;
            try provider_obj.put("model", .{ .string = cfg.model });
            try provider_obj.put("base_url", .{ .string = cfg.base_url });
            try provider_obj.put("max_tokens", .{ .integer = @intCast(cfg.max_tokens) });

            // Only save API key if it's owned (user-configured, not from env)
            if (cfg.api_key_owned) {
                if (cfg.api_key) |key| {
                    try provider_obj.put("api_key", .{ .string = key });
                }
            }

            try providers_obj.put(entry.key_ptr.*, .{ .object = provider_obj });
        }

        try json_value.object.put("providers", .{ .object = providers_obj });

        // Write to file
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();

        // Serialize JSON value
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, json_value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_str);

        _ = try file.write(json_str);
    }

    /// Load configuration from file
    pub fn loadFromFile(self: *Config) !bool {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch {
            return false;
        };
        defer parsed.deinit();

        const root = parsed.value;

        // Load default provider
        if (root.object.get("default_provider")) |dp| {
            if (dp == .string) {
                if (ProviderType.fromString(dp.string)) |pt| {
                    self.default_provider = pt;
                }
            }
        }

        // Load provider configs
        if (root.object.get("providers")) |providers| {
            if (providers == .object) {
                var piter = providers.object.iterator();
                while (piter.next()) |entry| {
                    const provider_name = entry.key_ptr.*;
                    const provider_config = entry.value_ptr.*;

                    if (provider_config == .object) {
                        // Get or create provider config
                        if (self.providers.getPtr(provider_name)) |cfg| {
                            // Update existing provider config
                            if (provider_config.object.get("api_key")) |key| {
                                if (key == .string) {
                                    // Free old key if owned
                                    if (cfg.api_key_owned) {
                                        if (cfg.api_key) |old_key| {
                                            self.allocator.free(old_key);
                                        }
                                    }
                                    cfg.api_key = try self.allocator.dupe(u8, key.string);
                                    cfg.api_key_owned = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        return true;
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
