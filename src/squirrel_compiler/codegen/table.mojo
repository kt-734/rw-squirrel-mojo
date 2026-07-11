from squirrel_compiler.parser import ParsedStruct, Field, FieldModifier
from squirrel_compiler.codegen.helpers import (
    sqrrl_prefixed,
    emit_field_type,
    emit_multi_element_type,
    emit_rel_type,
)
from squirrel_compiler.codegen.table_json import emit_table_json_methods
from squirrel_compiler.codegen.aggregates import emit_aggregate_methods


def _emit_for_and_count(field_name: String, state_name: String, value_type: String) -> String:
    """`for_<field>(value) -> Set[EntityHandle[...]]` + `count_<field>` --
    shared by `multi` (`value_type` the element type), `ordered`'s own
    exact-match pair (`value_type` the field type -- its five range-shaped
    siblings are a different shape entirely, not built here), and every
    plain field, since all three call the identical `.get_bwd(value)` on
    their own `Rel`/`MultiRel`/`OrderedRel` storage and turn the result
    into a `Set`, never a `List`: every id matching one exact value shares
    that value, with no meaningful order among them to preserve. A `List`
    there would let a caller write `@@matches[0]`/`@@matches[0].field =
    ...`, but that's not a real capability -- it's indexing into an
    arbitrary position, indistinguishable from `for @@m in @@matches: ...;
    break` on a `Set`, just terser and, worse, misleading (`[0]` reads
    like "the first one" when it's really "whichever one happened to land
    there"). `count_<field>` is `len(for_<field>(value))` without building
    a handle for every matching row just to throw it away right after."""
    var out = String()
    out += String(t"    def for_{field_name}(self, value: {value_type}) -> Set[EntityHandle[{state_name}]]:\n")
    out += String(t"        var ids = self.table.state[].state.{field_name}.get_bwd(value)\n")
    out += String(t"        var out = Set[EntityHandle[{state_name}]]()\n")
    out += "        for id in ids:\n"
    out += String(t"            out.add(self.table.handle_for(id))\n")
    out += "        return out^\n"
    out += "\n"
    out += String(t"    def count_{field_name}(self, value: {value_type}) -> Int:\n")
    out += String(t"        return len(self.table.state[].state.{field_name}.get_bwd(value))\n")
    return out


def _emit_group_by_and_count_by(
    field_name: String, state_name: String, key_type: String, binding: String
) -> String:
    """`group_by_<field>() -> Dict[KeyType, Set[EntityHandle[...]]]` +
    `count_by_<field>` -- shared by `multi` (`key_type` the element type,
    `binding` `"ref"` -- `MultiRel.all_bwd()` hands back a borrowed
    reference straight into the field's own storage), `ordered` (`key_type`
    the field type, `binding` `"var"` -- `OrderedRel.all_bwd()` has no
    `_bwd` dict to reference, so it's rebuilt fresh and owned each call,
    still ascending-ordered), and every plain field (`key_type` the field
    type, `binding` `"ref"`, same as `multi`). The *outer* `Dict`'s own
    iteration order is meaningful for `ordered` (ascending by value) --
    but each bucket's own `Set` never is, same reasoning as
    `_emit_for_and_count`: every id in one bucket shares the same value/
    membership fact, with nothing among themselves to order.
    `count_by_<field>` is `group_by_<field>` without ever building the
    `Set[EntityHandle[...]]` for each bucket, just `len()`-ing it."""
    var out = String()
    out += String(t"    def group_by_{field_name}(self) -> Dict[{key_type}, Set[EntityHandle[{state_name}]]]:\n")
    out += String(t"        {binding} buckets = self.table.state[].state.{field_name}.all_bwd()\n")
    out += String(t"        var out = Dict[{key_type}, Set[EntityHandle[{state_name}]]]()\n")
    out += "        for entry in buckets.items():\n"
    out += String(t"            var handles = Set[EntityHandle[{state_name}]]()\n")
    out += "            for id in entry.value:\n"
    out += String(t"                handles.add(self.table.handle_for(id))\n")
    out += "            out[entry.key] = handles^\n"
    out += "        return out^\n"
    out += "\n"
    out += String(t"    def count_by_{field_name}(self) -> Dict[{key_type}, Int]:\n")
    out += String(t"        {binding} buckets = self.table.state[].state.{field_name}.all_bwd()\n")
    out += String(t"        var out = Dict[{key_type}, Int]()\n")
    out += "        for entry in buckets.items():\n"
    out += "            out[entry.key] = len(entry.value)\n"
    out += "        return out^\n"
    return out


