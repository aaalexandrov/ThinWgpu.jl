if Sys.iswindows()
    function GetWin32Window(window)
        ccall((:glfwGetWin32Window, GLFW.libglfw), Ptr{Nothing}, (Ptr{GLFW.Window},), window.handle)
    end

    function GetModuleHandle(ptr)
        ccall((:GetModuleHandleA, "kernel32"), stdcall, Ptr{UInt32}, (UInt32,), ptr)
    end

    function GetOSSurfaceDescriptor(window::GLFW.Window)
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

function ConfigureWGPUSurface(surface::WGPUSurface, device::WGPUDevice, size::NTuple{2, UInt32}, surfFormat::WGPUTextureFormat)
    viewFormats = [surfFormat]

    config = Ref(WGPUSurfaceConfiguration(
        C_NULL,
        device,
        surfFormat,
        WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc,
        length(viewFormats),
        pointer(viewFormats, 1),
        WGPUCompositeAlphaMode_Opaque,
        size[1],
        size[2],
        WGPUPresentMode_Fifo
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
