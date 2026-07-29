const std = @import("std");

const Expression = @import("./ast.zig").Expression;
const TypeAst = @import("./ast.zig").TypeAst;
const MatchPattern = @import("./ast.zig").MatchPattern;
const SharedContext = @import("./shared.zig");
const BuiltIn = @import("./builtin.zig");

const TypeChecker = @This();
allocator: std.mem.Allocator,
error_context: ?TypeErrorContext,
shared_context: ?*SharedContext,

next_wildcard_id: usize,
substitutions: std.AutoHashMap(usize, *Type),
primitive_types: PrimitiveTypes,

const PrimitiveTypes = struct {
    unit: *Type,
    int: *Type,
    float: *Type,
    string: *Type,
    boolean: *Type,
};

pub const Type = union(enum) {
    wildcard: usize,

    unit,
    boolean,
    float,
    int,
    string,

    lambda: struct {
        argument: *Type,
        returns: *Type,
    },
    builtin: *const fn (*TypeChecker, *Type) TypeError!*Type,

    scope: *Scope,
    tuple: []*Type,

    alias: struct {
        name: []const u8,
        underlying: *Type,
    },

    variant: struct {
        name: []const u8,
        payload: ?*Type,
        parent_union: ?*Type,
    },

    union_of: []*Type,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,

    values: std.StringHashMap(*Type),
    types: std.StringHashMap(*Type),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) TypeError!*Scope {
        const env = allocator.create(Scope) catch {
            return TypeError.EnvironmentInitializationError;
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
            return TypeError.EnvironmentMapError;
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
            return TypeError.EnvironmentMapError;
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
    OutOfMemory,
    EnvironmentInitializationError,
    EnvironmentMapError,

    UnboundVariable,

    UnboundType,
    UnexpectedType,
    CannotUnify,

    MissingMatchCase,
    UnmatchedPattern,
    PatternOverusedVariable,

    PropertyNotFoundOnObject,
    MemberAccessOnNonEnvrionment,
    ExpectedEnvironmentTypeOnModuleEnd,
    ShadowingByModuleNotAllowed,
    ExpectedEnvironmentOnEnvExpansion,

    ExpectedConstructor,
    MissingConstructorPayload,
    UnexpectedConstructorPayload,
    UnboundConstructor,
    DuplicatedConstructor,

    Unimplemented,
    ImportFileNotFound,
};

const TypeErrorContext = union(enum) {
    unbound_variable: struct {
        variable: []const u8,
    },
    unexpected_type: struct {
        expected_type: []const *Type,
        found_type: *Type,
        context: *Expression,
    },
};

var global_unit_type: Type = .unit;
var global_int_type: Type = .int;
var global_float_type: Type = .float;
var global_string_type: Type = .string;
var global_boolean_type: Type = .boolean;

pub fn init(allocator: std.mem.Allocator, shared_context: ?*SharedContext) TypeChecker {
    return TypeChecker{
        .allocator = allocator,
        .error_context = null,
        .shared_context = shared_context,
        .next_wildcard_id = 0,
        .substitutions = std.AutoHashMap(usize, *Type).init(allocator),
        .primitive_types = PrimitiveTypes{
            .int = &global_int_type,
            .unit = &global_unit_type,
            .float = &global_float_type,
            .string = &global_string_type,
            .boolean = &global_boolean_type,
        },
    };
}

fn freshScope(self: *TypeChecker, parent_scope: ?*Scope) !*Scope {
    const fresh_scope = try Scope.init(self.allocator, parent_scope);

    if (parent_scope == null) {
        try fresh_scope.addType("int", self.primitive_types.int);
        try fresh_scope.addType("bool", self.primitive_types.boolean);
        try fresh_scope.addType("float", self.primitive_types.float);
        try fresh_scope.addType("unit", self.primitive_types.unit);
        try fresh_scope.addType("string", self.primitive_types.string);

        { // math builtins
            const intAndIntToInt = try self.freshType(.{ .builtin = BuiltIn.Types.intAndIntToInt });
            const floatToFloat = try self.freshType(.{ .builtin = BuiltIn.Types.floatToFloat });

            try fresh_scope.addValue("<@math.mod>", intAndIntToInt);

            inline for (.{ "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh" }) |name| {
                try fresh_scope.addValue("<@math." ++ name ++ ">", floatToFloat);
            }

            try fresh_scope.addValue("<@math.log2>", floatToFloat);
            try fresh_scope.addValue("<@math.log10>", floatToFloat);
            try fresh_scope.addValue("<@math.log>", try self.freshType(.{ .builtin = BuiltIn.Types.floatAndFloatToFloat }));

            try fresh_scope.addValue("<@math.sqrt>", floatToFloat);
            try fresh_scope.addValue("<@math.cbrt>", floatToFloat);

            try fresh_scope.addValue("<@math.round>", floatToFloat);
            try fresh_scope.addValue("<@math.floor>", floatToFloat);
            try fresh_scope.addValue("<@math.ceil>", floatToFloat);
            try fresh_scope.addValue("<@math.trunc>", floatToFloat);

            try fresh_scope.addValue("<@math.gcd>", intAndIntToInt);
        }
    }

    return fresh_scope;
}

pub fn inferType(self: *TypeChecker, expression: *Expression) TypeError!*Type {
    const fresh_scope = try self.freshScope(null);

    return self.finalizeType(try self._inferType(expression, fresh_scope));
}

pub fn finalizeType(self: *TypeChecker, tp: *Type) *Type {
    var visited = std.AutoHashMap(*Type, void).init(self.allocator);
    defer visited.deinit();

    return self._finalizeType(tp, &visited);
}

fn _finalizeType(self: *TypeChecker, tp: *Type, visited: *std.AutoHashMap(*Type, void)) *Type {
    const resolved = self.applySubstitutions(tp);

    if (visited.contains(resolved)) return resolved;
    visited.put(resolved, {}) catch {};

    switch (resolved.*) {
        .lambda => {
            resolved.lambda.argument = self._finalizeType(resolved.lambda.argument, visited);
            resolved.lambda.returns = self._finalizeType(resolved.lambda.returns, visited);
        },
        .scope => |scope| {
            var curr_scope: ?*Scope = scope;
            while (curr_scope) |s| {
                var it_values = s.values.iterator();
                while (it_values.next()) |entry| {
                    entry.value_ptr.* = self._finalizeType(entry.value_ptr.*, visited);
                }

                var it_types = s.types.iterator();
                while (it_types.next()) |entry| {
                    entry.value_ptr.* = self._finalizeType(entry.value_ptr.*, visited);
                }
                curr_scope = s.parent;
            }
        },
        .tuple => |tuple| {
            for (tuple, 0..) |t, i| {
                tuple[i] = self._finalizeType(t, visited);
            }
        },
        .alias => |alias| {
            resolved.alias.underlying = self._finalizeType(alias.underlying, visited);
        },
        .variant => |variant| {
            if (variant.payload) |payload| {
                resolved.variant.payload = self._finalizeType(payload, visited);
            }
        },
        .union_of => |un| {
            for (un, 0..) |t, i| {
                un[i] = self._finalizeType(t, visited);
            }
        },
        else => {},
    }

    return resolved;
}

pub fn freshWildcard(self: *TypeChecker) !*Type {
    const wildcard = try self.freshType(.{ .wildcard = self.next_wildcard_id });
    self.next_wildcard_id += 1;
    return wildcard;
}

const WildcardPrinter = struct {
    current_wildcard_char: u8 = 'a',
    wildcard_char_map: std.AutoHashMap(usize, u8),

    fn getChar(self: *WildcardPrinter, wildcardId: usize) !u8 {
        if (self.wildcard_char_map.get(wildcardId)) |char| return char;

        defer self.current_wildcard_char += 1;
        try self.wildcard_char_map.put(wildcardId, self.current_wildcard_char);
        return self.current_wildcard_char;
    }
};

pub const PrettyPrinter = struct {
    allocator: std.mem.Allocator,
    wildcard_printer: WildcardPrinter,
    visited: std.AutoHashMap(*Type, void),

    pub fn prettyPrint(allocator: std.mem.Allocator, tp: *Type) ![]const u8 {
        var pretty_printer = PrettyPrinter{
            .allocator = allocator,
            .wildcard_printer = WildcardPrinter{
                .wildcard_char_map = std.AutoHashMap(usize, u8).init(allocator),
            },
            .visited = std.AutoHashMap(*Type, void).init(allocator),
        };
        defer pretty_printer.visited.deinit();
        defer pretty_printer.wildcard_printer.wildcard_char_map.deinit();

        return pretty_printer._prettyPrint(tp, 0);
    }

    fn _prettyPrint(self: *PrettyPrinter, tp: *Type, level: u8) ![]const u8 {
        if (self.visited.contains(tp)) {
            return try std.fmt.allocPrint(self.allocator, "<cyclic: {s}>", .{@tagName(tp.*)});
        }

        try self.visited.put(tp, {});
        defer _ = self.visited.remove(tp);
        return switch (tp.*) {
            .unit => "unit",
            .boolean => "bool",
            .float => "float",
            .int => "int",
            .string => "string",
            .tuple => |tuple| {
                var str = std.ArrayList(u8).initCapacity(self.allocator, (tuple.len - 1) * 3) catch return TypeError.OutOfMemory;

                if (level >= 11) {
                    str.print(self.allocator, "(", .{}) catch return TypeError.OutOfMemory;
                }

                str.print(self.allocator, "{s}", .{try self._prettyPrint(tuple[0], 11)}) catch return TypeError.OutOfMemory;

                for (tuple[1..]) |it| {
                    str.print(self.allocator, " * {s}", .{try self._prettyPrint(it, 11)}) catch return TypeError.OutOfMemory;
                }

                if (level >= 11) {
                    str.print(self.allocator, ")", .{}) catch return TypeError.OutOfMemory;
                }

                return str.items;
            },
            .wildcard => |wildcard| {
                const char = try self.wildcard_printer.getChar(wildcard);
                return try std.fmt.allocPrint(self.allocator, "'{c}", .{char});
            },
            .lambda => |lambda| {
                var buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                if (level >= 1) {
                    try buf.print(self.allocator, "({s} -> {s})", .{ try self._prettyPrint(lambda.argument, 1), try self._prettyPrint(lambda.returns, 0) });
                } else {
                    try buf.print(self.allocator, "{s} -> {s}", .{ try self._prettyPrint(lambda.argument, 1), try self._prettyPrint(lambda.returns, 0) });
                }
                return buf.items;
            },
            .builtin => "builtin",
            .scope => |scope| {
                var str = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                try str.print(self.allocator, "env {{\n", .{});

                try str.print(self.allocator, "\tvalues {{\n", .{});
                var values = try std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0);
                var types = try std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0);

                var current_env: ?*Scope = scope;
                while (current_env) |curr| {
                    var values_iterator = curr.values.iterator();

                    while (values_iterator.next()) |entry| {
                        values.insert(self.allocator, 0, entry) catch return TypeError.OutOfMemory;
                    }

                    var types_iterator = curr.types.iterator();

                    while (types_iterator.next()) |entry| {
                        types.insert(self.allocator, 0, entry) catch return TypeError.OutOfMemory;
                    }
                    current_env = curr.parent;
                }

                for (values.items) |entry| {
                    try str.print(self.allocator, "\t\t{s}: {s}\n", .{ entry.key_ptr.*, try self._prettyPrint(entry.value_ptr.*, 0) });
                }
                try str.print(self.allocator, "\t}}\n\ttypes {{\n", .{});

                for (types.items) |entry| {
                    try str.print(self.allocator, "\t\t{s}: {s}\n", .{ entry.key_ptr.*, try self._prettyPrint(entry.value_ptr.*, 0) });
                }

                try str.print(self.allocator, "\t}}\n}}\n", .{});

                return str.items;
            },
            .alias => |alias| return alias.name,
            .union_of => |it| {
                var str = try std.ArrayList(u8).initCapacity(self.allocator, 0);
                try str.print(self.allocator, "{s}", .{try self._prettyPrint(it[0], level)});

                if (it.len > 0) {
                    for (it[1..]) |item| {
                        try str.print(self.allocator, " | {s}", .{try self._prettyPrint(item, level)});
                    }
                }

                return str.items;
            },
            .variant => |variant| {
                var str = try std.ArrayList(u8).initCapacity(self.allocator, 0);

                if (level >= 6)
                    try str.print(self.allocator, "(", .{});
                try str.print(self.allocator, "{s}", .{variant.name});

                if (variant.payload) |payload| {
                    try str.print(self.allocator, " of {s}", .{try self._prettyPrint(payload, 6)});
                }

                if (level >= 6)
                    try str.print(self.allocator, ")", .{});

                return str.items;
            },
        };
    }
};

