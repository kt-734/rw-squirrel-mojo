from squirrel_compiler.parser.text_utils import (
    source_location,
    line_indent_of,
    is_ident_char,
    is_after_arrow,
    is_after_for_keyword,
    is_after_container_bracket,
    is_unmarked_container_declaration,
)
from squirrel_compiler.parser.ast import (
    FieldModifier,
    Field,
    TypeParam,
    ParsedStruct,
    ConstructField,
    Construct,
    FieldAccess,
    NameRef,
    EntityParam,
    MarkerKind,
)
from squirrel_compiler.parser.scanner import Scanner, parse_construct_fields
from squirrel_compiler.parser.relation_type_text import (
    is_wrapped_relation_type,
    relation_target_of,
    relation_wrapper_of,
)
from squirrel_compiler.parser.field_parsing import (
    parse_fields,
    unqualify_self_type_params,
    parse_hand_written_struct_fields,
)
from squirrel_compiler.parser.type_expr import TypeExpr, parse_type_expr
