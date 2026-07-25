const std = @import("std");

const Type = @import("./typechecker.zig").Type;
const TypePrinter = @import("./typechecker.zig").PrettyPrinter;

pub const Bop = enum {
    add,
    subtract,
    multiply,
    divide,

    eq,
    not_eq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    eq_eq,
    not_eq_eq,

    or_op,
    and_op,
};

pub const MatchPattern = union(enum) {
    cons: struct {
        head: *MatchPattern,
        rest: *MatchPattern,
    },
    identifier: []const u8,
    tuple: struct {
        binds: []*MatchPattern,
    },

    constructor: struct {
        name: []const u8,
        payload: ?*MatchPattern,
    },

    wildcard,
};

pub const MatchCase = struct {
    pattern: *MatchPattern,
    block: *Expression,
};

pub const Expression = union(enum) {
    boolean: bool,
    import: []const u8,
    number: []const u8,
    string: []const u8,
    tuple: []*Expression,
    unit,
    variable: []const u8,
    constructor: struct {
        name: []const u8,
        payload: ?*Expression,
    },

    binary_operation: struct {
        operation: Bop,
        left: *Expression,
        right: *Expression,
    },
    not: *Expression,
    unary_minus: *Expression,

    condition: struct {
        expression: *Expression,
        satisfy_block: *Expression,
        else_block: *Expression,
    },
    match: struct {
        scrutinee: *Expression,
        explicit_scrutinee_type: ?*TypeAst,
        cases: []MatchCase,
    },

    application: struct {
        callee: *Expression,
        value: *Expression,
    },
    lambda: struct {
        identifier: []const u8,
        block: *Expression,
        inferred_type: ?*Type,
        explicit_argument_type: ?*TypeAst,
    },

    current_environment,
    use_environment: struct {
        environment: *Expression,
        block: *Expression,
    },
    declaration: struct {
        identifier: []const u8,
        explicit_type: ?*TypeAst,
        expression: *Expression,
        block: *Expression,
    },
    type_declaration: struct {
        identifier: []const u8,
        types_ast: []*TypeAst,
        block: *Expression,
    },
    member_access: struct {
        object: *Expression,
        member: []const u8,
    },
    module: struct {
        identifier: []const u8,
        block: *Expression,
        rest: *Expression,
    },

    type_ascription: struct {
        expression: *Expression,
        explicit_type: *TypeAst,
    },
};

pub const TypeAst = union(enum) {
    wildcard,
    identifier: []const u8,
    tuple: []*TypeAst,
    function: struct {
        argument: *TypeAst,
        returns: *TypeAst,
    },
    constructor: struct {
        name: []const u8,
        payload: ?*TypeAst,
    },
};

