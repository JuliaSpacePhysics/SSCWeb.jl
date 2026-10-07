cache_dir() = get(ENV, "SSCWEB_DIR", joinpath(homedir(), ".sscweb"))

clear_cache!() = rm(cache_dir(); recursive = true, force = true)

# Recent ephemerides may be predictions that SSC later replaces with definitive ones.
const UNSTABLE = Day(30)

# SSC sends nothing until the whole request is computed, and Downloads aborts after 20 s
# without data, so long ranges are split.
const MAX_SPAN = 30

day_path(id, rf, day) = joinpath(cache_dir(), id, "rf$rf", "$day.bin")

# Raw little-endian arrays behind one text header line per entry; unreadable files are refetched.
const MAGIC = "SSCWEB1"

# Decodes `:time` and `keys`, skipping other stored vars.
function read_day(path, keys)
    isfile(path) || return Dict{Symbol, Any}()
    return something(tryread(path, keys), Dict{Symbol, Any}())
end

function tryread(path, keys)
    try
        return open(path) do io
            readline(io) == MAGIC || return nothing
            chunk = Dict{Symbol, Any}()
            while !eof(io)
                f = split(readline(io))
                k = Symbol(f[1])
                n = parse.(Int, f[3:end])
                if k !== :time && k ∉ keys
                    skip(io, f[2] == "sym" ? n[1] + n[2] : 8 * prod(n))
                    continue
                end
                chunk[k] = if f[2] == "time"
                    DateTime.(UTM.(read!(io, Vector{Int64}(undef, n[1]))))
                elseif f[2] == "f64"
                    read!(io, Array{Float64}(undef, n...))
                else
                    table = Symbol.(split(String(read(io, n[2])), '\n'))
                    table[read!(io, Vector{UInt8}(undef, n[1]))]
                end
            end
            chunk
        end
    catch
        return nothing
    end
end

entry(io, k, x::Vector{DateTime}) = (println(io, k, " time ", length(x)); write(io, value.(x)))
entry(io, k, x::Array{Float64}) = (println(io, k, " f64 ", join(size(x), ' ')); write(io, x))
# Symbols (region names, < 256 distinct) as a newline-joined table plus one UInt8 code per sample.
function entry(io, k, x::Vector{Symbol})
    table = unique(x)
    s = join(table, '\n')
    println(io, k, " sym ", length(x), ' ', sizeof(s))
    write(io, s)
    return write(io, UInt8[findfirst(==(v), table) for v in x])
end

function write_day(path, chunk)
    mkpath(dirname(path))
    tmp = tempname(dirname(path))
    open(tmp, "w") do io
        println(io, MAGIC)
        foreach(((k, x),) -> entry(io, k, x), chunk)
    end
    return mv(tmp, path; force = true)
end

rows(x::AbstractMatrix, r) = x[r, :]
rows(x::AbstractVector, r) = x[r]

# Whole UTC days are fetched (and stored if `store`), so samples sit on a grid anchored at
# UTC midnight regardless of `t0`, and ranges shorter than the server minimum still work.
function day_locations(id, t0, t1, vars, rf; store = true, retry = true)
    days = Date(t0):Day(1):Date(t1)
    chunks = [store ? read_day(day_path(id, rf, d), vars) : Dict{Symbol, Any}() for d in days]
    need = [filter(v -> !haskey(c, v), vars) for c in chunks]
    spans = UnitRange{Int}[]
    i = 1
    while i <= length(days)
        if isempty(need[i])
            i += 1
            continue
        end
        j = i
        while j < length(days) && j - i + 1 < MAX_SPAN && need[j + 1] == need[i]
            j += 1
        end
        push!(spans, i:j)
        i = j + 1
    end
    results = try
        asyncmap(spans; ntasks = 4) do sp
            fetch_locations(id, DateTime(days[first(sp)]), DateTime(days[last(sp)] + Day(1)), need[first(sp)], rf)
        end
    catch e
        throw(e isa CapturedException ? e.ex : e)
    end
    stable = Date(now(UTC)) - UNSTABLE
    for (sp, data) in zip(spans, results)
        dtime = data[:time]::Vector{DateTime}
        for k in sp
            day = DateTime(days[k])
            r = searchsortedfirst(dtime, day):(searchsortedfirst(dtime, day + Day(1)) - 1)
            chunk = chunks[k]
            # A changed grid means SSC updated the ephemeris; drop stale vars.
            regrid = get(chunk, :time, dtime[r]) != dtime[r]
            regrid && empty!(chunk)
            chunk[:time] = dtime[r]
            foreach(v -> chunk[v] = rows(data[v], r), need[k])
            if store && days[k] < stable
                path = day_path(id, rf, days[k])
                write_day(path, regrid ? chunk : merge(read_day(path, VARS), chunk))
            end
        end
    end
    if !all(c -> all(v -> haskey(c, v), vars), chunks)
        retry || error("SSCWeb cache: inconsistent data for $id")
        return day_locations(id, t0, t1, vars, rf; store, retry = false)
    end
    time = reduce(vcat, [c[:time]::Vector{DateTime} for c in chunks])
    r = searchsortedfirst(time, t0):searchsortedlast(time, t1)
    return pushfirst!(Any[rows(reduce(vcat, [c[v] for c in chunks]), r) for v in vars], time[r])
end
