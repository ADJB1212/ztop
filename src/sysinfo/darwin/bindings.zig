const sys_c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/statvfs.h");
    @cInclude("net/if.h");
    @cInclude("net/route.h");
});

pub const c = struct {
    const __CFString = opaque {};
    const __CFDictionary = opaque {};
    const __CFData = opaque {};
    const __CFNumber = opaque {};
    const __CFArray = opaque {};
    const __CFBoolean = opaque {};
    const __CFAllocator = opaque {};

    pub const struct_proc_fdinfo = sys_c.struct_proc_fdinfo;
    pub const struct_socket_fdinfo = sys_c.struct_socket_fdinfo;
    pub const struct_in_sockinfo = sys_c.struct_in_sockinfo;
    pub const struct_if_msghdr2 = sys_c.struct_if_msghdr2;
    pub const struct_statvfs = sys_c.struct_statvfs;

    pub const PROC_PIDLISTFDS = sys_c.PROC_PIDLISTFDS;
    pub const PROC_PIDFDSOCKETINFO = sys_c.PROC_PIDFDSOCKETINFO;
    pub const PROX_FDTYPE_SOCKET = sys_c.PROX_FDTYPE_SOCKET;
    pub const SOCKINFO_IN = sys_c.SOCKINFO_IN;
    pub const SOCKINFO_TCP = sys_c.SOCKINFO_TCP;
    pub const SOCKINFO_UN = sys_c.SOCKINFO_UN;
    pub const INI_IPV4 = sys_c.INI_IPV4;
    pub const INI_IPV6 = sys_c.INI_IPV6;
    pub const TSI_S_CLOSED = sys_c.TSI_S_CLOSED;
    pub const TSI_S_LISTEN = sys_c.TSI_S_LISTEN;
    pub const TSI_S_SYN_SENT = sys_c.TSI_S_SYN_SENT;
    pub const TSI_S_SYN_RECEIVED = sys_c.TSI_S_SYN_RECEIVED;
    pub const TSI_S_ESTABLISHED = sys_c.TSI_S_ESTABLISHED;
    pub const TSI_S__CLOSE_WAIT = sys_c.TSI_S__CLOSE_WAIT;
    pub const TSI_S_FIN_WAIT_1 = sys_c.TSI_S_FIN_WAIT_1;
    pub const TSI_S_CLOSING = sys_c.TSI_S_CLOSING;
    pub const TSI_S_LAST_ACK = sys_c.TSI_S_LAST_ACK;
    pub const TSI_S_FIN_WAIT_2 = sys_c.TSI_S_FIN_WAIT_2;
    pub const TSI_S_TIME_WAIT = sys_c.TSI_S_TIME_WAIT;
    pub const CTL_NET = sys_c.CTL_NET;
    pub const PF_ROUTE = sys_c.PF_ROUTE;
    pub const NET_RT_IFLIST2 = sys_c.NET_RT_IFLIST2;
    pub const RTM_IFINFO2 = sys_c.RTM_IFINFO2;
    pub const IFF_LOOPBACK = sys_c.IFF_LOOPBACK;
    pub const CTL_KERN = sys_c.CTL_KERN;
    pub const KERN_PROCARGS2 = sys_c.KERN_PROCARGS2;
    pub const sysctl = sys_c.sysctl;
    pub const statvfs = sys_c.statvfs;

    pub const Boolean = u8;
    pub const CFTypeID = c_ulong;
    pub const CFIndex = c_long;
    pub const CFStringEncoding = u32;
    pub const CFNumberType = CFIndex;
    pub const IOOptionBits = u32;

    pub const CFTypeRef = *const anyopaque;
    pub const CFStringRef = *const __CFString;
    pub const CFDictionaryRef = *const __CFDictionary;
    pub const CFMutableDictionaryRef = *__CFDictionary;
    pub const CFDataRef = *const __CFData;
    pub const CFNumberRef = *const __CFNumber;
    pub const CFArrayRef = *const __CFArray;
    pub const CFBooleanRef = *const __CFBoolean;
    pub const CFAllocatorRef = *const __CFAllocator;

    pub const io_object_t = mach_port_t;
    pub const io_iterator_t = io_object_t;
    pub const io_registry_entry_t = io_object_t;
    pub const io_service_t = io_object_t;

    pub const KERN_SUCCESS: kern_return_t = 0;
    pub const kIOMainPortDefault: mach_port_t = 0;
    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
    pub const kCFNumberSInt64Type: CFNumberType = 4;
    pub const kCFNumberSInt32Type: CFNumberType = 3;
    pub const kIOBlockStorageDriverClass = "IOBlockStorageDriver";
    pub const kIOBlockStorageDriverStatisticsKey = "Statistics";
    pub const kIOBlockStorageDriverStatisticsBytesReadKey = "Bytes (Read)";
    pub const kIOBlockStorageDriverStatisticsBytesWrittenKey = "Bytes (Write)";

    pub extern fn IOServiceMatching(name: [*:0]const u8) ?CFMutableDictionaryRef;
    pub extern fn IOServiceGetMatchingServices(mainPort: mach_port_t, matching: CFDictionaryRef, existing: *io_iterator_t) kern_return_t;
    pub extern fn IOIteratorNext(iterator: io_iterator_t) io_object_t;
    pub extern fn IOObjectRelease(object: io_object_t) kern_return_t;
    pub extern fn IORegistryEntryCreateCFProperty(entry: io_registry_entry_t, key: CFStringRef, allocator: ?CFAllocatorRef, options: IOOptionBits) ?CFTypeRef;

    pub extern fn CFStringCreateWithCString(alloc: ?CFAllocatorRef, cStr: [*:0]const u8, encoding: CFStringEncoding) ?CFStringRef;
    pub extern fn CFRelease(cf: CFTypeRef) void;
    pub extern fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
    pub extern fn CFDictionaryGetTypeID() CFTypeID;
    pub extern fn CFStringGetTypeID() CFTypeID;
    pub extern fn CFDataGetTypeID() CFTypeID;
    pub extern fn CFNumberGetTypeID() CFTypeID;
    pub extern fn CFBooleanGetTypeID() CFTypeID;
    pub extern fn CFArrayGetTypeID() CFTypeID;
    pub extern fn CFStringGetCString(theString: CFStringRef, buffer: [*]u8, bufferSize: CFIndex, encoding: CFStringEncoding) Boolean;
    pub extern fn CFDataGetBytePtr(theData: CFDataRef) ?[*]const u8;
    pub extern fn CFDataGetLength(theData: CFDataRef) CFIndex;
    pub extern fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: CFStringRef) ?*const anyopaque;
    pub extern fn CFNumberGetValue(number: CFNumberRef, theType: CFNumberType, valuePtr: *anyopaque) Boolean;
    pub extern fn CFBooleanGetValue(boolean: CFBooleanRef) Boolean;
    pub extern fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;
    pub extern fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) ?*const anyopaque;

    pub extern fn IOPSCopyPowerSourcesInfo() ?CFTypeRef;
    pub extern fn IOPSCopyPowerSourcesList(blob: CFTypeRef) ?CFArrayRef;
    pub extern fn IOPSGetPowerSourceDescription(blob: CFTypeRef, ps: *const anyopaque) ?CFTypeRef;
    pub const kIOPSCurrentCapacityKey = "Current Capacity";
    pub const kIOPSMaxCapacityKey = "Max Capacity";
    pub const kIOPSPowerSourceStateKey = "Power Source State";
    pub const kIOPSIsChargingKey = "Is Charging";

    pub const IOHIDEventSystemClientRef = *anyopaque;
    pub const IOHIDServiceClientRef = *anyopaque;
    pub extern fn IOHIDEventSystemClientCreate(allocator: ?CFAllocatorRef) ?IOHIDEventSystemClientRef;
    pub extern fn IOHIDEventSystemClientCopyServices(client: IOHIDEventSystemClientRef) ?CFArrayRef;
    pub extern fn IOHIDServiceClientCopyProperty(service: IOHIDServiceClientRef, property: CFStringRef) ?CFTypeRef;
    pub extern fn IOHIDServiceClientConformsTo(service: IOHIDServiceClientRef, usagePage: u32, usage: u32) i32;
    pub extern fn IOHIDServiceClientCopyEvent(service: IOHIDServiceClientRef, event_type: i64, options: i32, reserved: i64) ?*anyopaque;
    pub extern fn IOHIDEventGetFloatValue(event: *anyopaque, field: u32) f64;
};

