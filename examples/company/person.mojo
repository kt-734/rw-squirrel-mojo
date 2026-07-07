from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__json import sqrrl__to_json, sqrrl__from_json
from squirrel_runtime.json import sqrrl__JsonScanner
from sub.employee import sqrrl__EmployeeTableState
from sub.employee import sqrrl__EmployeeTable


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var employee: Rel[EntityHandle[sqrrl__EmployeeTableState]]

    def __init__(out self):
        self.name = Rel[String]()
        self.employee = Rel[EntityHandle[sqrrl__EmployeeTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.employee.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]
    var keepalive: Set[EntityHandle[sqrrl__PersonTableState]]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())
        self.keepalive = Set[EntityHandle[sqrrl__PersonTableState]]()

    def create(mut self, name: String, employee: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.employee.put(e.id(), employee)
        return e

    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32, name: String, employee: EntityHandle[sqrrl__EmployeeTableState]) raises -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create_with_id(sqrrl__id)
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.employee.put(e.id(), employee)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__PersonTableState]]:
        return self.table.all()

    def dont_keepalive(mut self, e: EntityHandle[sqrrl__PersonTableState]) -> Bool:
        try:
            self.keepalive.remove(e)
            return True
        except:
            return False

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

    def get_employee(self, e: EntityHandle[sqrrl__PersonTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
        var got = self.table.state[].state.employee.get_fwd(e.id())
        return got.take()

    def set_employee(mut self, e: EntityHandle[sqrrl__PersonTableState], v: EntityHandle[sqrrl__EmployeeTableState]):
        self.table.state[].state.employee.update(e.id(), v)

    def for_employee(self, value: EntityHandle[sqrrl__EmployeeTableState]) -> List[EntityHandle[sqrrl__PersonTableState]]:
        var ids = self.table.state[].state.employee.get_bwd(value)
        var out = List[EntityHandle[sqrrl__PersonTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def to_json(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        var out = String("{")
        out += "\"name\":" + sqrrl__to_json(self.get_name(e))
        out += ","
        out += "\"employee\":" + sqrrl__to_json(self.get_employee(e))
        out += "}"
        return out^

    def from_json(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_employee: Optional[EntityHandle[sqrrl__EmployeeTableState]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "employee":
                    sqrrl__parsed_employee = sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int()))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.create(sqrrl__parsed_name.take(), sqrrl__parsed_employee.take())

    def sqrrl__from_json_with_id(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, sqrrl__id: UInt32, mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:
        var sqrrl__parsed_name: Optional[String] = None
        var sqrrl__parsed_employee: Optional[EntityHandle[sqrrl__EmployeeTableState]] = None
        sc.expect_byte(UInt8(ord("{")))
        if not sc.try_consume_byte(UInt8(ord("}"))):
            while True:
                var sqrrl__key = sc.parse_json_string()
                sc.expect_byte(UInt8(ord(":")))
                if sqrrl__key == "name":
                    sqrrl__parsed_name = sqrrl__from_json[String](sc)
                elif sqrrl__key == "employee":
                    sqrrl__parsed_employee = sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int()))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("}")))
                break
        return self.sqrrl__create_with_id(sqrrl__id, sqrrl__parsed_name.take(), sqrrl__parsed_employee.take())

    def all_to_json(self) -> String:
        var out = String("[")
        var sqrrl__first = True
        for sqrrl__e in self.all():
            if not sqrrl__first:
                out += ","
            sqrrl__first = False
            out += "[" + String(sqrrl__e.id()) + "," + self.to_json(sqrrl__e) + "]"
        out += "]"
        return out^

    def all_from_json(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable, mut sc: sqrrl__JsonScanner) raises:
        sc.expect_byte(UInt8(ord("[")))
        if not sc.try_consume_byte(UInt8(ord("]"))):
            while True:
                sc.expect_byte(UInt8(ord("[")))
                var sqrrl__id = UInt32(sc.parse_json_int())
                sc.expect_byte(UInt8(ord(",")))
                var sqrrl__e = self.sqrrl__from_json_with_id(sqrrl__tbl_Employee, sqrrl__id, sc)
                self.keepalive.add(sqrrl__e^)
                sc.expect_byte(UInt8(ord("]")))
                if sc.try_consume_byte(UInt8(ord(","))):
                    continue
                sc.expect_byte(UInt8(ord("]")))
                break
