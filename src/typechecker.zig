const std = @import("std");

const TypeChecker = @This();
const Expression = @import("./ast.zig").Expression;

allocator: std.mem.Allocator,
errorContext: ?TypeErrorContext,

nextWildcardId: usize,
substitutions: std.AutoHashMap(usize, *Type),

pub const Type = union(enum) {
    Int,
    Float,
    Boolean,
    String,
    Lambda: struct {
        argType: *Type,
        returnType: *Type,
    },
    Wildcard: usize,
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
        expectedType: []const *Type,
        foundType: *Type,
        context: *Expression,
    },
};

pub fn init(allocator: std.mem.Allocator) TypeChecker {
    return TypeChecker{
        .allocator = allocator,
        .errorContext = null,

        .nextWildcardId = 0,
        .substitutions = std.AutoHashMap(usize, *Type).init(allocator),
    };
}

pub fn inferType(self: *TypeChecker, expression: *Expression) TypeError!*Type {
    const typeEnv = try TypeEnv.init(self.allocator, null);

    return self.finalizeType(try self._inferType(expression, typeEnv));
}

pub fn finalizeType(self: *TypeChecker, tp: *Type) *Type {
    const resolved = self.applySubstitutions(tp);

    switch (resolved.*) {
        .Lambda => {
            resolved.Lambda.argType = self.finalizeType(resolved.Lambda.argType);
            resolved.Lambda.returnType = self.finalizeType(resolved.Lambda.returnType);
        },
        else => {},
    }

    return resolved;
}

fn freshWildcard(self: *TypeChecker) !*Type {
    const wildcard = try self.makeFreshTypeSpecific(.{ .Wildcard = self.nextWildcardId });
    self.nextWildcardId += 1;
    return wildcard;
}

const WildcardPrinter = struct {
    currentWildcardChar: u8 = 'a',
    wildcardCharMap: std.AutoHashMap(usize, u8),

    fn getChar(self: *WildcardPrinter, wildcardId: usize) !u8 {
        if (self.wildcardCharMap.get(wildcardId)) |char| return char;

        defer self.currentWildcardChar += 1;
        try self.wildcardCharMap.put(wildcardId, self.currentWildcardChar);
        return self.currentWildcardChar;
    }
};

pub fn prettyPrint(allocator: std.mem.Allocator, tp: Type, level: u8) ![]const u8 {
    var wildcardPrinter = WildcardPrinter{
        .wildcardCharMap = std.AutoHashMap(usize, u8).init(allocator),
    };

    return try _prettyPrint(allocator, tp, level, &wildcardPrinter);
}

