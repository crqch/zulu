const std = @import("std");
const Interpreter = @This();
const Expression = @import("./ast.zig").Expression;
const MatchPattern = @import("./ast.zig").MatchPattern;
const Bop = @import("./ast.zig").Bop;
const TypeChecker = @import("./typechecker.zig");

allocator: std.mem.Allocator,
last_expression: ?*Expression = null,

pub fn init(allocator: std.mem.Allocator) Interpreter {
    return Interpreter{
        .allocator = allocator,
        .last_expression = null,
    };
}

const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,
    bindings: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) !*Env {
        const env = allocator.create(Env) catch {
            return InterpreterError.ENVIRONMENT_INITALIZATION_ERROR;
        };

        env.* = Env{
            .allocator = allocator,
            .parent = parent,
            .bindings = std.StringHashMap(Value).init(allocator),
        };

        return env;
    }

    fn add(self: *Env, identifier: []const u8, value: Value) !void {
        self.bindings.put(identifier, value) catch {
            return InterpreterError.ENVIRONMENT_MAP_ERROR;
        };
    }

    fn get(self: *Env, identifier: []const u8) ?Value {
        if (self.bindings.get(identifier)) |val| {
            return val;
        }

        if (self.parent) |parent_env| {
            return parent_env.get(identifier);
        }

        return null;
    }
};

const ValueType = enum {
    Unit,
    Boolean,
    Float,
    Integer,
    String,

    Closure,

    Tuple,
    Environment,
};

pub const Value = union(ValueType) {
    Unit,

    Boolean: bool,
    Float: f64,
    Integer: i64,
    String: []const u8,

    Closure: struct {
        node: *Expression,
        env: *Env,
    },

    Tuple: []Value,
    Environment: *Env,
};

