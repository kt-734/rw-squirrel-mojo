# DSL guide

`@@` marks everything Squirrel-specific — struct declarations, entity
construction, relation fields, and world threading. A `.rel` file is
otherwise just Mojo; anything not `@@`-marked passes through untouched. See
[`examples/kitchen_sink`](https://github.com/kt-734/rw-squirrel-mojo/tree/main/examples/kitchen_sink)
for all of this combined in one project.

## Declaring an entity struct

`@@struct` gets a generated table, an id allocator, and
`create`/`get_<field>`/`set_<field>`/`for_<field>` methods per field:

```
@@struct @@Person:
    name: String
    age: UInt32
```

## Constructing and using one

`@@declare()` brings the shared world into scope once (typically in `main`),
followed by `@@init()` to actually build it; every other function that needs
it takes `@@` on its own parameter list instead of declaring/initializing
again:

```
def main() raises:
    @@declare()
    @@init()
    var @@alice = @@Person { .name = "alice", .age = 30 }
    @@alice.age = 31
    print(@@alice.name, @@alice.age)
```

`@@declare()` must appear exactly once, project-wide, before any
`@@init()`/`@@start_init_from_json(...)` call — it's what makes
`sqrrl__world` exist, as a real, live, empty world immediately. That's what
lets `@@init()`/`@@start_init_from_json(...)` be called any number of times
afterward, in any control-flow shape — including conditionally:

```
def main(dump: String, restoring: Bool) raises:
    @@declare()
    if restoring:
        @@start_init_from_json(dump)
    else:
        @@init()
    print(@@Person.all())
```

Every `@@init()`/`@@start_init_from_json(...)` call checks that whatever
`sqrrl__world` currently holds is empty before replacing it. If something is
still alive in it, that's a real bug worth surfacing rather than silently
discarding: it `abort`s with a `LeakedEntities` message. The same check runs
when `sqrrl__world` itself is destroyed (typically when its declaring
function returns).

A second, independent `@@declare()` anywhere else in the project is rejected
outright.

`@@finalize_init_from_json()` is optional, and valid after either form of
`@@init` — it drops every entity `@@start_init_from_json(...)` retained only
*temporarily* while reconstructing the world (see "JSON serialization"
below for why that retention is needed and where it lives). Call it once a
script has grabbed whatever references it actually cares about from the
reload; anything else — with no relation and no `keepalive` tag holding it
— is destroyed right then, same as any other last handle dropping:

```
def main(dump: String) raises:
    @@declare()
    @@start_init_from_json(dump)
    var kept = @@Person.all()      # re-establish whatever references matter first
    @@finalize_init_from_json()    # drop everything else the reload retained
    print(len(kept))
```

## Relation fields

A field typed `@@Type` points at another entity (refcounted: the target
stays alive as long as anything points at it). `for_<field>` is the reverse
lookup:

```
@@struct @@Department:
    name: String

@@struct @@Employee:
    title: String
    @@dept: @@Department
```

```
var @@eng = @@Department { .name = "Engineering" }
var @@alice = @@Employee { .title = "Engineer", .@@dept = @@eng }
var @@team = @@Employee.for_dept(@@eng) # List[EntityHandle[...]], indexable
var @@alices_dept = @@alice.@@dept      # a single tracked Department
```

`@@alice.@@dept` reads the relation field via instance syntax, tracking the
result the same way `for_<field>`/`create` do: a plain, unmarked variable is
rejected. Marking the last hop is required, not stylistic — there's no
plain `@@alice.dept` spelling for a relation field, only `@@alice.@@dept`;
`@@` on a hop always means "this is a relation," the same way it does
everywhere else. `@@Employee.get_dept(@@alice)` is the equivalent
table-level call, identical either way.

## Indexing and iterating

A tracked container (`for_<field>`'s result, or a container-typed entity
parameter) indexes with `@@name[i]`, and a further `.field` after that
reads/writes right through the indexed element:

```
print("first team member:", @@team[0].title)
@@team[0].title = "Lead Engineer"      # write-through-index
```

`for @@name in <container-call>:` binds `@@name` to the *element* type, so
`@@name.field` works directly inside the loop body, no indexing needed:

```
for @@emp in @@Employee.for_dept(@@eng):
    print(@@emp.title)
```

An ordinary, unmarked `for x in y:` is untouched, same as any other plain
Mojo code.

## Hopping through relations

A chain of `.@@relation` reads or writes follow each hop automatically. The
chain doesn't need to end in a plain field, either — ending on a relation
hop reads that relation itself, tracked the same way `get_<field>` is:

```
print(@@alice.@@job.@@dept.name)
@@alice.@@job.title = "Junior Engineer"
var @@alices_job_dept = @@alice.@@job.@@dept
```

## Field modifiers

One keyword before a field name:

| keyword       | meaning                                                              |
| ------------- | ---------------------------------------------------------------------|
| `unique`      | at most one entity may hold a given value; `for_<field>` raises instead of returning a list, and a duplicate raises on construction |
| `forwardonly` | no reverse index at all — for fields whose type isn't hashable, or where the reverse lookup is simply never needed |
| `multi`       | a genuine many-to-many relation: `Set[T]`-backed, with `add_to_<field>`/`remove_from_<field>` mutating one member at a time and `for_<field>` as the reverse query. Only ever needs declaring on *one* side |
| `ordered`     | a sorted index alongside the field's value, giving range queries (`for_<field>_greater_than`/`_less_than`/`_at_least`/`_at_most`/`_between`) in addition to the usual exact-match `for_<field>` |

```
@@struct @@Person:
    unique email: String
    forwardonly tags: List[String]
```

**`multi`** answers both directions from a single declaration:

```
@@struct @@Department:
    name: String
    multi @@projects: @@Project
```

```
_ = @@Department.add_to_projects(@@eng, @@website)
print(len(@@eng.@@projects))                          # this dept's projects
print(len(@@Department.for_projects(@@website)))      # which depts run this project
```

**`ordered`** gives range queries a hash-backed `Rel` can't answer quickly:

```
@@struct @@Employee:
    name: String
    ordered years_employed: UInt32
```

```
for @@e in @@Employee.for_years_employed_greater_than(4):
    print(@@e.name)
for @@e in @@Employee.for_years_employed_between(2, 5):
    print(@@e.name)
```

## `@@`-marked functions

Marking a function's own *name* with `@@` (`def @@name(...)`, not a
parameter) auto-threads the world through it: its definition gets `mut
sqrrl__world: sqrrl__World` inserted as its first parameter, and every call
site gets `sqrrl__world` inserted as its first argument — silently, on both
ends:

