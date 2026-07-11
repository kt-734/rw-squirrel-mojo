from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]

    def __init__(out self):
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())

    def create(mut self, name: String) -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def get_name(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__PersonTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__PersonTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__PersonTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_name(self, value: String) -> Int:
        return len(self.table.state[].state.name.get_bwd(value))

    def group_by_name(self) -> Dict[String, List[EntityHandle[sqrrl__PersonTableState]]]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__PersonTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__PersonTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_name(self) -> Dict[String, Int]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_name(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.name.all_bwd().keys():
            out.add(key)
        return out^

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_name.take())

    def sqrrl__from_json_with_id(mut self, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_name.take())

    def sqrrl__all_to_json(self) -> String:
        var out = String("[")
        var sqrrl__first = True
        for sqrrl__e in self.all():
            if not sqrrl__first:
                out += ","
            sqrrl__first = False
            out += "[" + String(sqrrl__e.id()) + "," + self.sqrrl__to_json(sqrrl__e) + "]"
        out += "]"
        return out^

    def sqrrl__all_from_json(mut self, mut sqrrl__temp: List[EntityHandle[sqrrl__PersonTableState]], mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                var sqrrl__e = self.sqrrl__from_json_with_id(sqrrl__id, sc)
                sqrrl__temp.append(sqrrl__e^)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break

struct sqrrl__GroupTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var members: MultiRel[EntityHandle[sqrrl__PersonTableState]]

    def __init__(out self):
        self.members = MultiRel[EntityHandle[sqrrl__PersonTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.members.fetch_remove_fwd(id)


struct sqrrl__GroupTable(Movable):
    var table: Table[sqrrl__GroupTableState]
    var keepalive: Set[EntityHandle[sqrrl__GroupTableState]]

    def __init__(out self):
        self.table = Table[sqrrl__GroupTableState](sqrrl__GroupTableState())
        self.keepalive = Set[EntityHandle[sqrrl__GroupTableState]]()

    def create(mut self, members: Set[EntityHandle[sqrrl__PersonTableState]]) -> EntityHandle[sqrrl__GroupTableState]:
        var e = self.table.create()
        self.table.state[].state.members.put(e.id(), members)
        self.keepalive.add(e.copy())
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, members: Set[EntityHandle[sqrrl__PersonTableState]]) raises -> EntityHandle[sqrrl__GroupTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.members.put(e.id(), members)
        self.keepalive.add(e.copy())
        return e

    def all(self) -> Set[EntityHandle[sqrrl__GroupTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def dont_keepalive(mut self, e: EntityHandle[sqrrl__GroupTableState]) -> Bool:
        try:
            self.keepalive.remove(e)
            return True
        except:
            return False

    def sqrrl__clear_keepalive(mut self):
        self.keepalive = Set[EntityHandle[sqrrl__GroupTableState]]()

    def get_members(self, e: EntityHandle[sqrrl__GroupTableState]) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        var got = self.table.state[].state.members.get_fwd(e.id())
        return got.take()

    def set_members(mut self, e: EntityHandle[sqrrl__GroupTableState], v: Set[EntityHandle[sqrrl__PersonTableState]]):
        self.table.state[].state.members.update(e.id(), v)

    def add_to_members(mut self, e: EntityHandle[sqrrl__GroupTableState], value: EntityHandle[sqrrl__PersonTableState]) -> Bool:
        return self.table.state[].state.members.add(e.id(), value)

    def remove_from_members(mut self, e: EntityHandle[sqrrl__GroupTableState], value: EntityHandle[sqrrl__PersonTableState]) -> Bool:
        return self.table.state[].state.members.remove(e.id(), value)

    def for_members(self, value: EntityHandle[sqrrl__PersonTableState]) -> List[EntityHandle[sqrrl__GroupTableState]]:
        var ids = self.table.state[].state.members.get_bwd(value)
        var out = List[EntityHandle[sqrrl__GroupTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_members(self, value: EntityHandle[sqrrl__PersonTableState]) -> Int:
        return len(self.table.state[].state.members.get_bwd(value))

    def group_by_members(self) -> Dict[EntityHandle[sqrrl__PersonTableState], List[EntityHandle[sqrrl__GroupTableState]]]:
        ref buckets = self.table.state[].state.members.all_bwd()
        var out = Dict[EntityHandle[sqrrl__PersonTableState], List[EntityHandle[sqrrl__GroupTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__GroupTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_members(self) -> Dict[EntityHandle[sqrrl__PersonTableState], Int]:
        ref buckets = self.table.state[].state.members.all_bwd()
        var out = Dict[EntityHandle[sqrrl__PersonTableState], Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_members(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        var out = Set[EntityHandle[sqrrl__PersonTableState]]()
        for key in self.table.state[].state.members.all_bwd().keys():
            out.add(key)
        return out^

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__GroupTableState]) -> String:
        var out = String("{")
        out += "\"members\":" + sqrrl__to_json(self.get_members(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__GroupTableState]:
        var sqrrl__parsed_members: Optional[Set[EntityHandle[sqrrl__PersonTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "members":
                    var sqrrl__parsed_members_tmp = Set[EntityHandle[sqrrl__PersonTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_members_tmp.add(sqrrl__tbl_Person.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_members = sqrrl__parsed_members_tmp^
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_members.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__GroupTableState]:
        var sqrrl__parsed_members: Optional[Set[EntityHandle[sqrrl__PersonTableState]]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "members":
                    var sqrrl__parsed_members_tmp = Set[EntityHandle[sqrrl__PersonTableState]]()
                    sc.expect_byte(UInt8(ord("[")))
                    if not sc.try_consume_byte(UInt8(ord("]"))):
                        while True:
                            sqrrl__parsed_members_tmp.add(sqrrl__tbl_Person.table.handle_for(UInt32(sc.parse_json_int())))
                            if sc.try_consume_byte(UInt8(ord(","))):
                                continue
                            sc.expect_byte(UInt8(ord("]")))
                            break
                    sqrrl__parsed_members = sqrrl__parsed_members_tmp^
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_members.take())

    def sqrrl__all_to_json(self) -> String:
        var out = String("[")
        var sqrrl__first = True
        for sqrrl__e in self.all():
            if not sqrrl__first:
                out += ","
            sqrrl__first = False
            out += "[" + String(sqrrl__e.id()) + "," + self.sqrrl__to_json(sqrrl__e) + "]"
        out += "]"
        return out^

    def sqrrl__all_from_json(mut self, mut sqrrl__tbl_Person: sqrrl__PersonTable, mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                _ = self.sqrrl__from_json_with_id(sqrrl__tbl_Person, sqrrl__id, sc)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break

def sqrrl__are_friends(mut sqrrl__world: sqrrl__World, sqrrl__one: EntityHandle[sqrrl__PersonTableState], sqrrl__two: EntityHandle[sqrrl__PersonTableState]) -> Bool:
    if sqrrl__one == sqrrl__two:
        return False
    for sqrrl__g in  sqrrl__world.Group.for_members(sqrrl__one):
        if sqrrl__two in sqrrl__world.Group.get_members(sqrrl__g):
            return True
    return False


def sqrrl__all_friends(mut sqrrl__world: sqrrl__World, sqrrl__person: EntityHandle[sqrrl__PersonTableState]) -> Set[EntityHandle[sqrrl__PersonTableState]]:
    var sqrrl__result = Set[EntityHandle[sqrrl__PersonTableState]]()
    for sqrrl__g in  sqrrl__world.Group.for_members(sqrrl__person):
        for sqrrl__p in  sqrrl__world.Group.get_members(sqrrl__g):
            if sqrrl__p != sqrrl__person:
                sqrrl__result.add(sqrrl__p)
    return sqrrl__result^


def main() raises:
    var sqrrl__world = sqrrl__init()
    try:
        var sqrrl__alice = sqrrl__world.Person.create(name = "Alice")
        var sqrrl__bob = sqrrl__world.Person.create(name = "Bob")
        var sqrrl__carol = sqrrl__world.Person.create(name = "Carol")
        var sqrrl__dave = sqrrl__world.Person.create(name = "Dave")

        # A "friend group" is modeled as its own entity rather than a
        # field directly on @@Person -- a field on @@Person pointing at
        # @@Person is a self-relation cycle no matter what wrapper it's
        # given (List/Set/multi all still count as an edge back to where
        # it started), so a real many-to-many friendship instead goes
        # through a join struct that only points *at* @@Person, never
        # the reverse. `keepalive` matters here too: a @@Group's only
        # strong reference is otherwise whatever local handle created
        # it, so without `keepalive` a group can silently stop existing
        # the moment nothing still holds that handle.
        _ = sqrrl__world.Group.create(members = Set(sqrrl__alice, sqrrl__bob))
        _ = sqrrl__world.Group.create(members = Set(sqrrl__alice, sqrrl__carol))

        print("alice and bob:", sqrrl__are_friends(sqrrl__world, sqrrl__alice, sqrrl__bob))
        print("alice and dave:", sqrrl__are_friends(sqrrl__world, sqrrl__alice, sqrrl__dave))
        print("alice and alice:", sqrrl__are_friends(sqrrl__world, sqrrl__alice, sqrrl__alice))

        print("alice's friends:")
        for sqrrl__f in  sqrrl__all_friends(sqrrl__world, sqrrl__alice):
            print(" -", sqrrl__world.Person.get_name(sqrrl__f))
    finally:
        sqrrl__world.sqrrl__check_no_leaks()
