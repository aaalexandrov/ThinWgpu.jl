function CreateBuffer(device::WGPUDevice; bufferDesc...)::WGPUBuffer
    bufDesc = ComplexStruct(WGPUBufferDescriptor; bufferDesc...)
    GC.@preserve bufDesc wgpuDeviceCreateBuffer(device, bufDesc.obj)
end

function CreateSampler(device::WGPUDevice; samplerDesc...)::WGPUSampler
    sampDesc = ComplexStruct(WGPUSamplerDescriptor; samplerDesc...)
    GC.@preserve sampDesc wgpuDeviceCreateSampler(device, sampDesc.obj)
end

function TypeToTextureFormat(::Type{T})::WGPUTextureFormat where T
    if T == UInt8
        return WGPUTextureFormat_R8Unorm
    end
    if T == NTuple{4, UInt8}
        return WGPUTextureFormat_RGBA8Unorm
    end
    error("Unknown type for texture format")
end

function TypeToIndexFormat(::Type{T})::WGPUIndexFormat where T
    if T == UInt16
        return WGPUIndexFormat_Uint16
    elseif T == UInt32
        return WGPUIndexFormat_Uint32
    end
    error("Invalid index format type")
end

function CreateTexture(device::WGPUDevice; textureDesc...)::WGPUTexture
    texDesc = ComplexStruct(WGPUTextureDescriptor; textureDesc...)
    GC.@preserve texDesc wgpuDeviceCreateTexture(device, texDesc.obj)
end

mutable struct Buffer
    buffer::WGPUBuffer
    name::String
    contentType::DataType
    function Buffer(device::Device, contentType::DataType; bufferDesc...)
        name = bufferDesc[:label]
        bufDesc = ComplexStruct(WGPUBufferDescriptor; bufferDesc...)
        buffer = GC.@preserve bufDesc wgpuDeviceCreateBuffer(device.device, bufDesc.obj)
        obj = new(buffer, name, contentType)
        finalizer(buffer_finalize, obj)
    end
end

function Buffer(device::Device, content; bufferDesc...)
    usage = bufferDesc[:usage]
    if usage in (WGPUBufferUsage_Index, WGPUBufferUsage_Vertex, WGPUBufferUsage_Uniform)
        usage |= WGPUBufferUsage_CopyDst
    end
    name = get(bufferDesc, :label, "buffer")
    mergedDesc = recursive_merge((;bufferDesc...), (;
        label = name, 
        size = sizeof(content), 
        usage = usage,
    ))
    buffer = Buffer(device, typeof(content); mergedDesc...)
    write(device, buffer, content)
    buffer
end

function buffer_finalize(buffer::Buffer)
    if buffer.buffer != C_NULL
        wgpuBufferRelease(buffer.buffer)
        buffer.buffer = WGPUBuffer(C_NULL)
    end
end

get_size(buffer::Buffer)::UInt64 = wgpuBufferGetSize(buffer.buffer)

function write(device::Device, buffer::Buffer, content, offset::UInt64 = zero(UInt64))
    data = isa(content, AbstractArray) ? pointer(content, 1) : pointer_from_objref(content)
    wgpuQueueWriteBuffer(device.queue, buffer.buffer, offset, data, sizeof(content))
end

mutable struct Sampler
    sampler::WGPUSampler
    name::String
    function Sampler(device::Device; samplerDesc...)
        name = samplerDesc[:label]
        sampler = CreateSampler(device.device; samplerDesc...)
        finalizer(sampler_finalize, new(sampler, name))
    end
end

function sampler_finalize(sampler::Sampler)
    if sampler.sampler != C_NULL
        wgpuSamplerRelease(sampler.sampler)
        sampler.sampler = WGPUSampler(C_NULL)
    end
end

@kwdef mutable struct Texture
    texture::WGPUTexture = WGPUTexture(C_NULL)
    view::WGPUTextureView = WGPUTextureView(C_NULL)
    name::String = "texture"
    Texture(texture, view, name) = finalizer(texture_finalize, new(texture, view, name))
end

function Texture(device::Device; textureDesc...)
    name = textureDesc[:label]
    texture = CreateTexture(device.device; textureDesc...)
    # TODO - use a texture view desc to set the name
    view = wgpuTextureCreateView(texture, C_NULL)
    Texture(texture, view, name)
end

function Texture(device::Device, content; textureDesc...)
    contentDim = (size(content)..., 1, 1)
    name = get(textureDesc, :label, "texture")
    usage = get(textureDesc, :usage, WGPUTextureUsage_TextureBinding)
    if usage == WGPUTextureUsage_TextureBinding
        usage |= WGPUTextureUsage_CopyDst
    end
    dimension = get(textureDesc, :dimension, WGPUTextureDimension(WGPUTextureDimension_1D + ndims(content) - 1))
    texSize = get(textureDesc, :size, WGPUExtent3D(contentDim[1], contentDim[2], contentDim[3]))
    format = get(textureDesc, :format, TypeToTextureFormat(eltype(content)))
    mipLevelCount = get(textureDesc, :mipLevelCount, UInt32(floor(log2(maximum(size(content))))) + 1)
    sampleCount = get(textureDesc, :sampleCount, 1)
    mergedDesc = recursive_merge((;textureDesc...), (;
        label = name,
        usage = usage,
        dimension = dimension,
        size = texSize,
        format = format,
        mipLevelCount = mipLevelCount,
        sampleCount = sampleCount,
    ))
    texture = Texture(device; mergedDesc...)
    write(device, texture, content)
    texture
end

function texture_finalize(texture::Texture)
    if texture.texture != C_NULL
        wgpuTextureRelease(texture.texture)
        texture.texture = WGPUTexture(C_NULL)
        wgpuTextureViewRelease(texture.view)
        texture.view = WGPUTextureView(C_NULL)
    end
end

get_usage(texture::Texture)::WGPUTextureUsageFlags = wgpuTextureGetUsage(texture.texture)
get_format(texture::Texture)::WGPUTextureFormat = wgpuTextureGetFormat(texture.texture)
get_dimension(texture::Texture)::WGPUTextureDimension = wgpuTextureGetDimension(texture.texture)
get_size(texture::Texture)::NTuple{4, UInt32} = (
    wgpuTextureGetWidth(texture.texture), 
    wgpuTextureGetHeight(texture.texture), 
    wgpuTextureGetDepthOrArrayLayers(texture.texture), 
    wgpuTextureGetMipLevelCount(texture.texture)
)
get_sample_count(texture::Texture)::UInt32 = wgpuTextureGetSampleCount(texture.texture)

function write(device::Device, texture::Texture, content, offset::NTuple{4, UInt32} = convert(NTuple{4, UInt32}, (0,0,0,0)), aspect::WGPUTextureAspect = WGPUTextureAspect_All)
    imgCopy = Ref(WGPUImageCopyTexture(
        C_NULL,
        texture.texture,
        offset[4],
        WGPUOrigin3D(offset[1], offset[2], offset[3]),
        aspect
    ))
    contentDim = (size(content)..., 1, 1)
    dataLayout = Ref(WGPUTextureDataLayout(
        C_NULL,
        0,
        contentDim[1] * sizeof(eltype(content)),
        contentDim[1] * contentDim[2] * sizeof(eltype(content))
    ))
    extent = Ref(WGPUExtent3D(contentDim[1], contentDim[2], contentDim[3]))
    wgpuQueueWriteTexture(device.queue, imgCopy, pointer(content, 1), sizeof(content), dataLayout, extent)
end