from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from schema.box import Box
from schema.pair import Pair
from schema.contact_info import ContactInfo


struct Profile(Copyable, Movable, ImplicitlyDeletable):
    var contact: ContactInfo
    var nicknames: Optional[List[String]]
    var scores: Dict[String, Int]
    var rating: Box[UInt32]
    var coordinates: Pair[Int, Int]

    def __init__(out self, var contact: ContactInfo, var nicknames: Optional[List[String]], var scores: Dict[String, Int], var rating: Box[UInt32], var coordinates: Pair[Int, Int]):
        self.contact = contact^
        self.nicknames = nicknames^
        self.scores = scores^
        self.rating = rating^
        self.coordinates = coordinates^

