const std = @import("std");
const Interpreter = @This();
const Expression = @import("./ast.zig").Expression;

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
    Integer: i32,
    Float: f64,
    Boolean: bool,
    String: []const u8,
};

pub fn printValue(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .Boolean => if (value.Boolean) "true" else "false",
        .Float => try std.fmt.allocPrint(allocator, "{d:.18}", .{value.Float}),
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
        .BinaryOperation => |bop| {
            const left = try self._eval(bop.left, environment);
            const right = try self._eval(bop.right, environment);

            return switch (bop.operation) {
                .ADD => {
                    try assertType(&[_]Value{ left, right }, &[_]ValueType{ .Integer, .Float });

                    switch (left) {
                        .Integer => |l_val| switch (right) {
                            .Integer => |r_val| return Value{ .Integer = l_val + r_val },
                            .Float => |r_val| return Value{ .Float = @as(f64, @floatFromInt(l_val)) + r_val },
                            else => return InterpreterError.UNEXPECTED_TYPE,
                        },
                        .Float => |l_val| switch (right) {
                            .Integer => |r_val| return Value{ .Float = l_val + @as(f64, @floatFromInt(r_val)) },
                            .Float => |r_val| return Value{ .Float = l_val + r_val },
                            else => return InterpreterError.UNEXPECTED_TYPE,
                        },
                        else => return InterpreterError.UNEXPECTED_TYPE,
                    }
                },
                else => return InterpreterError.UNIMPLEMENTED,
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
