from schema.person import sqrrl__PersonTable, sqrrl__PersonTableState
from schema.department import sqrrl__DepartmentTable, sqrrl__DepartmentTableState
from schema.project import sqrrl__ProjectTable, sqrrl__ProjectTableState
from schema.audit_log import sqrrl__AuditLogTable, sqrrl__AuditLogTableState
from schema.employee import sqrrl__EmployeeTable, sqrrl__EmployeeTableState
from squirrel_runtime.json import sqrrl__JsonScanner


struct sqrrl__World(Movable):
    var Person: sqrrl__PersonTable
    var Department: sqrrl__DepartmentTable
    var Project: sqrrl__ProjectTable
    var AuditLog: sqrrl__AuditLogTable
    var Employee: sqrrl__EmployeeTable

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.Department = sqrrl__DepartmentTable()
        self.Project = sqrrl__ProjectTable()
        self.AuditLog = sqrrl__AuditLogTable()
        self.Employee = sqrrl__EmployeeTable()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Project\":" + self.Project.all_to_json()
        out += ","
        out += "\"Department\":" + self.Department.all_to_json()
        out += ","
        out += "\"Employee\":" + self.Employee.all_to_json()
        out += ","
        out += "\"Person\":" + self.Person.all_to_json()
        out += ","
        out += "\"AuditLog\":" + self.AuditLog.all_to_json()
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
                sqrrl__world.Person.all_from_json(sqrrl__world.Employee, sc)
            elif sqrrl__key == "Department":
                sqrrl__world.Department.all_from_json(sqrrl__world.Project, sc)
            elif sqrrl__key == "Project":
                sqrrl__world.Project.all_from_json(sc)
            elif sqrrl__key == "AuditLog":
                sqrrl__world.AuditLog.all_from_json(sc)
            elif sqrrl__key == "Employee":
                sqrrl__world.Employee.all_from_json(sqrrl__world.Department, sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return sqrrl__world^
