from squirrel_compiler.parser import (
    Scanner,
    ParsedStruct,
    Field,
    TypeParam,
    FieldModifier,
    is_wrapped_relation_type,
    relation_target_of,
    relation_wrapper_of,
)
from squirrel_compiler.codegen import encode_container_type, recover_relation_type_str
from squirrel_compiler.driver.file_paths import module_path_for


struct DiscoveredStruct(Copyable, Movable, ImplicitlyDeletable):
    """One `@@struct` found during the directory walk, tagged with the
    dotted module path of the file that declared it -- used in the second
    pass to resolve which relation fields need a cross-file import."""

    var module_path: String
    var parsed: ParsedStruct

    def __init__(out self, var module_path: String, var parsed: ParsedStruct):
        self.module_path = module_path^
        self.parsed = parsed^


struct DiscoveryResult(Movable):
    """The output of `discover_structs`' pass over every `.rel` file:
    every struct found, and a `struct name -> declaring module` map."""

    var structs: List[DiscoveredStruct]
    var module_of: Dict[String, String]

    def __init__(out self, var structs: List[DiscoveredStruct], var module_of: Dict[String, String]):
        self.structs = structs^
        self.module_of = module_of^


def discover_structs(rel_files: List[String], target_root: String) raises -> DiscoveryResult:
    """Pass 1: parses every `@@struct` in every `.rel` file under
    `target_root`, without emitting anything yet. Returns the structs found
    (each tagged with its declaring module) and a `struct name -> declaring
    module` map -- both needed before any file's code can be emitted,
    since a relation field's target might live in a file we haven't walked
    to yet."""
    var discovered = List[DiscoveredStruct]()
    var module_of = Dict[String, String]()

    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        try:
            while sc.find_next_struct_decl():
                var parsed = sc.parse_struct()
                module_of[parsed.name] = module_path
                discovered.append(DiscoveredStruct(module_path, parsed^))
        except e:
            raise Error(path + ": " + String(e))

    return DiscoveryResult(discovered^, module_of^)


def _relation_fields_of(fields: List[Field]) -> Dict[String, String]:
    """Field name -> target struct name, for every relation field in
    `fields` -- shared by `build_relation_schema` across both `@@struct`s
    (`ds.parsed.fields`) and plain structs (`plain_struct_fields`'s own
    values), since a relation field means the same thing wherever it's
    declared: a plain struct can embed one back into an entity just as
    well as an `@@struct` can (see `codegen.emit_plain_struct`). A
    collection-typed relation field (`@@members: List[@@Employee]`)
    registers its *element* type the same way a bare one does, but
    `encode_container_type`-encoded (`"List[Employee]"`, not bare
    `"Employee"`) -- `get_<field>` on one of these returns a
    `List[EntityHandle[...]]`, not a single entity, so callers that key
    off this schema (`transform_source`'s `get_<field>` return-type
    inference) need to tell the two apart the same way `entity_to_type`
    already distinguishes a container-tracked variable from a plain one.
    A `multi` relation field (`multi @@members: @@Employee`) is registered
    the same encoded way as a wrapped one, even though its own `type_str`
    is the bare element type, not `Set[@@Employee]` -- `get_members`
    still actually returns `Set[EntityHandle[...]]` (`multi` is what
    turns the declared element type into a `Set[...]` field; see
    `codegen.emit_field_type`), so this schema needs to reflect that
    actual shape, not the syntax `multi`'s own field happened to be
    written with."""
    var out = Dict[String, String]()
    for field in fields:
        if field.modifier == FieldModifier.MULTI and field.type_str.startswith("@@"):
            out[field.name] = encode_container_type("Set", relation_target_of(field.type_str))
        elif field.type_str.startswith("@@"):
            out[field.name] = relation_target_of(field.type_str)
        elif is_wrapped_relation_type(field.type_str):
            out[field.name] = encode_container_type(
                relation_wrapper_of(field.type_str), relation_target_of(field.type_str)
            )
    return out^


def build_relation_schema(
    discovery: DiscoveryResult,
    plain_struct_fields: Dict[String, List[Field]] = Dict[String, List[Field]](),
) raises -> Dict[String, Dict[String, String]]:
    """Struct name -> relation field name -> target struct name, for every
    `@@struct` *and* plain struct declared project-wide -- one shared
    schema, not two, so a chained field access (`@@alice.@@employee.title`,
    or a hop through a plain struct's own embedded relation field) resolves
    the exact same way regardless of which kind of struct sits at each hop.
    `transform_source` needs this project-wide (not derivable from a single
    file's own source text) since an intermediate hop's target struct can
    be declared in a different file than the script using the chain (same
    reasoning `emit_file`'s cross-file import resolution already relies
    on). A collection field can't be hopped through as a chain
    intermediate (there's no single entity to continue from), so the
    hop-chain walk is the one reader of this schema that only ever
    encounters the bare form in practice -- but it still gets the encoded
    string for a wrapped field rather than silently mismatching it, since a
    `.field` chain accidentally stepping through a collection field is
    exactly the kind of mistake that should surface as an error, not be
    hidden. See `_relation_fields_of` for the per-field-list logic shared
    between the two struct kinds."""
    var schema = Dict[String, Dict[String, String]]()
    for ds in discovery.structs:
        schema[ds.parsed.name] = _relation_fields_of(ds.parsed.fields)
    for name in plain_struct_fields.keys():
        schema[name] = _relation_fields_of(plain_struct_fields[name])
    return schema^