pub const mach_port_t = u32;
pub const kern_return_t = c_int;

pub extern "c" fn mach_host_self() mach_port_t;
pub extern "c" fn host_statistics(host: mach_port_t, flavor: c_int, info: [*]c_int, count: *u32) kern_return_t;
pub extern "c" fn host_page_size(host: mach_port_t, page_size: *usize) kern_return_t;
pub extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
pub extern "c" fn proc_listallpids(buffer: ?[*]c_int, bufsize: c_int) c_int;
pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, bufsize: c_int) c_int;
pub extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, bufsize: c_int) c_int;
pub extern "c" fn proc_name(pid: c_int, buffer: [*]u8, bufsize: u32) c_int;
pub extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, bufsize: u32) c_int;
pub extern "c" fn mach_absolute_time() u64;
pub extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) kern_return_t;
pub extern "c" fn host_processor_info(host: mach_port_t, flavor: c_int, out_count: *u32, out_info: *[*]c_int, out_info_cnt: *u32) kern_return_t;
pub extern "c" fn vm_deallocate(task: mach_port_t, address: usize, size: usize) kern_return_t;
pub extern "c" fn mach_task_self() mach_port_t;

pub const MachTimebaseInfo = extern struct {
    numer: u32,
    denom: u32,
};

