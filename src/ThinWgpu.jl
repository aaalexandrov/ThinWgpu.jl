module ThinWgpu

using GLFW
using WGPUNative
using CEnum
using LinearAlgebra

include("Util.jl") 
include("Device.jl")
include("Resources.jl")
include("Surface.jl")
include("Shader.jl")
include("Processing.jl")
include("Downsample.jl")
include("MathUtil.jl")

const shaderName = "#tri.wgsl"
const shaderSrc = 
    """
    struct Uniforms {
        worldViewProj: mat4x4f,
    };

    @group(0) @binding(0) var<uniform> uni: Uniforms;
    @group(0) @binding(1) var texSampler: sampler;
    @group(0) @binding(2) var tex0: texture_2d<f32>;
   
    struct VSIn {
        @location(0) pos: vec3f, 
        @location(1) color: vec3f, 
        @location(2) uv: vec2f,
    };

    struct VSOut {
        @builtin(position) pos: vec4f,
        @location(0) color: vec4f,
        @location(1) uv: vec2f,
    };

    @vertex
    fn vs_main(vsIn: VSIn) -> VSOut {
        var vsOut: VSOut;
        vsOut.pos = uni.worldViewProj * vec4f(vsIn.pos, 1.0);
        vsOut.color = vec4f(vsIn.color, 1.0);
        vsOut.uv = vsIn.uv;
        return vsOut;
    }

    @fragment
    fn fs_main(vsOut: VSOut) -> @location(0) vec4f {
        var tex: vec4f = textureSample(tex0, texSampler, vsOut.uv);
        return vsOut.color * tex;
    }
    """

struct Uniforms
    worldViewProj::SMatrix{4, 4, Float32, 16}
end

struct VertexPosColorUv
    pos::SVector{3, Float32}
    color::SVector{3, Float32}
    uv::SVector{2, Float32}
end

const triVertices = [
    VertexPosColorUv(SA_F32[-0.5, -0.5, 0], SA_F32[1, 0, 0], SA_F32[0, 0]),
    VertexPosColorUv(SA_F32[ 0.5, -0.5, 0], SA_F32[0, 1, 0], SA_F32[0, 1]),
    VertexPosColorUv(SA_F32[ 0.0,  0.5, 0], SA_F32[0, 0, 1], SA_F32[1, 1]),
]

include("FixedFont.jl")

