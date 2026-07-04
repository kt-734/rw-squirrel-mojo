from schema.person import sqrrl__PersonTable
from schema.department import sqrrl__DepartmentTable
from schema.project import sqrrl__ProjectTable
from schema.audit_log import sqrrl__AuditLogTable
from schema.employee import sqrrl__EmployeeTable


struct sqrrl__Squirrel(Movable):
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


def sqrrl__init() -> sqrrl__Squirrel:
    return sqrrl__Squirrel()
