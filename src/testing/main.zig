const std = @import("std");
const parser_tests = @import("./parser.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    std.debug.print("Running tests\n", .{});

    var parser_tester = try parser_tests.Testing.init(allocator, io);
    try parser_tester.runTests();
}
