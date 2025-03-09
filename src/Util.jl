import Base.zero

zero(::Type{NTuple{N,T}}) where {N,T}=ntuple(i->zero(T), N)
zero_ref!(ref::Ref{T}) where T = Base.unsafe_securezero!(Base.unsafe_convert(Ptr{T}, ref))
ptr_from_ref(ref::Ref{T}) where T = Base.unsafe_convert(Ptr{T}, ref)

function ptr_to_field(p::Ptr{T}, name::Symbol) where T
    fieldIndex = Base.fieldindex(T, name)
    fieldType = fieldtype(T, fieldIndex)
    fieldOffs = fieldoffset(T, fieldIndex)
    convert(Ptr{fieldType}, p + fieldOffs)
end
ptr_to_field(ref::Ref{T}, name::Symbol) where T = ptr_to_field(ptr_from_ref(ref), name)

get_ptr_field(p::Ptr{T}, name::Symbol) where T = unsafe_load(ptr_to_field(p, name))
get_ptr_field(p::Ref{T}, name::Symbol) where T = get_ptr_field(ptr_from_ref(p), name)
set_ptr_field!(p::Ptr{T}, name::Symbol, val) where T = unsafe_store!(ptr_to_field(p, name), val)
set_ptr_field!(p::Ref{T}, name::Symbol, val) where T = set_ptr_field!(ptr_from_ref(p), name, val)