pub fn freshType(self: *TypeChecker, tp: Type) !*Type {
    return try freshTypeAllocator(self.allocator, tp);
}

fn freshTypeAllocator(allocator: std.mem.Allocator, tp: Type) !*Type {
    const fresh_type = allocator.create(Type) catch {
        return TypeError.OutOfMemory;
    };
    fresh_type.* = tp;

    return fresh_type;
}

pub fn _inferType(self: *TypeChecker, expression: *Expression, scope: *Scope) TypeError!*Type {
    switch (expression.*) {
        .unit => {
            return self.primitive_types.unit;
        },
        .number => |number| {
            if (std.mem.containsAtLeast(u8, number, 1, ".")) {
                return self.primitive_types.float;
            } else {
                return self.primitive_types.int;
            }
        },
        .import => |file_path| {
            if (self.shared_context) |sc| {
                const ret = sc.get(file_path) catch {
                    return TypeError.ImportFileNotFound;
                };
                return ret.type orelse return TypeError.ImportFileNotFound;
            } else {
                return TypeError.EnvironmentInitializationError;
            }
        },
        .constructor => |constructor| {
            var master_payload: ?*Type = null;
            if (scope.getType(constructor.name)) |type_definition| {
                if (type_definition.* != .variant) return TypeError.ExpectedConstructor;

                if (type_definition.variant.payload) |payload| {
                    if (constructor.payload) |exprPayload| {
                        const inferred_type = try self._inferType(exprPayload, scope);
                        try self.unifyTypes(payload, inferred_type);

                        master_payload = payload;
                    } else return TypeError.MissingConstructorPayload;
                } else {
                    if (constructor.payload) |_| {
                        return TypeError.UnexpectedConstructorPayload;
                    }
                    master_payload = null;
                }
                return type_definition.variant.parent_union orelse return TypeError.CannotUnify;
            }
            return TypeError.UnboundConstructor;
        },
        .boolean => return {
            return self.primitive_types.boolean;
        },
        .string => {
            return self.primitive_types.string;
        },
        .tuple => |tuple| {
            var types = std.ArrayList(*Type).initCapacity(self.allocator, tuple.len) catch return TypeError.OutOfMemory;

            for (tuple) |expr| {
                types.append(self.allocator, try self._inferType(expr, scope)) catch return TypeError.OutOfMemory;
            }

            return try self.freshType(.{ .tuple = types.items });
        },
        .not => |not| {
            const tp = try self._inferType(not, scope);

            const boolean_type = self.primitive_types.boolean;
            self.unifyTypes(tp, boolean_type) catch {
                self.error_context = .{
                    .unexpected_type = .{
                        .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                            self.primitive_types.boolean,
                        }) catch {
                            return TypeError.OutOfMemory;
                        },
                        .found_type = tp,
                        .context = expression,
                    },
                };
                return TypeError.UnexpectedType;
            };

            return self.primitive_types.boolean;
        },
        .unary_minus => |unary_minus| {
            const tp = try self._inferType(unary_minus, scope);

            const int_type = self.primitive_types.int;
            const float_type = self.primitive_types.float;

            self.unifyTypes(tp, int_type) catch {
                self.unifyTypes(tp, float_type) catch {
                    self.error_context = .{
                        .unexpected_type = .{
                            .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                                int_type,
                                float_type,
                            }) catch {
                                return TypeError.OutOfMemory;
                            },
                            .found_type = tp,
                            .context = expression,
                        },
                    };
                    return TypeError.UnexpectedType;
                };
            };

            return tp;
        },
        .variable => |variable| {
            const tp = scope.getValue(variable);

            if (tp) |val| return self.applySubstitutions(val);
            self.error_context = .{
                .unbound_variable = .{
                    .variable = variable,
                },
            };
            return TypeError.UnboundVariable;
        },
        .application => |application| {
            const callee_type = self.applySubstitutions(try self._inferType(application.callee, scope));

            const arg_type = try self.freshWildcard();
            if (callee_type.* == .builtin) {
                const value_type = try self._inferType(application.value, scope);

                return try callee_type.builtin(
                    self,
                    value_type,
                );
            }

            const return_type = try self.freshWildcard();

            const lambda_type = try self.freshType(.{ .lambda = .{
                .argument = arg_type,
                .returns = return_type,
            } });

            self.unifyTypes(callee_type, lambda_type) catch {
                self.error_context = TypeErrorContext{
                    .unexpected_type = .{
                        .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                            lambda_type,
                        }) catch {
                            return TypeError.OutOfMemory;
                        },
                        .found_type = callee_type,
                        .context = application.callee,
                    },
                };

                return TypeError.UnexpectedType;
            };

            const value_type = try self._inferType(application.value, scope);

            self.unifyTypes(value_type, arg_type) catch {
                self.error_context = TypeErrorContext{
                    .unexpected_type = .{
                        .expected_type = self.allocator.dupe(*Type, &[_]*Type{arg_type}) catch {
                            return TypeError.OutOfMemory;
                        },
                        .found_type = value_type,
                        .context = application.value,
                    },
                };

                return TypeError.UnexpectedType;
            };

            return return_type;
        },
        .binary_operation => |bop| {
            const raw_left = try self._inferType(bop.left, scope);
            const raw_right = try self._inferType(bop.right, scope);

            const left_type = self.applySubstitutions(raw_left);
            const right_type = self.applySubstitutions(raw_right);

            return switch (bop.operation) {
                .add, .subtract, .divide, .multiply, .gt, .gt_eq, .lt, .lt_eq => {
                    self.unifyTypes(left_type, self.primitive_types.int) catch {
                        self.unifyTypes(left_type, self.primitive_types.float) catch {
                            if (bop.operation == .add) {
                                self.unifyTypes(left_type, self.primitive_types.string) catch {};
                            }
                        };
                    };

                    const resolved_left_type = self.applySubstitutions(left_type);

                    if (resolved_left_type.* != .int and resolved_left_type.* != .float and (resolved_left_type.* != .string or bop.operation != .add)) {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, if (bop.operation == .add) &[_]*Type{
                                    self.primitive_types.int,
                                    self.primitive_types.float,
                                    self.primitive_types.string,
                                } else &[_]*Type{ self.primitive_types.int, self.primitive_types.float }) catch return TypeError.OutOfMemory,
                                .found_type = left_type,
                                .context = bop.left,
                            },
                        };

                        return TypeError.UnexpectedType;
                    }

                    self.unifyTypes(right_type, left_type) catch {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                                    left_type,
                                }) catch return TypeError.OutOfMemory,
                                .found_type = right_type,
                                .context = bop.right,
                            },
                        };

                        return TypeError.UnexpectedType;
                    };

                    // TODO: Type promotion

                    // if (left_type.* == .Float) {
                    //     right_type.* = .Float;
                    // }

                    // if (right_type.* == .Float) {
                    //     left_type.* = .Float;
                    // }

                    // Now left_type is the .Int type
                    // return left_type;

                    if (bop.operation == .gt or bop.operation == .gt_eq or bop.operation == .lt or bop.operation == .lt_eq) {
                        return self.primitive_types.boolean;
                    }
                    return left_type;
                },

                .eq_eq, .not_eq_eq, .eq, .not_eq => {
                    try self.unifyTypes(left_type, right_type);

                    if (left_type.* != .boolean and left_type.* != .float and left_type.* != .int and left_type.* != .string) {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                                    self.primitive_types.boolean,
                                    self.primitive_types.float,
                                    self.primitive_types.int,
                                    self.primitive_types.string,
                                }) catch {
                                    return TypeError.OutOfMemory;
                                },
                                .found_type = left_type,
                                .context = expression,
                            },
                        };
                        return TypeError.UnexpectedType;
                    }

                    return self.primitive_types.boolean;
                },

                .and_op, .or_op => {
                    self.unifyTypes(left_type, self.primitive_types.boolean) catch {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, &[_]*Type{self.primitive_types.boolean}) catch {
                                    return TypeError.OutOfMemory;
                                },
                                .found_type = left_type,
                                .context = expression,
                            },
                        };
                        return TypeError.UnexpectedType;
                    };
                    self.unifyTypes(right_type, self.primitive_types.boolean) catch {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, &[_]*Type{self.primitive_types.boolean}) catch {
                                    return TypeError.OutOfMemory;
                                },
                                .found_type = right_type,
                                .context = expression,
                            },
                        };
                        return TypeError.UnexpectedType;
                    };

                    return left_type;
                },

                // TODO: Type promotion
                // .eq, .not_eq => {
                // },
            };
        },
        .condition => |condition| {
            const condition_type = try self._inferType(condition.expression, scope);
            self.unifyTypes(condition_type, self.primitive_types.boolean) catch {
                self.error_context = TypeErrorContext{ .unexpected_type = .{
                    .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                        self.primitive_types.boolean,
                    }) catch {
                        return TypeError.OutOfMemory;
                    },
                    .found_type = condition_type,
                    .context = expression,
                } };
                return TypeError.UnexpectedType;
            };
            const satisfy_type = try self._inferType(condition.satisfy_block, scope);
            const else_type = try self._inferType(condition.else_block, scope);

            self.unifyTypes(satisfy_type, else_type) catch {
                self.error_context = TypeErrorContext{ .unexpected_type = .{
                    .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                        satisfy_type,
                    }) catch {
                        return TypeError.OutOfMemory;
                    },
                    .found_type = else_type,
                    .context = condition.else_block,
                } };
                return TypeError.UnexpectedType;
            };

            return satisfy_type;
        },
        .declaration => |declaration| {
            const block_scope = try self.freshScope(scope);

            const identifier = declaration.identifier;

            var explicit_type_optional: ?*Type = null;

            if (declaration.explicit_type) |explicitTypeAst| {
                explicit_type_optional = try self.parseTypeAst(explicitTypeAst.*, scope);
            }
            if (declaration.identifier[0] == '@') {
                const ident_type = try self.freshWildcard();
                try block_scope.addValue(identifier, ident_type);
                const expression_type = try self._inferType(declaration.expression, block_scope);

                if (explicit_type_optional) |explicit_type| {
                    self.unifyTypes(ident_type, explicit_type) catch {
                        self.error_context = TypeErrorContext{ .unexpected_type = .{
                            .context = declaration.expression,
                            .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                                explicit_type,
                            }) catch return TypeError.OutOfMemory,
                            .found_type = ident_type,
                        } };
                        return TypeError.UnexpectedType;
                    };
                }

                try self.unifyTypes(ident_type, expression_type);

                return try self._inferType(declaration.block, block_scope);
            } else {
                const expression_type = try self._inferType(declaration.expression, scope);

                if (explicit_type_optional) |explicitType| {
                    self.unifyTypes(expression_type, explicitType) catch {
                        self.error_context = TypeErrorContext{ .unexpected_type = .{
                            .context = declaration.expression,
                            .expected_type = self.allocator.dupe(*Type, &[_]*Type{
                                explicitType,
                            }) catch return TypeError.OutOfMemory,
                            .found_type = expression_type,
                        } };
                        return TypeError.UnexpectedType;
                    };
                }

                try block_scope.addValue(identifier, expression_type);

                return try self._inferType(declaration.block, block_scope);
            }
        },
        .type_declaration => |type_declaration| {
            const block_scope = try self.freshScope(scope);

            const identifier = type_declaration.identifier;

            const ident_type = try self.freshType(.{ .alias = .{
                .name = identifier,
                .underlying = try self.freshWildcard(),
            } });
            try block_scope.addType(identifier, ident_type);

            var explicit_type: ?*Type = null;
            if (type_declaration.types_ast.len == 1) {
                explicit_type = try self.parseTypeAst(type_declaration.types_ast[0].*, block_scope);

                if (explicit_type.?.* == .variant) {
                    explicit_type.?.variant.parent_union = ident_type;
                    try block_scope.addType(explicit_type.?.variant.name, explicit_type.?);
                }
            } else {
                var types = std.ArrayList(*Type).initCapacity(self.allocator, type_declaration.types_ast.len) catch return TypeError.OutOfMemory;
                var exhausted_identifiers = std.StringHashMap(void).init(self.allocator);
                defer exhausted_identifiers.deinit();

                for (type_declaration.types_ast) |typeAst| {
                    if (typeAst.* != .constructor) return TypeError.ExpectedConstructor;

                    if (exhausted_identifiers.get(typeAst.constructor.name)) |_| {
                        return TypeError.DuplicatedConstructor;
                    }
                    const parsed_type = try self.parseTypeAst(typeAst.*, block_scope);

                    if (parsed_type.* == .variant) {
                        parsed_type.variant.parent_union = ident_type;
                    }

                    exhausted_identifiers.put(parsed_type.variant.name, {}) catch return TypeError.OutOfMemory;

                    types.append(
                        self.allocator,
                        parsed_type,
                    ) catch return TypeError.OutOfMemory;

                    try block_scope.addType(parsed_type.variant.name, parsed_type);
                }

                explicit_type = try self.freshType(.{ .union_of = types.items });
            }
            ident_type.alias.underlying = explicit_type.?;

            return try self._inferType(type_declaration.block, block_scope);
        },
        .lambda => |lambda| {
            const closure_environment = try self.freshScope(scope);
            const argument_type = try self.freshWildcard();
            try closure_environment.addValue(lambda.identifier, argument_type);

            if (expression.*.lambda.explicit_argument_type) |explicitTypeAst| {
                const explicit_type = try self.parseTypeAst(explicitTypeAst.*, scope);
                try self.unifyTypes(explicit_type, argument_type);
            }

            const body_type = try self._inferType(lambda.block, closure_environment);

            const lambda_type = try self.freshType(.{ .lambda = .{
                .argument = argument_type,
                .returns = body_type,
            } });

            expression.*.lambda.inferred_type = lambda_type;

            return lambda_type;
        },
        .match => |match| {
            const scrutinee_type = try self._inferType(match.scrutinee, scope);

            if (match.explicit_scrutinee_type) |explicit_scrutinee_type| {
                const parsed_scrutinee_type = try self.parseTypeAst(explicit_scrutinee_type.*, scope);
                try self.unifyTypes(scrutinee_type, parsed_scrutinee_type);
            }

            var case_types = std.ArrayList(*Type).initCapacity(self.allocator, match.cases.len) catch return TypeError.OutOfMemory;
            var has_wildcard = false;

            var seen_constructors = std.StringHashMap(void).init(self.allocator);
            defer seen_constructors.deinit();

            for (match.cases) |case| {
                const fresh_scope = try self.freshScope(scope);

                var seen_variables = std.StringHashMap(void).init(self.allocator);
                defer seen_variables.deinit();
                const pattern_tp = try self.inferPattern(fresh_scope, case.pattern.*, &seen_variables);

                self.unifyTypes(scrutinee_type, pattern_tp) catch {
                    return TypeError.UnmatchedPattern;
                };

                switch (case.pattern.*) {
                    .constructor => |c| {
                        seen_constructors.put(c.name, {}) catch return TypeError.OutOfMemory;
                    },
                    .wildcard, .identifier => {
                        has_wildcard = true;
                    },
                    else => {},
                }

                case_types.append(self.allocator, try self._inferType(case.block, fresh_scope)) catch return TypeError.OutOfMemory;
            }

            if (case_types.items.len == 0) return TypeError.MissingMatchCase;

            var resolved_scrutinee = self.applySubstitutions(scrutinee_type);
            if (resolved_scrutinee.* == .alias) {
                resolved_scrutinee = self.applySubstitutions(resolved_scrutinee.alias.underlying);
            }

            if (resolved_scrutinee.* == .union_of and !has_wildcard) {
                for (resolved_scrutinee.union_of) |variant| {
                    if (!seen_constructors.contains(variant.variant.name)) {
                        // std.debug.print("Missing match case for: {s}\n", .{variant.Variant.name});
                        return TypeError.MissingMatchCase;
                    }
                }
            }

            const first_tp = case_types.items[0];
            if (case_types.items.len > 1) {
                for (case_types.items[1..], 1..) |caseTp, i| {
                    self.unifyTypes(first_tp, caseTp) catch {
                        self.error_context = TypeErrorContext{
                            .unexpected_type = .{
                                .expected_type = self.allocator.dupe(*Type, &[_]*Type{first_tp}) catch return TypeError.OutOfMemory,
                                .found_type = caseTp,
                                .context = match.cases[i].block,
                            },
                        };
                        return TypeError.UnexpectedType;
                    };
                }
            }

            return first_tp;
        },
        .member_access => |member_access| {
            const object_type = self.applySubstitutions(try self._inferType(member_access.object, scope));

            if (object_type.* != .scope) return TypeError.MemberAccessOnNonEnvrionment;

            const member_type = object_type.scope.getValue(member_access.member);

            if (member_type) |memberTp| {
                var cache = std.AutoHashMap(usize, *Type).init(self.allocator);
                defer cache.deinit();
                return try self.freshenType(memberTp, &cache);
            }

            return TypeError.PropertyNotFoundOnObject;
        },
        .module => |module| {
            const module_scope = try self.freshScope(scope);

            const tp = try self._inferType(module.block, module_scope);

            if (tp.* != .scope) return TypeError.ExpectedEnvironmentTypeOnModuleEnd;

            if (scope.getValue(module.identifier)) |_| {
                return TypeError.ShadowingByModuleNotAllowed;
            }

            try scope.addValue(module.identifier, try self.freshType(.{ .scope = tp.scope }));

            return try self._inferType(module.rest, scope);
        },
        .current_environment => {
            return try self.freshType(.{ .scope = scope });
        },
        .use_environment => |env| {
            const type_scope = try self._inferType(env.environment, scope);
            if (type_scope.* != .scope) return TypeError.ExpectedEnvironmentOnEnvExpansion;

            var temp_scope = try self.freshScope(scope);
            var cache = std.AutoHashMap(usize, *Type).init(self.allocator);
            defer cache.deinit();

            var values = std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0) catch return TypeError.OutOfMemory;
            var types = std.ArrayList(std.StringHashMap(*Type).Entry).initCapacity(self.allocator, 0) catch return TypeError.OutOfMemory;

            var current_scope: ?*Scope = type_scope.scope;
            while (current_scope) |curr| {
                var values_iterator = curr.values.iterator();

                while (values_iterator.next()) |entry| {
                    values.insert(self.allocator, 0, entry) catch return TypeError.OutOfMemory;
                }

                var types_iterator = curr.types.iterator();

                while (types_iterator.next()) |entry| {
                    types.insert(self.allocator, 0, entry) catch return TypeError.OutOfMemory;
                }
                current_scope = curr.parent;
            }

            for (values.items) |entry| {
                const fresh_val = try self.freshenType(entry.value_ptr.*, &cache);
                try temp_scope.addValue(entry.key_ptr.*, fresh_val);
            }

            for (types.items) |entry| {
                const fresh_tp = try self.freshenType(entry.value_ptr.*, &cache);
                try temp_scope.addType(entry.key_ptr.*, fresh_tp);
            }

            return try self._inferType(env.block, temp_scope);
        },
        .type_ascription => |type_ascription| {
            const inferred_type = try self._inferType(type_ascription.expression, scope);

            const parsed_type = try self.parseTypeAst(type_ascription.explicit_type.*, scope);

            try self.unifyTypes(inferred_type, parsed_type);

            return parsed_type;
        },
    }
}

