"""
$(SIGNATURES)

Runs JuDoc in the current directory.

Keyword arguments:

* `clear=false`:     whether to remove any existing output directory
* `verb=false`:      whether to display messages
* `port=8000`:       the port to use for the local server (should pick a number between 8000 and 9000)
* `single=false`:    whether to run a single pass or run continuously
* `prerender=false`: whether to pre-render javascript (KaTeX and highlight.js)
* `nomess=false`:    suppresses all messages (internal use).
* `isoptim=false`:   whether we're in an optimisation phase or not (if so, links are fixed in case
                     of a project website, see [`write_page`](@ref).
"""
function serve(; clear::Bool=true, verb::Bool=false, port::Int=8000, single::Bool=false,
                 prerender::Bool=false, nomess::Bool=false, isoptim::Bool=false,
                 no_fail_prerender::Bool=true
                 )::Union{Nothing,Int}
    # set the global path
    FOLDER_PATH[] = pwd()

    # brief check to see if we're in a folder that looks promising, otherwise stop
    # and tell the user to check (#155)
    if !isdir(joinpath(FOLDER_PATH[], "src"))
        throw(ArgumentError("The current directory doesn't have a src/ folder. " *
                            "Please change directory to a valid JuDoc folder."))
    end


    # construct the set of files to watch
    watched_files = jd_setup(clear=clear)

    nomess && (verb = false)

    # do a first full pass
    nomess || println("→ Initial full pass... ")
    start = time()
    sig = jd_fullpass(watched_files; clear=clear, verb=verb, prerender=prerender,
                      isoptim=isoptim, no_fail_prerender=no_fail_prerender)
    sig < 0 && return sig
    fmsg = rpad("✔ full pass...", 40)
    verb && (println(""); print(fmsg); print_final(fmsg, start); println(""))

    # start the continuous loop
    if !single
        nomess || println("→ Starting the server...")
        coreloopfun = (cntr, fw) -> jd_loop(cntr, fw, watched_files; clear=clear, verb=verb)
        # start the liveserver in the current directory
        LiveServer.setverbose(verb)
        LiveServer.serve(port=port, coreloopfun=coreloopfun)
    end
    return nothing
end


"""
$(SIGNATURES)

Sets up the collection of watched files by doing an initial scan of the input directory.
It also sets the paths variables and prepares the output directory.

**Keyword argument**

* `clear=false`: whether to remove any existing output directory

See also [`serve`](@ref).
"""
function jd_setup(; clear::Bool=true)::NamedTuple
    # . setting up:
    # -- reading and storing the path variables
    # -- setting up the output directory (see `clear`)
    set_paths!()
    prepare_output_dir(clear)

    # . recovering the list of files in the input dir we care about
    # -- these are stored in dictionaries, the key is the full path and the value is the time of
    # last change (useful for continuous monitoring)
    md_files    = TrackedFiles()
    html_files  = TrackedFiles()
    other_files = TrackedFiles()
    infra_files = TrackedFiles()
    # named tuples of all the watched files
    watched_files = (md=md_files, html=html_files, other=other_files, infra=infra_files)
    # fill the dictionaries
    scan_input_dir!(watched_files...)
    return watched_files
end


