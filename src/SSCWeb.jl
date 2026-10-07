module SSCWeb

using Dates: Date, DateTime, Day, UTC, UTM, now, value
using Downloads: request
using JSON: JSON

export observatories, ground_stations, locations, clear_cache!

@doc read(joinpath(dirname(@__DIR__), "README.md"), String) SSCWeb

const BASE_URL = "https://sscweb.gsfc.nasa.gov/WS/sscr/2"

const COORDS = (geo = "Geo", gm = "Gm", gse = "Gse", gsm = "Gsm", sm = "Sm", geitod = "GeiTod", geij2000 = "GeiJ2000")

# Flags in schema order; the schema requires every flag of an emitted group.
const FLAGS = (
    RegionOptions = ("Spacecraft", "RadialTracedFootpoint", "NorthBTracedFootpoint", "SouthBTracedFootpoint"),
    ValueOptions = ("RadialDistance", "BFieldStrength", "DipoleLValue", "DipoleInvLat"),
    DistanceFromOptions = ("NeutralSheet", "BowShock", "MPause", "BGseXYZ"),
)

# var => (option group, flag, response field)
const SCALARS = (
    r = (:ValueOptions, "RadialDistance", "RadialLength"),
    bmag = (:ValueOptions, "BFieldStrength", "MagneticStrength"),
    L = (:ValueOptions, "DipoleLValue", "DipoleLValue"),
    invlat = (:ValueOptions, "DipoleInvLat", "DipoleInvariantLatitude"),
    d_ns = (:DistanceFromOptions, "NeutralSheet", "NeutralSheetDistance"),
    d_bs = (:DistanceFromOptions, "BowShock", "BowShockDistance"),
    d_mp = (:DistanceFromOptions, "MPause", "MagnetoPauseDistance"),
    region = (:RegionOptions, "Spacecraft", "SpacecraftRegion"),
    region_radial = (:RegionOptions, "RadialTracedFootpoint", "RadialTracedFootpointRegions"),
    region_north = (:RegionOptions, "NorthBTracedFootpoint", "NorthBTracedFootpointRegions"),
    region_south = (:RegionOptions, "SouthBTracedFootpoint", "SouthBTracedFootpointRegions"),
)

const TRACES = (foot_north = "North", foot_south = "South", len_north = "North", len_south = "South")

const VARS = (keys(COORDS)..., keys(SCALARS)..., :b_gse, keys(TRACES)...)

function observatories()
    T = @NamedTuple{id::String, name::String, resolution::Int, start::DateTime, stop::DateTime, resource_id::Union{String, Missing}}
    return T[
        (o["Id"], o["Name"], o["Resolution"], o["StartTime"], o["EndTime"], get(o, "ResourceId", missing))
            for o in get_json("/observatories")["Observatory"]
    ]
end

function ground_stations()
    return map(get_json("/groundStations")["GroundStation"]) do g
        loc = g["Location"]
        (id = g["Id"], name = g["Name"], lat = Float64(loc["Latitude"]), lon = Float64(loc["Longitude"]))
    end
end

"""
    locations(id, t0, t1, vars...=:gse; resolution_factor=1, cache=true) -> NamedTuple

See the package README for `vars` and caching.
"""
function locations(id, t0, t1, vars::Symbol...; resolution_factor = 1, cache = true)
    # A Vector, not the Tuple, keeps one compiled method for every combination of vars.
    vs = isempty(vars) ? [:gse] : collect(Symbol, vars)
    for v in vs
        v in VARS || throw(ArgumentError("unknown var :$v; valid: $(join(VARS, ", "))"))
    end
    cols = day_locations(string(id), DateTime(t0), DateTime(t1), vs, Int(resolution_factor); store = cache)
    return NamedTuple{(:time, vs...)}(Tuple(cols))
end

function fetch_locations(id, t0, t1, vars, resolution_factor)
    body = data_request(id, t0, t1, vars; resolution_factor)
    result = post_json("/locations", body)["Result"]
    check_status(result)
    # No "Data" when the range lies entirely outside the observatory's coverage.
    haskey(result, "Data") || return Dict{Symbol, Any}(:time => DateTime[], (v => empty_column(v) for v in vars)...)
    return satellite_data(only(result["Data"]), vars)
end

empty_column(v) =
    haskey(COORDS, v) || v === :b_gse ? Matrix{Float64}(undef, 0, 3) :
    startswith(String(v), "foot") ? Matrix{Float64}(undef, 0, 2) :
    startswith(String(v), "region") ? Symbol[] : Float64[]

include("cache.jl")