pub const WifiSnapshotRaw = extern struct {
    ssid_len: usize,
    phy_mode: i64,
    channel_band: i64,
};

pub extern "c" fn ztop_read_wifi_snapshot(ssid_buf: [*]u8, ssid_buf_len: usize) WifiSnapshotRaw;

pub const HOST_CPU_LOAD_INFO: c_int = 3;
pub const HOST_VM_INFO: c_int = 2;
pub const PROCESSOR_CPU_LOAD_INFO: c_int = 2;
pub const KERN_SUCCESS: c_int = 0;
pub const PROC_PIDTASKINFO: c_int = 4;
pub const CPU_STATE_USER = 0;
pub const CPU_STATE_SYSTEM = 1;
pub const CPU_STATE_IDLE = 2;
pub const CPU_STATE_NICE = 3;
pub const CPU_STATE_MAX = 4;

pub const PROC_PIDTHREADINFO: c_int = 5;
pub const PROC_PIDRUSAGE = 5;
pub const PROC_PIDLISTTHREADS: c_int = 6;
pub const PROC_PIDT_SHORTBSDINFO: c_int = 13;

pub const SIDL = 1;
pub const SRUN = 2;
pub const SSLEEP = 3;
pub const SSTOP = 4;
pub const SZOMB = 5;

pub const ProcBsdShortInfo = extern struct {
    pbsi_pid: u32,
    pbsi_ppid: u32,
    pbsi_pgid: u32,
    pbsi_status: u32,
    pbsi_comm: [16]u8,
    pbsi_flags: u32,
    pbsi_uid: u32,
    pbsi_gid: u32,
    pbsi_ruid: u32,
    pbsi_rgid: u32,
    pbsi_svuid: u32,
    pbsi_svgid: u32,
    pbsi_rfu: u32,
};

pub const rusage_info_v2 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
};

pub const HostCpuLoadInfo = extern struct {
    ticks: [4]u32,
};

pub const VmStatistics = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u32,
    reactivations: u32,
    pageins: u32,
    pageouts: u32,
    faults: u32,
    cow_faults: u32,
    lookups: u32,
    hits: u32,
    purgeable_count: u32,
    speculative_count: u32,
};

pub const xsw_usage = extern struct {
    xsu_total: u64,
    xsu_avail: u64,
    xsu_used: u64,
    xsu_pagesize: u32,
    xsu_encrypted: bool,
};

pub const ProcTaskInfo = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

pub const ProcThreadInfo = extern struct {
    pth_user_time: u64,
    pth_system_time: u64,
    pth_cpu_usage: i32,
    pth_policy: i32,
    pth_run_state: i32,
    pth_flags: i32,
    pth_sleep_time: i32,
    pth_curpri: i32,
    pth_priority: i32,
    pth_maxpri: i32,
    pth_name: [64]u8,
};

pub const TH_STATE_RUNNING: i32 = 1;
pub const TH_STATE_STOPPED: i32 = 2;
pub const TH_STATE_WAITING: i32 = 3;
pub const TH_STATE_UNINTERRUPTIBLE: i32 = 4;
pub const TH_STATE_HALTED: i32 = 5;
