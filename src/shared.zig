const std = @import("std");

const Value = @import("./interpreter.zig").Value;
const readFileContents = @import("./root.zig").readFileContents;
const Options = @import("./root.zig").Options;
const Type = @import("./typechecker.zig").Type;
const Pipeline = @import("./pipeline.zig");

const SharedContext = @This();

const BindingsType = std.StringHashMap(ReturnType);

pub const ReturnType = struct {
    value: ?Value,
    type: ?*Type,
};

allocator: std.mem.Allocator,
bindings: std.StringHashMap(ReturnType),
io: std.Io,
options: Options,
pipeline: Pipeline,

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !SharedContext {
    return SharedContext{
        .allocator = allocator,
        .bindings = std.StringHashMap(ReturnType).init(allocator),
        .io = io,
        .options = options,
        .pipeline = Pipeline.init(allocator, options),
    };
}

pub fn deinit(self: *SharedContext) void {
    var it = self.bindings.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "_")) {
            self.allocator.free(@constCast(key));
        }
    }
    self.bindings.deinit();
    self.pipeline.deinit();
}

pub fn load(self: *SharedContext, filePath: []const u8) !void {
    const absolutePath = try std.Io.Dir.cwd().realPathFileAlloc(self.io, filePath, self.allocator);
    if (self.bindings.get(absolutePath)) |_| {
        self.allocator.free(absolutePath);
        return;
    }

    const source = try readFileContents(self.allocator, self.io, filePath);
    defer self.allocator.free(source);

    const ret = try self.pipeline.run(self, filePath, source, self.options) orelse return error.Unexpected;

    try self.bindings.put(absolutePath, ret);
}

pub fn loadSource(self: *SharedContext, source: []const u8) !void {
    const ret = try self.pipeline.run(self, "_", source, self.options) orelse return error.Unexpected;

    try self.bindings.put("_", ret);
}

pub fn get(self: *SharedContext, filePath: []const u8) !ReturnType {
    if (std.mem.eql(u8, filePath, "_")) {
        if (self.bindings.get("_")) |ret| return ret;

        return error.FileNotFound;
    }
    const absolutePath = try std.Io.Dir.cwd().realPathFileAlloc(self.io, filePath, self.allocator);

    if (self.bindings.get(absolutePath)) |ret| return ret;
    defer self.allocator.free(absolutePath);

    return error.FileNotFound;
}
