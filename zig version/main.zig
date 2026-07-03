const std = @import("std");
const Io = std.Io;
const codegen = @import("codegen.zig");

const runtime_files = .{
    .{ "squirrel_runtime.zig",          @embedFile("runtime/squirrel_runtime.zig") },
    .{ "squirrel_runtime/O2O.zig",      @embedFile("runtime/squirrel_runtime/O2O.zig") },
    .{ "squirrel_runtime/M2O.zig",      @embedFile("runtime/squirrel_runtime/M2O.zig") },
    .{ "squirrel_runtime/M2M.zig",      @embedFile("runtime/squirrel_runtime/M2M.zig") },
    .{ "squirrel_runtime/Rel.zig",      @embedFile("runtime/squirrel_runtime/Rel.zig") },
    .{ "squirrel_runtime/RefCount.zig", @embedFile("runtime/squirrel_runtime/RefCount.zig") },
    .{ "squirrel_runtime/RefWalk.zig",  @embedFile("runtime/squirrel_runtime/RefWalk.zig") },
    .{ "squirrel_runtime/IdAllocator.zig", @embedFile("runtime/squirrel_runtime/IdAllocator.zig") },
};

const Table = struct {
    /// Root-relative `@import` path to the generated `.zig` file, e.g.
    /// "sub/person.zig" (always `/`-separated, regardless of host OS).
    import_path: []const u8,
    /// The `@@struct` name, e.g. "Person".
    name: []const u8,
};

/// Writes `squirrel.zig` at the conversion root: a single aggregator that
/// imports every table found across the whole directory walk and exposes
/// `init(allocator)`/`deinit()` calling each table's `sqrrl___init`/
/// `sqrrl___deinit` in turn (deinit in reverse order). Without this, a
/// `.rel` file using N tables would have to call N different
/// `TypeName.sqrrl___init(allocator)`s itself instead of one
/// `Squirrel.init(allocator)`. Aliases each import as `T0`, `T1`, ... to
/// sidestep any chance of two tables (possibly from different files)
/// sharing the same struct name.
fn writeSquirrelAggregator(arena: std.mem.Allocator, dir: Io.Dir, io: Io, tables: []const Table) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    for (tables, 0..) |t, idx| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "const T{d} = @import(\"{s}\").sqrrl__{s};\n", .{ idx, t.import_path, t.name }));
    }

    try out.appendSlice(arena, "\npub fn init(allocator: std.mem.Allocator) void {\n");
    for (0..tables.len) |idx| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "    T{d}.sqrrl___init(allocator);\n", .{idx}));
    }
    try out.appendSlice(arena, "}\n\npub fn deinit() void {\n");
    var idx = tables.len;
    while (idx > 0) {
        idx -= 1;
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "    T{d}.sqrrl___deinit();\n", .{idx}));
    }
    try out.appendSlice(arena, "}\n");

    const file = try dir.createFile(io, "squirrel.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}

fn copyRuntime(dir: Io.Dir, io: Io) !void {
    dir.createDir(io, "squirrel_runtime", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    inline for (runtime_files) |entry| {
        const path, const content = entry;
        const file = try dir.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }
}

/// Scans a .rel source file for `@import("X.zig").@@Name` patterns and
/// returns a map from each bare `Name` to the DECLARING `.rel` path (i.e.
/// `"X.zig"` with the `.zig` suffix swapped for `.rel`, resolved relative to
/// `current_file_path`'s directory). Used to qualify relation-edge targets
/// with their defining file before adding them to the cycle-detection graph.
/// Strings in the returned map are borrowed from `source` or arena-allocated.
fn scanImports(arena: std.mem.Allocator, source: []const u8, current_file_path: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(arena);
    const file_dir = std.fs.path.dirname(current_file_path) orelse "";

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@import(\"")) |at| {
        pos = at + "@import(\"".len;
        const path_start = pos;
        while (pos < source.len and source[pos] != '"') : (pos += 1) {}
        if (pos >= source.len) break;
        const zig_path = source[path_start..pos];
        pos += 1; // skip closing "

        // Skip ')' then expect '.@@Name'
        while (pos < source.len and source[pos] != '.') : (pos += 1) {}
        if (pos + 3 > source.len or source[pos] != '.' or source[pos + 1] != '@' or source[pos + 2] != '@') continue;
        pos += 3;
        const name_start = pos;
        while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) : (pos += 1) {}
        if (pos == name_start) continue;
        const name = source[name_start..pos];

        // Convert "X.zig" -> "X.rel", resolved relative to current file's dir.
        const stem = if (std.mem.endsWith(u8, zig_path, ".zig")) zig_path[0 .. zig_path.len - 4] else zig_path;
        const rel_path = if (file_dir.len > 0)
            try std.fmt.allocPrint(arena, "{s}/{s}.rel", .{ file_dir, stem })
        else
            try std.fmt.allocPrint(arena, "{s}.rel", .{stem});
        try map.put(name, rel_path);
    }
    return map;
}

