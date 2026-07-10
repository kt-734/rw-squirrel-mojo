from squirrel_compiler.parser import ParsedStruct, Field, FieldModifier
from squirrel_compiler.codegen.helpers import emit_field_type, emit_multi_element_type


def _fold_body(agg_kind: String, y_name: String, ids_expr: String, indent: String, assign_prefix: String) -> String:
    """Emits the fold computing `agg_kind` (`sum`/`avg`/`min`/`max`) over
    field `y_name`'s forward-store values across `ids_expr` (an already
    non-empty `List[UInt32]`), storing the result via `assign_prefix`
    (`"return "` for the `_for_` singular form, `"out[entry.key] = "` for
    the `_by_` all-groups form) -- shared across both, and across every
    `X` modifier that reaches it (`unique` is trivial enough it never
    calls this at all, see `_emit_pair`), since folding over an
    already-materialized `List[UInt32]` looks identical regardless of
    which `Rel` variant originally produced those ids. Starts from the
    first id's own value rather than a constructed zero/identity value --
    `Y`'s declared type is trusted (same as `ordered`/`unique` are
    trusted for `Comparable`/`Hashable`) to support `+`/`<`/`>`, but never
    assumed to support construction from an integer literal too, which a
    zero-initialized accumulator would require. `get_fwd(...)` returns an
    `Optional[T]` and `.take()` needs a mutable binding -- can't chain
    `.get_fwd(...).take()` directly on the rvalue it returns (confirmed:
    Mojo rejects that as "invalid use of mutating method on rvalue"), so
    every fetch binds to a named `var` first, matching how `get_<field>`
    itself already does this two-step (`var got = ...get_fwd(...); return
    got.take()`)."""
    var get_fwd = String("self.table.state[].state.") + y_name + ".get_fwd(" + ids_expr + "["
    var out = String()
    out += indent + "var sqrrl__opt = " + get_fwd + "0])\n"
    out += indent + "var sqrrl__result = sqrrl__opt.take()\n"
    if agg_kind == "min" or agg_kind == "max":
        var op = "<" if agg_kind == "min" else ">"
        out += indent + "for sqrrl__i in range(1, len(" + ids_expr + ")):\n"
        out += indent + "    var sqrrl__opt2 = " + get_fwd + "sqrrl__i])\n"
        out += indent + "    var sqrrl__v = sqrrl__opt2.take()\n"
        out += indent + "    if sqrrl__v " + op + " sqrrl__result:\n"
        out += indent + "        sqrrl__result = sqrrl__v\n"
        out += indent + assign_prefix + "sqrrl__result\n"
    elif agg_kind == "avg":
        out += indent + "for sqrrl__i in range(1, len(" + ids_expr + ")):\n"
        out += indent + "    var sqrrl__opt2 = " + get_fwd + "sqrrl__i])\n"
        out += indent + "    sqrrl__result = sqrrl__result + sqrrl__opt2.take()\n"
        out += indent + assign_prefix + "Float64(sqrrl__result) / Float64(len(" + ids_expr + "))\n"
    else:  # sum
        out += indent + "for sqrrl__i in range(1, len(" + ids_expr + ")):\n"
        out += indent + "    var sqrrl__opt2 = " + get_fwd + "sqrrl__i])\n"
        out += indent + "    sqrrl__result = sqrrl__result + sqrrl__opt2.take()\n"
        out += indent + assign_prefix + "sqrrl__result\n"
    return out


def _materialize_ids(bucket_expr: String, indent: String) -> String:
    """`sqrrl__ids: List[UInt32]`, collected from `bucket_expr` (a
    `Set[UInt32]` or `List[UInt32]`) -- normalizes either shape to one
    indexable form, so `_fold_body`'s `ids_expr[0]`/`ids_expr[i]` works
    regardless of which `Rel` variant `bucket_expr` came from (`Set`
    itself isn't indexable in Mojo, unlike `List`)."""
    var out = String()
    out += indent + "var sqrrl__ids = List[UInt32]()\n"
    out += indent + "for sqrrl__id in " + bucket_expr + ":\n"
    out += indent + "    sqrrl__ids.append(sqrrl__id)\n"
    return out


