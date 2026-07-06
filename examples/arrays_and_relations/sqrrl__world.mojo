from arrays_and_relations import sqrrl__DepartmentTable, sqrrl__DepartmentTableState
from arrays_and_relations import sqrrl__EmployeeTable, sqrrl__EmployeeTableState
from squirrel_runtime.json import sqrrl__JsonScanner
from squirrel_runtime.entity import EntityHandle


struct sqrrl__World(Movable):
    var Department: sqrrl__DepartmentTable
    var Employee: sqrrl__EmployeeTable
    var sqrrl__reloaded_Department: List[EntityHandle[sqrrl__DepartmentTableState]]
    var sqrrl__reloaded_Employee: List[EntityHandle[sqrrl__EmployeeTableState]]

    def __init__(out self):
        self.Department = sqrrl__DepartmentTable()
        self.Employee = sqrrl__EmployeeTable()
        self.sqrrl__reloaded_Department = List[EntityHandle[sqrrl__DepartmentTableState]]()
        self.sqrrl__reloaded_Employee = List[EntityHandle[sqrrl__EmployeeTableState]]()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Department\":["
        var sqrrl__first_Department = True
        for sqrrl__e in self.Department.all():
            if not sqrrl__first_Department:
                out += ","
            sqrrl__first_Department = False
            out += "[" + String(sqrrl__e.id()) + "," + self.Department.to_json(sqrrl__e) + "]"
        out += "]"
        out += ","
        out += "\"Employee\":["
        var sqrrl__first_Employee = True
        for sqrrl__e in self.Employee.all():
            if not sqrrl__first_Employee:
                out += ","
            sqrrl__first_Employee = False
            out += "[" + String(sqrrl__e.id()) + "," + self.Employee.to_json(sqrrl__e) + "]"
        out += "]"
        out += "}"
        return out^


def sqrrl__init() -> sqrrl__World:
    return sqrrl__World()


def sqrrl__world_from_json(mut sc: sqrrl__JsonScanner) raises -> sqrrl__World:
    var sqrrl__world = sqrrl__World()
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "Department":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        var sqrrl__e = sqrrl__world.Department.sqrrl__from_json_with_id(sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Department.append(sqrrl__e^)
                        sc.expect_byte(UInt8(ord("]")))
                        if sc.try_consume_byte(UInt8(ord(","))):
                            continue
                        sc.expect_byte(UInt8(ord("]")))
                        break
            elif sqrrl__key == "Employee":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        var sqrrl__e = sqrrl__world.Employee.sqrrl__from_json_with_id(sqrrl__world.Department, sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Employee.append(sqrrl__e^)
                        sc.expect_byte(UInt8(ord("]")))
                        if sc.try_consume_byte(UInt8(ord(","))):
                            continue
                        sc.expect_byte(UInt8(ord("]")))
                        break
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return sqrrl__world^
