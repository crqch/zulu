const std = @import("std");

const TypeChecker = @This();
const Expression = @import("./ast.zig").Expression;

allocator: std.mem.Allocator,
errorContext: ?TypeErrorContext,

pub const Type = union(enum) {
    Int,
    Float,
    Boolean,
    String,
    Lambda: struct {
        argType: *Type,
        returnType: *Type,
    },
    Wildcard,
};

const TypeEnv = struct {
    allocator: std.mem.Allocator,
    parent: ?*TypeEnv,
    bindings: std.StringHashMap(*Type),

    pub fn init(allocator: std.mem.Allocator, parent: ?*TypeEnv) TypeError!*TypeEnv {
        const env = allocator.create(TypeEnv) catch {
            return TypeError.ENVIRONMENT_INITALIZATION_ERROR;
        };

        env.* = TypeEnv{
            .allocator = allocator,
            .parent = parent,
            .bindings = std.StringHashMap(*Type).init(allocator),
        };

        return env;
    }

    fn add(self: *TypeEnv, identifier: []const u8, tp: *Type) !void {
        self.bindings.put(identifier, tp) catch {
            return TypeError.ENVIRONMENT_MAP_ERROR;
        };
    }

    fn get(self: *TypeEnv, identifier: []const u8) ?*Type {
        if (self.bindings.get(identifier)) |val| {
            return val;
        }

        if (self.parent) |parent_env| {
            return parent_env.get(identifier);
        }

        return null;
    }
};

pub const TypeError = error{
    UNBOUND_VARIABLE,
    ENVIRONMENT_INITALIZATION_ERROR,
    ENVIRONMENT_MAP_ERROR,
    UNEXPECTED_TYPE,
    OUT_OF_MEMORY,
    CANNOT_UNIFY,
    TYPE_PROMOTION_NOT_IMPLEMENTED,
};

const TypeErrorContext = union(enum) {
    UNBOUND_VARIABLE: struct {
        variable: []const u8,
    },
    UNEXPECTED_TYPE: struct {
        expectedType: []const Type,
        foundType: Type,
        context: *Expression,
    },
};

pub fn init(allocator: std.mem.Allocator) TypeChecker {
    return TypeChecker{
        .allocator = allocator,
        .errorContext = null,
    };
}

pub fn inferType(self: *TypeChecker, expression: *Expression) TypeError!*Type {
    const typeEnv = try TypeEnv.init(self.allocator, null);

    return try self._inferType(expression, typeEnv);
}

pub fn prettyPrint(allocator: std.mem.Allocator, tp: Type, level: u8) ![]const u8 {
    return switch (tp) {
        .Boolean => "bool",
        .Float => "float",
        .Int => "int",
        .String => "string",
        // TODO: Add wildcard unifiable type names
        .Wildcard => "_",
        .Lambda => |lam| {
            var buf = try std.ArrayList(u8).initCapacity(allocator, 0);

            if (level >= 1) {
                try buf.print(allocator, "({s} -> {s})", .{ try prettyPrint(allocator, lam.argType.*, 1), try prettyPrint(allocator, lam.returnType.*, 0) });
            } else {
                try buf.print(allocator, "{s} -> {s}", .{ try prettyPrint(allocator, lam.argType.*, 1), try prettyPrint(allocator, lam.returnType.*, 0) });
            }
            return buf.items;
        },
    };
}

fn makeFreshType(self: *TypeChecker) !*Type {
    return self.allocator.create(Type) catch {
        return TypeError.OUT_OF_MEMORY;
    };
}

fn makeFreshTypeSpecific(self: *TypeChecker, tp: Type) !*Type {
    const freshType = self.allocator.create(Type) catch {
        return TypeError.OUT_OF_MEMORY;
    };
    freshType.* = tp;

    return freshType;
}

