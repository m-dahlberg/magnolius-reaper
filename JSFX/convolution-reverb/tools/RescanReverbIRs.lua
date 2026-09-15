-- Rescan reverb IRs (Magnolius_ConvolutionReverb.jsfx)
--
-- Rebuilds <resource>/Data/ConvReverbIRs.idx, the filename index the plugin's
-- built-in IR browser reads. Same job as tools/index_irs.py, but runnable from
-- inside REAPER: Actions -> Load ReaScript, then run it after adding IRs and
-- press Rescan in the plugin.
--
-- The index lives in Data/ and NOT in Data/ReverbIRs, because anything inside
-- that folder also appears in the Reverb IR file slider's dropdown.

local res    = reaper.GetResourcePath()
local sep    = package.config:sub(1, 1)
local irdir  = res .. sep .. "Data" .. sep .. "ReverbIRs"
local outpath = res .. sep .. "Data" .. sep .. "ConvReverbIRs.idx"

local names = {}

local function scan(dir, prefix)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():sub(-4) == ".wav" then names[#names + 1] = prefix .. f end
    i = i + 1
  end
  i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    scan(dir .. sep .. d, prefix .. d .. "/")
    i = i + 1
  end
end

scan(irdir, "")
table.sort(names, function(a, b) return a:lower() < b:lower() end)

local fh = io.open(outpath, "w")
if not fh then
  reaper.ShowMessageBox("Could not write:\n" .. outpath, "Rescan reverb IRs", 0)
  return
end
fh:write(table.concat(names, "\n"))
if #names > 0 then fh:write("\n") end
fh:close()

reaper.ShowMessageBox(
  string.format("Indexed %d IR file(s) from:\n%s\n\nPress Rescan in the plugin.",
                #names, irdir),
  "Rescan reverb IRs", 0)
