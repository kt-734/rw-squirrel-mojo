from unique_field import sqrrl__PersonTable


struct sqrrl__Squirrel(Movable):
    var Person: sqrrl__PersonTable

    def __init__(out self):
        self.Person = sqrrl__PersonTable()


def sqrrl__init() -> sqrrl__Squirrel:
    return sqrrl__Squirrel()