fn _inferType(self: *TypeChecker, expression: *Expression, environment: *TypeEnv) TypeError!*Type {
    switch (expression.*) {
        .Number => {
            const freshType = try self.makeFreshType();
            if (std.mem.containsAtLeast(u8, expression.Number, 1, ".")) {
                freshType.* = .Float;
            } else {
                freshType.* = .Int;
            }

            return freshType;
        },
        .Boolean => return {
            const freshType = try self.makeFreshType();
            freshType.* = .Boolean;
            return freshType;
        },
        .String => {
            const freshType = try self.makeFreshType();
            freshType.* = .String;
            return freshType;
        },
        .Not => |not| {
            const freshType = try self.makeFreshType();
            const tp = try self._inferType(not, environment);

            const booleanType = try self.makeFreshTypeSpecific(.Boolean);
            self.unifyTypes(tp, booleanType) catch {
                self.errorContext = .{
                    .UNEXPECTED_TYPE = .{
                        .expectedType = &[_]Type{
                            Type.Boolean,
                        },
                        .foundType = tp.*,
                        .context = expression,
                    },
                };
                return TypeError.UNEXPECTED_TYPE;
            };

            freshType.* = .Boolean;
            return freshType;
        },
        .Variable => |v| {
            const tp = environment.get(v);

            if (tp) |val| return val;
            self.errorContext = .{
                .UNBOUND_VARIABLE = .{
                    .variable = v,
                },
            };
            return TypeError.UNBOUND_VARIABLE;
        },
        .Application => |app| {
            const calleeType = try self._inferType(app.callee, environment);

            const _argType = try self.makeFreshTypeSpecific(.Wildcard);
            const _returnType = try self.makeFreshTypeSpecific(.Wildcard);

            const lambdaType = try self.makeFreshTypeSpecific(.{ .Lambda = .{
                .argType = _argType,
                .returnType = _returnType,
            } });

            self.unifyTypes(calleeType, lambdaType) catch {
                self.errorContext = TypeErrorContext{
                    .UNEXPECTED_TYPE = .{
                        .expectedType = self.allocator.dupe(Type, &[_]Type{
                            lambdaType.*,
                        }) catch {
                            return TypeError.OUT_OF_MEMORY;
                        },
                        .foundType = calleeType.*,
                        .context = app.callee,
                    },
                };

                return TypeError.UNEXPECTED_TYPE;
            };

            const valueType = try self._inferType(app.value, environment);

            self.unifyTypes(valueType, calleeType.Lambda.argType) catch {
                self.errorContext = TypeErrorContext{
                    .UNEXPECTED_TYPE = .{
                        .expectedType = self.allocator.dupe(Type, &[_]Type{calleeType.Lambda.argType.*}) catch {
                            return TypeError.OUT_OF_MEMORY;
                        },
                        .foundType = valueType.*,
                        .context = app.value,
                    },
                };

                return TypeError.UNEXPECTED_TYPE;
            };

            return calleeType.Lambda.returnType;
        },
        .BinaryOperation => |bop| {
            const leftType = try self._inferType(bop.left, environment);
            const rightType = try self._inferType(bop.right, environment);

            return switch (bop.operation) {
                .ADD, .SUBTRACT, .DIVIDE, .MULTIPLY, .GT, .GTEQ, .LT, .LTEQ => {
                    const intType = try self.makeFreshType();
                    intType.* = .Int;
                    if ((leftType.* != .Int and leftType.* != .Float)) {
                        if (rightType.* != .Wildcard) {
                            try self.unifyTypes(leftType, rightType);
                        } else {
                            try self.unifyTypes(leftType, intType);
                        }
                    }
                    if ((rightType.* != .Int and rightType.* != .Float)) {
                        if (leftType.* != .Wildcard) {
                            try self.unifyTypes(rightType, leftType);
                        } else {
                            try self.unifyTypes(rightType, intType);
                        }
                    }

                    if ((leftType.* == .Int and rightType.* == .Float) or
                        (leftType.* == .Float and rightType.* == .Int)) return TypeError.TYPE_PROMOTION_NOT_IMPLEMENTED;

                    // TODO: Type promotion

                    // if (leftType.* == .Float) {
                    //     rightType.* = .Float;
                    // }

                    // if (rightType.* == .Float) {
                    //     leftType.* = .Float;
                    // }

                    // Now leftType is the .Int type
                    // return leftType;

                    if (bop.operation == .GT or bop.operation == .GTEQ or bop.operation == .LT or bop.operation == .LTEQ) {
                        const freshType = try self.makeFreshTypeSpecific(.Boolean);
                        return freshType;
                    }
                    return leftType;
                },

                .EQEQ, .NOTEQEQ, .EQ, .NOTEQ => {
                    try self.unifyTypes(leftType, rightType);

                    if (leftType.* != .Boolean and leftType.* != .Float and leftType.* != .Int and leftType.* != .String) {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(Type, &[_]Type{
                                    Type{ .Boolean = {} },
                                    Type{ .Float = {} },
                                    Type{ .Int = {} },
                                    Type{ .String = {} },
                                }) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = leftType.*,
                                .context = expression,
                            },
                        };
                        return TypeError.UNEXPECTED_TYPE;
                    }

                    const freshType = try self.makeFreshType();
                    freshType.* = .Boolean;

                    return freshType;
                },

                .AND, .OR => {
                    const freshType = try self.makeFreshType();
                    freshType.* = .Boolean;
                    self.unifyTypes(leftType, freshType) catch {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(Type, &[_]Type{freshType.*}) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = leftType.*,
                                .context = expression,
                            },
                        };
                        return TypeError.UNEXPECTED_TYPE;
                    };
                    self.unifyTypes(rightType, freshType) catch {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(Type, &[_]Type{freshType.*}) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = rightType.*,
                                .context = expression,
                            },
                        };
                        return TypeError.UNEXPECTED_TYPE;
                    };

                    return leftType;
                },

                // TODO: Type promotion
                // .EQ, .NOTEQ => {
                // },
            };
        },
        .Condition => |cond| {
            const conditionType = try self._inferType(cond.expression, environment);
            var booleanType = Type{ .Boolean = {} };
            self.unifyTypes(conditionType, &booleanType) catch {
                self.errorContext = TypeErrorContext{ .UNEXPECTED_TYPE = .{
                    .expectedType = self.allocator.dupe(Type, &[_]Type{
                        Type{ .Boolean = {} },
                    }) catch {
                        return TypeError.OUT_OF_MEMORY;
                    },
                    .foundType = conditionType.*,
                    .context = expression,
                } };
                return TypeError.UNEXPECTED_TYPE;
            };
            const satisfyType = try self._inferType(cond.satisfyBlock, environment);
            const elseType = try self._inferType(cond.elseBlock, environment);

            self.unifyTypes(satisfyType, elseType) catch {
                self.errorContext = TypeErrorContext{ .UNEXPECTED_TYPE = .{
                    .expectedType = self.allocator.dupe(Type, &[_]Type{
                        satisfyType.*,
                    }) catch {
                        return TypeError.OUT_OF_MEMORY;
                    },
                    .foundType = elseType.*,
                    .context = cond.elseBlock,
                } };
                return TypeError.UNEXPECTED_TYPE;
            };

            return satisfyType;
        },
        .Declaration => |decl| {
            const blockEnvironment = try TypeEnv.init(self.allocator, environment);
            if (decl.identifier[0] == '@') {
                const freshWildcard = try self.makeFreshTypeSpecific(.Wildcard);
                try blockEnvironment.add(decl.identifier, freshWildcard);
                const expressionType = try self._inferType(decl.expression, blockEnvironment);
                try self.unifyTypes(freshWildcard, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            } else {
                const expressionType = try self._inferType(decl.expression, environment);
                try blockEnvironment.add(decl.identifier, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            }
        },
        .Lambda => |lam| {
            const closureEnvironment = try TypeEnv.init(self.allocator, environment);
            const argumentType = try self.makeFreshTypeSpecific(.Wildcard);
            try closureEnvironment.add(lam.identifier, argumentType);

            const bodyType = try self._inferType(lam.block, closureEnvironment);

            const lambdaType = try self.makeFreshTypeSpecific(.{ .Lambda = .{
                .argType = argumentType,
                .returnType = bodyType,
            } });

            expression.*.Lambda.type = lambdaType;
            return lambdaType;
        },
    }
}