function main()
    windowName = "Main"

    GLFW.WindowHint(GLFW.CLIENT_API, GLFW.NO_API)
    window = GLFW.CreateWindow(800, 800, windowName)

    device = Device()
    surface = Surface(device, window, windowName)
    init(device, surface)
    surface.presentMode = WGPUPresentMode_Immediate

    shaderStages = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment
    shader = Shader(device, shaderName, shaderSrc, shaderStages, (
        (;
            label=shaderName,
            entries=(
                (binding=0, visibility=shaderStages, buffer=(type=WGPUBufferBindingType_Uniform,)),
                (binding=1, visibility=shaderStages, sampler=(type=WGPUSamplerBindingType_Filtering,)),
                (binding=2, visibility=shaderStages, texture=(sampleType=WGPUTextureSampleType_Float, viewDimension=WGPUTextureViewDimension_2D,)),
            ),
        ),
    ),)

    pipeline = Pipeline(device, shader;
        vertex = (buffers = [VertexPosColorUv],),
        primitive = (topology = WGPUPrimitiveTopology_TriangleList,),
        multisample = (count = 1, mask = typemax(UInt32),),
        fragment = (targets = ((format = surface.format, writeMask = WGPUColorWriteMask_All,),),),
    )

    uniforms = Ref(Uniforms(zero(fieldtype(Uniforms, :worldViewProj))))
    
    uniformBuffer = Buffer(device, uniforms; label = "uniforms", usage = WGPUBufferUsage_Uniform)
    vertexBuffer = Buffer(device, triVertices; label = "vertices", usage = WGPUBufferUsage_Vertex)

    samplerLinearRepeat = Sampler(device; 
        label = "linearRepeat",
        addressModeU = WGPUAddressMode_Repeat,
        addressModeV = WGPUAddressMode_Repeat,
        addressModeW = WGPUAddressMode_Repeat,
        magFilter = WGPUFilterMode_Linear,
        minFilter = WGPUFilterMode_Linear,
        mipmapFilter = WGPUMipmapFilterMode_Linear,
        lodMaxClamp = typemax(Float32),
        maxAnisotropy = typemax(UInt16),
    )

    fontPipeline = Pipeline(device, shader;
        vertex = (buffers = [VertexPosColorUv],),
        primitive = (topology = WGPUPrimitiveTopology_TriangleList,),
        multisample = (count = 1, mask = typemax(UInt32),),
        fragment = (targets = ((
            format = surface.format, 
            blend = (color = (srcFactor = WGPUBlendFactor_SrcAlpha, dstFactor = WGPUBlendFactor_OneMinusSrcAlpha,), alpha = (srcFactor = WGPUBlendFactor_One,),),
            writeMask = WGPUColorWriteMask_All,
        ),),),
    )

    font = fixed_font_10x20(device)
    fontModel = FontModel(device, font, fontPipeline, samplerLinearRepeat, (Int32(1), Int32(1)))

    texture = Texture(device, [ntuple(i->UInt8((isodd(floor(x/64)+floor(y/64)) || i > 3) * 255), 4) for x=1:1024, y=1:1024];
        label = "tex2D",
        usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_StorageBinding | WGPUTextureUsage_CopyDst,
    )

    bindGroup = CreateBindGroup(device.device; 
        label = "bindGroup",
        layout = shader.bindGroupLayouts[1],
        entries = (
            (binding = 0, buffer = uniformBuffer.buffer, size = get_size(uniformBuffer),),
            (binding = 1, sampler = samplerLinearRepeat.sampler),
            (binding = 2, textureView = texture.view),
        ),
    )

    commands = Commands()
    renderPass = RenderPass()
    renderPassDesc = ComplexStruct(WGPURenderPassDescriptor; 
        label = renderPass.name,
        colorAttachments = ((
            view = C_NULL, 
            loadOp = WGPULoadOp_Clear, 
            storeOp = WGPUStoreOp_Store, 
            clearValue = WGPUColor(0.3, 0.3, 0.3, 1)
        ),),
    )

    open(device, commands)
    downsample_texture(device, commands, texture)
    close(commands)
    submit(device, (commands,))

    startTime = time()
    frames = 0
    frameTime = time_ns()
    while !GLFW.WindowShouldClose(window)
        acquireStatus = acquire_texture(surface)
        if acquireStatus == AcquireTextureFailed
            @info acquireStatus
            break
        elseif acquireStatus == AcquireTextureReconfigure
            winSize = GLFW.GetWindowSize(window)
            configure(surface, device, (winSize.width, winSize.height), surface.presentMode)
            set_resolution(fontModel, (winSize.width, winSize.height))
        else
            frameDuration = frameTime
            frameTime = time_ns()
            frameDuration = frameTime - frameDuration

            @assert(has_acquired_texture(surface))
            surfaceTex = get_acquired_texture(surface)

            # updates
            wtoh = Float32(surface.size[1])/surface.size[2]
            xform = ortho(-1f0*wtoh, 1f0*wtoh, 1f0, -1f0, 0f0, 1f0) * xform_compose(SA_F32[0, 0, 0.5], rot(Float32((time() - startTime) % 2pi), SA_F32[0, 0, -1]), 1.0f0)
            set_ptr_field!(xform, uniforms, :worldViewProj)
            write(device, uniformBuffer, uniforms)

            add_text(fontModel, "$(round(1e9 / frameDuration; digits = 2)) fps", SVector{2, Int32}(20, 20), SVector{3, Float32}(0, 0, 0.5), 1.5f0)
            update(device, fontModel)

            open(device, commands)

            set_ptr_field!(surfaceTex.view, renderPassDesc.obj, :colorAttachments, 1, :view)
            begin_pass(renderPass, commands, renderPassDesc)

            #rendering goes here
            set_pipeline(renderPass, pipeline)
            set_bind_group(renderPass, 0, bindGroup)
            set_vertex_buffer(renderPass, 0, vertexBuffer)
            draw(renderPass, 3)

            render(fontModel, renderPass)

            end_pass(renderPass)

            close(commands)

            submit(device, (commands,))
            present(surface)
        
            frames += 1
        end

        wgpuDevicePoll(device.device, false, C_NULL)
        GLFW.PollEvents()
    end
    runTime = time() - startTime
    @info "Frames: $frames, run time: $(round(runTime; digits = 3)), fps: $(round(frames / runTime; digits = 3))"

    wgpuBindGroupRelease(bindGroup)

    downsample_finalize()
    finalize(renderPass)
    finalize(commands)
    finalize(texture)
    finalize(fontModel)
    finalize(fontPipeline)
    finalize(font)
    finalize(samplerLinearRepeat)
    finalize(vertexBuffer)
    finalize(uniformBuffer)
    finalize(pipeline)
    finalize(shader)
    finalize(surface)
    finalize(device)

    GLFW.DestroyWindow(window)
    nothing
end

function run()
    try
        GLFW.Init()
        main()
    finally
        # so that windows close in case of an runtime error
        GLFW.Terminate()
    end
end

@time run()

end