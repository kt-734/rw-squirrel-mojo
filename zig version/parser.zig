const std = @import("std");

pub const Field = struct {
    /// Always the bare field name, `@@`-stripped if it was marked — see
    /// `parseFields`. Never carries `@@` itself: nothing downstream
    /// (`codegen.zig`'s `emitTable`) ever rewrites a field name, only the
    /// type, so there's nothing for a `sqrrl__`/`sqrrl___` prefix to attach
    /// to here.
    name: []const u8,
    /// Raw, untouched type text — usually a plain Zig type (`u32`,
    /// `[]const u8`), but may also be a *relation* to another `@@struct`:
    /// `@@employee: @@Employee`. `type_str` is left as the literal captured
    /// text either way (`"@@Employee"` verbatim here) — `codegen.zig`'s
    /// `emitFieldType` is what recognizes the `@@`-marked case and expands
    /// it to `sqrrl__Employee.sqrrl___Entity` wherever the field's type is
    /// actually emitted, not this parser.
    type_str: []const u8,
};

pub const ParsedStruct = struct {
    name: []const u8,
    /// Caller owns this slice (allocated via `allocator.alloc`/`toOwnedSlice`)
    /// and must free it.
    fields: []Field,
    /// Position in `source` just past the closing `}` of the `@@struct`
    /// block, i.e. where scanning should resume.
    end: usize,
};

/// A `@@entity.field` use-site access, read or write — optionally chained
/// through one or more relation fields: `@@alice.@@employee.age` reads
/// `age` off the `Employee` entity stored in `alice`'s `employee` field
/// (itself declared `@@employee: @@Employee` in `@@struct`, see `Field`).
pub const FieldAccess = struct {
    entity: []const u8,
    /// Zero or more intermediate relation hops between `entity` and `field`
    /// — e.g. `["employee"]` for `@@alice.@@employee.age`. Each one names a
    /// field, on the entity reached so far, that itself holds another
    /// squirrel entity. Caller owns this slice; free with `allocator.free`.
    /// Every hop is `@@`-marked in the source (`.@@employee`, not
    /// `.employee`) — only the terminal `field` isn't, mirroring how
    /// `@@alice.age` already only marks `alice`, not `age`.
    relations: [][]const u8,
    field: []const u8,
    /// Trimmed RHS text for a write (`@@entity.field = expr;`), null for a
    /// plain read (`@@entity.field`).
    write_value: ?[]const u8,
    /// Position in `source` to resume scanning from.
    end: usize,
};

/// A `@@TypeName { .field = expr, ... }` construction use site, optionally
/// qualified (`person.@@Person { ... }`).
pub const Construct = struct {
    type_name: []const u8,
    /// Verbatim text of a dotted qualifier chain immediately before `@@`,
    /// including the trailing `.` (e.g. `"person."`), or null if this is a
    /// bare `@@TypeName { ... }`. When present, `type_name` needs the
    /// `sqrrl__` prefix to resolve — `person.Person` doesn't exist, only
    /// `person.sqrrl__Person` does (`person` being a whole-module import,
    /// `const person = @import("person.zig");`, rather than a pre-aliased
    /// local name) — and the *whole* expression, qualifier included, has to
    /// be replaced as one unit: `try` must prefix the entire path
    /// (`try person.sqrrl__Person.sqrrl___create(...)`), so the qualifier
    /// can't be left as separately-copied pass-through text the way an
    /// entity name in `@@entity.field` can.
    /// Only a plain dotted chain of identifiers is recognized as a
    /// qualifier (`a.b.@@Person`); anything with a call or index in it
    /// (`foo().@@Person`) isn't — same "no arbitrary expressions" scope
    /// limit as `parseFieldAccess`'s entity.
    qualifier: ?[]const u8,
    /// The `{ ... }` body, trimmed but otherwise verbatim — it's already
    /// valid Zig anonymous-struct-literal field syntax (`.field = expr,
    /// ...`), just missing the leading `.` before the `{`, so there's
    /// nothing to re-parse here.
    body: []const u8,
    /// Position in `source` to resume scanning from.
    end: usize,
};

/// A `@@entity.destroy()` use site, optionally chained through one or more
/// relation fields (see `FieldAccess.relations`) — `@@alice.@@employee.destroy()`.
pub const Destroy = struct {
    entity: []const u8,
    /// See `FieldAccess.relations`. Caller owns this slice.
    relations: [][]const u8,
    /// Position in `source` to resume scanning from.
    end: usize,
};

