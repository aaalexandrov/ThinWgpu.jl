abstract type PassBase end

@kwdef mutable struct Commands
    encoder::WGPUCommandEncoder = WGPUCommandEncoder(C_NULL)
    commandBuffer::WGPUCommandBuffer = WGPUCommandBuffer(C_NULL)
    name::String = "Commands"
    encoderDesc::Ref{WGPUCommandEncoderDescriptor} = Ref(WGPUCommandEncoderDescriptor(C_NULL, C_NULL))
    function Commands(encoder, cmdBuffer, name, encoderDesc) 
        set_ptr_field!(pointer(name), encoderDesc, :label)
        finalizer(commands_finalize, new(
            encoder, 
            cmdBuffer, 
            name, 
            encoderDesc
        ))
    end
end

function commands_finalize(commands::Commands)
    if commands.encoder != C_NULL
        wgpuCommandEncoderRelease(commands.encoder)
        commands.encoder = WGPUCommandEncoder(C_NULL)
    end
    if commands.commandBuffer != C_NULL
        wgpuCommandBufferRelease(commands.commandBuffer)
        commands.commandBuffer = WGPUCommandBuffer(C_NULL)
    end
end

is_open(commands::Commands) = commands.encoder != C_NULL
is_closed(commands::Commands) = commands.commandBuffer != C_NULL
is_empty(commands::Commands) = !is_open(commands) && !is_closed(commands)
function open(device::Device, commands::Commands)
    @assert(is_empty(commands))
    commands.encoder = wgpuDeviceCreateCommandEncoder(device.device, commands.encoderDesc)
end

function close(commands::Commands)
    @assert(is_open(commands))
    @assert(!is_closed(commands))
    cmdBufferDesc = Ref(WGPUCommandBufferDescriptor(C_NULL, pointer(commands.name)))
    commands.commandBuffer = wgpuCommandEncoderFinish(commands.encoder, cmdBufferDesc)
    wgpuCommandEncoderRelease(commands.encoder)
    commands.encoder = WGPUCommandEncoder(C_NULL)
    @assert(is_closed(commands))
    @assert(!is_open(commands))
end

function on_submitted(commands::Commands)
    @assert(is_closed(commands))
    @assert(!is_open(commands))
    wgpuCommandBufferRelease(commands.commandBuffer)
    commands.commandBuffer = WGPUCommandBuffer(C_NULL)
    @assert(is_empty(commands))
end

function submit(device::Device, commandsArray)
    @assert(length(device.submitCommandBuffers) == 0)
    for commands in commandsArray
        if is_open(commands)
            close(commands)
        end
        push!(device.submitCommandBuffers, commands.commandBuffer)
    end
    wgpuQueueSubmit(device.queue, length(device.submitCommandBuffers), pointer(device.submitCommandBuffers, 1))
    resize!(device.submitCommandBuffers, 0)
    foreach(on_submitted, commandsArray)
end

@kwdef mutable struct RenderPass <: PassBase
    encoder::WGPURenderPassEncoder = WGPURenderPassEncoder(C_NULL)
    name::String = "RenderPass"
    RenderPass(encoder, name) = finalizer(render_pass_finalize, new(encoder, name))
end

function render_pass_finalize(renderPass::RenderPass)
    if renderPass.encoder != C_NULL
        wgpuRenderPassEncoderRelease(renderPass.encoder)
        renderPass.encoder = WGPURenderPassEncoder(C_NULL)
    end
end

function begin_pass(renderPass::RenderPass, commands::Commands, passDesc::ComplexStruct{WGPURenderPassDescriptor})
    @assert(renderPass.encoder == C_NULL)
    @assert(is_open(commands))
    renderPass.encoder = GC.@preserve passDesc wgpuCommandEncoderBeginRenderPass(commands.encoder, passDesc.obj)
end
begin_pass(renderPass::RenderPass, commands::Commands; renderPassDesc...) = begin_pass(renderPass, commands, ComplexStruct(WGPURenderPassDescriptor; renderPassDesc...))

