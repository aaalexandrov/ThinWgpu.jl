import Base.zero

try_convert(::Type{T}, v) where T = try convert(T, v) catch end
zero(::Type{NTuple{N,T}}) where {N,T}=ntuple(i->zero(T), N)
zero_ref!(ref::Ref{T}) where T = Base.unsafe_securezero!(Base.unsafe_convert(Ptr{T}, ref))
ptr_from_ref(ref::Ref{T}) where T = convert(Ptr{T}, pointer_from_objref(ref))

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

hash_by_value_count(v, field::Symbol) = 1
function hash_by_value(v::T, h::UInt = zero(UInt), ptrLen::UInt = one(UInt))::UInt where T
    if T <: Array || T <: Tuple
        for i in eachindex(v)
            h = hash_by_value(v[i], h)
        end
    elseif T <: Ptr && v != C_NULL && T != Ptr{Cvoid}
        for i = 1:ptrLen
            h = hash_by_value(unsafe_load(v, i), h)
        end
    elseif T <: Ref
        h = hash_by_value(v[], h)
    elseif isstructtype(T) && !(T <: String)
        for f in fieldnames(T)
            h = hash_by_value(getfield(v, f), h, hash_by_value_count(v, f))
        end
    else
        h = hash(v, h)
    end
    h
end

function init_is_array_field(::Type{T}, i) where T
    @assert(fieldtype(T, i) <: Ptr)
    return i > 1 && fieldtype(T, i-1) <: Integer && endswith(string(fieldname(T, i-1)), "Count")
end

function init_convert(::Type{T}, v) where T
    try
        return convert(T, v)
    catch
    end
    if T <: Ptr
        if isa(v, Ref)
            return pointer_from_objref(v)
        elseif isa(v, String)
            return pointer(v)
        end
    end
end
function init_val(::Type{T}, objs::Array{Any}; vals...)::T where T
    if T <: Ptr
        convert(T, C_NULL)
    elseif T <: CEnum.Cenum
        z = T(zero(CEnum.basetype(T)))
        typemin(T) <= z <= typemax(T) ? z : typemin(T)
    elseif isstructtype(T)
        @assert(all(f->f in fieldnames(T), keys(vals)))
        params = []
        for (i,f) in pairs(fieldnames(T))
            type = fieldtype(T, f)
            fieldVal = nothing
            if haskey(vals, f) 
                val = vals[f]
                fieldVal = init_convert(type, val)
                if isnothing(fieldVal)
                    if type <: Ptr
                        if init_is_array_field(T, i)
                            fieldVec = Vector{eltype(type)}()
                            for v in eachindex(val)
                                push!(fieldVec, init_val(eltype(type), objs; val[v]...))
                            end
                            push!(objs, fieldVec)
                            params[i-1] = length(fieldVec) # the previous parameter is the array count, set it
                            fieldVal = pointer(fieldVec, 1)
                        else
                            refVal = Ref(init_val(eltype(type), objs; val...))
                            push!(objs, refVal)
                            fieldVal = ptr_from_ref(refVal)
                        end
                    else
                        fieldVal = init_val(type, objs; val...)
                    end
                else
                    if !isimmutable(val)
                        push!(objs, val)
                    end
                end
            else 
                fieldVal = init_val(type, objs)
            end
            push!(params, fieldVal)
        end
        T(params...)
    else
        zero(T)
    end
end

struct ComplexStruct{T}
    obj::Ref{T}
    sub::Vector{Any}
end

function ComplexStruct(::Type{T}; vals...) where T
    sub = Any[]
    ComplexStruct{T}(Ref(init_val(T, sub; vals...)), sub)
end