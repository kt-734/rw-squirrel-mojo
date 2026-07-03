const std = @import("std");
const parser = @import("parser.zig");

/// One directed edge in the cross-struct relation graph: `from` has a
/// relation field (`@@field: @@To`) pointing at `to`. Both strings are
/// borrowed from the source that was passed to `transformSquirrel`, so they
/// remain valid as long as the source does. `main.zig` collects these across
/// all files to run a DFS cycle check before writing `squirrel.zig`.
pub const RelationEdge = struct { from: []const u8, to: []const u8 };

pub const Conversion = struct {
    /// Caller owns this; free with `allocator.free`.
    code: []u8,
    /// Names of every `@@struct` declared in this file, in source order
    /// (e.g. `["Person"]`). Caller owns this slice — the strings themselves
    /// are borrowed from `source`, not copied, so `source` must outlive it.
    /// `main.zig` uses this to generate a `squirrel.zig` aggregator that
    /// calls every table's `sqrrl___init`/`sqrrl___deinit` from one place,
    /// instead of every `.rel` file having to call each table it uses
    /// individually.
    struct_names: [][]const u8,
    /// One edge per relation field (`@@field: @@Target`) across every struct
    /// declared in this file. Strings are borrowed from `source`. Caller owns
    /// the slice itself; free with `allocator.free`.
    relation_edges: []RelationEdge,
};

