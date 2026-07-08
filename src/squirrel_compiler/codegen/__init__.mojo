from squirrel_compiler.codegen.helpers import (
    sqrrl_prefixed,
    emit_field_type,
    emit_multi_element_type,
    emit_rel_type,
    encode_container_type,
    is_container_type,
    container_wrapper_of,
    container_element_of,
)
from squirrel_compiler.codegen.table import emit_table
from squirrel_compiler.codegen.table_json import (
    relation_targets_for,
    emit_table_json_methods,
    emit_plain_struct_from_json,
)
from squirrel_compiler.codegen.generics import (
    qualify_type_params_with_self,
    substitute_type_params_expr,
)
from squirrel_compiler.codegen.plain_struct import (
    emit_plain_struct,
    recover_relation_type_str,
)
from squirrel_compiler.codegen.json_module import emit_json_module
from squirrel_compiler.codegen.rewrite import rewrite_markers
from squirrel_compiler.codegen.transform import transform_source