```
def @@make_department(name: String) -> @@Department:
    var @@dept = @@Department { .name = name }
    return @@dept

def @@hire(name: String, title: String, @@dept: @@Department) raises -> @@Employee:
    var @@emp = @@Employee { .name = name, .title = title, .@@dept = @@dept }
    return @@emp
```

```
var @@eng = @@make_department("Engineering")
var @@alice = @@hire("Alice", "Engineer", @@eng)
```

A call site only works inside a function that already has `sqrrl__world`
itself, via `@@init()` or its own `@@`-marked name/parameters.

## Plain structs

A bare `struct` (no `@@`) is an ordinary embedded value, not its own table.
It can hold plain fields, *and* its own `@@`-marked relation fields pointing
back at a real entity struct:

```
struct Note {
    @@author: @@Employee,
    text: String,
}

@@struct @@Person:
    name: String
    forwardonly home: Address
```

## `keepalive`

An entity normally dies the moment its last handle drops. `keepalive` on a
`@@struct` overrides that — `create` adds every new entity to an internal
set, so it survives with no relation or local variable holding it:

```
@@struct keepalive @@Project:
    name: String
```

```
_ = @@Project.create(name = "Website Revamp")    # handle discarded, entity lives on
print("all projects:", len(@@Project.all()))
```

## JSON serialization

`sqrrl__world` itself has `to_json`/a reload counterpart, dumping and
restoring every table's every live entity at once — there's no per-entity
`@@Type.to_json(...)` sugar, since a relation field only ever serializes as
the target's bare id, not its contents. `@@init()`'s reload counterpart is
`@@start_init_from_json`/`@@finalize_init_from_json` (see "Constructing and
using one" above); the dump half has no sugar at all — there's nothing to
inject, it just always dumps everything — so that's thread-`sqrrl__world`-
by-hand territory (see [Advanced features](advanced-features.md)):

```
var dump = sqrrl__world.to_json()      # -> String, every table's every live entity

var sc = sqrrl__JsonScanner(dump)
var reloaded = sqrrl__world_from_json(sc)    # -> sqrrl__World, a fresh one
```

Reconstruction proceeds in dependency order, so by the time any entity's
relation field is resolved, its target is already live in the reloaded
world. `unique` fields still enforce their constraint through reload.

For the full detail on generated method signatures, container-type
inference, and the dump/reload internals, see the
[README](https://github.com/kt-734/rw-squirrel-mojo/blob/main/README.md).
