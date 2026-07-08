from schema.person import sqrrl__PersonTable, sqrrl__PersonTableState
from schema.department import sqrrl__DepartmentTable, sqrrl__DepartmentTableState
from schema.project import sqrrl__ProjectTable, sqrrl__ProjectTableState
from schema.audit_log import sqrrl__AuditLogTable, sqrrl__AuditLogTableState
from schema.employee import sqrrl__EmployeeTable, sqrrl__EmployeeTableState
from squirrel_runtime.json import sqrrl__JsonScanner
from squirrel_runtime.entity import EntityHandle
from std.os import abort


struct TempKeepAlives(Movable):
    var Person: List[EntityHandle[sqrrl__PersonTableState]]
    var Department: List[EntityHandle[sqrrl__DepartmentTableState]]
    var Project: List[EntityHandle[sqrrl__ProjectTableState]]
    var Employee: List[EntityHandle[sqrrl__EmployeeTableState]]

    def __init__(out self):
        self.Person = List[EntityHandle[sqrrl__PersonTableState]]()
        self.Department = List[EntityHandle[sqrrl__DepartmentTableState]]()
        self.Project = List[EntityHandle[sqrrl__ProjectTableState]]()
        self.Employee = List[EntityHandle[sqrrl__EmployeeTableState]]()


struct sqrrl__World(Movable):
    var Person: sqrrl__PersonTable
    var Department: sqrrl__DepartmentTable
    var Project: sqrrl__ProjectTable
    var AuditLog: sqrrl__AuditLogTable
    var Employee: sqrrl__EmployeeTable
    var sqrrl__temp_keep_alives: Optional[TempKeepAlives]

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.Department = sqrrl__DepartmentTable()
        self.Project = sqrrl__ProjectTable()
        self.AuditLog = sqrrl__AuditLogTable()
        self.Employee = sqrrl__EmployeeTable()
        self.sqrrl__temp_keep_alives = None

    def sqrrl__finalize_temp_keep_alives(mut self):
        self.sqrrl__temp_keep_alives = None

    def sqrrl__check_no_leaks(mut self):
        self.AuditLog.sqrrl__clear_keepalive()
        var sqrrl__leaked_Person = len(self.Person.all())
        if sqrrl__leaked_Person > 0:
            abort("LeakedEntities: 'Person' still has " + String(sqrrl__leaked_Person) + " live entities outside sqrrl__world -- something external still references them")
        var sqrrl__leaked_Department = len(self.Department.all())
        if sqrrl__leaked_Department > 0:
            abort("LeakedEntities: 'Department' still has " + String(sqrrl__leaked_Department) + " live entities outside sqrrl__world -- something external still references them")
        var sqrrl__leaked_Project = len(self.Project.all())
        if sqrrl__leaked_Project > 0:
            abort("LeakedEntities: 'Project' still has " + String(sqrrl__leaked_Project) + " live entities outside sqrrl__world -- something external still references them")
        var sqrrl__leaked_AuditLog = len(self.AuditLog.all())
        if sqrrl__leaked_AuditLog > 0:
            abort("LeakedEntities: 'AuditLog' still has " + String(sqrrl__leaked_AuditLog) + " live entities outside sqrrl__world -- something external still references them")
        var sqrrl__leaked_Employee = len(self.Employee.all())
        if sqrrl__leaked_Employee > 0:
            abort("LeakedEntities: 'Employee' still has " + String(sqrrl__leaked_Employee) + " live entities outside sqrrl__world -- something external still references them")

    def __del__(deinit self):
        self.sqrrl__check_no_leaks()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Project\":" + self.Project.sqrrl__all_to_json()
        out += ","
        out += "\"Department\":" + self.Department.sqrrl__all_to_json()
        out += ","
        out += "\"Employee\":" + self.Employee.sqrrl__all_to_json()
        out += ","
        out += "\"Person\":" + self.Person.sqrrl__all_to_json()
        out += ","
        out += "\"AuditLog\":" + self.AuditLog.sqrrl__all_to_json()
        out += "}"
        return out^


def sqrrl__init() -> sqrrl__World:
    return sqrrl__World()


def sqrrl__world_from_json(mut sc: sqrrl__JsonScanner) raises -> sqrrl__World:
    var sqrrl__world = sqrrl__World()
    sqrrl__world.sqrrl__temp_keep_alives = Optional[TempKeepAlives](TempKeepAlives())
    sc.expect_byte(UInt8(ord("{")))
    if not sc.try_consume_byte(UInt8(ord("}"))):
        while True:
            var sqrrl__key = sc.parse_json_string()
            sc.expect_byte(UInt8(ord(":")))
            if sqrrl__key == "Person":
                sqrrl__world.Person.sqrrl__all_from_json(sqrrl__world.Employee, sqrrl__world.sqrrl__temp_keep_alives.value().Person, sc)
            elif sqrrl__key == "Department":
                sqrrl__world.Department.sqrrl__all_from_json(sqrrl__world.Project, sqrrl__world.sqrrl__temp_keep_alives.value().Department, sc)
            elif sqrrl__key == "Project":
                sqrrl__world.Project.sqrrl__all_from_json(sqrrl__world.sqrrl__temp_keep_alives.value().Project, sc)
            elif sqrrl__key == "AuditLog":
                sqrrl__world.AuditLog.sqrrl__all_from_json(sc)
            elif sqrrl__key == "Employee":
                sqrrl__world.Employee.sqrrl__all_from_json(sqrrl__world.Department, sqrrl__world.sqrrl__temp_keep_alives.value().Employee, sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return sqrrl__world^


def sqrrl__init_from_json(json: String) raises -> sqrrl__World:
    var sqrrl__scanner = sqrrl__JsonScanner(json)
    return sqrrl__world_from_json(sqrrl__scanner)