pub const AstPrinter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn prettyPrint(allocator: std.mem.Allocator, expression: Expression) ![]u8 {
        var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);

        errdefer buffer.deinit(allocator);

        var ast_printer = AstPrinter{
            .allocator = allocator,
            .buffer = buffer,
        };

        try ast_printer.printNode(expression, 0);

        return ast_printer.buffer.items;
    }

    fn printType(self: *AstPrinter, type_ast: TypeAst, level: u8) ![]const u8 {
        return switch (type_ast) {
            .wildcard => "_",
            .identifier => |ident| ident,
            .tuple => |tuple| {
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                if (level > 15) try buffer.print(self.allocator, "(", .{});

                try buffer.print(self.allocator, "{s}", .{try self.printType(tuple[0].*, 16)});
                if (tuple.len > 1)
                    for (tuple[1..]) |t| {
                        try buffer.print(self.allocator, " * {s}", .{try self.printType(t.*, 16)});
                    };

                if (level > 15) try buffer.print(self.allocator, ")", .{});

                return buffer.items;
            },
            .constructor => |constructor| {
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                if (level > 25) try buffer.print(self.allocator, "(", .{});

                try buffer.print(self.allocator, "{s}", .{constructor.name});
                if (constructor.payload) |payload| {
                    try buffer.print(self.allocator, " of {s}", .{try self.printType(payload.*, 26)});
                }

                if (level > 25) try buffer.print(self.allocator, ")", .{});

                return buffer.items;
            },
            .function => |fun| {
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                if (level > 10) {
                    try buffer.print(self.allocator, "({s} => {s})", .{ try self.printType(fun.argument.*, 0), try self.printType(fun.returns.*, level) });
                } else {
                    try buffer.print(self.allocator, "{s} => {s}", .{ try self.printType(fun.argument.*, 0), try self.printType(fun.returns.*, level) });
                }

                return buffer.items;
            },
        };
    }

    fn printNode(self: *AstPrinter, expr: Expression, level: usize) !void {
        try self.buffer.appendNTimes(self.allocator, ' ', level);
        try self.buffer.print(self.allocator, "", .{});

        switch (expr) {
            .application => |app| {
                try self.buffer.print(self.allocator, "Application\n", .{});
                try self.printNode(app.callee.*, level + 1);
                try self.printNode(app.value.*, level + 1);
            },
            .lambda => |lam| {
                if (lam.explicit_argument_type) |argumentType| {
                    try self.buffer.print(self.allocator, "Lambda ( {s} : {s} )\n", .{ lam.identifier, try self.printType(argumentType.*, 0) });
                } else {
                    try self.buffer.print(self.allocator, "Lambda ( {s} )\n", .{lam.identifier});
                }

                try self.printNode(lam.block.*, level + 1);
            },
            .declaration => |dec| {
                if (dec.explicit_type) |explicitType| {
                    try self.buffer.print(self.allocator, "Declaration ( {s} : {s} )\n", .{ dec.identifier, try self.printType(explicitType.*, 0) });
                } else {
                    try self.buffer.print(self.allocator, "Declaration ( {s} )\n", .{dec.identifier});
                }

                try self.printNode(dec.expression.*, level + 1);

                try self.printNode(dec.block.*, level + 1);
            },
            .type_declaration => |dec| {
                if (dec.types_ast.len == 1)
                    try self.buffer.print(self.allocator, "TypeDeclaration ( {s} : {s} )\n", .{ dec.identifier, try self.printType(dec.types_ast[0].*, 0) })
                else {
                    try self.buffer.print(self.allocator, "TypeDeclaration ( {s} :\n", .{dec.identifier});
                    for (dec.types_ast) |typeAst| {
                        try self.buffer.appendNTimes(self.allocator, ' ', level + 1);
                        try self.buffer.print(self.allocator, "{s}\n", .{try self.printType(typeAst.*, 0)});
                    }
                    try self.buffer.appendNTimes(self.allocator, ' ', level);
                    try self.buffer.print(self.allocator, ")\n", .{});
                }

                try self.printNode(dec.block.*, level + 1);
            },
            .module => |mod| {
                try self.buffer.print(self.allocator, "Module ( {s} )\n", .{mod.identifier});

                try self.printNode(mod.block.*, level + 1);
                try self.printNode(mod.rest.*, level + 1);
            },
            .string => |str| {
                try self.buffer.print(self.allocator, "String\n", .{});
                try self.buffer.appendNTimes(self.allocator, ' ', level + 1);
                try self.buffer.print(self.allocator, "{s}\n", .{str});
            },
            .number => |num| {
                try self.buffer.print(self.allocator, "Number( {s} )\n", .{num});
            },
            .import => |name| {
                try self.buffer.print(self.allocator, "Import( {s} )\n", .{name});
            },
            .unit => {
                try self.buffer.print(self.allocator, "Unit\n", .{});
            },
            .current_environment => {
                try self.buffer.print(self.allocator, "CurrentEnvironment\n", .{});
            },
            .use_environment => |env| {
                try self.buffer.print(self.allocator, "UseEnvironment\n", .{});
                try self.printNode(env.environment.*, level + 1);
                try self.printNode(env.block.*, level + 1);
            },
            .boolean => |b| {
                try self.buffer.print(self.allocator, "Boolean( {s} )\n", .{if (b) "True" else "False"});
            },
            .tuple => |expressions| {
                try self.buffer.print(self.allocator, "Tuple\n", .{});
                for (expressions) |expression| {
                    try self.printNode(expression.*, level + 1);
                }
            },
            .variable => |v| {
                try self.buffer.print(self.allocator, "Variable( {s} )\n", .{v});
            },
            .constructor => |constructor| {
                try self.buffer.print(self.allocator, "Constructor( {s} )\n", .{constructor.name});

                if (constructor.payload) |payload| {
                    try self.printNode(payload.*, level + 1);
                }
            },
            .binary_operation => |bop| {
                try self.buffer.print(self.allocator, "BinaryOperation( {s} )\n", .{@tagName(bop.operation)});

                try self.printNode(bop.left.*, level + 1);

                try self.printNode(bop.right.*, level + 1);
            },
            .condition => |condition| {
                try self.buffer.print(self.allocator, "Condition\n", .{});

                try self.printNode(condition.expression.*, level + 1);
                try self.printNode(condition.satisfy_block.*, level + 1);
                try self.printNode(condition.else_block.*, level + 1);
            },
            .match => |match| {
                try self.buffer.print(self.allocator, "Match\n", .{});

                try self.printNode(match.scrutinee.*, level + 1);

                if (match.explicit_scrutinee_type) |scrutineeType| {
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
            .not => |not| {
                try self.buffer.print(self.allocator, "Not\n", .{});

                try self.printNode(not.*, level + 1);
            },
            .unary_minus => |opposite| {
                try self.buffer.print(self.allocator, "UnaryMinus\n", .{});

                try self.printNode(opposite.*, level + 1);
            },
            .member_access => |memberAccess| {
                try self.buffer.print(self.allocator, "MemberAccess ( {s} )\n", .{memberAccess.member});

                try self.printNode(memberAccess.object.*, level + 1);
            },
            .type_ascription => |typeAscription| {
                try self.buffer.print(self.allocator, "TypeAscription ( {s} )\n", .{try self.printType(typeAscription.explicit_type.*, 0)});
                try self.printNode(typeAscription.expression.*, level + 1);
            },
        }
    }

    fn printPattern(self: *AstPrinter, pattern: MatchPattern, level: usize) !void {
        try self.buffer.appendNTimes(self.allocator, ' ', level);
        try self.buffer.append(self.allocator, '|');
        switch (pattern) {
            .cons => |cons| {
                try self.buffer.print(self.allocator, "Cons\n", .{});
                try self.printPattern(cons.head.*, level + 1);
                try self.printPattern(cons.rest.*, level + 1);
            },
            .wildcard => {
                try self.buffer.print(self.allocator, "Wildcard\n", .{});
            },
            .identifier => |ident| {
                try self.buffer.print(self.allocator, "Identifier ( {s} )\n", .{ident});
            },
            .tuple => |patterns| {
                try self.buffer.print(self.allocator, "Tuple\n", .{});
                for (patterns.binds) |_pattern| {
                    try self.printPattern(_pattern.*, level + 1);
                }
            },
            .constructor => |constructor| {
                try self.buffer.print(self.allocator, "Constructor ( {s} )\n", .{constructor.name});
                if (constructor.payload) |payload|
                    try self.printPattern(payload.*, level + 1);
            },
        }
    }
};
