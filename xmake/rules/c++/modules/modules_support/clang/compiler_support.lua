--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki, Arthapz
-- @file        clang/compiler_support.lua
--

-- imports
import("core.base.semver")
import("core.base.option")
import("core.base.json")
import("lib.detect.find_tool")
import("lib.detect.find_file")
import(".compiler_support", {inherit = true})

-- get includedirs for stl headers
--
-- $ echo '#include <vector>' | clang -x c++ -E - | grep '/vector"'
-- # 1 "/usr/include/c++/11/vector" 1 3
-- # 58 "/usr/include/c++/11/vector" 3
-- # 59 "/usr/include/c++/11/vector" 3
--
function _get_toolchain_includedirs_for_stlheaders(target, includedirs, clang)
    local tmpfile = os.tmpfile() .. ".cc"
    io.writefile(tmpfile, "#include <vector>")
    local argv = {"-E", "-x", "c++", tmpfile}
    local cpplib = _get_cpplibrary_name(target)
    if cpplib then
        if cpplib == "c++" then
            table.insert(argv, 1, "-stdlib=libc++")
        elseif cpplib == "stdc++" then
            table.insert(argv, 1, "-stdlib=libstdc++")
        end
    end
    local result = try {function () return os.iorunv(clang, argv) end}
    if result then
        for _, line in ipairs(result:split("\n", {plain = true})) do
            line = line:trim()
            if line:startswith("#") and line:find("/vector\"", 1, true) then
                local includedir = line:match("\"(.+)/vector\"")
                if includedir and os.isdir(includedir) then
                    table.insert(includedirs, path.normalize(includedir))
                    break
                end
            end
        end
    end
    os.tryrm(tmpfile)
end

function _get_cpplibrary_name(target)
    -- libc++ come first because on windows, if we use libc++ clang will still use msvc crt so MD / MT / MDd / MTd can be set
    if target:has_runtime("c++_shared", "c++_static") then
        return "c++"
    elseif target:has_runtime("stdc++_shared", "stdc++_static") then
        return "stdc++"
    elseif target:is_plat("windows") and target:has_runtime("MD", "MT", "MDd", "MTd") then
        return "msstl"
    end
end

-- load module support for the current target
function load(target)
    local clangmodulesflag, modulestsflag, withoutflag = get_modulesflag(target)

    -- add module flags
    if not withoutflag then
        target:add("cxxflags", modulestsflag)
    end

    -- fix default visibility for functions and variables [-fvisibility] differs in PCH file vs. current file
    -- module.pcm cannot be loaded due to a configuration mismatch with the current compilation.
    --
    -- it will happen in binary target depend on library target with modules, and enable release mode at same time.
    --
    -- @see https://github.com/xmake-io/xmake/issues/3358#issuecomment-1432586767
    local dep_symbols
    local has_library_deps = false
    for _, dep in ipairs(target:orderdeps()) do
        if dep:is_shared() or dep:is_static() or dep:is_object() then
            dep_symbols = dep:get("symbols")
            has_library_deps = true
            break
        end
    end
    if has_library_deps then
        target:set("symbols", dep_symbols and dep_symbols or "none")
    end

    -- on Windows before llvm18 we need to disable delayed-template-parsing because it's incompatible with modules, from llvm >= 18, it's disabled by default
    local clang_version = get_clang_version(target)
    if semver.compare(clang_version, "18") < 0 then
        target:add("cxxflags", "-fno-delayed-template-parsing")
    end
end

