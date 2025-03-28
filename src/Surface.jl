if Sys.iswindows()
    function GetWin32Window(window)
        ccall((:glfwGetWin32Window, GLFW.libglfw), Ptr{Nothing}, (Ptr{GLFW.Window},), window.handle)
    end

    function GetModuleHandle(ptr)
        ccall((:GetModuleHandleA, "kernel32"), stdcall, Ptr{UInt32}, (UInt32,), ptr)
    end
elseif Sys.islinux()
    function GetX11Display()
        ccall((:glfwGetX11Display, GLFW.libglfw), Ptr{Nothing}, ())
    end

    function GetX11Window(window::GLFW.Window)
        ccall((:glfwGetX11Window, GLFW.libglfw), UInt64, (Ptr{GLFW.Window},), window.handle)
    end
end

function GetOSSurfaceDescriptor(window::GLFW.Window)
    if Sys.iswindows()
        Ref(WGPUSurfaceDescriptorFromWindowsHWND(
            WGPUChainedStruct(C_NULL, WGPUSType_SurfaceDescriptorFromWindowsHWND),
            GetModuleHandle(C_NULL),
            GetWin32Window(window)
        ))
    elseif Sys.islinux()
        Ref(WGPUSurfaceDescriptorFromXlibWindow(
            WGPUChainedStruct(C_NULL, WGPUSType_SurfaceDescriptorFromXlibWindow),
            GetX11Display(),
            GetX11Window(window)
        ))
    else
        error("Unsupported OS")
    end
end

function CreateOSSurface(wgpuInst::WGPUInstance, window::GLFW.Window, label::String)::WGPUSurface
    osDesc = GetOSSurfaceDescriptor(window)
    surfDesc = Ref(WGPUSurfaceDescriptor(
        Ptr{WGPUChainedStruct}(Base.unsafe_convert(Ptr{Cvoid}, osDesc)),
        pointer(label)
    ))

    GC.@preserve osDesc label wgpuInstanceCreateSurface(wgpuInst, surfDesc)
end

function ConfigureWGPUSurface(surface::WGPUSurface, device::WGPUDevice, size::NTuple{2, Int32}, surfFormat::WGPUTextureFormat, presentMode::WGPUPresentMode)
    viewFormats = [surfFormat]

    config = Ref(WGPUSurfaceConfiguration(
        C_NULL,
        device,
        surfFormat,
        WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc,
        length(viewFormats),
        pointer(viewFormats, 1),
        WGPUCompositeAlphaMode_Opaque,
        UInt32(size[1]),
        UInt32(size[2]),
        presentMode
    ))

    GC.@preserve viewFormats wgpuSurfaceConfigure(surface, config)
end

function CreateSurfaceCurrentTextureView(surface::WGPUSurface)
    surfTex = Ref{WGPUSurfaceTexture}()
    zero_ref!(surfTex)
    wgpuSurfaceGetCurrentTexture(surface, surfTex)

    if surfTex[].status != WGPUSurfaceGetCurrentTextureStatus_Success 
        return C_NULL
    end

    @assert(surfTex[].texture != C_NULL)
    @assert(surfTex[].status == WGPUSurfaceGetCurrentTextureStatus_Success)

    wgpuTextureCreateView(surfTex[].texture, C_NULL)
end

@cenum SurfaceAcquireTextureResult::UInt32 begin 
    AcquireTextureSuccess 
    AcquireTextureReconfigure
    AcquireTextureFailed
end

mutable struct Surface
    surface::WGPUSurface
    name::String
    format::WGPUTextureFormat
    presentMode::WGPUPresentMode
    size::NTuple{2, Int32}
    currentTexture::Texture
    currentSurface::Ref{WGPUSurfaceTexture}
    Surface(wgpuSurf::WGPUSurface, name::String) = finalizer(surface_finalize, new(
        wgpuSurf, 
        name, 
        WGPUTextureFormat_Undefined, 
        WGPUPresentMode_Fifo, 
        (-1, -1),
        Texture(; name = name),
        Ref(WGPUSurfaceTexture(C_NULL, 0, WGPUSurfaceGetCurrentTextureStatus_Force32))
    ))
end

function Surface(device, window::GLFW.Window, name::String)
    Surface(CreateOSSurface(device.instance, window, name), name)
end

function surface_finalize(surface::Surface)
    if surface.surface != C_NULL
        wgpuSurfaceRelease(surface.surface)
        surface.surface = C_NULL
    end
end

is_configured(surface::Surface) = surface.size[1] >= 0
function configure(surface::Surface, device::Device, size::NTuple{2, Int32}, presentMode::WGPUPresentMode)
    surface.size = size
    surface.presentMode = presentMode
    ConfigureWGPUSurface(surface.surface, device.device, surface.size, surface.format, surface.presentMode)
end

function init(device::Device, surface::Surface)
    @assert(device.adapter == C_NULL)
    @assert(device.device == C_NULL)
    @assert(device.queue == C_NULL)

    device.adapter = GetWGPUAdapter(device.instance, surface.surface)

    adapterProps = GetWGPUAdapterProperties(device.adapter)
    @info unsafe_string(adapterProps[].name)

    device.device = GetWGPUDevice(device.adapter, surface.name)
    device.queue = wgpuDeviceGetQueue(device.device)

    surface.format = wgpuSurfaceGetPreferredFormat(surface.surface, device.adapter)
    @info "Surface format $(surface.format)"
end

function acquire_texture(surface::Surface)::SurfaceAcquireTextureResult
    curTex = surface.currentTexture
    @assert(curTex.texture == C_NULL && curTex.view == C_NULL)
    if !is_configured(surface)
        return AcquireTextureReconfigure
    end
    wgpuSurfaceGetCurrentTexture(surface.surface, surface.currentSurface)
    if surface.currentSurface[].status != WGPUSurfaceGetCurrentTextureStatus_Success
        if surface.currentSurface[].status in (WGPUSurfaceGetCurrentTextureStatus_Outdated, WGPUSurfaceGetCurrentTextureStatus_Lost)
            return AcquireTextureReconfigure
        else
            return AcquireTextureFailed
        end
    elseif surface.currentSurface[].suboptimal != 0
        return AcquireTextureReconfigure
    end

    curTex.texture = surface.currentSurface[].texture
    curTex.view = wgpuTextureCreateView(curTex.texture, C_NULL)

    AcquireTextureSuccess
end

has_acquired_texture(surface::Surface) = surface.currentTexture.texture != C_NULL
get_acquired_texture(surface::Surface) = surface.currentTexture

function present(surface::Surface)
    curTex = surface.currentTexture
    @assert(curTex.texture != C_NULL && curTex.view != C_NULL)
    wgpuTextureViewRelease(curTex.view)
    curTex.texture = C_NULL
    curTex.view = C_NULL
    wgpuSurfacePresent(surface.surface)
end