/// A bare `@@name` — every `@@`-marked identifier that isn't part of a
/// `@@struct`, `@@entity.field`, `@@TypeName { ... }`, or `@@entity.destroy()`
/// shape. Covers both a name being *declared/bound* (`var @@alice = ...`,
/// `const @@Person = ...`) and a name being *referenced* as a bare value
/// (`@import("person.zig").@@Person`) — both rewrite identically, to
/// `sqrrl__name` (see `codegen.zig`'s `emitNameRef`), so there's no reason
/// to keep them as separate marker kinds or parse functions.
pub const NameRef = struct {
    name: []const u8,
    end: usize,
};

/// What `findNextMarker` found: a `@@struct` declaration, a `@@entity.field`
/// use-site access, a `@@TypeName { ... }` construction, a
/// `@@entity.destroy()`, or a bare `@@name` (declared or referenced — see
/// `NameRef`). The payload is the index of the marker itself.
pub const Marker = union(enum) {
    struct_decl: usize,
    field_access: usize,
    construct: usize,
    destroy: usize,
    name_ref: usize,
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Scans an identifier starting at `pos`. Returns its end position, which
/// equals `pos` itself if there's no identifier there (the various callers
/// that require a non-empty identifier check for that and error). Pulled
/// out since "scan an identifier, note where it ends" is the single most
/// repeated operation in this file.
fn scanIdent(source: []const u8, pos: usize) usize {
    var p = pos;
    while (p < source.len and isIdentChar(source[p])) : (p += 1) {}
    return p;
}

fn skipWhitespace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return i;
}

/// If `source[pos..]` starts a `//` line comment or a `"`/`'` literal,
/// returns the position just past it; otherwise returns `pos` unchanged.
/// Every structural scan (brace matching, comma splitting, `@@struct`
/// searching) routes through this so that `{`, `}`, `,`, or even `@@struct`
/// itself sitting inside a comment or string doesn't desync the parser.
fn skipNonCode(source: []const u8, pos: usize) usize {
    if (pos >= source.len) return pos;
    if (source[pos] == '/' and pos + 1 < source.len and source[pos + 1] == '/') {
        var i = pos;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        return i;
    }
    if (source[pos] == '"' or source[pos] == '\'') {
        const quote = source[pos];
        var i = pos + 1;
        while (i < source.len and source[i] != quote) : (i += 1) {
            if (source[i] == '\\' and i + 1 < source.len) i += 1;
        }
        return @min(i + 1, source.len);
    }
    return pos;
}

/// Skips whitespace and `//` comments (interleaved, in any order — a
/// comment can be followed by more whitespace then another comment) to find
/// the next position that's either real code or EOF. Anywhere the parser
/// expects "the next token", it should skip trivia first via this, not bare
/// `skipWhitespace` — otherwise a comment sitting where a token is expected
/// (e.g. a comment-only line right before a field name) is mistaken for the
/// token itself and fails to parse.
///
/// Caution: this also calls `skipNonCode`, which treats a string/char
/// literal as skippable trivia too (so brace/marker matching elsewhere isn't
/// desynced by a stray `{`/`@@` sitting inside one). That's correct when
/// looking for the *next token after* some value, but wrong when looking
/// for where a *value itself* starts — a string is a valid value, not
/// something to skip past. Use `skipWhitespaceAndComments` for the latter
/// (see `parseFieldAccess`'s write-value scan).
pub fn skipTrivia(s: []const u8, start: usize) usize {
    var i = start;
    while (true) {
        const next = skipNonCode(s, skipWhitespace(s, i));
        if (next == i) return i;
        i = next;
    }
}

/// Like `skipTrivia`, but stops at a string/char literal instead of skipping
/// over it — for positioning right before a value that might itself be a
/// string (`@@entity.field = "literal";`), where `skipTrivia` would
/// incorrectly consume the whole literal as if it were trivia to skip past,
/// leaving nothing for the value scan to find.
fn skipWhitespaceAndComments(s: []const u8, start: usize) usize {
    var i = start;
    while (true) {
        i = skipWhitespace(s, i);
        if (i < s.len and s[i] == '/' and i + 1 < s.len and s[i + 1] == '/') {
            while (i < s.len and s[i] != '\n') : (i += 1) {}
            continue;
        }
        return i;
    }
}

