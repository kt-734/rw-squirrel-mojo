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
| `value_eq` | `(a, b) -> Bool` | field-by-field comparison — `equatable`-tagged structs only — see [below](#value_eq) |
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
`EntityHandle[...]`. That also holds when the declared type wraps the
relation in something other than `List`/`Set`/`multi`'s own `Set[...]` —
`Optional[@@Department]` gives `FieldType = Optional[EntityHandle[...]]`
throughout (`create`/`get_dept`/`set_dept`/`count_dept`/`group_by_dept`/
...), since none of this table's generation branches on the wrapper's
name, only on the field's own modifier (`unique`/`multi`/`ordered`/
`forwardonly`/plain). See the [DSL guide](dsl-guide.md#relation-fields) for
how `Optional`-wrapped fields unwrap through the `@@`-marker sugar.

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

## `sum_<field>`/`avg_<field>`/`min_<field>`/`max_<field>`/`median_<field>` — aggregating one field by another

Generated for a `stats`- or `ordered`-marked field, paired against every
*other* groupable field in the struct (any modifier but `forwardonly`,
which has no reverse index to group by at all). `ordered` alone earns
`min_`/`max_`/`median_` for free (it already requires `Comparable` for
its own range queries, and finding a median needs comparisons, not
arithmetic); `stats` additionally earns `sum_`/`avg_` (it requires `+`
too). This parser can't verify a field's declared type actually supports
`+`/`<`/`>` any more than `unique` can verify `Hashable` —
`stats`/`ordered` are trusted the same way, rejected by Mojo's own compiler
if wrong.

Three shapes per aggregate kind, `<y>` the aggregated field and `<x>` the
grouping field:

| method | signature | behavior |
| --- | --- | --- |
| `{agg}_<y>()` | `() raises -> ResultType` | whole table, no grouping at all — walks `id_count()`/`is_live` directly (same primitives `all()` itself uses), building no `EntityHandle` |
| `{agg}_<y>_by_<x>()` | `() -> Dict[XFieldType, ResultType]` | every group at once, walking `x`'s own `all_bwd()` the same way `group_by_<field>`/`count_by_<field>` do |
| `{agg}_<y>_for_<x>(value)` | `(value: XFieldType) raises -> ResultType` | one group, via `x`'s own `get_bwd(value)` — cheaper when only one group matters, mirroring `for_<field>`/`count_<field>` sitting alongside their own `_by_` sibling |

`{agg}` is `sum`/`avg`/`min`/`max`/`median`. `ResultType` is `<y>`'s own
declared type for every one of them except `avg` — even `median`, since
picking a middle value out of the data (the upper of the two middle
values for an even-sized group, not an interpolation) never needs `<y>`
to support arithmetic, only `<`. `avg` alone is always `Float64`,
regardless of `<y>`'s own type (`Int`, `UInt32`, ...): an integer average
silently truncating (`total // count`) would lose information a
`Float64` promotion doesn't.

`{agg}_<y>_for_<x>(value)` and the whole-table `{agg}_<y>()` both `raise`
if the group/table is empty — there's no sensible non-raising default for
an empty average, minimum, maximum, or median, and raising uniformly
(rather than only for some of them) keeps every aggregate kind behaving
the same way. `{agg}_<y>_by_<x>()` never raises — every bucket `all_bwd()`
hands back already has at least one id in it by construction.

`median`'s whole-table and `_by_<x>` shapes are the two places `ordered`
and `stats` genuinely diverge in *how* they're computed, not just in
which kinds they earn: an `ordered` `<y>` already maintains a value-sorted
id list for its own range queries, so both shapes read the middle
directly out of that (O(1) for the whole table; one linear pass
distributing ids into per-group buckets, already in order, for `_by_`).
A `stats`-only `<y>`, or `_for_<x>` regardless of `<y>`'s modifiers, has
no such structure to lean on and collects-then-sorts fresh each time —
the true cost of a median with nothing already ordered to read from.
(`_for_<x>` never uses the fast path even for an `ordered` `<y>`: sorting
just the one group asked about is cheaper than scanning the whole
table's sorted list to filter it down to that group.)

`<x> == <y>` is skipped entirely (no `sum_salary_by_salary`) — aggregating
a field grouped by itself is degenerate, since every entity in one of its
own value-groups already holds that exact value.

```
print(@@Employee.sum_salary())                 # whole table
print(@@Employee.avg_salary_for_dept(@@eng))    # one department
for @@d in @@Employee.sum_salary_by_dept():     # every department at once
    print(@@d.name)
```

`{agg}_<y>_by_<x>()` gets the same `@@`-tracking as `group_by_<field>`/
`count_by_<field>` when `<x>` is itself a relation field (`@@d` above is a
real, `@@`-trackable `Department`) — the same first-parameter-only
tracking, `<x>` supplying the `Dict`'s key type. `{agg}_<y>_for_<x>(value)`
and the whole-table form both return a bare scalar, not a container, so
neither has anything to `@@`-track.

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
an ordinary relational database.

Opt-in via `equatable` on the struct declaration (`@@struct equatable
@@Name:`, combinable with `keepalive` in either order). Every field's own
type needs to support `!=` for it to compile — not checked ahead of time,
the same trust-the-compiler reasoning as `unique`'s `Hashable`/`ordered`'s
`Comparable`/`stats`'s `+` — but unlike those three, `value_eq` used to be
generated unconditionally for every struct, so any struct with a single
non-`Equatable` field (most commonly an embedded plain struct, which
doesn't derive `Equatable` by default) carried that compile risk whether
or not anyone wanted `value_eq` at all — and since Mojo only fully
type-checks a generated method once something actually calls it, the
failure could stay silent indefinitely. The `equatable` tag confines that
risk to structs that actually ask for it.

## Example

An `Employee` struct with a `unique email`, a `title`, a
`@@dept: @@Department` field, and a `stats salary: Float64` field
generates:

```
create(email: String, title: String, dept: EntityHandle[...], salary: Float64) raises -> EntityHandle[...]

get_email(e) -> String              set_email(e, v: String) raises
get_title(e) -> String              set_title(e, v: String)
get_dept(e) -> EntityHandle[...]    set_dept(e, v: EntityHandle[...])
get_salary(e) -> Float64            set_salary(e, v: Float64)

for_email(value: String) raises -> EntityHandle[...]            # unique
for_title(value: String) -> List[EntityHandle[...]]             # plain
for_dept(value: EntityHandle[...]) -> List[EntityHandle[...]]   # relation field, still just "plain"
for_salary(value: Float64) -> List[EntityHandle[...]]

count_email(value: String) -> Int                                # 0 or 1, no raising
count_title(value: String) -> Int
count_dept(value: EntityHandle[...]) -> Int
count_salary(value: Float64) -> Int

group_by_email() -> Dict[String, EntityHandle[...]]             # unique
group_by_title() -> Dict[String, List[EntityHandle[...]]]       # plain
group_by_dept() -> Dict[EntityHandle[...], List[EntityHandle[...]]]
group_by_salary() -> Dict[Float64, List[EntityHandle[...]]]

count_by_title() -> Dict[String, Int]                            # not generated for email -- unique
count_by_dept() -> Dict[EntityHandle[...], Int]
count_by_salary() -> Dict[Float64, Int]

distinct_email() -> Set[String]                                   # cheap "which values are taken"
distinct_title() -> Set[String]
distinct_dept() -> Set[EntityHandle[...]]
distinct_salary() -> Set[Float64]

count() -> Int                                                   # whole-table, no grouping

# stats salary, paired against every other groupable field (email/title/dept):
sum_salary() raises -> Float64             avg_salary() raises -> Float64
min_salary() raises -> Float64             max_salary() raises -> Float64

sum_salary_by_dept() -> Dict[EntityHandle[...], Float64]
sum_salary_for_dept(value: EntityHandle[...]) raises -> Float64
avg_salary_by_dept() -> Dict[EntityHandle[...], Float64]           # always Float64
avg_salary_for_dept(value: EntityHandle[...]) raises -> Float64
min_salary_by_dept() -> Dict[EntityHandle[...], Float64]
max_salary_for_dept(value: EntityHandle[...]) raises -> Float64
# ...and the same six shapes again paired with email/title
```

For the compiler internals behind this (schema discovery, cycle checking,
codegen structure), see the
[README](https://github.com/kt-734/rw-squirrel-mojo/blob/main/README.md).
