# Generated method reference

![](images/emblems/method.png){ align=right width="180" }

Every `@@struct` produces a `sqrrl__NameTable`, called as
`sqrrl__world.Name.<method>(...)` — every method below is unprefixed
(`create`, `get_<field>`, ...), regardless of the `sqrrl__`-prefixed names
the struct/table types themselves get. `<field>` is a field's own declared
name; `FieldType`/`ElementType` are that field's own declared type (or, for
`multi`, its bare element type — see below).

## Every struct

| method | signature | notes |
| --- | --- | --- |
| `create` | `(field1: T1, field2: T2, ...) -> EntityHandle[...]` | one parameter per field, in declared order; `raises` if *any* field is `unique` |
| `all` | `() -> Set[EntityHandle[...]]` | every currently-live entity in the table |
| `count` | `() -> Int` | `len(all())` without building a handle for every entity first — O(1) |
| `value_eq` | `(a, b) -> Bool` | field-by-field comparison — see [below](#value_eq) |
| `dont_keepalive` | `(e) -> Bool` | `keepalive`-tagged structs only — see [`keepalive`](dsl-guide.md#keepalive) |

## Every field

| method | signature | notes |
| --- | --- | --- |
| `get_<field>` | `(e) -> FieldType` | |
| `set_<field>` | `(e, v: FieldType)` | `raises` only if *this* field is `unique` |

## `for_<field>` — reverse lookup by value

| field is... | signature | behavior |
| --- | --- | --- |
| plain (no modifier) | `(value: FieldType) -> List[EntityHandle[...]]` | every entity currently holding exactly `value` |
| `unique` | `(value: FieldType) raises -> EntityHandle[...]` | the one entity holding `value`; raises if none does |
| `multi` | `(value: ElementType) -> List[EntityHandle[...]]` | every entity whose set *contains* `value` — bare element type, not the field's whole `Set[...]` type |
| `ordered` (exact match) | `(value: FieldType) -> Set[EntityHandle[...]]` | same shape as `all()` — matching ids have no meaningful order to preserve |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all |

`ordered` fields additionally get five range-shaped siblings, all `List`-returning (the sorted order is the whole point, which a `Set` would throw away):

| method | signature |
| --- | --- |
| `for_<field>_greater_than` | `(value: FieldType) -> List[EntityHandle[...]]` |
| `for_<field>_less_than` | `(value: FieldType) -> List[EntityHandle[...]]` |
| `for_<field>_at_least` | `(value: FieldType) -> List[EntityHandle[...]]` |
| `for_<field>_at_most` | `(value: FieldType) -> List[EntityHandle[...]]` |
| `for_<field>_between` | `(low: FieldType, high: FieldType) -> List[EntityHandle[...]]` |

A relation field (`@@dept: @@Department`) isn't a special case anywhere in
this table — it's an ordinary field whose `FieldType` happens to be
`EntityHandle[...]`.

## `count_<field>` — how many, without materializing

`len(for_<field>(value))` without building an `EntityHandle` for every
match first, just to `len()` and discard them.

| field is... | signature | behavior |
| --- | --- | --- |
| plain (no modifier) | `(value: FieldType) -> Int` | how many entities hold exactly `value` |
| `unique` | `(value: FieldType) -> Int` | `0` or `1` — the only non-raising way to ask "is this value taken"; `for_<field>` raises instead |
| `multi` | `(value: ElementType) -> Int` | how many entities' sets contain `value` — bare element type, like `for_<field>` |
| `ordered` (exact match) | `(value: FieldType) -> Int` | same exact-match semantics as `for_<field>` |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all |

`unique`'s `count_<field>` is the one genuinely new capability here, not
just a faster version of something already possible — every other row in
this table answers a question `for_<field>` could already answer, just
without the wasted `EntityHandle` construction.

## `group_by_<field>` — every value at once

`for_<field>` turned inside out: every value at once, mapped to its own
matching entities, instead of one value looked up at a time. It falls out
of what each field kind's storage already maintains internally (the same
reverse index `for_<field>` itself reads one bucket of), so it costs
nothing new to compute.

| field is... | signature | behavior |
| --- | --- | --- |
| plain (no modifier) | `() -> Dict[FieldType, List[EntityHandle[...]]]` | every value currently in use, mapped to every entity holding it |
| `unique` | `() -> Dict[FieldType, EntityHandle[...]]` | every value mapped to its own single entity — no `List` wrapping |
| `multi` | `() -> Dict[ElementType, List[EntityHandle[...]]]` | every element mapped to every entity whose set contains it — keyed by the bare element type |
| `ordered` | `() -> Dict[FieldType, List[EntityHandle[...]]]` | same shape as plain, but iteration visits values in ascending order |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all |

`group_by_<field>` only gives you *one* direction of a `multi` relation —
"for each element, every row whose set contains it." The other direction
("for each row, its own member set") isn't a new method: it's just
`get_<field>` on a value you already have, or `all()` plus `get_<field>`
per row for every row at once.

## `count_by_<field>` — every value's count at once

`group_by_<field>` without ever building the `List[EntityHandle[...]]`/
`EntityHandle` for each group, just `len()`-ing it. Same shape as
`group_by_<field>` above, `Int` in place of the entity/entities — **except
`unique`, which isn't generated here at all**: every group is exactly `1`
by construction, carrying zero information beyond what `unique` already
guarantees.

## `distinct_<field>` — which values exist, nothing else

`group_by_<field>` without building an `EntityHandle`/count for each
group either — just the distinct values themselves. This is the one
that actually matters for `unique`: `group_by_<field>().keys()` looks like
it should be free, but it isn't — `group_by_<field>` already paid for a
real `handle_for` call (a `WeakPointer` upgrade + `EntityHandle`
construction) per value before you ever get to `.keys()`. `distinct_<field>`
reads straight off the reverse index's own keys instead, no entities built
at any point.

| field is... | signature | notes |
| --- | --- | --- |
| plain (no modifier) | `() -> Set[FieldType]` | |
| `unique` | `() -> Set[FieldType]` | the cheap way to ask "which values are taken" |
| `multi` | `() -> Set[ElementType]` | keyed by the bare element type |
| `ordered` | `() -> List[FieldType]` | `List`, not `Set` — the ascending order is the whole point of `ordered`, made explicit in the return type rather than resting on `Set`'s own (real, but less obviously-ordered-to-a-reader) iteration behavior |
| `forwardonly` | *(not generated)* | no reverse index exists for this field at all |

When the field is a relation, `distinct_<field>()`'s result is `@@`-tracked
like any other entity container (`for_<field>`/`all()`): bind it to an
`@@`-marked variable, or iterate it directly, and `@@`-marked field access
on its elements works the same way:

```
for @@d in @@Employee.distinct_dept():
    print(@@d.name)
```

For a plain field, the result is a container of ordinary values, and
`@@`-marking it is rejected.

`group_by_<field>`/`count_by_<field>` get the same treatment for their
*first* type parameter only (the `Dict`'s key) — iterating a bare `Dict`
already yields keys, so that's the only parameter `for @@name in ...:`
binding needs, the same trick a `@@`-marked function's own
`-> Dict[@@Type, V]:` return type already uses:

```
for @@d in @@Employee.group_by_dept():
    print("department:", @@d.name)
```

The value side of that `Dict` (`List[EntityHandle[...]]`/
`EntityHandle[...]`/`Int` per key) isn't `@@`-tracked at all — there's no
way to bind both a `Dict`'s key and value through the marker system yet,
only whichever one iterating the bare container already gives for free.

## `multi`-only

| method | signature | notes |
| --- | --- | --- |
| `add_to_<field>` | `(e, value: ElementType) -> Bool` | `True` if newly added, `False` if already a member |
| `remove_from_<field>` | `(e, value: ElementType) -> Bool` | `True` if it was actually removed |

## `value_eq` {#value_eq}

Compares two handles field-by-field — deliberately *not* what
`@@alice == @@bob` gives you. `EntityHandle`'s own `==` is id-based (needed
as-is so a relation field can use it as a `Dict`/`Set` key): two handles
pointing at the *same* row are always equal regardless of their current
field values, and two *different* rows are never equal no matter how
identical their fields are. `value_eq` is the other axis — same field
values, not necessarily the same row. A relation field is compared by its
own `==` here too (i.e. "points at the same row"), not recursed into the
target's own fields, matching how a foreign key column's equality works in
an ordinary relational database. Every field's own type needs to support
`!=` for this to compile.

## Example

An `Employee` struct with a `unique email`, a `title`, and a
`@@dept: @@Department` field generates:

```
create(email: String, title: String, dept: EntityHandle[...]) raises -> EntityHandle[...]

get_email(e) -> String              set_email(e, v: String) raises
get_title(e) -> String              set_title(e, v: String)
get_dept(e) -> EntityHandle[...]    set_dept(e, v: EntityHandle[...])

for_email(value: String) raises -> EntityHandle[...]            # unique
for_title(value: String) -> List[EntityHandle[...]]             # plain
for_dept(value: EntityHandle[...]) -> List[EntityHandle[...]]   # relation field, still just "plain"

count_email(value: String) -> Int                                # 0 or 1, no raising
count_title(value: String) -> Int
count_dept(value: EntityHandle[...]) -> Int

group_by_email() -> Dict[String, EntityHandle[...]]             # unique
group_by_title() -> Dict[String, List[EntityHandle[...]]]       # plain
group_by_dept() -> Dict[EntityHandle[...], List[EntityHandle[...]]]

count_by_title() -> Dict[String, Int]                            # not generated for email -- unique
count_by_dept() -> Dict[EntityHandle[...], Int]

distinct_email() -> Set[String]                                   # cheap "which values are taken"
distinct_title() -> Set[String]
distinct_dept() -> Set[EntityHandle[...]]

count() -> Int                                                   # whole-table, no grouping
```

For the compiler internals behind this (schema discovery, cycle checking,
codegen structure), see the
[README](https://github.com/kt-734/rw-squirrel-mojo/blob/main/README.md).