fn parseTypeAst(self: *TypeChecker, type_ast: TypeAst, scope: *Scope) TypeError!*Type {
    return switch (type_ast) {
        .wildcard => try self.freshWildcard(),
        .identifier => |identifier| {
            if (scope.getType(identifier)) |ident| return ident;
            if (identifier[0] == '\'') {
                const new_wildcard = try self.freshWildcard();

                try scope.addType(identifier, new_wildcard);

                return new_wildcard;
            }
            return TypeError.UnboundType;
        },
        .tuple => |tuple| {
            var elements = std.ArrayList(*Type).initCapacity(self.allocator, 1) catch return TypeError.OutOfMemory;

            for (tuple) |it| {
                elements.append(self.allocator, try self.parseTypeAst(it.*, scope)) catch return TypeError.OutOfMemory;
            }

            return try self.freshType(.{ .tuple = elements.items });
        },
        .function => |function| {
            return self.freshType(.{ .lambda = .{
                .argument = try self.parseTypeAst(function.argument.*, scope),
                .returns = try self.parseTypeAst(function.returns.*, scope),
            } });
        },
        .constructor => |constructor| {
            return self.freshType(.{ .variant = .{
                .name = constructor.name,
                .payload = if (constructor.payload) |payload| try self.parseTypeAst(payload.*, scope) else null,
                .parent_union = null,
            } });
        },
    };
}

