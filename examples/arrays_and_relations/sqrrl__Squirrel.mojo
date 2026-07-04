from arrays_and_relations import sqrrl__DepartmentTable
from arrays_and_relations import sqrrl__EmployeeTable


struct sqrrl__Squirrel(Movable):
    var Department: sqrrl__DepartmentTable
    var Employee: sqrrl__EmployeeTable

    def __init__(out self):
        self.Department = sqrrl__DepartmentTable()
        self.Employee = sqrrl__EmployeeTable()


def sqrrl__init() -> sqrrl__Squirrel:
    return sqrrl__Squirrel()
