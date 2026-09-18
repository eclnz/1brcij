# Kernel-observed counters, shared by the probes.
#
#   rchar       bytes delivered to read()/pread(). Page faults against an mmap
#               do NOT count, so this is "how much did the library eagerly
#               load" rather than "how much did it end up using".
#   read_bytes  bytes actually fetched from the block device, readahead
#               included. Counts both read() and major faults.
#   rss         resident set size: how much is actually in this process now.
#   majflt      major (disk-backed) page faults.

const PAGE = 4096

function iocounters()
    rchar = readb = 0
    for line in eachline("/proc/self/io")
        i = findfirst(==(':'), line)
        i === nothing && continue
        k, v = line[1:i-1], parse(Int, strip(line[i+1:end]))
        k == "rchar" && (rchar = v)
        k == "read_bytes" && (readb = v)
    end
    return (rchar = rchar, read_bytes = readb)
end

rss() = parse(Int, split(read("/proc/self/statm", String))[2]) * PAGE

function majflt()
    s = read("/proc/self/stat", String)
    return parse(Int, split(s[findlast(==(')'), s)+2:end])[10])
end

nopenfds() = length(readdir("/proc/self/fd"))

function drop_caches()
    run(`sync`)
    write("/proc/sys/vm/drop_caches", "3")
    return nothing
end