/// Rewrites every `@@`-marked construct in `source`, leaving everything
/// else byte-for-byte untouched:
///   - `@@struct Name { field: Type, ... }` becomes a generated Zig "table"
///     type (see `emitTable`).
///   - `@@entity.field` (a read) or `@@entity.field = expr;` (a write)
///     becomes a call against that table's generated accessors (see
///     `emitFieldAccess`) — Squirrel-style bare field access, rewritten to
///     real Zig. A write's `try` requires the enclosing function to return
///     an error union; that's on the `.rel` author, not something this
///     rewriter can paper over. Can be chained through relation fields —
///     `@@alice.@@employee.age` — see `parser.FieldAccess.relations`.
///   - `@@TypeName { .field = expr, ... }` becomes `try sqrrl__TypeName.sqrrl___create(.{ ... })`
///     (see `emitConstruct`) — same `try`-requires-an-error-union caveat.
///   - `@@entity.destroy()` becomes `sqrrl__entity.decref()` (see
///     `emitDestroy`) — the one entity-level operation that isn't a field
///     get/set, so it needs its own marker rather than reusing field access.
///   - A bare `@@name` — whether it's being declared/bound (`var @@alice = ...`)
///     or just referenced as a value (inside an import chain:
///     `@import("person.zig").@@Person`) — becomes `sqrrl__name` (see
///     `emitNameRef`). Both cases rewrite identically, so they're one marker.
///
/// Every `@@`-marked identifier — type name, entity variable, doesn't matter
/// which — becomes `sqrrl__name`, full stop, with no per-marker-type
/// exceptions. That's deliberate: it means the *local Zig name* a `.rel`
/// entity or type alias actually gets is always `sqrrl__`-prefixed too, so
/// it can never collide with anything else in the surrounding (potentially
/// hand-written) Zig code — the same collision-avoidance reasoning already
/// applied to every generated table/method name, just extended to cover the
/// `.rel` author's own chosen identifiers as well. The one consequence: an
/// unqualified construct's type name (`@@Person { ... }`) now has to
/// resolve via a matching `@@name = @@TypeName` import-alias declaration
/// elsewhere in the file (so `sqrrl__Person` actually exists in scope) —
/// arbitrary custom aliasing (`@@SomeOtherName { ... }` without a `sqrrl__`
/// counterpart) isn't supported.
///
/// `import_depth` is how many directories deep this source file sits below
/// the conversion root, so a generated `@import` of `squirrel_runtime.zig`
/// (always written at the root by `copyRuntime`) resolves correctly.
///
/// The `std`/`squirrel_runtime` imports are only prepended when a `@@struct`
/// was actually converted, since field-access rewrites don't reference
/// either — a file with field-access sugar but no `@@struct` is expected to
/// already have its own `const std = @import("std");`, same as hand-written
/// Zig. (A single file with *both* `@@struct` and its own hand-written `std`
/// import would still collide; not handled, since the project's structure so
/// far keeps schema files and usage files separate.)
pub fn transformSquirrel(allocator: std.mem.Allocator, source: []const u8, import_depth: usize) !Conversion {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var struct_names: std.ArrayList([]const u8) = .empty;
    errdefer struct_names.deinit(allocator);
    var edges: std.ArrayList(RelationEdge) = .empty;
    errdefer edges.deinit(allocator);

    // For auto-defer detection: track the most recent name_ref that looks like
    // a var/const declaration, so the construct arm can emit the RC incref+defer.
    var last_decl: ?struct { var_name: []const u8, type_name: ?[]const u8 } = null;
    // Set when we're inside a struct/union literal assigned to a `@@`-variable
    // (either a new declaration or a reassignment).  Suppresses per-field
    // auto-incref on `@@name` refs — instead, `sqrrl___increfAll`/`sqrrl___decrefAll`
    // are emitted at the closing `}`, handling arbitrary nesting generically.
    var in_refwalk_literal: bool = false;
    // When set (reassignment case), holds the variable name that needs increfAll
    // after the literal closes.  For declarations, last_decl.var_name is used.
    var reassign_var: ?[]const u8 = null;

    // Names of `@@`-declared union types (e.g. `const @@Animal = union(enum){...}`).
    // `@@Animal{...}` constructs for these types emit a plain union literal instead
    // of a `sqrrl___create` call; RC is managed via sqrrl___increfAll/decrefAll.
    var union_type_names = std.StringHashMap(void).init(allocator);
    defer union_type_names.deinit();

    var had_struct = false;
    var had_refwalk = false; // set when sqrrl___increfAll/decrefAll calls are emitted
    var i: usize = 0;
    while (parser.findNextMarker(source, i)) |marker| {
        // Before processing the next marker, check if a pending struct/union
        // literal needs increfAll/decrefAll injection at the closing `}`.
        if (in_refwalk_literal) {
            const marker_start: usize = switch (marker) { inline else => |p| p };
            const text = source[i..marker_start];
            const maybe_open = std.mem.indexOf(u8, text, "{");
            if (std.mem.indexOf(u8, text, "}")) |close_idx| {
                if (maybe_open == null or close_idx < maybe_open.?) {
                    const close_in_source = i + close_idx;
                    const after_close = parser.skipTrivia(source, close_in_source + 1);
                    const has_semi = after_close < source.len and source[after_close] == ';';
                    const consume_to = if (has_semi) after_close + 1 else close_in_source + 1;
                    try out.appendSlice(allocator, source[i..consume_to]);
                    const var_name = reassign_var orelse last_decl.?.var_name;
                    const is_decl = reassign_var == null;
                    had_refwalk = true;
                    try print(allocator, &out, "\nsquirrel_runtime.sqrrl___increfAll(sqrrl__{s});\n", .{var_name});
                    if (is_decl) try print(allocator, &out, "defer squirrel_runtime.sqrrl___decrefAll(sqrrl__{s});\n", .{var_name});
                    i = consume_to;
                    last_decl = null;
                    in_refwalk_literal = false;
                    reassign_var = null;
                }
            }
        }
        switch (marker) {
            .struct_decl => |start| {
                try out.appendSlice(allocator, source[i..start]);
                had_struct = true;

                const parsed = try parser.parseStruct(allocator, source, start);
                defer allocator.free(parsed.fields);
                try emitTable(allocator, &out, parsed.name, parsed.fields);
                try struct_names.append(allocator, parsed.name);

                for (parsed.fields) |f| {
                    // Scan the whole type_str for any `@@Identifier` references,
                    // not just a leading `@@` — so a field like
                    // `astr: struct { a: @@A }` also produces an edge to `A`.
                    var pos: usize = 0;
                    while (std.mem.indexOfPos(u8, f.type_str, pos, "@@")) |at| {
                        pos = at + 2;
                        const id_start = pos;
                        while (pos < f.type_str.len and
                            (std.ascii.isAlphanumeric(f.type_str[pos]) or f.type_str[pos] == '_')) : (pos += 1) {}
                        if (pos > id_start)
                            try edges.append(allocator, .{ .from = parsed.name, .to = f.type_str[id_start..pos] });
                    }
                }

                i = parsed.end;
            },
            .field_access => |start| {
                try out.appendSlice(allocator, source[i..start]);

                const access = try parser.parseFieldAccess(allocator, source, start);
                defer allocator.free(access.relations);
                try emitFieldAccess(allocator, &out, access);

                i = access.end;
            },
            .construct => |start| {
                try out.appendSlice(allocator, source[i..start]);

                const construct = try parser.parseConstruct(source, start);

                if (union_type_names.contains(construct.type_name)) {
                    // `@@Animal{...}` where Animal is a `@@`-declared union type:
                    // emit a plain union literal (no sqrrl___create), then let
                    // sqrrl___increfAll/decrefAll manage RC at the statement level.
                    if (construct.qualifier) |qualifier| try out.appendSlice(allocator, qualifier);
                    try print(allocator, &out, "sqrrl__{s}{{ ", .{construct.type_name});
                    try emitConstructBody(allocator, &out, construct.body);
                    try out.appendSlice(allocator, " }");

                    const after_ws = parser.skipTrivia(source, construct.end);
                    const has_semi = after_ws < source.len and source[after_ws] == ';';
                    // Determine if we need a scope reference (declaration or reassignment).
                    const rc_var = if (last_decl) |d| d.var_name else reassign_var;
                    const is_decl_rc = last_decl != null;
                    if (rc_var) |var_name| {
                        if (has_semi) i = after_ws + 1 else i = construct.end;
                        had_refwalk = true;
                        try print(allocator, &out, ";\nsquirrel_runtime.sqrrl___increfAll(sqrrl__{s});\n", .{var_name});
                        if (is_decl_rc) try print(allocator, &out, "defer squirrel_runtime.sqrrl___decrefAll(sqrrl__{s});\n", .{var_name});
                        last_decl = null;
                        in_refwalk_literal = false;
                        reassign_var = null;
                    } else {
                        i = construct.end;
                    }
                } else {
                    try emitConstruct(allocator, &out, construct);

                    // If the construct is the RHS of a `var/const @@name = @@Type{...}`
                    // declaration, emit RC incref + auto-defer destroy immediately after.
                    if (last_decl) |decl| {
                        const after_ws = parser.skipTrivia(source, construct.end);
                        const has_semi = after_ws < source.len and source[after_ws] == ';';
                        if (has_semi) i = after_ws + 1 else i = construct.end;
                        try print(allocator, &out, ";\ndefer sqrrl__{s}.decref();\n", .{decl.var_name});
                        last_decl = null;
                    } else {
                        i = construct.end;
                    }
                }
            },
            .destroy => |start| {
                try out.appendSlice(allocator, source[i..start]);

                const destroy = try parser.parseDestroy(allocator, source, start);
                defer allocator.free(destroy.relations);
                try emitDestroy(allocator, &out, destroy);

                i = destroy.end;
                if (destroy.relations.len > 0) {
                    // Chained destroys emit a block (see emitDestroy), which is
                    // already a complete statement — swallow the source's own
                    // trailing ';' so it isn't carried through as a stray
                    // empty statement after the block.
                    const after_ws = parser.skipTrivia(source, i);
                    if (after_ws < source.len and source[after_ws] == ';') i = after_ws + 1;
                }
            },
            .name_ref => |start| {
                try out.appendSlice(allocator, source[i..start]);

                const ref = try parser.parseNameRef(source, start);

                // Compute last-non-whitespace char before `@@` for type-position detection.
                var tp = start;
                while (tp > 0 and std.ascii.isWhitespace(source[tp - 1])) tp -= 1;
                const preceding_trimmed = std.mem.trimEnd(u8, source[i..start], " \t\r\n");
                const preceding = std.mem.trimEnd(u8, source[i..start], " \t\r\n");
                const is_new_decl = std.mem.endsWith(u8, preceding, "var") or std.mem.endsWith(u8, preceding, "const");
                const has_stmt_end = std.mem.indexOf(u8, source[i..start], ";") != null;

                // Reset context at statement/declaration boundaries FIRST, so the
                // reassignment detection below doesn't see a stale in_refwalk_literal.
                if (is_new_decl or has_stmt_end) {
                    last_decl = null;
                    in_refwalk_literal = false;
                    reassign_var = null;
                }
                if (is_new_decl) {
                    last_decl = .{ .var_name = ref.name, .type_name = null };
                    // Detect `const @@Animal = union(...) { ... }` — register as a
                    // union type so `@@Animal{...}` constructs emit a plain union
                    // literal rather than a `sqrrl___create` call.
                    const after_name = parser.skipTrivia(source, ref.end);
                    if (after_name < source.len and source[after_name] == '=') {
                        const after_eq = parser.skipTrivia(source, after_name + 1);
                        if (std.mem.startsWith(u8, source[after_eq..], "union("))
                            try union_type_names.put(ref.name, {});
                    }
                }

                // Detect reassignment BEFORE emitting the name (reset has already run
                // above, so reassign_var won't be spuriously cleared).  Guard: not a
                // new declaration, not already in a refwalk context, lowercase entity
                // variable name, and not a struct-literal field name (preceded by `.`).
                // `.@@field` guard: only apply the dot-exclusion when the `.` is on
                // the SAME LINE as `@@` (no newline between them), i.e. it's a real
                // struct-literal field separator, not a `.` at the end of a comment.
                const is_adjacent_dot = blk: {
                    if (tp == 0 or source[tp - 1] != '.') break :blk false;
                    for (source[tp..start]) |c| if (c == '\n') break :blk false;
                    break :blk true;
                };
                if (!is_new_decl and !in_refwalk_literal and
                    ref.name.len > 0 and std.ascii.isLower(ref.name[0]) and
                    !is_adjacent_dot)
                {
                    const after_ref = parser.skipTrivia(source, ref.end);
                    if (after_ref < source.len and source[after_ref] == '=' and
                        (after_ref + 1 >= source.len or source[after_ref + 1] != '='))
                    {
                        had_refwalk = true;
                        try print(allocator, &out, "squirrel_runtime.sqrrl___decrefAll(sqrrl__{s});\n", .{ref.name});
                        reassign_var = ref.name;
                        in_refwalk_literal = true;
                    }
                }

                // Emit the name with context-appropriate suffix.
                if (tp > 0 and source[tp - 1] == ':') {
                    try emitName(allocator, &out, ref.name);
                    try out.appendSlice(allocator, ".sqrrl___Entity");
                } else if (ref.name.len > 0 and std.ascii.isLower(ref.name[0]) and
                    std.mem.endsWith(u8, preceding_trimmed, "=") and
                    !std.mem.endsWith(u8, preceding_trimmed, "==") and
                    !std.mem.endsWith(u8, preceding_trimmed, "!="))
                {
                    try emitName(allocator, &out, ref.name);
                    if (!in_refwalk_literal) try out.appendSlice(allocator, ".incref()");
                    if (last_decl != null) in_refwalk_literal = true;
                } else {
                    try emitName(allocator, &out, ref.name);
                }

                i = ref.end;
            },
        }
    }
    if (in_refwalk_literal) {
        const remaining = source[i..];
        const maybe_open = std.mem.indexOf(u8, remaining, "{");
        if (std.mem.indexOf(u8, remaining, "}")) |close_idx| {
            if (maybe_open == null or close_idx < maybe_open.?) {
                const close_in_source = i + close_idx;
                const after_close = parser.skipTrivia(source, close_in_source + 1);
                const has_semi = after_close < source.len and source[after_close] == ';';
                const consume_to = if (has_semi) after_close + 1 else close_in_source + 1;
                try out.appendSlice(allocator, source[i..consume_to]);
                const var_name = reassign_var orelse last_decl.?.var_name;
                const is_decl = reassign_var == null;
                had_refwalk = true;
                try print(allocator, &out, "\nsquirrel_runtime.sqrrl___increfAll(sqrrl__{s});\n", .{var_name});
                if (is_decl) try print(allocator, &out, "defer squirrel_runtime.sqrrl___decrefAll(sqrrl__{s});\n", .{var_name});
                try out.appendSlice(allocator, source[consume_to..]);
                last_decl = null;
                in_refwalk_literal = false;
                reassign_var = null;
            } else {
                try out.appendSlice(allocator, source[i..]);
            }
        } else {
            try out.appendSlice(allocator, source[i..]);
        }
    } else {
        try out.appendSlice(allocator, source[i..]);
    }

    const names = try struct_names.toOwnedSlice(allocator);
    errdefer allocator.free(names);
    const edge_slice = try edges.toOwnedSlice(allocator);
    errdefer allocator.free(edge_slice);

    if (!had_struct and !had_refwalk) return .{ .code = try out.toOwnedSlice(allocator), .struct_names = names, .relation_edges = edge_slice };

    var final: std.ArrayList(u8) = .empty;
    errdefer final.deinit(allocator);
    if (had_struct) {
        // Schema files with @@struct declarations need both std and squirrel_runtime.
        try final.appendSlice(allocator, "const std = @import(\"std\");\nconst squirrel_runtime = @import(\"");
        for (0..import_depth) |_| try final.appendSlice(allocator, "../");
        try final.appendSlice(allocator, "squirrel_runtime.zig\");\n\n");
    } else {
        // Usage files bring their own `const std`; only add squirrel_runtime.
        try final.appendSlice(allocator, "const squirrel_runtime = @import(\"");
        for (0..import_depth) |_| try final.appendSlice(allocator, "../");
        try final.appendSlice(allocator, "squirrel_runtime.zig\");\n");
    }
    try final.appendSlice(allocator, out.items);
    out.deinit(allocator);
    return .{ .code = try final.toOwnedSlice(allocator), .struct_names = names, .relation_edges = edge_slice };
}

