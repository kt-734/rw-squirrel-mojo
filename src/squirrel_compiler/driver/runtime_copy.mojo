from std.os import listdir, makedirs
from std.os.path import dirname, isdir, isfile, join


def ensure_init_files(rel_files: List[String], target_root: String) raises:
    """Writes an empty `__init__.mojo` in every directory (below
    `target_root`, exclusive) that contains a converted file -- Mojo only
    treats a directory as an importable package if it has one (confirmed:
    `from sub.employee import EmployeeTableState` failed with "unable to
    locate module 'sub'" until `sub/__init__.mojo` existed), same
    requirement `squirrel_runtime`/`squirrel_compiler` already have.

    `target_root` itself never gets one, deliberately -- every generated
    file that reaches across directories (`sqrrl__world.mojo`/
    `sqrrl__json.mojo`'s own per-struct imports, a relation field's
    cross-file `Table`/`TableState`) does so via bare top-level names
    (`schema.person`, `sqrrl__EmployeeTable`) resolved against `target_root`
    itself as an `-I` search root -- an `__init__.mojo` sitting directly in
    that root would turn the root into a package in its own right, which
    breaks resolving any of its own flat sibling files as top-level modules
    (confirmed: `sqrrl__world.mojo` importing `schema.person` failed with
    "unable to locate module 'schema'" the moment `target_root`'s own
    `__init__.mojo` existed, in both `mojo run` and the language server).
    Trims a trailing slash first -- `dirname(path)` never has one, so
    `target_root` needing an exact string match against it would otherwise
    silently stop excluding the root the moment a caller passed one in
    (confirmed: `target_root` passed as `"examples/kitchen_sink/"` instead
    of `"examples/kitchen_sink"` never matched `dir`, so the loop walked
    one directory too far and wrote the exact `__init__.mojo` this is
    trying to prevent)."""
    var root = target_root
    if root.endswith("/"):
        root = String(root[byte=0 : root.byte_length() - 1])
    var seen = List[String]()
    for path in rel_files:
        var dir = dirname(path)
        while dir != root and dir not in seen:
            seen.append(dir)
            var init_path = join(dir, "__init__.mojo")
            if not isfile(init_path):
                var f = open(init_path, "w")
                f.close()
            dir = dirname(dir)


def copy_runtime(this_project_root: String, dest_root: String) raises:
    """Copies `squirrel_runtime`'s `.mojo` files into
    `dest_root/squirrel_runtime`, so generated files' `from
    squirrel_runtime...` imports resolve at the conversion root -- matching
    `main.zig`'s `copyRuntime`, but as a plain filesystem copy (reading from
    this project's own `src/squirrel_runtime`) rather than Zig's
    `@embedFile`-into-the-binary approach; this tool isn't distributed as a
    standalone binary yet, so there's nothing to embed into."""
    var src_dir = join(this_project_root, "src", "squirrel_runtime")
    var dest_dir = join(dest_root, "squirrel_runtime")
    _copy_tree(src_dir, dest_dir)


def _copy_tree(src_dir: String, dest_dir: String) raises:
    """Recursively copies every file and subdirectory under `src_dir` into
    `dest_dir`, mirroring the structure exactly -- so `squirrel_runtime`'s
    own package layout (e.g. `rel/` being a subpackage of several files,
    not a single flat one) never needs a maintained file list here that
    has to be kept in sync by hand whenever a file's added, removed, or
    renamed. Mirrors `find_rel_files`/`_collect_rel_files`'s own
    `listdir`/`isdir` recursion above, just copying instead of collecting."""
    makedirs(dest_dir, exist_ok=True)
    for entry in listdir(src_dir):
        var src_path = join(src_dir, entry)
        var dest_path = join(dest_dir, entry)
        if isdir(src_path):
            _copy_tree(src_path, dest_path)
        else:
            var f = open(src_path, "r")
            var content = f.read()
            f.close()

            var out = open(dest_path, "w")
            out.write(content)
            out.close()