# No BFieldModel: the server default is IGRF + T89c (Kp = 3), traced to 100 km.
function data_request(id, t0, t1, vars; resolution_factor = 1)
    io = IOBuffer()
    print(io, """<DataRequest xmlns="http://sscweb.gsfc.nasa.gov/schema">""")
    print(io, "<TimeInterval><Start>", t0, "Z</Start><End>", t1, "Z</End></TimeInterval>")
    print(io, "<Satellites><Id>", id, "</Id><ResolutionFactor>", resolution_factor, "</ResolutionFactor></Satellites>")
    print(io, "<OutputOptions><AllLocationFilters>true</AllLocationFilters>")
    # CoordinateOptions is required, and X/Y/Z must be requested together or the server drops them.
    coords = filter(in(keys(COORDS)), vars)
    for cs in (isempty(coords) ? (:geo,) : coords), c in ("X", "Y", "Z")
        print(io, "<CoordinateOptions><CoordinateSystem>", COORDS[cs], "</CoordinateSystem><Component>", c, "</Component></CoordinateOptions>")
    end
    on = Set(SCALARS[v][2] for v in vars if haskey(SCALARS, v))
    :b_gse in vars && push!(on, "BGseXYZ")
    for (group, flags) in pairs(FLAGS)
        any(in(on), flags) || continue
        print(io, "<", group, ">")
        foreach(f -> print(io, "<", f, ">", f in on, "</", f, ">"), flags)
        print(io, "</", group, ">")
    end
    for hemi in unique(TRACES[v] for v in vars if haskey(TRACES, v))
        print(io, "<BFieldTraceOptions><CoordinateSystem>Geo</CoordinateSystem><Hemisphere>", hemi, "</Hemisphere>")
        print(io, "<FootpointLatitude>true</FootpointLatitude><FootpointLongitude>true</FootpointLongitude><FieldLineLength>true</FieldLineLength></BFieldTraceOptions>")
    end
    print(io, "</OutputOptions></DataRequest>")
    return String(take!(io))
end

function satellite_data(s, vars)
    return Dict{Symbol, Any}(:time => Vector{DateTime}(s["Time"]), (v => column(s, v) for v in vars)...)
end

xyz(d, k) = hcat(floats(d[k * "X"]), floats(d[k * "Y"]), floats(d[k * "Z"]))

function column(s, v)
    if haskey(COORDS, v)
        # "GEI_TOD" in the response for "GeiTod" in the request
        c = only(c for c in s["Coordinates"] if replace(c["CoordinateSystem"], "_" => "") == uppercase(COORDS[v]))
        return xyz(c, "")
    elseif haskey(SCALARS, v)
        x = s[SCALARS[v][3]]
        return startswith(String(v), "region") ? Symbol.(x) : floats(x)
    elseif v === :b_gse
        return xyz(s, "Bgse")
    else
        t = only(t for t in s["BtraceData"] if t["Hemisphere"] == uppercase(TRACES[v]))
        return startswith(String(v), "foot") ? hcat(floats(t["Latitude"]), floats(t["Longitude"])) : floats(t["ArcLength"])
    end
end

# Fill values: -1e31, or the string "NaN" (failed traces)
floats(x) = [v isa Real && v > -1.0e30 ? Float64(v) : NaN for v in x]

function check_status(result)
    status = result["StatusCode"]
    msg = join(get(result, "StatusText", ()), "; ")
    status == "ERROR" && error("SSCWeb $(result["StatusSubCode"]): $msg")
    status == "SUCCESS" || @warn "SSCWeb $status: $msg"
    return
end

# JSON over XML: smaller and ~5x faster to parse. SSC documents its JSON as less stable than XML.
const HEADERS = ["Accept" => "application/json"]

get_json(path) = untag(JSON.parse(fetch_body(BASE_URL * path; headers = HEADERS)))

function post_json(path, xml)
    headers = [HEADERS; "Content-Type" => "application/xml"]
    return untag(JSON.parse(fetch_body(BASE_URL * path; method = "POST", input = IOBuffer(xml), headers)))
end

function fetch_body(url; input = nothing, retries = 3, kw...)
    out = IOBuffer()
    resp = request(url; output = out, throw = false, input = isnothing(input) ? nothing : seekstart(input), kw...)
    # Transport errors include a reused connection the server already closed, which curl
    # cannot replay because the request body is not rewindable.
    if resp isa Exception
        retries > 0 || throw(resp)
        return fetch_body(url; input, retries = retries - 1, kw...)
    end
    body = String(take!(out))
    resp.status == 200 && return body
    wait = findfirst(h -> lowercase(first(h)) == "retry-after", resp.headers)
    if resp.status in (429, 503) && !isnothing(wait) && retries > 0
        sleep(parse(Int, last(resp.headers[wait])))
        return fetch_body(url; input, retries = retries - 1, kw...)
    end
    error("SSCWeb HTTP $(resp.status) for $url: $body")
end

# Jackson-typed JSON: every object/list is wrapped as ["java.class.Name", value].
const TYPE_TAG = r"^(java|javax|gov)\."

untag(x) = x
untag(x::AbstractDict) = Dict{String, Any}(String(k) => untag(v) for (k, v) in x)
function untag(x::AbstractVector)
    if length(x) == 2 && x[1] isa AbstractString && occursin(TYPE_TAG, x[1])
        # "2020-01-01T00:00:00.000+00:00"; SSCWeb always returns UTC
        x[1] == "javax.xml.datatype.XMLGregorianCalendar" && return DateTime(x[2][1:23])
        return untag(x[2])
    end
    return map(untag, x)
end

include("workload.jl")

end
