const std = @import("std");

const Expression = @import("./ast.zig").Expression;
const TypeAst = @import("./ast.zig").TypeAst;
const MatchPattern = @import("./ast.zig").MatchPattern;
const SharedContext = @import("./shared.zig");

const TypeChecker = @This();
allocator: std.mem.Allocator,
errorContext: ?TypeErrorContext,
sharedContext: ?*SharedContext,

nextWildcardId: usize,
substitutions: std.AutoHashMap(usize, *Type),

pub const Type = union(enum) {
    Wildcard: usize,

    Unit,
    Boolean,
    Float,
    Int,
    String,

    Lambda: struct {
        argType: *Type,
        returnType: *Type,
    },

    Environment: *Scope,
    Tuple: []*Type,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,

    values: std.StringHashMap(*Type),
    types: std.StringHashMap(*Type),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) TypeError!*Scope {
        const env = allocator.create(Scope) catch {
            return TypeError.ENVIRONMENT_INITALIZATION_ERROR;
        };

        env.* = Scope{
            .allocator = allocator,
            .parent = parent,
            .values = std.StringHashMap(*Type).init(allocator),
            .types = std.StringHashMap(*Type).init(allocator),
        };

        return env;
    }

    fn addValue(self: *Scope, identifier: []const u8, tp: *Type) !void {
        self.values.put(identifier, tp) catch {
            return TypeError.ENVIRONMENT_MAP_ERROR;
        };
    }

    fn getValue(self: *Scope, identifier: []const u8) ?*Type {
        if (self.values.get(identifier)) |val| {
            return val;
        }

        if (self.parent) |parent_env| {
            return parent_env.getValue(identifier);
        }

        return null;
    }

    fn addType(self: *Scope, identifier: []const u8, tp: *Type) !void {
        self.types.put(identifier, tp) catch {
            return TypeError.ENVIRONMENT_MAP_ERROR;
        };
    }

    fn getType(self: *Scope, identifier: []const u8) ?*Type {
        if (self.types.get(identifier)) |val| {
            return val;
        }

        if (self.parent) |parent_env| {
            return parent_env.getType(identifier);
        }

        return null;
    }
};

