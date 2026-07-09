from squirrel_compiler.parser import Field
from squirrel_compiler.codegen.rewrite import rewrite_markers


def transform_source(
    source: String,
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
    multi_fields: Dict[String, List[String]] = Dict[String, List[String]](),
) raises -> String:
    """Entry point for converting one whole `.rel` file: starts
    `entity_to_type`/`world_declared` fresh and hands off to
    `rewrite_markers`, which does the actual work (see its own doc comment
    for everything `@@`-marked it handles) -- kept as a separate, minimal
    wrapper so callers converting a full file don't need to know or care
    that the same core is also invoked recursively, per construct field,
    from `build_create_call`."""
    var entity_to_type = Dict[String, String]()
    var world_declared = False
    return rewrite_markers(
        source,
        relation_schema,
        function_returns,
        unique_fields,
        ordered_fields,
        plain_struct_fields,
        relation_targets,
        entity_to_type,
        world_declared,
        multi_fields,
    )
