const downsampleName = "#downsample.wgsl"
const downsampleWorkgroupSize = (8, 8)

function GetTextureFormatString(format::WGPUTextureFormat)
    nameStr = string(Base.Symbol(format))
    nameStr = replace(nameStr, "WGPUTextureFormat_" => "")
    return lowercase(nameStr)
end

function GetDownsampleShaderSrc(formatString::String)::String
    """
    @group(0) @binding(0) var srcTex: texture_2d<f32>;
    @group(0) @binding(1) var dstTex: texture_storage_2d<$(formatString), write>;

    fn compute_sample(s00: vec4f, s01: vec4f, s10: vec4f, s11: vec4f) -> vec4f {
        return (s00 + s01 + s10 + s11) * 0.25;
    }

    @compute @workgroup_size$(downsampleWorkgroupSize)
    fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
        let srcCoord = 2u * id.xy;
        let s00 = textureLoad(srcTex, srcCoord + vec2u(0, 0), 0);
        let s01 = textureLoad(srcTex, srcCoord + vec2u(0, 1), 0);
        let s10 = textureLoad(srcTex, srcCoord + vec2u(1, 0), 0);
        let s11 = textureLoad(srcTex, srcCoord + vec2u(1, 1), 0);            
        let sample = compute_sample(s00, s01, s10, s11);
        textureStore(dstTex, id.xy, sample);
    }
    """
end

const downsamplePipelines = Dict{WGPUTextureFormat, Pipeline}()

function GetDownsamplePipeline(device::Device, format::WGPUTextureFormat)::Pipeline
    get!(downsamplePipelines, format) do 
        fmtString = GetTextureFormatString(format)
        src = GetDownsampleShaderSrc(fmtString)
        shaderName = downsampleName * fmtString
        stageFlags = WGPUShaderStageFlags(WGPUShaderStage_Compute)
        shader = Shader(device, shaderName, src, stageFlags,
            (
                (;
                    label = shaderName,
                    entries = (
                        (binding = 0, visibility = stageFlags, texture = (
                            sampleType = WGPUTextureSampleType_Float, 
                            viewDimension = WGPUTextureViewDimension_2D,
                        ),),
                        (binding = 1, visibility = stageFlags, storageTexture = (
                            access = WGPUStorageTextureAccess_WriteOnly, 
                            format = format, 
                            viewDimension = WGPUTextureViewDimension_2D,
                        ),),
                    ),
                ),
            )
        )
        Pipeline(device, shader)
    end
end

function downsample_texture(device::Device, computePass::ComputePass, texture::Texture)
    viewDesc = Ref(WGPUTextureViewDescriptor(
        C_NULL,
        pointer(texture.name),
        get_format(texture),
        WGPUTextureViewDimension_2D,
        0,
        1,
        0,
        1,
        WGPUTextureAspect_All
    ))
    viewSrc = wgpuTextureCreateView(texture.texture, viewDesc)
    pipeline = GetDownsamplePipeline(device, viewDesc[].format)
    bindGroupDesc = ComplexStruct(WGPUBindGroupDescriptor;
        label = "downsample",
        layout = pipeline.shader.bindGroupLayouts[1],
        entries = (
            (binding = 0, textureView = viewSrc),
            (binding = 1, textureView = viewSrc),
        ),
    )
    texSize = get_size(texture)
    set_pipeline(computePass, pipeline)
    for l = 1:texSize[4]-1
        set_ptr_field!(l, viewDesc, :baseMipLevel)
        viewDst = wgpuTextureCreateView(texture.texture, viewDesc)
        set_ptr_field!(viewSrc, bindGroupDesc.obj, :entries, 1, :textureView)
        set_ptr_field!(viewDst, bindGroupDesc.obj, :entries, 2, :textureView)
        bindGroup = wgpuDeviceCreateBindGroup(device.device, bindGroupDesc.obj)
        set_bind_group(computePass, 0, bindGroup, (), true)
        mipSize = Int32.(ceil.(Float32.(texSize[1:2] .>> l) ./ downsampleWorkgroupSize))
        dispatch(computePass, mipSize[1], mipSize[2], 1)
        wgpuTextureViewRelease(viewSrc)
        viewSrc = viewDst
    end
    wgpuTextureViewRelease(viewSrc)
end

function downsample_finalize()
    for (k, p) in downsamplePipelines
        finalize(p.shader)
        finalize(p)
    end
    empty!(downsamplePipelines)
end

