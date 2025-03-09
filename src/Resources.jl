function CreateBuffer(device::WGPUDevice, queue::WGPUQueue, name::String, usage::WGPUBufferUsageFlags, content)::WGPUBuffer
    bufferDesc = Ref(WGPUBufferDescriptor(
        C_NULL,
        pointer(name),
        usage | WGPUBufferUsage_CopyDst,
        sizeof(content),
        false
    ))
    buffer = GC.@preserve name wgpuDeviceCreateBuffer(device, bufferDesc)
    ptrContent = typeof(content) <: Ref ? ptr_from_ref(content) : pointer(content)
    GC.@preserve content wgpuQueueWriteBuffer(queue, buffer, 0, ptrContent, bufferDesc[].size)
    buffer
end

function CreateSampler(device::WGPUDevice, name::String, addressMode::WGPUAddressMode, filterMode::WGPUFilterMode)::WGPUSampler
    samplerDesc = Ref(WGPUSamplerDescriptor(
        C_NULL,
        pointer(name),
        addressMode,
        addressMode,
        addressMode,
        filterMode,
        filterMode,
        filterMode == WGPUFilterMode_Nearest ? WGPUMipmapFilterMode_Nearest : WGPUMipmapFilterMode_Linear,
        0,
        typemax(Float32),
        WGPUCompareFunction_Undefined,
        filterMode == WGPUFilterMode_Nearest ? 1 : typemax(UInt16)
    ))
    GC.@preserve name wgpuDeviceCreateSampler(device, samplerDesc)
end

function TypeToTextureFormat(::Type{T}) where T
    if T == UInt8
        return WGPUTextureFormat_R8Unorm
    end
    if T == NTuple{4, UInt8}
        return WGPUTextureFormat_RGBA8Unorm
    end
    error("Unknown type for texture format")
end

function CreateTexture(device::WGPUDevice, queue::WGPUQueue, name::String, usage::WGPUTextureUsage, content)::WGPUTexture
    contentDim = [size(content)..., 1, 1]
    textureDesc = Ref(WGPUTextureDescriptor(
        C_NULL,
        pointer(name),
        WGPUTextureUsage(usage | WGPUTextureUsage_CopyDst),
        WGPUTextureDimension(WGPUTextureDimension_1D + ndims(content) - 1),
        WGPUExtent3D(contentDim[1], contentDim[2], contentDim[3]),
        TypeToTextureFormat(eltype(content)),
        UInt32(ceil(log2(maximum(size(content))))),
        1,
        0,
        C_NULL
    ))
    texture = GC.@preserve name wgpuDeviceCreateTexture(device, textureDesc)
    imageCopyTex = Ref(WGPUImageCopyTexture(
        C_NULL,
        texture,
        0,
        WGPUOrigin3D(0, 0, 0),
        WGPUTextureAspect_All
    ))
    texLayout = Ref(WGPUTextureDataLayout(
        C_NULL,
        0,
        contentDim[1] * sizeof(eltype(content)),
        contentDim[1] * contentDim[2] * sizeof(eltype(content))
    ))
    GC.@preserve textureDesc, wgpuQueueWriteTexture(queue, imageCopyTex, pointer(content), sizeof(content), texLayout, ptr_to_field(textureDesc, :size))
    texture
end
