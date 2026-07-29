const std = @import("std");

const Interpreter = @import("./interpreter.zig");
const InterpreterError = Interpreter.InterpreterError;
const Value = Interpreter.Value;
const Typechecker = @import("./typechecker.zig");
const TypeError = Typechecker.TypeError;
const Type = Typechecker.Type;

pub const math = struct {
    pub const mod = struct {
        pub fn interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
            const a = value.tuple[0].integer;
            const b = value.tuple[1].integer;
            return try self.makeValue(.{ .integer = @mod(a, b) });
        }
    };

    pub const Generic = struct {
        pub fn oneFloatToFloat(comptime function: anytype) *const fn (*Interpreter, *Value) InterpreterError!*Value {
            return struct {
                fn _interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
                    return try self.makeValue(.{ .float = function(value.float) });
                }
            }._interp;
        }

        pub fn twoFloatsToFloat(comptime function: anytype) *const fn (*Interpreter, *Value) InterpreterError!*Value {
            return struct {
                fn _interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
                    const a = value.tuple[0].float;
                    const b = value.tuple[1].float;
                    return try self.makeValue(.{ .float = function(a, b) });
                }
            }._interp;
        }

        pub fn twoIntsToInt(comptime function: anytype) *const fn (*Interpreter, *Value) InterpreterError!*Value {
            return struct {
                fn _interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
                    const a = value.tuple[0].integer;
                    const b = value.tuple[1].integer;
                    return try self.makeValue(.{ .integer = function(a, b) });
                }
            }._interp;
        }
    };

    pub const customTwoArg = struct {};

    pub const logX = struct {
        pub fn interp(comptime base: i32) (*const fn (*Interpreter, *Value) InterpreterError!*Value) {
            return struct {
                fn _interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
                    return try self.makeValue(.{ .float = std.math.log(f64, base, value.float) });
                }
            }._interp;
        }

        pub fn inferType(self: *Typechecker, tp: *Type) TypeError!*Type {
            try self.unifyTypes(tp, self.primitive_types.float);

            return self.primitive_types.float;
        }
    };

    pub const log = struct {
        pub fn interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
            const base = value.tuple[0].float;
            const val = value.tuple[1].float;

            return try self.makeValue(.{ .float = std.math.log(f64, base, val) });
        }

        pub fn inferType(self: *Typechecker, tp: *Type) TypeError!*Type {
            try self.unifyTypes(tp, try self.freshType(.{ .tuple = try self.allocator.dupe(*Type, &[_]*Type{
                self.primitive_types.float,
                self.primitive_types.float,
            }) }));

            return self.primitive_types.float;
        }
    };

    pub const gcd = struct {
        pub fn interp(self: *Interpreter, value: *Value) InterpreterError!*Value {
            const a = value.tuple[0].integer;
            const b = value.tuple[1].integer;

            if (a < 0 or b < 0) return InterpreterError.NegativeNumbersInGCD;

            return try self.makeValue(.{ .integer = @as(i64, @intCast(std.math.gcd(@as(u64, @intCast(a)), @as(u64, @intCast(b))))) });
        }
    };
};

pub const Types = struct {
    pub fn floatToFloat(self: *Typechecker, tp: *Type) TypeError!*Type {
        try self.unifyTypes(tp, self.primitive_types.float);

        return self.primitive_types.float;
    }

    pub fn floatAndFloatToFloat(self: *Typechecker, tp: *Type) TypeError!*Type {
        try self.unifyTypes(tp, try self.freshType(.{ .tuple = try self.allocator.dupe(*Type, &[_]*Type{
            self.primitive_types.float,
            self.primitive_types.float,
        }) }));
        return self.primitive_types.float;
    }

    pub fn intAndIntToInt(self: *Typechecker, tp: *Type) TypeError!*Type {
        try self.unifyTypes(tp, try self.freshType(.{ .tuple = try self.allocator.dupe(*Type, &[_]*Type{
            self.primitive_types.int,
            self.primitive_types.int,
        }) }));
        return self.primitive_types.int;
    }
};
