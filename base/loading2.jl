const PkgMap = Dict{Symbol, PkgId}
const PkgInfo = Tuple{PkgMap, Dict{PkgId, PkgMap}, Dict{PkgId, String}}

# find `where` stanza and return the PkgId for `name`
# return set of project file root and deps `name => uuid` mapping
function explicit_manifest_deps_get(manifest_file::String)::Dict{PkgId, PkgMap}
    info = Dict{PkgId, PkgMap}()
    open(manifest_file) do io
        id_map = PkgMap()
        later_id = Vector{PkgId}()
        later_deps = Vector{Vector{Any}}()
        uuid = deps = name = nothing
        state = :top
        # parse the manifest file, looking for uuid, name, and deps sections
        for line in eachline(io)
            if (m = match(re_section_capture, line)) !== nothing
                if name !== nothing
                    uuid === nothing && @warn "Missing UUID for $name may not be handled correctly" # roots should be the toplevel list
                    id = PkgId(uuid, name)
                    if deps isa PkgMap
                        info[id] = deps
                    elseif deps !== nothing
                        deps_list = nothing
                        # deps is a String of names, later we need to convert this to a Dict of UUID
                        # TODO: handle inline table syntax
                        if deps[1] == '[' || deps[end] == ']'
                            deps_list = Meta.parse(deps, raise=false)
                            if Meta.isexpr(deps_list, :vect) && all(x -> isa(x, String), deps_list.args)
                                deps_list = deps_list.args
                            end
                        end
                        if deps_list === nothing
                            @warn "Unexpected TOML deps format:\n$deps"
                        else
                            push!(later_map, id)
                            push!(later_deps, deps_list)
                        end
                    end
                    id_map[Symbol(name)] = id
                end
                uuid = deps = nothing
                name = String(m.captures[1])
                state = :stanza
            elseif state == :stanza
                if (m = match(re_uuid_to_string, line)) !== nothing
                    uuid = UUID(m.captures[1])
                elseif (m = match(re_deps_to_any, line)) !== nothing
                    deps = String(m.captures[1])
                elseif occursin(re_subsection_deps, line)
                    state = :deps
                    deps = PkgMap()
                elseif occursin(re_section, line)
                    state = :other
                end
            elseif state == :deps
                if (m = match(re_key_to_string, line)) !== nothing
                    d_name = String(m.captures[1])
                    d_uuid = UUID(m.captures[2])
                    deps[Symbol(d_name)] = PkgId(d_uuid, d_name)
                end
            end
        end
        # now that we have a map of name => uuid,
        # build the rest of the map
        for i = 1:length(later_id)
            id = later_id[i]
            deps = later_deps[i]
            deps_map = PkgMap()
            for dep in deps
                dep = Symbol(dep::String)
                deps_map[dep] = id_map[dep]
            end
            info[id] = deps_map
        end
        nothing
    end
    return info
end

#function explicit_manifest_uuid_path(project_file::String, pkg::PkgId)::Union{Nothing,String}
#    open(manifest_file) do io
#        uuid = name = path = hash = nothing
#        for line in eachline(io)
#            if (m = match(re_section_capture, line)) != nothing
#                uuid == pkg.uuid && break
#                name = String(m.captures[1])
#                path = hash = nothing
#            elseif (m = match(re_uuid_to_string, line)) != nothing
#                uuid = UUID(m.captures[1])
#            elseif (m = match(re_path_to_string, line)) != nothing
#                path = String(m.captures[1])
#            elseif (m = match(re_hash_to_string, line)) != nothing
#                hash = SHA1(m.captures[1])
#            end
#        end
#        uuid == pkg.uuid || return nothing
#        name == pkg.name || return nothing # TODO: allow a mismatch?
#        if path !== nothing
#            path = normpath(abspath(dirname(manifest_file), path))
#            return path
#        end
#        hash === nothing && return nothing
#        # Keep the 4 since it used to be the default
#        for slug in (version_slug(uuid, hash, 4), version_slug(uuid, hash))
#            for depot in DEPOT_PATH
#                path = abspath(depot, "packages", name, slug)
#                ispath(path) && return path
#            end
#        end
#        return nothing
#    end
#end

