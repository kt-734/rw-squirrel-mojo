from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner
from sqrrl__json import sqrrl__Address_from_json
from schema.department import sqrrl__DepartmentTableState
from schema.department import sqrrl__DepartmentTable


struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var title: Rel[String]
    var dept: Rel[EntityHandle[sqrrl__DepartmentTableState]]

    def __init__(out self):
        self.title = Rel[String]()
        self.dept = Rel[EntityHandle[sqrrl__DepartmentTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.title.fetch_remove_fwd(id)
        _ = self.dept.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, title: String, dept: EntityHandle[sqrrl__DepartmentTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.dept.put(e.id(), dept)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, title: String, dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.dept.put(e.id(), dept)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        return self.table.all()

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

    def get_dept(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__DepartmentTableState]:
        var got = self.table.state[].state.dept.get_fwd(e.id())
        return got.take()

    def set_dept(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: EntityHandle[sqrrl__DepartmentTableState]):
        self.table.state[].state.dept.update(e.id(), v)

    def for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.dept.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def to_json(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var out = String("{")
        out += "\"title\":" + sqrrl__to_json(self.get_title(e))
        out += ","
        out += "\"dept\":" + sqrrl__to_json(self.get_dept(e))
        out += "}"
        return out^

    def from_json(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_title: Optional[String] = None
        var sqrrl__parsed_dept: Optional[EntityHandle[sqrrl__DepartmentTableState]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                elif sqrrl__key == "dept":
                    sqrrl__parsed_dept = sqrrl__tbl_Department.table.handle_for(UInt32(sc.parse_json_int()))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_title.take(), sqrrl__parsed_dept.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var sqrrl__parsed_title: Optional[String] = None
        var sqrrl__parsed_dept: Optional[EntityHandle[sqrrl__DepartmentTableState]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "title":
                    sqrrl__parsed_title = sqrrl__from_json[String](sc)
                elif sqrrl__key == "dept":
                    sqrrl__parsed_dept = sqrrl__tbl_Department.table.handle_for(UInt32(sc.parse_json_int()))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_title.take(), sqrrl__parsed_dept.take())