fn _prettyPrint(allocator: std.mem.Allocator, tp: Type, level: u8, wildcardPrinter: *WildcardPrinter) ![]const u8 {
    return switch (tp) {
        .Boolean => "bool",
        .Float => "float",
        .Int => "int",
        .String => "string",
        .Wildcard => |wild| {
            const char = try wildcardPrinter.getChar(wild);
            return try std.fmt.allocPrint(allocator, "'{c}", .{char});
        },
        .Lambda => |lam| {
            var buf = try std.ArrayList(u8).initCapacity(allocator, 0);

            if (level >= 1) {
                try buf.print(allocator, "({s} -> {s})", .{ try _prettyPrint(allocator, lam.argType.*, 1, wildcardPrinter), try _prettyPrint(allocator, lam.returnType.*, 0, wildcardPrinter) });
            } else {
                try buf.print(allocator, "{s} -> {s}", .{ try _prettyPrint(allocator, lam.argType.*, 1, wildcardPrinter), try _prettyPrint(allocator, lam.returnType.*, 0, wildcardPrinter) });
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
                        .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                            try self.makeFreshTypeSpecific(.Boolean),
                        }) catch {
                            return TypeError.OUT_OF_MEMORY;
                        },
                        .foundType = tp,
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

            if (tp) |val| return self.applySubstitutions(val);
            self.errorContext = .{
                .UNBOUND_VARIABLE = .{
                    .variable = v,
                },
            };
            return TypeError.UNBOUND_VARIABLE;
        },
        .Application => |app| {
            const calleeType = self.applySubstitutions(try self._inferType(app.callee, environment));

            const _argType = try self.freshWildcard();
            const _returnType = try self.freshWildcard();

            const lambdaType = try self.makeFreshTypeSpecific(.{ .Lambda = .{
                .argType = _argType,
                .returnType = _returnType,
            } });

            self.unifyTypes(calleeType, lambdaType) catch {
                self.errorContext = TypeErrorContext{
                    .UNEXPECTED_TYPE = .{
                        .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                            lambdaType,
                        }) catch {
                            return TypeError.OUT_OF_MEMORY;
                        },
                        .foundType = calleeType,
                        .context = app.callee,
                    },
                };

                return TypeError.UNEXPECTED_TYPE;
            };

            const valueType = try self._inferType(app.value, environment);

            self.unifyTypes(valueType, _argType) catch {
                self.errorContext = TypeErrorContext{
                    .UNEXPECTED_TYPE = .{
                        .expectedType = self.allocator.dupe(*Type, &[_]*Type{_argType}) catch {
                            return TypeError.OUT_OF_MEMORY;
                        },
                        .foundType = valueType,
                        .context = app.value,
                    },
                };

                return TypeError.UNEXPECTED_TYPE;
            };

            return _returnType;
        },
        .BinaryOperation => |bop| {
            const rawLeft = try self._inferType(bop.left, environment);
            const rawRight = try self._inferType(bop.right, environment);

            const leftType = self.applySubstitutions(rawLeft);
            const rightType = self.applySubstitutions(rawRight);

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
                                .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                                    try self.makeFreshTypeSpecific(.Boolean),
                                    try self.makeFreshTypeSpecific(.Float),
                                    try self.makeFreshTypeSpecific(.Int),
                                    try self.makeFreshTypeSpecific(.String),
                                }) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = leftType,
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
                                .expectedType = self.allocator.dupe(*Type, &[_]*Type{freshType}) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = leftType,
                                .context = expression,
                            },
                        };
                        return TypeError.UNEXPECTED_TYPE;
                    };
                    self.unifyTypes(rightType, freshType) catch {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(*Type, &[_]*Type{freshType}) catch {
                                    return TypeError.OUT_OF_MEMORY;
                                },
                                .foundType = rightType,
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
                    .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                        try self.makeFreshTypeSpecific(.Boolean),
                    }) catch {
                        return TypeError.OUT_OF_MEMORY;
                    },
                    .foundType = conditionType,
                    .context = expression,
                } };
                return TypeError.UNEXPECTED_TYPE;
            };
            const satisfyType = try self._inferType(cond.satisfyBlock, environment);
            const elseType = try self._inferType(cond.elseBlock, environment);

            self.unifyTypes(satisfyType, elseType) catch {
                self.errorContext = TypeErrorContext{ .UNEXPECTED_TYPE = .{
                    .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                        satisfyType,
                    }) catch {
                        return TypeError.OUT_OF_MEMORY;
                    },
                    .foundType = elseType,
                    .context = cond.elseBlock,
                } };
                return TypeError.UNEXPECTED_TYPE;
            };

            return satisfyType;
        },
        .Declaration => |decl| {
            const blockEnvironment = try TypeEnv.init(self.allocator, environment);
            if (decl.identifier[0] == '@') {
                const identType = try self.freshWildcard();
                try blockEnvironment.add(decl.identifier, identType);
                const expressionType = try self._inferType(decl.expression, blockEnvironment);
                try self.unifyTypes(identType, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            } else {
                const expressionType = try self._inferType(decl.expression, environment);
                try blockEnvironment.add(decl.identifier, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            }
        },
        .Lambda => |lam| {
            const closureEnvironment = try TypeEnv.init(self.allocator, environment);
            const argumentType = try self.freshWildcard();
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

fn applySubstitutions(self: *TypeChecker, tp: *Type) *Type {
    if (tp.* == .Wildcard)
        if (self.substitutions.get(tp.Wildcard)) |resolvedType| {
            const nestedType = self.applySubstitutions(resolvedType);
            self.substitutions.put(tp.Wildcard, nestedType) catch {};

            return nestedType;
        };
    return tp;
}

fn unifyTypes(self: *TypeChecker, rawLeft: *Type, rawRight: *Type) !void {
    const left = self.applySubstitutions(rawLeft);
    const right = self.applySubstitutions(rawRight);

    if (left == right or (left.* == .Wildcard and right.* == .Wildcard and left.Wildcard == right.Wildcard)) {
        return;
    }

    if (left.* == .Wildcard) {
        self.substitutions.put(left.Wildcard, right) catch return TypeError.OUT_OF_MEMORY;
        return;
    }
    if (right.* == .Wildcard) {
        self.substitutions.put(right.Wildcard, left) catch return TypeError.OUT_OF_MEMORY;
        return;
    }

    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return TypeError.CANNOT_UNIFY;
    }

    if (left.* == .Lambda) {
        try self.unifyTypes(left.Lambda.argType, right.Lambda.argType);
        try self.unifyTypes(left.Lambda.returnType, right.Lambda.returnType);
    }
}
