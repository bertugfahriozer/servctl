[Unit]
Description=Resource limits for {{DOMAIN}}
Documentation=man:systemd.resource-control(5)

[Slice]
# ─── CPU Limitleri ───
# CPUQuota: 100% = 1 tam core
CPUQuota={{CPU_QUOTA}}
CPUWeight=100

# ─── Bellek Limitleri ───
MemoryMax={{MEMORY_MAX}}
MemoryHigh={{MEMORY_HIGH}}
MemorySwapMax=0

# ─── I/O Limitleri ───
IOWeight=100
IOReadBandwidthMax={{IO_READ_MAX}}
IOWriteBandwidthMax={{IO_WRITE_MAX}}

# ─── Process Limitleri ───
TasksMax={{TASKS_MAX}}
