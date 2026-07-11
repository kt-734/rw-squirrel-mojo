from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner


struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var title: Rel[String]

    def __init__(out self):
        self.title = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.title.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, title: String) -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.title.put(e.id(), title)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, title: String) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.title.put(e.id(), title)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        return self.table.all()

    def count(self) -> Int:
        return self.table.count()

    def get_title(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var got = self.table.state[].state.title.get_fwd(e.id())
        return got.take()

    def set_title(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String):
        self.table.state[].state.title.update(e.id(), v)

    def for_title(self, value: String) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.title.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def count_title(self, value: String) -> Int:
        return len(self.table.state[].state.title.get_bwd(value))

    def group_by_title(self) -> Dict[String, List[EntityHandle[sqrrl__EmployeeTableState]]]:
        ref buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, List[EntityHandle[sqrrl__EmployeeTableState]]]()
        for entry in buckets.items():
            var handles = List[EntityHandle[sqrrl__EmployeeTableState]]()
            for id in entry.value:
                handles.append(self.table.handle_for(id))
            out[entry.key] = handles^
        return out^

    def count_by_title(self) -> Dict[String, Int]:
        ref buckets = self.table.state[].state.title.all_bwd()
        var out = Dict[String, Int]()
        for entry in buckets.items():
            out[entry.key] = len(entry.value)
        return out^

    def distinct_title(self) -> Set[String]:
        var out = Set[String]()
        for key in self.table.state[].state.title.all_bwd().keys():
            out.add(key)
        return out^

    def sqrrl__to_json(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var out = String("{")
        out += "\"title\":" + sqrrl__to_json(self.get_title(e))
        out += "}"
        return out^

    def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_title: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_title.take())

    def sqrrl__from_json_with_id(mut self, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_title: Optional[String] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_title.take())

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

    def sqrrl__all_from_json(mut self, mut sqrrl__temp: List[EntityHandle[sqrrl__EmployeeTableState]], mut sc: sqrrl__JsonScanner) raises:
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

