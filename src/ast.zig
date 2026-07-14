const std = @import("std");
const Type = @import("./typechecker.zig").Type;

pub const Bop = enum {
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,

    EQ,
    NOTEQ,
    LT,
    GT,
    LTEQ,
    GTEQ,
    EQEQ,
    NOTEQEQ,

    OR,
    AND,
};

pub const Expression = union(enum) {
    BinaryOperation: struct {
        operation: Bop,
        left: *Expression,
        right: *Expression,
    },
    Not: *Expression,
    Variable: []const u8,
    Number: []const u8,
    Boolean: bool,
    String: []const u8,
    Declaration: struct {
        identifier: []const u8,
        expression: *Expression,
        block: *Expression,
    },
    Lambda: struct {
        identifier: []const u8,
        block: *Expression,
        type: ?*Type,
    },
    Application: struct {
        callee: *Expression,
        value: *Expression,
    },
    Condition: struct {
        expression: *Expression,
        satisfyBlock: *Expression,
        elseBlock: *Expression,
    },
};

pub const AstPrinter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn prettyPrint(allocator: std.mem.Allocator, expr: Expression) ![]u8 {
        var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);

        errdefer buffer.deinit(allocator);

        var astPrinter = AstPrinter{
            .allocator = allocator,
            .buffer = buffer,
        };

        try astPrinter.printNode(expr, 0);

        return astPrinter.buffer.items;
    }

    fn printNode(self: *AstPrinter, expr: Expression, level: usize) !void {
        try self.buffer.appendNTimes(self.allocator, ' ', level);
        try self.buffer.print(self.allocator, "", .{});

        switch (expr) {
            .Application => |app| {
                try self.buffer.print(self.allocator, "Application\n", .{});
                try self.printNode(app.callee.*, level + 1);
                try self.printNode(app.value.*, level + 1);
            },
            .Lambda => |lam| {
                try self.buffer.print(self.allocator, "Lambda ( {s} )\n", .{lam.identifier});

                try self.printNode(lam.block.*, level + 1);
            },
            .Declaration => |dec| {
                try self.buffer.print(self.allocator, "Declaration ( {s} )\n", .{dec.identifier});

                try self.printNode(dec.expression.*, level + 1);

                try self.printNode(dec.block.*, level + 1);
            },
            .String => |str| {
                try self.buffer.print(self.allocator, "String\n", .{});
                try self.buffer.appendNTimes(self.allocator, ' ', level + 1);
                try self.buffer.print(self.allocator, "{s}\n", .{str});
            },
            .Number => |num| {
                try self.buffer.print(self.allocator, "Number( {s} )\n", .{num});
            },
            .Boolean => |b| {
                try self.buffer.print(self.allocator, "Boolean( {s} )\n", .{if (b) "True" else "False"});
            },
            .Variable => |v| {
                try self.buffer.print(self.allocator, "Variable( {s} )\n", .{v});
            },
            .BinaryOperation => |bop| {
                try self.buffer.print(self.allocator, "BinaryOperation( {s} )\n", .{@tagName(bop.operation)});

                try self.printNode(bop.left.*, level + 1);

                try self.printNode(bop.right.*, level + 1);
            },
            .Condition => |condition| {
                try self.buffer.print(self.allocator, "Condition\n", .{});

                try self.printNode(condition.expression.*, level + 1);
                try self.printNode(condition.satisfyBlock.*, level + 1);
                try self.printNode(condition.elseBlock.*, level + 1);
            },
            .Not => |not| {
                try self.buffer.print(self.allocator, "Not\n", .{});

                try self.printNode(not.*, level + 1);
            },
        }
    }
};
