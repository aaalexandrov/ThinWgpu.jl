function CreateWGSLShaderModule(device::WGPUDevice, label::String, source::String)::WGPUShaderModule
    sourceDesc = Ref(WGPUShaderModuleWGSLDescriptor(
        WGPUChainedStruct(C_NULL, WGPUSType_ShaderModuleWGSLDescriptor),
        pointer(source)
    ))
    shaderDesc = Ref(WGPUShaderModuleDescriptor(
        Ptr{WGPUChainedStruct}(Base.unsafe_convert(Ptr{Cvoid}, sourceDesc)),
        pointer(label),
        0,
        C_NULL
    ))
    GC.@preserve label source sourceDesc wgpuDeviceCreateShaderModule(device, shaderDesc)
end

function CreateBindGroupLayout(device::WGPUDevice; bindingLayoutDescs...)::WGPUBindGroupLayout
    bindGroupDesc = ComplexStruct(WGPUBindGroupLayoutDescriptor; bindingLayoutDescs...)
    GC.@preserve bindGroupDesc wgpuDeviceCreateBindGroupLayout(device, bindGroupDesc.obj)
end

function GetVertexFormat(::Type{T}, unorm::Bool = false)::WGPUVertexFormat where T
    local baseType
    dim = fieldcount(T)
    elemType = eltype(T)
    if elemType == Float32
        baseType = "Float32"
    elseif elemType == UInt8
        baseType = unorm ? "Unorm8" : "Uint8"
    elseif elemType == Int8
        baseType = unorm ? "Snorm8" : "Sint8"
    elseif elemType == UInt16
        baseType = unorm ? "Unorm16" : "Uint16"
    elseif elemType == Int16
        baseType = unorm ? "Snorm16" : "Sint16"
    elseif elemType == UInt32
        baseType = "Uint32"
    elseif elemType == Int32
        baseType = "Sint32"
    else
        error("Unrecognized type")
    end
    valName = "WGPUVertexFormat_$baseType"
    if dim > 1
        valName = "$(valName)x$dim"
    end
    valName = Symbol(valName)
    ind = findfirst(x->x[1] == valName, CEnum.name_value_pairs(WGPUVertexFormat))
    isnothing(ind) ? WGPUVertexFormat_Undefined : WGPUVertexFormat(CEnum.name_value_pairs(WGPUVertexFormat)[ind][2]) 
end

function FillVertexAttributes(::Type{T}, attrs::Vector{WGPUVertexAttribute}) where T
    for i in 1:fieldcount(T)
        vertexFormat = GetVertexFormat(fieldtype(T, i))
        @assert(vertexFormat != WGPUVertexFormat_Undefined)
        push!(attrs, WGPUVertexAttribute(
            vertexFormat,
            fieldoffset(T, i),
            length(attrs)
        ))
    end
end

function GetVertexLayout(::Type{T}, attrs::Vector{WGPUVertexAttribute})::WGPUVertexBufferLayout where T
    FillVertexAttributes(T, attrs)
    WGPUVertexBufferLayout(
        sizeof(T),
        WGPUVertexStepMode_Vertex,
        length(attrs),
        pointer(attrs, 1)
    )
end

function CreateBindGroup(device::WGPUDevice, name::String, bindGroupLayout::WGPUBindGroupLayout, bindings::Vector{Any})::WGPUBindGroup
    bindGroupEntries = WGPUBindGroupEntry[]
    resize!(bindGroupEntries, length(bindings))
    Base.memset(pointer(bindGroupEntries, 1), 0, sizeof(bindGroupEntries))
    for i in 1:length(bindings)
        entry = pointer(bindGroupEntries, i)
        set_ptr_field!(entry, :binding, i - 1)
        bind = bindings[i]
        if typeof(bind) == WGPUBuffer
            set_ptr_field!(entry, :buffer, bind)
            set_ptr_field!(entry, :size, wgpuBufferGetSize(bind))
        elseif typeof(bind) == WGPUSampler
            set_ptr_field!(entry, :sampler, bind)
        elseif typeof(bind) == WGPUTextureView
            set_ptr_field!(entry, :textureView, bind)
        else
            error("Unrecognized binding")
        end
    end
    bindGroupDesc = Ref(WGPUBindGroupDescriptor(
        C_NULL,
        pointer(name),
        bindGroupLayout,
        length(bindGroupEntries),
        pointer(bindGroupEntries, 1)
    ))
    GC.@preserve name bindGroupEntries wgpuDeviceCreateBindGroup(device, bindGroupDesc)
