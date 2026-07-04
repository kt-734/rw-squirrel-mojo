from std.testing import assert_equal, assert_true, assert_false, TestSuite

from squirrel_runtime.id_allocator import IdAllocator


def test_basic_alloc() raises:
    var ids = IdAllocator()
    assert_equal(ids.alloc(), UInt32(0))
    assert_equal(ids.alloc(), UInt32(1))
    assert_equal(ids.alloc(), UInt32(2))
    assert_true(ids.is_live(0))
    assert_true(ids.is_live(1))
    assert_true(ids.is_live(2))


def test_recycles_freed_ids() raises:
    var ids = IdAllocator()
    _ = ids.alloc()  # 0
    _ = ids.alloc()  # 1
    _ = ids.alloc()  # 2

    ids.free(1)
    assert_false(ids.is_live(1))

    var recycled = ids.alloc()
    assert_equal(recycled, UInt32(1))
    assert_true(ids.is_live(1))

    # 1 is taken again now; the next fresh id continues from next_id, not 0.
    assert_equal(ids.alloc(), UInt32(3))


def test_free_then_recycle() raises:
    var ids = IdAllocator()
    _ = ids.alloc()  # 0
    ids.free(0)
    assert_false(ids.is_live(0))
    assert_equal(ids.alloc(), UInt32(0))

    # No test for double-free/free-of-never-allocated: IdAllocator.free
    # aborts (not raises) on those now -- see its doc comment -- and an
    # abort can't be caught in-process the way a raised Error can, so
    # there's nothing safe to assert here without crashing the test runner
    # itself.


def test_id_count_tracks_highest_id_ever_allocated() raises:
    """`id_count()` is one past the highest id ever handed out -- the upper
    bound `Table.all()` walks (paired with `is_live`) to enumerate live
    entities in one pass. Freeing an id doesn't shrink it (the slot's still
    there, just marked dead), only allocating a fresh one grows it."""
    var ids = IdAllocator()
    assert_equal(ids.id_count(), 0)
    _ = ids.alloc()  # 0
    _ = ids.alloc()  # 1
    assert_equal(ids.id_count(), 2)
    ids.free(0)
    assert_equal(ids.id_count(), 2)
    _ = ids.alloc()  # recycles 0
    assert_equal(ids.id_count(), 2)
    _ = ids.alloc()  # 2
    assert_equal(ids.id_count(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