function explicit_project_deps_get(project_file::String)::PkgInfo
    roots = PkgMap()
    info = Dict{PkgId, PkgMap}()
    paths = Dict{PkgId, String}()
    open(project_file) do io
        root_name = nothing
        manifest_file = nothing
        root_uuid = dummy_uuid(project_file)
        state = :top
        for line in eachline(io)
            if occursin(re_section, line)
                state = occursin(re_section_deps, line) ? :deps : :other
            elseif state == :top
                if (m = match(re_name_to_string, line)) != nothing
                    root_name = String(m.captures[1])
                elseif (m = match(re_uuid_to_string, line)) != nothing
                    root_uuid = UUID(m.captures[1])
                elseif (m = match(re_manifest_to_string, line)) != nothing
                    manifest_file = normpath(joinpath(dir, m.captures[1]))
                end
            elseif state == :deps
                if (m = match(re_key_to_string, line)) != nothing
                    name = m.captures[1]
                    uuid = UUID(m.captures[2])
                    roots[Symbol(name)] = PkgId(name, uuid)
                end
            end
        end
        root_name !== nothing && (roots[Symbol(root_name)] = PkgId(root_name, root_uuid))

        if manifest_file === nothing
            for mfst in manifest_names
                manifest_file = joinpath(dir, mfst)
                if isfile_casesensitive(manifest_file)
                    info = explicit_manifest_deps_get(manifest_file)
                    break
                end
            end
        elseif isfile_casesensitive(manifest_file)
            info = explicit_manifest_deps_get(manifest_file)
        end
        nothing
    end
    return roots, info, paths
end

# look for an entry-point for `name`, check that UUID matches
# if there's a project file, look up `name` in its deps and return that
# otherwise return `nothing` to indicate the caller should keep searching
function implicit_manifest_deps_get(dir::String, where::PkgId, name::String)::Union{Nothing,PkgId}
    return PkgId(pkg_uuid, name)
end


# return the set of entry point that exist in a top-level package (no environment)
function implicit_project_deps_get(dir::String)::PkgInfo
    roots = PkgMap()
    info = Dict{PkgId, PkgMap}()
    paths = Dict{PkgId, String}()
    for name in readdir(dir)
        path, project_file = entry_point_and_project_file(dir, name)
        if path !== nothing
            id = nothing
            if project_file === nothing
                id = PkgId(name)
                info[id] = roots
            else
                id = project_file_name_uuid(project_file, name)
                id.name == name || (id = nothing)
                deps = explicit_project_deps_get(project_file)[1] # TODO: don't need to look at the Manifest
                info[id] = deps
            end
            if id !== nothing
                roots[Symbol(name)] = id
                paths[id] = path
            end
        end
    end
    return roots, info, paths
end

function project_deps_get(env::String)::PkgInfo
    project_file = env_project_file(env)
    if project_file isa String
        # use project and manifest files
        return explicit_project_deps_get(project_file)
    elseif project_file
        # if env names a directory, search it
        return implicit_project_deps_get(env)
    end
    return (PkgMap(), Dict{PkgId, PkgMap}(), Dict{PkgId, String}())
end

# identify_package computes the PkgId for `name` from toplevel context
# by looking through the Project.toml files and directories
function identify_package()::Vector{Dict{Symbol, PkgId}}
    return Vector{PkgInfo}[ project_deps_get(env, name) for env in load_path() ]
end


function locate_package()::Vector{Dict{PkgId, String}}
    if pkg.uuid === nothing
        for env in load_path()
            # look for the toplevel pkg `pkg.name` in this entry
            found = project_deps_get(env, pkg.name)
            found === nothing && continue
            if pkg == found
                # pkg.name is present in this directory or project file,
                # return the path the entry point for the code, if it could be found
                # otherwise, signal failure
                return implicit_manifest_uuid_path(env, pkg)
            end
            @assert found.uuid !== nothing
            return locate_package(found) # restart search now that we know the uuid for pkg
        end
    else
        for env in load_path()
            path = manifest_uuid_path(env, pkg)
            path === nothing || return entry_path(path, pkg.name)
        end
    end
    return nothing
end


