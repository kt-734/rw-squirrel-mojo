from unique_field import sqrrl__PersonTable, sqrrl__PersonTableState
from squirrel_runtime.json import sqrrl__JsonScanner
from squirrel_runtime.entity import EntityHandle


struct sqrrl__World(Movable):
    var Person: sqrrl__PersonTable
    var sqrrl__reloaded_Person: List[EntityHandle[sqrrl__PersonTableState]]

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.sqrrl__reloaded_Person = List[EntityHandle[sqrrl__PersonTableState]]()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Person\":["
        var sqrrl__first_Person = True
        for sqrrl__e in self.Person.all():
            if not sqrrl__first_Person:
                out += ","
            sqrrl__first_Person = False
            out += "[" + String(sqrrl__e.id()) + "," + self.Person.to_json(sqrrl__e) + "]"
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
                        var sqrrl__e = sqrrl__world.Person.sqrrl__from_json_with_id(sqrrl__id, sc)
                        sqrrl__world.sqrrl__reloaded_Person.append(sqrrl__e^)
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
