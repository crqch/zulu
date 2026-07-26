const std = @import("std");

const Value = @import("./interpreter.zig").Value;
const readFileContents = @import("./root.zig").readFileContents;
const Options = @import("./root.zig").Options;
const Type = @import("./typechecker.zig").Type;
const Pipeline = @import("./pipeline.zig");

const SharedContext = @This();

const BindingsType = std.StringHashMap(ReturnType);

pub const ReturnType = struct {
    value: ?*Value,
    type: ?*Type,
};

allocator: std.mem.Allocator,
bindings: std.StringHashMap(ReturnType),
io: std.Io,
options: Options,
pipeline: Pipeline,
current_absolute_dir: []const u8,

fn resolvePath(self: *SharedContext, relative_path: []const u8) ![]const u8 {
    const resolved_path = try std.fs.path.resolve(self.allocator, &.{ self.current_absolute_dir, relative_path });
    return try std.Io.Dir.cwd().realPathFileAlloc(self.io, resolved_path, self.allocator);
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !SharedContext {
    return SharedContext{
        .allocator = allocator,
        .bindings = std.StringHashMap(ReturnType).init(allocator),
        .io = io,
        .options = options,
        .pipeline = Pipeline.init(allocator, options),
        .current_absolute_dir = ".",
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

pub fn load(self: *SharedContext, relative_file_path: []const u8) !void {
    const absolute_path = try self.resolvePath(relative_file_path);

    if (self.bindings.get(absolute_path)) |_| {
        self.allocator.free(absolute_path);
        return;
    }

    const source = try readFileContents(self.allocator, self.io, absolute_path);
    defer self.allocator.free(source);

    const new_scope_dir = std.fs.path.dirname(absolute_path) orelse ".";
    const previous_path = self.current_absolute_dir;
    self.current_absolute_dir = new_scope_dir;
    const ret = try self.pipeline.run(self, absolute_path, source, self.options) orelse return error.Unexpected;
    self.current_absolute_dir = previous_path;

    try self.bindings.put(absolute_path, ret);
}

pub fn loadSource(self: *SharedContext, source: []const u8) !void {
    const ret = try self.pipeline.run(self, "_", source, self.options) orelse return error.Unexpected;

    try self.bindings.put("_", ret);
}

pub fn get(self: *SharedContext, relative_file_path: []const u8) !ReturnType {
    if (std.mem.eql(u8, relative_file_path, "_")) {
        if (self.bindings.get("_")) |ret| return ret;

        return error.FileNotFound;
    }

    const absolute_path = try self.resolvePath(relative_file_path);

    if (self.bindings.get(absolute_path)) |ret| return ret;
    defer self.allocator.free(absolute_path);

    return error.FileNotFound;
}
