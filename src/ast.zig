const std = @import("std");

pub const Bop = enum {
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,

    EQ,
    LT,
    GT,
    LTEQ,
    GTEQ,
    EQEQ,
};

pub const Expression = union(enum) {
    BinaryOperation: struct {
        operation: Bop,
        left: *Expression,
        right: *Expression,
    },
    Variable: struct {
        identifier: []const u8,
    },
    Number: struct {
        value: []const u8,
    },
    Boolean: struct {
        value: bool,
    },
    String: struct {
        value: []const u8,
    },
    Declaration: struct {
        identifier: []const u8,
        expression: *Expression,
        block: *Expression,
    },
    Lambda: struct {
        identifier: []const u8,
        block: *Expression,
    },
    Application: struct {
        callee: *Expression,
        value: *Expression,
    },
};