/// `pos` must point at a `{`. Scans to the matching `}` at real-code depth
/// (comments/strings can't desync the brace count) and returns the position
/// just past it.
fn scanBracedSpan(source: []const u8, pos_at_open_brace: usize) !usize {
    var pos = pos_at_open_brace + 1;
    var depth: usize = 1;
    while (pos < source.len and depth > 0) {
        const skipped = skipNonCode(source, pos);
        if (skipped != pos) {
            pos = skipped;
            continue;
        }
        switch (source[pos]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
        pos += 1;
    }
    if (depth != 0) return error.InvalidSquirrelSyntax;
    return pos;
}

/// If `at` (the index of `@@`) is immediately preceded by a dotted chain of
/// plain identifiers (`a.b.c.@@Type`), returns the position where that
/// chain begins (the start of `a`). Otherwise returns `at` unchanged. Used
/// so a qualified construct (`person.@@Person { ... }`) is treated as one
/// marker spanning the whole `person.@@Person { ... }`, not just `@@Person
/// { ... }` with `person.` left as separately-copied plain text — `try` has
/// to prefix the entire expression, which only works if the whole thing is
/// replaced as a unit.
fn qualifierStart(source: []const u8, at: usize) usize {
    var pos = at;
    while (pos > 0 and source[pos - 1] == '.') {
        const dot_pos = pos - 1;
        var j = dot_pos;
        while (j > 0 and isIdentChar(source[j - 1])) : (j -= 1) {}
        if (j == dot_pos) break; // nothing identifier-like before the dot
        pos = j;
    }
    return pos;
}

/// Finds the next `@@` marker at real-code depth (i.e. not inside a comment
/// or string literal), starting at `start`, and reports which kind it is:
/// `@@struct` is a declaration; any other `@@identifier` is disambiguated by
/// peeking past the identifier:
///   - `{` → construction (`@@TypeName { ... }`)
///   - `.` followed by zero or more `@@`-marked relation hops
///     (`.@@employee.@@manager...`), then:
///       - `.destroy(` → entity destroy (`@@entity[.@@relation]*.destroy()`)
///       - `.member(` (member followed immediately by `(`, not `destroy`) →
///         a bare `@@name` (`NameRef`), letting `.member(args...)` pass through
///         as literal Zig text. This is the static-call pattern:
///         `@@Person.forName("alice")` becomes `sqrrl__Person.forName("alice")`
///         with `forName("alice")` untouched as literal text.
///       - `.member` (anything else) → field access
///         (`@@entity[.@@relation]*.field`, read or write)
///   - anything else (including `=`, `==`, end of statement, ...) → a bare
///     `@@name` (`NameRef`) — declared or referenced, doesn't matter, both
///     rewrite the same way.
/// Routing all of these through one scan keeps `skipNonCode` as the single
/// source of truth for what counts as "real code" — a `{`, `}`, `,`, or even
/// `@@` itself sitting inside a comment or string never desyncs anything.
pub fn findNextMarker(source: []const u8, start: usize) ?Marker {
    var i = start;
    while (i < source.len) {
        const skipped = skipNonCode(source, i);
        if (skipped != i) {
            i = skipped;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "@@struct")) return .{ .struct_decl = i };
        if (std.mem.startsWith(u8, source[i..], "@@")) {
            var p = skipTrivia(source, scanIdent(source, i + 2));
            if (p < source.len and source[p] == '{') return .{ .construct = qualifierStart(source, i) };
            // Skip past any `.@@relation` hops to reach the terminal `.member`.
            while (p < source.len and source[p] == '.' and std.mem.startsWith(u8, source[p + 1 ..], "@@")) {
                p = skipTrivia(source, scanIdent(source, p + 1 + "@@".len));
            }
            if (p < source.len and source[p] == '.') {
                const member_start = p + 1;
                const member_end = scanIdent(source, member_start);
                const after_member = skipTrivia(source, member_end);
                if (after_member < source.len and source[after_member] == '(') {
                    if (std.mem.eql(u8, source[member_start..member_end], "destroy"))
                        return .{ .destroy = i };
                    // Non-destroy call with `(` — static method call on a table
                    // type or entity. Let `@@name` rewrite as a name_ref and
                    // `.method(args)` pass through as literal Zig text.
                    return .{ .name_ref = i };
                }
                return .{ .field_access = i };
            }
            return .{ .name_ref = i };
        }
        i += 1;
    }
    return null;
}