def _result_type(agg_kind: String, y_field_type: String) -> String:
    if agg_kind == "avg":
        return "Float64"
    return y_field_type


def _emit_for_variant(
    agg_kind: String,
    y: Field,
    x: Field,
    y_field_type: String,
) -> String:
    """`{agg}_<y>_for_<x>(value) raises -> ResultType` -- the single-value
    sibling of `_by_`, mirroring `for_<field>`/`count_<field>` sitting
    alongside `group_by_<field>`/`count_by_<field>`: only pays for the one
    group asked about, via `x`'s own `get_bwd(value)`, rather than every
    bucket. `unique` x is trivial (`get_bwd` already raises on no match,
    and a group of exactly one id makes every one of sum/avg/min/max the
    same single value); every other modifier can hit a genuinely empty
    bucket (an arbitrary caller-supplied `value` nothing holds), so those
    raise explicitly instead -- there's no sensible non-raising default
    for avg/min/max of nothing, and raising uniformly (rather than only
    for those three) keeps all four siblings behaving the same way."""
    var out = String()
    var method_name = agg_kind + "_" + y.name + "_for_" + x.name
    var result_type = _result_type(agg_kind, y_field_type)
    if x.modifier == FieldModifier.UNIQUE:
        var x_field_type = emit_field_type(x)
        out += String(t"    def {method_name}(self, value: {x_field_type}) raises -> {result_type}:\n")
        out += String(t"        var sqrrl__id = self.table.state[].state.{x.name}.get_bwd(value)\n")
        out += String(t"        var sqrrl__opt = self.table.state[].state.{y.name}.get_fwd(sqrrl__id)\n")
        if agg_kind == "avg":
            out += "        return Float64(sqrrl__opt.take())\n"
        else:
            out += "        return sqrrl__opt.take()\n"
        return out

    var x_value_type: String
    if x.modifier == FieldModifier.MULTI:
        x_value_type = emit_multi_element_type(x)
    else:
        x_value_type = emit_field_type(x)
    out += String(t"    def {method_name}(self, value: {x_value_type}) raises -> {result_type}:\n")
    out += _materialize_ids(
        String("self.table.state[].state.") + x.name + ".get_bwd(value)", "        "
    )
    out += String(
        t'        if len(sqrrl__ids) == 0:\n'
        t'            raise Error("{method_name}: no entities found for this value")\n'
    )
    out += _fold_body(agg_kind, y.name, "sqrrl__ids", "        ", "return ")
    return out


def _emit_by_variant(
    agg_kind: String,
    y: Field,
    x: Field,
    y_field_type: String,
) -> String:
    """`{agg}_<y>_by_<x>() -> Dict[XKeyType, ResultType]` -- every group at
    once, walking `x`'s own `all_bwd()` the same way `group_by_<field>`/
    `count_by_<field>` already do (`ref` for `Rel`/`UniqueRel`/`MultiRel`,
    `var` for `OrderedRel`'s own owned rebuild -- see `all_bwd`'s doc
    comments in `squirrel_runtime.rel`). Never needs to raise -- every
    bucket `all_bwd()` hands back already has at least one id in it by
    construction, unlike `_for_`'s arbitrary caller-supplied value."""
    var out = String()
    var method_name = agg_kind + "_" + y.name + "_by_" + x.name
    var result_type = _result_type(agg_kind, y_field_type)

    if x.modifier == FieldModifier.UNIQUE:
        var x_field_type = emit_field_type(x)
        out += String(t"    def {method_name}(self) -> Dict[{x_field_type}, {result_type}]:\n")
        out += String(t"        ref sqrrl__ids = self.table.state[].state.{x.name}.all_bwd()\n")
        out += String(t"        var out = Dict[{x_field_type}, {result_type}]()\n")
        out += "        for entry in sqrrl__ids.items():\n"
        out += String(t"            var sqrrl__opt = self.table.state[].state.{y.name}.get_fwd(entry.value)\n")
        if agg_kind == "avg":
            out += "            out[entry.key] = Float64(sqrrl__opt.take())\n"
        else:
            out += "            out[entry.key] = sqrrl__opt.take()\n"
        out += "        return out^\n"
        return out

    var x_key_type: String
    var binding: String
    if x.modifier == FieldModifier.MULTI:
        x_key_type = emit_multi_element_type(x)
        binding = "ref"
    elif x.modifier == FieldModifier.ORDERED:
        x_key_type = emit_field_type(x)
        binding = "var"
    else:
        x_key_type = emit_field_type(x)
        binding = "ref"

    out += String(t"    def {method_name}(self) -> Dict[{x_key_type}, {result_type}]:\n")
    out += String(t"        {binding} sqrrl__buckets = self.table.state[].state.{x.name}.all_bwd()\n")
    out += String(t"        var out = Dict[{x_key_type}, {result_type}]()\n")
    out += "        for entry in sqrrl__buckets.items():\n"
    out += _materialize_ids("entry.value", "            ")
    out += _fold_body(agg_kind, y.name, "sqrrl__ids", "            ", "out[entry.key] = ")
    out += "        return out^\n"
    return out


