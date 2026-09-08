/// Comptime verification of Serializer and Deserializer interfaces.
/// Whether S implements the full Serializer interface.
pub fn isSerializer(comptime S: type) bool {
    return @hasDecl(S, "serializeBool") and
        @hasDecl(S, "serializeInt") and
        @hasDecl(S, "serializeFloat") and
        @hasDecl(S, "serializeString") and
        @hasDecl(S, "serializeNull") and
        @hasDecl(S, "serializeVoid") and
        @hasDecl(S, "beginArray") and
        @hasDecl(S, "beginStruct");
}

/// Whether S implements the optional length-aware container API.
///
/// `beginArray` / `beginStruct` let a serializer discover the element count
/// only at `end()`, which forces length-prefixed formats such as MessagePack
/// to buffer the payload. A serializer may additionally declare:
///
///     fn beginArrayLen(self: *S, len: usize) Error!ArrayContainer
///     fn beginStructLen(self: *S, len: usize) Error!StructContainer
///
/// which the core calls whenever the count is known up front, letting the
/// serializer emit the header first and stream the payload.
///
/// Contract: the caller must emit **exactly** `len` elements or fields into
/// the returned container before calling `end()`. Writing a different number
/// silently produces a malformed document, so serializers are encouraged to
/// assert the count under `std.debug.runtime_safety`.
///
/// Both declarations must be present or absent together.
pub fn hasKnownLengthContainers(comptime S: type) bool {
    const has_array = @hasDecl(S, "beginArrayLen");
    const has_struct = @hasDecl(S, "beginStructLen");
    if (has_array != has_struct)
        @compileError(@typeName(S) ++ " must declare both beginArrayLen and beginStructLen, or neither");
    return has_array;
}

/// Whether D implements the full Deserializer interface.
pub fn isDeserializer(comptime D: type) bool {
    return @hasDecl(D, "deserializeBool") and
        @hasDecl(D, "deserializeInt") and
        @hasDecl(D, "deserializeFloat") and
        @hasDecl(D, "deserializeString") and
        @hasDecl(D, "deserializeOptional") and
        @hasDecl(D, "deserializeStruct") and
        @hasDecl(D, "deserializeSeq") and
        @hasDecl(D, "deserializeEnum");
}
