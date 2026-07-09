# Generated method reference

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

group_by_email() -> Dict[String, EntityHandle[...]]             # unique
group_by_title() -> Dict[String, List[EntityHandle[...]]]       # plain
group_by_dept() -> Dict[EntityHandle[...], List[EntityHandle[...]]]
```

For the compiler internals behind this (schema discovery, cycle checking,
codegen structure), see the
[README](https://github.com/kt-734/rw-squirrel-mojo/blob/main/README.md).
