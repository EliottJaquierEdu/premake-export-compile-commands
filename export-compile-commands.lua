local p = premake

p.modules.export_compile_commands = {}
local m = p.modules.export_compile_commands

local workspace = p.workspace
local project = p.project

local function esc(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  return s
end

local function esc_table(t)
  local res = {}
  for k, v in pairs(t) do
    table.insert(res, esc(v))
  end
  return res
end

local function quote(s)
  return '"' .. esc(s) .. '"'
end

function m.getToolset(cfg)
  return p.tools[cfg.toolset or 'gcc']
end

function m.getCommonFlags(prj, cfg)
  -- some tools that consumes compile_commands.json have problems with relative include paths
  relative = project.getrelative
  project.getrelative = function(prj, dir) return dir end

  local toolset = m.getToolset(cfg)
  local flags = toolset.getcppflags(cfg)
  flags = table.join(flags, toolset.getdefines(cfg.defines))
  flags = table.join(flags, toolset.getundefines(cfg.undefines))
  flags = table.join(flags, toolset.getincludedirs(cfg, cfg.includedirs, cfg.sysincludedirs))
  flags = table.join(flags, toolset.getforceincludes(cfg))
  if project.iscpp(prj) then
    flags = table.join(flags, toolset.getcxxflags(cfg))
  elseif project.isc(prj) then
    flags = table.join(flags, toolset.getcflags(cfg))
  end
  flags = table.join(flags, cfg.buildoptions)
  project.getrelative = relative
  return flags
end

function m.getObjectPath(prj, cfg, node)
  return path.join(cfg.objdir, path.appendExtension(node.objname, '.o'))
end

function m.getDependenciesPath(prj, cfg, node)
  return path.join(cfg.objdir, path.appendExtension(node.objname, '.d'))
end

function m.getFileFlags(prj, cfg, node)
  return table.join(m.getCommonFlags(prj, cfg), {
    '-o', quote(m.getObjectPath(prj, cfg, node)),
    '-MF', quote(m.getDependenciesPath(prj, cfg, node)),
    '-c', quote(node.abspath)
  })
end

local function computesystemincludepaths(tool, iscfile)
  local cmd = tool .. " -E -v -fsyntax-only " .. (iscfile and '-x c' or '-x c++') .. ' "' .. _MAIN_SCRIPT .. '"' -- Use script as dummy "c" file
  local s,e = os.outputof(cmd, "both")
  if not s or not e then return {} end
  local s = string.match(s, "#include <...> search starts here:\n(.*)End of search list.\n")
  local includepaths = {}
  for w in string.gmatch(s, " *([^\n]+) *") do
    table.insert(includepaths, path.normalize(w))
  end
  return includepaths
end

local systemincludepathscache = {}

local function getsystemincludepaths(tool, iscfile)
  if not systemincludepathscache[tool] then systemincludepathscache[tool] = {} end
  local toolcache = systemincludepathscache[tool]
  if not toolcache[iscfile] then toolcache[iscfile] = computesystemincludepaths(tool, iscfile) end
  return toolcache[iscfile]
end

local function getsystemflags(tool, iscfile)
  return table.implode(getsystemincludepaths(tool, iscfile), ' -isystem \\"', '\\"', '')
end

function m.generateCompileCommand(prj, cfg, node)
  local toolset = m.getToolset(cfg)
  local tool = path.iscfile(node.abspath) and 'cc' or 'cxx'
  cfg.gccprefix = cfg.gccprefix or "" -- hack to have gcc.gettoolname return non-nil
  local tool = toolset.gettoolname(cfg, tool) or tool
  local system_flag = getsystemflags(tool, path.iscfile(node.abspath))
  return {
    directory = prj.location,
    file = node.abspath,
    command = (tool .. system_flag .. " " .. table.concat(esc_table(m.getFileFlags(prj, cfg, node)), ' '))
  }
end

function m.includeFile(prj, node, depth)
  return path.iscppfile(node.abspath) or path.iscfile(node.abspath)
end

function m.getProjectCommands(prj, cfg)
  local tr = project.getsourcetree(prj)
  local cmds = {}
  p.tree.traverse(tr, {
    onleaf = function(node, depth)
      if not m.includeFile(prj, node, depth) then
        return
      end
      table.insert(cmds, m.generateCompileCommand(prj, cfg, node))
    end
  })
  return cmds
end

function m.onWorkspace(wks)
  local cfgCmds = {}
  for prj in workspace.eachproject(wks) do
    for cfg in project.eachconfig(prj) do
      local cfgKey = string.format('%s', cfg.shortname)
      if not cfgCmds[cfgKey] then
        cfgCmds[cfgKey] = {}
      end
      cfgCmds[cfgKey] = table.join(cfgCmds[cfgKey], m.getProjectCommands(prj, cfg))
    end
  end
  for cfgKey,cmds in pairs(cfgCmds) do
    local outfile = string.format('%s/compile_commands.json', cfgKey)
    p.generate(wks, outfile, function(wks)
      p.push('[')
      for i = 1, #cmds do
        local item = cmds[i]
        p.push('{')
        p.x('"directory": "%s",', item.directory)
        p.x('"file": "%s",', item.file)
        p.w('"command": "%s"', item.command)
        if i ~= #cmds then
          p.pop('},')
        else
          p.pop('}')
        end
      end
      p.pop(']')
    end)
  end
end

newaction {
  trigger = 'export-compile-commands',
  description = 'Export compiler commands in JSON Compilation Database Format',
  onWorkspace = m.onWorkspace,
  toolset = "clang",
  valid_kinds = { "ConsoleApp", "WindowedApp", "Makefile", "SharedLib", "StaticLib", "Utility" },
  valid_languages = { "C", "C++" },
  valid_tools = {
    cc = { "gcc", "clang" }
  }
}

return m
