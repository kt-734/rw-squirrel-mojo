from squirrel_compiler.parser import ParsedStruct, Field, FieldModifier
from squirrel_compiler.codegen.helpers import emit_field_type, emit_multi_element_type


def _fold_body(
    agg_kind: String, y_name: String, y_field_type: String, ids_expr: String, indent: String, assign_prefix: String
) -> String:
    """Emits the fold computing `agg_kind` (`sum`/`avg`/`min`/`max`/
    `median`) over field `y_name`'s forward-store values across
    `ids_expr` (an already non-empty `List[UInt32]`), storing the result
    via `assign_prefix` (`"return "` for the `_for_` singular form,
    `"out[entry.key] = "` for the `_by_` all-groups form) -- shared
    across both, and across every `X` modifier that reaches it (`unique`
    is trivial enough it never calls this at all, see `_emit_pair`),
    since folding over an already-materialized `List[UInt32]` looks
    identical regardless of which `Rel` variant originally produced those
    ids. Starts from the first id's own value rather than a constructed
    zero/identity value -- `Y`'s declared type is trusted (same as
    `ordered`/`unique` are trusted for `Comparable`/`Hashable`) to
    support `+`/`<`/`>`, but never assumed to support construction from
    an integer literal too, which a zero-initialized accumulator would
    require. `get_fwd(...)` returns an `Optional[T]` and `.take()` needs
    a mutable binding -- can't chain `.get_fwd(...).take()` directly on
    the rvalue it returns (confirmed: Mojo rejects that as "invalid use
    of mutating method on rvalue"), so every fetch binds to a named `var`
    first, matching how `get_<field>` itself already does this two-step
    (`var got = ...get_fwd(...); return got.take()`).

    `median` is the one kind here that isn't a running fold at all --
    finding a middle element needs every value collected and sorted
    first, not just compared one at a time against a running result, so
    it takes its own branch below (`y_field_type` exists on this
    signature only for that branch's `List[y_field_type]`). This is the
    *slow* path -- collect then sort, O(k log k) for a group of size k --
    used for a `stats`-only `y` (no maintained order to lean on at all)
    and for every `_for_` call regardless of `y`'s own modifiers
    (touching only the one group asked about beats re-deriving anything
    from a whole-table structure sized for every group at once, see
    `_emit_for_variant`'s own doc comment). An `ordered` `y`'s
    whole-table and `_by_` medians skip this entirely -- see
    `_emit_median_whole_table_fast`/`_emit_median_by_fast`, which read
    `OrderedRel.sorted_ids()` (already maintained on every `put`/
    `update`) instead of re-sorting from scratch."""
    if agg_kind == "median":
        var out = String()
        out += indent + "var sqrrl__values = List[" + y_field_type + "]()\n"
        out += indent + "for sqrrl__id in " + ids_expr + ":\n"
        out += (
            indent
            + "    var sqrrl__opt = self.table.state[].state."
            + y_name
            + ".get_fwd(sqrrl__id)\n"
        )
        out += indent + "    sqrrl__values.append(sqrrl__opt.take())\n"
        out += indent + "sort(sqrrl__values)\n"
        out += indent + assign_prefix + "sqrrl__values[len(sqrrl__values) // 2]\n"
        return out

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
    out += _fold_body(agg_kind, y.name, y_field_type, "sqrrl__ids", "        ", "return ")
    return out


def _emit_median_by_fast(y: Field, x: Field, y_field_type: String) -> String:
    """`median_<y>_by_<x>() -> Dict[XKeyType, ResultType]` for an `ordered`
    `y` grouped by a non-`multi` `x` -- one linear walk of `y`'s own
    `OrderedRel.sorted_ids()` (already in `y`-order), appending each id
    into a per-`x`-value bucket as it goes, rather than the general
    `_by_` path's per-bucket materialize-then-sort (`_fold_body`'s
    `median` branch, O(k log k) per group). A subsequence of an
    already-sorted sequence is still sorted, so every bucket comes out
    `y`-ordered for free -- picking each one's middle element afterward
    is O(1). Requires `x` not `multi`: a `multi` `x`'s `get_fwd(id)`
    returns a *set* of values, not one, so a single id can belong to
    several buckets at once -- the one-value-per-id bucketing this
    function does breaks down there, and it falls back to the general
    `_by_` path instead (see `_emit_by_variant`)."""
    var out = String()
    var method_name = "median_" + y.name + "_by_" + x.name
    var x_key_type = emit_field_type(x)
    out += String(t"    def {method_name}(self) -> Dict[{x_key_type}, {y_field_type}]:\n")
    out += String(t"        ref sqrrl__sorted = self.table.state[].state.{y.name}.sorted_ids()\n")
    out += String(t"        var sqrrl__buckets = Dict[{x_key_type}, List[UInt32]]()\n")
    out += "        for sqrrl__id in sqrrl__sorted:\n"
    out += String(t"            var sqrrl__xopt = self.table.state[].state.{x.name}.get_fwd(sqrrl__id)\n")
    out += "            var sqrrl__xval = sqrrl__xopt.take()\n"
    out += "            if sqrrl__xval not in sqrrl__buckets:\n"
    out += "                sqrrl__buckets[sqrrl__xval.copy()] = List[UInt32]()\n"
    out += "            try:\n"
    out += "                sqrrl__buckets[sqrrl__xval].append(sqrrl__id)\n"
    out += "            except:\n"
    out += String(t'                abort("{method_name}: unreachable Dict operation failure")\n')
    out += String(t"        var out = Dict[{x_key_type}, {y_field_type}]()\n")
    out += "        for entry in sqrrl__buckets.items():\n"
    out += String(
        t"            var sqrrl__opt = self.table.state[].state.{y.name}.get_fwd(entry.value[len(entry.value) // 2])\n"
    )
    out += "            out[entry.key] = sqrrl__opt.take()\n"
    out += "        return out^\n"
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
    construction, unlike `_for_`'s arbitrary caller-supplied value.

    `median` with an `ordered` `y` and a non-`multi` `x` dispatches to
    `_emit_median_by_fast` instead of the body below -- see its own doc
    comment for why that combination gets a genuinely faster
    implementation rather than just reusing this one's `_fold_body` call."""
    if agg_kind == "median" and y.modifier == FieldModifier.ORDERED and x.modifier != FieldModifier.MULTI:
        return _emit_median_by_fast(y, x, y_field_type)

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
    out += _fold_body(agg_kind, y.name, y_field_type, "sqrrl__ids", "            ", "out[entry.key] = ")
    out += "        return out^\n"
    return out