/// Splits a `@@struct` body into `name: Type` fields, tolerating nested
/// brackets in the type (e.g. `[]const u8`), comments/strings containing
/// stray `,`/`:`/brackets, and a trailing comma. Rejects duplicate names —
/// collisions with generated identifiers aren't checked here because
/// `codegen.zig` prefixes every generated-but-fixed name with `sqrrl___`,
/// so a user field can never collide with one.
///
/// A relation field's name must itself be `@@`-marked too —
/// `@@employee: @@Employee`, not `employee: @@Employee` — so the `@@`s stay
/// "lined up" with the type, the same consistency rule applied to every
/// other `@@`-marked declaration in this tool (see `NameRef`). The `@@` is
/// stripped before `name` is stored (see `Field.name`); marking only exists
/// to keep relation fields visually distinct from plain ones in the
/// `.rel` source, it has no effect on generated code. A field name marked
/// without a relation type, or a relation type with an unmarked name, is
/// rejected as `error.InvalidSquirrelSyntax`.
fn parseFields(allocator: std.mem.Allocator, body: []const u8) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    errdefer fields.deinit(allocator);

    var pos: usize = 0;
    while (true) {
        pos = skipTrivia(body, pos);
        if (pos >= body.len) break;

        const name_is_marked = std.mem.startsWith(u8, body[pos..], "@@");
        if (name_is_marked) pos += "@@".len;

        const name_start = pos;
        pos = scanIdent(body, pos);
        if (pos == name_start) return error.InvalidSquirrelSyntax;
        const name = body[name_start..pos];
        for (fields.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateFieldName;
        }

        pos = skipTrivia(body, pos);
        if (pos >= body.len or body[pos] != ':') return error.InvalidSquirrelSyntax;
        pos += 1;
        pos = skipTrivia(body, pos);

        const type_start = pos;
        var depth: i32 = 0;
        while (pos < body.len) {
            const skipped = skipNonCode(body, pos);
            if (skipped != pos) {
                pos = skipped;
                continue;
            }
            switch (body[pos]) {
                '[', '(', '{' => depth += 1,
                ']', ')', '}' => depth -= 1,
                ',' => if (depth == 0) break,
                else => {},
            }
            pos += 1;
        }
        const type_str = std.mem.trim(u8, body[type_start..pos], " \t\r\n");
        if (type_str.len == 0) return error.InvalidSquirrelSyntax;
        if (name_is_marked != std.mem.startsWith(u8, type_str, "@@")) return error.InvalidSquirrelSyntax;
        try fields.append(allocator, .{ .name = name, .type_str = type_str });

        if (pos < body.len and body[pos] == ',') pos += 1;
    }
    return fields.toOwnedSlice(allocator);
}

/// Scans zero or more `.@@relation` hops starting at `pos` (which must be
/// positioned right after the entity/preceding hop's identifier). Stops as
/// soon as a `.` isn't followed by `@@` — that's the terminal segment, left
/// for the caller to parse. Shared by `parseFieldAccess` and `parseDestroy`.
fn scanRelationHops(allocator: std.mem.Allocator, source: []const u8, start: usize) !struct { relations: [][]const u8, pos: usize } {
    var relations: std.ArrayList([]const u8) = .empty;
    errdefer relations.deinit(allocator);

    var pos = start;
    while (pos < source.len and source[pos] == '.' and std.mem.startsWith(u8, source[pos + 1 ..], "@@")) {
        const seg_start = pos + 1 + "@@".len;
        const seg_end = scanIdent(source, seg_start);
        if (seg_end == seg_start) return error.InvalidSquirrelSyntax;
        try relations.append(allocator, source[seg_start..seg_end]);
        pos = seg_end;
    }
    return .{ .relations = try relations.toOwnedSlice(allocator), .pos = pos };
}

/// Parses one `@@entity[.@@relation]*.field` use-site access — a read, or
/// (if followed by `= expr;`) a write. `at` must be the index of the `@@`
/// itself (e.g. from `findNextMarker`'s `.field_access`). Caller must free
/// the returned `relations` slice.
///
/// v1 deliberately only supports bare identifiers for the entity and each
/// relation hop (`@@alice.@@employee.name`, not `@@getPerson(id).name` or
/// `@@self.alice.name`) — parsing arbitrary Zig expressions by hand isn't
/// worth the complexity until a real `.rel` script actually needs it.
pub fn parseFieldAccess(allocator: std.mem.Allocator, source: []const u8, at: usize) !FieldAccess {
    var pos = at + "@@".len;

    const entity_start = pos;
    pos = scanIdent(source, pos);
    if (pos == entity_start) return error.InvalidSquirrelSyntax;
    const entity = source[entity_start..pos];

    const hops = try scanRelationHops(allocator, source, pos);
    const relations = hops.relations;
    errdefer allocator.free(relations);
    pos = hops.pos;

    if (pos >= source.len or source[pos] != '.') return error.InvalidSquirrelSyntax;
    pos += 1;

    const field_start = pos;
    pos = scanIdent(source, pos);
    if (pos == field_start) return error.InvalidSquirrelSyntax;
    const field = source[field_start..pos];
    const after_field = pos;

    const after_ws = skipTrivia(source, after_field);
    const is_write = after_ws < source.len and source[after_ws] == '=' and
        (after_ws + 1 >= source.len or source[after_ws + 1] != '=');
    if (!is_write) {
        return .{ .entity = entity, .relations = relations, .field = field, .write_value = null, .end = after_field };
    }

    pos = skipWhitespaceAndComments(source, after_ws + 1);
    const value_start = pos;
    var depth: i32 = 0;
    while (pos < source.len) {
        const skipped = skipNonCode(source, pos);
        if (skipped != pos) {
            pos = skipped;
            continue;
        }
        switch (source[pos]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ';' => if (depth == 0) break,
            else => {},
        }
        pos += 1;
    }
    if (pos >= source.len) return error.InvalidSquirrelSyntax;
    const value = std.mem.trim(u8, source[value_start..pos], " \t\r\n");
    if (value.len == 0) return error.InvalidSquirrelSyntax;
    pos += 1; // consume the ';'

    return .{ .entity = entity, .relations = relations, .field = field, .write_value = value, .end = pos };
}