set_pipeline(renderPass::RenderPass, pipeline::Pipeline) = wgpuRenderPassEncoderSetPipeline(renderPass.encoder, pipeline.pipeline)
function set_bind_group(renderPass::RenderPass, groupIndex::Integer, group::WGPUBindGroup, dynamicOffsets = ()) 
    wgpuRenderPassEncoderSetBindGroup(renderPass.encoder, groupIndex, group, length(dynamicOffsets), length(dynamicOffsets) > 0 ? pointer(dynamicOffsets, 1) : C_NULL)
end
function set_vertex_buffer(renderPass::RenderPass, slot::Integer, buffer::Buffer, offset::Integer = 0, size::Integer = 0)
    wgpuRenderPassEncoderSetVertexBuffer(renderPass.encoder, slot, buffer.buffer, offset, size > 0 ? size : get_size(buffer))
end
function set_index_buffer(renderPass::RenderPass, buffer::Buffer, offset::Integer = 0, size::Integer = 0)
    wgpuRenderPassEncoderSetIndexBuffer(
        renderPass.encoder, 
        buffer.buffer, 
        TypeToIndexFormat(eltype(buffer.contentType)), 
        offset, size > 0 ? size : get_size(buffer)
    )
end
function draw(renderPass::RenderPass, vertexCount::Integer, instanceCount::Integer = 1, firstVertex::Integer = 0, firstInstance::Integer = 0)
    wgpuRenderPassEncoderDraw(renderPass.encoder, vertexCount, instanceCount, firstVertex, firstInstance)
end    

function end_pass(renderPass::RenderPass)
    @assert(renderPass.encoder != C_NULL)
    wgpuRenderPassEncoderEnd(renderPass.encoder)
    wgpuRenderPassEncoderRelease(renderPass.encoder)
    renderPass.encoder = WGPURenderPassEncoder(C_NULL)
end

@kwdef mutable struct ComputePass <: PassBase
    encoder::WGPUComputePassEncoder = WGPUComputePassEncoder(C_NULL)
    name::String = "ComputePass"
    ComputePass(encoder, name) = finalizer(compute_pass_finalize, new(encoder, name))
end

function compute_pass_finalize(computePass::ComputePass)
    if computePass.encoder != C_NULL
        wgpuComputePassEncoderRelease(computePass.encoder)
        computePass.encoder = WGPUComputePassEncoder(C_NULL)
    end
end

function begin_pass(computePass::ComputePass, commands::Commands, passDesc::ComplexStruct{WGPUComputePassDescriptor})
    @assert(computePass.encoder == C_NULL)
    @assert(is_open(commands))
    computePass.encoder = GC.@preserve passDesc wgpuCommandEncoderBeginComputePass(commands.encoder, passDesc.obj)
end
begin_pass(computePass::ComputePass, commands::Commands; computePassDesc...) = begin_pass(computePass, commands, ComplexStruct(WGPUComputePassDescriptor; computePassDesc...))

set_pipeline(computePass::ComputePass, pipeline::Pipeline) = wgpuComputePassEncoderSetPipeline(computePass.encoder, pipeline.pipeline)
function set_bind_group(computePass::ComputePass, groupIndex::Integer, group::WGPUBindGroup, dynamicOffsets = ()) 
    wgpuComputePassEncoderSetBindGroup(computePass.encoder, groupIndex, group, length(dynamicOffsets), length(dynamicOffsets) > 0 ? pointer(dynamicOffsets, 1) : C_NULL)
end
function dispatch(computePass::ComputePass, workgroupCountX::Integer = 1, workGroupCountY::Integer = 1, workgroupCountZ::Integer = 1)
    wgpuComputePassEncoderDispatchWorkgroups(computePass.encoder, workgroupCountX, workgroupCountY, workgroupCountZ)
end

function end_pass(computePass::ComputePass)
    @assert(computePass.encoder != C_NULL)
    wgpuComputePassEncoderEnd(computePass.encoder)
    wgpuComputePassEncoderRelease(computePass.encoder)
    computePass.encoder = WGPUComputePassEncoder(C_NULL)
end

