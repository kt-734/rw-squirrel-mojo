from std.os import abort

from squirrel_runtime.rel.fwd_store import _FwdStore
from squirrel_runtime.rel.rel_like import RelLike


struct OrderedRel[T: KeyElement & Comparable & ImplicitlyDeletable & Copyable](RelLike, Movable):
    """Per-field storage for an `ordered`-marked field: `_fwd` is the same
    dense-array-by-id storage every other `Rel` variant shares; `_sorted` is
    a `List[UInt32]` of every id currently holding a value, kept sorted by
    that value (ascending) -- what makes a range query
    (`greater_than`/`less_than`/`at_least`/`at_most`/`between`) a pair of
    binary searches plus a slice, O(log n + k), instead of the O(n) full
    scan a linear-filter-over-`all()` approach would be.

    Every mutation (`put`/`update`/`fetch_remove_fwd`) keeps `_sorted` in
    sync via binary-search insert/remove -- O(log n) comparisons, but O(n)
    for the actual `List` insert/removal shift, the same complexity trade
    any sorted-array (not a tree) structure always has. Ids sharing the
    same value aren't ordered relative to each other beyond insertion
    order; removing a specific one scans just that equal-value run
    (bounded by how many ids share the value, not the table's size).

    Bounded by `Comparable` (Mojo's real `<`/`<=`/`>`/`>=` trait) in
    addition to `KeyElement` -- this parser has no way to verify a field's
    type is actually ordered any more than `unique` can verify `Hashable`,
    so `ordered` is trusted the same way, rejected by Mojo's own compiler
    with a clear message if it's wrong."""

    comptime FieldType = Self.T

    var _fwd: _FwdStore[Self.T]
    var _sorted: List[UInt32]

    def __init__(out self):
        self._fwd = _FwdStore[Self.T]()
        self._sorted = List[UInt32]()

    def put(mut self, id: UInt32, value: Self.T):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead)."""
        self._fwd.set_new(id, value)
        self._insert_sorted(id, value)

    def update(mut self, id: UInt32, value: Self.T):
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead). Removes `id` from `_sorted` (using its
        *old* value) before touching `_fwd` at all, not after -- `_remove_
        sorted`'s binary search reads `_fwd` for every id it probes,
        including this one, so mutating `_fwd` first would make its own
        old position look inconsistent with its (already-changed) value
        mid-search."""
        var old = self._fwd.get(id)
        if not old:
            abort("OrderedRel.update: id not found")
        self._remove_sorted(id, old.value())
        _ = self._fwd.replace(id, value)
        self._insert_sorted(id, value)

    def get_fwd(self, id: UInt32) -> Optional[Self.T]:
        return self._fwd.get(id)

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.T]:
        """Clear id's value; returns the value it held, or None. Same
        ordering requirement as `update` -- remove from `_sorted` (reading
        `_fwd` for its old value) before clearing `_fwd`, not after."""
        var peeked = self._fwd.get(id)
        if not peeked:
            return None
        self._remove_sorted(id, peeked.value())
        return self._fwd.clear(id)

    def get_bwd(self, value: Self.T) -> List[UInt32]:
        """Every id currently holding exactly `value` -- same name and
        shape as `Rel`/`UniqueRel`/`MultiRel`'s own reverse index, so a
        `for_<field>` (exact match) call site doesn't need to know its
        field is `ordered` rather than plain; a binary-search
        `between(value, value)` under the hood instead of `Rel`'s hash
        lookup, same result."""
        return self.between(value, value)

    def all_bwd(self) -> Dict[Self.T, List[UInt32]]:
        """Every distinct value currently in use, each mapped to every id
        holding it -- the whole reverse index at once, rather than one
        bucket via `get_bwd`. Unlike `Rel`/`UniqueRel`/`MultiRel`'s own
        `all_bwd` (a plain `.copy()`, since their own `_bwd` already has
        this shape), `OrderedRel` has no `_bwd` dict to copy -- built here
        by walking `_sorted` instead, grouping each contiguous run of equal
        values (free, since `_sorted` already keeps them contiguous),
        inserting each group in ascending order. `Dict`'s own iteration
        order matches insertion order (documented, not just observed --
        same guarantee Python's `dict` makes), so a caller iterating this
        still sees `ordered`'s own sort order, same shape as the other
        three `Rel` variants' `all_bwd`. What `group_by_<field>`
        (`codegen.table`) walks."""
        var out = Dict[Self.T, List[UInt32]]()
        var i = 0
        while i < len(self._sorted):
            var value = self._value_at(i)
            var ids = List[UInt32]()
            while i < len(self._sorted) and self._value_at(i) == value:
                ids.append(self._sorted[i])
                i += 1
            out[value^] = ids^
        return out^

    def sorted_ids(self) -> ref [self._sorted] List[UInt32]:
        """Every id currently holding a value, in ascending order by that
        value -- a borrowed reference straight into `_sorted` (`self` is
        only borrowed here, so this is read-only, same reasoning as `Rel.
        all_bwd`), not a copy, exposing the order this struct already
        maintains on every `put`/`update` rather than making a caller
        rebuild it (collect then sort from scratch) when they already know
        the field is `ordered`. What `median_<field>`'s whole-table and
        `_by_` variants use (`codegen.aggregates`) to get an O(1)/O(n)
        answer respectively instead of the O(n log n) a fresh sort would
        cost -- the entire reason `ordered` maintains this structure at
        all, not just for range queries."""
        return self._sorted

    def greater_than(self, value: Self.T) -> List[UInt32]:
        """Every id whose value is strictly greater than `value`."""
        return self._slice(self._upper_bound(value), len(self._sorted))

    def at_least(self, value: Self.T) -> List[UInt32]:
        """Every id whose value is greater than or equal to `value`."""
        return self._slice(self._lower_bound(value), len(self._sorted))

    def less_than(self, value: Self.T) -> List[UInt32]:
        """Every id whose value is strictly less than `value`."""
        return self._slice(0, self._lower_bound(value))

    def at_most(self, value: Self.T) -> List[UInt32]:
        """Every id whose value is less than or equal to `value`."""
        return self._slice(0, self._upper_bound(value))

    def between(self, low: Self.T, high: Self.T) -> List[UInt32]:
        """Every id whose value is in `[low, high]` (inclusive both ends).
        Empty (not an error) if `low > high`."""
        var start = self._lower_bound(low)
        var end = self._upper_bound(high)
        if start >= end:
            return List[UInt32]()
        return self._slice(start, end)

    def _slice(self, start: Int, end: Int) -> List[UInt32]:
        var out = List[UInt32]()
        for i in range(start, end):
            out.append(self._sorted[i])
        return out^

    def _value_at(self, index: Int) -> Self.T:
        return self._fwd.get(self._sorted[index]).value().copy()

    def _lower_bound(self, value: Self.T) -> Int:
        """First index whose value is >= `value` -- also the insertion
        point that keeps equal values after any existing ones."""
        var lo = 0
        var hi = len(self._sorted)
        while lo < hi:
            var mid = (lo + hi) // 2
            if self._value_at(mid) < value:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def _upper_bound(self, value: Self.T) -> Int:
        """First index whose value is > `value`."""
        var lo = 0
        var hi = len(self._sorted)
        while lo < hi:
            var mid = (lo + hi) // 2
            if self._value_at(mid) <= value:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def _insert_sorted(mut self, id: UInt32, value: Self.T):
        self._sorted.insert(self._lower_bound(value), id)

    def _remove_sorted(mut self, id: UInt32, value: Self.T):
        """Removes `id` from `_sorted` -- `value` is what it was stored
        under, needed to find the equal-value run to search within (ids
        sharing a value aren't otherwise ordered relative to each other)."""
        var start = self._lower_bound(value)
        var end = self._upper_bound(value)
        for i in range(start, end):
            if self._sorted[i] == id:
                _ = self._sorted.pop(i)
                return
        abort("OrderedRel._remove_sorted: id not found in its own value's range")
