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

pub const MatchPattern = union(enum) {
    Identifier: []const u8,
    Cons: struct {
        head: *MatchPattern,
        rest: *MatchPattern,
    },
    Tuple: struct {
        binds: []*MatchPattern,
    },
    Wildcard,
};

pub const MatchCase = struct {
    pattern: *MatchPattern,
    block: *Expression,
};

pub const Expression = union(enum) {
    BinaryOperation: struct {
        operation: Bop,
        left: *Expression,
        right: *Expression,
    },
    Not: *Expression,
    UnaryMinus: *Expression,
    Variable: []const u8,
    Number: []const u8,
    Unit,
    Boolean: bool,
    String: []const u8,
    Tuple: []*Expression,
    Declaration: struct {
        identifier: []const u8,
        expression: *Expression,
        block: *Expression,
    },
    Module: struct {
        identifier: []const u8,
        block: *Expression,
        rest: *Expression,
    },
    Lambda: struct {
        identifier: []const u8,
        block: *Expression,
        type: ?*Type,
    },
    Match: struct {
        scrutinee: *Expression,
        cases: []MatchCase,
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
    MemberAccess: struct {
        object: *Expression,
        member: []const u8,
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
            .Module => |mod| {
                try self.buffer.print(self.allocator, "Module ( {s} )\n", .{mod.identifier});

                try self.printNode(mod.block.*, level + 1);
                try self.printNode(mod.rest.*, level + 1);
            },
            .String => |str| {
                try self.buffer.print(self.allocator, "String\n", .{});
                try self.buffer.appendNTimes(self.allocator, ' ', level + 1);
                try self.buffer.print(self.allocator, "{s}\n", .{str});
            },
            .Number => |num| {
                try self.buffer.print(self.allocator, "Number( {s} )\n", .{num});
            },
            .Unit => {
                try self.buffer.print(self.allocator, "Unit\n", .{});
            },
            .Boolean => |b| {
                try self.buffer.print(self.allocator, "Boolean( {s} )\n", .{if (b) "True" else "False"});
            },
            .Tuple => |expressions| {
                try self.buffer.print(self.allocator, "Tuple\n", .{});
                for (expressions) |expression| {
                    try self.printNode(expression.*, level + 1);
                }
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
            .Match => |match| {
                try self.buffer.print(self.allocator, "Match\n", .{});

                try self.printNode(match.scrutinee.*, level + 1);

                for (match.cases) |case| {
                    try self.buffer.appendNTimes(self.allocator, ' ', level + 1);
                    try self.buffer.print(self.allocator, "Case\n", .{});
                    try self.printPattern(case.pattern.*, level + 2);
                    try self.printNode(case.block.*, level + 2);
                }
            },
            .Not => |not| {
                try self.buffer.print(self.allocator, "Not\n", .{});

                try self.printNode(not.*, level + 1);
            },
            .UnaryMinus => |opposite| {
                try self.buffer.print(self.allocator, "UnaryMinus\n", .{});

                try self.printNode(opposite.*, level + 1);
            },
            .MemberAccess => |memberAccess| {
                try self.buffer.print(self.allocator, "MemberAccess ( {s} )\n", .{memberAccess.member});

                try self.printNode(memberAccess.object.*, level + 1);
            },
        }
    }

    fn printPattern(self: *AstPrinter, pattern: MatchPattern, level: usize) !void {
        try self.buffer.appendNTimes(self.allocator, ' ', level);
        try self.buffer.append(self.allocator, '|');
        switch (pattern) {
            .Cons => |cons| {
                try self.buffer.print(self.allocator, "Cons\n", .{});
                try self.printPattern(cons.head.*, level + 1);
                try self.printPattern(cons.rest.*, level + 1);
            },
            .Wildcard => {
                try self.buffer.print(self.allocator, "Wildcard\n", .{});
            },
            .Identifier => |ident| {
                try self.buffer.print(self.allocator, "Identifier ( {s} )\n", .{ident});
            },
            .Tuple => |patterns| {
                try self.buffer.print(self.allocator, "Tuple\n", .{});
                for (patterns.binds) |_pattern| {
                    try self.printPattern(_pattern.*, level + 1);
                }
            },
        }
    }
};