/// Parses one `@@entity[.@@relation]*.destroy()` use site. `at` must be the
/// index of the `@@` itself (e.g. from `findNextMarker`'s `.destroy`). The
/// parens must be empty — `sqrrl___destroy` takes no arguments. Caller must
/// free the returned `relations` slice.
pub fn parseDestroy(allocator: std.mem.Allocator, source: []const u8, at: usize) !Destroy {
    var pos = at + "@@".len;

    const entity_start = pos;
    pos = scanIdent(source, pos);
    if (pos == entity_start) return error.InvalidSquirrelSyntax;
    const entity = source[entity_start..pos];

    const hops = try scanRelationHops(allocator, source, pos);
    const relations = hops.relations;
    errdefer allocator.free(relations);
    pos = hops.pos;

    pos = skipTrivia(source, pos);
    if (pos >= source.len or source[pos] != '.') return error.InvalidSquirrelSyntax;
    pos += 1;

    const member_start = pos;
    pos = scanIdent(source, pos);
    if (!std.mem.eql(u8, source[member_start..pos], "destroy")) return error.InvalidSquirrelSyntax;

    pos = skipTrivia(source, pos);
    if (pos >= source.len or source[pos] != '(') return error.InvalidSquirrelSyntax;
    pos = skipTrivia(source, pos + 1);
    if (pos >= source.len or source[pos] != ')') return error.InvalidSquirrelSyntax;
    pos += 1;

    return .{ .entity = entity, .relations = relations, .end = pos };
}

/// Parses a bare `@@name` — declared or referenced, doesn't matter (see
/// `NameRef`). `at` must be the index of the `@@` itself (e.g. from
/// `findNextMarker`'s `.name_ref`). `end` points just past `name` —
/// nothing past it is consumed, so for a declaration (`@@name = ...`),
/// whatever follows the `=` is picked up as its own, separate marker on
/// `findNextMarker`'s next iteration.
pub fn parseNameRef(source: []const u8, at: usize) !NameRef {
    const start = at + "@@".len;
    const pos = scanIdent(source, start);
    if (pos == start) return error.InvalidSquirrelSyntax;
    return .{ .name = source[start..pos], .end = pos };
}

/// Parses one `@@struct Name { field: Type, ... }` block. `at` must be the
/// index of the `@@struct` token itself (e.g. from `findNextMarker`).
pub fn parseStruct(allocator: std.mem.Allocator, source: []const u8, at: usize) !ParsedStruct {
    var pos = at + "@@struct".len;
    pos = skipTrivia(source, pos);

    const name_start = pos;
    pos = scanIdent(source, pos);
    if (pos == name_start) return error.InvalidSquirrelSyntax;
    const name = source[name_start..pos];

    pos = skipTrivia(source, pos);
    if (pos >= source.len or source[pos] != '{') return error.InvalidSquirrelSyntax;
    const body_start = pos + 1;
    pos = try scanBracedSpan(source, pos);
    const body = source[body_start .. pos - 1];

    const fields = try parseFields(allocator, body);
    return .{ .name = name, .fields = fields, .end = pos };
}

/// Parses one `@@TypeName { .field = expr, ... }` construction, optionally
/// qualified (`person.@@Person { ... }` — see `Construct.qualifier`). `at`
/// must be the position `findNextMarker`'s `.construct` reported — which,
/// when qualified, is the *start of the qualifier chain*, not the `@@`
/// itself (`qualifierStart` already backed it up); when unqualified the two
/// are the same position. Either way this scans forward from `at`: an
/// optional `ident.ident....` chain, then `@@`, then the type name and body.
pub fn parseConstruct(source: []const u8, at: usize) !Construct {
    var pos = at;

    const qualifier_start = pos;
    while (true) {
        const seg_start = pos;
        pos = scanIdent(source, pos);
        if (pos == seg_start or pos >= source.len or source[pos] != '.') {
            pos = seg_start;
            break;
        }
        pos += 1; // consume the '.'
    }
    const qualifier: ?[]const u8 = if (pos > qualifier_start) source[qualifier_start..pos] else null;

    if (pos + 2 > source.len or source[pos] != '@' or source[pos + 1] != '@') return error.InvalidSquirrelSyntax;
    pos += 2;

    const name_start = pos;
    pos = scanIdent(source, pos);
    if (pos == name_start) return error.InvalidSquirrelSyntax;
    const type_name = source[name_start..pos];

    pos = skipTrivia(source, pos);
    if (pos >= source.len or source[pos] != '{') return error.InvalidSquirrelSyntax;
    const body_start = pos + 1;
    pos = try scanBracedSpan(source, pos);
    const body = std.mem.trim(u8, source[body_start .. pos - 1], " \t\r\n");

    return .{ .type_name = type_name, .qualifier = qualifier, .body = body, .end = pos };
}