"""
$(SIGNATURES)

A single full pass of judoc looking at all watched files and processing them as appropriate.

**Keyword arguments**

* `clear=false`:     whether to remove any existing output directory
* `verb=false`:      whether to display messages
* `prerender=false`: whether to prerender katex and code blocks
* `isoptim=false`  : whether it's an optimization pass
* `no_fail_prerender=true`: whether to skip if a prerendering goes wrong in which case don't prerender

See also [`jd_loop`](@ref), [`serve`](@ref) and [`publish`](@ref).
"""
function jd_fullpass(watched_files::NamedTuple; clear::Bool=false, verb::Bool=false,
                     prerender::Bool=false, isoptim::Bool=false, no_fail_prerender::Bool=true
                     )::Int
     # initiate page segments
     head    = read(joinpath(PATHS[:src_html], "head.html"), String)
     pg_foot = read(joinpath(PATHS[:src_html], "page_foot.html"), String)
     foot    = read(joinpath(PATHS[:src_html], "foot.html"), String)

    # reset global page variables and latex definitions
    # NOTE: need to keep track of pre-path if specified, see optimize
    prepath = get(GLOBAL_PAGE_VARS, "prepath", nothing)
    def_GLOBAL_PAGE_VARS!()
    def_GLOBAL_LXDEFS!()
    # reinsert prepath if specified
    isnothing(prepath) || (GLOBAL_PAGE_VARS["prepath"] = prepath)

    # process configuration file (see also `process_md_defs`)
    process_config()


    # looking for an index file to process
    indexmd   = PATHS[:src] => "index.md"
    indexhtml = PATHS[:src] => "index.html"

    # rest of the pages
    s = 0
    begin
        if isfile(joinpath(indexmd...))
            a = process_file(:md, indexmd, head, pg_foot, foot; clear=clear,
                              prerender=prerender, isoptim=isoptim)
            if a < 0 && prerender && no_fail_prerender
                process_file(:md, indexmd, head, pg_foot, foot; clear=clear,
                              prerender=false, isoptim=isoptim)
            end
            s += a
        elseif isfile(joinpath(indexhtml...))
            a = process_file(:html, indexhtml, head, pg_foot, foot; clear=clear,
                              prerender=prerender, isoptim=isoptim)
            if a < 0 && prerender && no_fail_prerender
                process_file(:html, indexhtml, head, pg_foot, foot; clear=clear,
                              prerender=false, isoptim=isoptim)
            end
            s += a
        else
            @warn "I didn't find an index.[md|html], there should be one. Ignoring."
        end
        # process rest of the files
        for (case, dict) ∈ pairs(watched_files), (fpair, t) ∈ dict
            occursin("index.", fpair.second) && continue
            a = process_file(case, fpair, head, pg_foot, foot, t; clear=clear,
                              prerender=prerender, isoptim=isoptim)
            if a < 0 && prerender && no_fail_prerender
                process_file(case, fpair, head, pg_foot, foot, t; clear=clear,
                                  prerender=false, isoptim=isoptim)
            end
            s += a
        end
    end
    # return -1 if any page
    return ifelse(s<0, -1, 0)
end


"""
$(SIGNATURES)

This is the function that is continuously run, checks if files have been modified and if so,
processes them. Every 30 cycles, it checks whether any file was added or deleted and consequently
updates the `watched_files`.

**Keyword arguments**

* `clear=false`: whether to remove any existing output directory
* `verb=false`:  whether to display messages
"""
function jd_loop(cycle_counter::Int, ::LiveServer.FileWatcher, watched_files::NamedTuple;
                 clear::Bool=false, verb::Bool=false)::Nothing
    # every 30 cycles (3 seconds), scan directory to check for new or deleted files and
    # update dicts accordingly
    if mod(cycle_counter, 30) == 0
        # 1) check if some files have been deleted; note that we don't do anything,
        # we just remove the file reference from the corresponding dictionary.
        for d ∈ watched_files, (fpair, _) ∈ d
            isfile(joinpath(fpair...)) || delete!(d, fpair)
        end
        # 2) scan the input folder, if new files have been added then this will update
        # the dictionaries
        scan_input_dir!(watched_files..., verb)
    else
        # do a pass over the files, check if one has changed and if so trigger
        # the appropriate file processing mechanism
        for (case, dict) ∈ pairs(watched_files), (fpair, t) ∈ dict
            # check if there was a modification to the file
            fpath = joinpath(fpair...)
            cur_t = mtime(fpath)
            cur_t <= t && continue
            # if there was then the file has been modified and should be re-processed + copied
            fmsg = rpad("→ file $(fpath[length(FOLDER_PATH[])+1:end]) was modified ", 30)
            verb && print(fmsg)
            dict[fpair] = cur_t
            # if it's an infra_file
            if haskey(watched_files[:infra], fpair)
                #TODO: couldn't test this branch
                verb && println("→ full pass...")
                start = time()
                jd_fullpass(watched_files; clear=false, verb=false, prerender=false)
                verb && (print_final(rpad("✔ full pass...", 15), start); println(""))
            else
                fmsg = fmsg * rpad("→ updating... ", 15)
                verb && print("\r" * fmsg)
                start = time()
                # TODO, ideally these would only be read if they've changed. Not super important
                # but just not necessary. (Fixing may be a bit of a pain though)
                head    = read(joinpath(PATHS[:src_html], "head.html"), String)
                pg_foot = read(joinpath(PATHS[:src_html], "page_foot.html"), String)
                foot    = read(joinpath(PATHS[:src_html], "foot.html"), String)
                process_file(case, fpair, head, pg_foot, foot, cur_t; clear=false, prerender=false)
                verb && print_final(fmsg, start)
            end
        end
    end
    return nothing
end
