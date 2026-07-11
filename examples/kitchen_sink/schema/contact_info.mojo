from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from schema.address import Address


struct ContactInfo(Copyable, Movable, ImplicitlyDeletable):
    var home: Address
    var emails: List[String]

    def __init__(out self, var home: Address, var emails: List[String]):
        self.home = home^
        self.emails = emails^