pub const TypeError = error{
    OUT_OF_MEMORY,
    ENVIRONMENT_INITALIZATION_ERROR,
    ENVIRONMENT_MAP_ERROR,

    UNBOUND_VARIABLE,

    UNEXPECTED_TYPE,
    CANNOT_UNIFY,

    MISSING_MATCH_CASE,
    UNMATCHED_PATTERN,

    PROPERTY_NOT_FOUND_ON_OBJECT,
    MEMBER_ACCESS_ON_NON_ENVIRONMENT,
    EXPECTED_ENVIRONMENT_TYPE_ON_MODULE_END,
    SHADOWING_BY_MODULE_NOT_ALLOWED,
    EXPECTED_ENVIRONMENT_ON_ENV_EXPANSION,

    UNIMPLEMENTED,
    IMPORT_FILE_NOT_FOUND,
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

pub fn init(allocator: std.mem.Allocator, sharedContext: ?*SharedContext) TypeChecker {
    return TypeChecker{
        .allocator = allocator,
        .errorContext = null,
        .sharedContext = sharedContext,

        .nextWildcardId = 0,
        .substitutions = std.AutoHashMap(usize, *Type).init(allocator),
    };
}

fn freshEnvironment(self: *TypeChecker, parentEnvironment: ?*Scope) !*Scope {
    const freshEnv = try Scope.init(self.allocator, parentEnvironment);

    if (parentEnvironment == null) {
        try freshEnv.addType("bool", try self.makeFreshTypeSpecific(.Boolean));
        try freshEnv.addType("int", try self.makeFreshTypeSpecific(.Int));
        try freshEnv.addType("float", try self.makeFreshTypeSpecific(.Float));
        try freshEnv.addType("string", try self.makeFreshTypeSpecific(.String));
        try freshEnv.addType("unit", try self.makeFreshTypeSpecific(.Unit));
    }

    return freshEnv;
}

pub fn inferType(self: *TypeChecker, expression: *Expression) TypeError!*Type {
    const typeEnv = try self.freshEnvironment(null);

    return self.finalizeType(try self._inferType(expression, typeEnv));
}

pub fn finalizeType(self: *TypeChecker, tp: *Type) *Type {
    const resolved = self.applySubstitutions(tp);

    switch (resolved.*) {
        .Lambda => {
            resolved.Lambda.argType = self.finalizeType(resolved.Lambda.argType);
            resolved.Lambda.returnType = self.finalizeType(resolved.Lambda.returnType);
        },
        .Environment => |env| {
            var it = env.values.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.* = self.finalizeType(entry.value_ptr.*);
            }
        },
        .Tuple => |types| {
            for (types, 0..) |t, i| {
                types[i] = self.finalizeType(t);
            }
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

pub const PrettyPrinter = struct {
    allocator: std.mem.Allocator,
    wildcardPrinter: WildcardPrinter,

    pub fn prettyPrint(allocator: std.mem.Allocator, tp: Type) ![]const u8 {
        var prettyPrinter = PrettyPrinter{
            .allocator = allocator,
            .wildcardPrinter = WildcardPrinter{
                .wildcardCharMap = std.AutoHashMap(usize, u8).init(allocator),
            },
        };
        return prettyPrinter._prettyPrint(tp, 0);
    }

    fn _prettyPrint(self: *PrettyPrinter, tp: Type, level: u8) ![]const u8 {
        return switch (tp) {
            .Unit => "unit",
            .Boolean => "bool",
            .Float => "float",
            .Int => "int",
            .String => "string",
            .Tuple => |types| {
                var str = std.ArrayList(u8).initCapacity(self.allocator, (types.len - 1) * 3) catch return TypeError.OUT_OF_MEMORY;

                if (level >= 11) {
                    str.print(self.allocator, "(", .{}) catch return TypeError.OUT_OF_MEMORY;
                }

                str.print(self.allocator, "{s}", .{try self._prettyPrint(types[0].*, 11)}) catch return TypeError.OUT_OF_MEMORY;

                for (types[1..]) |_tp| {
                    str.print(self.allocator, " * {s}", .{try self._prettyPrint(_tp.*, 11)}) catch return TypeError.OUT_OF_MEMORY;
                }

                if (level >= 11) {
                    str.print(self.allocator, ")", .{}) catch return TypeError.OUT_OF_MEMORY;
                }

                return str.items;
            },
            .Wildcard => |wild| {
                const char = try self.wildcardPrinter.getChar(wild);
                return try std.fmt.allocPrint(self.allocator, "'{c}", .{char});
            },
            .Lambda => |lam| {
                var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                if (level >= 1) {
                    try buf.print(self.allocator, "({s} -> {s})", .{ try self._prettyPrint(lam.argType.*, 1), try self._prettyPrint(lam.returnType.*, 0) });
                } else {
                    try buf.print(self.allocator, "{s} -> {s}", .{ try self._prettyPrint(lam.argType.*, 1), try self._prettyPrint(lam.returnType.*, 0) });
                }
                return buf.items;
            },
            .Environment => |env| {
                var str = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                try str.print(self.allocator, "env {{\n", .{});

                try str.print(self.allocator, "\tvalues {{\n", .{});
                var values = try std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0);
                var types = try std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0);

                var current_env: ?*Scope = env;
                while (current_env) |curr| {
                    var valuesIterator = curr.values.iterator();

                    while (valuesIterator.next()) |entry| {
                        values.insert(self.allocator, 0, entry) catch return TypeError.OUT_OF_MEMORY;
                    }

                    var typesIterator = curr.types.iterator();

                    while (typesIterator.next()) |entry| {
                        types.insert(self.allocator, 0, entry) catch return TypeError.OUT_OF_MEMORY;
                    }
                    current_env = curr.parent;
                }

                for (values.items) |entry| {
                    try str.print(self.allocator, "\t\t{s}: {s}\n", .{ entry.key_ptr.*, try self._prettyPrint(entry.value_ptr.*.*, 0) });
                }
                try str.print(self.allocator, "\t}}\n\ttypes {{\n", .{});

                for (types.items) |entry| {
                    try str.print(self.allocator, "\t\t{s}: {s}\n", .{ entry.key_ptr.*, try self._prettyPrint(entry.value_ptr.*.*, 0) });
                }

                try str.print(self.allocator, "\t}}\n}}\n", .{});

                return str.items;
            },
        };
    }
};

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

fn _inferType(self: *TypeChecker, expression: *Expression, environment: *Scope) TypeError!*Type {
    switch (expression.*) {
        .Unit => {
            return try self.makeFreshTypeSpecific(.Unit);
        },
        .Number => {
            const freshType = try self.makeFreshType();
            if (std.mem.containsAtLeast(u8, expression.Number, 1, ".")) {
                freshType.* = .Float;
            } else {
                freshType.* = .Int;
            }

            return freshType;
        },
        .Import => |filePath| {
            if (self.sharedContext) |sc| {
                const ret = sc.get(filePath) catch {
                    return TypeError.IMPORT_FILE_NOT_FOUND;
                };
                return ret.type orelse return TypeError.IMPORT_FILE_NOT_FOUND;
            } else {
                return TypeError.ENVIRONMENT_INITALIZATION_ERROR;
            }
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
        .Tuple => |expressions| {
            var types = std.ArrayList(*Type).initCapacity(self.allocator, expressions.len) catch return TypeError.OUT_OF_MEMORY;

            for (expressions) |expr| {
                types.append(self.allocator, try self._inferType(expr, environment)) catch return TypeError.OUT_OF_MEMORY;
            }

            return try self.makeFreshTypeSpecific(.{ .Tuple = types.items });
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
        .UnaryMinus => |unaryMinus| {
            const tp = try self._inferType(unaryMinus, environment);

            const intType = try self.makeFreshTypeSpecific(.Int);
            const floatType = try self.makeFreshTypeSpecific(.Float);

            self.unifyTypes(tp, intType) catch {
                self.unifyTypes(tp, floatType) catch {
                    self.errorContext = .{
                        .UNEXPECTED_TYPE = .{
                            .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                                intType,
                                floatType,
                            }) catch {
                                return TypeError.OUT_OF_MEMORY;
                            },
                            .foundType = tp,
                            .context = expression,
                        },
                    };
                    return TypeError.UNEXPECTED_TYPE;
                };
            };

            return tp;
        },
        .Variable => |v| {
            const tp = environment.getValue(v);

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
                    const intType = try self.makeFreshTypeSpecific(.Int);
                    const floatType = try self.makeFreshTypeSpecific(.Float);
                    const stringType = try self.makeFreshTypeSpecific(.String);

                    self.unifyTypes(leftType, intType) catch {
                        self.unifyTypes(leftType, floatType) catch {
                            if (bop.operation == .ADD) {
                                self.unifyTypes(leftType, stringType) catch {};
                            }
                        };
                    };

                    const resolvedLeftType = self.applySubstitutions(leftType);

                    if (resolvedLeftType.* != .Int and resolvedLeftType.* != .Float and (resolvedLeftType.* != .String or bop.operation != .ADD)) {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(*Type, if (bop.operation == .ADD) &[_]*Type{
                                    intType,
                                    floatType,
                                    stringType,
                                } else &[_]*Type{ intType, floatType }) catch return TypeError.OUT_OF_MEMORY,
                                .foundType = leftType,
                                .context = bop.left,
                            },
                        };

                        return TypeError.UNEXPECTED_TYPE;
                    }

                    self.unifyTypes(rightType, leftType) catch {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                                    leftType,
                                }) catch return TypeError.OUT_OF_MEMORY,
                                .foundType = rightType,
                                .context = bop.right,
                            },
                        };

                        return TypeError.UNEXPECTED_TYPE;
                    };

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
            const blockEnvironment = try self.freshEnvironment(environment);

            var explicitTypeOptional: ?*Type = null;

            if (decl.explicitType) |explicitTypeAst| {
                explicitTypeOptional = try self.parseTypeAst(explicitTypeAst.*, environment);
            }
            if (decl.identifier[0] == '@') {
                const identType = try self.freshWildcard();
                try blockEnvironment.addValue(decl.identifier, identType);
                const expressionType = try self._inferType(decl.expression, blockEnvironment);

                if (explicitTypeOptional) |explicitType| {
                    self.unifyTypes(identType, explicitType) catch {
                        self.errorContext = TypeErrorContext{ .UNEXPECTED_TYPE = .{
                            .context = decl.expression,
                            .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                                explicitType,
                            }) catch return TypeError.OUT_OF_MEMORY,
                            .foundType = identType,
                        } };
                        return TypeError.UNEXPECTED_TYPE;
                    };
                }

                try self.unifyTypes(identType, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            } else {
                const expressionType = try self._inferType(decl.expression, environment);

                if (explicitTypeOptional) |explicitType| {
                    self.unifyTypes(expressionType, explicitType) catch {
                        self.errorContext = TypeErrorContext{ .UNEXPECTED_TYPE = .{
                            .context = decl.expression,
                            .expectedType = self.allocator.dupe(*Type, &[_]*Type{
                                explicitType,
                            }) catch return TypeError.OUT_OF_MEMORY,
                            .foundType = expressionType,
                        } };
                        return TypeError.UNEXPECTED_TYPE;
                    };
                }

                try blockEnvironment.addValue(decl.identifier, expressionType);

                return try self._inferType(decl.block, blockEnvironment);
            }
        },
        .Lambda => |lam| {
            const closureEnvironment = try self.freshEnvironment(environment);
            const argumentType = try self.freshWildcard();
            try closureEnvironment.addValue(lam.identifier, argumentType);

            const bodyType = try self._inferType(lam.block, closureEnvironment);

            const lambdaType = try self.makeFreshTypeSpecific(.{ .Lambda = .{
                .argType = argumentType,
                .returnType = bodyType,
            } });

            if (expression.*.Lambda.explicitArgumentType) |explicitTypeAst| {
                const explicitType = try self.parseTypeAst(explicitTypeAst.*, environment);
                try self.unifyTypes(explicitType, argumentType);
            }

            expression.*.Lambda.inferredType = lambdaType;

            return lambdaType;
        },
        .Match => |match| {
            const scrutineeTp = try self._inferType(match.scrutinee, environment);

            if (match.explicitScrutineeType) |explicitScrutineeTypeAst| {
                const parsedScrutineeType = try self.parseTypeAst(explicitScrutineeTypeAst.*, environment);
                try self.unifyTypes(scrutineeTp, parsedScrutineeType);
            }
            var caseTypes = std.ArrayList(*Type).initCapacity(self.allocator, match.cases.len) catch return TypeError.OUT_OF_MEMORY;

            for (match.cases) |case| {
                const freshEnv = try self.freshEnvironment(environment);

                const patternTp = try self.inferPattern(freshEnv, case.pattern.*);

                self.unifyTypes(scrutineeTp, patternTp) catch {
                    return TypeError.UNMATCHED_PATTERN;
                };

                caseTypes.append(self.allocator, try self._inferType(case.block, freshEnv)) catch return TypeError.OUT_OF_MEMORY;
            }

            if (caseTypes.items.len == 0) {
                return TypeError.MISSING_MATCH_CASE;
            }

            const firstTp = caseTypes.items[0];
            if (caseTypes.items.len > 1) {
                for (caseTypes.items[1..], 1..) |caseTp, i| {
                    self.unifyTypes(firstTp, caseTp) catch {
                        self.errorContext = TypeErrorContext{
                            .UNEXPECTED_TYPE = .{
                                .expectedType = self.allocator.dupe(*Type, &[_]*Type{firstTp}) catch return TypeError.OUT_OF_MEMORY,
                                .foundType = caseTp,
                                .context = match.cases[i].block,
                            },
                        };
                        return TypeError.UNEXPECTED_TYPE;
                    };
                }
            }

            return firstTp;
        },
        .MemberAccess => |memberAccess| {
            const objectType = self.applySubstitutions(try self._inferType(memberAccess.object, environment));

            if (objectType.* != .Environment) return TypeError.MEMBER_ACCESS_ON_NON_ENVIRONMENT;

            const memberType = objectType.Environment.getValue(memberAccess.member);

            if (memberType) |memberTp| {
                var cache = std.AutoHashMap(usize, *Type).init(self.allocator);
                defer cache.deinit();
                return try self.freshenType(memberTp, &cache);
            }

            return TypeError.PROPERTY_NOT_FOUND_ON_OBJECT;
        },
        .Module => |module| {
            const moduleEnvironment = try self.freshEnvironment(null);

            const tp = try self._inferType(module.block, moduleEnvironment);

            if (tp.* != .Environment) return TypeError.EXPECTED_ENVIRONMENT_TYPE_ON_MODULE_END;

            if (environment.getValue(module.identifier)) |_| {
                return TypeError.SHADOWING_BY_MODULE_NOT_ALLOWED;
            }

            try environment.addValue(module.identifier, try self.makeFreshTypeSpecific(.{ .Environment = tp.Environment }));

            return try self._inferType(module.rest, environment);
        },
        .CurrentEnvironment => {
            return try self.makeFreshTypeSpecific(.{ .Environment = environment });
        },
        .UseEnvironment => |env| {
            const typeEnv = try self._inferType(env.environment, environment);
            if (typeEnv.* != .Environment) return TypeError.EXPECTED_ENVIRONMENT_ON_ENV_EXPANSION;

            var temp_env = try self.freshEnvironment(environment);
            var cache = std.AutoHashMap(usize, *Type).init(self.allocator);
            defer cache.deinit();

            var it = typeEnv.Environment.values.iterator();
            while (it.next()) |entry| {
                const freshVal = try self.freshenType(entry.value_ptr.*, &cache);
                try temp_env.addValue(entry.key_ptr.*, freshVal);
            }

            return try self._inferType(env.block, temp_env);
        },
        .TypeAscription => |env| {
            const inferredType = try self._inferType(env.expression, environment);

            const parsedType = try self.parseTypeAst(env.explicitType.*, environment);

            try self.unifyTypes(inferredType, parsedType);

            return parsedType;
        },
    }
}