test "findNextMarker ignores @@struct inside a comment" {
    const source = "// not @@struct Real\n@@struct Actual { x: u32 }";
    const marker = findNextMarker(source, 0).?;
    try std.testing.expectEqualStrings("@@struct Actual { x: u32 }", source[marker.struct_decl..]);
}

test "findNextMarker ignores @@struct inside a string" {
    const source = "const s = \"@@struct Fake { x: u32 }\";\n@@struct Real { y: u32 }";
    const marker = findNextMarker(source, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, source[marker.struct_decl..], "@@struct Real"));
}

test "findNextMarker distinguishes @@struct from a field access" {
    const source = "@@alice.name\n@@struct Foo { x: u32 }";
    const first = findNextMarker(source, 0).?;
    try std.testing.expectEqual(@as(usize, 0), first.field_access);
    const second = findNextMarker(source, first.field_access + 2).?;
    try std.testing.expect(std.mem.startsWith(u8, source[second.struct_decl..], "@@struct Foo"));
}

test "findNextMarker distinguishes a construct from a field access" {
    const access = findNextMarker("@@alice.name", 0).?;
    try std.testing.expectEqual(@as(usize, 0), access.field_access);

    const construct = findNextMarker("@@Person { .name = \"a\" }", 0).?;
    try std.testing.expectEqual(@as(usize, 0), construct.construct);

    // Whitespace between the identifier and `{` shouldn't change the result.
    const spaced = findNextMarker("@@Person   { .name = \"a\" }", 0).?;
    try std.testing.expectEqual(@as(usize, 0), spaced.construct);
}