pub fn printValue(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .Unit => "unit",
        .Boolean => if (value.Boolean) "true" else "false",
        .Float => try std.fmt.allocPrint(allocator, "{d}", .{value.Float}),
        .Integer => try std.fmt.allocPrint(allocator, "{d}", .{value.Integer}),
        .String => try std.fmt.allocPrint(allocator, "\"{s}\"", .{value.String}),
        .Tuple => |values| {
            var str = try std.ArrayList(u8).initCapacity(allocator, 0);

            try str.print(allocator, "(", .{});
            try str.print(allocator, "{s}", .{try printValue(allocator, values[0])});
            for (values[1..]) |_val| {
                try str.print(allocator, ", {s}", .{try printValue(allocator, _val)});
            }

            try str.print(allocator, ")", .{});

            return str.items;
        },
        .Closure => try std.fmt.allocPrint(allocator, "[{s}]", .{try TypeChecker.PrettyPrinter.prettyPrint(allocator, value.Closure.node.Lambda.type.?.*)}),
        .Environment => |env| {
            var str = std.ArrayList(u8).initCapacity(allocator, 0) catch return InterpreterError.MEMORY_ALLOCATION_FAILED;

            try str.print(allocator, "env {{\n", .{});
            var entries = try std.ArrayList(std.StringHashMap(Value).Entry).initCapacity(allocator, 0);

            var current_env: ?*Env = env;
            while (current_env) |curr| {
                var iterator = curr.bindings.iterator();

                while (iterator.next()) |entry| {
                    entries.insert(allocator, 0, entry) catch return InterpreterError.MEMORY_ALLOCATION_FAILED;
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

pub fn eval(self: *Interpreter, expression: *Expression) !Value {
    const env = try Env.init(self.allocator, null);

    return try self._eval(expression, env);
}

fn _eval(self: *Interpreter, expression: *Expression, environment: *Env) InterpreterError!Value {
    self.last_expression = expression;
    switch (expression.*) {
        .Unit => {
            return Value{ .Unit = {} };
        },
        .Number => |num| {
            const periodIndex = std.mem.find(u8, num, ".");

            if (periodIndex) |index| {
                if (index == 0) {
                    expression.Number = std.fmt.allocPrint(self.allocator, "0{s}", .{num}) catch {
                        return InterpreterError.MEMORY_ALLOCATION_FAILED;
                    };
                }

                const float = std.fmt.parseFloat(f64, expression.Number) catch {
                    return InterpreterError.FLOAT_PARSING_FAILED;
                };
                return Value{ .Float = float };
            }

            // TODO: Add other number bases
            const int = std.fmt.parseInt(i32, num, 10) catch {
                return InterpreterError.INT_PARSING_FAILED;
            };
            return Value{ .Integer = int };
        },
        .String => |str| {
            return Value{
                .String = str,
            };
        },
        .Boolean => |boolean| {
            return Value{
                .Boolean = boolean,
            };
        },
        .Variable => |variable| {
            if (environment.get(variable)) |value| {
                return value;
            }
            return InterpreterError.UNBOUND_VARIABLE;
        },
        .Tuple => |expressions| {
            var values = std.ArrayList(Value).initCapacity(self.allocator, expressions.len) catch return InterpreterError.MEMORY_ALLOCATION_FAILED;

            for (expressions) |ex| {
                values.append(self.allocator, try self._eval(ex, environment)) catch return InterpreterError.MEMORY_ALLOCATION_FAILED;
            }

            return Value{
                .Tuple = values.items,
            };
        },
        .Lambda => {
            return Value{
                .Closure = .{
                    .node = expression,
                    .env = environment,
                },
            };
        },
        .Not => |not| {
            const notValue = try self._eval(not, environment);

            if (notValue != .Boolean) return InterpreterError.UNEXPECTED_TYPE;

            return Value{
                .Boolean = !notValue.Boolean,
            };
        },
        .UnaryMinus => |unaryMinus| {
            const notValue = try self._eval(unaryMinus, environment);

            if (notValue != .Float and notValue != .Integer) return InterpreterError.UNEXPECTED_TYPE;

            if (notValue == .Float) {
                return Value{
                    .Float = notValue.Float * -1,
                };
            } else {
                return Value{
                    .Integer = notValue.Integer * -1,
                };
            }
        },
        .Declaration => |declaration| {
            var blockEnvironment = try Env.init(self.allocator, environment);

            const evaluatedExpression = try self._eval(declaration.expression, if (declaration.identifier[0] == '@') blockEnvironment else environment);

            try blockEnvironment.add(declaration.identifier, evaluatedExpression);

            return try self._eval(declaration.block, blockEnvironment);
        },
        .Application => |application| {
            const evaluatedCallee = try self._eval(application.callee, environment);
            const evaluatedValue = try self._eval(application.value, environment);

            if (evaluatedCallee != .Closure) return InterpreterError.UNEXPECTED_TYPE;

            const closure = evaluatedCallee.Closure;
            const closureEnvironment = try Env.init(self.allocator, closure.env);

            try closureEnvironment.add(closure.node.Lambda.identifier, evaluatedValue);

            return try self._eval(closure.node.Lambda.block, closureEnvironment);
        },
        .Condition => |condition| {
            const conditionExpression = try self._eval(condition.expression, environment);

            if (conditionExpression != .Boolean) return InterpreterError.UNEXPECTED_TYPE;

            if (conditionExpression.Boolean) {
                return try self._eval(condition.satisfyBlock, environment);
            } else {
                return try self._eval(condition.elseBlock, environment);
            }
        },
        .BinaryOperation => |bop| {
            var left = try self._eval(bop.left, environment);
            var right = try self._eval(bop.right, environment);

            return switch (bop.operation) {
                Bop.ADD, Bop.SUBTRACT, Bop.DIVIDE, Bop.MULTIPLY => {
                    if (bop.operation == .ADD) {
                        try assertType(&[_]Value{ left, right }, &[_]ValueType{ .Integer, .Float, .String });
                    } else {
                        try assertType(&[_]Value{ left, right }, &[_]ValueType{ .Integer, .Float });
                    }
                    try castType(&left, &right);

                    return switch (left) {
                        .Integer => Value{ .Integer = try numericOperation(i64, left.Integer, right.Integer, bop.operation) },
                        .Float => Value{ .Float = try numericOperation(f64, left.Float, right.Float, bop.operation) },
                        .String => Value{ .String = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ left.String, right.String }) catch return InterpreterError.MEMORY_ALLOCATION_FAILED },
                        else => unreachable,
                    };
                },
                Bop.NOTEQ => {
                    expression.*.BinaryOperation.operation = Bop.EQ;

                    const negatedValue = try self._eval(expression, environment);

                    return Value{
                        .Boolean = !negatedValue.Boolean,
                    };
                },
                Bop.NOTEQEQ => {
                    expression.*.BinaryOperation.operation = Bop.EQEQ;

                    const negatedValue = try self._eval(expression, environment);

                    return Value{
                        .Boolean = !negatedValue.Boolean,
                    };
                },
                Bop.EQ => {
                    switch (left) {
                        ValueType.Boolean => {
                            try assertType(&[_]Value{right}, &[_]ValueType{.Boolean});
                            return Value{
                                .Boolean = left.Boolean == right.Boolean,
                            };
                        },
                        ValueType.Float => {
                            try assertType(&[_]Value{right}, &[_]ValueType{ .Float, .Integer });
                            try castType(&left, &right);
                            return Value{
                                .Boolean = left.Float == right.Float,
                            };
                        },
                        ValueType.Integer => {
                            try assertType(&[_]Value{right}, &[_]ValueType{ .Float, .Integer });
                            try castType(&left, &right);
                            if (left == .Integer) return Value{
                                .Boolean = left.Integer == right.Integer,
                            } else return Value{
                                .Boolean = left.Float == right.Float,
                            };
                        },
                        ValueType.String => {
                            try assertType(&[_]Value{right}, &[_]ValueType{.String});
                            const eql = std.mem.eql(u8, left.String, right.String);

                            return Value{ .Boolean = eql };
                        },
                        else => return InterpreterError.UNEXPECTED_TYPE,
                    }
                },
                Bop.EQEQ => {
                    switch (left) {
                        ValueType.Boolean => {
                            try assertType(&[_]Value{right}, &[_]ValueType{.Boolean});
                            return Value{
                                .Boolean = left.Boolean == right.Boolean,
                            };
                        },
                        ValueType.Float => {
                            try assertType(&[_]Value{right}, &[_]ValueType{ .Integer, .Float });
                            if (right != .Float) return Value{
                                .Boolean = false,
                            };
                            return Value{
                                .Boolean = left.Float == right.Float,
                            };
                        },
                        ValueType.Integer => {
                            try assertType(&[_]Value{right}, &[_]ValueType{ .Integer, .Float });
                            if (right != .Integer) return Value{
                                .Boolean = false,
                            };
                            return Value{
                                .Boolean = left.Integer == right.Integer,
                            };
                        },
                        ValueType.String => {
                            try assertType(&[_]Value{right}, &[_]ValueType{.String});
                            const eql = std.mem.eql(u8, left.String, right.String);

                            return Value{ .Boolean = eql };
                        },
                        else => return InterpreterError.UNEXPECTED_TYPE,
                    }
                },
                Bop.GT, Bop.GTEQ, Bop.LT, Bop.LTEQ => {
                    try assertType(&[_]Value{ left, right }, &[_]ValueType{ .Integer, .Float });
                    try castType(&left, &right);

                    return switch (left) {
                        .Integer => Value{ .Boolean = try numericComparison(i64, left.Integer, right.Integer, bop.operation) },
                        .Float => Value{ .Boolean = try numericComparison(f64, left.Float, right.Float, bop.operation) },
                        else => unreachable,
                    };
                },
                Bop.AND, Bop.OR => {
                    try assertType(&[_]Value{ left, right }, &[_]ValueType{.Boolean});

                    return switch (bop.operation) {
                        Bop.AND => Value{ .Boolean = left.Boolean and right.Boolean },
                        Bop.OR => Value{ .Boolean = left.Boolean or right.Boolean },
                        else => unreachable,
                    };
                },
            };
        },
        .Match => |match| {
            const value = try self._eval(match.scrutinee, environment);

            for (match.cases) |case| {
                if (try self.matchesPattern(case.pattern.*, value)) {
                    const freshEnv = try Env.init(self.allocator, environment);
                    try self.expandEnvByPattern(freshEnv, case.pattern.*, value);
                    return try self._eval(case.block, freshEnv);
                }
            }

            return InterpreterError.MISSING_MATCH_CASE;
        },
        .CurrentEnvironment => {
            return Value{
                .Environment = environment,
            };
        },
        .MemberAccess => |memberAccess| {
            const objectValue = try self._eval(memberAccess.object, environment);
            if (objectValue != .Environment) return InterpreterError.MEMBER_ACCESS_ON_NON_ENVIRONMENT;

            std.log.info("{s}\n", .{memberAccess.member});
            const memberValue = objectValue.Environment.get(memberAccess.member);

            if (memberValue) |val| return val;
            return InterpreterError.PROPERTY_NOT_FOUND_ON_OBJECT;
        },
        .Module => |mod| {
            const moduleEnvironment = try Env.init(self.allocator, null);

            const value = try self._eval(mod.block, moduleEnvironment);

            if (value != .Environment) return InterpreterError.EXPECTED_CURRENT_ENVIRONMENT_ON_MODULE_END;

            try environment.add(mod.identifier, Value{
                .Environment = value.Environment,
            });

            return self._eval(mod.rest, environment);
        },
    }
}

fn expandEnvByPattern(self: *Interpreter, environment: *Env, pattern: MatchPattern, value: Value) InterpreterError!void {
    return switch (pattern) {
        .Cons => |cons| {
            _ = cons;
            return InterpreterError.UNIMPLEMENTED;
        },
        .Tuple => |idents| {
            if (value != .Tuple or value.Tuple.len != idents.binds.len) return InterpreterError.UNMATCHED_PATTERN;
            for (idents.binds, value.Tuple) |pat, val| {
                try self.expandEnvByPattern(environment, pat.*, val);
            }
        },
        .Identifier => |ident| {
            try environment.add(ident, value);
        },
        .Wildcard => {},
    };
}

fn matchesPattern(self: *Interpreter, pattern: MatchPattern, value: Value) InterpreterError!bool {
    return switch (pattern) {
        .Cons => |cons| {
            _ = cons;
            return InterpreterError.UNIMPLEMENTED;
        },
        .Tuple => |idents| {
            if (value != .Tuple or value.Tuple.len != idents.binds.len) return false;
            for (idents.binds, value.Tuple) |pat, val| {
                if (!try self.matchesPattern(pat.*, val)) return false;
            }
            return true;
        },
        .Identifier, .Wildcard => true,
    };
}

const InterpreterError = error{
    UNEXPECTED_TYPE,
    TYPE_PROMOTION_NOT_IMPLEMENTED,

    FLOAT_PARSING_FAILED,
    INT_PARSING_FAILED,

    MEMORY_ALLOCATION_FAILED,

    DIVISION_BY_ZERO,

    UNBOUND_VARIABLE,
    ENVIRONMENT_MAP_ERROR,
    ENVIRONMENT_INITALIZATION_ERROR,

    UNMATCHED_PATTERN,
    MISSING_MATCH_CASE,

    PROPERTY_NOT_FOUND_ON_OBJECT,
    MEMBER_ACCESS_ON_NON_ENVIRONMENT,
    EXPECTED_CURRENT_ENVIRONMENT_ON_MODULE_END,

    UNIMPLEMENTED,
};

fn assertType(values: []const Value, valueTypes: []const ValueType) InterpreterError!void {
    for (values) |value| {
        var is_valid = false;

        const current_type = std.meta.activeTag(value);

        for (valueTypes) |allowed_type| {
            if (current_type == allowed_type) {
                is_valid = true;
                break;
            }
        }

        if (!is_valid) {
            return InterpreterError.UNEXPECTED_TYPE;
        }
    }
}

fn castType(val1: *Value, val2: *Value) InterpreterError!void {
    return switch (val1.*) {
        .Integer => switch (val2.*) {
            .Integer => return,
            .Float => return InterpreterError.TYPE_PROMOTION_NOT_IMPLEMENTED,
            // .Float => {
            //     val1.* = Value{
            //         .Float = @as(f64, @floatFromInt(val_1)),
            //     };
            // },
            else => unreachable,
        },
        .Float => switch (val2.*) {
            .Integer => return InterpreterError.TYPE_PROMOTION_NOT_IMPLEMENTED,
            // .Integer => |val_2| {
            //     val2.* = Value{ .Float = @as(f64, @floatFromInt(val_2)) };
            // },
            .Float => return,
            else => unreachable,
        },
        .String => {},
        else => unreachable,
    };
}

fn numericOperation(comptime T: type, left: T, right: T, operation: Bop) InterpreterError!T {
    return switch (operation) {
        .ADD => {
            if (T == i64) {
                return left +| right;
            }
            return left + right;
        },
        .SUBTRACT => {
            if (T == i64) {
                return left -| right;
            }
            return left - right;
        },
        .DIVIDE => {
            if (right == 0) return InterpreterError.DIVISION_BY_ZERO;
            if (T == i64) {
                return @divFloor(left, right);
            }
            return left / right;
        },
        .MULTIPLY => {
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
        .GT => left > right,
        .GTEQ => left >= right,
        .LT => left < right,
        .LTEQ => left <= right,
        else => unreachable,
    };
}