/// The single transformation underlying every `@@`-marked identifier:
/// `sqrrl__` + the name. This is the *only* place that prefix gets written —
/// `emitFieldAccess`/`emitDestroy`/`emitConstruct` each call this for their
/// entity/type portion and then append their own method-call syntax, rather
/// than each formatting `"sqrrl__{s}"` themselves.
fn emitName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    try print(allocator, out, "sqrrl__{s}", .{name});
}

/// Emits the Zig call a `@@entity.field` use-site access rewrites to: a read
/// becomes `sqrrl__entity.sqrrl___field()` (auto-unwrapped — a field that
/// was never `put` panics here rather than surfacing as a typed null, traded
/// deliberately for ergonomics matching Squirrel's dynamic property access);
/// a write becomes `try sqrrl__entity.sqrrl___setField(value);`.
///
/// A *chained* read (one or more relation hops, `access.relations`, from
/// `@@alice.@@employee.age`) stays a single inline expression — each hop
/// gets the same `.sqrrl___hop()` treatment as the terminal read, so a
/// missing link panics at that hop rather than the chain quietly evaluating
/// to null — because every getter (including the terminal one) takes
/// `self` *by value*, and calling a by-value method on a temporary is fine
/// in Zig.
///
/// A *chained write* can't use that same flat expression, though: the
/// setter takes `self: *sqrrl___Entity` (see `emitTable`'s const-
/// correctness note), and Zig won't let you take a mutable pointer to the
/// temporary result of a chained call — only to an addressable local
/// variable. So a chained write instead emits a block that binds each hop
/// to its own `var` (see `emitRelayChain`) and calls the setter on the last
/// one. `@@alice.age = 31` (no hops) stays the simple inline form, since
/// `sqrrl__alice` is already an addressable variable.
fn emitFieldAccess(allocator: std.mem.Allocator, out: *std.ArrayList(u8), access: parser.FieldAccess) !void {
    if (access.write_value) |value| {
        if (access.relations.len == 0) {
            try print(allocator, out, "try ", .{});
            try emitName(allocator, out, access.entity);
            try print(allocator, out, ".sqrrl___set{c}{s}({s});", .{
                std.ascii.toUpper(access.field[0]), access.field[1..], value,
            });
        } else {
            try emitRelayChain(allocator, out, access.entity, access.relations);
            try print(allocator, out, "    try sqrrl___relay{d}.sqrrl___set{c}{s}({s});\n}}", .{
                access.relations.len - 1, std.ascii.toUpper(access.field[0]), access.field[1..], value,
            });
        }
    } else {
        try emitName(allocator, out, access.entity);
        for (access.relations) |hop| {
            try print(allocator, out, ".sqrrl___{s}()", .{hop});
        }
        try print(allocator, out, ".sqrrl___{s}()", .{access.field});
    }
}

