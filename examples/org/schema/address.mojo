from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


from std.hashlib import Hasher


struct Address(ImplicitlyCopyable, Movable, ImplicitlyDeletable, Hashable, Equatable):
    var city: String

    def __init__(out self, var city: String):
        self.city = city^

    def __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.city)

    def __eq__(self, other: Self) -> Bool:
        return self.city == other.city

    def __ne__(self, other: Self) -> Bool:
        return self.city != other.city
