from std.testing import assert_equal, assert_true, assert_false, TestSuite

from squirrel_runtime.entity import Table, EntityHandle, TableStateLike
from squirrel_runtime.rel import Rel


struct TestState(TableStateLike, Movable, ImplicitlyDeletable):
    """A minimal state with no relation fields -- standing in for what a
    generated table's state struct provides, for these generic-runtime
    tests that don't care about field-specific behavior. Id allocation
    itself lives on `TableStorage` now, not here -- see `entity.mojo`."""

    def __init__(out self):
        pass

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        pass


def test_create_allocates_a_live_id() raises:
    var table = Table[TestState](TestState())
    var e = table.create()
    # `e.id()` must come last: it's e's final mention, and Mojo destroys a
    # value immediately after its last use (not at end of scope) -- reading
    # is_live() after this would observe e already dropped and its id freed.
    assert_true(table.is_live(0))
    assert_equal(e.id(), UInt32(0))


def test_id_is_recycled_when_last_handle_drops() raises:
    var table = Table[TestState](TestState())
    var e = table.create()
    assert_true(table.is_live(0))
    _ = e^
    assert_false(table.is_live(0))

    # The freed slot is reused, matching IdAllocator's own recycling test.
    var e2 = table.create()
    assert_equal(e2.id(), UInt32(0))


def test_copying_into_a_container_bumps_the_count_automatically() raises:
    # This is the exact bug class the Zig version couldn't catch: appending
    # a handle into a List is an implicit copy, and here that copy runs
    # __copyinit__ (incref) with no manual bookkeeping anywhere.
    var table = Table[TestState](TestState())
    var e = table.create()

    var holders = List[EntityHandle[TestState]]()
    holders.append(e)
    holders.append(e)
    assert_equal(e.count(), 3)  # e itself, plus the two copies in holders

    # The id must still be live -- two of its three references live inside
    # `holders`, not just in `e`.
    holders_copy_still_alive = table.is_live(0)
    assert_true(holders_copy_still_alive)

    holders.clear()
    assert_equal(e.count(), 1)
    assert_true(table.is_live(0))  # e itself still holds the last reference

    _ = e^
    assert_false(table.is_live(0))


struct EmployeeTestState(TableStateLike, Movable, ImplicitlyDeletable):
    var title: Rel[String]

    def __init__(out self):
        self.title = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.title.fetch_remove_fwd(id)


struct PersonTestState(TableStateLike, Movable, ImplicitlyDeletable):
    var employee: Rel[EntityHandle[EmployeeTestState]]

    def __init__(out self):
        self.employee = Rel[EntityHandle[EmployeeTestState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.employee.fetch_remove_fwd(id)


def test_destroying_an_entity_cascades_into_its_relation_fields() raises:
    # The bug this test guards against: a relation field lives in the
    # OWNING table's Rel (self.employee), addressed by the owner's id -- not
    # embedded as a direct field of EntityInner itself. Mojo's automatic
    # field-wise destruction cascade only reaches fields actually stored
    # inside the value being dropped, so without cleanup_relations wired
    # into EntityInner.__del__, destroying Alice would free her id but leave
    # PersonTestState.employee.fwd[alice_id] still holding a live reference
    # to Bob forever -- a permanent leak, confirmed by tracing through it
    # before this was fixed.
    var employees = Table[EmployeeTestState](EmployeeTestState())
    var bob = employees.create()
    employees.state[].state.title.put(bob.id(), "engineer")

    var people = Table[PersonTestState](PersonTestState())
    var alice = people.create()
    people.state[].state.employee.put(alice.id(), bob)

    assert_equal(bob.count(), 3)  # bob itself, +1 fwd copy, +1 bwd key copy

    _ = alice^
    assert_equal(bob.count(), 1)  # cascade cleanup dropped both references


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