def _emit_distinct_set(field_name: String, value_type: String) -> String:
    """`distinct_<field>() -> Set[ValueType]` -- every distinct value
    currently in use, with no `EntityHandle` built at all. Shared by
    `multi`, `unique`, and every plain field. `ordered`'s own
    `distinct_<field>` returns `List`, not `Set` -- the ascending order is
    the whole point of `ordered` there (same reason its range-shaped
    `for_<field>_*` methods stay `List`-returning), so it's built inline
    instead of through this helper."""
    var out = String()
    out += String(t"    def distinct_{field_name}(self) -> Set[{value_type}]:\n")
    out += String(t"        var out = Set[{value_type}]()\n")
    out += String(t"        for key in self.table.state[].state.{field_name}.all_bwd().keys():\n")
    out += "            out.add(key)\n"
    out += "        return out^\n"
    return out


def emit_table(parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]) raises -> String:
    """Emits two generated structs per `@@struct`.

    - `sqrrl__NameTableState` -- implements `TableStateLike` (just one `Rel`
      per field, plus `sqrrl__cleanup_relations`), and is what
      `EntityHandle`/`Table` are actually parametrized by.
      `sqrrl__cleanup_relations` calls `fetch_remove_fwd` on every field and
      discards the result -- for a relation field, that drops the returned
      `EntityHandle`, decref'ing whatever it pointed to, which is what
      makes destroying an entity correctly release its relations instead of
      leaking them (see `TableStateLike`'s doc comment in `entity.mojo` for
      the concrete leak this closes). Id allocation itself lives on the
      runtime's `TableStorage` wrapper, not here -- it's mechanically
      identical for every table, so there's nothing table-specific to
      generate for it.
    - `sqrrl__NameTable` -- the user-facing wrapper, holding a
      `Table[sqrrl__NameTableState]` plus typed `create`/`get_*`/`set_*`/
      `for_*` methods delegating into it, via
      `self.table.state[].state.<field>` (the first `.state` is `Table`'s
      `ArcPointer` target, `TableStorage`; the second is `TableStorage`'s
      own field holding the generated state). `create`/`get_*`/`set_*`/
      `for_*` stay bare, unprefixed -- unlike the struct names and
      `cleanup_relations`, colliding with a `.rel` field literally named
      `create` (or `get_<fieldname>`) is an edge case narrow enough not to
      be worth the extra noise on every accessor.

    Every field, `unique` or not, also gets a reverse-lookup `for_<field>`
    built on the field's own `Rel`/`UniqueRel.get_bwd` (already indexing
    every value -> id(s), just unused before `for_*` existed to expose it):
    a plain field's `for_<field>(value)` returns every matching entity as a
    `Set[EntityHandle[...]]` (there can be several, with no meaningful
    order among them to preserve -- every one shares the identical value),
    while a `unique` field's returns a single `EntityHandle[...]` directly
    and raises if
    none matches -- reflecting that `UniqueRel.get_bwd` itself raises on a
    genuinely realistic condition (the value was never registered), which a
    plain `Rel.get_bwd` doesn't (it just returns an empty set). Both
    variants call `Table.handle_for(id)` (never
    `EntityHandle(EntityInner(_id=id, _table=...))` directly) to turn a bare
    id from `get_bwd` into a real handle -- fabricating one independently
    would create a second, uncoordinated owner over the same id, corrupting
    the entity's actual refcount (confirmed via a direct repro: doing that
    double-frees the id once the fabricated handle drops, even while a
    legitimate handle for it is still alive). `handle_for` instead upgrades
    a stored `WeakPointer`, sharing whatever handle(s) already exist rather
    than creating a new owner -- see its doc comment in `entity.mojo`.
    `handle_for` itself aborts rather than raises if the id turns out to be
    dead, matching `Rel.put`/`update`'s own invariant-violation convention:
    every id reaching it comes straight from a `get_bwd` whose _bwd index is
    only ever in sync with currently-live ids, so a dead one getting
    through would be a real bug, not recoverable bad input -- which is why
    only the `unique` `for_<field>` needs `raises` at all (from its own
    `UniqueRel.get_bwd`), not the plain one.

    `create` gains `raises` whenever *any* field is `unique` (a `put` on
    that field can raise); `set_<field>` gains it only for that field
    itself.

    Using `sqrrl__NameTableState` as the tag (not a separate marker type,
    and not `sqrrl__NameTable` itself) is what lets
    `EntityHandle[sqrrl__PersonTableState]` and
    `EntityHandle[sqrrl__EmployeeTableState]` be distinct,
    mutually-incompatible types with no duplicated runtime logic per
    `@@struct`."""
    var state_name = sqrrl_prefixed(parsed.name) + "TableState"
    var table_name = sqrrl_prefixed(parsed.name) + "Table"

    var out = String(t"struct {state_name}(TableStateLike, Movable, ImplicitlyDeletable):\n")
    for f in parsed.fields:
        out += String(t"    var {f.name}: {emit_rel_type(f)}\n")
    out += "\n"

    out += "    def __init__(out self):\n"
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        self.{f.name} = {emit_rel_type(f)}()\n")
    out += "\n"

    out += String(t"    def {sqrrl_prefixed('cleanup_relations')}(mut self, id: UInt32):\n")
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        _ = self.{f.name}.fetch_remove_fwd(id)\n")

    out += "\n\n"
    out += String(t"struct {table_name}(Movable):\n")
    out += String(t"    var table: Table[{state_name}]\n")
    if parsed.is_keepalive:
        out += String(t"    var keepalive: Set[EntityHandle[{state_name}]]\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    out += String(t"        self.table = Table[{state_name}]({state_name}())\n")
    if parsed.is_keepalive:
        out += String(t"        self.keepalive = Set[EntityHandle[{state_name}]]()\n")
    out += "\n"

    var any_unique = False
    for f in parsed.fields:
        if f.modifier == FieldModifier.UNIQUE:
            any_unique = True
            break

    out += "    def create(mut self"
    for f in parsed.fields:
        out += String(t", {f.name}: {emit_field_type(f)}")
    out += ")"
    if any_unique:
        # A single `create` sets every field in one body -- if *any* one of
        # them is `unique` (a `UniqueRel.put`, which is `raises`), the whole
        # function must be `raises` too, since Mojo requires that of any
        # caller of a `raises` method. `MultiRel.put` doesn't raise (a
        # `Set`-backed field can't hold a duplicate to reject in the first
        # place), so a `multi` field alone doesn't force this. Unlike
        # `set_<field>` below, there's no per-field granularity available
        # here: it's the same function for every field, not one function
        # each. `raises` must come before the `->`, not after (Mojo
        # syntax), unlike `set_<field>` which has no return type to worry
        # about ordering against.
        out += " raises"
    out += String(t" -> EntityHandle[{state_name}]:\n")
    out += "        var e = self.table.create()\n"
    for f in parsed.fields:
        out += String(t"        self.table.state[].state.{f.name}.put(e.id(), {f.name})\n")
    if parsed.is_keepalive:
        # `create` puts every new entity in `keepalive` by default -- the
        # actual point of the tag, letting it outlive whatever scope
        # constructed it without needing a relation elsewhere or a
        # long-lived local `var` to hold it alive. `.copy()` since `e`
        # itself is still returned below.
        out += "        self.keepalive.add(e.copy())\n"
    out += "        return e\n"
    out += "\n"

    # `sqrrl__create_with_id` -- `create`'s twin, for `sqrrl__world_from_json`
    # (see `emit_world_module`) reconstructing a `sqrrl__World` from a JSON
    # dump: a relation field elsewhere in the dump serializes as another
    # entity's exact original id, so recreating that entity has to land on
    # that same id, not whatever `Table.create`'s own auto-allocation would
    # hand out. Always `raises`, unlike `create` (conditionally `raises` only
    # if a `unique` field's `UniqueRel.put` could reject a duplicate) --
    # `Table.create_with_id` itself raises if the requested id is already
    # live.
    out += String(t"    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32")
    for f in parsed.fields:
        out += String(t", {f.name}: {emit_field_type(f)}")
    out += String(t") raises -> EntityHandle[{state_name}]:\n")
    out += "        var e = self.table.create_with_id(sqrrl__id)\n"
    for f in parsed.fields:
        out += String(t"        self.table.state[].state.{f.name}.put(e.id(), {f.name})\n")
    if parsed.is_keepalive:
        out += "        self.keepalive.add(e.copy())\n"
    out += "        return e\n"
    out += "\n"
    out += String(t"    def all(self) -> Set[EntityHandle[{state_name}]]:\n")
    out += "        return self.table.all()\n"
    out += "\n"
    # `count()` is `len(self.all())` without building a handle for every
    # live entity just to throw it away right after -- `Table.count()`
    # is O(1) (`IdAllocator.live_count()`, tracked from `free_list`'s own
    # size, not scanned).
    out += "    def count(self) -> Int:\n"
    out += "        return self.table.count()\n"
    if parsed.is_keepalive:
        out += "\n"
        out += String(
            t"    def dont_keepalive(mut self, e: EntityHandle[{state_name}]) -> Bool:\n"
        )
        out += "        try:\n"
        out += "            self.keepalive.remove(e)\n"
        out += "            return True\n"
        out += "        except:\n"
        out += "            return False\n"

        # Used only by `sqrrl__World.sqrrl__check_no_leaks`
        # (`driver.emit_world_module`) -- dropping every reference this
        # table's own `keepalive` set holds, all at once, right before that
        # check verifies nothing *else* is still keeping an entity alive.
        # Reassigns to a fresh `Set` rather than removing entries one at a
        # time; `Set` has no bulk-clear of its own here to call instead.
        out += "\n"
        out += String(t"    def sqrrl__clear_keepalive(mut self):\n")
        out += String(t"        self.keepalive = Set[EntityHandle[{state_name}]]()\n")

    # `value_eq` -- field-by-field comparison, deliberately *not*
    # `EntityHandle.__eq__` (id-based, needed as-is so `Rel[EntityHandle[
    # ...]]` can use it as a `_bwd` dict key -- repurposing it here would
    # break every relation field's own indexing). A relation field is
    # compared by its own `EntityHandle.__eq__` (id-based) here too, not
    # recursed into the target's own fields -- "points at the same row",
    # not "points at a row with the same content", matching how a foreign
    # key column's equality works in an ordinary relational database, and
    # avoiding walking the same relation graph `check_no_relation_cycles`
    # already bounds. Every field type needs to be `Equatable` for this to
    # compile -- not checked ahead of time here; a field type that isn't
    # fails with Mojo's own compile error at the `!=` below, same as
    # relying on Mojo's own definite-initialization checking elsewhere in
    # this codebase rather than duplicating a check it already does.
    #
    # Only generated for an `equatable`-tagged struct (`ParsedStruct`'s own
    # doc comment) -- unlike every other method in this file, `value_eq`
    # used to be unconditional, meaning *any* struct with a non-`Equatable`
    # field (most commonly an embedded plain struct, which doesn't derive
    # `Equatable` by default) carried this same compile failure regardless
    # of whether its own author ever wanted `value_eq` at all. Gating it
    # behind an explicit keyword confines that risk to only the structs
    # that actually ask for it, the same way `unique`/`ordered`/`stats`
    # already confine their own type-support risk to an opt-in field.
    if parsed.is_equatable:
        out += "\n"
        out += String(
            t"    def value_eq(self, a: EntityHandle[{state_name}],"
            t" b: EntityHandle[{state_name}]) -> Bool:\n"
        )
        if len(parsed.fields) == 0:
            out += "        return True\n"
        else:
            for f in parsed.fields:
                out += String(t"        if self.get_{f.name}(a) != self.get_{f.name}(b):\n")
                out += "            return False\n"
            out += "        return True\n"

    for f in parsed.fields:
        var field_type = emit_field_type(f)
        out += "\n"
        out += String(t"    def get_{f.name}(self, e: EntityHandle[{state_name}]) -> {field_type}:\n")
        out += String(t"        var got = self.table.state[].state.{f.name}.get_fwd(e.id())\n")
        out += "        return got.take()\n"
        out += "\n"
        out += String(t"    def set_{f.name}(mut self, e: EntityHandle[{state_name}], v: {field_type})")
        if f.modifier == FieldModifier.UNIQUE:
            out += " raises"
        out += ":\n"
        out += String(t"        self.table.state[].state.{f.name}.update(e.id(), v)\n")
        out += "\n"
        if f.modifier == FieldModifier.MULTI:
            # `add_to_<field>`/`remove_from_<field>` expose `MultiRel`'s own
            # single-element `add`/`remove` directly -- the actual
            # ergonomic point of `multi` being "add/remove one member",
            # not the get_<field>+copy+append+set_<field> round trip
            # every other collection-typed field needs. `for_<field>`
            # takes the bare *element* type here (`MultiRel.get_bwd`'s own
            # shape), not the whole field type `for_<field>` uses for
            # every other kind of field -- "which rows contain this one
            # member", the actual many-to-many reverse query.
            var element_type = emit_multi_element_type(f)
            out += String(
                t"    def add_to_{f.name}(mut self, e: EntityHandle[{state_name}], value: {element_type}) -> Bool:\n"
            )
            out += String(t"        return self.table.state[].state.{f.name}.add(e.id(), value)\n")
            out += "\n"
            out += String(
                t"    def remove_from_{f.name}(mut self, e: EntityHandle[{state_name}], value: {element_type}) -> Bool:\n"
            )
            out += String(t"        return self.table.state[].state.{f.name}.remove(e.id(), value)\n")
            out += "\n"
            out += _emit_for_and_count(f.name, state_name, element_type)
            out += "\n"
            out += _emit_group_by_and_count_by(f.name, state_name, element_type, "ref")
            out += "\n"
            out += _emit_distinct_set(f.name, element_type)
            continue
        if f.modifier == FieldModifier.FORWARD_ONLY:
            # `ForwardOnlyRel` has no `_bwd` reverse index (its value isn't
            # assumed `KeyElement`) and thus no `get_bwd` to build a
            # `for_<field>` from -- a `forwardonly` field only gets
            # `get_*`/`set_*` above, not a reverse lookup. A collection-typed
            # relation field *without* `forwardonly` still gets one like
            # any other field: it's backed by ordinary `Rel`/`UniqueRel`
            # (see `emit_rel_type`), so `get_bwd` exists.
            continue
        if f.modifier == FieldModifier.ORDERED:
            # `OrderedRel.get_bwd` (exact match, same name as every other
            # `Rel` variant's own reverse index) builds `for_<field>` here,
            # a binary search (`between(value, value)`) under the hood
            # rather than a hash lookup -- but returned as `Set`, same
            # reasoning (and the same return type) as every other field
            # kind's own exact-match `for_<field>` below: ids matching one
            # exact value have no meaningful order among themselves to
            # preserve, so there's nothing for a `List` to actually be
            # doing there beyond implying an order that isn't real. The
            # range-shaped methods below (`greater_than`/`less_than`/
            # `at_least`/`at_most`/`between`) stay `List`-returning, unlike
            # exact match -- their whole point is the sorted order
            # `_sorted` maintains, which a `Set` would throw away.
            out += _emit_for_and_count(f.name, state_name, field_type)
            for method_name in ["greater_than", "less_than", "at_least", "at_most"]:
                out += "\n"
                out += String(
                    t"    def for_{f.name}_{method_name}(self, value: {field_type}) -> List[EntityHandle[{state_name}]]:\n"
                )
                out += String(t"        var ids = self.table.state[].state.{f.name}.{method_name}(value)\n")
                out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
                out += "        for id in ids:\n"
                out += String(t"            out.append(self.table.handle_for(id))\n")
                out += "        return out^\n"
            out += "\n"
            out += String(
                t"    def for_{f.name}_between(self, low: {field_type}, high: {field_type}) ->"
                t" List[EntityHandle[{state_name}]]:\n"
            )
            out += String(t"        var ids = self.table.state[].state.{f.name}.between(low, high)\n")
            out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
            out += "        for id in ids:\n"
            out += String(t"            out.append(self.table.handle_for(id))\n")
            out += "        return out^\n"
            out += "\n"
            out += _emit_group_by_and_count_by(f.name, state_name, field_type, "var")
            out += "\n"
            # `distinct_<field>` is every distinct value currently in use,
            # with no `EntityHandle` built at all -- `List`, not `Set`,
            # unlike every other field kind's own `distinct_<field>`: the
            # ascending order is the whole point of `ordered` (same reason
            # the range-shaped `for_<field>_*` methods stay `List`-returning
            # rather than `Set`), so it's made explicit in the return type
            # itself rather than resting on `Set`'s own (real, but less
            # obviously-ordered-to-a-reader) iteration behavior.
            out += String(t"    def distinct_{f.name}(self) -> List[{field_type}]:\n")
            out += String(t"        var out = List[{field_type}]()\n")
            out += String(t"        for key in self.table.state[].state.{f.name}.all_bwd().keys():\n")
            out += "            out.append(key)\n"
            out += "        return out^\n"
            continue
        if f.modifier == FieldModifier.UNIQUE:
            out += String(t"    def for_{f.name}(self, value: {field_type}) raises -> EntityHandle[{state_name}]:\n")
            out += String(t"        var id = self.table.state[].state.{f.name}.get_bwd(value)\n")
            out += String(t"        return self.table.handle_for(id)\n")
            out += "\n"
            # `count_<field>` is the one genuinely *new* capability in this
            # group, not just a faster version of something already
            # possible: `for_<field>` *raises* if `value` isn't in use, so
            # there's no way today to ask "is this value taken" without a
            # try/except. `0`/`1`, via a plain `in` check against
            # `all_bwd()`'s own `_bwd` reference -- no raising, no handle
            # built either way.
            out += String(t"    def count_{f.name}(self, value: {field_type}) -> Int:\n")
            out += String(
                t"        return 1 if value in self.table.state[].state.{f.name}.all_bwd() else 0\n"
            )
            out += "\n"
            # `group_by_<field>` walks `UniqueRel.all_bwd()` -- every value
            # currently in use, each mapped to its own single id (by
            # construction of `unique`), so no `List`/`Set` wrapping is
            # needed the way every other field kind's `group_by_<field>`
            # does -- each group has exactly one member. `ref`, not `var`
            # -- see the `multi` branch's own comment above.
            out += String(
                t"    def group_by_{f.name}(self) -> Dict[{field_type}, EntityHandle[{state_name}]]:\n"
            )
            out += String(t"        ref ids = self.table.state[].state.{f.name}.all_bwd()\n")
            out += String(t"        var out = Dict[{field_type}, EntityHandle[{state_name}]]()\n")
            out += "        for entry in ids.items():\n"
            out += String(t"            out[entry.key] = self.table.handle_for(entry.value)\n")
            out += "        return out^\n"
            # No `count_by_<field>` for `unique` -- every group is exactly
            # 1 by construction, so it would carry zero information beyond
            # what `unique` already guarantees. Unlike `group_by_<field>`
            # (still useful here -- it's a real value -> entity lookup
            # table), a count that's always 1 isn't worth generating.
            out += "\n"
            # `distinct_<field>` *is* worth generating here, though --
            # "which values are currently taken" without paying for
            # `group_by_<field>`'s own `handle_for` call per value (a real
            # `WeakPointer` upgrade + `EntityHandle` construction each
            # time). This is the cheap way to ask that question for
            # `unique` specifically.
            out += _emit_distinct_set(f.name, field_type)
        else:
            # `Set`, not `List` -- every id matching an exact value shares
            # that identical value, so there's no meaningful order among
            # them to preserve (`Rel.get_bwd` itself is `Set[UInt32]`, an
            # arbitrary hash bucket). A `List` here would let a caller
            # write `@@matches[0]`/`@@matches[0].field = ...`, but that's
            # not a real capability -- it's indexing into an arbitrary
            # position, indistinguishable from `for @@m in @@matches:
            # ...; break` on a `Set`, just terser and, worse, misleading
            # (`[0]` reads like "the first one" when it's really "whichever
            # one happened to land there"). Matches `ordered`'s own
            # exact-match `for_<field>` (below), which already returns
            # `Set` for the identical reason -- range-shaped queries
            # (`_between`/`_greater_than`/...) stay `List`, since those
            # genuinely carry `_sorted`'s order.
            out += _emit_for_and_count(f.name, state_name, field_type)
            out += "\n"
            out += _emit_group_by_and_count_by(f.name, state_name, field_type, "ref")
            out += "\n"
            out += _emit_distinct_set(f.name, field_type)

    out += emit_aggregate_methods(parsed)

    out += "\n"
    out += emit_table_json_methods(parsed, state_name, plain_struct_fields)
    return out


