const std = @import("std");
const Interpreter = @This();
const Expression = @import("./ast.zig").Expression;
const MatchPattern = @import("./ast.zig").MatchPattern;
const Bop = @import("./ast.zig").Bop;
const TypeChecker = @import("./typechecker.zig");
const SharedContext = @import("./shared.zig");
const readFileContents = @import("./root.zig").readFileContents;

allocator: std.mem.Allocator,
shared_context: *SharedContext,
last_expression: ?*Expression = null,

pub fn init(allocator: std.mem.Allocator, shared_context: *SharedContext) Interpreter {
    return Interpreter{
        .allocator = allocator,
        .shared_context = shared_context,
        .last_expression = null,
    };
}

const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,
    bindings: std.StringHashMap(*Value),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) !*Env {
        const env = allocator.create(Env) catch {
            return InterpreterError.EnvironmentInitializationError;
        };

        env.* = Env{
            .allocator = allocator,
            .parent = parent,
            .bindings = std.StringHashMap(*Value).init(allocator),
        };

        return env;
    }

    fn add(self: *Env, identifier: []const u8, value: *Value) !void {
        self.bindings.put(identifier, value) catch {
            return InterpreterError.EnvironmentMapError;
        };
    }

    fn get(self: *Env, identifier: []const u8) ?*Value {
        if (self.bindings.get(identifier)) |val| {
            return val;
        }

        if (self.parent) |parent_env| {
            return parent_env.get(identifier);
        }

        return null;
    }

    fn expand(self: *Env, env: *Env) !void {
        if (self.parent) |parent_env| {
            return try parent_env.expand(env);
        }

        self.parent = env;
    }
};

const ValueType = enum {
    unit,
    boolean,
    float,
    integer,
    string,

    variant,

    closure,

    tuple,
    environment,
};

pub const Value = union(ValueType) {
    unit,

    boolean: bool,
    float: f64,
    integer: i64,
    string: []const u8,

    variant: struct {
        name: []const u8,
        payload: ?*Value,
    },

    closure: struct {
        node: *Expression,
        env: *Env,
    },

    tuple: []*Value,
    environment: *Env,
};

pub fn printValue(allocator: std.mem.Allocator, value: *Value) ![]const u8 {
    return switch (value.*) {
        .unit => "unit",
        .boolean => if (value.boolean) "true" else "false",
        .float => try std.fmt.allocPrint(allocator, "{d}", .{value.float}),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{value.integer}),
        .string => try std.fmt.allocPrint(allocator, "\"{s}\"", .{value.string}),
        .tuple => |values| {
            var str = try std.ArrayList(u8).initCapacity(allocator, 0);

            try str.print(allocator, "(", .{});
            try str.print(allocator, "{s}", .{try printValue(allocator, values[0])});
            for (values[1..]) |_val| {
                try str.print(allocator, ", {s}", .{try printValue(allocator, _val)});
            }

            try str.print(allocator, ")", .{});

            return str.items;
        },
        .closure => try std.fmt.allocPrint(allocator, "[{s}]", .{try TypeChecker.PrettyPrinter.prettyPrint(allocator, value.closure.node.lambda.inferred_type.?)}),
        .variant => {
            if (value.variant.payload) |payload| {
                return try std.fmt.allocPrint(allocator, "{s} ({s})", .{ value.variant.name, try printValue(allocator, payload) });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}", .{value.variant.name});
            }
        },
        .environment => |env| {
            var str = std.ArrayList(u8).initCapacity(allocator, 0) catch return InterpreterError.MemoryAllocationFailed;

            try str.print(allocator, "env {{\n", .{});
            var entries = try std.ArrayList(std.StringHashMap(*Value).Entry).initCapacity(allocator, 0);

            var current_env: ?*Env = env;
            while (current_env) |curr| {
                var iterator = curr.bindings.iterator();

                while (iterator.next()) |entry| {
                    entries.insert(allocator, 0, entry) catch return InterpreterError.MemoryAllocationFailed;
                }
                current_env = curr.parent;
            }

            for (entries.items) |entry| {
                try str.print(allocator, "\t{s}: {s}\n", .{ entry.key_ptr.*, try printValue(allocator, entry.value_ptr.*) });
            }

            try str.print(allocator, "}}\n", .{});

            return str.items;
        },
    };
}

