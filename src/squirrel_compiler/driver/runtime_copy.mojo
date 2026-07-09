from std.os import makedirs
from std.os.path import dirname, isfile, join

from squirrel_compiler.driver.embedded_runtime import embedded_runtime_files


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


def copy_runtime(dest_root: String) raises:
    """Writes `squirrel_runtime`'s `.mojo` files into
    `dest_root/squirrel_runtime`, so generated files' `from
    squirrel_runtime...` imports resolve at the conversion root -- matching
    `main.zig`'s `copyRuntime`, from `embedded_runtime_files()` (generated
    by `tools/generate_embedded_runtime.mojo`, baked into the compiler
    itself at build time) rather than a plain filesystem copy: this way a
    `mojo build`-produced executable is fully standalone -- runnable from
    any working directory, copied anywhere -- with no dependency on this
    project's own source tree existing on disk alongside it, the same
    guarantee Zig's `@embedFile` gave the original version of this tool."""
    var dest_dir = join(dest_root, "squirrel_runtime")
    for entry in embedded_runtime_files().items():
        var dest_path = join(dest_dir, entry.key)
        makedirs(dirname(dest_path), exist_ok=True)
        var out = open(dest_path, "w")
        out.write(entry.value)
        out.close()


