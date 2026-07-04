from schema.person import sqrrl__PersonTable
from schema.department import sqrrl__DepartmentTable
from schema.employee import sqrrl__EmployeeTable


struct sqrrl__Squirrel(Movable):
    var Person: sqrrl__PersonTable
    var Department: sqrrl__DepartmentTable
    var Employee: sqrrl__EmployeeTable

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.Department = sqrrl__DepartmentTable()
        self.Employee = sqrrl__EmployeeTable()


def sqrrl__init() -> sqrrl__Squirrel:
    return sqrrl__Squirrel()
