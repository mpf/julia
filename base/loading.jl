# This file is a part of Julia. License is MIT: http://julialang.org/license

# Base.require is the implementation for the `import` statement

function find_in_path(name::AbstractString)
    isabspath(name) && return name
    isfile(name) && return abspath(name)
    base = name
    if endswith(name,".jl")
        base = name[1:end-3]
    else
        name = string(base,".jl")
        isfile(name) && return abspath(name)
    end
    for prefix in [Pkg.dir(); LOAD_PATH]
        path = joinpath(prefix, name)
        isfile(path) && return abspath(path)
        path = joinpath(prefix, base, "src", name)
        isfile(path) && return abspath(path)
        path = joinpath(prefix, name, "src", name)
        isfile(path) && return abspath(path)
    end
    return nothing
end

find_in_node_path(name, node::Int=1) = myid() == node ?
    find_in_path(name) : remotecall_fetch(node, find_in_path, name)

function find_source_file(file)
    (isabspath(file) || isfile(file)) && return file
    file2 = find_in_path(file)
    file2 != nothing && return file2
    file2 = joinpath(JULIA_HOME, DATAROOTDIR, "julia", "base", file)
    isfile(file2) ? file2 : nothing
end

function find_in_cache_path(mod::Symbol)
    name = string(mod)
    for prefix in LOAD_CACHE_PATH
        path = joinpath(prefix, name*".ji")
        if isfile(path)
            produce(path)
        end
    end
    nothing
end

function _include_from_serialized(content::Vector{UInt8})
    m = ccall(:jl_restore_incremental_from_buf, UInt, (Ptr{Uint8},Int), content, sizeof(content))
    return m != 0
end

function _require_from_serialized(node::Int, path_to_try::ByteString, toplevel_load::Bool)
    if toplevel_load && myid() == 1 && nprocs() > 1
        # broadcast top-level import/using from node 1 (only)
        if node == myid()
            content = open(readbytes, path_to_try)
        else
            content = remotecall_fetch(node, open, readbytes, path_to_try)
        end
        if _include_from_serialized(content)
            others = filter(x -> x != myid(), procs())
            refs = Any[ @spawnat p _include_from_serialized(content) for p in others]
            for (id, ref) in zip(others, refs)
                if !fetch(ref)
                    warn("node state is inconsistent: node $id failed to load cache from $path_to_try")
                end
            end
            return true
        end
    elseif node == myid()
        if ccall(:jl_restore_incremental, UInt, (Ptr{Uint8},), path_to_try) != 0
            return true
        end
    else
        content = remotecall_fetch(node, open, readbytes, path_to_try)
        if _include_from_serialized(content)
            return true
        end
    end
    # otherwise, continue search
    return false
end

function _require_from_serialized(node::Int, mod::Symbol, toplevel_load::Bool)
    name = string(mod)
    finder = @spawnat node @task find_in_cache_path(mod) # TODO: switch this to an explicit Channel
    while true
        path_to_try = remotecall_fetch(node, consume_fetch, finder)
        path_to_try === nothing && return false
        if _require_from_serialized(node, path_to_try, toplevel_load)
            return true
        else
            warn("deserialization checks failed while attempting to load cache from $path_to_try")
        end
    end
end

consume_fetch(finder) = consume(fetch(finder))

# to synchronize multiple tasks trying to import/using something
const package_locks = Dict{Symbol,Condition}()
const package_loaded = Set{Symbol}()

# require always works in Main scope and loads files from node 1
toplevel_load = true
function require(mod::Symbol)
    global toplevel_load
    loading = get(package_locks, mod, false)
    if loading !== false
        # load already in progress for this module
        wait(loading)
        return
    end
    package_locks[mod] = Condition()

    last = toplevel_load::Bool
    try
        toplevel_load = false
        if _require_from_serialized(1, mod, last)
            return true
        end
        if JLOptions().incremental != 0
            # spawn off a new incremental compile task from node 1 for recursive `require` calls
            cachefile = compile(mod)
            if !_require_from_serialized(1, cachefile, last)
                warn("require failed to create a precompiled cache file")
            end
            return
        end

        name = string(mod)
        path = find_in_node_path(name, 1)
        path === nothing && throw(ArgumentError("$name not found in path"))
        if last && myid() == 1 && nprocs() > 1
            # broadcast top-level import/using from node 1 (only)
            content = open(readall, path)
            refs = Any[ @spawnat p eval(Main, :(Base.include_from_node1($path))) for p in procs() ]
            for r in refs; wait(r); end
        else
            eval(Main, :(Base.include_from_node1($path)))
        end
    finally
        toplevel_load = last
        loading = pop!(package_locks, mod)
        notify(loading, all=true)
    end
    nothing