/// Emits a block that walks `relations`, binding each hop's result to its
/// own `var sqrrl___relayN` (`sqrrl___relay0 = entity.hop1().?;`,
/// `sqrrl___relay1 = sqrrl___relay0.hop2().?;`, ...) — leaves the block
/// open (no closing `}`) for the caller to emit the terminal mutating call
/// against `sqrrl___relay{relations.len - 1}`. Shared by `emitFieldAccess`
/// (chained write) and `emitDestroy` (chained destroy); both need this
/// because their terminal call requires an addressable `*sqrrl___Entity`,
/// which a chain of temporaries doesn't provide directly — see
/// `emitFieldAccess`'s doc comment for the full reasoning. `relations` must
/// be non-empty.
fn emitRelayChain(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entity: []const u8, relations: []const []const u8) !void {
    try print(allocator, out, "{{\n    var sqrrl___relay0 = ", .{});
    try emitName(allocator, out, entity);
    try print(allocator, out, ".sqrrl___{s}();\n", .{relations[0]});
    for (relations[1..], 1..) |hop, idx| {
        try print(allocator, out, "    var sqrrl___relay{d} = sqrrl___relay{d}.sqrrl___{s}();\n", .{ idx, idx - 1, hop });
    }
}

/// Re-scans a construct body for `@@`-marked constructs and name refs, rewriting
/// them rather than passing the body through verbatim. Called by `emitConstruct`
/// and recursively for nested bodies.
///
/// Nested `@@Type{...}` constructs use `auto_incref = false` because the
/// containing `sqrrl___create` will call `sqrrl___incref` on each relation-field
/// argument after `put` — if the nested create also started at rc=1, the entity
/// would end up at rc=2 with only one holder, leaking permanently.
/// Bare `@@name` refs become `sqrrl__name`. Field accesses and other markers
/// that can appear as field values use the same emitters as the top level.
/// Non-`@@` text (field names, literals, commas) passes through unchanged.
fn emitConstructBody(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !void {
    var i: usize = 0;
    while (parser.findNextMarker(body, i)) |marker| {
        switch (marker) {
            .struct_decl => |start| {
                try out.appendSlice(allocator, body[i .. start + "@@struct".len]);
                i = start + "@@struct".len;
            },
            .construct => |start| {
                try out.appendSlice(allocator, body[i..start]);
                const nested = try parser.parseConstruct(body, start);
                try print(allocator, out, "try ", .{});
                if (nested.qualifier) |qualifier| try out.appendSlice(allocator, qualifier);
                try emitName(allocator, out, nested.type_name);
                try out.appendSlice(allocator, ".sqrrl___create(.{ ");
                try emitConstructBody(allocator, out, nested.body);
                try out.appendSlice(allocator, " })");
                i = nested.end;
            },
            .field_access => |start| {
                try out.appendSlice(allocator, body[i..start]);
                const access = try parser.parseFieldAccess(allocator, body, start);
                defer allocator.free(access.relations);
                try emitFieldAccess(allocator, out, access);
                i = access.end;
            },
            .destroy => |start| {
                try out.appendSlice(allocator, body[i..start]);
                const destroy = try parser.parseDestroy(allocator, body, start);
                defer allocator.free(destroy.relations);
                try emitDestroy(allocator, out, destroy);
                i = destroy.end;
            },
            .name_ref => |start| {
                try out.appendSlice(allocator, body[i..start]);
                const ref = try parser.parseNameRef(body, start);
                try emitName(allocator, out, ref.name);
                i = ref.end;
            },
        }
    }
    try out.appendSlice(allocator, body[i..]);
}

/// Emits `try sqrrl__TypeName.sqrrl___create(.{ ... }, true)`. The body is
/// re-scanned via `emitConstructBody` so nested `@@Type{...}` and `@@name` refs
/// are rewritten rather than passed through verbatim. `auto_incref = true`
/// because every top-level construct gives the caller one reference — the
/// auto-defer for `var/const @@name` declarations handles scope cleanup; other
/// use sites (struct members etc.) must decref manually.
fn emitConstruct(allocator: std.mem.Allocator, out: *std.ArrayList(u8), construct: parser.Construct) !void {
    // Wrap in parens so .incref() can be chained on the result of `try`.
    // Every top-level construct gives the caller one reference (rc 0→1); the
    // auto-defer for `var/const @@name` or manual decref elsewhere releases it.
    try out.appendSlice(allocator, "(try ");
    if (construct.qualifier) |qualifier| try out.appendSlice(allocator, qualifier);
    try emitName(allocator, out, construct.type_name);
    try out.appendSlice(allocator, ".sqrrl___create(.{ ");
    try emitConstructBody(allocator, out, construct.body);
    try out.appendSlice(allocator, " })).incref()");
}

/// Emits a field's type, used everywhere `emitTable` needs to write one out
/// (the getter return type, setter param type, `Rel(...)` storage/init
/// calls, and `sqrrl___create`'s args struct). If `type_str` is a bare
/// `@@Identifier` — a *relation* field, declared `@@employee: @@Employee` in
/// `@@struct` — expands it to `sqrrl__Employee.sqrrl___Entity`: the actual
/// per-row handle type that gets stored, not the table type itself
/// (`sqrrl__Employee` alone would mean "store the whole table as a field
/// value", which isn't what a relation means). Otherwise emits `type_str`
/// verbatim — a plain Zig type like `u32` or `[]const u8`.
fn emitFieldType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), type_str: []const u8) !void {
    if (std.mem.startsWith(u8, type_str, "@@")) {
        try print(allocator, out, "sqrrl__{s}.sqrrl___Entity", .{type_str["@@".len..]});
    } else {
        try out.appendSlice(allocator, type_str);
    }
}