pub fn eval(self: *Interpreter, expression: *Expression) !*Value {
    const env = try Env.init(self.allocator, null);

    return try self._eval(expression, env);
}

fn _eval(self: *Interpreter, expression: *Expression, environment: *Env) InterpreterError!*Value {
    self.last_expression = expression;
    switch (expression.*) {
        .unit => {
            return try self.makeValue(.{ .unit = {} });
        },
        .number => |num| {
            const period_index = std.mem.find(u8, num, ".");

            if (period_index) |index| {
                if (index == 0) {
                    expression.number = std.fmt.allocPrint(self.allocator, "0{s}", .{num}) catch {
                        return InterpreterError.MemoryAllocationFailed;
                    };
                }

                const float = std.fmt.parseFloat(f64, expression.number) catch {
                    return InterpreterError.FloatParsingFailed;
                };
                return try self.makeValue(.{ .float = float });
            }

            // TODO: Add other number bases
            const int = std.fmt.parseInt(i32, num, 10) catch {
                return InterpreterError.IntParsingFailed;
            };
            return try self.makeValue(.{ .integer = int });
        },
        .import => |file_path| {
            const ret = self.shared_context.get(file_path) catch {
                unreachable;
            };

            if (ret.value) |value| {
                return value;
            }
            unreachable;
        },
        .string => |str| {
            return try self.makeValue(.{ .string = str });
        },
        .boolean => |boolean| {
            return try self.makeValue(.{ .boolean = boolean });
        },
        .variable => |variable| {
            if (environment.get(variable)) |value| {
                return value;
            }
            unreachable;
        },
        .constructor => |constructor| {
            var evaluated_payload: ?*Value = null;

            if (constructor.payload) |payload| {
                evaluated_payload = try self._eval(payload, environment);
            }

            return try self.makeValue(.{
                .variant = .{
                    .name = try self.reallocateIdentifier(constructor.name),
                    .payload = evaluated_payload,
                },
            });
        },
        .tuple => |expressions| {
            var values = std.ArrayList(*Value).initCapacity(self.allocator, expressions.len) catch return InterpreterError.MemoryAllocationFailed;

            for (expressions) |ex| {
                values.append(self.allocator, try self._eval(ex, environment)) catch return InterpreterError.MemoryAllocationFailed;
            }

            return try self.makeValue(.{
                .tuple = values.items,
            });
        },
        .lambda => {
            return try self.makeValue(.{
                .closure = .{
                    .node = expression,
                    .env = environment,
                },
            });
        },
        .not => |not| {
            const notValue = try self._eval(not, environment);

            return try self.makeValue(.{
                .boolean = !notValue.boolean,
            });
        },
        .unary_minus => |unary_minus| {
            const not_value = try self._eval(unary_minus, environment);

            if (not_value.* == .float) {
                return try self.makeValue(.{
                    .float = not_value.float * -1,
                });
            } else {
                return try self.makeValue(.{
                    .integer = not_value.integer * -1,
                });
            }
        },
        .declaration => |declaration| {
            var block_environment = try Env.init(self.allocator, environment);

            const identifier = try self.reallocateIdentifier(declaration.identifier);
            const evaluated_expression = try self._eval(declaration.expression, if (declaration.identifier[0] == '@') block_environment else environment);

            try block_environment.add(identifier, evaluated_expression);

            return try self._eval(declaration.block, block_environment);
        },
        .type_declaration => |declaration| {
            return try self._eval(declaration.block, environment);
        },
        .application => |application| {
            const evaluated_callee = try self._eval(application.callee, environment);
            const evaluated_value = try self._eval(application.value, environment);

            const closure = evaluated_callee.closure;
            const closure_environment = try Env.init(self.allocator, closure.env);

            try closure_environment.add(closure.node.lambda.identifier, evaluated_value);

            return try self._eval(closure.node.lambda.block, closure_environment);
        },
        .condition => |condition| {
            const condition_expression = try self._eval(condition.expression, environment);

            if (condition_expression.boolean) {
                return try self._eval(condition.satisfy_block, environment);
            } else {
                return try self._eval(condition.else_block, environment);
            }
        },
        .binary_operation => |bop| {
            const left = try self._eval(bop.left, environment);
            const right = try self._eval(bop.right, environment);

            return switch (bop.operation) {
                Bop.add, Bop.subtract, Bop.divide, Bop.multiply => {
                    return try self.makeValue(switch (left.*) {
                        .integer => .{ .integer = try numericOperation(i64, left.integer, right.integer, bop.operation) },
                        .float => .{ .float = try numericOperation(f64, left.float, right.float, bop.operation) },
                        .string => .{ .string = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left.string, right.string }) catch return InterpreterError.MemoryAllocationFailed },
                        else => unreachable,
                    });
                },
                Bop.not_eq => {
                    expression.*.binary_operation.operation = Bop.eq;

                    const negated_value = try self._eval(expression, environment);

                    return try self.makeValue(.{
                        .boolean = !negated_value.boolean,
                    });
                },
                Bop.not_eq_eq => {
                    expression.*.binary_operation.operation = Bop.eq_eq;

                    const negated_value = try self._eval(expression, environment);

                    return try self.makeValue(.{
                        .boolean = !negated_value.boolean,
                    });
                },
                Bop.eq, // This is a WIP for checking equality over the same type
                Bop.eq_eq,
                => {
                    switch (left.*) {
                        ValueType.boolean => {
                            return try self.makeValue(.{
                                .boolean = left.boolean == right.boolean,
                            });
                        },
                        ValueType.float => {
                            if (right.* != .float) return try self.makeValue(.{
                                .boolean = false,
                            });
                            return try self.makeValue(.{
                                .boolean = left.float == right.float,
                            });
                        },
                        ValueType.integer => {
                            if (right.* != .integer) return try self.makeValue(.{
                                .boolean = false,
                            });
                            return try self.makeValue(.{
                                .boolean = left.integer == right.integer,
                            });
                        },
                        ValueType.string => {
                            const eql = std.mem.eql(u8, left.string, right.string);

                            return try self.makeValue(.{ .boolean = eql });
                        },
                        else => unreachable,
                    }
                },
                Bop.gt, Bop.gt_eq, Bop.lt, Bop.lt_eq => {
                    return try self.makeValue(switch (left.*) {
                        .integer => .{ .boolean = try numericComparison(i64, left.integer, right.integer, bop.operation) },
                        .float => .{ .boolean = try numericComparison(f64, left.float, right.float, bop.operation) },
                        else => unreachable,
                    });
                },
                Bop.and_op, Bop.or_op => {
                    return try self.makeValue(switch (bop.operation) {
                        Bop.and_op => .{ .boolean = left.boolean and right.boolean },
                        Bop.or_op => .{ .boolean = left.boolean or right.boolean },
                        else => unreachable,
                    });
                },
            };
        },
        .match => |match| {
            const value = try self._eval(match.scrutinee, environment);

            for (match.cases) |case| {
                if (try self.matchesPattern(case.pattern.*, value)) {
                    const fresh_env = try Env.init(self.allocator, environment);
                    try self.expandEnvByPattern(fresh_env, case.pattern.*, value);
                    return try self._eval(case.block, fresh_env);
                }
            }

            unreachable;
        },
        .current_environment => {
            return try self.makeValue(.{
                .environment = environment,
            });
        },
        .use_environment => |env| {
            const evaluated_env = try self._eval(env.environment, environment);

            var temp_env = try Env.init(self.allocator, environment);
            var it = evaluated_env.environment.bindings.iterator();
            while (it.next()) |entry| {
                try temp_env.add(entry.key_ptr.*, entry.value_ptr.*);
            }

            return try self._eval(env.block, temp_env);
        },
        .member_access => |member_access| {
            const object_value = try self._eval(member_access.object, environment);

            const member_value = object_value.environment.get(member_access.member);

            if (member_value) |val| return val;
            unreachable;
        },
        .module => |mod| {
            const module_environment = try Env.init(self.allocator, environment);

            const value = try self._eval(mod.block, module_environment);

            try environment.add(mod.identifier, try self.makeValue(.{
                .environment = value.environment,
            }));

            return self._eval(mod.rest, environment);
        },
        .type_ascription => |type_ascription| {
            return self._eval(type_ascription.expression, environment);
        },
    }
}

