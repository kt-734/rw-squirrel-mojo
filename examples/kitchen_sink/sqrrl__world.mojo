from schema.person import sqrrl__PersonTable, sqrrl__PersonTableState
from schema.department import sqrrl__DepartmentTable, sqrrl__DepartmentTableState
from schema.project import sqrrl__ProjectTable, sqrrl__ProjectTableState
from schema.audit_log import sqrrl__AuditLogTable, sqrrl__AuditLogTableState
from schema.employee import sqrrl__EmployeeTable, sqrrl__EmployeeTableState
from squirrel_runtime.json import sqrrl__JsonScanner
from squirrel_runtime.entity import EntityHandle


struct sqrrl__World(Movable):
    var Person: sqrrl__PersonTable
    var Department: sqrrl__DepartmentTable
    var Project: sqrrl__ProjectTable
    var AuditLog: sqrrl__AuditLogTable
    var Employee: sqrrl__EmployeeTable
    var sqrrl__reloaded_Person: List[EntityHandle[sqrrl__PersonTableState]]
    var sqrrl__reloaded_Department: List[EntityHandle[sqrrl__DepartmentTableState]]
    var sqrrl__reloaded_Project: List[EntityHandle[sqrrl__ProjectTableState]]
    var sqrrl__reloaded_Employee: List[EntityHandle[sqrrl__EmployeeTableState]]

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.Department = sqrrl__DepartmentTable()
        self.Project = sqrrl__ProjectTable()
        self.AuditLog = sqrrl__AuditLogTable()
        self.Employee = sqrrl__EmployeeTable()
        self.sqrrl__reloaded_Person = List[EntityHandle[sqrrl__PersonTableState]]()
        self.sqrrl__reloaded_Department = List[EntityHandle[sqrrl__DepartmentTableState]]()
        self.sqrrl__reloaded_Project = List[EntityHandle[sqrrl__ProjectTableState]]()
        self.sqrrl__reloaded_Employee = List[EntityHandle[sqrrl__EmployeeTableState]]()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Project\":["
        var sqrrl__first_Project = True
        for sqrrl__e in self.Project.all():
            if not sqrrl__first_Project:
                out += ","
            sqrrl__first_Project = False
            out += "[" + String(sqrrl__e.id()) + "," + self.Project.to_json(sqrrl__e) + "]"
        out += "]"
        out += ","
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
        out += ","
        out += "\"Person\":["
        var sqrrl__first_Person = True
        for sqrrl__e in self.Person.all():
            if not sqrrl__first_Person:
                out += ","
            sqrrl__first_Person = False
            out += "[" + String(sqrrl__e.id()) + "," + self.Person.to_json(sqrrl__e) + "]"
        out += "]"
        out += ","
        out += "\"AuditLog\":["
        var sqrrl__first_AuditLog = True
        for sqrrl__e in self.AuditLog.all():
            if not sqrrl__first_AuditLog:
                out += ","
            sqrrl__first_AuditLog = False
            out += "[" + String(sqrrl__e.id()) + "," + self.AuditLog.to_json(sqrrl__e) + "]"
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
            if sqrrl__key == "Person":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        var sqrrl__e = sqrrl__world.Person.sqrrl__from_json_with_id(sqrrl__world.Employee, sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Person.append(sqrrl__e^)
                        sc.expect_byte(UInt8(ord("]")))
                        if sc.try_consume_byte(UInt8(ord(","))):
                            continue
                        sc.expect_byte(UInt8(ord("]")))
                        break
            elif sqrrl__key == "Department":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        var sqrrl__e = sqrrl__world.Department.sqrrl__from_json_with_id(sqrrl__world.Project, sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Department.append(sqrrl__e^)
                        sc.expect_byte(UInt8(ord("]")))
                        if sc.try_consume_byte(UInt8(ord(","))):
                            continue
                        sc.expect_byte(UInt8(ord("]")))
                        break
            elif sqrrl__key == "Project":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        var sqrrl__e = sqrrl__world.Project.sqrrl__from_json_with_id(sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Project.append(sqrrl__e^)
                        sc.expect_byte(UInt8(ord("]")))
                        if sc.try_consume_byte(UInt8(ord(","))):
                            continue
                        sc.expect_byte(UInt8(ord("]")))
                        break
            elif sqrrl__key == "AuditLog":
                sc.expect_byte(UInt8(ord("[")))
                if not sc.try_consume_byte(UInt8(ord("]"))):
                    while True:
                        sc.expect_byte(UInt8(ord("[")))
                        var sqrrl__id = UInt32(sc.parse_json_int())
                        sc.expect_byte(UInt8(ord(",")))
                        _ = sqrrl__world.AuditLog.sqrrl__from_json_with_id(sqrrl__id, sc)
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