const NodeState = enum { in_stack, done };

/// DFS from `node`, tracking the current path in `path` so the caller can
/// reconstruct the cycle if one is found. Returns the cycle as a slice of
/// node names (from cycle-start to cycle-start again) on the first detected
/// cycle, or null if the subtree rooted at `node` is acyclic.
fn dfs(
    arena: std.mem.Allocator,
    graph: *const std.StringHashMap(std.ArrayList([]const u8)),
    node: []const u8,
    state: *std.StringHashMap(NodeState),
    path: *std.ArrayList([]const u8),
) !?[][]const u8 {
    const gentry = try state.getOrPut(node);
    if (gentry.found_existing) {
        if (gentry.value_ptr.* == .in_stack) {
            // Cycle found — extract the loop from path.
            for (path.items, 0..) |n, idx| {
                if (std.mem.eql(u8, n, node)) {
                    const loop = try arena.alloc([]const u8, path.items.len - idx + 1);
                    @memcpy(loop[0 .. path.items.len - idx], path.items[idx..]);
                    loop[path.items.len - idx] = node; // repeat start to close the loop
                    return loop;
                }
            }
        }
        return null; // already fully explored, no cycle
    }
    gentry.value_ptr.* = .in_stack;
    try path.append(arena, node);
    if (graph.get(node)) |targets| {
        for (targets.items) |target| {
            if (try dfs(arena, graph, target, state, path)) |cycle| return cycle;
        }
    }
    _ = path.pop();
    gentry.value_ptr.* = .done;
    return null;
}