fn inferPattern(self: *TypeChecker, scope: *Scope, pattern: MatchPattern, seen_variables: *std.StringHashMap(void)) TypeError!*Type {
    return switch (pattern) {
        .wildcard => self.freshWildcard(),
        .identifier => |identifier| {
            if (seen_variables.get(identifier)) |_| return TypeError.PatternOverusedVariable;
            const fresh_type = try self.freshWildcard();
            try scope.addValue(identifier, fresh_type);
            try seen_variables.put(identifier, {});
            return fresh_type;
        },
        .tuple => |tuple| {
            var types = std.ArrayList(*Type).initCapacity(self.allocator, tuple.binds.len) catch return TypeError.OutOfMemory;
            for (tuple.binds) |pat| {
                types.append(self.allocator, try self.inferPattern(scope, pat.*, seen_variables)) catch return TypeError.OutOfMemory;
            }
            return try self.freshType(.{ .tuple = types.items });
        },
        .constructor => |constructor| {
            const type_def = scope.getType(constructor.name) orelse return TypeError.UnboundConstructor;
            if (type_def.* != .variant) return TypeError.ExpectedConstructor;

            if (type_def.variant.payload) |expected_payload| {
                if (constructor.payload) |actual_payload_ast| {
                    const actual_payload_type = try self.inferPattern(scope, actual_payload_ast.*, seen_variables);
                    try self.unifyTypes(expected_payload, actual_payload_type);
                } else {
                    return TypeError.MissingConstructorPayload;
                }
            } else if (constructor.payload != null) {
                return TypeError.UnexpectedConstructorPayload;
            }

            return type_def.variant.parent_union orelse return TypeError.CannotUnify;
        },
        .cons => TypeError.Unimplemented,
    };
}

