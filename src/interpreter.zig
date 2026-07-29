const std = @import("std");
const Interpreter = @This();
const Expression = @import("./ast.zig").Expression;
const MatchPattern = @import("./ast.zig").MatchPattern;
const Bop = @import("./ast.zig").Bop;
const TypeChecker = @import("./typechecker.zig");
const SharedContext = @import("./shared.zig");
const BuiltIn = @import("./builtin.zig");
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

fn freshEnv(self: *Interpreter, parent_env: ?*Env) !*Env {
    const fresh_env = try Env.init(self.allocator, parent_env);

    if (parent_env == null) {
        { // math builtins
            try fresh_env.add("<@math.mod>", try self.makeValue(.{ .builtin = BuiltIn.math.mod.interp }));

            try fresh_env.add("<@math.sin>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.sin) }));
            try fresh_env.add("<@math.cos>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.cos) }));
            try fresh_env.add("<@math.tan>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.tan) }));

            try fresh_env.add("<@math.asin>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.asin) }));
            try fresh_env.add("<@math.acos>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.acos) }));
            try fresh_env.add("<@math.atan>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.atan) }));

            try fresh_env.add("<@math.sinh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.sinh) }));
            try fresh_env.add("<@math.cosh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.cosh) }));
            try fresh_env.add("<@math.tanh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.tanh) }));

            try fresh_env.add("<@math.asinh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.asinh) }));
            try fresh_env.add("<@math.acosh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.acosh) }));
            try fresh_env.add("<@math.atanh>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.atanh) }));

            try fresh_env.add("<@math.log2>", try self.makeValue(.{ .builtin = BuiltIn.math.logX.interp(2) }));
            try fresh_env.add("<@math.log10>", try self.makeValue(.{ .builtin = BuiltIn.math.logX.interp(10) }));

            try fresh_env.add("<@math.log>", try self.makeValue(.{ .builtin = BuiltIn.math.log.interp }));

            try fresh_env.add("<@math.sqrt>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.sqrt) }));
            try fresh_env.add("<@math.cbrt>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.cbrt) }));

            try fresh_env.add("<@math.round>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.round) }));
            try fresh_env.add("<@math.floor>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.floor) }));
            try fresh_env.add("<@math.ceil>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.ceil) }));
            try fresh_env.add("<@math.trunc>", try self.makeValue(.{ .builtin = BuiltIn.math.Generic.oneFloatToFloat(std.math.trunc) }));

            try fresh_env.add("<@math.gcd>", try self.makeValue(.{ .builtin = BuiltIn.math.gcd.interp }));
        }
    }

    return fresh_env;
}

const ValueType = enum {
    unit,
    boolean,
    float,
    integer,
    string,

    variant,

    closure,
    builtin,

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
    builtin: *const fn (*Interpreter, *Value) InterpreterError!*Value,
    tuple: []*Value,
    environment: *Env,
};

pub fn printValue(allocator: std.mem.Allocator, value: *Value) ![]const u8 {
    return switch (value.*) {
        .unit => "unit",
        .boolean => |boolean| if (boolean) "true" else "false",
        .float => |float| try std.fmt.allocPrint(allocator, "{d}", .{float}),
        .integer => |integer| try std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .string => |string| try std.fmt.allocPrint(allocator, "\"{s}\"", .{string}),
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
        .builtin => "builtin",
        .closure => |closure| try std.fmt.allocPrint(allocator, "[{s}]", .{try TypeChecker.PrettyPrinter.prettyPrint(allocator, closure.node.lambda.inferred_type.?)}),
        .variant => |variant| {
            if (variant.payload) |payload| {
                return try std.fmt.allocPrint(allocator, "{s} {s}", .{ variant.name, try printValue(allocator, payload) });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}", .{variant.name});
            }
        },
        .environment => |environment| {
            var str = std.ArrayList(u8).initCapacity(allocator, 0) catch return InterpreterError.MemoryAllocationFailed;

            try str.print(allocator, "env {{\n", .{});
            var entries = try std.ArrayList(std.StringHashMap(*Value).Entry).initCapacity(allocator, 0);

            var current_env: ?*Env = environment;
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
    const env = try self.freshEnv(null);

    return try self._eval(expression, env);
}

fn _eval(self: *Interpreter, expression: *Expression, environment: *Env) InterpreterError!*Value {
    self.last_expression = expression;
    switch (expression.*) {
        .unit => {
            return try self.makeValue(.{ .unit = {} });
        },
        .number => |number| {
            const period_index = std.mem.find(u8, number, ".");

            if (period_index) |index| {
                if (index == 0) {
                    expression.number = std.fmt.allocPrint(self.allocator, "0{s}", .{number}) catch {
                        return InterpreterError.MemoryAllocationFailed;
                    };
                }

                const float = std.fmt.parseFloat(f64, expression.number) catch {
                    return InterpreterError.FloatParsingFailed;
                };
                return try self.makeValue(.{ .float = float });
            }

            // TODO: Add other number bases
            const int = std.fmt.parseInt(i64, number, 10) catch {
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
        .string => |string| {
            return try self.makeValue(.{ .string = string });
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
        .tuple => |tuple| {
            var values = std.ArrayList(*Value).initCapacity(self.allocator, tuple.len) catch return InterpreterError.MemoryAllocationFailed;

            for (tuple) |it| {
                values.append(self.allocator, try self._eval(it, environment)) catch return InterpreterError.MemoryAllocationFailed;
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
            const not_value = try self._eval(not, environment);

            return try self.makeValue(.{
                .boolean = !not_value.boolean,
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
            const evaluated_expression = try self._eval(declaration.expression, if (declaration.expression.* == .lambda or declaration.identifier[0] == '@') block_environment else environment);

            try block_environment.add(identifier, evaluated_expression);

            return try self._eval(declaration.block, block_environment);
        },
        .type_declaration => |type_declaration| {
            return try self._eval(type_declaration.block, environment);
        },
        .application => |application| {
            const evaluated_callee = try self._eval(application.callee, environment);
            const evaluated_value = try self._eval(application.value, environment);

            switch (evaluated_callee.*) {
                .closure => |closure| {
                    const closure_environment = try Env.init(self.allocator, closure.env);
                    try closure_environment.add(closure.node.lambda.identifier, evaluated_value);
                    try closure_environment.add("@", evaluated_callee);
                    return try self._eval(closure.node.lambda.block, closure_environment);
                },
                .builtin => |builtin_fn| {
                    return try builtin_fn(self, evaluated_value);
                },
                else => unreachable,
            }
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
        .module => |module| {
            const module_environment = try Env.init(self.allocator, environment);

            const value = try self._eval(module.block, module_environment);

            try environment.add(module.identifier, try self.makeValue(.{
                .environment = value.environment,
            }));

            return self._eval(module.rest, environment);
        },
        .type_ascription => |type_ascription| {
            return self._eval(type_ascription.expression, environment);
        },
    }
}

fn reallocateIdentifier(self: *Interpreter, str: []const u8) InterpreterError![]const u8 {
    return self.shared_context.allocator.dupe(u8, str) catch return InterpreterError.MemoryAllocationFailed;
}

pub fn makeValue(self: *Interpreter, value: Value) InterpreterError!*Value {
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
        .tuple => |tuple| {
            if (value.* != .tuple or value.tuple.len != tuple.binds.len) return InterpreterError.UnmatchedPattern;
            for (tuple.binds, value.tuple) |pat, val| {
                try self.expandEnvByPattern(environment, pat.*, val);
            }
        },
        .identifier => |identifier| {
            try environment.add(identifier, value);
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
        .tuple => |tuple| {
            if (value.* != .tuple or value.tuple.len != tuple.binds.len) return false;
            for (tuple.binds, value.tuple) |pat, val| {
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

    NegativeNumbersInGCD,

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
