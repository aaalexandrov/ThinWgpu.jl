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
    bindGroupLayoutDesc = ComplexStruct(WGPUBindGroupLayoutDescriptor; bindingLayoutDescs...)
    GC.@preserve bindGroupLayoutDesc wgpuDeviceCreateBindGroupLayout(device, bindGroupLayoutDesc.obj)
end

function CreateBindGroup(device::WGPUDevice; bindGroupDesc...)
    bindGroupDesc = ComplexStruct(WGPUBindGroupDescriptor; bindGroupDesc...)
    GC.@preserve bindGroupDesc wgpuDeviceCreateBindGroup(device, bindGroupDesc.obj)
end

function GetVertexFormat(::Type{T}, unorm::Bool = false)::WGPUVertexFormat where T
    local baseType
    dim = length(T)
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

const entryVs = "vs_main"
const entryFs = "fs_main"
const entryCs = "cs_main"

mutable struct Shader
    shader::WGPUShaderModule
    name::String
    stages::WGPUShaderStageFlags
    bindGroupLayouts::Vector{WGPUBindGroupLayout}
    pipelineLayout::WGPUPipelineLayout
    function Shader(device::Device, name::String, source::String, stages::WGPUShaderStageFlags, bindGroupLayoutDescs)
        shader = CreateWGSLShaderModule(device.device, name, source)
        bindGroupLayouts = [CreateBindGroupLayout(device.device; groupDesc...) for groupDesc in bindGroupLayoutDescs]
        pipelineLayoutDesc = ComplexStruct(WGPUPipelineLayoutDescriptor;
            label = name,
            bindGroupLayouts = bindGroupLayouts,
        )
        pipelineLayout = GC.@preserve pipelineLayoutDesc wgpuDeviceCreatePipelineLayout(device.device, pipelineLayoutDesc.obj)
        obj = new(shader, name, stages, bindGroupLayouts, pipelineLayout)
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

mutable struct Pipeline
    pipeline::Union{WGPURenderPipeline, WGPUComputePipeline}
    shader::Shader
    name::String
    function Pipeline(device::Device, shader::Shader; pipelineDesc...)
        name = get(pipelineDesc, :name, shader.name)
        pipeline = nothing
        if (shader.stages & WGPUShaderStage_Compute) != 0
            mergedDesc = recursive_merge((;pipelineDesc...), (;
                label = name,
                layout = shader.pipelineLayout,
                compute = (_module = shader.shader, entryPoint = entryCs),
            ))
            pipeDesc = ComplexStruct(WGPUComputePipelineDescriptor; mergedDesc...)
            pipeline = GC.@preserve pipeDesc wgpuDeviceCreateComputePipeline(device.device, pipeDesc.obj)
        else
            mergedDesc = recursive_merge((;pipelineDesc...), (;
                label = name,
                layout = shader.pipelineLayout,
                vertex = (_module = shader.shader, entryPoint = entryVs),
                fragment = (_module = shader.shader, entryPoint = entryFs),
            ))
            pipeDesc = ComplexStruct(WGPURenderPipelineDescriptor; mergedDesc...)
            pipeline = GC.@preserve pipeDesc wgpuDeviceCreateRenderPipeline(device.device, pipeDesc.obj)
        end
        obj = new(pipeline, shader, name)
        finalizer(render_pipeline_finalize, obj)
    end
end

function render_pipeline_finalize(pipeline::Pipeline)
    if pipeline.pipeline != C_NULL
        if isa(pipeline.pipeline, WGPURenderPipeline)
            wgpuRenderPipelineRelease(pipeline.pipeline)
            pipeline.pipeline = convert(WGPURenderPipeline, C_NULL)
        elseif isa(pipeline.pipeline, WGPUComputePipeline)
            wgpuComputePipelineRelease(pipeline.pipeline)
            pipeline.pipeline = convert(WGPUComputePipeline, C_NULL)
        end
    end
end