/// True for `[]T` fields that should use `sqrrl___OwnedSliceRel` instead of
/// `sqrrl___Rel` — any slice type EXCEPT `[]const u8`, which stays as a plain
/// scalar value (string) backed by the existing `sqrrl___Rel` with
/// `StringContext` bwd hashing.
fn isOwnedSlice(type_str: []const u8) bool {
    return std.mem.startsWith(u8, type_str, "[]") and !std.mem.eql(u8, type_str, "[]const u8");
}

/// Extracts the element type from an owned-slice type string, stripping the
/// `[]` (and optional `const`) prefix: `[]u32` → `"u32"`, `[]const u32` →
/// `"u32"`. Only call when `isOwnedSlice` is true.
fn sliceElemType(type_str: []const u8) []const u8 {
    const rest = type_str["[]".len..];
    if (std.mem.startsWith(u8, rest, "const ")) return rest["const ".len..];
    return rest;
}

/// The type that appears in the getter return / setter param / sqrrl___create
/// args for a field — identical to `emitFieldType` for scalar/relation fields,
/// but for owned-slice fields substitutes `[]const Elem` (a read-only view
/// of the stored slice rather than the internal mutable copy).
fn emitFieldApiType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), type_str: []const u8) !void {
    if (isOwnedSlice(type_str)) {
        try print(allocator, out, "[]const {s}", .{sliceElemType(type_str)});
    } else {
        try emitFieldType(allocator, out, type_str);
    }
}

/// Emits the full `squirrel_runtime.sqrrl___Rel(...)` or
/// `sqrrl___OwnedSliceRel(...)` type for a field's Rel var declaration and
/// init call, choosing the right generic based on whether the field is an
/// owned slice.
fn emitRelDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), type_str: []const u8) !void {
    if (isOwnedSlice(type_str)) {
        try print(allocator, out, "squirrel_runtime.sqrrl___OwnedSliceRel(sqrrl___Entity, {s})", .{sliceElemType(type_str)});
    } else {
        try out.appendSlice(allocator, "squirrel_runtime.sqrrl___Rel(sqrrl___Entity, ");
        try emitFieldType(allocator, out, type_str);
        try out.appendSlice(allocator, ")");
    }
}

/// Emits the Zig call a `@@entity.decref()` use site rewrites to:
/// `sqrrl__entity.decref()` — no `try`, since `sqrrl___destroy`
/// returns plain `void`. A chained destroy needs the same relay-block
/// treatment as a chained write, and for the same reason — `sqrrl___destroy`
/// also requires `*sqrrl___Entity`. See `emitFieldAccess`'s doc comment and
/// `emitRelayChain`.
fn emitDestroy(allocator: std.mem.Allocator, out: *std.ArrayList(u8), destroy: parser.Destroy) !void {
    if (destroy.relations.len == 0) {
        try emitName(allocator, out, destroy.entity);
        try print(allocator, out, ".decref()", .{});
    } else {
        try emitRelayChain(allocator, out, destroy.entity, destroy.relations);
        try print(allocator, out, "    sqrrl___relay{d}.decref();\n}}", .{destroy.relations.len - 1});
    }
}