end

# remote/parallel load

include_string(txt::ByteString, fname::ByteString) =
    ccall(:jl_load_file_string, Any, (Ptr{UInt8},Csize_t,Ptr{UInt8},Csize_t),
          txt, sizeof(txt), fname, sizeof(fname))

include_string(txt::AbstractString, fname::AbstractString) = include_string(bytestring(txt), bytestring(fname))

include_string(txt::AbstractString) = include_string(txt, "string")

function source_path(default::Union{AbstractString,Void}="")
    t = current_task()
    while true
        s = t.storage
        if !is(s, nothing) && haskey(s, :SOURCE_PATH)
            return s[:SOURCE_PATH]
        end
        if is(t, t.parent)
            return default
        end
        t = t.parent
    end
end

macro __FILE__() source_path() end

function include_from_node1(path::AbstractString)
    prev = source_path(nothing)
    path = (prev == nothing) ? abspath(path) : joinpath(dirname(prev),path)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path
    local result
    try
        if myid()==1
            # sleep a bit to process file requests from other nodes
            nprocs()>1 && sleep(0.005)
            result = Core.include(path)
            nprocs()>1 && sleep(0.005)
        else
            result = include_string(remotecall_fetch(1, readall, path), path)
        end
    finally
        if prev == nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
    result
end

function evalfile(path::AbstractString, args::Vector{UTF8String}=UTF8String[])
    return eval(Module(:__anon__),
                Expr(:toplevel,
                     :(const ARGS = $args),
                     :(eval(x) = Main.Core.eval(__anon__,x)),
                     :(eval(m,x) = Main.Core.eval(m,x)),
                     :(Main.Base.include($path))))
end
evalfile(path::AbstractString, args::Vector) = evalfile(path, UTF8String[args...])

function create_expr_cache(input::AbstractString, output::AbstractString)
    code_object = """
        while !eof(STDIN)
            eval(Main, deserialize(STDIN))
        end
        """
    io, pobj = open(detach(setenv(`$(julia_cmd())
            --output-ji $output --output-incremental=yes
            --startup-file=no --history-file=no
            --eval $code_object`,
        ["JULIA_HOME=$JULIA_HOME", "HOME=$(homedir())"])), "w", STDOUT)
    serialize(io, quote
        empty!(Base.LOAD_PATH)
        append!(Base.LOAD_PATH, $LOAD_PATH)
        empty!(Base.LOAD_CACHE_PATH)
        append!(Base.LOAD_CACHE_PATH, $LOAD_CACHE_PATH)
        empty!(Base.DL_LOAD_PATH)
        append!(Base.DL_LOAD_PATH, $DL_LOAD_PATH)
    end)
    source = source_path(nothing)
    if source !== nothing
        serialize(io, quote
            task_local_storage()[:SOURCE_PATH] = $(source)
        end)
    end
    serialize(io, :(Base.include($(abspath(input)))))
    if source !== nothing
        serialize(io, quote
            delete!(task_local_storage(), :SOURCE_PATH)
        end)
    end
    close(io)
    wait(pobj)
    return pobj
end

function compile(mod::Symbol)
    myid() == 1 || error("can only compile from node 1")
    name = string(mod)
    path = find_in_path(name)
    path === nothing && throw(ArgumentError("$name not found in path"))
    cachepath = LOAD_CACHE_PATH[1]
    if !isdir(cachepath)
        mkpath(cachepath)
    end
    cachefile = abspath(cachepath, name*".ji")
    create_expr_cache(path, cachefile)
    return cachefile
end
