from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import Set

from squirrel_runtime.rel import Rel, ForwardOnlyRel, MultiRel
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
    # owner, and _bwd's dict key holds one more real reference the first time
    # a value appears -- both are dropped correctly on removal, symmetric
    # with any scalar field. This replaces the earlier separate EntityRel
    # type: the original "permanent pinning" finding was a bug in
    # _remove_from_bucket (never deleting an emptied key), not a fundamental
    # limit of using a handle as a _bwd key.
    var people = Table[PersonTestState](PersonTestState())
    var jobs = Table[JobTestState](JobTestState())
    var alice = people.create()
    var carol = people.create()
    var job = jobs.create()

    var field = Rel[EntityHandle[JobTestState]]()
    assert_equal(job.count(), 1)
    field.put(alice.id(), job)
    assert_equal(job.count(), 3)  # +1 fwd copy, +1 _bwd's first-insertion key copy
    field.put(carol.id(), job)
    assert_equal(job.count(), 4)  # +1 fwd copy; _bwd key already exists -- no new reference
    assert_equal(len(field.get_bwd(job)), 2)

    _ = field.fetch_remove_fwd(alice.id())
    assert_equal(job.count(), 3)  # lost alice's fwd copy, _bwd bucket still has carol
    assert_equal(len(field.get_bwd(job)), 1)

    _ = field.fetch_remove_fwd(carol.id())
    assert_equal(job.count(), 1)  # lost carol's fwd copy AND the now-empty _bwd key
    assert_equal(len(field.get_bwd(job)), 0)


def test_forward_only_rel_field() raises:
    # ForwardOnlyRel backs a `forwardonly`-marked field -- one whose type
    # genuinely isn't KeyElement (a collection is KeyElement exactly when
    # its element type is, so `List[EntityHandle[...]]` here is just a
    # convenient stand-in, not the only realistic case -- a plain
    # `List[Int]` needing `forwardonly` looks identical from ForwardOnlyRel's
    # own side). No _bwd index at all, so unlike test_relation_field above
    # there's no get_bwd/bucket bookkeeping to exercise, just that
    # put/get_fwd/fetch_remove_fwd round-trip a whole List correctly and that
    # dropping the returned List on fetch_remove_fwd decref's every entity
    # inside it, same as a single EntityHandle does for a scalar relation
    # field. (List's own copy is copy-on-write over its backing buffer, so
    # unlike a bare EntityHandle field, an intermediate `.copy()` of the List
    # itself doesn't bump every element's refcount one-for-one -- this only
    # asserts the invariant that actually matters: nothing leaks once every
    # handle to `job`, direct or list-held, goes out of scope.)
    var people = Table[PersonTestState](PersonTestState())
    var jobs = Table[JobTestState](JobTestState())
    var alice = people.create()
    var bob = people.create()
    var job = jobs.create()

    var field = ForwardOnlyRel[List[EntityHandle[JobTestState]]]()
    assert_true(job.count() >= 1)

    var members = List[EntityHandle[JobTestState]]()
    members.append(job)
    members.append(job)
    field.put(alice.id(), members^)

    var got_opt = field.get_fwd(alice.id())
    var got = got_opt.take()
    assert_equal(len(got), 2)
    assert_true(got[0] == job)
    assert_true(got[1] == job)

    assert_false(Bool(field.get_fwd(bob.id())))

    var removed_opt = field.fetch_remove_fwd(alice.id())
    var removed = removed_opt.take()
    assert_equal(len(removed), 2)

    assert_false(Bool(field.get_fwd(alice.id())))
    assert_equal(job.count(), 1)  # every list-held copy released; only `job` itself remains


def test_multi_rel_field() raises:
    # MultiRel backs a `multi`-marked field -- a genuine many-to-many
    # relation, indexed by each *element* rather than the field's whole
    # value (what ordinary Rel does for a plain collection field).
    # FieldType is Set[T], not List[T] -- membership is a set (this row
    # either has this member or it doesn't), so a duplicate can't exist
    # even via put/update's own wholesale-value path, structurally rather
    # than via a runtime check.
    var people = Table[PersonTestState](PersonTestState())
    var jobs = Table[JobTestState](JobTestState())
    var alice = people.create()
    var bob = people.create()
    var job1 = jobs.create()
    var job2 = jobs.create()

    var field = MultiRel[EntityHandle[JobTestState]]()
    field.put(alice.id(), Set[EntityHandle[JobTestState]]())
    field.put(bob.id(), Set[EntityHandle[JobTestState]]())

    assert_true(field.add(alice.id(), job1))
    assert_false(field.add(alice.id(), job1))  # idempotent -- already a member
    assert_true(field.add(alice.id(), job2))
    assert_true(field.add(bob.id(), job1))

    assert_equal(len(field.get_fwd(alice.id()).value()), 2)
    assert_equal(len(field.get_fwd(bob.id()).value()), 1)

    # The reverse many-to-many query: which owners contain this one element.
    assert_equal(len(field.get_bwd(job1)), 2)  # alice and bob
    assert_equal(len(field.get_bwd(job2)), 1)  # alice only

    assert_true(field.remove(alice.id(), job1))
    assert_false(field.remove(alice.id(), job1))  # already gone
    assert_equal(len(field.get_bwd(job1)), 1)  # bob only now
    assert_equal(len(field.get_fwd(alice.id()).value()), 1)

    # A Set built with the same element added twice just has one member --
    # no duplicate ever exists to reject in the first place.
    var dup = Set[EntityHandle[JobTestState]]()
    dup.add(job1)
    dup.add(job1)
    assert_equal(len(dup), 1)
    field.update(bob.id(), dup)
    assert_equal(len(field.get_fwd(bob.id()).value()), 1)

    var removed = field.fetch_remove_fwd(bob.id())
    assert_equal(len(removed.value()), 1)
    assert_equal(len(field.get_bwd(job1)), 0)  # bob's own membership gone too


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