-- provide toolchain include directories for stl headerunit when p1689 is not supported
function toolchain_includedirs(target)
    local includedirs = _g.includedirs
    if includedirs == nil then
        includedirs = {}
        local clang, toolname = target:tool("cxx")
        assert(toolname:startswith("clang"))
        _get_toolchain_includedirs_for_stlheaders(target, includedirs, clang)
        local cpplib = _get_cpplibrary_name(target)
        local runtime_flag
        if cpplib then
            if cpplib == "c++" then
                runtime_flag = "-stdlib=libc++"
            elseif cpplib == "stdc++" then
                runtime_flag = "-stdlib=libstdc++"
            end
        end
        local _, result = try {function () return os.iorunv(clang, table.join({"-E", "-Wp,-v", "-xc", os.nuldev()}, runtime_flag or {})) end}
        if result then
            for _, line in ipairs(result:split("\n", {plain = true})) do
                line = line:trim()
                if os.isdir(line) then
                    table.insert(includedirs, path.normalize(line))
                elseif line:startswith("End") then
                    break
                end
            end
        end
        _g.includedirs = includedirs
    end
    return includedirs
end

-- get clang path
function get_clang_path(target)
    local clang_path = _g.clang_path
    if not clang_path then
        local program, toolname = target:tool("cxx")
        if program and toolname:startswith("clang") then
            local clang = find_tool(toolname, {program = program})
            if clang then
                clang_path = clang.program
            end
        end
        clang_path = clang_path or false
        _g.clang_path = clang_path
    end
    return clang_path or nil
end

-- get clang version
function get_clang_version(target)
    local clang_version = _g.clang_version
    if not clang_version then
        local program, toolname = target:tool("cxx")
        if program and toolname:startswith("clang") then
            local clang = find_tool(toolname, {program = program, version = true})
            if clang then
                clang_version = clang.version
            end
        end
        clang_version = clang_version or false
        _g.clang_version = clang_version
    end
    return clang_version or nil
end

-- get clang-scan-deps
function get_clang_scan_deps(target)
    local clang_scan_deps = _g.clang_scan_deps
    if not clang_scan_deps then
        local program, toolname = target:tool("cxx")
        if program and toolname:startswith("clang") then
            local dir = path.directory(program)
            local basename = path.basename(program)
            local extension = path.extension(program)
            program = (basename:gsub("clang", "clang-scan-deps")) .. extension
            if dir and dir ~= "." and os.isdir(dir) then
                program = path.join(dir, program)
            end
            local result = find_tool("clang-scan-deps", {program = program, version = true})
            if result then
                clang_scan_deps = result.program
            end
        end
        clang_scan_deps = clang_scan_deps or false
        _g.clang_scan_deps = clang_scan_deps
    end
    return clang_scan_deps or nil
end

function get_stdmodules(target)
    if target:policy("build.c++.modules.std") then
        local cpplib = _get_cpplibrary_name(target)
        if cpplib then
            if cpplib == "c++" then
                -- libc++ module is found by parsing libc++.modules.json
                -- which can be found in <llvm_path>/lib subdirectory (i.e on debian it should be <llvm_path>/lib/x86_64-unknown-linux-gnu/)
                -- in the futur llvm may provide a way to directory get the path of libc++.modules.json 
                -- @see https://github.com/llvm/llvm-project/pull/76451 (has been revert, so we need to wait)
                local clang_path = path.directory(get_clang_path(target))
                local clang_lib_path = path.join(clang_path, "..", "lib")
                local modules_json_path = find_file("libc++.modules.json", clang_lib_path)
                if modules_json_path then
                    local modules_json = json.decode(io.readfile(modules_json_path))
                    local std_module_directory = path.directory(modules_json.modules[1]["source-path"])
                    if not path.is_absolute(std_module_directory) then
                        std_module_directory = path.join(path.directory(modules_json_path), std_module_directory)
                    end
                    return {path.join(std_module_directory, "std.cppm"), path.join(std_module_directory, "std.compat.cppm")}
                end
            elseif cpplib == "stdc++" then
                -- libstdc++ doesn't have a std module file atm
            elseif cpplib == "msstl" then
                -- msstl std module file is not compatible with llvm <= 19
                -- local toolchain = target:toolchain("clang")
                -- local msvc = import("core.tool.toolchain", {anonymous = true}).load("msvc", {plat = toolchain:plat(), arch = toolchain:arch()})
                -- if msvc then
                --     local vcvars = msvc:config("vcvars")
                --     if vcvars.VCInstallDir and vcvars.VCToolsVersion then
                --         modules = {}
                --
                --         local stdmodulesdir = path.join(vcvars.VCInstallDir, "Tools", "MSVC", vcvars.VCToolsVersion, "modules")
                --         assert(stdmodulesdir, "Can't enable C++23 std modules, directory missing !")
                --
                --         return {path.join(stdmodulesdir, "std.ixx"), path.join(stdmodulesdir, "std.compat.ixx")}
                --     end
                -- end
            end
        end
    end
