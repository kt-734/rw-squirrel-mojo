from std.os import listdir
from std.os.path import isdir, isfile, join


def find_rel_files(root: String) raises -> List[String]:
    """Recursively finds every `.rel` file under `root`, depth-first,
    returning full paths (root-relative, joined via `os.path.join`)."""
    var out = List[String]()
    _collect_rel_files(root, out)
    return out^


def _collect_rel_files(dir: String, mut out: List[String]) raises:
    for entry in listdir(dir):
        var full = join(dir, entry)
        if isdir(full):
            _collect_rel_files(full, out)
        elif isfile(full) and entry.endswith(".rel"):
            out.append(full)


def mojo_output_path(rel_path: String) -> String:
    """`foo/bar.rel` -> `foo/bar.mojo`, written alongside the source file,
    matching the Zig converter's `stem ++ ".zig"` convention."""
    return String(rel_path[byte = 0 : rel_path.byte_length() - String(".rel").byte_length()]) + ".mojo"


def module_path_for(rel_path: String, target_root: String) -> String:
    """`sub/employee.rel` (rooted at `target_root`) -> `sub.employee`, the
    dotted Mojo module path a cross-file relation import needs."""
    var root_prefix = target_root
    if not root_prefix.endswith("/"):
        root_prefix += "/"
    var relative = rel_path
    if relative.startswith(root_prefix):
        relative = String(relative.removeprefix(root_prefix))
    var without_ext = String(
        relative[byte = 0 : relative.byte_length() - String(".rel").byte_length()]
    )
    return without_ext.replace("/", ".")


