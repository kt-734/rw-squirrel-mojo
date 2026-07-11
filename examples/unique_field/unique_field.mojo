from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var email: UniqueRel[String]
    var name: Rel[String]

    def __init__(out self):
        self.email = UniqueRel[String]()
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.email.fetch_remove_fwd(id)
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())

    def create(mut self, email: String, name: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.name.put(e.id(), name)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, email: String, name: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def get_email(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var got = self.table.state[].state.email.get_fwd(e.id())
        return got.take()

    def set_email(mut self, e: EntityHandle[sqrrl__PersonTableState], v: String) raises:
        self.table.state[].state.email.update(e.id(), v)

    def for_email(self, value: String) raises -> EntityHandle[sqrrl__PersonTableState]:
        var id = self.table.state[].state.email.get_bwd(value)
        return self.table.handle_for(id)

    def count_email(self, value: String) -> Int:
        return 1 if value in self.table.state[].state.email.all_bwd() else 0

    def group_by_email(self) -> Dict[String, EntityHandle[sqrrl__PersonTableState]]:
        ref ids = self.table.state[].state.email.all_bwd()
        var out = Dict[String, EntityHandle[sqrrl__PersonTableState]]()
        for entry in ids.items():
            out[entry.key] = self.table.handle_for(entry.value)
        return out^

    def distinct_email(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.email.all_bwd().keys():
            out.add(key)
        return out^

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
        out += "\"email\":" + sqrrl__to_json(self.get_email(e))
        out += ","
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_email: Optional[String] = None
        var sqrrl__parsed_name: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "email":
                    sqrrl__parsed_email = sqrrl__from_json[String](sc)
                elif sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_email.take(), sqrrl__parsed_name.take())

    def sqrrl__from_json_with_id(mut self, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_email: Optional[String] = None
        var sqrrl__parsed_name: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "email":
                    sqrrl__parsed_email = sqrrl__from_json[String](sc)
                elif sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_email.take(), sqrrl__parsed_name.take())

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

def main() raises:
    var sqrrl__world = sqrrl__init()
    try:
        var sqrrl__alice = sqrrl__world.Person.create(email = "alice@example.com", name = "alice")
        var sqrrl__bob = sqrrl__world.Person.create(email = "bob@example.com", name = "bob")

        var sqrrl__found = sqrrl__world.Person.for_email("bob@example.com")
        print("found by email:", sqrrl__world.Person.get_name(sqrrl__found))

        try:
            var sqrrl__carol = sqrrl__world.Person.create(email = "alice@example.com", name = "carol")
            print("should not reach here")
        except e:
            print("rejected duplicate email:", e)

        var sqrrl__matches = sqrrl__world.Person.for_name("alice")
        print("for_name is not unique, so it returns a list:", len(sqrrl__matches), "match(es)")
        print("indexed into it:", sqrrl__world.Person.get_name(sqrrl__matches[0]))

        print(sqrrl__world.Person.get_name(sqrrl__alice), sqrrl__world.Person.get_name(sqrrl__bob))
    finally:
        sqrrl__world.sqrrl__check_no_leaks()