fn applySubstitutions(self: *TypeChecker, tp: *Type) *Type {
    if (tp.* == .wildcard)
        if (self.substitutions.get(tp.wildcard)) |resolvedType| {
            const nested_type = self.applySubstitutions(resolvedType);
            self.substitutions.put(tp.wildcard, nested_type) catch {};

            return nested_type;
        };
    return tp;
}

fn _occursInType(self: *TypeChecker, wildcard_id: usize, tp: *Type, visited: *std.AutoHashMap(*Type, void)) bool {
    const resolved = self.applySubstitutions(tp);

    if (visited.contains(resolved)) return false;
    visited.put(resolved, {}) catch {};

    switch (resolved.*) {
        .wildcard => |id| return id == wildcard_id,
        .lambda => |lambda| {
            return self._occursInType(wildcard_id, lambda.argument, visited) or
                self._occursInType(wildcard_id, lambda.returns, visited);
        },
        .tuple => |tuple| {
            for (tuple) |it| {
                if (self._occursInType(wildcard_id, it, visited)) return true;
            }
            return false;
        },
        .scope => |scope| {
            var it = scope.values.iterator();
            while (it.next()) |entry| {
                if (self._occursInType(wildcard_id, entry.value_ptr.*, visited)) return true;
            }
            return false;
        },
        .alias => |alias| {
            return self._occursInType(wildcard_id, alias.underlying, visited);
        },
        else => return false,
    }
}