def build_unique_fields(discovery: DiscoveryResult) -> Dict[String, List[String]]:
    """Struct name -> names of its `unique`-marked fields, for every
    `@@struct` declared project-wide. Lets `rewrite_markers` tell whether a
    `@@Type.for_<field>(...)` table-level call returns a single
    `EntityHandle[...]` (a `unique` field's `for_<field>`, or `create`) or a
    `List[EntityHandle[...]]` (any other field's) -- only the former can
    sensibly be bound to an `@@`-marked variable for further `@@name.field`
    access afterward, same reasoning as `build_function_returns`."""
    var unique_fields = Dict[String, List[String]]()
    for ds in discovery.structs:
        var names = List[String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.UNIQUE:
                names.append(field.name)
        unique_fields[ds.parsed.name] = names^
    return unique_fields^


def build_ordered_fields(discovery: DiscoveryResult) -> Dict[String, List[String]]:
    """Struct name -> names of its `ordered`-marked fields, for every
    `@@struct` declared project-wide. Lets `rewrite_markers`
    (`_is_ordered_field_query`) tell whether a `@@Type.for_<field>(...)`
    (or one of its five range-shaped siblings) table-level call returns
    `Set[EntityHandle[...]]` (an `ordered` field's own six query methods,
    see `emit_table`'s `FieldModifier.ORDERED` branch) rather than the
    `List[EntityHandle[...]]` any other field's `for_<field>` returns --
    same reasoning as `build_unique_fields`."""
    var ordered_fields = Dict[String, List[String]]()
    for ds in discovery.structs:
        var names = List[String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.ORDERED:
                names.append(field.name)
        ordered_fields[ds.parsed.name] = names^
    return ordered_fields^


def build_multi_fields(discovery: DiscoveryResult) -> Dict[String, List[String]]:
    """Struct name -> names of its `multi`-marked fields, for every
    `@@struct` declared project-wide. Lets `rewrite_markers` tell whether a
    `@@Type.distinct_<field>(...)` table-level call is keyed by the
    field's own *element* type (`relation_schema`'s already-`Set[...]`-
    encoded entry for a `multi` relation field, matching `emit_table`'s own
    `Set[ElementType]` codegen for it) rather than the field's whole
    (possibly also container-wrapped, e.g. `List[@@Employee]`) type the way
    a bare or wrapped-but-not-`multi` relation field's `distinct_<field>`
    is -- `relation_schema` alone can't distinguish those two container
    cases from each other (both get the same `Wrapper[Target]` encoding),
    same reasoning as `build_unique_fields`/`build_ordered_fields`."""
    var multi_fields = Dict[String, List[String]]()
    for ds in discovery.structs:
        var names = List[String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.MULTI:
                names.append(field.name)
        multi_fields[ds.parsed.name] = names^
    return multi_fields^


def build_plain_struct_fields(
    plain_structs: List[DiscoveredStruct],
    rel_files: List[String],
    mut plain_struct_type_params: Dict[String, List[TypeParam]],
) raises -> Dict[String, List[Field]]:
    """Plain struct name -> its own parsed field list, project-wide --
    what `emit_table`/`emit_plain_struct_from_json`/
    `_emit_from_json_field_parse` need to tell "a plain-struct-typed
    field" apart from a leaf/container one, and to recurse into *its*
    own fields to collect relation targets transitively (a plain struct
    embedded by value can itself embed a relation field, or another
    plain struct that does -- see `_collect_relation_targets` in
    `codegen.mojo`). `plain_struct_type_params` (`mut`, populated
    alongside in the same pass rather than re-scanning separately) is the
    matching plain struct name -> its own `[T: Bound, ...]` type-parameter
    list, non-empty only for a *generic* plain struct
    (`emit_plain_struct_from_json`'s own doc comment covers how that
    reaches its generated companion).

    `plain_structs` (`discover_plain_structs`, shorthand-form only) covers
    every `struct Name { field: Type, ... }`; this also scans `rel_files`
    a second time for the hand-written form (`struct Name(Traits...):`/
    `struct Name:`, an ordinary Mojo struct `discover_plain_structs`
    doesn't recognize at all) via
    `Scanner.find_next_hand_written_plain_struct_decl`/
    `parse_hand_written_plain_struct` -- its fields are already
    real, converted Mojo types (never `@@`-marked shorthand, since a
    hand-written struct's own relation field, if any, has to be spelled
    out as `EntityHandle[sqrrl__<Name>TableState]` directly), so each
    one's `type_str` is passed through `codegen.recover_relation_type_str`
    first -- reversing that conversion back to the pseudo `@@Type`/
    `List[@@Type]`/... shorthand `_relation_field_shape`/
    `_collect_relation_targets`/`_emit_from_json_field_parse` already
    expect, letting a hand-written struct's relation field (if any) flow
    through that same, single code path with nothing struct-flavor-
    specific to maintain downstream. This is what closes the one
    documented gap in JSON support: before this, a hand-written plain
    struct's own `from_json` reconstruction always raised at runtime
    (`sqrrl__from_json: unsupported type`) since its fields were entirely
    unknown to this compiler."""
    var out = Dict[String, List[Field]]()
    for ps in plain_structs:
        out[ps.parsed.name] = ps.parsed.fields.copy()
        plain_struct_type_params[ps.parsed.name] = ps.parsed.type_params.copy()

    for path in rel_files:
        var f = open(path, "r")
        var source = f.read()
        f.close()
        var sc = Scanner(source)
        try:
            while sc.find_next_hand_written_plain_struct_decl():
                var parsed = sc.parse_hand_written_plain_struct()
                var fields = List[Field]()
                for field in parsed.fields:
                    fields.append(
                        Field(
                            name=field.name,
                            type_str=recover_relation_type_str(field.type_str),
                            modifier=field.modifier,
                            is_stats=field.is_stats,
                        )
                    )
                out[parsed.name] = fields^
                plain_struct_type_params[parsed.name] = parsed.type_params.copy()
        except e:
            raise Error(path + ": " + String(e))

    return out^


