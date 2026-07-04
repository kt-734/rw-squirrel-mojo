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