fn parseTypeAst(self: *TypeChecker, typeAst: TypeAst, environment: *Scope) TypeError!*Type {
    return switch (typeAst) {
        .Wildcard => try self.freshWildcard(),
        .Identifier => |ident| {
            if (environment.getType(ident)) |identifier| return identifier;
            if (ident[0] == '\'') {
                const newWildcard = try self.freshWildcard();

                try environment.addType(ident, newWildcard);

                return newWildcard;
            }
            return TypeError.UNBOUND_VARIABLE;
        },
        .Tuple => |tupleElements| {
            var elements = std.ArrayList(*Type).initCapacity(self.allocator, 1) catch return TypeError.OUT_OF_MEMORY;

            for (tupleElements) |elem| {
                elements.append(self.allocator, try self.parseTypeAst(elem.*, environment)) catch return TypeError.OUT_OF_MEMORY;
            }

            return try self.makeFreshTypeSpecific(.{ .Tuple = elements.items });
        },
        .Function => |fun| {
            return self.makeFreshTypeSpecific(.{ .Lambda = .{
                .argType = try self.parseTypeAst(fun.argument.*, environment),
                .returnType = try self.parseTypeAst(fun.returnType.*, environment),
            } });
        },
    };
}

fn inferPattern(self: *TypeChecker, environment: *Scope, pattern: MatchPattern) TypeError!*Type {
    return switch (pattern) {
        .Wildcard => self.freshWildcard(),
        .Identifier => |ident| {
            const freshType = try self.freshWildcard();
            try environment.addValue(ident, freshType);
            return freshType;
        },
        .Tuple => |tup| {
            var types = std.ArrayList(*Type).initCapacity(self.allocator, tup.binds.len) catch return TypeError.OUT_OF_MEMORY;
            for (tup.binds) |pat| {
                types.append(self.allocator, try self.inferPattern(environment, pat.*)) catch return TypeError.OUT_OF_MEMORY;
            }
            return try self.makeFreshTypeSpecific(.{ .Tuple = types.items });
        },
        .Cons => TypeError.UNIMPLEMENTED,
    };
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

fn occursInType(self: *TypeChecker, wildcardId: usize, tp: *Type) bool {
    const resolved = self.applySubstitutions(tp);
    switch (resolved.*) {
        .Wildcard => |id| return id == wildcardId,
        .Lambda => |lam| {
            return self.occursInType(wildcardId, lam.argType) or self.occursInType(wildcardId, lam.returnType);
        },
        .Tuple => |types| {
            for (types) |t| {
                if (self.occursInType(wildcardId, t)) return true;
            }
            return false;
        },
        .Environment => |env| {
            var it = env.values.iterator();
            while (it.next()) |entry| {
                if (self.occursInType(wildcardId, entry.value_ptr.*)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn freshenType(self: *TypeChecker, tp: *Type, cache: *std.AutoHashMap(usize, *Type)) TypeError!*Type {
    const resolved = self.applySubstitutions(tp);
    switch (resolved.*) {
        .Wildcard => |id| {
            if (cache.get(id)) |fresh| {
                return fresh;
            }
            const fresh = self.freshWildcard() catch return TypeError.OUT_OF_MEMORY;
            cache.put(id, fresh) catch return TypeError.OUT_OF_MEMORY;
            return fresh;
        },
        .Lambda => |lam| {
            const freshArg = try self.freshenType(lam.argType, cache);
            const freshRet = try self.freshenType(lam.returnType, cache);
            return self.makeFreshTypeSpecific(.{ .Lambda = .{ .argType = freshArg, .returnType = freshRet } }) catch return TypeError.OUT_OF_MEMORY;
        },
        .Tuple => |types| {
            const freshTypes = self.allocator.alloc(*Type, types.len) catch return TypeError.OUT_OF_MEMORY;
            for (types, 0..) |t, i| {
                freshTypes[i] = try self.freshenType(t, cache);
            }
            return self.makeFreshTypeSpecific(.{ .Tuple = freshTypes }) catch return TypeError.OUT_OF_MEMORY;
        },
        .Environment => |env| {
            const freshEnv = try self.freshEnvironment(env.parent);
            var it = env.values.iterator();
            while (it.next()) |entry| {
                const freshVal = try self.freshenType(entry.value_ptr.*, cache);
                try freshEnv.addValue(entry.key_ptr.*, freshVal);
            }
            return self.makeFreshTypeSpecific(.{ .Environment = freshEnv }) catch return TypeError.OUT_OF_MEMORY;
        },
        else => return resolved,
    }
}

fn unifyTypes(self: *TypeChecker, rawLeft: *Type, rawRight: *Type) TypeError!void {
    const left = self.applySubstitutions(rawLeft);
    const right = self.applySubstitutions(rawRight);

    if (left == right or (left.* == .Wildcard and right.* == .Wildcard and left.Wildcard == right.Wildcard)) {
        return;
    }

    if (left.* == .Wildcard) {
        if (self.occursInType(left.Wildcard, right)) {
            return TypeError.CANNOT_UNIFY;
        }
        self.substitutions.put(left.Wildcard, right) catch return TypeError.OUT_OF_MEMORY;
        return;
    }
    if (right.* == .Wildcard) {
        if (self.occursInType(right.Wildcard, left)) {
            return TypeError.CANNOT_UNIFY;
        }
        self.substitutions.put(right.Wildcard, left) catch return TypeError.OUT_OF_MEMORY;
        return;
    }

    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return TypeError.CANNOT_UNIFY;
    }

    switch (left.*) {
        .Lambda => {
            try self.unifyTypes(left.Lambda.argType, right.Lambda.argType);
            try self.unifyTypes(left.Lambda.returnType, right.Lambda.returnType);
        },
        .Tuple => |leftTypes| {
            const rightTypes = right.Tuple;
            if (leftTypes.len != rightTypes.len) {
                return TypeError.CANNOT_UNIFY;
            }
            for (leftTypes, rightTypes) |l, r| {
                try self.unifyTypes(l, r);
            }
        },
        else => {},
    }
}