/// Checks the entire relation graph for cycles. Returns the first cycle found
/// as an owned slice of struct names (loop from cycle-start back to itself),
/// or null if the graph is acyclic.
fn findCycle(
    arena: std.mem.Allocator,
    graph: *const std.StringHashMap(std.ArrayList([]const u8)),
) !?[][]const u8 {
    var state = std.StringHashMap(NodeState).init(arena);
    var path: std.ArrayList([]const u8) = .empty;
    var it = graph.keyIterator();
    while (it.next()) |key| {
        if (try dfs(arena, graph, key.*, &state, &path)) |cycle| return cycle;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <directory>\n", .{args[0]});
        return error.MissingArgument;
    }

    const dir_path = args[1];
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening directory '{s}': {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var tables: std.ArrayList(Table) = .empty;
    // Adjacency list for the relation graph: struct name → target struct names.
    // Collected during the walk so we can DFS-check for cycles afterwards.
    var graph = std.StringHashMap(std.ArrayList([]const u8)).init(arena);

    var converted: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".rel")) continue;

        // Open and read the source .rel file
        const src_file = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
            std.debug.print("Error opening '{s}': {}\n", .{ entry.path, err });
            continue;
        };
        const file_len = src_file.length(io) catch |err| {
            src_file.close(io);
            std.debug.print("Error getting size of '{s}': {}\n", .{ entry.path, err });
            continue;
        };
        const buffer = try arena.alloc(u8, @intCast(file_len));
        const bytes_read = src_file.readPositionalAll(io, buffer, 0) catch |err| {
            src_file.close(io);
            std.debug.print("Error reading '{s}': {}\n", .{ entry.path, err });
            continue;
        };
        src_file.close(io);
        const content = buffer[0..bytes_read];

        // entry.path is relative to the conversion root, e.g. "sub/dir/file.rel" -
        // the depth of separators tells generated code how many "../" it needs to
        // reach the squirrel_runtime/ that copyRuntime writes at the root.
        var import_depth: usize = 0;
        for (entry.path) |c| {
            if (c == '/' or c == '\\') import_depth += 1;
        }

        const conversion = codegen.transformSquirrel(arena, content, import_depth) catch |err| {
            std.debug.print("Error converting '{s}': {}\n", .{ entry.path, err });
            continue;
        };

        // Write the output .zig file alongside the .rel file
        const stem = entry.basename[0 .. entry.basename.len - ".rel".len];
        const out_name = try std.mem.concat(arena, u8, &.{ stem, ".zig" });

        const out_file = entry.dir.createFile(io, out_name, .{}) catch |err| {
            std.debug.print("Error creating '{s}': {}\n", .{ out_name, err });
            continue;
        };
        out_file.writeStreamingAll(io, conversion.code) catch |err| {
            out_file.close(io);
            std.debug.print("Error writing '{s}': {}\n", .{ out_name, err });
            continue;
        };
        out_file.close(io);

        if (conversion.struct_names.len > 0) {
            // entry.path is root-relative, e.g. "sub/dir/file.rel"; the
            // squirrel.zig aggregator lives at the root, so it needs that
            // same path with ".rel" swapped for ".zig" and, on Windows,
            // backslashes normalized to '/' (Zig @import always uses '/').
            const import_path = try arena.alloc(u8, entry.path.len - ".rel".len + ".zig".len);
            @memcpy(import_path[0 .. entry.path.len - ".rel".len], entry.path[0 .. entry.path.len - ".rel".len]);
            @memcpy(import_path[entry.path.len - ".rel".len ..], ".zig");
            for (import_path) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            for (conversion.struct_names) |name| {
                try tables.append(arena, .{ .import_path = import_path, .name = name });
            }
        }

        // Collect relation edges for the cycle check, qualified by file path so
        // same-named structs in different files don't collide.  Resolution order
        // for the `to` side: if the target name is declared in THIS file (same
        // file), use this file's path; otherwise look it up in the import map
        // built from `const @@Name = @import("X.zig").@@Name;` declarations;
        // falling back to the bare name if the import isn't traceable.
        const import_map = try scanImports(arena, content, entry.path);
        for (conversion.struct_names) |name| {
            const qname = try std.fmt.allocPrint(arena, "{s}::{s}", .{ entry.path, name });
            if (!graph.contains(qname))
                try graph.put(qname, .empty);
        }
        for (conversion.relation_edges) |edge| {
            const qfrom = try std.fmt.allocPrint(arena, "{s}::{s}", .{ entry.path, edge.from });
            // Qualify the target: same file > import map > bare name.
            const qto = for (conversion.struct_names) |sn| {
                if (std.mem.eql(u8, sn, edge.to))
                    break try std.fmt.allocPrint(arena, "{s}::{s}", .{ entry.path, edge.to });
            } else if (import_map.get(edge.to)) |imp_rel|
                try std.fmt.allocPrint(arena, "{s}::{s}", .{ imp_rel, edge.to })
            else
                edge.to; // unresolved — best effort
            const gentry = try graph.getOrPut(qfrom);
            if (!gentry.found_existing) gentry.value_ptr.* = .empty;
            try gentry.value_ptr.append(arena, qto);
        }

        std.debug.print("{s} -> {s}\n", .{ entry.path, out_name });
        converted += 1;
    }

    // DFS cycle check across the whole relation graph.  Matches by bare struct
    // name — if two files happen to declare same-named structs, the check may
    // be slightly conservative (false positive) or miss a cross-file edge, but
    // that's an already-noted caveat (see CLAUDE.md).
    if (try findCycle(arena, &graph)) |cycle| {
        std.debug.print("error: relation cycle detected: ", .{});
        for (cycle, 0..) |name, idx| {
            if (idx != 0) std.debug.print(" -> ", .{});
            std.debug.print("{s}", .{name});
        }
        std.debug.print("\n", .{});
        return error.RelationCycle;
    }

    try copyRuntime(dir, io);
    try writeSquirrelAggregator(arena, dir, io, tables.items);

    std.debug.print("Done: {d} file(s) converted.\n", .{converted});
}
