const std = @import("std");

const Type = @import("./typechecker.zig").Type;
const TypePrinter = @import("./typechecker.zig").PrettyPrinter;

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
    Cons: struct {
        head: *MatchPattern,
        rest: *MatchPattern,
    },
    Identifier: []const u8,
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
    Boolean: bool,
    Import: []const u8,
    Number: []const u8,
    String: []const u8,
    Tuple: []*Expression,
    Unit,
    Variable: []const u8,

    BinaryOperation: struct {
        operation: Bop,
        left: *Expression,
        right: *Expression,
    },
    Not: *Expression,
    UnaryMinus: *Expression,

    Condition: struct {
        expression: *Expression,
        satisfyBlock: *Expression,
        elseBlock: *Expression,
    },
    Match: struct {
        scrutinee: *Expression,
        explicitScrutineeType: ?*TypeAst,
        cases: []MatchCase,
    },

    Application: struct {
        callee: *Expression,
        value: *Expression,
    },
    Lambda: struct {
        identifier: []const u8,
        block: *Expression,
        inferredType: ?*Type,
        explicitArgumentType: ?*TypeAst,
    },

    CurrentEnvironment,
    UseEnvironment: struct {
        environment: *Expression,
        block: *Expression,
    },
    Declaration: struct {
        identifier: []const u8,
        explicitType: ?*TypeAst,
        expression: *Expression,
        block: *Expression,
    },
    TypeDeclaration: struct {
        identifier: []const u8,
        typeAst: *TypeAst,
        block: *Expression,
    },
    MemberAccess: struct {
        object: *Expression,
        member: []const u8,
    },
    Module: struct {
        identifier: []const u8,
        block: *Expression,
        rest: *Expression,
    },

    TypeAscription: struct {
        expression: *Expression,
        explicitType: *TypeAst,
    },
};

pub const TypeAst = union(enum) {
    Wildcard,
    Identifier: []const u8,
    Tuple: []*TypeAst,
    Function: struct {
        argument: *TypeAst,
        returnType: *TypeAst,
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

    fn printType(self: *AstPrinter, typeAst: TypeAst, level: u8) ![]const u8 {
        return switch (typeAst) {
            .Wildcard => "_",
            .Identifier => |ident| ident,
            .Tuple => |tup| {
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                if (level > 15) try buffer.print(self.allocator, "(", .{});

                try buffer.print(self.allocator, "{s}", .{try self.printType(tup[0].*, 16)});
                if (tup.len > 1)
                    for (tup[1..]) |t| {
                        try buffer.print(self.allocator, " * {s}", .{try self.printType(t.*, 16)});
                    };

                if (level > 15) try buffer.print(self.allocator, ")", .{});

                return buffer.items;
            },
            .Function => |fun| {
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                if (level > 10) {
                    try buffer.print(self.allocator, "({s} => {s})", .{ try self.printType(fun.argument.*, 0), try self.printType(fun.returnType.*, level) });
                } else {
                    try buffer.print(self.allocator, "{s} => {s}", .{ try self.printType(fun.argument.*, 0), try self.printType(fun.returnType.*, level) });
                }

                return buffer.items;
            },
        };
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
                if (lam.explicitArgumentType) |argumentType| {
                    try self.buffer.print(self.allocator, "Lambda ( {s} : {s} )\n", .{ lam.identifier, try self.printType(argumentType.*, 0) });
                } else {
                    try self.buffer.print(self.allocator, "Lambda ( {s} )\n", .{lam.identifier});
                }

                try self.printNode(lam.block.*, level + 1);
            },
            .Declaration => |dec| {
                if (dec.explicitType) |explicitType| {
                    try self.buffer.print(self.allocator, "Declaration ( {s} : {s} )\n", .{ dec.identifier, try self.printType(explicitType.*, 0) });
                } else {
                    try self.buffer.print(self.allocator, "Declaration ( {s} )\n", .{dec.identifier});
                }

                try self.printNode(dec.expression.*, level + 1);

                try self.printNode(dec.block.*, level + 1);
            },
            .TypeDeclaration => |dec| {
                try self.buffer.print(self.allocator, "TypeDeclaration ( {s} : {s} )\n", .{ dec.identifier, try self.printType(dec.typeAst.*, 0) });

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
            .Import => |name| {
                try self.buffer.print(self.allocator, "Import( {s} )\n", .{name});
            },
            .Unit => {
                try self.buffer.print(self.allocator, "Unit\n", .{});
            },
            .CurrentEnvironment => {
                try self.buffer.print(self.allocator, "CurrentEnvironment\n", .{});
            },
            .UseEnvironment => |env| {
                try self.buffer.print(self.allocator, "UseEnvironment\n", .{});
                try self.printNode(env.environment.*, level + 1);
                try self.printNode(env.block.*, level + 1);
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

                if (match.explicitScrutineeType) |scrutineeType| {
                    try self.buffer.appendNTimes(self.allocator, ' ', level);
                    try self.buffer.print(self.allocator, "of type {s}", .{try self.printType(scrutineeType.*, 0)});
                }

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
            .TypeAscription => |typeAscription| {
                try self.buffer.print(self.allocator, "TypeAscription ( {s} )\n", .{try self.printType(typeAscription.explicitType.*, 0)});
                try self.printNode(typeAscription.expression.*, level + 1);
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