end

function get_bmi_extension()
    return ".pcm"
end

function get_modulesflag(target)
    local clangmodulesflag = _g.clangmodulesflag
    local modulestsflag = _g.modulestsflag
    local withoutflag = _g.withoutflag
    if clangmodulesflag == nil and modulestsflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodules", "cxxflags", {flagskey = "clang_modules"}) then
            clangmodulesflag = "-fmodules"
        end
        if compinst:has_flags("-fmodules-ts", "cxxflags", {flagskey = "clang_modules_ts"}) then
            modulestsflag = "-fmodules-ts"
        end
        local clang_version = get_clang_version(target)
        withoutflag = semver.compare(clang_version, "16.0") >= 0
        assert(withoutflag or modulestsflag, "compiler(clang): does not support c++ module!")
        _g.clangmodulesflag = clangmodulesflag or false
        _g.modulestsflag = modulestsflag or false
        _g.withoutflag = withoutflag or false
    end
    return clangmodulesflag or nil, modulestsflag or nil, withoutflag or nil
end

function get_builtinmodulemapflag(target)
    local builtinmodulemapflag = _g.builtinmodulemapflag
    if builtinmodulemapflag == nil then
        -- this flag seems clang on mingw doesn't distribute it
        -- @see https://github.com/xmake-io/xmake/pull/2833
        if not target:is_plat("mingw") then
            local compinst = target:compiler("cxx")
            if compinst:has_flags("-fbuiltin-module-map", "cxxflags", {flagskey = "clang_builtin_module_map"}) then
                builtinmodulemapflag = "-fbuiltin-module-map"
            end
            assert(builtinmodulemapflag, "compiler(clang): does not support c++ module!")
        end
        _g.builtinmodulemapflag = builtinmodulemapflag or false
    end
    return builtinmodulemapflag or nil
end

function get_implicitmodulesflag(target)
    local implicitmodulesflag = _g.implicitmodulesflag
    if implicitmodulesflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fimplicit-modules", "cxxflags", {flagskey = "clang_implicit_modules"}) then
            implicitmodulesflag = "-fimplicit-modules"
        end
        assert(implicitmodulesflag, "compiler(clang): does not support c++ module!")
        _g.implicitmodulesflag = implicitmodulesflag or false
    end
    return implicitmodulesflag or nil
end

function get_implicitmodulemapsflag(target)
    local implicitmodulemapsflag = _g.implicitmodulemapsflag
    if implicitmodulemapsflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fimplicit-module-maps", "cxxflags", {flagskey = "clang_implicit_module_map"}) then
            implicitmodulemapsflag = "-fimplicit-module-maps"
        end
        assert(implicitmodulemapsflag, "compiler(clang): does not support c++ module!")
        _g.implicitmodulemapsflag = implicitmodulemapsflag or false
    end
    return implicitmodulemapsflag or nil
end

function get_noimplicitmodulemapsflag(target)
    local noimplicitmodulemapsflag = _g.noimplicitmodulemapsflag
    if noimplicitmodulemapsflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fno-implicit-module-maps", "cxxflags", {flagskey = "clang_no_implicit_module_maps"}) then
            noimplicitmodulemapsflag = "-fno-implicit-module-maps"
        end
        assert(noimplicitmodulemapsflag, "compiler(clang): does not support c++ module!")
        _g.noimplicitmodulemapsflag = noimplicitmodulemapsflag or false
    end
    return noimplicitmodulemapsflag or nil
