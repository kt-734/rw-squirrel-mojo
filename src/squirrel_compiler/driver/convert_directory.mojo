from std.os.path import join
from squirrel_compiler.parser import TypeParam
from squirrel_compiler.driver.file_paths import find_rel_files, module_path_for, mojo_output_path
from squirrel_compiler.driver.discovery import (
    discover_structs,
    build_relation_schema,
    build_unique_fields,
    build_ordered_fields,
    build_multi_fields,
    build_plain_struct_fields,
)
from squirrel_compiler.driver.json_container_types import (
    build_relation_targets,
    build_json_container_types,
    build_json_module_source,
)
from squirrel_compiler.driver.misc_builders import (
    build_function_returns,
    discover_plain_structs,
    discover_hand_written_plain_structs,
    check_single_declare_call,
)
from squirrel_compiler.driver.cycles import check_no_relation_cycles
from squirrel_compiler.driver.cross_file_symbols import build_cross_file_symbols
from squirrel_compiler.driver.world_module import emit_world_module
from squirrel_compiler.driver.emit_file import emit_file
from squirrel_compiler.driver.runtime_copy import ensure_init_files, copy_runtime


def convert_directory(target_root: String) raises:
    """Walks `target_root` for `.rel` files, writes a generated `.mojo` file
    alongside each one (resolving cross-file relation imports along the
    way), writes the project-wide `sqrrl__world.mojo`
    (`emit_world_module`), and writes `squirrel_runtime` into `target_root`
    from `copy_runtime`'s embedded copy. Mirrors `main.zig`'s `pub fn
    main`, minus the init/deinit aggregator -- `sqrrl__World` is a plain
    instance a script obtains via `@@init()` and threads by hand, so
    there's no static lifecycle to aggregate."""
    var rel_files = find_rel_files(target_root)
    var discovery = discover_structs(rel_files, target_root)
    var plain_structs = discover_plain_structs(rel_files, target_root)
    var hand_written_plain_structs = discover_hand_written_plain_structs(rel_files, target_root)
    var cycle_check_plain_structs = plain_structs.copy()
    for hw in hand_written_plain_structs:
        cycle_check_plain_structs.append(hw.copy())
    check_no_relation_cycles(discovery, cycle_check_plain_structs)
    check_single_declare_call(rel_files)
    ensure_init_files(rel_files, target_root)
    var plain_struct_type_params = Dict[String, List[TypeParam]]()
    var plain_struct_fields = build_plain_struct_fields(plain_structs, rel_files, plain_struct_type_params)
    var relation_schema = build_relation_schema(discovery, plain_struct_fields)
    var function_returns = build_function_returns(rel_files)
    var unique_fields = build_unique_fields(discovery)
    var ordered_fields = build_ordered_fields(discovery)
    var multi_fields = build_multi_fields(discovery)
    var cross_file_symbols = build_cross_file_symbols(discovery, rel_files, target_root)
    var relation_targets = build_relation_targets(discovery, plain_struct_fields)

    var world_module = emit_world_module(discovery, relation_targets)
    var world_path = join(target_root, "sqrrl__world.mojo")
    var sf = open(world_path, "w")
    sf.write(world_module)
    sf.close()

    var plain_struct_dispatch_types = List[String]()
    var json_container_types = build_json_container_types(
        discovery, plain_structs, plain_struct_fields, plain_struct_type_params, plain_struct_dispatch_types
    )
    var json_module = build_json_module_source(
        discovery,
        json_container_types,
        plain_struct_dispatch_types,
        plain_struct_fields,
        plain_struct_type_params,
        cross_file_symbols,
    )
    var json_path = join(target_root, "sqrrl__json.mojo")
    var jf = open(json_path, "w")
    jf.write(json_module)
    jf.close()

    var converted = 0
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var generated = emit_file(
            path,
            module_path,
            discovery,
            relation_schema,
            function_returns,
            unique_fields,
            ordered_fields,
            cross_file_symbols,
            plain_struct_fields,
            relation_targets,
            multi_fields,
        )
        var out_path = mojo_output_path(path)

        var f = open(out_path, "w")
        f.write(generated)
        f.close()

        print(path, "->", out_path)
        converted += 1

    copy_runtime(target_root)
    print("Done:", converted, "file(s) converted.")