fn reallocateIdentifier(self: *Interpreter, str: []const u8) InterpreterError![]const u8 {
    return self.shared_context.allocator.dupe(u8, str) catch return InterpreterError.MemoryAllocationFailed;
}

fn makeValue(self: *Interpreter, value: Value) InterpreterError!*Value {
    const fresh_value = self.allocator.create(Value) catch return InterpreterError.MemoryAllocationFailed;

    fresh_value.* = value;

    return fresh_value;
}

fn expandEnvByPattern(self: *Interpreter, environment: *Env, pattern: MatchPattern, value: *Value) InterpreterError!void {
    return switch (pattern) {
        .cons => |cons| {
            _ = cons;
            return InterpreterError.Unimplemented;
        },
        .tuple => |idents| {
            if (value.* != .tuple or value.tuple.len != idents.binds.len) return InterpreterError.UnmatchedPattern;
            for (idents.binds, value.tuple) |pat, val| {
                try self.expandEnvByPattern(environment, pat.*, val);
            }
        },
        .identifier => |ident| {
            try environment.add(ident, value);
        },
        .constructor => |constructor| {
            if (constructor.payload) |payload| {
                return try self.expandEnvByPattern(environment, payload.*, value.variant.payload.?);
            }
        },
        .wildcard => {},
    };
}

