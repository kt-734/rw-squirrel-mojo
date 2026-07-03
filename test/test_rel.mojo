from std.testing import assert_equal, assert_true, assert_false, TestSuite

from squirrel_runtime.rel import Rel
from squirrel_runtime.entity import Table, EntityHandle, TableStateLike


def test_int_field() raises:
    var rel = Rel[UInt32]()
    rel.put(0, 10)
    rel.put(1, 20)
    rel.put(2, 10)  # shared value, not a bijection

    assert_equal(rel.get_fwd(0).value(), UInt32(10))

    # No test for put-on-an-already-set-id / update-on-a-never-put-id:
    # Rel.put/update abort (not raise) on those now -- see the doc comment
    # on Rel -- and an abort can't be caught in-process, so there's nothing
    # safe to assert without crashing the test runner itself.

    assert_equal(len(rel.get_bwd(10)), 2)

    rel.update(0, 999)  # 0 moves out of the shared "10" bucket
    assert_equal(rel.get_fwd(0).value(), UInt32(999))
    assert_equal(len(rel.get_bwd(10)), 1)
    assert_equal(len(rel.get_bwd(999)), 1)

    assert_equal(rel.fetch_remove_fwd(0).value(), UInt32(999))
    assert_equal(len(rel.get_bwd(999)), 0)
    assert_equal(len(rel.get_bwd(10)), 1)  # id 2 untouched
    assert_false(Bool(rel.get_fwd(0)))

    rel.put(0, 30)  # freed slot can be reused
    assert_equal(rel.get_fwd(0).value(), UInt32(30))


def test_string_field() raises:
    var rel = Rel[String]()
    rel.put(0, "alice")
    rel.put(1, "bob")

    assert_equal(rel.get_fwd(0).value(), String("alice"))
    assert_equal(len(rel.get_bwd("bob")), 1)
    assert_equal(len(rel.get_bwd("carol")), 0)

    # Two separate String instances, same content -- must match by content,
    # not identity.
    var b2 = String("bob")
    rel.put(2, b2)
    assert_equal(len(rel.get_bwd("bob")), 2)


def test_float_field_bitcast_equality() raises:
    var rel = Rel[Float64]()
    rel.put(0, 1.5)
    rel.put(1, -0.0)
    rel.put(2, 0.0)

    assert_equal(rel.get_fwd(0).value(), Float64(1.5))
    # +0.0 and -0.0 are distinct keys here -- matches Zig's deliberate
    # FloatBitcastContext, and comes for free from Mojo's default float
    # hashing/equality.
    assert_equal(len(rel.get_bwd(0.0)), 1)
    assert_equal(len(rel.get_bwd(-0.0)), 1)

    # NOTE: unlike Zig's FloatBitcastContext, a NaN key is NOT reflexively
    # equal to itself here -- Mojo's Float64 equality follows real IEEE-754
    # semantics (NaN != NaN). put()-ing a NaN succeeds, but get_bwd(nan)
    # will not find it. Known gap, deferred: see conversation notes.


struct PersonTestState(TableStateLike, Movable, ImplicitlyDeletable):
    def __init__(out self):
        pass

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        pass


struct JobTestState(TableStateLike, Movable, ImplicitlyDeletable):
    def __init__(out self):
        pass

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        pass


def test_relation_field() raises:
    # FieldType = EntityHandle[JobTestState]: fwd holds a real reference per
    # owner, and bwd's dict key holds one more real reference the first time
    # a value appears -- both are dropped correctly on removal, symmetric
    # with any scalar field. This replaces the earlier separate EntityRel
    # type: the original "permanent pinning" finding was a bug in
    # _remove_from_bucket (never deleting an emptied key), not a fundamental
    # limit of using a handle as a bwd key.
    var people = Table[PersonTestState](PersonTestState())
    var jobs = Table[JobTestState](JobTestState())
    var alice = people.create()
    var carol = people.create()
    var job = jobs.create()

    var field = Rel[EntityHandle[JobTestState]]()
    assert_equal(job.count(), 1)
    field.put(alice.id(), job)
    assert_equal(job.count(), 3)  # +1 fwd copy, +1 bwd's first-insertion key copy
    field.put(carol.id(), job)
    assert_equal(job.count(), 4)  # +1 fwd copy; bwd key already exists -- no new reference
    assert_equal(len(field.get_bwd(job)), 2)

    _ = field.fetch_remove_fwd(alice.id())
    assert_equal(job.count(), 3)  # lost alice's fwd copy, bwd bucket still has carol
    assert_equal(len(field.get_bwd(job)), 1)

    _ = field.fetch_remove_fwd(carol.id())
    assert_equal(job.count(), 1)  # lost carol's fwd copy AND the now-empty bwd key
    assert_equal(len(field.get_bwd(job)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
