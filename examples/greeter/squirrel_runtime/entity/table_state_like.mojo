trait TableStateLike:
    """What a generated table's state struct must provide so the shared
    machinery can cascade-clean relation fields when an entity dies without
    knowing what fields a specific table has.

    A generated `sqrrl__EmployeeTableState` implements this with just one
    method: `sqrrl__cleanup_relations` -- prefixed, like the generated
    struct names themselves, so it can never collide with a `.rel`-declared
    field of the same name (a `.rel` author could plausibly name a field
    `cleanup_relations`; they can't plausibly type `sqrrl__cleanup_relations`
    by accident). It calls `fetch_remove_fwd` on each of its own `Rel`
    fields for the given id and discards the result -- for a relation
    field, that drops the returned `EntityHandle`, decref'ing whatever it
    pointed to; for a plain field, it's just freeing the table's own stored
    copy. Without this, destroying an entity would free its id but leave its
    relation fields' stored references behind forever: `sqrrl__PersonTableState`'s
    `employee: Rel[EntityHandle[sqrrl__EmployeeTableState]]` doesn't live
    inside `EntityInner` itself, so Mojo's automatic field-wise destruction
    cascade (which does work for a relation embedded as a direct struct
    field) can't reach it -- confirmed by tracing through a concrete leak:
    destroying a Person left `PersonTableState.employee.fwd[alice_id]` still
    holding a live reference to Bob, permanently inflating his refcount.

    Id allocation itself (`alloc_id`/`free_id`/`is_live`) is *not* part of
    this trait -- it lives on `TableStorage` instead (a fixed, non-generated
    wrapper), since it's mechanically identical for every table and doesn't
    need to vary per `@@struct`. Mojo trait methods can have default bodies
    that call other required methods, but not ones that return a reference
    to a field (confirmed: the trait's abstract return-origin annotation and
    an implementation's field-specific one don't unify, even when they
    should be compatible) -- so hoisting id allocation into `TableStorage`,
    rather than trying to default-implement it on the trait, is what
    actually removes the boilerplate from generated code."""

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        ...