fn matchesPattern(self: *Interpreter, pattern: MatchPattern, value: *Value) InterpreterError!bool {
    return switch (pattern) {
        .cons => |cons| {
            _ = cons;
            return InterpreterError.Unimplemented;
        },
        .tuple => |idents| {
            if (value.* != .tuple or value.tuple.len != idents.binds.len) return false;
            for (idents.binds, value.tuple) |pat, val| {
                if (!try self.matchesPattern(pat.*, val)) return false;
            }
            return true;
        },
        .constructor => |constructor| {
            if (value.* != .variant or !std.mem.eql(u8, value.variant.name, constructor.name)) return false;

            if (constructor.payload) |constructorPayload| {
                if (value.variant.payload) |variantPayload| {
                    return try self.matchesPattern(constructorPayload.*, variantPayload);
                }
                return false;
            }
            return value.variant.payload == null;
        },
        .identifier, .wildcard => true,
    };
}

pub const InterpreterError = error{
    FloatParsingFailed,
    IntParsingFailed,

    MemoryAllocationFailed,

    DivisionByZero,

    EnvironmentMapError,
    EnvironmentInitializationError,

    UnmatchedPattern,

    Unimplemented,
};

fn numericOperation(comptime T: type, left: T, right: T, operation: Bop) InterpreterError!T {
    return switch (operation) {
        .add => {
            if (T == i64) {
                return left +| right;
            }
            return left + right;
        },
        .subtract => {
            if (T == i64) {
                return left -| right;
            }
            return left - right;
        },
        .divide => {
            if (right == 0) return InterpreterError.DivisionByZero;
            if (T == i64) {
                return @divFloor(left, right);
            }
            return left / right;
        },
        .multiply => {
            if (T == i64) {
                return left *| right;
            }
            return left * right;
        },
        else => unreachable,
    };
}

fn numericComparison(comptime T: type, left: T, right: T, operation: Bop) InterpreterError!bool {
    return switch (operation) {
        .gt => left > right,
        .gt_eq => left >= right,
        .lt => left < right,
        .lt_eq => left <= right,
        else => unreachable,
    };
}