fn unifyTypes(self: *TypeChecker, left: *Type, right: *Type) !void {
    if (std.meta.activeTag(left.*) == std.meta.activeTag(right.*)) return;

    if (right.* == .Wildcard) return try self.unifyTypes(right, left);

    if (left.* == .Wildcard) {
        return switch (right.*) {
            .Wildcard => unreachable,
            .Boolean => {
                left.* = .Boolean;
                return;
            },
            .Float => {
                left.* = .Float;
                return;
            },
            .Int => {
                left.* = .Int;
                return;
            },
            .String => {
                left.* = .String;
                return;
            },
            .Lambda => |lam| {
                const argType = try self.makeFreshTypeSpecific(.Wildcard);
                try self.unifyTypes(argType, lam.argType);

                const returnType = try self.makeFreshTypeSpecific(.Wildcard);
                try self.unifyTypes(returnType, lam.returnType);

                const lambdaType = try self.makeFreshTypeSpecific(.{ .Lambda = .{
                    .argType = argType,
                    .returnType = returnType,
                } });

                left.* = lambdaType.*;
                // to try:
                // left.* = right.*;
                return;
            },
        };
    }

    if (left.* == .Lambda and right.* == .Lambda) {
        try self.unifyTypes(left.Lambda.argType, right.Lambda.argType);
        try self.unifyTypes(left.Lambda.returnType, right.Lambda.returnType);
        return;
    }

    return TypeError.CANNOT_UNIFY;
}
