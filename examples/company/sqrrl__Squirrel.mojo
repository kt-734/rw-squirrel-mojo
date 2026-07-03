from person import sqrrl__PersonTable
from sub.employee import sqrrl__EmployeeTable


struct sqrrl__Squirrel(Movable):
    var Person: sqrrl__PersonTable
    var Employee: sqrrl__EmployeeTable

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.Employee = sqrrl__EmployeeTable()


def sqrrl__init() -> sqrrl__Squirrel:
    return sqrrl__Squirrel()