end    

const entryVs = "vs_main"
const entryFs = "fs_main"

function CreateWGSLRenderPipeline(device::WGPUDevice, name::String, source::String, vertexType::Type, bindGroupLayouts::Vector{WGPUBindGroupLayout}, surfFormat::WGPUTextureFormat)::WGPURenderPipeline
    shader = CreateWGSLShaderModule(device, name, source)

    layoutDesc = Ref(WGPUPipelineLayoutDescriptor(
        C_NULL,
        pointer(name),
        length(bindGroupLayouts),
        pointer(bindGroupLayouts, 1)
    ))
    pipelineLayout = GC.@preserve name bindGroupLayouts wgpuDeviceCreatePipelineLayout(device, layoutDesc)

    colorTargets = [WGPUColorTargetState(
        C_NULL,
        surfFormat,
        C_NULL,
        WGPUColorWriteMask_All
    )]
    fragmentState = Ref(WGPUFragmentState(
        C_NULL,
        shader,
        pointer(entryFs),
        0,
        C_NULL,
        length(colorTargets),
        pointer(colorTargets, 1)
    ))
    vertexAttrs = WGPUVertexAttribute[]
    vertexLayout = [GetVertexLayout(vertexType, vertexAttrs)]
    pipelineDesc = Ref(WGPURenderPipelineDescriptor(
        C_NULL,
        pointer(name),
        pipelineLayout,
        WGPUVertexState(
            C_NULL,
            shader,
            pointer(entryVs),
            0,
            C_NULL,
            length(vertexLayout),
            pointer(vertexLayout, 1)
        ),
        WGPUPrimitiveState(
            C_NULL,
            WGPUPrimitiveTopology_TriangleList,
            WGPUIndexFormat_Undefined,
            WGPUFrontFace_CCW,
            WGPUCullMode_None
        ),
        C_NULL,
        WGPUMultisampleState(
            C_NULL,
            1,
            typemax(UInt32),
            false
        ),
        ptr_from_ref(fragmentState)
    ))
    pipeline = GC.@preserve name entryVs entryFs colorTargets vertexAttrs vertexLayout fragmentState wgpuDeviceCreateRenderPipeline(device, pipelineDesc)

    wgpuPipelineLayoutRelease(pipelineLayout)
    wgpuShaderModuleRelease(shader)

    pipeline
end

abstract type PipelineBase end

mutable struct Shader
    shader::WGPUShaderModule
    name::String
    stages::WGPUShaderStageFlags
    bindGroupLayouts::Vector{WGPUBindGroupLayout}
    function Shader(device::Device, name::String, source::String, stages::WGPUShaderStageFlags, bindGroupLayoutDescs)
        shader = CreateWGSLShaderModule(device.device, name, source)
        bindGroupLayouts = [CreateBindGroupLayout(device.device; groupDesc...) for groupDesc in bindGroupLayoutDescs]
        obj = new(shader, name, stages, bindGroupLayouts)
        finalizer(shader_finalize, obj)
    end
end

function shader_finalize(shader::Shader)
    foreach(wgpuBindGroupLayoutRelease, shader.bindGroupLayouts)
    resize!(shader.bindGroupLayouts, 0)
    if shader.shader != C_NULL
        wgpuShaderModuleRelease(shader.shader)
        shader.shader = C_NULL
    end
end