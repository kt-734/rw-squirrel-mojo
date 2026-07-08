from squirrel_compiler.parser import TypeParam, TypeExpr, parse_type_expr
from std.memory import ArcPointer


def _emit_type_param_list(type_params: List[TypeParam]) -> String:
    """`[T: Bound, U: Bound2]`, or `""` if `type_params` is empty -- the
    generic-parameter suffix on a plain struct's own generated header
    (`emit_plain_struct`) and its `from_json` companion's own type-param
    list (`emit_plain_struct_from_json`), both immediately after the
    struct/function name, before the parenthesized trait list or value
    parameter list respectively."""
    if len(type_params) == 0:
        return ""
    var out = String("[")
    var first = True
    for tp in type_params:
        if not first:
            out += ", "
        first = False
        out += String(t"{tp.name}: {tp.bound}")
    out += "]"
    return out^


def _emit_type_arg_list(type_params: List[TypeParam]) -> String:
    """`[T, U]`, or `""` if `type_params` is empty -- the bare parameter
    *names* (no bounds), used wherever a generic plain struct's own
    declared parameters need to be supplied as concrete type arguments to
    itself (its `from_json` companion's own `-> Name[T, U]:` return type)
    rather than redeclared with their bounds."""
    if len(type_params) == 0:
        return ""
    var out = String("[")
    var first = True
    for tp in type_params:
        if not first:
            out += ", "
        first = False
        out += tp.name
    out += "]"
    return out^


def substitute_type_params_expr(
    t: TypeExpr, type_params: List[TypeParam], type_args: List[TypeExpr]
) -> TypeExpr:
    """Walks `t` (a parsed field type), replacing every `LEAF` node whose
    name matches one of `type_params`'s own names with the
    correspondingly-positioned entry in `type_args` -- e.g. substituting
    `T -> String` turns `List[T]` into `List[String]`. Leaves a
    `RELATION` node alone (never a type parameter's own name, since `@@T`
    isn't grammar this DSL accepts) and a `PARAMETERIZED` node's own
    wrapper name alone too (`List`, `Dict`, a plain struct's own name),
    recursing only into `args`. Falls back to leaving a parameter's own
    name bare if `type_args` doesn't have a correspondingly-positioned
    entry (a malformed instantiation with too few type arguments) --
    this function's job is to emit useful Mojo, not validate arity; a
    genuinely wrong arity surfaces as an ordinary Mojo compile error
    downstream instead. The shared walk behind `qualify_type_params_with_self`
    (substituting each parameter with its own `Self.`-qualified name) and
    `driver.build_json_container_types` substituting a generic plain
    struct's own field types at a concrete instantiation, `TypeExpr`-to-
    `TypeExpr` with no render-then-reparse round trip in between."""
    if t.kind == TypeExpr.LEAF:
        for idx in range(len(type_params)):
            if type_params[idx].name == t.name:
                if idx < len(type_args):
                    return type_args[idx].copy()
                return t.copy()
        return t.copy()
    if t.kind == TypeExpr.PARAMETERIZED:
        var new_args = List[ArcPointer[TypeExpr]]()
        for i in range(t.arg_count()):
            new_args.append(ArcPointer(substitute_type_params_expr(t.arg(i), type_params, type_args)))
        return TypeExpr(kind=TypeExpr.PARAMETERIZED, name=t.name, args=new_args^)
    return t.copy()


def qualify_type_params_with_self(type_str: String, type_params: List[TypeParam]) -> String:
    """Replaces every whole-word occurrence of one of `type_params`'s own
    names within `type_str` with `Self.<name>` -- Mojo requires a generic
    struct's own fields/methods to refer to its own type parameter this
    way (confirmed: `var value: T` inside `struct Box[T]:`'s own body
    raises "unqualified access to struct parameter 'T'; use 'Self.T'
    instead", even nested inside a container like `List[T]`), unlike a
    *free function's* own type parameter, which stays bare
    (`emit_plain_struct_from_json`'s generated `from_json` companion is
    always a free function, never a method, so it never needs this --
    confirmed the reverse case, a free function referencing its own type
    parameter bare, compiles and runs correctly with no qualification at
    all). No-op (and skipped entirely) when `type_params` is empty, the
    overwhelmingly common, non-generic case. Just `substitute_type_params_expr`
    substituting each parameter with its own `Self.`-qualified name."""
    if len(type_params) == 0:
        return type_str
    var self_args = List[TypeExpr]()
    for tp in type_params:
        self_args.append(TypeExpr(kind=TypeExpr.LEAF, name="Self." + tp.name, args=List[ArcPointer[TypeExpr]]()))
    return substitute_type_params_expr(parse_type_expr(type_str), type_params, self_args).render()


