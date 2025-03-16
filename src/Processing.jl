abstract type PassBase end

@kwdef mutable struct Commands
    encoder::WGPUCommandEncoder = WGPUCommandEncoder(C_NULL)
    commandBuffer::WGPUCommandBuffer = WGPUCommandBuffer(C_NULL)
    name::String = "Commands"
end