test "parseFieldAccess parses a read" {
    const access = try parseFieldAccess(std.testing.allocator, "@@alice.name", 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("alice", access.entity);
    try std.testing.expectEqual(@as(usize, 0), access.relations.len);
    try std.testing.expectEqualStrings("name", access.field);
    try std.testing.expectEqual(@as(?[]const u8, null), access.write_value);
    try std.testing.expectEqual(@as(usize, "@@alice.name".len), access.end);
}

test "parseFieldAccess parses a write and stops at the right brace/paren depth" {
    const source = "@@alice.age = compute(x, y) + 1; std.debug.print(\"\", .{});";
    const access = try parseFieldAccess(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("alice", access.entity);
    try std.testing.expectEqualStrings("age", access.field);
    try std.testing.expectEqualStrings("compute(x, y) + 1", access.write_value.?);
    try std.testing.expectEqualStrings(" std.debug.print(\"\", .{});", source[access.end..]);
}

test "parseFieldAccess does not mistake == for an assignment" {
    const access = try parseFieldAccess(std.testing.allocator, "@@alice.age == 5", 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqual(@as(?[]const u8, null), access.write_value);
}

// Regression: `skipTrivia` treats a string/char literal as skippable trivia
// (so brace/marker scanning elsewhere isn't desynced by a stray `{`/`@@`
// inside one — see its doc comment) — which made it the wrong thing to
// position right before the write *value* itself: for `@@alice.name = "x";`
// it would skip clean over `"x"` looking for "the next token", landing on
// `;` with nothing left to scan, so the value came out empty and got
// rejected. Fixed by switching to `skipWhitespaceAndComments`, which stops
// at a string instead of consuming it.
test "parseFieldAccess parses a string-literal write value" {
    const access = try parseFieldAccess(std.testing.allocator, "@@alice.name = \"Main St\";", 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("\"Main St\"", access.write_value.?);
}

test "parseFieldAccess parses a string-literal write value containing braces and dots" {
    const access = try parseFieldAccess(std.testing.allocator, "@@alice.name = \"{not a brace}.@@not.a.hop\";", 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("\"{not a brace}.@@not.a.hop\"", access.write_value.?);
}

test "parseFieldAccess parses a chained relation hop" {
    const access = try parseFieldAccess(std.testing.allocator, "@@alice.@@employee.age", 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("alice", access.entity);
    try std.testing.expectEqual(@as(usize, 1), access.relations.len);
    try std.testing.expectEqualStrings("employee", access.relations[0]);
    try std.testing.expectEqualStrings("age", access.field);
}

test "parseFieldAccess parses multiple chained relation hops, and a write at the end" {
    const source = "@@alice.@@employee.@@manager.age = 40;";
    const access = try parseFieldAccess(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(access.relations);
    try std.testing.expectEqualStrings("alice", access.entity);
    try std.testing.expectEqual(@as(usize, 2), access.relations.len);
    try std.testing.expectEqualStrings("employee", access.relations[0]);
    try std.testing.expectEqualStrings("manager", access.relations[1]);
    try std.testing.expectEqualStrings("age", access.field);
    try std.testing.expectEqualStrings("40", access.write_value.?);
}

test "findNextMarker recognizes destroy and classifies non-destroy calls as name_ref" {
    const destroy = findNextMarker("@@alice.destroy()", 0).?;
    try std.testing.expectEqual(@as(usize, 0), destroy.destroy);

    // `.destroy` without parens is a field read, not a destroy call.
    const not_a_call = findNextMarker("@@alice.destroy", 0).?;
    try std.testing.expectEqual(@as(usize, 0), not_a_call.field_access);

    // Any `.member(` that is not `destroy` is a static/table-level call —
    // `@@Person` rewrites as a name_ref and `.forName(...)` passes through
    // as literal Zig text, producing `sqrrl__Person.forName(...)`.
    const static_call = findNextMarker("@@Person.forName(\"alice\")", 0).?;
    try std.testing.expectEqual(@as(usize, 0), static_call.name_ref);
}

test "parseDestroy parses entity.destroy()" {
    const source = "@@alice.destroy(); rest";
    const destroy = try parseDestroy(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(destroy.relations);
    try std.testing.expectEqualStrings("alice", destroy.entity);
    try std.testing.expectEqual(@as(usize, 0), destroy.relations.len);
    try std.testing.expectEqualStrings("; rest", source[destroy.end..]);
}

test "parseDestroy tolerates whitespace inside the parens" {
    const destroy = try parseDestroy(std.testing.allocator, "@@alice.destroy(  )", 0);
    defer std.testing.allocator.free(destroy.relations);
    try std.testing.expectEqualStrings("alice", destroy.entity);
}

test "parseDestroy rejects non-empty arguments" {
    try std.testing.expectError(error.InvalidSquirrelSyntax, parseDestroy(std.testing.allocator, "@@alice.destroy(5)", 0));
}

test "parseDestroy parses a chained relation hop" {
    const destroy = try parseDestroy(std.testing.allocator, "@@alice.@@employee.destroy();", 0);
    defer std.testing.allocator.free(destroy.relations);
    try std.testing.expectEqualStrings("alice", destroy.entity);
    try std.testing.expectEqual(@as(usize, 1), destroy.relations.len);
    try std.testing.expectEqualStrings("employee", destroy.relations[0]);
}

test "findNextMarker recognizes destroy through a chained relation hop" {
    const destroy = findNextMarker("@@alice.@@employee.destroy()", 0).?;
    try std.testing.expectEqual(@as(usize, 0), destroy.destroy);

    const access = findNextMarker("@@alice.@@employee.age", 0).?;
    try std.testing.expectEqual(@as(usize, 0), access.field_access);
}

test "findNextMarker treats both a declaration and a bare reference as name_ref" {
    // `@@name = ...`: a declaration/binding.
    const decl = findNextMarker("@@Person = @import(\"x\").@@Person;", 0).?;
    try std.testing.expectEqual(@as(usize, 0), decl.name_ref);

    // Nothing meaningful follows: a bare value reference. Same marker kind —
    // both rewrite identically, so there's nothing to disambiguate anymore.
    const ref = findNextMarker("@import(\"x\").@@Person;", 0).?;
    try std.testing.expectEqual(@as(usize, "@import(\"x\").".len), ref.name_ref);

    // `==`, `.`-less end of statement, anything: still just name_ref.
    const eq = findNextMarker("@@Person == OtherType", 0).?;
    try std.testing.expectEqual(@as(usize, 0), eq.name_ref);

    // Still a field access when `.member` follows, same as before.
    const access = findNextMarker("@@alice.name", 0).?;
    try std.testing.expectEqual(@as(usize, 0), access.field_access);
}

test "parseNameRef parses a bare reference" {
    const source = "@@Person;";
    const ref = try parseNameRef(source, 0);
    try std.testing.expectEqualStrings("Person", ref.name);
    try std.testing.expectEqualStrings(";", source[ref.end..]);
}

test "parseNameRef parses a declaration and stops before '='" {
    const source = "@@Person = @import(\"x\").@@Person;";
    const decl = try parseNameRef(source, 0);
    try std.testing.expectEqualStrings("Person", decl.name);
    try std.testing.expectEqualStrings(" = @import(\"x\").@@Person;", source[decl.end..]);
}

test "parseConstruct parses a field-init body verbatim" {
    const source = "@@Person { .name = \"alice\", .age = 30 } ; rest";
    const construct = try parseConstruct(source, 0);
    try std.testing.expectEqualStrings("Person", construct.type_name);
    try std.testing.expectEqual(@as(?[]const u8, null), construct.qualifier);
    try std.testing.expectEqualStrings(".name = \"alice\", .age = 30", construct.body);
    try std.testing.expectEqualStrings(" ; rest", source[construct.end..]);
}

test "parseConstruct detects a qualified construct (preceded by an identifier chain)" {
    const source = "person.@@Person { .name = \"alice\" }";
    // `at` is the start of the qualifier chain, matching what
    // `findNextMarker` reports for a qualified construct (it backs up via
    // `qualifierStart` before returning), not the `@@` itself.
    const construct = try parseConstruct(source, 0);
    try std.testing.expectEqualStrings("Person", construct.type_name);
    try std.testing.expectEqualStrings("person.", construct.qualifier.?);
}

test "parseConstruct detects a multi-segment qualifier chain" {
    const source = "a.b.@@Person { .name = \"alice\" }";
    const construct = try parseConstruct(source, 0);
    try std.testing.expectEqualStrings("a.b.", construct.qualifier.?);
}

test "findNextMarker backs up a qualified construct's reported position to the qualifier start" {
    const source = "var x = person.@@Person { .name = \"a\" };";
    const marker = findNextMarker(source, 0).?;
    try std.testing.expectEqualStrings("person.@@Person { .name = \"a\" };", source[marker.construct..]);
}

test "parseConstruct tolerates a brace inside a comment in the body" {
    const source = "@@Person {\n    // odd brace: }\n    .name = \"a\",\n}";
    const construct = try parseConstruct(source, 0);
    try std.testing.expectEqual(source.len, construct.end);
}

test "parseConstruct rejects malformed input" {
    try std.testing.expectError(error.InvalidSquirrelSyntax, parseConstruct("@@Person not_braces", 0));
}

test "parseStruct tolerates a brace inside a comment in the body" {
    const source = "@@struct Foo {\n    // odd brace: }\n    x: u32,\n}";
    const parsed = try parseStruct(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(parsed.fields);
    try std.testing.expectEqualStrings("Foo", parsed.name);
    try std.testing.expectEqual(@as(usize, 1), parsed.fields.len);
    try std.testing.expectEqualStrings("x", parsed.fields[0].name);
    try std.testing.expectEqual(source.len, parsed.end);
}

test "parseStruct tolerates nested brackets in a field type" {
    const source = "@@struct Foo { x: u32, label: []const u8 }";
    const parsed = try parseStruct(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(parsed.fields);
    try std.testing.expectEqual(@as(usize, 2), parsed.fields.len);
    try std.testing.expectEqualStrings("[]const u8", parsed.fields[1].type_str);
}

test "parseStruct rejects duplicate field names" {
    const source = "@@struct Foo { x: u32, x: f32 }";
    try std.testing.expectError(error.DuplicateFieldName, parseStruct(std.testing.allocator, source, 0));
}

test "parseStruct rejects malformed input" {
    try std.testing.expectError(error.InvalidSquirrelSyntax, parseStruct(std.testing.allocator, "@@struct Foo not_braces", 0));
}

test "parseStruct parses a relation field whose name and type are both @@-marked" {
    const source = "@@struct Person { @@employee: @@Employee }";
    const parsed = try parseStruct(std.testing.allocator, source, 0);
    defer std.testing.allocator.free(parsed.fields);
    try std.testing.expectEqual(@as(usize, 1), parsed.fields.len);
    try std.testing.expectEqualStrings("employee", parsed.fields[0].name);
    try std.testing.expectEqualStrings("@@Employee", parsed.fields[0].type_str);
}

test "parseStruct rejects a relation type with an unmarked field name" {
    const source = "@@struct Person { employee: @@Employee }";
    try std.testing.expectError(error.InvalidSquirrelSyntax, parseStruct(std.testing.allocator, source, 0));
}

test "parseStruct rejects a @@-marked field name with a non-relation type" {
    const source = "@@struct Person { @@age: u32 }";
    try std.testing.expectError(error.InvalidSquirrelSyntax, parseStruct(std.testing.allocator, source, 0));
}