fn occursInType(self: *TypeChecker, wildcard_id: usize, tp: *Type) bool {
    var visited = std.AutoHashMap(*Type, void).init(self.allocator);
    defer visited.deinit();

    return self._occursInType(wildcard_id, tp, &visited);
}

fn freshenScope(self: *TypeChecker, scope: *Scope, cache: *std.AutoHashMap(usize, *Type)) TypeError!*Scope {
    const fresh_parent = if (scope.parent) |p| (if (p.parent == null) p else try self.freshenScope(p, cache)) else null;
    const fresh_scope = try Scope.init(self.allocator, fresh_parent);
    var it_values = scope.values.iterator();
    while (it_values.next()) |entry| {
        const fresh_val = try self.freshenType(entry.value_ptr.*, cache);
        try fresh_scope.addValue(entry.key_ptr.*, fresh_val);
    }

    var it_types = scope.types.iterator();
    while (it_types.next()) |entry| {
        const fresh_type = try self.freshenType(entry.value_ptr.*, cache);
        try fresh_scope.addType(entry.key_ptr.*, fresh_type);
    }

    return fresh_scope;
}

fn freshenType(self: *TypeChecker, tp: *Type, cache: *std.AutoHashMap(usize, *Type)) TypeError!*Type {
    const resolved = self.applySubstitutions(tp);
    switch (resolved.*) {
        .wildcard => |id| {
            if (cache.get(id)) |fresh| {
                return fresh;
            }
            const fresh_wildcard = try self.freshWildcard();
            cache.put(id, fresh_wildcard) catch return TypeError.OutOfMemory;
            return fresh_wildcard;
        },
        .lambda => |lambda| {
            const fresh_argument = try self.freshenType(lambda.argument, cache);
            const fresh_returns = try self.freshenType(lambda.returns, cache);
            return try self.freshType(.{ .lambda = .{ .argument = fresh_argument, .returns = fresh_returns } });
        },
        .tuple => |tuple| {
            const fresh_types = self.allocator.alloc(*Type, tuple.len) catch return TypeError.OutOfMemory;
            for (tuple, 0..) |t, i| {
                fresh_types[i] = try self.freshenType(t, cache);
            }
            return try self.freshType(.{ .tuple = fresh_types });
        },
        .scope => |scope| {
            const fresh_scope = try self.freshenScope(scope, cache);
            return try self.freshType(.{ .scope = fresh_scope });
        },
        .alias => {
            return resolved;
        },
        .variant => |variant| {
            return try self.freshType(.{ .variant = .{
                .name = variant.name,
                .payload = if (variant.payload) |payload| try self.freshenType(payload, cache) else null,
                .parent_union = variant.parent_union,
            } });
        },
        .union_of => |un| {
            const fresh_types = self.allocator.alloc(*Type, un.len) catch return TypeError.OutOfMemory;
            for (un, 0..) |t, i| {
                fresh_types[i] = try self.freshenType(t, cache);
            }
            return try self.freshType(.{ .union_of = fresh_types });
        },
        else => return resolved,
    }
}

