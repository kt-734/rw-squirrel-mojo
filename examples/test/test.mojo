from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__world import sqrrl__init, sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner


struct sqrrl__TestTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]

    def __init__(out self):
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__TestTable(Movable):
    var table: Table[sqrrl__TestTableState]

    def __init__(out self):
        self.table = Table[sqrrl__TestTableState](sqrrl__TestTableState())

    def create(mut self, name: String) -> EntityHandle[sqrrl__TestTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String) raises -> EntityHandle[sqrrl__TestTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__TestTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def value_eq(self, a: EntityHandle[sqrrl__TestTableState], b: EntityHandle[sqrrl__TestTableState]) -> Bool:
        if self.get_name(a) != self.get_name(b):
            return False
        return True

    def get_name(self, e: EntityHandle[sqrrl__TestTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__TestTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__TestTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__TestTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_name(self, value: String) -> Int:
        return len(self.table.state[].state.name.get_bwd(value))

    def group_by_name(self) -> Dict[String, List[EntityHandle[sqrrl__TestTableState]]]:
        ref buckets = self.table.state[].state.name.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__TestTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__TestTableState]]()
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

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__TestTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__TestTableState]:
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

    def sqrrl__from_json_with_id(mut self, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__TestTableState]:
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

    def sqrrl__all_from_json(mut self, mut sqrrl__temp: List[EntityHandle[sqrrl__TestTableState]], mut sc: sqrrl__JsonScanner) raises:
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
def sqrrl__testFunc(mut sqrrl__world: sqrrl__World) -> List[EntityHandle[sqrrl__TestTableState]]:
    var ret = List[EntityHandle[sqrrl__TestTableState]]()
    ret.append(sqrrl__world.Test.create(name = "ex1"))
    return ret^

def main():
    var sqrrl__world = sqrrl__init()
    try:
        var sqrrl__localList = sqrrl__testFunc(sqrrl__world)
        for sqrrl__l in  sqrrl__localList:
            print(sqrrl__world.Test.get_name(sqrrl__l))

        print(sqrrl__world.Test.get_name(sqrrl__localList[0]))
    finally:
        sqrrl__world.sqrrl__check_no_leaks()