end

function get_prebuiltmodulepathflag(target)
    local prebuiltmodulepathflag = _g.prebuiltmodulepathflag
    if prebuiltmodulepathflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fprebuilt-module-path=" .. os.tmpdir(), "cxxflags", {flagskey = "clang_prebuild_module_path"}) then
            prebuiltmodulepathflag = "-fprebuilt-module-path="
        end
        assert(prebuiltmodulepathflag, "compiler(clang): does not support c++ module!")
        _g.prebuiltmodulepathflag = prebuiltmodulepathflag or false
    end
    return prebuiltmodulepathflag or nil
end

function get_modulecachepathflag(target)
    local modulecachepathflag = _g.modulecachepathflag
    if modulecachepathflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodules-cache-path=" .. os.tmpdir(), "cxxflags", {flagskey = "clang_modules_cache_path"}) then
            modulecachepathflag = "-fmodules-cache-path="
        end
        assert(modulecachepathflag, "compiler(clang): does not support c++ module!")
        _g.modulecachepathflag = modulecachepathflag or false
    end
    return modulecachepathflag or nil
end

function get_modulefileflag(target)
    local modulefileflag = _g.modulefileflag
    if modulefileflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodule-file=" .. os.tmpfile() .. get_bmi_extension(), "cxxflags", {flagskey = "clang_module_file"}) then
            modulefileflag = "-fmodule-file="
        end
        assert(modulefileflag, "compiler(clang): does not support c++ module!")
        _g.modulefileflag = modulefileflag or false
    end
    return modulefileflag or nil
end

function get_moduleheaderflag(target)
    local moduleheaderflag = _g.moduleheaderflag
    if moduleheaderflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodule-header=system", "cxxflags", {flagskey = "clang_module_header"}) then
            moduleheaderflag = "-fmodule-header="
        end
        _g.moduleheaderflag = moduleheaderflag or false
    end
    return moduleheaderflag or nil
end

function has_clangscandepssupport(target)
    local support_clangscandeps = _g.support_clangscandeps
    if support_clangscandeps == nil then
        local clangscandeps = get_clang_scan_deps(target)
        local clang_version = get_clang_version(target)
        if clangscandeps and clang_version and semver.compare(clang_version, "16.0") >= 0 then
            support_clangscandeps = true
        end
        _g.support_clangscandeps = support_clangscandeps or false
    end
    return support_clangscandeps or nil
end

function get_keepsystemincludesflag(target)
    local keepsystemincludesflag = _g.keepsystemincludesflag
    if keepsystemincludesflag == nil then
        local compinst = target:compiler("cxx")
        local clang_version = get_clang_version(target)
        if compinst:has_flags("-E -fkeep-system-includes", "cxxflags", {flagskey = "clang_keep_system_includes", tryrun = true}) and
            semver.compare(clang_version, "18.0") >= 0 then
            keepsystemincludesflag = "-fkeep-system-includes"
        end
        _g.keepsystemincludesflag = keepsystemincludesflag or false
    end
    return keepsystemincludesflag or nil
end

function get_moduleoutputflag(target)
    local moduleoutputflag = _g.moduleoutputflag
    if moduleoutputflag == nil then
        local compinst = target:compiler("cxx")
        local clang_version = get_clang_version(target)
        if compinst:has_flags("-fmodule-output=", "cxxflags", {flagskey = "clang_module_output", tryrun = true}) and
            semver.compare(clang_version, "16.0") >= 0 then
            moduleoutputflag = "-fmodule-output="
        end
        _g.moduleoutputflag = moduleoutputflag or false
    end
    return moduleoutputflag or nil
end