/// Emits a "table" type for `@@struct Name { ... }`. `sqrrl__Name` is a
/// **static/singleton** type: its storage is container-level `var`s, not
/// instance fields, so there's exactly one `Name` table per process — no
/// instance to create or thread through calls. Tradeoff accepted
/// deliberately: this fits a script-conversion tool where one global game/
/// script world per process is the norm, at the cost of test isolation and
/// the ability to ever have two independent tables.
///   - `sqrrl__Name.sqrrl___init(allocator)` / `sqrrl___deinit()` initialize
///     and tear down the static storage; calling any other method before
///     `sqrrl___init` reads `undefined` memory, same as any other Zig
///     static — there's no compile-time guard against it.
///   - `sqrrl__Name.sqrrl___create(.{ .field = x, ... })` allocates an id,
///     inserts into every field's rel, and rolls back on error.
///   - `sqrrl__Name.sqrrl___Entity` is just `{ sqrrl___id }` — a plain id
///     handle. Reading/writing a field is a method call (`entity.sqrrl___field()` /
///     `entity.sqrrl___setField(v)`) since Zig has no computed-property syntax
///     for `entity.field` to trigger a lookup; these reach back into the
///     static storage via `Self.field`, not a parameter, which is also why
///     they have to be qualified with `Self.` instead of bare `field` —
///     `Entity` defines its own method derived from the same name, which
///     would otherwise shadow the outer static var from within `Entity`'s
///     own scope.
///   - The getter takes `self: sqrrl___Entity` (by value — reading a field
///     shouldn't need a mutable binding), but the setter and `sqrrl___destroy`
///     take `self: *sqrrl___Entity`. Neither actually writes through that
///     pointer (the real mutation lands in the static `Rel`/`IdAllocator`
///     storage, not the entity handle itself), so by-value would still
///     compile — but it would also let `const alice = ...; alice.sqrrl___setAge(v)`
///     silently succeed, since Zig's `const` only protects the binding it's
///     attached to, not state reachable through it. Taking `*sqrrl___Entity`
///     forces the caller's binding to be `var`, so `const`-ness on an entity
///     handle means what a reader expects it to mean.
///   - `entity.decref()` removes the entity from every field rel and
///     frees its id. Named `destroy`, not `deinit`, deliberately: `deinit` in
///     Zig idiom means "free *this value's own* resources" (true of the
///     table — it owns `Rel`/`IdAllocator` instances — but `Entity` owns
///     nothing, it's just a `u32`). What actually happens is removing a row
///     from the table, which is what `sqrrl__Name.sqrrl___destroy` already
///     calls it — naming the entity-level wrapper the same way keeps both
///     forms consistent.
///   - A field can itself be a relation to another `@@struct`, declared
///     `@@employee: @@Employee` — `emitFieldType` expands that to
///     `sqrrl__Employee.sqrrl___Entity` everywhere the field's type is
///     written, so the field stores another table's row handle directly.
///     Reading it back gives `?sqrrl__Employee.sqrrl___Entity`, same as any
///     other field; chaining through it at a use site is
///     `@@alice.@@employee.age` (see `parser.FieldAccess.relations`).
///
/// Every identifier the generator itself needs — the id-allocator var, the
/// lifecycle methods, the nested entity type and its own field, *and* the
/// per-field accessor/setter methods — is prefixed with `sqrrl___`. Only the
/// per-field storage var and constructor arg names (`name:`, `args.name`)
/// are the user's bare field name, since matching it there is the whole
/// point. The accessors are *not* left as the bare field name (`entity.name`
/// rather than `entity.sqrrl___name()`) because that bare name needs to stay
/// free for `@@entity.field` use-site sugar (see `transformSquirrel`) to
/// rewrite to — it would otherwise collide with a real, directly-callable
/// Zig method of the same name.
fn emitTable(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, fields: []const parser.Field) !void {
    try print(allocator, out, "pub const sqrrl__{s} = struct {{\n    const Self = @This();\n\n", .{name});
    try print(allocator, out, "    pub const sqrrl___Entity = struct {{\n        sqrrl___id: u32,\n\n", .{});
    for (fields) |f| {
        try print(allocator, out, "        pub fn sqrrl___{s}(self: sqrrl___Entity) ", .{f.name});
        try emitFieldApiType(allocator, out, f.type_str);
        try print(allocator, out, " {{\n            return Self.{s}.getFwd(self) orelse @panic(\"sqrrl__{s}.{s}: field not set\");\n        }}\n", .{ f.name, name, f.name });
        if (std.mem.startsWith(u8, f.type_str, "@@")) {
            // Relation setter: incref new target first (infallible after ensureSlot),
            // then update the Rel, then decref the old target.  Ordering matters:
            //   1. incref new (infallible) so it can't be 0 if update succeeds
            //   2. errdefer decref new in case update fails
            //   3. capture old before update
            //   4. update the Rel (may fail)
            //   5. decref old only after a successful update
            const target = f.type_str["@@".len..];
            try print(allocator, out,
                \\
                \\        pub fn sqrrl___set{c}{s}(self: *sqrrl___Entity, value: sqrrl__{s}.sqrrl___Entity) !void {{
                \\            _ = value.incref();
                \\            errdefer value.decref();
                \\            const sqrrl___prev = Self.{s}.getFwd(self.*);
                \\            try Self.{s}.update(self.*, value);
                \\            if (sqrrl___prev) |p| p.decref();
                \\        }}
                \\
            , .{ std.ascii.toUpper(f.name[0]), f.name[1..], target, f.name, f.name });
        } else {
            try print(allocator, out,
                \\
                \\        pub fn sqrrl___set{c}{s}(self: *sqrrl___Entity, value:
            , .{ std.ascii.toUpper(f.name[0]), f.name[1..] });
            try out.appendSlice(allocator, " ");
            try emitFieldApiType(allocator, out, f.type_str);
            try print(allocator, out,
                \\) !void {{
                \\            try Self.{s}.update(self.*, value);
                \\        }}
                \\
            , .{f.name});
        }
    }
    // incref/decref logic lives directly on the entity — no table-level
    // sqrrl___incref/sqrrl___decref needed as intermediaries.
    try print(allocator, out, "        pub fn incref(self: sqrrl___Entity) sqrrl___Entity {{\n            Self.sqrrl___rc.incref(self.sqrrl___id);\n            return self;\n        }}\n", .{});
    try print(allocator, out, "        pub fn decref(self: sqrrl___Entity) void {{\n            if (Self.sqrrl___rc.decref(self.sqrrl___id) == 0)\n                Self.sqrrl___destroy_inner(self);\n        }}\n    }};\n\n", .{});

    for (fields) |f| {
        try print(allocator, out, "    var {s}: ", .{f.name});
        try emitRelDecl(allocator, out, f.type_str);
        try out.appendSlice(allocator, " = undefined;\n");
    }
    try print(allocator, out, "    var sqrrl___ids: squirrel_runtime.sqrrl___IdAllocator = undefined;\n", .{});
    try print(allocator, out, "    var sqrrl___rc: squirrel_runtime.sqrrl___RefCount = undefined;\n\n", .{});

    try print(allocator, out, "    pub fn sqrrl___init(allocator: std.mem.Allocator) void {{\n        sqrrl___ids = squirrel_runtime.sqrrl___IdAllocator.init(allocator);\n        sqrrl___rc = squirrel_runtime.sqrrl___RefCount.init(allocator);\n", .{});
    for (fields) |f| {
        try print(allocator, out, "        {s} = ", .{f.name});
        try emitRelDecl(allocator, out, f.type_str);
        try out.appendSlice(allocator, ".init(allocator);\n");
    }
    try print(allocator, out, "    }}\n\n", .{});

    try print(allocator, out, "    pub fn sqrrl___deinit() void {{\n        sqrrl___ids.deinit();\n        sqrrl___rc.deinit();\n", .{});
    for (fields) |f| {
        try print(allocator, out, "        {s}.deinit();\n", .{f.name});
    }
    try print(allocator, out, "    }}\n\n", .{});


    // Owned-slice and relation fields have no bwd index, so skip for* for those.
    for (fields) |f| {
        if (isOwnedSlice(f.type_str) or std.mem.startsWith(u8, f.type_str, "@@")) continue;
        try print(allocator, out, "    pub fn for{c}{s}(value: ", .{ std.ascii.toUpper(f.name[0]), f.name[1..] });
        try emitFieldType(allocator, out, f.type_str);
        try print(allocator, out, ") []const sqrrl___Entity {{\n        return {s}.getBwd(value);\n    }}\n\n", .{f.name});
    }

    try print(allocator, out, "    pub fn sqrrl___create(args: struct {{ ", .{});
    for (fields, 0..) |f, idx| {
        if (idx != 0) try print(allocator, out, ", ", .{});
        try print(allocator, out, "{s}: ", .{f.name});
        try emitFieldApiType(allocator, out, f.type_str);
    }
    try print(allocator, out,
        \\ }}) !sqrrl___Entity {{
        \\        const id = try sqrrl___ids.alloc();
        \\        const entity: sqrrl___Entity = .{{ .sqrrl___id = id }};
        \\        errdefer sqrrl___ids.free(id) catch unreachable;
        \\        try Self.sqrrl___rc.ensureSlot(id);
        \\
    , .{});
    for (fields) |f| {
        if (isOwnedSlice(f.type_str)) {
            try print(allocator, out, "        errdefer {s}.remove(entity);\n", .{f.name});
        } else if (std.mem.startsWith(u8, f.type_str, "@@")) {
            // errdefer: undo both the put AND the incref that follows it.
            try print(allocator, out, "        errdefer if ({s}.fetchRemoveFwd(entity)) |prev| prev.decref();\n", .{f.name});
        } else {
            try print(allocator, out, "        errdefer _ = {s}.fetchRemoveFwd(entity);\n", .{f.name});
        }
    }
    for (fields) |f| {
        try print(allocator, out, "        try {s}.put(entity, args.{s});\n", .{ f.name, f.name });
        if (std.mem.startsWith(u8, f.type_str, "@@")) {
            // Incref after successful put — infallible (ensureSlot ran at target's create).
            try print(allocator, out, "        _ = args.{s}.incref();\n", .{f.name});
        }
    }
    try print(allocator, out, "        return entity;\n    }}\n\n", .{});

    // sqrrl___destroy_inner: the real cleanup, called only when rc reaches 0.
    try print(allocator, out, "    fn sqrrl___destroy_inner(entity: sqrrl___Entity) void {{\n", .{});
    for (fields) |f| {
        if (isOwnedSlice(f.type_str)) {
            try print(allocator, out, "        {s}.remove(entity);\n", .{f.name});
        } else if (std.mem.startsWith(u8, f.type_str, "@@")) {
            // Decref relation target before removing from the Rel.
            try print(allocator, out, "        if ({s}.fetchRemoveFwd(entity)) |prev| prev.decref();\n", .{f.name});
        } else {
            try print(allocator, out, "        _ = {s}.fetchRemoveFwd(entity);\n", .{f.name});
        }
    }
    try print(allocator, out, "        sqrrl___ids.free(entity.sqrrl___id) catch unreachable;\n    }}\n", .{});

    try print(allocator, out, "}};\n", .{});
}

