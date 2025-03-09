module ThinWgpu

using GLFW
using WGPUNative
using CEnum
using LinearAlgebra

include("Util.jl") 
include("Surface.jl")
include("Device.jl")
include("Shader.jl")
include("Resources.jl")

function rotation_z(angle::Float32)::Matrix{Float32}
    c = cos(angle)
    s = sin(angle)
    Float32[ c s 0 0
            -s c 0 0
             0 0 1 0
             0 0 0 1 ]
end

const shaderName = "#tri.wgsl"
const shaderSrc = 
    """
    struct Uniforms {
        worldViewProj: mat4x4f,
    };

    @group(0) @binding(0) var<uniform> uni: Uniforms;
    @group(0) @binding(1) var texSampler: sampler;
    @group(0) @binding(2) var tex0: texture_2d<f32>;
   
    struct VSOut {
        @builtin(position) pos: vec4f,
        @location(0) color: vec4f,
        @location(1) uv: vec2f,
    };

    @vertex
    fn vs_main(@location(0) pos: vec3f, @location(1) color: vec3f, @location(2) uv: vec2f) -> VSOut {
        var vsOut: VSOut;
        vsOut.pos = uni.worldViewProj * vec4f(pos, 1.0);
        vsOut.color = vec4f(color, 1.0);
        vsOut.uv = uv;
        return vsOut;
    }

    @fragment
    fn fs_main(vsOut: VSOut) -> @location(0) vec4f {
        var tex: vec4f = textureSample(tex0, texSampler, vsOut.uv);
        return vsOut.color * tex;
    }
    """

struct Uniforms
    worldViewProj::NTuple{16, Float32}
end

struct VertexPos
    pos::NTuple{3, Float32}
    color::NTuple{3, Float32}
    uv::NTuple{2, Float32}
end

const triVertices = [
    VertexPos((-0.5, -0.5, 0), (1, 0, 0), (0, 0)),
    VertexPos(( 0.5, -0.5, 0), (0, 1, 0), (0, 1)),
    VertexPos(( 0.0,  0.5, 0), (0, 0, 1), (1, 1)),
]



function LogCallback(logLevel::WGPULogLevel, msg::Ptr{Cchar})
    @info logLevel unsafe_string(msg)
end