def _emit_median_whole_table_fast(y: Field, y_field_type: String) -> String:
    """`median_<y>() raises -> ResultType` for an `ordered` `y` -- reads
    the middle element straight out of `OrderedRel.sorted_ids()` (already
    maintained on every `put`/`update`), O(1) plus the length check,
    instead of the general whole-table path's O(n) id collection
    followed by an O(n log n) collect-and-sort (`_fold_body`'s `median`
    branch). The one aggregate whole-table variant that doesn't walk
    `id_count()`/`is_live()` at all -- `sorted_ids()` already only ever
    holds live ids (`fetch_remove_fwd`, called from `sqrrl__cleanup_
    relations` when an entity dies, keeps it in sync), so there's nothing
    that loop would filter out here anyway."""
    var out = String()
    var method_name = "median_" + y.name
    out += String(t"    def {method_name}(self) raises -> {y_field_type}:\n")
    out += String(t"        ref sqrrl__sorted = self.table.state[].state.{y.name}.sorted_ids()\n")
    out += String(
        t'        if len(sqrrl__sorted) == 0:\n'
        t'            raise Error("{method_name}: table has no entities")\n'
    )
    out += String(
        t"        var sqrrl__opt = self.table.state[].state.{y.name}.get_fwd(sqrrl__sorted[len(sqrrl__sorted) // 2])\n"
    )
    out += "        return sqrrl__opt.take()\n"
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
    uniformly across all four keeps them behaving the same way.

    `median` with an `ordered` `y` dispatches to
    `_emit_median_whole_table_fast` instead of the body below -- see its
    own doc comment."""
    if agg_kind == "median" and y.modifier == FieldModifier.ORDERED:
        return _emit_median_whole_table_fast(y, y_field_type)

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
    out += _fold_body(agg_kind, y.name, y_field_type, "sqrrl__ids", "        ", "return ")
    return out


def emit_aggregate_methods(parsed: ParsedStruct) -> String:
    """`sum_<y>_by_<x>`/`sum_<y>_for_<x>`/`sum_<y>` (and `avg_`/`min_`/
    `max_`/`median_` siblings) for every aggregatable field `y`
    (`stats`-marked, or `ordered` -- `ordered` alone already proves
    `Comparable`, earning `min_`/`max_`/`median_` for free; `stats`
    proves both `Comparable` and `+`, additionally earning `sum_`/`avg_`
    on top), paired with every groupable field `x` in the same struct
    (any modifier but `forwardonly`, which has no reverse index to group
    by at all) for the `_by_`/`_for_` siblings, plus one ungrouped,
    whole-table sibling per `y` alone. `x == y` is skipped for the paired
    siblings -- aggregating a field grouped by itself is degenerate
    (every entity in one of its own value-groups already holds that exact
    value). `median_` needs `Comparable` the same as `min_`/`max_` (to
    sort), so it's earned by the exact same `y` eligibility -- see
    `_emit_median_whole_table_fast`/`_emit_median_by_fast` for why an
    `ordered` `y` gets a faster implementation than a `stats`-only one
    for two of its three shapes."""
    var groupable = List[Field]()
    var aggregatable = List[Field]()
    for f in parsed.fields:
        if f.modifier != FieldModifier.FORWARD_ONLY:
            groupable.append(f.copy())
        if f.is_stats or f.modifier == FieldModifier.ORDERED:
            aggregatable.append(f.copy())

    var out = String()
    for y in aggregatable:
        var kinds = List[String]()
        if y.is_stats:
            kinds.append("sum")
            kinds.append("avg")
        kinds.append("min")
        kinds.append("max")
        kinds.append("median")
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
