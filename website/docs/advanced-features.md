# Advanced features

Everything in the [DSL guide](dsl-guide.md) is written to avoid
`sqrrl__`-prefixed names entirely — `@@init()`, `@@`-marked functions, and
`@@Type.method(...)` calls thread the generated `sqrrl__World` world and its
generated types automatically, so ordinary `.rel` code never needs to name
them.

This page covers the escape hatches: writing `sqrrl__`-prefixed names
directly, by hand, when you need to cross a boundary the `@@` sugar doesn't
reach on its own — real Mojo code outside any `.rel` file's own `@@`-marked
functions, or a library function you don't want to write in the DSL at all.

## Escaping to/from plain Mojo

A value from ordinary, non-`@@` code can be retroactively marked with an
explicit type annotation, and an `@@`-marked function can be called from
ordinary code by threading `sqrrl__world` by hand instead of using
`@@init()`:

```
def promote(mut sqrrl__world: sqrrl__World, e: EntityHandle[sqrrl__EmployeeTableState], t: String) -> EntityHandle[sqrrl__EmployeeTableState]:
    sqrrl__world.Employee.set_title(e, t)
    return e
...
var raw = promote(sqrrl__world, @@bob_emp, "Senior Sales Rep");
var @@promoted_bob: @@Employee = raw;
```

`promote` here is ordinary, hand-written Mojo — not a `.rel`-specific
construct at all — that happens to take and return the same generated types
(`sqrrl__World`, `EntityHandle[sqrrl__EmployeeTableState]`) an `@@`-marked
function would get automatically. This is the pattern for:

- A function you want to write in real Mojo rather than the `@@` DSL (more
  control over the exact signature, or logic that doesn't fit the DSL's own
  grammar).
- Passing `sqrrl__world` into code that lives outside any `.rel` file's own
  `@@`-marked functions (a plain library function, a callback, ...).
- Retroactively marking a value that arrived via one of the above (`var
  @@promoted_bob: @@Employee = raw;`) so it can go back to being used with
  ordinary `@@name.field` syntax afterward.

The types themselves aren't special — `sqrrl__World` and
`EntityHandle[sqrrl__<Name>TableState]` are just the real, generated Mojo
types every `@@`-marked construct already compiles down to; writing them out
by hand is exactly as valid as Mojo compiles it, just without the `@@` sugar
doing it for you.

## One `sqrrl__world` per project

Squirrel deliberately restricts a project to exactly one `@@declare()`. Every
`@@`-marked construct only ever proves that a value is *some* live entity —
never that it belongs to the *same* `sqrrl__world` as whatever it's about to
be used alongside. A plain struct with a relation field (or a `List`/`Set`
of entity handles) can carry an `EntityHandle` across a function boundary
without it ever appearing as a bare `@@name` again, so a syntactic check at
the call site can't catch every path an entity could take between two
independently-declared worlds. A single, project-wide `sqrrl__world` sidesteps
the question entirely: there's only ever one world for a handle to belong
to.

If you genuinely need two independent worlds in one process, that's exactly
the kind of boundary this page is for — thread each one by hand, explicitly,
rather than asking `@@declare()` to manage more than one.