fn print(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

test "transformSquirrel passes plain Zig through untouched" {
    const source = "const std = @import(\"std\");\npub fn add(a: i32, b: i32) i32 { return a + b; }\n";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(source, result.code);
    try std.testing.expectEqual(@as(usize, 0), result.struct_names.len);
}

test "transformSquirrel emits a table for @@struct" {
    const source = "@@struct Person {\n    name: []const u8,\n    age: u32,\n    height: f32,\n}\n";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);

    try std.testing.expectEqual(@as(usize, 1), result.struct_names.len);
    try std.testing.expectEqualStrings("Person", result.struct_names[0]);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const squirrel_runtime = @import(\"squirrel_runtime.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub const sqrrl__Person = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var name: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, []const u8) = undefined;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var age: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, u32) = undefined;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const Self = @This();") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub fn sqrrl___setHeight(self: *sqrrl___Entity, value: f32) !void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "try Self.height.update(self.*, value);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub fn sqrrl___create(args: struct { name: []const u8, age: u32, height: f32 }) !sqrrl___Entity {") != null);
    // Bwd reverse-lookup methods on the table type.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub fn forName(value: []const u8) []const sqrrl___Entity {") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub fn forAge(value: u32) []const sqrrl___Entity {") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "return name.getBwd(value);") != null);
}

test "transformSquirrel rewrites @@Type.method( as name_ref leaving .method(args) as literal" {
    const source = "const alices = @@Person.forName(\"alice\");";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "const alices = sqrrl__Person.forName(\"alice\");",
        result.code,
    );
}

test "transformSquirrel handles a field named id, table, init, or deinit without colliding" {
    const source = "@@struct Foo { id: u32, table: []const u8, init: f32, deinit: u32 }";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var id: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, u32) = undefined;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var table: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, []const u8) = undefined;") != null);
}

test "transformSquirrel collects multiple struct names in source order" {
    const source = "@@struct Foo { x: u32 }\n@@struct Bar { y: u32 }\n";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqual(@as(usize, 2), result.struct_names.len);
    try std.testing.expectEqualStrings("Foo", result.struct_names[0]);
    try std.testing.expectEqualStrings("Bar", result.struct_names[1]);
}

test "transformSquirrel nests the squirrel_runtime import per directory depth" {
    const source = "@@struct Foo { x: u32 }";
    const result = try transformSquirrel(std.testing.allocator, source, 2);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "@import(\"../../squirrel_runtime.zig\")") != null);
}

test "transformSquirrel rejects malformed @@struct" {
    try std.testing.expectError(error.InvalidSquirrelSyntax, transformSquirrel(std.testing.allocator, "@@struct Foo not_braces", 0));
}

test "transformSquirrel rewrites a field read with auto-unwrap" {
    const source = "std.debug.print(\"{s}\", .{@@alice.name});";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings("std.debug.print(\"{s}\", .{sqrrl__alice.sqrrl___name()});", result.code);
}

test "transformSquirrel rewrites a field write with try" {
    const source = "@@alice.age = 31;";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings("try sqrrl__alice.sqrrl___setAge(31);", result.code);
}

test "transformSquirrel field-access-only source gets no std/squirrel_runtime prelude" {
    const source = "const std = @import(\"std\");\npub fn main() !void {\n    @@alice.age = 31;\n}\n";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    // Exactly one `const std = @import` — the file's own, not a duplicate we injected.
    try std.testing.expectEqual(@as(?usize, 0), std.mem.indexOf(u8, result.code, "const std = @import"));
    try std.testing.expect(std.mem.indexOf(u8, result.code, "try sqrrl__alice.sqrrl___setAge(31);") != null);
}

test "transformSquirrel rewrites a construction" {
    const source = "const alice = @@Person { .name = \"alice\", .age = 30 };";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "const alice = (try sqrrl__Person.sqrrl___create(.{ .name = \"alice\", .age = 30 })).incref();",
        result.code,
    );
}

test "transformSquirrel rewrites a destroy" {
    const source = "@@alice.decref();";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings("sqrrl__alice.decref();", result.code);
}

test "transformSquirrel rewrites a name_ref declaration and a bare reference identically" {
    const source = "const std = @import(\"std\");\nconst @@Person = @import(\"person.zig\").@@Person;\n";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nconst sqrrl__Person = @import(\"person.zig\").sqrrl__Person;\n",
        result.code,
    );
}

test "transformSquirrel rewrites a @@-marked declaration plus construct consistently" {
    const source = "var @@alice = @@Person { .name = \"alice\", .age = 30 };";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    // create chained with .incref(); auto-defer decrefs at scope exit.
    try std.testing.expectEqualStrings(
        "var sqrrl__alice = (try sqrrl__Person.sqrrl___create(.{ .name = \"alice\", .age = 30 })).incref();\ndefer sqrrl__alice.decref();\n",
        result.code,
    );
}

test "transformSquirrel rewrites a qualified construct (whole-module import)" {
    const source = "var alice = person.@@Person { .name = \"alice\", .age = 30 };";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "var alice = (try person.sqrrl__Person.sqrrl___create(.{ .name = \"alice\", .age = 30 })).incref();",
        result.code,
    );
}

