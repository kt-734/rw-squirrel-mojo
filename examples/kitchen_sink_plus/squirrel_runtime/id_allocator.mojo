from std.os import abort


struct IdAllocator(Movable):
    """Hands out `UInt32` entity ids, recycling freed ids instead of growing
    forever. This is the only thing that decides which id a new entity gets."""

    var next_id: UInt32
    var free_list: List[UInt32]
    var live: List[Bool]

    def __init__(out self):
        self.next_id = 0
        self.free_list = List[UInt32]()
        self.live = List[Bool]()

    def alloc(mut self) -> UInt32:
        """Allocate an id: a recycled one if any are free, otherwise the next
        id that's never been handed out before."""
        var id: UInt32
        if len(self.free_list) > 0:
            id = self.free_list.pop()
        else:
            id = self.next_id
            self.next_id += 1

        while Int(id) >= len(self.live):
            self.live.append(False)
        self.live[Int(id)] = True
        return id

    def alloc_specific(mut self, id: UInt32) raises:
        """Like `alloc`, but for a *specific* id rather than whichever one
        is next -- used when reconstructing a `sqrrl__World` from a JSON
        dump (`sqrrl__world_from_json`), where a relation field's own
        serialized value is another entity's exact original id: recreating
        that entity under a *different* id (whatever `alloc()` would have
        handed out fresh) would silently point every relation field
        referencing it at the wrong row, or at nothing at all. Raises
        (rather than aborting, unlike `free`) if `id` is already live --
        that's a real, recoverable-by-the-caller possibility here (a
        corrupt or hand-edited dump), not an invariant this codebase's own
        allocator broke.

        Ids in `[next_id, id)` that this call skips past -- because `id`
        is higher than anything handed out so far -- go straight onto the
        free list rather than being silently lost: the same ids `alloc()`
        would eventually hand out on its own, just reserved out of order
        here instead of in the usual monotonic sequence."""
        if self.is_live(id):
            raise Error("IdAllocator.alloc_specific: id already live")
        var idx = Int(id)
        if idx < len(self.live):
            var pos = -1
            for i in range(len(self.free_list)):
                if self.free_list[i] == id:
                    pos = i
                    break
            if pos < 0:
                raise Error("IdAllocator.alloc_specific: id not available")
            _ = self.free_list.pop(pos)
        else:
            while idx > len(self.live):
                self.free_list.append(UInt32(len(self.live)))
                self.live.append(False)
            self.live.append(False)
            self.next_id = id + 1
        self.live[idx] = True

    def free(mut self, id: UInt32):
        """Release id back to the free list for reuse. Aborts if id isn't
        currently allocated -- a double free, or a bug in the caller.
        Unrecoverable rather than raising: the only caller is
        `EntityInner.__del__`, which frees an id exactly once per entity by
        construction -- if this ever fires, something upstream (id
        allocation, refcounting) is already broken, and there's no
        meaningful way for a caller to recover from that."""
        if not self.is_live(id):
            abort("IdAllocator.free: id not allocated")
        self.live[Int(id)] = False
        self.free_list.append(id)

    def is_live(self, id: UInt32) -> Bool:
        return Int(id) < len(self.live) and self.live[Int(id)]

    def id_count(self) -> Int:
        """One past the highest id ever handed out -- the upper bound
        `Table.all()` walks (paired with `is_live`) to enumerate a table's
        currently-live entities in a single pass, without materializing an
        intermediate list of ids first."""
        return len(self.live)
