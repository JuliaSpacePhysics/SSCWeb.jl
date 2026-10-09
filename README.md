# SSCWeb.jl

Spacecraft ephemerides and geospace regions from NASA's [Satellite Situation Center](https://sscweb.gsfc.nasa.gov) web service.

```julia
using SSCWeb

observatories()     # Vector of (id, name, resolution [s], start, stop, resource_id); resource_id is "" when SSC has none
ground_stations()   # Vector of (id, name, lat, lon)

loc = locations("mms1", "2020-01-01", "2020-01-02")    # GSE position
loc.time            # Vector{DateTime}
loc.gse             # N×3 Matrix (x, y, z) in km

loc = locations("themisa", t0, t1, :gsm, :region, :foot_north)
locs = locations.(["mms1", "themisa"], t0, t1, :sm)      # one request per id; asyncmap to overlap
```

Times: anything `DateTime(x)` accepts (`DateTime`, `Date`, ISO string), interpreted as UTC.
Ids: `id` column of `observatories()`. A bad id throws; ranges outside coverage or between samples return empty columns.

## `locations(id, t0, t1, vars...; resolution_factor = 1, cache = true)`

Returns `(time, vars...)` as a `NamedTuple` (default var `:gse`). Fill values are `NaN`.
Cadence is the `resolution` column of `observatories()` (60 s at best); `resolution_factor = n` keeps every n-th sample, cutting server time.

Returns samples within `[t0, t1]` on a fixed per-observatory grid (UTC midnight plus an offset, e.g. hh:mm:30), independent of `t0`; grids of different observatories need not coincide.
With `cache = true` days are stored per (id, `resolution_factor`) in `~/.sscweb` (or `$SSCWEB_DIR`) and only missing days/vars are fetched; the last 30 days are never stored, since SSC may still revise them. `cache = false` neither reads nor writes the cache. `clear_cache!()` empties it.

| var | value |
|---|---|
| `:geo :gm :gse :gsm :sm :geitod :geij2000` | N×3 position, km (SSC's RE = 6378.16 km) |
| `:r` | radial distance, km |
| `:d_ns :d_bs :d_mp` | distance to neutral sheet / bow shock / magnetopause, km; negative = inside |
| `:region` | `Symbol`, one of `:INTERPLANETARY_MEDIUM`, `:{DAYSIDE,NIGHTSIDE}_{MAGNETOSHEATH,MAGNETOSPHERE,PLASMASPHERE}`, `:PLASMA_SHEET`, `:TAIL_LOBE`, `:{LOW,HIGH}_LATITUDE_BOUNDARY_LAYER` |
| `:region_radial :region_north :region_south` | `Symbol` region of the radial / north / south traced footpoint: `:NOT_APPLICABLE`, `:LOW_LATITUDE`, `:{NORTH,SOUTH}_{CUSP,CLEFT,AURORAL_OVAL,POLAR_CAP,MID_LATITUDE}` |
| `:bmag`, `:b_gse` | model \|B\| / N×3 B in GSE, nT |
| `:L`, `:invlat` | dipole L-shell, invariant latitude (deg) |
| `:foot_north :foot_south`, `:len_north :len_south` | N×2 GEO (lat, lon ∈ [0, 360)) footpoint at 100 km, deg; field-line length, km |

Field-model vars default to IGRF + T89c (Kp = 3) and match TsyganenkoModels.jl to ~1e-4 when positions are scaled by SSC's RE.
For time-varying drivers or T96/T01/TS04, use TsyganenkoModels.jl + GeoCotrans.jl on the positions instead.
