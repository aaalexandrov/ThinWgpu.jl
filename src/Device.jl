function LogCallback(logLevel::WGPULogLevel, msg::Ptr{Cchar})
    @info logLevel unsafe_string(msg)
end

function GetWGPUAdapterCallback(status::WGPURequestAdapterStatus, adapter::WGPUAdapter, msg::Ptr{Cchar}, userData::Ptr{Cvoid})
    @assert(status == WGPURequestAdapterStatus_Success)
    adapterOut = Base.unsafe_pointer_to_objref(Ptr{WGPUAdapter}(userData))
    adapterOut[] = adapter
    nothing
end

function GetWGPUAdapter(wgpuInst::WGPUInstance, surface::WGPUSurface)::WGPUAdapter
    adapterOptions = Ref(WGPURequestAdapterOptions(
        C_NULL,
        surface,
        WGPUPowerPreference_HighPerformance,
        WGPUBackendType_Undefined,
        false # forceFallbackAdapter
    ))

    adapter = Ref{WGPUAdapter}()
    callback = @cfunction(GetWGPUAdapterCallback, Cvoid, (WGPURequestAdapterStatus, WGPUAdapter, Ptr{Cchar}, Ptr{Cvoid}))
    wgpuInstanceRequestAdapter(wgpuInst, adapterOptions, callback, adapter)
    adapter[]
end

function GetWGPUAdapterProperties(adapter::WGPUAdapter)::Ref{WGPUAdapterProperties}
    adapterProps = Ref{WGPUAdapterProperties}()
    zero_ref!(adapterProps)
    ret = wgpuAdapterGetProperties(adapter, adapterProps)
    @assert(ret != 0)
    adapterProps
end

function GetWGPUAdapterLimits(adapter::WGPUAdapter)::Ref{WGPULimits}
    adapterLimits = Ref{WGPUSupportedLimits}()
    zero_ref!(adapterLimits)
    ret = wgpuAdapterGetLimits(adapter, adapterLimits)
    @assert(ret != 0)
    Ref(adapterLimits[].limits)
end

function GetWGPUAdapterFeatures(adapter::WGPUAdapter)::Vector{WGPUFeatureName}
    adapterFeatures = Vector{WGPUFeatureName}()
    resize!(adapterFeatures, wgpuAdapterEnumerateFeatures(adapter, C_NULL))
    size = GC.@preserve adapterFeatures wgpuAdapterEnumerateFeatures(adapter, pointer(adapterFeatures, 1))
    @assert(size == length(adapterFeatures))
    adapterFeatures
end

function GetWGPUDeviceCallback(status::WGPURequestDeviceStatus, device::WGPUDevice, msg::Ptr{Cchar} , userData::Ptr{Cvoid})
    @assert(status == WGPURequestDeviceStatus_Success)
    deviceOut = Base.unsafe_pointer_to_objref(Ptr{WGPUDevice}(userData))
    deviceOut[] = device
    nothing
end

function GetWGPUDevice(adapter::WGPUAdapter, label::String)::WGPUDevice
    deviceDesc = Ref(WGPUDeviceDescriptor(
        C_NULL,
        pointer(label),
        0,
        C_NULL,
        C_NULL,
        WGPUQueueDescriptor(
            C_NULL,
            pointer(label)
        ),
        C_NULL,
        C_NULL
    ))

    device = Ref{WGPUDevice}()
    callback = @cfunction(GetWGPUDeviceCallback, Cvoid, (WGPURequestDeviceStatus, WGPUDevice, Ptr{Cchar}, Ptr{Cvoid}))
    GC.@preserve label wgpuAdapterRequestDevice(adapter, deviceDesc, callback, device)
    device[]
end