function main()
    GLFW.WindowHint(GLFW.CLIENT_API, GLFW.NO_API)
    window = GLFW.CreateWindow(800, 800, "Win32 Kek")

    # the @cfunction value needs to stay local because otherwise the Julia debugger breaks
    CLogCallback = @cfunction(LogCallback, Cvoid, (WGPULogLevel, Ptr{Cchar}))
    wgpuSetLogCallback(CLogCallback, C_NULL)
    wgpuSetLogLevel(WGPULogLevel_Warn)

    inst = wgpuCreateInstance(Ref(WGPUInstanceDescriptor(C_NULL)))

    surface = CreateOSSurface(inst, window, "Keke")
    adapter = GetWGPUAdapter(inst, surface)

    adapterProps = GetWGPUAdapterProperties(adapter)
    @info unsafe_string(adapterProps[].name)

    device = GetWGPUDevice(adapter, "wgpu.jl")
    queue = wgpuDeviceGetQueue(device)

    surfFormat = wgpuSurfaceGetPreferredFormat(surface, adapter)
    @info "Surface format $surfFormat"

    bindGroupLayout = CreateBindGroupLayout(device, shaderName, WGPUShaderStageFlags(WGPUShaderStage_Vertex | WGPUShaderStage_Fragment), Any[
        WGPUBufferBindingLayout(C_NULL, WGPUBufferBindingType_Uniform, false, 0),
        WGPUSamplerBindingLayout(C_NULL, WGPUSamplerBindingType_Filtering),
        WGPUTextureBindingLayout(C_NULL, WGPUTextureSampleType_Float, WGPUTextureViewDimension_2D, false),
    ])

    pipeline = CreateWGSLRenderPipeline(device, shaderName, shaderSrc, eltype(triVertices), [bindGroupLayout], surfFormat)

    uniforms = Ref{Uniforms}()
    set_ptr_field!(uniforms, :worldViewProj, tuple(reshape(Matrix{Float32}(I, 4, 4), 16)...))
    
    uniformBuffer = CreateBuffer(device, queue, "uniforms", WGPUBufferUsageFlags(WGPUBufferUsage_Uniform), uniforms)
    vertexBuffer = CreateBuffer(device, queue, "triVerts", WGPUBufferUsageFlags(WGPUBufferUsage_Vertex), triVertices)

    samplerLinearRepeat = CreateSampler(device, "linearRepeat", WGPUAddressMode_Repeat, WGPUFilterMode_Linear)
    texture = CreateTexture(device, queue, "tex2D", WGPUTextureUsage_TextureBinding, [ntuple(i->UInt8((isodd(x+y) || i > 3) * 255), 4) for x=1:4, y=1:4])
    textureView = wgpuTextureCreateView(texture, C_NULL)

    bindGroup = CreateBindGroup(device, "bindGroup", bindGroupLayout, Any[uniformBuffer, samplerLinearRepeat, textureView])

    startTime = time()
    frames = 0
    (winWidth, winHeight) = (-1, -1)    
    while !GLFW.WindowShouldClose(window)
        (newWidth, newHeight) = GLFW.GetWindowSize(window)
        if newWidth != winWidth || newHeight != winHeight
            (winWidth, winHeight) = (newWidth, newHeight)
            ConfigureWGPUSurface(surface, device, (UInt32(winWidth), UInt32(winHeight)), surfFormat)
        end

        texView = CreateSurfaceCurrentTextureView(surface)
        if texView != C_NULL
            # updates
            rot = rotation_z(Float32((time() - startTime) % 2pi))
            Base.memmove(ptr_to_field(uniforms, :worldViewProj), pointer(rot), sizeof(rot))
            wgpuQueueWriteBuffer(queue, uniformBuffer, 0, uniforms, sizeof(uniforms))

            label = "cmds"
            encoderDesc = Ref(WGPUCommandEncoderDescriptor(C_NULL, pointer(label)))
            encoder = GC.@preserve label wgpuDeviceCreateCommandEncoder(device, encoderDesc)

            colorAttachments = [WGPURenderPassColorAttachment(
                C_NULL,
                texView,
                C_NULL,
                WGPULoadOp_Clear,
                WGPUStoreOp_Store,
                WGPUColor(0.3, 0.3, 0.3, 1)
            )] 
            renderPassDesc = Ref(WGPURenderPassDescriptor(
                C_NULL,
                pointer(label),
                length(colorAttachments),
                pointer(colorAttachments, 1),
                C_NULL,
                C_NULL,
                C_NULL
            ))
            renderPass = GC.@preserve colorAttachments wgpuCommandEncoderBeginRenderPass(encoder, renderPassDesc)

            #rendering goes here
            wgpuRenderPassEncoderSetPipeline(renderPass, pipeline)
            wgpuRenderPassEncoderSetBindGroup(renderPass, 0, bindGroup, 0, C_NULL)
            wgpuRenderPassEncoderSetVertexBuffer(renderPass, 0, vertexBuffer, 0, wgpuBufferGetSize(vertexBuffer))
            wgpuRenderPassEncoderDraw(renderPass, 3, 1, 0, 0)

            wgpuRenderPassEncoderEnd(renderPass)
            wgpuRenderPassEncoderRelease(renderPass)

            cmdBufferDesc = Ref(WGPUCommandBufferDescriptor(C_NULL, pointer(label)))
            cmdBuffer = GC.@preserve label wgpuCommandEncoderFinish(encoder, cmdBufferDesc)
            wgpuCommandEncoderRelease(encoder)

            cmds = [cmdBuffer]
            wgpuQueueSubmit(queue, length(cmds), pointer(cmds, 1))
            wgpuCommandBufferRelease(cmdBuffer)

            wgpuTextureViewRelease(texView)
            wgpuSurfacePresent(surface)
            
            frames += 1
        end
        wgpuDevicePoll(device, false, C_NULL)
        GLFW.PollEvents()
    end
    runTime = time() - startTime
    @info "Frames: $frames, run time: $(round(runTime; digits = 3)), fps: $(round(frames / runTime; digits = 3))"

    wgpuBindGroupRelease(bindGroup)
    wgpuTextureViewRelease(textureView)
    wgpuTextureRelease(texture)
    wgpuSamplerRelease(samplerLinearRepeat)
    wgpuBufferRelease(uniformBuffer)
    wgpuBufferRelease(vertexBuffer)
    wgpuRenderPipelineRelease(pipeline)
    wgpuBindGroupLayoutRelease(bindGroupLayout)
    wgpuQueueRelease(queue)
    wgpuDeviceRelease(device)
    wgpuAdapterRelease(adapter)
    wgpuSurfaceRelease(surface)
    wgpuInstanceRelease(inst)

    wgpuSetLogCallback(C_NULL, C_NULL)

    GLFW.DestroyWindow(window)
end

try
    GLFW.Init()
    main()
finally
    # so that windows close in case of an runtime error
    GLFW.Terminate()
end

end