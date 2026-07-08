from unique_field import sqrrl__PersonTable, sqrrl__PersonTableState
from squirrel_runtime.json import sqrrl__JsonScanner
from squirrel_runtime.entity import EntityHandle
from std.os import abort


struct TempKeepAlives(Movable):
    var Person: List[EntityHandle[sqrrl__PersonTableState]]

    def __init__(out self):
        self.Person = List[EntityHandle[sqrrl__PersonTableState]]()


struct sqrrl__World(Movable):
    var Person: sqrrl__PersonTable
    var sqrrl__temp_keep_alives: Optional[TempKeepAlives]

    def __init__(out self):
        self.Person = sqrrl__PersonTable()
        self.sqrrl__temp_keep_alives = None

    def sqrrl__finalize_temp_keep_alives(mut self):
        self.sqrrl__temp_keep_alives = None

    def sqrrl__check_no_leaks(mut self):
        var sqrrl__leaked_Person = len(self.Person.all())
        if sqrrl__leaked_Person > 0:
            abort("LeakedEntities: 'Person' still has " + String(sqrrl__leaked_Person) + " live entities outside sqrrl__world -- something external still references them")

    def __del__(deinit self):
        self.sqrrl__check_no_leaks()

    def to_json(self) -> String:
        var out = String("{")
        out += "\"Person\":" + self.Person.sqrrl__all_to_json()
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
                sqrrl__world.Person.sqrrl__all_from_json(sqrrl__world.sqrrl__temp_keep_alives.value().Person, sc)
            if sc.try_consume_byte(UInt8(ord(","))):
                continue
            sc.expect_byte(UInt8(ord("}")))
            break
    return sqrrl__world^


def sqrrl__init_from_json(json: String) raises -> sqrrl__World:
    var sqrrl__scanner = sqrrl__JsonScanner(json)
    return sqrrl__world_from_json(sqrrl__scanner)
