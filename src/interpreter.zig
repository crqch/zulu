const std = @import("std");
const Interpreter = @This();
const Expression = @import("./ast.zig").Expression;
const Bop = @import("./ast.zig").Bop;

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Interpreter {
    return Interpreter{
        .allocator = allocator,
    };
}

const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,
    bindings: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) !*Env {
        const env = try allocator.create(Env);

        env.* = Env{
            .allocator = allocator,
            .parent = parent,
            .bindings = std.StringHashMap(Value).init(allocator),
        };

        return env;
    }

    fn add(self: *Env, identifier: []const u8, value: Value) !void {
        try self.bindings.put(identifier, value);
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
    Integer,
    Float,
    Boolean,
    String,
};

const Value = union(ValueType) {
    Integer: i64,
    Float: f64,
    Boolean: bool,
    String: []const u8,
};

pub fn printValue(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .Boolean => if (value.Boolean) "true" else "false",
        .Float => try std.fmt.allocPrint(allocator, "{d}", .{value.Float}),
        .Integer => try std.fmt.allocPrint(allocator, "{d}", .{value.Integer}),
        .String => try std.fmt.allocPrint(allocator, "{s}", .{value.String}),
    };
}

pub fn eval(self: *Interpreter, expression: *Expression) !Value {
    const env = try Env.init(self.allocator, null);

    return try self._eval(expression, env);
}

fn _eval(self: *Interpreter, expression: *Expression, environment: *Env) InterpreterError!Value {
    switch (expression.*) {
        .Number => |num| {
            const periodIndex = std.mem.find(u8, num.value, ".");

            if (periodIndex) |index| {
                if (index == 0) {
                    expression.Number.value = std.fmt.allocPrint(self.allocator, "0{s}", .{num.value}) catch {
                        return InterpreterError.MEMORY_ALLOCATION_FAILED;
                    };
                }

                const float = std.fmt.parseFloat(f64, expression.Number.value) catch {
                    return InterpreterError.FLOAT_PARSING_FAILED;
                };
                return Value{ .Float = float };
            }

            // TODO: Add other number bases
            const int = std.fmt.parseInt(i32, num.value, 10) catch {
                return InterpreterError.INT_PARSING_FAILED;
            };
            return Value{ .Integer = int };
        },
        .String => |str| {
            return Value{
                .String = str.value,
            };
        },
        .Boolean => |boolean| {
            return Value{
                .Boolean = boolean.value,
            };
        },
        .BinaryOperation => |bop| {
            var left = try self._eval(bop.left, environment);
            var right = try self._eval(bop.right, environment);

            return switch (bop.operation) {
                Bop.ADD, Bop.SUBTRACT, Bop.DIVIDE, Bop.MULTIPLY => {
                    try assertType(&[_]Value{ left, right }, &[_]ValueType{ .Integer, .Float });
                    try castType(&left, &right);

                    return switch (left) {
                        .Integer => Value{ .Integer = try numericOperation(i64, left.Integer, right.Integer, bop.operation) },
                        .Float => Value{ .Float = try numericOperation(f64, left.Float, right.Float, bop.operation) },
                        else => unreachable,
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
            };
        },
        else => return error.UNIMPLEMENTED,
    }
}

const InterpreterError = error{
    UNEXPECTED_TYPE,
    FLOAT_PARSING_FAILED,
    INT_PARSING_FAILED,
    MEMORY_ALLOCATION_FAILED,
    DIVISION_BY_ZERO,

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
    switch (val1.*) {
        .Integer => |val_1| switch (val2.*) {
            .Integer => return,
            .Float => {
                val1.* = Value{
                    .Float = @as(f64, @floatFromInt(val_1)),
                };
            },
            else => unreachable,
        },
        .Float => switch (val2.*) {
            .Integer => |val_2| {
                val2.* = Value{ .Float = @as(f64, @floatFromInt(val_2)) };
            },
            .Float => return,
            else => unreachable,
        },
        else => unreachable,
    }
}

fn numericOperation(comptime T: type, left: T, right: T, operation: Bop) InterpreterError!T {
    return switch (operation) {
        .ADD => left + right,
        .SUBTRACT => left - right,
        .DIVIDE => {
            if (right == 0) return InterpreterError.DIVISION_BY_ZERO;
            if (T == i64) {
                return @divFloor(left, right);
            }
            return left / right;
        },
        .MULTIPLY => left * right,
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