def _emit_whole_table_variant(agg_kind: String, y: Field, y_field_type: String) -> String:
    """`{agg}_<y>() raises -> ResultType` -- every live entity in the
    table, no grouping field at all, mirroring `count()` sitting
    alongside `count_<field>`/`count_by_<field>`: the same
    `id_count()`/`is_live` walk `Table.all()` itself uses, but building no
    `EntityHandle` at all (not even a discarded one) -- there's no
    grouping field's own reverse index to piggyback on here, so this is
    the most direct route to every live id regardless. Raises on an empty
    table, same reasoning as `_for_`'s empty-bucket case: there's no
    sensible non-raising default for avg/min/max of nothing, and raising
    uniformly across all four keeps them behaving the same way."""
    var out = String()
    var method_name = agg_kind + "_" + y.name
    var result_type = _result_type(agg_kind, y_field_type)
    out += String(t"    def {method_name}(self) raises -> {result_type}:\n")
    out += "        var sqrrl__ids = List[UInt32]()\n"
    out += "        for sqrrl__i in range(self.table.state[].id_count()):\n"
    out += "            var sqrrl__id = UInt32(sqrrl__i)\n"
    out += "            if self.table.state[].is_live(sqrrl__id):\n"
    out += "                sqrrl__ids.append(sqrrl__id)\n"
    out += String(
        t'        if len(sqrrl__ids) == 0:\n'
        t'            raise Error("{method_name}: table has no entities")\n'
    )
    out += _fold_body(agg_kind, y.name, "sqrrl__ids", "        ", "return ")
    return out


def emit_aggregate_methods(parsed: ParsedStruct) -> String:
    """`sum_<y>_by_<x>`/`sum_<y>_for_<x>`/`sum_<y>` (and `avg_`/`min_`/
    `max_` siblings) for every aggregatable field `y` (`math`-marked, or
    `ordered` -- `ordered` alone already proves `Comparable`, earning
    `min_`/`max_` for free; `math` proves both `Comparable` and `+`,
    earning all four), paired with every groupable field `x` in the same
    struct (any modifier but `forwardonly`, which has no reverse index to
    group by at all) for the `_by_`/`_for_` siblings, plus one ungrouped,
    whole-table sibling per `y` alone. `x == y` is skipped for the paired
    siblings -- aggregating a field grouped by itself is degenerate
    (every entity in one of its own value-groups already holds that exact
    value)."""
    var groupable = List[Field]()
    var aggregatable = List[Field]()
    for f in parsed.fields:
        if f.modifier != FieldModifier.FORWARD_ONLY:
            groupable.append(f.copy())
        if f.is_math or f.modifier == FieldModifier.ORDERED:
            aggregatable.append(f.copy())

    var out = String()
    for y in aggregatable:
        var kinds = List[String]()
        if y.is_math:
            kinds.append("sum")
            kinds.append("avg")
        kinds.append("min")
        kinds.append("max")
        var y_field_type = emit_field_type(y)
        for agg_kind in kinds:
            out += "\n"
            out += _emit_whole_table_variant(agg_kind, y, y_field_type)
        for x in groupable:
            if x.name == y.name:
                continue
            for agg_kind in kinds:
                out += "\n"
                out += _emit_by_variant(agg_kind, y, x, y_field_type)
                out += "\n"
                out += _emit_for_variant(agg_kind, y, x, y_field_type)
    return out