pub fn unifyTypes(self: *TypeChecker, raw_left: *Type, raw_right: *Type) TypeError!void {
    const left = self.applySubstitutions(raw_left);
    const right = self.applySubstitutions(raw_right);

    if (left == right or (left.* == .wildcard and right.* == .wildcard and left.wildcard == right.wildcard)) {
        return;
    }

    if (left.* == .wildcard) {
        if (self.occursInType(left.wildcard, right)) {
            return TypeError.CannotUnify;
        }
        self.substitutions.put(left.wildcard, right) catch return TypeError.OutOfMemory;
        return;
    }
    if (right.* == .wildcard) {
        if (self.occursInType(right.wildcard, left)) {
            return TypeError.CannotUnify;
        }
        self.substitutions.put(right.wildcard, left) catch return TypeError.OutOfMemory;
        return;
    }

    if (left.* == .alias and right.* == .alias and std.mem.eql(u8, left.alias.name, right.alias.name)) {
        return;
    }

    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) {
        return TypeError.CannotUnify;
    }

    switch (left.*) {
        .lambda => {
            try self.unifyTypes(left.lambda.argument, right.lambda.argument);
            try self.unifyTypes(left.lambda.returns, right.lambda.returns);
        },
        .tuple => |left_types| {
            const right_types = right.tuple;
            if (left_types.len != right_types.len) {
                return TypeError.CannotUnify;
            }
            for (left_types, right_types) |l, r| {
                try self.unifyTypes(l, r);
            }
        },
        else => {},
    }
}