test "transformSquirrel rewrites nested @@Type{...} inside a construct body with incref=false" {
    // Inner @@Employee{...} is nested in Person's body — uses incref=false because
    // Person's sqrrl___create will incref it via the relation-field put.
    const source = "var @@alice = @@Person { .name = \"alice\", .employee = @@Employee { .name = \"carol\", .age = 45 } };";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    // Outer Person: chained .incref() + auto-defer.
    // Inner Employee (nested in body): no incref chain — Person's create handles it.
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "sqrrl__Person.sqrrl___create(.{ .name = \"alice\", .employee = try sqrrl__Employee.sqrrl___create(.{ .name = \"carol\", .age = 45 }) }))",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__alice.decref()") != null);
    // No auto-defer for the inner employee — Person's create manages its lifetime.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__Employee") == null);
}

test "transformSquirrel rewrites @@name refs inside a construct body" {
    // @@carol inside the body is a name_ref (an existing entity variable), not a construct.
    const source = "var @@alice = @@Person { .name = \"alice\", .employee = @@carol };";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        ".employee = sqrrl__carol",
    ) != null);
}

test "transformSquirrel uses OwnedSliceRel and const-view API for slice fields" {
    const source = "@@struct Person { tags: []u32, name: []const u8 }";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    // Slice field uses OwnedSliceRel with element type.
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "var tags: squirrel_runtime.sqrrl___OwnedSliceRel(sqrrl___Entity, u32) = undefined;",
    ) != null);
    // String field stays as regular Rel.
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "var name: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, []const u8) = undefined;",
    ) != null);
    // Slice getter returns []const u32 (panics if not set).
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___tags(self: sqrrl___Entity) []const u32 {",
    ) != null);
    // Slice setter takes []const u32.
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___setTags(self: *sqrrl___Entity, value: []const u32) !void {",
    ) != null);
    // create args use []const u32 for slice fields.
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___create(args: struct { tags: []const u32, name: []const u8 }) !sqrrl___Entity {",
    ) != null);
    // Slice field uses .remove in destroy (not fetchRemoveFwd).
    try std.testing.expect(std.mem.indexOf(u8, result.code, "tags.remove(entity);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "_ = name.fetchRemoveFwd(entity);") != null);
    // No for* method generated for the slice field.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "forTags") == null);
    // for* method IS generated for the string field.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "pub fn forName") != null);
}

test "transformSquirrel expands a relation field's type" {
    const source = "@@struct Person { @@employee: @@Employee }";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "var employee: squirrel_runtime.sqrrl___Rel(sqrrl___Entity, sqrrl__Employee.sqrrl___Entity) = undefined;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___employee(self: sqrrl___Entity) sqrrl__Employee.sqrrl___Entity {",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___setEmployee(self: *sqrrl___Entity, value: sqrrl__Employee.sqrrl___Entity) !void {",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code,
        "pub fn sqrrl___create(args: struct { employee: sqrrl__Employee.sqrrl___Entity }) !sqrrl___Entity {",
    ) != null);
}

test "transformSquirrel rewrites a chained relation read with panic-on-missing getters" {
    const source = "std.debug.print(\"{d}\", .{@@alice.@@employee.age});";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "std.debug.print(\"{d}\", .{sqrrl__alice.sqrrl___employee().sqrrl___age()});",
        result.code,
    );
}

test "transformSquirrel rewrites a chained relation write" {
    const source = "@@alice.@@employee.age = 40;";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    var sqrrl___relay0 = sqrrl__alice.sqrrl___employee();\n" ++
            "    try sqrrl___relay0.sqrrl___setAge(40);\n" ++
            "}",
        result.code,
    );
}

test "transformSquirrel rewrites a chained relation write with multiple hops" {
    const source = "@@alice.@@employee.@@manager.age = 40;";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    var sqrrl___relay0 = sqrrl__alice.sqrrl___employee();\n" ++
            "    var sqrrl___relay1 = sqrrl___relay0.sqrrl___manager();\n" ++
            "    try sqrrl___relay1.sqrrl___setAge(40);\n" ++
            "}",
        result.code,
    );
}

test "transformSquirrel rewrites a chained relation destroy" {
    const source = "@@alice.@@employee.destroy();";
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    var sqrrl___relay0 = sqrrl__alice.sqrrl___employee();\n" ++
            "    sqrrl___relay0.decref();\n" ++
            "}",
        result.code,
    );
}

test "transformSquirrel auto-defer fires for const @@name in presence of earlier constructs" {
    const source =
        \\var w1 = Wrapper{ .@@entity = @@Employee{ .name = "dave", .age = 50 } };
        \\const @@carol2 = @@Employee{ .name = "carol2", .age = 33 };
    ;
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__carol2.decref()") != null);
}

test "transformSquirrel auto-defer fires after @@entity: @@Employee type declaration" {
    // Regression: `@@entity: @@Employee` in a struct field declaration expands
    // to `sqrrl__entity: sqrrl__Employee.sqrrl___Entity` (@@entity is a name_ref
    // with `:` prefix, @@Employee is a name_ref in type position).  The
    // @@Employee name_ref must NOT set last_decl — it is NOT a `const @@X = ...`
    // declaration; it is a TYPE annotation.  If it does set last_decl, the
    // subsequent `const @@carol2 = @@Employee{...}` construct arm will see
    // a stale last_decl with var_name="Employee" and emit the wrong defer.
    const source =
        \\const Wrapper = struct { @@entity: @@Employee };
        \\const @@carol2 = @@Employee{ .name = "carol2", .age = 33 };
    ;
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    // carol2 must get its own auto-defer, not a spurious "Employee" defer.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__carol2.decref()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__Employee.decref(sqrrl__Employee)") == null);
}

test "transformSquirrel auto-defer fires for const @@carol2 with full Wrapper deinit context" {
    // Matches the actual usage.rel scenario: Wrapper struct with @@entity field
    // AND a deinit that accesses self.@@entity, THEN const @@carol2 declaration.
    // The self.@@entity name_ref inside deinit must not clear last_decl in a way
    // that prevents carol2 from getting its auto-defer.
    const source =
        \\const Wrapper = struct {
        \\    @@entity: @@Employee,
        \\    pub fn deinit(self: *@This()) void {
        \\        sqrrl__Employee.sqrrl___decref(self.@@entity);
        \\    }
        \\};
        \\const @@carol2 = @@Employee{ .name = "carol2", .age = 33 };
    ;
    const result = try transformSquirrel(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(result.code);
    defer std.testing.allocator.free(result.struct_names);
    defer std.testing.allocator.free(result.relation_edges);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "defer sqrrl__carol2.decref()") != null);
}
